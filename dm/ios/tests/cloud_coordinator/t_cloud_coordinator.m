// Exercise the actual coordinator, including its CKOperation construction,
// serial worker, preboot restore and native background-task lifetime. Only UI,
// account lookup and database delivery are replaced; archives/files are real.
#import <Foundation/Foundation.h>
#import <CloudKit/CloudKit.h>
#import <UIKit/UIKit.h>
#import <unistd.h>
static NSString *testDocuments;
static NSArray<NSString *> *TestSearchPaths(NSSearchPathDirectory directory,NSSearchPathDomainMask domains,BOOL expand) {
    (void)directory;(void)domains;(void)expand;return @[testDocuments];
}
#define NSSearchPathForDirectoriesInDomains TestSearchPaths
#import "../../Sources/DmCloudSave.m"
#undef NSSearchPathForDirectoriesInDomains

static NSUInteger checks, scenarios;
static void Check(BOOL condition,NSString *message) {
    ++checks;if(!condition){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static void OnMain(void (^block)(void)) { if(NSThread.isMainThread)block();else dispatch_sync(dispatch_get_main_queue(),block); }
static void Wait(dispatch_semaphore_t sem,NSString *description) {
    Check(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,description);
}
static void Put(NSString *root,NSString *name,NSString *content) {
    NSString *path=[root stringByAppendingPathComponent:name];
    Check([NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL],@"fixture directory");
    Check([[content dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES],@"fixture data");
}
static NSDictionary *Save(NSString *root,NSString *label) {
    Put(root,@"Common.bin",[@"common-" stringByAppendingString:label]);Put(root,@"File1.bin",[@"progress-" stringByAppendingString:label]);
    NSError *error=nil;NSDictionary *save=DmReadSave(root,&error);Check(save!=nil&&!error,@"fixture accepted by actual codec");return save;
}
static BOOL Same(NSString *path,NSDictionary *save) { return [DmReadSave(path,NULL)[@"digest"] isEqual:save[@"digest"]]; }

@interface FakeDatabase : NSObject
@property(strong) dispatch_queue_t queue;
@property(strong) NSMapTable *recordVersions;
@property(copy) NSString *directory;
@property(strong) NSDictionary *head;
@property NSUInteger generation;
@property NSUInteger fetches;
@property NSUInteger modifications;
@property NSUInteger attemptedModifications;
@property NSUInteger cancelledModifications;
@property NSUInteger cancelledFetches;
@property BOOL offline;
@property(copy) void (^beforeModify)(CKModifyRecordsOperation *);
@property(copy) void (^beforeAssetFetch)(void);
@property(strong) NSMutableArray<NSString *> *uploadedDigests;
- (void)setServerSave:(NSDictionary *)save;
- (NSDictionary *)serverSave;
- (void)addOperation:(CKDatabaseOperation *)operation;
@end
@implementation FakeDatabase
- (instancetype)init {
    if((self=[super init])) {
        _queue=dispatch_queue_create("dm.test-cloud-transport",DISPATCH_QUEUE_SERIAL);
        _recordVersions=[NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory|NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory];
        _uploadedDigests=[NSMutableArray new];
    }return self;
}
- (void)setServerSave:(NSDictionary *)save { @synchronized(self){self.head=save;++self.generation;} }
- (NSDictionary *)serverSave { @synchronized(self){return self.head;} }
- (CKRecord *)recordForID:(CKRecordID *)identifier asset:(BOOL)asset {
    @synchronized(self) {
        if(!self.head)return nil;
        CKRecord *record=[[CKRecord alloc] initWithRecordType:@"GameSave" recordID:identifier];
        record[@"digest"]=self.head[@"digest"];record[@"device"]=@"Other fixture device";record[@"updated"]=NSDate.date;
        [self.recordVersions setObject:@(self.generation) forKey:record];
        if(asset) {
            NSString *path=[self.directory stringByAppendingPathComponent:[NSString stringWithFormat:@"server-%@.plist",NSUUID.UUID.UUIDString]];
            Check([DmEncodeSave(self.head,NULL) writeToFile:path atomically:YES],@"real server archive fixture");
            record[@"payload"]=[[CKAsset alloc] initWithFileURL:[NSURL fileURLWithPath:path]];
        }return record;
    }
}
- (void)addOperation:(CKDatabaseOperation *)operation {
    dispatch_async(self.queue,^{@autoreleasepool {
        NSError *failure=self.offline?[NSError errorWithDomain:CKErrorDomain code:CKErrorNetworkUnavailable userInfo:nil]:nil;
        if([operation isKindOfClass:CKFetchRecordsOperation.class]) {
            CKFetchRecordsOperation *fetch=(id)operation;++self.fetches;
            if(fetch.isCancelled){++self.cancelledFetches;failure=[NSError errorWithDomain:CKErrorDomain code:CKErrorOperationCancelled userInfo:nil];}
            BOOL asset=!fetch.desiredKeys;
            if(asset&&self.beforeAssetFetch)self.beforeAssetFetch();
            CKRecordID *identifier=fetch.recordIDs.firstObject;
            CKRecord *record=failure?nil:[self recordForID:identifier asset:asset];
            if(!failure&&!record)failure=[NSError errorWithDomain:CKErrorDomain code:CKErrorUnknownItem userInfo:nil];
            if(fetch.perRecordCompletionBlock)fetch.perRecordCompletionBlock(record,identifier,failure);
            if(fetch.fetchRecordsCompletionBlock)fetch.fetchRecordsCompletionBlock(record?@{identifier:record}:@{},failure);
        }else if([operation isKindOfClass:CKModifyRecordsOperation.class]) {
            CKModifyRecordsOperation *modify=(id)operation;++self.attemptedModifications;
            Check(modify.savePolicy==CKRecordSaveIfServerRecordUnchanged,@"actual upload uses CloudKit compare-and-swap policy");
            Check(modify.recordsToSave.count==1,@"actual upload sends one complete head");
            if(self.beforeModify)self.beforeModify(modify);
            CKRecord *record=modify.recordsToSave.firstObject;
            @synchronized(self) {
                NSNumber *version=[self.recordVersions objectForKey:record];
                NSUInteger expected=version?version.unsignedIntegerValue:0;
                NSUInteger actual=self.head?self.generation:0;
                if(modify.isCancelled){++self.cancelledModifications;failure=[NSError errorWithDomain:CKErrorDomain code:CKErrorOperationCancelled userInfo:nil];}
                if(!failure&&expected!=actual)failure=[NSError errorWithDomain:CKErrorDomain code:CKErrorServerRecordChanged userInfo:nil];
                if(!failure) {
                    CKAsset *asset=record[@"payload"];
                    NSDictionary *save=DmDecodeSave([NSData dataWithContentsOfURL:asset.fileURL],&failure);
                    Check(save!=nil&&!failure,@"actual coordinator's upload archive decodes and verifies");
                    self.head=save;++self.generation;++self.modifications;[self.uploadedDigests addObject:save[@"digest"]];
                }
            }
            if(modify.perRecordSaveBlock)modify.perRecordSaveBlock(record.recordID,failure?nil:record,failure);
            if(modify.modifyRecordsCompletionBlock)modify.modifyRecordsCompletionBlock(failure?@[]:@[record],@[],failure);
        }else Check(NO,@"unexpected transport operation");
    }});
}
@end

static _Thread_local BOOL initializingCoordinator;
@interface FakeContainer : NSObject
@property(copy) NSString *user;
@property(strong) NSError *failure;
@property(copy) void (^beforeLookup)(void);
- (void)fetchUserRecordIDWithCompletionHandler:(void (^)(CKRecordID *,NSError *))completion;
@end
@implementation FakeContainer
- (void)fetchUserRecordIDWithCompletionHandler:(void (^)(CKRecordID *,NSError *))completion {
    if(self.beforeLookup)self.beforeLookup();
    completion(self.failure?nil:[[CKRecordID alloc] initWithRecordName:self.user],self.failure);
}
@end
@interface TestCoordinator : DmCloudSave
@end
@implementation TestCoordinator
+ (BOOL)enabled { return !initializingCoordinator; }
- (instancetype)init {
    initializingCoordinator=YES;self=[super init];initializingCoordinator=NO;return self;
}
@end

static TestCoordinator *Coordinator(NSString *root,FakeDatabase **database) {
    OnMain(^{UIApplication.sharedApplication.applicationState=UIApplicationStateActive;});
    testDocuments=root;[NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];unsetenv("DM_SAVE");
    TestCoordinator *c=[TestCoordinator new];FakeDatabase *db=[FakeDatabase new];db.directory=c.directory;c.database=(id)db;
    FakeContainer *container=[FakeContainer new];container.user=@"fixture-private-user";c.container=(id)container;*database=db;return c;
}
static void Drain(TestCoordinator *c) {
    // Non-main callers may schedule coordinator work through the main queue.
    OnMain(^{});dispatch_sync(c.queue,^{});OnMain(^{});
    Check(!c.syncScheduled,@"coordinator worker drained");
}
static NSString *Status(TestCoordinator *c) {
    NSData *data=[NSData dataWithContentsOfFile:[c.directory stringByAppendingPathComponent:@"status.json"]];
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL][@"status"];
}
static void Stop(TestCoordinator *c) { OnMain(^{[c.timer invalidate];c.timer=nil;}); }
static void Begin(NSString *name) { ++scenarios;printf("scenario: %s\n",name.UTF8String); }
static void BlockFile(NSString *path) {
    if([NSFileManager.defaultManager fileExistsAtPath:path])
        Check([NSFileManager.defaultManager removeItemAtPath:path error:NULL],@"remove fixture target before write fault");
    Check([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:NULL],@"directory at file target forces a real Foundation write failure");
}
static void RepairFile(NSString *path) {
    Check([NSFileManager.defaultManager removeItemAtPath:path error:NULL],@"remove write-fault directory");
}

static void Run(void) { @autoreleasepool {
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"dm-coordinator-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSDictionary *a=Save([root stringByAppendingPathComponent:@"fixtures/a"],@"A");
    NSDictionary *b=Save([root stringByAppendingPathComponent:@"fixtures/b"],@"B");
    NSDictionary *cSave=Save([root stringByAppendingPathComponent:@"fixtures/c"],@"C");
    FakeDatabase *db;TestCoordinator *c;

    Begin(@"first upload executes real CKModifyRecordsOperation and acknowledges only confirmed content");
    c=Coordinator([root stringByAppendingPathComponent:@"first"],&db);
    Check(DmRestoreSave(a,c.profile,[c.directory stringByAppendingPathComponent:@"Backups"],NULL),@"first device save fixture");
    [c publish:a];c.started=YES;[c checkForChanges];Drain(c);
    Check([db.serverSave[@"digest"] isEqual:a[@"digest"]],@"first complete save becomes private cloud head");
    Check([c.state[@"baseDigest"] isEqual:a[@"digest"]]&&[c.state[@"uploads"] integerValue]==1,@"confirmed upload advances persistent base");
    Check([Status(c) isEqual:@"synced"]&&Same(c.profile,a),@"upload retains local progress and records success");Stop(c);

    Begin(@"fresh phone preboot imports before completion and creates no competing blank upload");
    c=Coordinator([root stringByAppendingPathComponent:@"fresh-phone"],&db);[db setServerSave:b];
    dispatch_semaphore_t booted=dispatch_semaphore_create(0);__block BOOL correctAtCompletion=NO;
    OnMain(^{[c prepareForController:[UIViewController new] completion:^{correctAtCompletion=Same(c.profile,b);dispatch_semaphore_signal(booted);}];});
    Wait(booted,@"preboot completion");Drain(c);
    Check(correctAtCompletion&&c.started,@"guest begins only after real archive restore");
    Check([c.state[@"imports"] integerValue]==1&&db.modifications==0,@"fresh device downloads without upload");
    Check([c.state[@"baseDigest"] isEqual:b[@"digest"]]&&Same(c.profile,b),@"imported complete tree acknowledged");Stop(c);

    Begin(@"fresh offline boot requires an explicit choice while cached progress starts offline");
    c=Coordinator([root stringByAppendingPathComponent:@"fresh-offline"],&db);db.offline=YES;
    UIViewController *screen=[UIViewController new];dispatch_semaphore_t offlineBooted=dispatch_semaphore_create(0);
    OnMain(^{[c prepareForController:screen completion:^{dispatch_semaphore_signal(offlineBooted);}];});Drain(c);
    __block UIAlertController *alert;
    OnMain(^{alert=(id)screen.presentedViewController;Check(alert.actions.count==2&&!c.started,@"fresh offline phone waits at Retry or explicit offline choice");});
    Check(dispatch_semaphore_wait(offlineBooted,DISPATCH_TIME_NOW)!=0,@"fresh offline game cannot mount before a decision");
    OnMain(^{UIAlertAction *action=alert.actions.lastObject;Check([action.title isEqual:@"Start without iCloud"],@"offline start is explicit");action.handler(action);});
    Wait(offlineBooted,@"explicit offline boot completion");Check(c.started&&!DmReadSave(c.profile,NULL),@"explicit offline choice does not invent progress");Stop(c);
    c=Coordinator([root stringByAppendingPathComponent:@"cached-offline"],&db);db.offline=YES;
    Check(DmRestoreSave(a,c.profile,[c.directory stringByAppendingPathComponent:@"Backups"],NULL),@"cached offline tree");
    UIViewController *cachedScreen=[UIViewController new];dispatch_semaphore_t cachedBooted=dispatch_semaphore_create(0);
    OnMain(^{[c prepareForController:cachedScreen completion:^{dispatch_semaphore_signal(cachedBooted);}];});
    Wait(cachedBooted,@"valid cached game plays offline");Drain(c);
    OnMain(^{Check(!cachedScreen.presentedViewController&&c.started&&Same(c.profile,a),@"cached offline path preserves progress without a blocking prompt");});Stop(c);

    Begin(@"unreadable local tree offers retry without mounting or importing over it");
    c=Coordinator([root stringByAppendingPathComponent:@"unreadable"],&db);[db setServerSave:b];
    Put(c.profile,@"File1.bin",@"existing-progress");NSString *outside=[root stringByAppendingPathComponent:@"outside.bin"];Put(root,@"outside.bin",@"outside");
    Check([NSFileManager.defaultManager createSymbolicLinkAtPath:[c.profile stringByAppendingPathComponent:@"Common.bin"] withDestinationPath:outside error:NULL],@"unsafe tree fixture");
    UIViewController *brokenScreen=[UIViewController new];dispatch_semaphore_t brokenBooted=dispatch_semaphore_create(0);
    OnMain(^{[c prepareForController:brokenScreen completion:^{dispatch_semaphore_signal(brokenBooted);}];});Drain(c);
    OnMain(^{UIAlertController *a=(id)brokenScreen.presentedViewController;Check(a.actions.count==1&&[a.actions[0].title isEqual:@"Retry"]&&!c.started,@"read error offers only retry");});
    Check(dispatch_semaphore_wait(brokenBooted,DISPATCH_TIME_NOW)!=0&&db.fetches==0,@"unreadable local files never mount or reach remote replacement");Stop(c);

    Begin(@"network and account errors keep completed local save and base intact");
    c=Coordinator([root stringByAppendingPathComponent:@"offline"],&db);[db setServerSave:a];db.offline=YES;
    Check(DmRestoreSave(b,c.profile,[c.directory stringByAppendingPathComponent:@"Backups"],NULL),@"offline local tree");
    c.state[@"baseDigest"]=a[@"digest"];[c publish:b];c.started=YES;[c checkForChanges];Drain(c);
    Check([Status(c) isEqual:@"pending"]&&Same(c.profile,b)&&[c.state[@"baseDigest"] isEqual:a[@"digest"]],@"fetch error neither imports nor acknowledges");
    Check(db.attemptedModifications==0&&[db.serverSave[@"digest"] isEqual:a[@"digest"]],@"offline transport does not overwrite cloud");
    ((FakeContainer *)(id)c.container).failure=cloudError(@"Fixture offline account");db.offline=NO;NSUInteger fetches=db.fetches;[c checkForChanges];Drain(c);
    Check(db.fetches==fetches&&Same(c.profile,b)&&[Status(c) isEqual:@"pending"],@"account error returns safely before cloud operations");Stop(c);

    Begin(@"iCloud account change pauses the real account-check path");
    c=Coordinator([root stringByAppendingPathComponent:@"account-change"],&db);[db setServerSave:a];
    c.state[@"cloudUser"]=@"previous-private-user";c.state[@"baseDigest"]=a[@"digest"];[c publish:b];c.started=YES;
    [c checkForChanges];Drain(c);
    Check(db.fetches==0&&db.attemptedModifications==0&&[c.state[@"cloudUser"] isEqual:@"previous-private-user"],@"another account cannot inherit or overwrite sync ancestry");
    Check([Status(c) isEqual:@"pending"]&&[db.serverSave[@"digest"] isEqual:a[@"digest"]],@"account mismatch preserves the remote head");Stop(c);

    Begin(@"divergent local and remote branches are both recoverable");
    c=Coordinator([root stringByAppendingPathComponent:@"divergent"],&db);[db setServerSave:cSave];
    Check(DmRestoreSave(b,c.profile,[c.directory stringByAppendingPathComponent:@"Backups"],NULL),@"divergent local tree");
    c.state[@"baseDigest"]=a[@"digest"];[c publish:b];c.started=YES;[c checkForChanges];Drain(c);
    Check([Status(c) isEqual:@"conflict"]&&Same(c.profile,b)&&db.modifications==0,@"divergent saves never silently select a winner");
    for(NSDictionary *save in @[b,cSave]) {
        NSString *file=[[c.directory stringByAppendingPathComponent:@"Conflicts"] stringByAppendingPathComponent:[save[@"digest"] stringByAppendingPathExtension:@"plist"]];
        Check([DmDecodeSave([NSData dataWithContentsOfFile:file],NULL)[@"digest"] isEqual:save[@"digest"]],@"both conflict archives remain fully verified");
    }Stop(c);

    Begin(@"preboot divergence waits for choice and imports only the selected verified cloud save");
    c=Coordinator([root stringByAppendingPathComponent:@"boot-conflict"],&db);[db setServerSave:cSave];
    Check(DmRestoreSave(b,c.profile,[c.directory stringByAppendingPathComponent:@"Backups"],NULL),@"boot conflict local tree");
    c.state[@"baseDigest"]=a[@"digest"];UIViewController *conflictScreen=[UIViewController new];dispatch_semaphore_t resolved=dispatch_semaphore_create(0);
    OnMain(^{[c prepareForController:conflictScreen completion:^{dispatch_semaphore_signal(resolved);}];});Drain(c);
    Check(!c.started&&dispatch_semaphore_wait(resolved,DISPATCH_TIME_NOW)!=0&&Same(c.profile,b),@"conflict prevents guest mount until choice");
    OnMain(^{UIAlertController *a=(id)conflictScreen.presentedViewController;Check(a.actions.count==3,@"both conflict branches and offline option are available");UIAlertAction *choice=a.actions.firstObject;Check([choice.title isEqual:@"Use iCloud save"],@"explicit cloud branch choice");choice.handler(choice);});
    Wait(resolved,@"resolved cloud branch boot completion");Drain(c);
    Check(c.started&&Same(c.profile,cSave)&&[c.state[@"imports"] integerValue]==1&&db.modifications==0,@"chosen cloud branch restored before boot and acknowledged");
    NSArray *backups=[NSFileManager.defaultManager contentsOfDirectoryAtPath:[c.directory stringByAppendingPathComponent:@"Backups"] error:NULL];
    Check(backups.count==1&&Same([[c.directory stringByAppendingPathComponent:@"Backups"] stringByAppendingPathComponent:backups.firstObject],b),@"replaced local branch remains in a recoverable real directory backup");Stop(c);

    Begin(@"missing previously synced cloud head requires explicit local-to-cloud repair");
    c=Coordinator([root stringByAppendingPathComponent:@"deleted-cloud"],&db);
    Check(DmRestoreSave(a,c.profile,[c.directory stringByAppendingPathComponent:@"Backups"],NULL),@"deleted-cloud local tree");
    c.state[@"baseDigest"]=a[@"digest"];UIViewController *deletedScreen=[UIViewController new];dispatch_semaphore_t repaired=dispatch_semaphore_create(0);
    OnMain(^{[c prepareForController:deletedScreen completion:^{dispatch_semaphore_signal(repaired);}];});Drain(c);
    Check(!c.started&&db.modifications==0&&Same(c.profile,a),@"missing known cloud record is never silently recreated or imported");
    Check(dispatch_semaphore_wait(repaired,DISPATCH_TIME_NOW)!=0,@"missing cloud head waits for an explicit repair or offline choice");
    OnMain(^{
        UIAlertController *a=(id)deletedScreen.presentedViewController;Check(a.actions.count==2,@"only local repair and offline choices exist");
        UIAlertAction *choice=a.actions.firstObject;Check([choice.title isEqual:@"Restore this save to iCloud"],@"unavailable cloud branch cannot be selected");choice.handler(choice);
    });
    Wait(repaired,@"explicit new-record repair boot completion");Drain(c);
    Check(c.started&&Same(c.profile,a)&&[db.serverSave[@"digest"] isEqual:a[@"digest"]]&&db.modifications==1,@"explicit repair creates missing cloud head by actual new-record CAS");
    NSString *preserved=[[c.directory stringByAppendingPathComponent:@"Conflicts"] stringByAppendingPathComponent:[a[@"digest"] stringByAppendingPathExtension:@"plist"]];
    Check([DmDecodeSave([NSData dataWithContentsOfFile:preserved],NULL)[@"digest"] isEqual:a[@"digest"]],@"repair retains verified local archive");Stop(c);

    Begin(@"head changes between fetch and CAS upload cannot overwrite another device");
    c=Coordinator([root stringByAppendingPathComponent:@"cas"],&db);[db setServerSave:a];
    Check(DmRestoreSave(b,c.profile,[c.directory stringByAppendingPathComponent:@"Backups"],NULL),@"CAS local tree");
    c.state[@"baseDigest"]=a[@"digest"];[c publish:b];c.started=YES;
    __weak FakeDatabase *weakDB=db;db.beforeModify=^(CKModifyRecordsOperation *op){(void)op;[weakDB setServerSave:cSave];};
    [c checkForChanges];Drain(c);
    Check([db.serverSave[@"digest"] isEqual:cSave[@"digest"]]&&db.modifications==0,@"server CAS rejection preserves the new remote head");
    Check([c.state[@"baseDigest"] isEqual:a[@"digest"]]&&Same(c.profile,b)&&[Status(c) isEqual:@"pending"],@"rejected CAS is not acknowledged; local branch remains");
    db.beforeModify=nil;[c checkForChanges];Drain(c);Check([Status(c) isEqual:@"conflict"],@"next check detects divergence after a rejected CAS");Stop(c);

    Begin(@"remote head changing between metadata and asset fetch does not import mismatched data");
    c=Coordinator([root stringByAppendingPathComponent:@"download-race"],&db);[db setServerSave:a];
    __weak FakeDatabase *raceDB=db;db.beforeAssetFetch=^{[raceDB setServerSave:b];};
    NSError *error=nil;NSString *result=[c sync:nil boot:YES error:&error];
    Check([result isEqual:@"error"]&&error!=nil&&!DmReadSave(c.profile,NULL),@"inconsistent two-phase cloud head is rejected before restore");Stop(c);

    Begin(@"save during upload drains newest commit before ending background allowance");
    c=Coordinator([root stringByAppendingPathComponent:@"coalesce"],&db);[c publish:a];c.started=YES;
    __block NSUInteger calls=0;__block BOOL taskAliveForSecond=NO;__weak TestCoordinator *weakC=c;
    db.beforeModify=^(CKModifyRecordsOperation *op){
        (void)op;++calls;
        if(calls==1)[weakC committed:b];
        if(calls==2)OnMain(^{taskAliveForSecond=UIApplication.sharedApplication.activeTasks.count==1;});
    };
    __block NSUInteger endedBefore;OnMain(^{UIApplication.sharedApplication.applicationState=UIApplicationStateBackground;endedBefore=UIApplication.sharedApplication.endedTasks;[c flushForBackground];});Drain(c);
    Check(calls==2&&[db.uploadedDigests isEqual:@[a[@"digest"],b[@"digest"]]],@"same worker uploads initial and newer committed save");
    Check(taskAliveForSecond&&[c.state[@"baseDigest"] isEqual:b[@"digest"]],@"background lease remains active until latest save confirmed");
    OnMain(^{Check(UIApplication.sharedApplication.activeTasks.count==0&&UIApplication.sharedApplication.endedTasks==endedBefore+1,@"background task ends exactly once after queue drains");});
    NSDictionary *journal=DmDecodeSave([NSData dataWithContentsOfFile:[c.directory stringByAppendingPathComponent:@"last-committed.plist"]],NULL);
    Check([journal[@"digest"] isEqual:b[@"digest"]],@"latest commit has recoverable real archive journal");Stop(c);

    Begin(@"expiration cancels in-flight CloudKit without acknowledging or deleting local progress");
    c=Coordinator([root stringByAppendingPathComponent:@"expiration"],&db);[c publish:a];c.started=YES;
    Check(DmRestoreSave(a,c.profile,[c.directory stringByAppendingPathComponent:@"Backups"],NULL),@"expiration local progress fixture");
    dispatch_semaphore_t modifying=dispatch_semaphore_create(0),resume=dispatch_semaphore_create(0);
    db.beforeModify=^(CKModifyRecordsOperation *op){(void)op;dispatch_semaphore_signal(modifying);Wait(resume,@"release expired transport");};
    OnMain(^{UIApplication.sharedApplication.applicationState=UIApplicationStateBackground;[c flushForBackground];});Wait(modifying,@"upload reached expiration barrier");
    OnMain(^{UIApplication.sharedApplication.expirationHandler();Check(UIApplication.sharedApplication.activeTasks.count==0,@"expiration ends UIKit allowance immediately");});
    dispatch_semaphore_signal(resume);Drain(c);
    Check(db.cancelledModifications==1&&db.modifications==0&&!c.state[@"baseDigest"],@"cancelled native CKOperation is not acknowledged");
    Check(Same(c.profile,a)&&[Status(c) isEqual:@"pending"]&&!db.serverSave,@"expiration retains exact local tree for retry");Stop(c);

    Begin(@"expiration during account lookup cancels later operations and waits for foreground retry");
    c=Coordinator([root stringByAppendingPathComponent:@"account-expiration"],&db);[c publish:a];c.started=YES;
    dispatch_semaphore_t lookingUp=dispatch_semaphore_create(0),allowLookup=dispatch_semaphore_create(0);
    ((FakeContainer *)(id)c.container).beforeLookup=^{dispatch_semaphore_signal(lookingUp);Wait(allowLookup,@"release expired account lookup");};
    __block NSUInteger leasesBefore;
    OnMain(^{UIApplication.sharedApplication.applicationState=UIApplicationStateBackground;[c flushForBackground];leasesBefore=UIApplication.sharedApplication.beganTasks;});
    Wait(lookingUp,@"account lookup reached expiration barrier");OnMain(^{UIApplication.sharedApplication.expirationHandler();});
    dispatch_semaphore_signal(allowLookup);Drain(c);
    Check(db.cancelledFetches==1&&db.attemptedModifications==0&&!c.state[@"baseDigest"],@"operation created after expiration is cancelled, not uploaded");
    ((FakeContainer *)(id)c.container).beforeLookup=nil;[c committed:b];Drain(c);
    OnMain(^{Check(UIApplication.sharedApplication.beganTasks==leasesBefore&&UIApplication.sharedApplication.activeTasks.count==0,@"background retry cannot reacquire allowance after expiration");});
    Check(db.fetches==1&&db.modifications==0,@"expired background worker performs no further cloud request");
    OnMain(^{UIApplication.sharedApplication.applicationState=UIApplicationStateActive;[c checkForChanges];});Drain(c);
    Check([db.serverSave[@"digest"] isEqual:b[@"digest"]]&&[c.state[@"baseDigest"] isEqual:b[@"digest"]],@"foreground retry uploads newest retained completed save");Stop(c);

    Begin(@"queued old background completion cannot end a newer active worker");
    c=Coordinator([root stringByAppendingPathComponent:@"background-end-race"],&db);[db setServerSave:a];[c publish:a];c.state[@"baseDigest"]=a[@"digest"];c.started=YES;
    dispatch_semaphore_t newUpload=dispatch_semaphore_create(0),allowNewUpload=dispatch_semaphore_create(0);
    db.beforeModify=^(CKModifyRecordsOperation *op){(void)op;dispatch_semaphore_signal(newUpload);Wait(allowNewUpload,@"release newer worker");};
    OnMain(^{
        UIApplication.sharedApplication.applicationState=UIApplicationStateBackground;
        c.backgroundTask=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"fixture existing allowance" expirationHandler:^{}];
        [c endBackgroundTask];[c committed:b];
    });
    Wait(newUpload,@"new worker reached barrier");
    OnMain(^{Check(UIApplication.sharedApplication.activeTasks.count==1,@"stale end block observes new worker and keeps allowance");});
    dispatch_semaphore_signal(allowNewUpload);Drain(c);
    OnMain(^{Check(UIApplication.sharedApplication.activeTasks.count==0,@"new worker ends allowance after confirmation");});
    Check([c.state[@"baseDigest"] isEqual:b[@"digest"]],@"new worker still confirms latest committed save");Stop(c);

    Begin(@"commit after busy check but before UIKit ends lease obtains a replacement allowance");
    c=Coordinator([root stringByAppendingPathComponent:@"narrow-background-race"],&db);[db setServerSave:a];[c publish:a];c.state[@"baseDigest"]=a[@"digest"];c.started=YES;
    dispatch_semaphore_t narrowUpload=dispatch_semaphore_create(0),allowNarrow=dispatch_semaphore_create(0),committed=dispatch_semaphore_create(0);
    db.beforeModify=^(CKModifyRecordsOperation *op){(void)op;dispatch_semaphore_signal(narrowUpload);Wait(allowNarrow,@"release narrow-race upload");};
    OnMain(^{
        UIApplication.sharedApplication.applicationState=UIApplicationStateBackground;
        c.backgroundTask=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"fixture ending allowance" expirationHandler:^{}];
        UIApplication.sharedApplication.beforeEnd=^{
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{[c committed:b];dispatch_semaphore_signal(committed);});
            Wait(committed,@"commit publishes between busy check and UIKit end");
        };
        [c endBackgroundTask];
    });
    Wait(narrowUpload,@"narrow-race worker reached barrier");
    OnMain(^{Check(UIApplication.sharedApplication.activeTasks.count==1,@"late background commit receives an active replacement lease");});
    dispatch_semaphore_signal(allowNarrow);Drain(c);
    Check([c.state[@"baseDigest"] isEqual:b[@"digest"]],@"late background commit is acknowledged");
    OnMain(^{Check(UIApplication.sharedApplication.activeTasks.count==0,@"replacement lease ends after newest commit");});Stop(c);

    Begin(@"mounted runtime save is never replaced by cloud progress");
    c=Coordinator([root stringByAppendingPathComponent:@"mounted"],&db);[db setServerSave:b];
    Check(DmRestoreSave(a,c.profile,[c.directory stringByAppendingPathComponent:@"Backups"],NULL),@"mounted local tree");
    c.state[@"baseDigest"]=a[@"digest"];[c publish:a];c.started=YES;[c checkForChanges];Drain(c);
    Check([Status(c) isEqual:@"restart-to-import"]&&Same(c.profile,a),@"cloud-ahead branch waits until next boot");
    Check([c.state[@"imports"] integerValue]==0&&[c.state[@"baseDigest"] isEqual:a[@"digest"]]&&db.modifications==0,@"runtime check neither imports nor advances base");Stop(c);

    Begin(@"failed account-state write blocks cloud mutation until local persistence recovers");
    c=Coordinator([root stringByAppendingPathComponent:@"state-pin-failure"],&db);
    Check(DmRestoreSave(a,c.profile,[c.directory stringByAppendingPathComponent:@"Backups"],NULL),@"state fault local progress");
    NSString *statePath=[c.directory stringByAppendingPathComponent:@"state.plist"];
    BlockFile(statePath);[c publish:a];c.started=YES;[c checkForChanges];Drain(c);
    Check(db.modifications==0&&db.fetches==0&&!c.state[@"cloudUser"]&&!c.state[@"baseDigest"],@"undurable account pin cannot fetch/mutate cloud or advance ancestry");
    Check([Status(c) isEqual:@"pending"]&&Same(c.profile,a),@"failed pin preserves local progress and stays pending");
    RepairFile(statePath);[c checkForChanges];Drain(c);
    Check(db.modifications==1&&[c.state[@"baseDigest"] isEqual:a[@"digest"]]&&[Status(c) isEqual:@"synced"],@"ordinary retry persists pin and confirms the same progress");Stop(c);

    Begin(@"confirmed upload with failed state write retries ancestry before a newer commit");
    c=Coordinator([root stringByAppendingPathComponent:@"state-ack-failure"],&db);
    Check(DmRestoreSave(a,c.profile,[c.directory stringByAppendingPathComponent:@"Backups"],NULL),@"ack fault local A");
    NSString *ackState=[c.directory stringByAppendingPathComponent:@"state.plist"];
    db.beforeModify=^(CKModifyRecordsOperation *op){(void)op;BlockFile(ackState);};
    [c publish:a];c.started=YES;[c checkForChanges];Drain(c);
    Check(db.modifications==1&&[db.serverSave[@"digest"] isEqual:a[@"digest"]],@"server really confirmed A before local state failed");
    Check(!c.state[@"baseDigest"]&&[c.state[@"uploads"] integerValue]==0&&[Status(c) isEqual:@"pending"],@"failed durable acknowledgement neither advances base/counter nor claims synced");
    Check(DmRestoreSave(b,c.profile,[c.directory stringByAppendingPathComponent:@"Backups"],NULL),@"newer committed B after pending ack");
    [c committed:b];Drain(c);Check(db.modifications==1&&Same(c.profile,b),@"newer save cannot bypass failed confirmed ancestry persistence");
    db.beforeModify=nil;RepairFile(ackState);[c checkForChanges];Drain(c);
    Check(db.modifications==2&&[db.serverSave[@"digest"] isEqual:b[@"digest"]]&&[c.state[@"baseDigest"] isEqual:b[@"digest"]],@"retry persists A ancestry then CAS uploads B without a false conflict");
    Check([c.state[@"uploads"] integerValue]==2&&[Status(c) isEqual:@"synced"],@"confirmed counters advance once each after durable recovery");Stop(c);

    Begin(@"failed journal retains newest commits and retries without another game save");
    c=Coordinator([root stringByAppendingPathComponent:@"journal-failure"],&db);[c publish:a];c.started=YES;[c checkForChanges];Drain(c);
    NSString *journalPath=[c.directory stringByAppendingPathComponent:@"last-committed.plist"];
    BlockFile(journalPath);
    Check(DmRestoreSave(b,c.profile,[c.directory stringByAppendingPathComponent:@"Backups"],NULL),@"journal fault local B");[c committed:b];Drain(c);
    Check(db.modifications==1&&[db.serverSave[@"digest"] isEqual:a[@"digest"]]&&Same(c.profile,b),@"failed journal defers upload while retaining committed B");
    Check([Status(c) isEqual:@"pending"],@"journal failure cannot report synced");
    Check(DmRestoreSave(cSave,c.profile,[c.directory stringByAppendingPathComponent:@"Backups"],NULL),@"journal fault newer local C");[c committed:cSave];Drain(c);
    Check(db.modifications==1&&Same(c.profile,cSave),@"newer failed journal also stays local");
    RepairFile(journalPath);[c checkForChanges];Drain(c);
    NSDictionary *retriedJournal=DmDecodeSave([NSData dataWithContentsOfFile:journalPath],NULL);
    Check([retriedJournal[@"digest"] isEqual:cSave[@"digest"]]&&[db.serverSave[@"digest"] isEqual:cSave[@"digest"]],@"retry journals and uploads the newest complete snapshot");
    Check(db.modifications==2&&![db.uploadedDigests containsObject:b[@"digest"]]&&[Status(c) isEqual:@"synced"],@"superseded B is not uploaded or allowed to replace C journal");Stop(c);

    Begin(@"reopening with a blocked journal cannot bypass the persistence gate");
    NSString *reopenRoot=[root stringByAppendingPathComponent:@"journal-reopen"];
    c=Coordinator(reopenRoot,&db);[c publish:a];c.started=YES;[c checkForChanges];Drain(c);
    NSString *reopenJournal=[c.directory stringByAppendingPathComponent:@"last-committed.plist"];BlockFile(reopenJournal);
    Check(DmRestoreSave(b,c.profile,[c.directory stringByAppendingPathComponent:@"Backups"],NULL),@"reopen committed B");[c committed:b];Drain(c);Stop(c);
    c=Coordinator(reopenRoot,&db);[db setServerSave:a];UIViewController *reopenScreen=[UIViewController new];dispatch_semaphore_t reopened=dispatch_semaphore_create(0);
    OnMain(^{[c prepareForController:reopenScreen completion:^{dispatch_semaphore_signal(reopened);}];});Wait(reopened,@"cached local progress may boot while journal is blocked");Drain(c);
    Check(c.started&&Same(c.profile,b)&&db.modifications==0&&[Status(c) isEqual:@"pending"],@"fresh coordinator keeps valid local save but does not upload without a journal");
    OnMain(^{Check(!reopenScreen.presentedViewController,@"valid cached progress needs no destructive-start prompt");});
    RepairFile(reopenJournal);[c checkForChanges];Drain(c);
    Check(db.modifications==1&&[db.serverSave[@"digest"] isEqual:b[@"digest"]]&&[Status(c) isEqual:@"synced"],@"post-reopen retry journals then uploads without a new commit");Stop(c);

    Begin(@"imported progress survives failed acknowledgement state and keeps its counter on retry");
    c=Coordinator([root stringByAppendingPathComponent:@"import-state-failure"],&db);[db setServerSave:b];
    NSString *importState=[c.directory stringByAppendingPathComponent:@"state.plist"];
    db.beforeAssetFetch=^{BlockFile(importState);};UIViewController *importScreen=[UIViewController new];dispatch_semaphore_t imported=dispatch_semaphore_create(0);
    OnMain(^{[c prepareForController:importScreen completion:^{dispatch_semaphore_signal(imported);}];});Wait(imported,@"verified restored progress can boot despite pending sync-state write");Drain(c);
    Check(c.started&&Same(c.profile,b)&&[c.state[@"imports"] integerValue]==0&&!c.state[@"baseDigest"]&&db.modifications==0,@"failed import ack keeps restored tree but no undurable base/counter");
    Check([Status(c) isEqual:@"pending"],@"import state failure is pending, not synced");
    db.beforeAssetFetch=nil;RepairFile(importState);[c checkForChanges];Drain(c);
    Check([c.state[@"imports"] integerValue]==1&&[c.state[@"baseDigest"] isEqual:b[@"digest"]]&&db.modifications==0,@"retry retains one confirmed import without uploading or restoring again");Stop(c);

    Begin(@"fresh imported save can play offline while its journal write is blocked");
    c=Coordinator([root stringByAppendingPathComponent:@"import-journal-failure"],&db);[db setServerSave:b];
    NSString *importJournal=[c.directory stringByAppendingPathComponent:@"last-committed.plist"];BlockFile(importJournal);
    UIViewController *journalScreen=[UIViewController new];dispatch_semaphore_t journalBoot=dispatch_semaphore_create(0);
    OnMain(^{[c prepareForController:journalScreen completion:^{dispatch_semaphore_signal(journalBoot);}];});Wait(journalBoot,@"restored local progress boots after journal error");Drain(c);
    Check(c.started&&Same(c.profile,b)&&!c.state[@"baseDigest"]&&[Status(c) isEqual:@"pending"],@"restored progress stays recoverable without false sync acknowledgement");
    OnMain(^{Check(!journalScreen.presentedViewController,@"restored valid local tree never offers a blank replacement");});
    RepairFile(importJournal);[c checkForChanges];Drain(c);
    Check([c.state[@"baseDigest"] isEqual:b[@"digest"]]&&db.modifications==0&&[Status(c) isEqual:@"synced"],@"journal recovery acknowledges the existing remote branch without upload");Stop(c);

    Begin(@"account change after a pending confirmed state never publishes into another account");
    c=Coordinator([root stringByAppendingPathComponent:@"pending-account-change"],&db);[c publish:a];c.started=YES;
    NSString *changedState=[c.directory stringByAppendingPathComponent:@"state.plist"];
    db.beforeModify=^(CKModifyRecordsOperation *op){(void)op;BlockFile(changedState);};[c checkForChanges];Drain(c);
    Check(db.modifications==1&&[Status(c) isEqual:@"pending"],@"account-change fixture has a server-confirmed pending acknowledgement");
    db.beforeModify=nil;RepairFile(changedState);((FakeContainer *)(id)c.container).user=@"different-private-user";
    [c committed:b];Drain(c);
    Check(db.modifications==1&&[c.state[@"cloudUser"] isEqual:@"fixture-private-user"]&&[c.state[@"baseDigest"] isEqual:a[@"digest"]],@"retry persists only original account ancestry and rejects the changed account");
    Check([[c snapshot][@"digest"] isEqual:b[@"digest"]]&&[Status(c) isEqual:@"pending"],@"new local branch remains available without a cross-account upload");Stop(c);

    printf("cloud coordinator: %lu scenarios, %lu checks passed\n",(unsigned long)scenarios,(unsigned long)checks);
    [NSFileManager.defaultManager removeItemAtPath:root error:NULL];exit(0);
}}
int main(void) { @autoreleasepool {dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{Run();});CFRunLoopRun();} }
