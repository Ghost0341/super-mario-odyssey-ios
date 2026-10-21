// Exercise the production codec and atomic restore on isolated real files.
#import <Foundation/Foundation.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>
#include <errno.h>
static int TestSwap(const char *, const char *, unsigned);
static int TestClone(const char *, const char *, int);
static ssize_t TestWrite(int, const void *, size_t);
static ssize_t TestRead(int, void *, size_t);
static int TestStat(int, struct stat *);
#define renamex_np TestSwap
#define clonefile TestClone
#define write TestWrite
#define read TestRead
#define fstat TestStat
#import "../Sources/DmSaveArchive.m"
#undef renamex_np
#undef clonefile
#undef write
#undef read
#undef fstat

static BOOL failSwap, failClone, failWrite, corruptWrite;
enum { NO_CAPTURE_FAULT, BODY_EINTR, EOF_EINTR, AFTER_STAT_EINTR, EOF_EIO, AFTER_STAT_EIO,
       EOF_GROWTH, AFTER_SIZE, AFTER_MTIME, AFTER_CTIME };
static unsigned captureFault, captureInjected;
static BOOL readEnded;
static ssize_t TestRead(int fd, void *bytes, size_t count) {
    if (captureFault == BODY_EINTR && !captureInjected && count > 1) {
        captureInjected++; errno = EINTR; return -1;
    }
    ssize_t result = read(fd, bytes, count);
    if (count == 1 && result == 0) {
        readEnded = YES;
        if (!captureInjected && (captureFault == EOF_EINTR || captureFault == EOF_EIO || captureFault == EOF_GROWTH)) {
            captureInjected++;
            if (captureFault == EOF_GROWTH) return 1;
            errno = captureFault == EOF_EINTR ? EINTR : EIO; return -1;
        }
    }
    return result;
}
static int TestStat(int fd, struct stat *st) {
    if (readEnded && !captureInjected && (captureFault == AFTER_STAT_EINTR || captureFault == AFTER_STAT_EIO)) {
        captureInjected++; errno = captureFault == AFTER_STAT_EINTR ? EINTR : EIO; return -1;
    }
    int result = fstat(fd, st);
    if (!result && readEnded && !captureInjected) {
        if (captureFault == AFTER_SIZE) { st->st_size++; captureInjected++; }
        if (captureFault == AFTER_MTIME) { st->st_mtimespec.tv_sec++; captureInjected++; }
        if (captureFault == AFTER_CTIME) { st->st_ctimespec.tv_sec++; captureInjected++; }
    }
    if (!result) readEnded = NO;
    return result;
}
static int TestSwap(const char *a, const char *b, unsigned flags) {
    if (failSwap) { errno = EIO; return -1; }
    return renamex_np(a, b, flags);
}
static int TestClone(const char *a, const char *b, int flags) {
    if (failClone) { errno = ENOSPC; return -1; }
    return clonefile(a, b, flags);
}
static ssize_t TestWrite(int fd, const void *bytes, size_t count) {
    if (failWrite) { errno = ENOSPC; return 0; }
    if (corruptWrite && count) {
        NSMutableData *bad = [NSMutableData dataWithBytes:bytes length:count];
        ((uint8_t *)bad.mutableBytes)[0] ^= 1;
        return write(fd, bad.bytes, bad.length);
    }
    return write(fd, bytes, count);
}
@interface OversizedData : NSData
@end
@implementation OversizedData
- (NSUInteger)length { return 300u << 20; }
- (const void *)bytes { abort(); }
@end
static unsigned checks;
static void Check(BOOL pass, NSString *message) {
    checks++;
    if (!pass) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static void Put(NSString *root, NSString *path, NSString *contents) {
    NSString *file = [root stringByAppendingPathComponent:path];
    Check([NSFileManager.defaultManager createDirectoryAtPath:file.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL], @"create fixture directory");
    Check([[contents dataUsingEncoding:NSUTF8StringEncoding] writeToFile:file options:0 error:NULL], @"write fixture file");
}
static NSMutableDictionary *MutableSnapshot(NSDictionary *save) {
    NSMutableDictionary *copy = [save mutableCopy];
    copy[@"files"] = [save[@"files"] mutableCopy]; copy[@"directories"] = [save[@"directories"] mutableCopy];
    copy[@"guestNames"] = [save[@"guestNames"] mutableCopy];
    return copy;
}
static void Resign(NSMutableDictionary *save) { save[@"digest"] = TreeDigest(save[@"files"], save[@"directories"], save[@"guestNames"]); }
static NSData *RawEncode(NSDictionary *save) {
    return [NSPropertyListSerialization dataWithPropertyList:save format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
}
static void BadSnapshot(NSDictionary *bad, NSString *message) {
    Check(!DmEncodeSave(bad, NULL), message);
    Check(!DmDecodeSave(RawEncode(bad), NULL), message);
}
static BOOL Same(NSString *directory, NSDictionary *save) {
    return [DmReadSave(directory, NULL)[@"digest"] isEqual:save[@"digest"]];
}
int main(int argc, const char **argv) { @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"dm-save-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *local = [root stringByAppendingPathComponent:@"local"], *backups = [root stringByAppendingPathComponent:@"backups"];
    Check([fm createDirectoryAtPath:local withIntermediateDirectories:YES attributes:nil error:NULL], @"create isolated test root");
    NSError *error = nil;
    Check(!DmReadSave([root stringByAppendingPathComponent:@"absent"], &error) && !error, @"missing tree is not progress");
    Check(!DmReadSave(local, &error) && !error, @"empty tree is not progress");
    Put(local, @"Common.bin", @"common-v1");
    Check(!DmReadSave(local, &error) && !error, @"Common-only first boot is not competing progress");
    Put(local, @"File1.bin", @"");
    Check(!DmReadSave(local, &error) && !error, @"zero-length playable file is not progress");
    Put(local, @"File1.bin", @"progress-v1"); Put(local, @".hidden", @"hidden-data");
    Put(local, @"slots/empty-file", @""); Put(local, @".dm-case-0", @"alias-data");
    Check([fm createDirectoryAtPath:[local stringByAppendingPathComponent:@"slots/empty-directory"] withIntermediateDirectories:YES attributes:nil error:NULL], @"empty directory fixture");
    const char guest[] = "FILE1.bin";
    Check(!setxattr([local stringByAppendingPathComponent:@".dm-case-0"].fileSystemRepresentation, kGuestName, guest, sizeof guest - 1, 0, XATTR_NOFOLLOW), @"guest-name alias metadata fixture");
    NSDictionary *save = DmReadSave(local, &error);
    Check(save != nil && !error, [NSString stringWithFormat:@"read complete save: %@", error]);
    Check([save[@"files"] count] == 5 && [save[@"directories"] count] == 2, @"preserve all hidden/empty/ordinary files and empty directories");
    Check([save[@"files"][@"File1.bin"] isEqual:[@"progress-v1" dataUsingEncoding:NSUTF8StringEncoding]], @"exact file bytes");
    NSData *encoded = DmEncodeSave(save, &error);
    Check(encoded.length && !error, @"encode validated archive");
    NSDictionary *decoded = DmDecodeSave(encoded, &error);
    Check([decoded isEqual:save] && !error, @"complete checksum-stable binary archive round trip");
    NSArray *cases = @[@[@"a",@"a",@"a",@"equal"], @[@"a",@"a",@"b",@"download"], @[@"b",@"a",@"a",@"upload"],
        @[@"b",@"a",@"c",@"conflict"], @[@"a",@"",@"",@"upload"], @[@"",@"",@"a",@"download"],
        @[@"a",@"a",@"",@"conflict"], @[@"a",@"",@"b",@"conflict"], @[@"",@"",@"",@"empty"]];
    for (NSArray *test in cases) Check([DmSaveDecision([test[0] length] ? test[0] : nil, [test[1] length] ? test[1] : nil,
        [test[2] length] ? test[2] : nil) isEqual:test[3]], @"three-way conflict decision");

    NSString *fresh = [root stringByAppendingPathComponent:@"fresh"];
    NSMutableDictionary *unordered = MutableSnapshot(save); unordered[@"directories"] = [[save[@"directories"] reverseObjectEnumerator] allObjects]; Resign(unordered);
    Check(DmRestoreSave(unordered, fresh, backups, &error) && Same(fresh, save), @"restore missing target, unordered directories, exact bytes and guest metadata");
    Put(fresh, @"File1.bin", @"different-local-progress"); Put(fresh, @"only-local.bin", @"recover-me");
    NSDictionary *previous = DmReadSave(fresh, NULL);
    Put(root, @"outside.txt", @"outside-save-tree");
    Check(DmRestoreSave(save, fresh, backups, &error) && Same(fresh, save), @"atomic replacement of an existing save");
    NSArray *backupEntries = [fm contentsOfDirectoryAtPath:backups error:NULL];
    Check(backupEntries.count == 1, @"one recoverable verified backup");
    Check(Same([backups stringByAppendingPathComponent:backupEntries.firstObject], previous), @"backup retains every replaced local file");
    Check(![fm fileExistsAtPath:[fresh stringByAppendingPathComponent:@"only-local.bin"]], @"published tree matches entire remote tree");
    Check([[NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"outside.txt"] encoding:NSUTF8StringEncoding error:NULL] isEqual:@"outside-save-tree"], @"outside data is untouched");

    for (unsigned fault = 0; fault < 4; fault++) {
        failWrite = fault == 0; corruptWrite = fault == 1; failClone = fault == 2; failSwap = fault == 3;
        Check(!DmRestoreSave(save, fresh, backups, &error) && error != nil, @"write/checksum/clone/swap failure rolls back");
        failWrite = corruptWrite = failClone = failSwap = NO;
        Check(Same(fresh, save), @"failed import retains exact committed tree");
        for (NSString *entry in [fm contentsOfDirectoryAtPath:root error:NULL])
            Check(![entry hasPrefix:@".save-import-"], @"failed staging is cleaned");
    }
    NSString *nestedBackup = [fresh stringByAppendingPathComponent:@"must-not-create/backups"];
    Check(!DmRestoreSave(save, fresh, nestedBackup, &error) && ![fm fileExistsAtPath:[fresh stringByAppendingPathComponent:@"must-not-create"]], @"nested backup rejected before modifying save");
    NSString *link = [root stringByAppendingPathComponent:@"save-link"];
    Check(!symlink(fresh.fileSystemRepresentation, link.fileSystemRepresentation), @"create directory symlink");
    Check(!DmRestoreSave(save, fresh, [link stringByAppendingPathComponent:@"must-not-create"], &error) && Same(fresh, save), @"symlink backup route cannot enter save");
    Check(!DmReadSave(link, &error) && error != nil, @"root symlink rejected");
    Check(!DmRestoreSave(save, link, backups, &error) && Same(fresh, save), @"restore target symlink rejected");
    NSString *badLink = [fresh stringByAppendingPathComponent:@"bad-link"];
    Check(!symlink([root stringByAppendingPathComponent:@"outside.txt"].fileSystemRepresentation, badLink.fileSystemRepresentation), @"create file symlink");
    Check(!DmReadSave(fresh, &error) && error != nil, @"entry symlink rejected"); [fm removeItemAtPath:badLink error:NULL];
    Check(!mkfifo(badLink.fileSystemRepresentation, 0600), @"create special file");
    Check(!DmReadSave(fresh, &error) && error != nil, @"special file rejected without blocking"); [fm removeItemAtPath:badLink error:NULL];
    int fd = open(badLink.fileSystemRepresentation, O_CREAT | O_WRONLY, 0600);
    Check(fd >= 0 && !ftruncate(fd, kFileLimit + 1), @"create oversized sparse fixture"); close(fd);
    Check(!DmReadSave(fresh, &error) && error != nil, @"oversized local file rejected before reading"); [fm removeItemAtPath:badLink error:NULL];

    NSMutableDictionary *bad = MutableSnapshot(save);
    bad[@"files"][@"File1.bin"] = [@"corruption" dataUsingEncoding:NSUTF8StringEncoding];
    BadSnapshot(bad, @"checksum corruption rejected");
    Check(!DmRestoreSave(bad, fresh, backups, &error) && Same(fresh, save), @"corruption rejected before import");
    for (NSString *unsafe in @[@"../escape", @"/absolute", @"x//y", @"x/./y", @"x/../y", @"bad\\name", @"tail/", [NSString stringWithFormat:@"bad%C", (unichar)0]]) {
        bad = MutableSnapshot(save); bad[@"files"][unsafe] = NSData.data; Resign(bad);
        BadSnapshot(bad, @"correctly checksummed traversal/malformed path rejected");
    }
    bad = MutableSnapshot(save); [bad[@"files"] removeObjectForKey:@"File1.bin"]; Resign(bad); BadSnapshot(bad, @"incomplete remote progress rejected");
    bad = MutableSnapshot(save); bad[@"game"] = @"another-game"; Resign(bad); BadSnapshot(bad, @"archive game identity enforced");
    bad = MutableSnapshot(save); bad[@"files"][@"A"] = NSData.data; bad[@"files"][@"a"] = NSData.data; Resign(bad); BadSnapshot(bad, @"case-insensitive physical path collision rejected");
    bad = MutableSnapshot(save); bad[@"files"][@"orphan/file"] = NSData.data; Resign(bad); BadSnapshot(bad, @"missing parent rejected");
    bad = MutableSnapshot(save); [bad[@"directories"] addObject:@"File1.bin"]; Resign(bad); BadSnapshot(bad, @"file/directory collision rejected");
    bad = MutableSnapshot(save); bad[@"guestNames"][@"File1.bin"] = [@"../escape" dataUsingEncoding:NSUTF8StringEncoding]; Resign(bad); BadSnapshot(bad, @"unsafe guest metadata rejected");
    bad = MutableSnapshot(save); bad[@"guestNames"][@".dm-case-0"] = [@"File1.bin" dataUsingEncoding:NSUTF8StringEncoding]; Resign(bad); BadSnapshot(bad, @"duplicate effective guest filenames rejected");
    bad = MutableSnapshot(save);
    bad[@"guestNames"][@".dm-case-0"] = [[@"x" stringByPaddingToLength:300 withString:@"x" startingAtIndex:0] dataUsingEncoding:NSUTF8StringEncoding]; Resign(bad);
    Check(DmEncodeSave(bad, NULL) != nil, @"bounded long Horizon guest name is preserved through physical alias");
    bad = MutableSnapshot(save); bad[@"files"][@"invalid-data"] = @7; Check(!DmEncodeSave(bad, NULL), @"non-data file rejected");
    bad = MutableSnapshot(save); bad[@"files"][@"large"] = [[OversizedData alloc] init]; Check(!DmEncodeSave(bad, NULL), @"oversized remote file rejected without accessing bytes");
    Check(!DmDecodeSave([[OversizedData alloc] init], NULL), @"oversized encoded payload rejected before parsing");
    Check(!DmDecodeSave([@"not-a-save" dataUsingEncoding:NSUTF8StringEncoding], NULL), @"malformed encoded payload rejected");
    Check(!DmDecodeSave([encoded subdataWithRange:NSMakeRange(0, encoded.length / 2)], NULL), @"truncated encoded payload rejected");
    bad = MutableSnapshot(save);
    for (unsigned i = 0; i < kEntryLimit; i++) bad[@"files"][[NSString stringWithFormat:@"entry-%u", i]] = NSData.data;
    Check(!DmEncodeSave(bad, NULL), @"entry limit enforced");

    // Capture interruptions must not masquerade as mutation. Genuine EOF/stat
    // errors and every size/mtime/ctime mismatch still fail closed, distinctly.
    for (unsigned fault = BODY_EINTR; fault <= AFTER_CTIME; fault++) {
        captureFault = fault; captureInjected = 0; readEnded = NO; error = nil;
        NSDictionary *captured = DmReadSave(local, &error);
        Check(captureInjected == 1, @"targeted capture fault reached exact syscall branch");
        if (fault <= AFTER_STAT_EINTR) {
            Check(captured != nil && !error && [captured[@"digest"] isEqual:save[@"digest"]], @"EINTR retries preserve exact valid snapshot");
        } else {
            Check(!captured && error != nil, @"real errors/changes still reject capture");
            if (fault == EOF_EIO || fault == AFTER_STAT_EIO) {
                Check([error.domain isEqual:NSPOSIXErrorDomain] && error.code == EIO, @"syscall error preserves exact errno");
                Check([error.localizedDescription containsString:fault == EOF_EIO ? @"Read save EOF (" : @"Inspect save after read ("], @"diagnostic distinguishes EOF and stat errors");
            } else Check([error.localizedDescription containsString:fault == EOF_GROWTH ? @"Save grew while reading" : @"Save metadata changed while reading"], @"growth/metadata diagnostics are distinct");
        }
    }
    captureFault = NO_CAPTURE_FAULT; readEnded = NO;

    if (argc == 2) {
        NSDictionary *real = DmReadSave(@(argv[1]), &error);
        Check(real != nil, [NSString stringWithFormat:@"read genuine fixture: %@", error]);
        NSData *realData = DmEncodeSave(real, &error);
        Check([DmDecodeSave(realData, &error)[@"digest"] isEqual:real[@"digest"]], @"genuine save checksum round trip");
        NSString *realCopy = [root stringByAppendingPathComponent:@"genuine-copy"];
        Check(DmRestoreSave(real, realCopy, backups, &error) && Same(realCopy, real), @"genuine save restore preserves every byte");
        printf("genuine fixture: %lu files, %lu encoded bytes, digest %s\n", (unsigned long)[real[@"files"] count], (unsigned long)realData.length, [real[@"digest"] UTF8String]);
    }
    [fm removeItemAtPath:root error:NULL];
    printf("PASS save archive: %u checks, actual files/guest metadata, empty/incomplete boot, checksum/title/path bounds, atomic backup/restore/rollback, three-way decisions\n", checks);
    return 0;
} }
