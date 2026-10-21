// Private CloudKit handoff of verified whole saves. Only successful game commits
// are captured; imports happen before the guest mounts its save directory.
#import "DmCloudSave.h"
#import "DmSaveArchive.h"
#import <CloudKit/CloudKit.h>
#include "game_profile.h"

@interface DmCloudSave ()
@property(strong) dispatch_queue_t queue; // state and all CloudKit work belong here
@property(strong) CKContainer *container;
@property(strong) CKDatabase *database;
@property(copy) NSString *profile;
@property(copy) NSString *directory;
@property(strong) NSMutableDictionary *state;
@property(strong) NSLock *snapshotLock; // game thread publishes only completed snapshots
@property(strong) NSDictionary *latest;
@property(strong) CKOperation *operation;
@property BOOL started;
@property BOOL syncScheduled;
@property(strong) NSTimer *timer; // main-thread lifecycle/UI below
@property(weak) UIViewController *controller;
@property UIBackgroundTaskIdentifier backgroundTask;
@property BOOL backgroundExpired; // main thread; renewed only after foregrounding
@property BOOL pausedForBackground; // protected by snapshotLock
@end

static NSError *cloudError(NSString *message) {
    return [NSError errorWithDomain:@"DmCloudSave" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL sameDigest(NSString *a, NSString *b) { return a == b || [a isEqual:b]; }

@implementation DmCloudSave
+ (BOOL)enabled { return strlen(DM_GAME_CLOUD_CONTAINER) != 0; }
+ (instancetype)shared {
    static DmCloudSave *value; static dispatch_once_t once;
    dispatch_once(&once,^{value=[self new];}); return value;
}
- (instancetype)init {
    if ((self=[super init])) {
        _queue=dispatch_queue_create("dm.private-cloud-save",DISPATCH_QUEUE_SERIAL);
        _snapshotLock=[NSLock new]; _backgroundTask=UIBackgroundTaskInvalid;
        NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        const char *path=getenv("DM_SAVE");
        _profile=(path ? @(path) : [docs stringByAppendingPathComponent:@"save"]).stringByStandardizingPath;
        _directory=[docs stringByAppendingPathComponent:@"iCloudSync"];
        [NSFileManager.defaultManager createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:nil];
        _state=[[NSDictionary dictionaryWithContentsOfFile:[_directory stringByAppendingPathComponent:@"state.plist"]] mutableCopy] ?: [NSMutableDictionary new];
        if ([self.class enabled]) {
            _container=[CKContainer containerWithIdentifier:@DM_GAME_CLOUD_CONTAINER];
            _database=_container.privateCloudDatabase;
        }
    } return self;
}
- (void)saveState {
    if (![self.state writeToFile:[self.directory stringByAppendingPathComponent:@"state.plist"] atomically:YES])
        fprintf(stderr,"[RED] cloud-save: could not persist sync state; local save retained\n");
}
- (NSDictionary *)snapshot {
    [self.snapshotLock lock]; NSDictionary *save=self.latest; [self.snapshotLock unlock]; return save;
}
- (void)publish:(NSDictionary *)save {
    [self.snapshotLock lock]; self.latest=save; [self.snapshotLock unlock];
}
- (void)setStatus:(NSString *)status detail:(NSString *)detail remote:(NSString *)remote {
    // Only this serial queue writes receipts. They are diagnostics, never game UI.
    NSMutableDictionary *receipt=[@{@"status":status,@"detail":detail ?: @"",@"date":NSDate.date.description,
        @"game":@DM_GAME_ID,@"container":@DM_GAME_CLOUD_CONTAINER,@"device":UIDevice.currentDevice.model,
        @"build":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"",
        @"localDigest":[self snapshot][@"digest"] ?: @"",@"baseDigest":self.state[@"baseDigest"] ?: @"",
        @"uploads":self.state[@"uploads"] ?: @0,@"imports":self.state[@"imports"] ?: @0} mutableCopy];
    if (remote) receipt[@"remoteDigest"]=remote;
    NSData *json=[NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingPrettyPrinted error:nil];
    if (![json writeToFile:[self.directory stringByAppendingPathComponent:@"status.json"] options:NSDataWritingAtomic error:nil])
        fprintf(stderr,"[RED] cloud-save: could not write diagnostic receipt\n");
    fprintf(stderr,"[cloud-save] %s: %s\n",status.UTF8String,detail.UTF8String ?: "");
}
- (void)pending:(NSError *)error {
    [self setStatus:@"pending" detail:error.localizedDescription ?: @"Local save retained; retrying automatically." remote:nil];
}
- (CKRecordID *)recordID {
    return [[CKRecordID alloc] initWithRecordName:[NSString stringWithFormat:@"%s-save-format-1",DM_GAME_ID]];
}
- (BOOL)checkAccount:(NSError **)error {
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    __block CKRecordID *user=nil; __block NSError *failure=nil;
    [self.container fetchUserRecordIDWithCompletionHandler:^(CKRecordID *recordID,NSError *e){user=recordID;failure=e;dispatch_semaphore_signal(done);}];
    if (dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))) {
        if(error)*error=cloudError(@"iCloud did not respond; local progress is safe."); return NO;
    }
    if (failure || !user) { if(error)*error=failure ?: cloudError(@"Sign in to iCloud to sync saves."); return NO; }
    NSString *previous=self.state[@"cloudUser"];
    if (previous && ![previous isEqual:user.recordName]) {
        if(error)*error=cloudError(@"The iCloud account changed. Sync is paused to preserve both accounts' saves."); return NO;
    }
    self.state[@"cloudUser"]=user.recordName; [self saveState]; return YES;
}
- (void)trackOperation:(CKOperation *)operation {
    [self.snapshotLock lock]; self.operation=operation; BOOL paused=self.pausedForBackground; [self.snapshotLock unlock];
    if (paused) [operation cancel];
}
- (CKRecord *)fetchRecordWithAsset:(BOOL)asset error:(NSError **)error {
    CKFetchRecordsOperation *operation=[[CKFetchRecordsOperation alloc] initWithRecordIDs:@[self.recordID]];
    if (!asset) operation.desiredKeys=@[@"digest",@"device",@"updated"];
    operation.configuration.timeoutIntervalForRequest=10; operation.configuration.timeoutIntervalForResource=20;
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    __block CKRecord *result=nil; __block NSError *failure=nil;
    operation.perRecordCompletionBlock=^(CKRecord *record,CKRecordID *identifier,NSError *e){(void)identifier;result=record;failure=e;};
    operation.fetchRecordsCompletionBlock=^(NSDictionary *records,NSError *e){(void)records;if(!failure)failure=e;dispatch_semaphore_signal(done);};
    [self trackOperation:operation]; [self.database addOperation:operation];
    BOOL timedOut=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,25*NSEC_PER_SEC)) != 0;
    [self trackOperation:nil];
    if (timedOut) { [operation cancel]; if(error)*error=cloudError(@"iCloud download timed out; local progress is safe."); return nil; }
    if (failure.code==CKErrorUnknownItem && [failure.domain isEqual:CKErrorDomain]) failure=nil;
    if(error)*error=failure; return failure ? nil : result;
}
- (NSDictionary *)readRecord:(CKRecord *)record error:(NSError **)error {
    CKAsset *asset=record[@"payload"];
    if (![asset isKindOfClass:CKAsset.class] || !asset.fileURL) {
        if(error)*error=cloudError(@"The iCloud save download is incomplete."); return nil;
    }
    // The archive decoder imposes game identity, entry, byte and tree bounds.
    NSNumber *size=nil; [asset.fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:error];
    if (!size || size.unsignedLongLongValue > (300ull<<20)) {
        if(error && !*error)*error=cloudError(@"The iCloud save exceeds the archive limit."); return nil;
    }
    NSData *data=[NSData dataWithContentsOfURL:asset.fileURL options:NSDataReadingMappedIfSafe error:error];
    NSDictionary *save=data ? DmDecodeSave(data,error) : nil;
    if (save && ![save[@"digest"] isEqual:record[@"digest"]]) {
        if(error)*error=cloudError(@"The iCloud save checksum did not match."); return nil;
    }
    return save;
}
- (void)acknowledge:(NSDictionary *)save {
    self.state[@"baseDigest"]=save[@"digest"]; self.state[@"lastSynced"]=NSDate.date; [self saveState];
    [self setStatus:@"synced" detail:@"Completed save confirmed in iCloud." remote:save[@"digest"]];
}
- (BOOL)upload:(NSDictionary *)save replacing:(CKRecord *)record error:(NSError **)error {
    NSData *data=DmEncodeSave(save,error); if(!data)return NO;
    NSString *file=[self.directory stringByAppendingPathComponent:[NSString stringWithFormat:@"upload-%@.plist",NSUUID.UUID.UUIDString]];
    if (![data writeToFile:file options:NSDataWritingAtomic error:error]) return NO;
    CKRecord *head=record ?: [[CKRecord alloc] initWithRecordType:@"GameSave" recordID:self.recordID];
    head[@"payload"]=[[CKAsset alloc] initWithFileURL:[NSURL fileURLWithPath:file]];
    head[@"digest"]=save[@"digest"]; head[@"device"]=UIDevice.currentDevice.model; head[@"updated"]=NSDate.date;
    CKModifyRecordsOperation *operation=[[CKModifyRecordsOperation alloc] initWithRecordsToSave:@[head] recordIDsToDelete:nil];
    operation.savePolicy=CKRecordSaveIfServerRecordUnchanged;
    operation.configuration.timeoutIntervalForRequest=10; operation.configuration.timeoutIntervalForResource=25;
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    __block CKRecord *saved=nil; __block NSError *failure=nil;
    operation.perRecordSaveBlock=^(CKRecordID *identifier,CKRecord *result,NSError *e){(void)identifier;saved=result;failure=e;};
    operation.modifyRecordsCompletionBlock=^(NSArray *records,NSArray *deleted,NSError *e){
        (void)records;(void)deleted;if(!failure)failure=e;
        [NSFileManager.defaultManager removeItemAtPath:file error:nil]; dispatch_semaphore_signal(done);
    };
    [self trackOperation:operation]; [self.database addOperation:operation];
    BOOL timedOut=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC)) != 0;
    [self trackOperation:nil];
    if (timedOut) { [operation cancel]; if(error)*error=cloudError(@"iCloud upload timed out; the completed save will retry."); return NO; }
    if (failure || !saved) { if(error)*error=failure ?: cloudError(@"iCloud did not confirm the upload."); return NO; }
    self.state[@"uploads"]=@([self.state[@"uploads"] unsignedIntegerValue]+1);
    [self acknowledge:save]; return YES;
}
- (BOOL)preserve:(NSDictionary *)save error:(NSError **)error {
    if(!save)return YES;
    NSString *dir=[self.directory stringByAppendingPathComponent:@"Conflicts"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSString *path=[dir stringByAppendingPathComponent:[save[@"digest"] stringByAppendingPathExtension:@"plist"]];
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
        NSDictionary *existing=DmDecodeSave([NSData dataWithContentsOfFile:path],error);
        return existing && [existing[@"digest"] isEqual:save[@"digest"]];
    }
    NSData *data=DmEncodeSave(save,error); return data && [data writeToFile:path options:NSDataWritingAtomic error:error];
}
- (NSString *)sync:(NSDictionary *)local boot:(BOOL)boot error:(NSError **)error {
    [self.snapshotLock lock];BOOL paused=self.pausedForBackground;[self.snapshotLock unlock];
    if (paused) { if(error)*error=cloudError(@"Background allowance expired; the completed save will sync on return.");return @"error"; }
    if (![self checkAccount:error]) return @"error";
    CKRecord *head=[self fetchRecordWithAsset:NO error:error]; if(error && *error)return @"error";
    NSString *remoteDigest=head[@"digest"];
    if (head && ![remoteDigest isKindOfClass:NSString.class]) {if(error)*error=cloudError(@"Invalid iCloud save metadata.");return @"error";}
    NSString *decision=DmSaveDecision(local[@"digest"],self.state[@"baseDigest"],remoteDigest);
    if ([decision isEqual:@"equal"]) { [self acknowledge:local]; return @"done"; }
    if ([decision isEqual:@"empty"]) { [self setStatus:@"ready" detail:@"The first completed save will sync automatically." remote:nil]; return @"done"; }
    if ([decision isEqual:@"upload"]) return [self upload:local replacing:head error:error] ? @"done" : @"error";
    if (!head && [decision isEqual:@"conflict"]) {
        if (![self preserve:local error:error]) return @"error";
        [self setStatus:@"missing-cloud" detail:@"The previous iCloud copy is missing. The local save is backed up; choose whether to restore it to iCloud on next launch." remote:nil];
        return @"missing-cloud";
    }
    head=[self fetchRecordWithAsset:YES error:error]; if(error && *error)return @"error";
    NSDictionary *remote=[self readRecord:head error:error]; if(!remote)return @"error";
    if (![remote[@"digest"] isEqual:remoteDigest]) {if(error)*error=cloudError(@"The other device saved again; retrying with its latest save.");return @"error";}
    if ([decision isEqual:@"download"] && boot) {
        if (!DmRestoreSave(remote,self.profile,[self.directory stringByAppendingPathComponent:@"Backups"],error)) return @"error";
        [self publish:remote]; self.state[@"imports"]=@([self.state[@"imports"] unsignedIntegerValue]+1);
        [self acknowledge:remote]; return @"done";
    }
    if (![self preserve:local error:error] || ![self preserve:remote error:error]) return @"error";
    // A mounted game is never hot-replaced, even when only the cloud changed.
    [self setStatus:[decision isEqual:@"download"] ? @"restart-to-import" : @"conflict"
        detail:@"Both saves are preserved; check again before the next launch." remote:remoteDigest];
    return @"conflict";
}
- (void)finishBoot:(void (^)(void))completion {
    [self.snapshotLock lock]; self.started=YES; [self.snapshotLock unlock];
    if (!self.timer) {
        __weak DmCloudSave *weakSelf=self;
        self.timer=[NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer){(void)timer;[weakSelf checkForChanges];}];
    }
    completion();
}
- (void)prepareForController:(UIViewController *)controller completion:(void (^)(void))completion {
    if (![self.class enabled]) {completion();return;}
    self.controller=controller;
    UILabel *loading=[UILabel new]; loading.text=@"Loading save…";
    loading.font=[UIFont systemFontOfSize:15]; loading.textColor=UIColor.whiteColor; loading.textAlignment=NSTextAlignmentCenter;
    loading.frame=controller.view.bounds; loading.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [controller.view addSubview:loading];
    dispatch_async(self.queue,^{@autoreleasepool {
        NSError *localError=nil; NSDictionary *local=DmReadSave(self.profile,&localError); [self publish:local];
        NSError *error=localError;
        NSString *result=error ? @"error" : [self sync:local boot:YES error:&error];
        if(error)[self pending:error];
        dispatch_async(dispatch_get_main_queue(),^{
            [loading removeFromSuperview];
            if (error && !local) {
                // A fresh phone must not silently create new progress when an
                // existing iPad save could not be checked. Cached saves work offline.
                UIAlertController *alert=[UIAlertController alertControllerWithTitle:localError ? @"Local save could not be read" : @"iCloud save is not available yet"
                    message:localError ? @"Your save files are preserved. Retry before starting the game." : @"Retry to load your progress from the other device, or explicitly start without iCloud. The cloud copy will be preserved."
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"Retry" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;[self prepareForController:controller completion:completion];}]];
                if (!localError) [alert addAction:[UIAlertAction actionWithTitle:@"Start without iCloud" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){(void)action;[self finishBoot:completion];}]];
                [controller presentViewController:alert animated:YES completion:nil]; return;
            }
            BOOL missing=[result isEqual:@"missing-cloud"];
            if (![result isEqual:@"conflict"] && !missing) { [self finishBoot:completion]; return; }
            UIAlertController *alert=[UIAlertController alertControllerWithTitle:missing ? @"iCloud copy is missing" : @"Choose game progress"
                message:missing ? @"Your local save is backed up. Restore this progress to iCloud, or continue offline?" : @"Both devices have progress that has not synced together. Both saves are backed up. Which should this game continue?" preferredStyle:UIAlertControllerStyleAlert];
            if (!missing) [alert addAction:[UIAlertAction actionWithTitle:@"Use iCloud save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;[self resolveCloud:YES completion:completion];}]];
            [alert addAction:[UIAlertAction actionWithTitle:missing ? @"Restore this save to iCloud" : @"Keep this device’s save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;[self resolveCloud:NO completion:completion];}]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Play offline" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){(void)action;[self finishBoot:completion];}]];
            [controller presentViewController:alert animated:YES completion:nil];
        });
    }});
}
- (void)resolveCloud:(BOOL)useCloud completion:(void (^)(void))completion {
    dispatch_async(self.queue,^{@autoreleasepool {
        NSError *error=nil; BOOL account=[self checkAccount:&error];
        CKRecord *head=account ? [self fetchRecordWithAsset:YES error:&error] : nil;
        NSDictionary *remote=head ? [self readRecord:head error:&error] : nil, *local=[self snapshot];
        BOOL ok=NO;
        if (!error && !head && !useCloud && local && [self preserve:local error:&error]) {
            // A missing cloud copy is recreated only after the player's choice;
            // create-if-absent CAS still protects a concurrent other-device save.
            ok=[self upload:local replacing:nil error:&error];
        } else if (!error && remote && [self preserve:local error:&error] && [self preserve:remote error:&error]) {
            if (useCloud) {
                ok=DmRestoreSave(remote,self.profile,[self.directory stringByAppendingPathComponent:@"Backups"],&error);
                if (ok) { [self publish:remote];self.state[@"imports"]=@([self.state[@"imports"] unsignedIntegerValue]+1);[self acknowledge:remote]; }
            } else if (local) { ok=[self upload:local replacing:head error:&error]; }
        }
        if(!ok)[self pending:error ?: cloudError(@"Could not resolve the save; both copies are preserved.")];
        dispatch_async(dispatch_get_main_queue(),^{
            if(ok){[self finishBoot:completion];return;}
            UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Save transfer is pending"
                message:@"Your local progress is preserved. Retry the transfer or continue locally." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Retry" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;[self resolveCloud:useCloud completion:completion];}]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Play offline" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){(void)action;[self finishBoot:completion];}]];
            [self.controller presentViewController:alert animated:YES completion:nil];
        });
    }});
}
- (void)endBackgroundTask {
    dispatch_async(dispatch_get_main_queue(),^{
        // A new commit can enqueue another worker before this main-queue turn.
        [self.snapshotLock lock]; BOOL busy=self.syncScheduled; [self.snapshotLock unlock];
        if (!busy && self.backgroundTask!=UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:self.backgroundTask]; self.backgroundTask=UIBackgroundTaskInvalid;
        }
    });
}
- (void)checkForChanges {
    if (![self.class enabled]) return;
    // Lease acquisition, scheduling and lease completion share the main queue.
    // The commit hook never waits on it while holding the game's save locks.
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{[self checkForChanges];}); return; }
    BOOL background=UIApplication.sharedApplication.applicationState==UIApplicationStateBackground;
    if (!background) {
        self.backgroundExpired=NO;
        [self.snapshotLock lock];self.pausedForBackground=NO;[self.snapshotLock unlock];
    }
    [self.snapshotLock lock]; BOOL started=self.started; [self.snapshotLock unlock];
    if (!started) return;
    if (background) [self ensureBackgroundTask];
    [self.snapshotLock lock];
    if (!self.started || self.syncScheduled) {[self.snapshotLock unlock];return;}
    self.syncScheduled=YES; [self.snapshotLock unlock];
    dispatch_async(self.queue,^{@autoreleasepool {
        for (;;) {
            NSDictionary *snapshot=[self snapshot]; NSError *error=nil;
            NSString *result=[self sync:snapshot boot:NO error:&error]; if(error)[self pending:error];
            [self.snapshotLock lock];
            BOOL newer=!sameDigest(self.latest[@"digest"],snapshot[@"digest"]);
            if (!newer || ![result isEqual:@"done"]) self.syncScheduled=NO;
            [self.snapshotLock unlock];
            if (!newer || ![result isEqual:@"done"]) break;
            // Drain commits made during an upload before ending the background task.
        }
        [self endBackgroundTask];
    }});
}
- (void)ensureBackgroundTask {
    if (self.backgroundTask==UIBackgroundTaskInvalid && !self.backgroundExpired) {
        self.backgroundTask=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"Sync completed game save" expirationHandler:^{
            self.backgroundExpired=YES;
            [self.snapshotLock lock];self.pausedForBackground=YES;CKOperation *operation=self.operation;[self.snapshotLock unlock];[operation cancel];
            if(self.backgroundTask!=UIBackgroundTaskInvalid){[UIApplication.sharedApplication endBackgroundTask:self.backgroundTask];self.backgroundTask=UIBackgroundTaskInvalid;}
        }];
    }
}
- (void)flushForBackground {
    if (![self.class enabled]) return;
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{[self flushForBackground];}); return; }
    [self.snapshotLock lock]; BOOL started=self.started; [self.snapshotLock unlock]; if(!started)return;
    [self ensureBackgroundTask]; [self checkForChanges];
}
- (void)committed:(NSDictionary *)save {
    NSError *error=nil; NSData *encoded=DmEncodeSave(save,&error);
    if (![encoded writeToFile:[self.directory stringByAppendingPathComponent:@"last-committed.plist"] options:NSDataWritingAtomic error:&error])
        fprintf(stderr,"[RED] cloud-save: snapshot journal failed; game save retained: %s\n",error.localizedDescription.UTF8String ?: "encoding failed");
    [self publish:save]; [self checkForChanges];
}
@end

void dm_front_save_committed(const char *directory) {
    if(!directory || ![DmCloudSave enabled])return;
    @autoreleasepool {
        DmCloudSave *cloud=DmCloudSave.shared;
        if (![@(directory).stringByStandardizingPath isEqual:cloud.profile])return;
        NSError *error=nil; NSDictionary *save=DmReadSave(cloud.profile,&error);
        if(save)[cloud committed:save];
        else if(error)fprintf(stderr,"[RED] cloud-save: could not capture completed save: %s\n",error.localizedDescription.UTF8String);
    }
}
