// Complete committed save snapshots; no game assets, caches or network activity.
#import "DmSaveArchive.h"
#import <CommonCrypto/CommonDigest.h>
#include "game_profile.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

#ifndef DM_GAME_CLOUD_REQUIRED_FILES
#define DM_GAME_CLOUD_REQUIRED_FILES ""
#endif
static const NSUInteger kEntryLimit = 4096, kFileLimit = 64u << 20;
static const NSUInteger kTreeLimit = 256u << 20, kEncodedLimit = 264u << 20;
static const char kGuestName[] = "org.d2rmobile.guest-name";

static BOOL Reject(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"DmSaveArchive" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static BOOL PosixCodeError(NSError **error, int code, NSString *operation) {
    code = code ?: EIO;
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:
        [NSString stringWithFormat:@"%@: %s", operation, strerror(code)]}];
    return NO;
}
static BOOL PosixError(NSError **error, NSString *operation) { return PosixCodeError(error, errno, operation); }
static ssize_t ReadRetry(int fd, void *buffer, size_t count) {
    ssize_t result;
    do { result = read(fd, buffer, count); } while (result < 0 && errno == EINTR);
    return result;
}
static int StatRetry(int fd, struct stat *st) {
    int result;
    do { result = fstat(fd, st); } while (result < 0 && errno == EINTR);
    return result;
}
static BOOL SafePath(id value) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *path = value;
    NSData *utf8 = [path dataUsingEncoding:NSUTF8StringEncoding];
    if (!utf8.length || utf8.length > 1024 || [path containsString:@"\\"] ||
        [path rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound) return NO;
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    if (parts.count > 32) return NO;
    for (NSString *part in parts)
        if (!part.length || [part isEqual:@"."] || [part isEqual:@".."] ||
            [part lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 255) return NO;
    return YES;
}
static NSString *SafeGuestName(id value) {
    if (![value isKindOfClass:NSData.class] || ![value length] || [value length] > 0x300) return nil;
    NSString *name = [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
    if (!name.length || [name isEqual:@"."] || [name isEqual:@".."] || [name containsString:@"/"] ||
        [name containsString:@"\\"] || [name rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound) return nil;
    return name;
}
static NSArray *SortedPaths(NSDictionary *files, NSArray *directories) {
    return [[files.allKeys arrayByAddingObjectsFromArray:directories] sortedArrayUsingComparator:
        ^NSComparisonResult(NSString *a, NSString *b) { return [a compare:b options:NSLiteralSearch]; }];
}
static void HashData(CC_SHA256_CTX *ctx, NSData *data) {
    uint64_t length = CFSwapInt64HostToBig(data.length);
    CC_SHA256_Update(ctx, &length, sizeof length);
    if (data.length) CC_SHA256_Update(ctx, data.bytes, (CC_LONG)data.length);
}
static NSString *TreeDigest(NSDictionary *files, NSArray *directories, NSDictionary *guestNames) {
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
    const char domain[] = "DmSaveArchive1";
    CC_SHA256_Update(&ctx, domain, sizeof domain);
    HashData(&ctx, [@DM_GAME_ID dataUsingEncoding:NSUTF8StringEncoding]);
    for (NSString *path in SortedPaths(files, directories)) {
        uint8_t kind = files[path] ? 1 : 0;
        CC_SHA256_Update(&ctx, &kind, sizeof kind);
        HashData(&ctx, [path dataUsingEncoding:NSUTF8StringEncoding]);
        HashData(&ctx, files[path] ?: NSData.data);
        HashData(&ctx, guestNames[path] ?: NSData.data);
    }
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(bytes, &ctx);
    NSMutableString *digest = [NSMutableString stringWithCapacity:64];
    for (unsigned i = 0; i < sizeof bytes; i++) [digest appendFormat:@"%02x", bytes[i]];
    return digest;
}
static BOOL HasProgress(NSDictionary *files) {
    BOOL nonempty = NO;
    for (NSData *data in files.allValues) if (data.length) { nonempty = YES; break; }
    if (!nonempty) return NO;
    for (NSString *name in [@DM_GAME_CLOUD_REQUIRED_FILES componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
        if (name.length && ![files[name] length]) return NO;
    return YES;
}
static BOOL Validate(NSDictionary *save, NSError **error) {
    if (![save isKindOfClass:NSDictionary.class] || save.count != 6 || ![save[@"format"] isEqual:@1] ||
        ![save[@"game"] isEqual:@DM_GAME_ID] || ![save[@"files"] isKindOfClass:NSDictionary.class] ||
        ![save[@"directories"] isKindOfClass:NSArray.class] || ![save[@"guestNames"] isKindOfClass:NSDictionary.class] ||
        ![save[@"digest"] isKindOfClass:NSString.class] || [save[@"digest"] length] != 64)
        return Reject(error, @"Invalid save archive format or game identity.");
    NSDictionary *files = save[@"files"], *guestNames = save[@"guestNames"];
    NSArray *directories = save[@"directories"];
    if (files.count + directories.count > kEntryLimit || guestNames.count > files.count + directories.count)
        return Reject(error, @"Save archive entry limit exceeded.");
    NSMutableSet *all = [NSMutableSet set], *folded = [NSMutableSet set], *dirs = [NSMutableSet set];
    for (id path in [files.allKeys arrayByAddingObjectsFromArray:directories]) {
        if (!SafePath(path)) return Reject(error, @"Unsafe save archive path.");
        NSString *fold = [[path precomposedStringWithCanonicalMapping] lowercaseString];
        if ([all containsObject:path] || [folded containsObject:fold])
            return Reject(error, @"Save archive contains conflicting physical paths.");
        [all addObject:path]; [folded addObject:fold];
    }
    [dirs addObjectsFromArray:directories];
    for (NSString *path in all) {
        NSString *parent = path.stringByDeletingLastPathComponent;
        if (parent.length && ![dirs containsObject:parent]) return Reject(error, @"Save archive is missing a parent directory.");
    }
    NSUInteger total = 0;
    for (NSString *path in files) {
        id data = files[path];
        if (![data isKindOfClass:NSData.class] || [data length] > kFileLimit || total > kTreeLimit - [data length])
            return Reject(error, @"Invalid or oversized save file.");
        total += [data length];
    }
    for (id path in guestNames) {
        id data = guestNames[path];
        if (![all containsObject:path] || !SafeGuestName(data))
            return Reject(error, @"Invalid guest filename metadata.");
    }
    NSMutableSet *guestPaths = [NSMutableSet set];
    for (NSString *path in all) {
        // Match hle_fs.c: only physical collision aliases consult this xattr.
        NSString *name = path.lastPathComponent;
        if ([name hasPrefix:@".dm-case-"] && guestNames[path]) name = SafeGuestName(guestNames[path]);
        NSString *guestPath = [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:name];
        if ([guestPaths containsObject:guestPath]) return Reject(error, @"Save archive contains duplicate guest filenames.");
        [guestPaths addObject:guestPath];
    }
    if (!HasProgress(files)) return Reject(error, @"No complete game progress is available.");
    if (![TreeDigest(files, directories, guestNames) isEqual:save[@"digest"]])
        return Reject(error, @"Save archive checksum mismatch.");
    return YES;
}
static BOOL ReadGuestName(int fd, NSString *path, NSMutableDictionary *names, NSError **error) {
    char bytes[0x301];
    ssize_t length = fgetxattr(fd, kGuestName, bytes, sizeof bytes, 0, 0);
    if (length < 0) return errno == ENOATTR ? YES : PosixError(error, @"Read guest filename metadata");
    if (!length || length > 0x300) return Reject(error, @"Invalid local guest filename metadata.");
    names[path] = [NSData dataWithBytes:bytes length:(NSUInteger)length];
    return YES;
}
static BOOL ReadTree(int parent, NSString *prefix, NSMutableDictionary *files, NSMutableArray *directories,
                     NSMutableDictionary *guestNames, NSUInteger *total, NSError **error) {
    DIR *stream = fdopendir(dup(parent));
    if (!stream) return PosixError(error, @"Read save directory");
    BOOL ok = YES;
    while (ok) {
        errno = 0; struct dirent *entry = readdir(stream);
        if (!entry) { if (errno) ok = PosixError(error, @"Enumerate save directory"); break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSString stringWithUTF8String:entry->d_name];
        if (!name) { ok = Reject(error, @"Save filename is not valid UTF-8."); break; }
        NSString *path = prefix.length ? [prefix stringByAppendingFormat:@"/%@", name] : name;
        if (!SafePath(path) || files.count + directories.count >= kEntryLimit) { ok = Reject(error, @"Unsafe or oversized local save tree."); break; }
        struct stat initial;
        if (fstatat(parent, entry->d_name, &initial, AT_SYMLINK_NOFOLLOW)) { ok = PosixError(error, @"Inspect save entry"); break; }
        if (!S_ISDIR(initial.st_mode) && !S_ISREG(initial.st_mode)) { ok = Reject(error, @"Save tree contains a symbolic link or special file."); break; }
        int fd = openat(parent, entry->d_name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (S_ISDIR(initial.st_mode) ? O_DIRECTORY : 0));
        if (fd < 0) { ok = PosixError(error, @"Open save entry"); break; }
        struct stat before;
        if (StatRetry(fd, &before) || before.st_dev != initial.st_dev || before.st_ino != initial.st_ino || before.st_mode != initial.st_mode)
            ok = Reject(error, @"Save entry changed while it was read.");
        if (ok) ok = ReadGuestName(fd, path, guestNames, error);
        if (ok && S_ISDIR(before.st_mode)) {
            [directories addObject:path];
            ok = ReadTree(fd, path, files, directories, guestNames, total, error);
        } else if (ok) {
            if (before.st_size < 0 || (uint64_t)before.st_size > kFileLimit || *total > kTreeLimit - (NSUInteger)before.st_size)
                ok = Reject(error, @"Local save file limit exceeded.");
            if (ok) {
                NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)before.st_size];
                NSUInteger offset = 0;
                while (offset < data.length) {
                    ssize_t n = ReadRetry(fd, (uint8_t *)data.mutableBytes + offset, data.length - offset);
                    if (n <= 0) { ok = Reject(error, @"Save file changed or could not be read completely."); break; }
                    offset += (NSUInteger)n;
                }
                if (ok) {
                    struct stat after; char extra;
                    ssize_t tail = ReadRetry(fd, &extra, 1);
                    int tailError = errno;
                    if (tail < 0) ok = PosixCodeError(error, tailError, [NSString stringWithFormat:@"Read save EOF (%@)", path]);
                    else if (tail > 0) ok = Reject(error, [NSString stringWithFormat:@"Save grew while reading %@ (expected %lld bytes).", path, before.st_size]);
                    else if (StatRetry(fd, &after)) {
                        int statError = errno;
                        ok = PosixCodeError(error, statError, [NSString stringWithFormat:@"Inspect save after read (%@)", path]);
                    } else if (after.st_size != before.st_size ||
                        after.st_mtimespec.tv_sec != before.st_mtimespec.tv_sec || after.st_mtimespec.tv_nsec != before.st_mtimespec.tv_nsec ||
                        after.st_ctimespec.tv_sec != before.st_ctimespec.tv_sec || after.st_ctimespec.tv_nsec != before.st_ctimespec.tv_nsec) {
                        // Distinguish genuine mutation from EOF/stat syscall errors.
                        // Keep all timestamp/size guards; never silently accept a changed tree.
                        ok = Reject(error, [NSString stringWithFormat:
                            @"Save metadata changed while reading %@ (size %lld/%lld, mtime %ld.%09ld/%ld.%09ld, ctime %ld.%09ld/%ld.%09ld, inode %llu/%llu).",
                            path, before.st_size, after.st_size,
                            before.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec,
                            before.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec, after.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec,
                            (unsigned long long)before.st_ino, (unsigned long long)after.st_ino]);
                    }
                }
                if (ok) { files[path] = [data copy]; *total += data.length; }
            }
        }
        close(fd);
    }
    closedir(stream);
    return ok;
}
// Internal reads also represent empty/incomplete trees so pre-restore backups
// can be verified without treating those trees as cloud progress.
static NSDictionary *ReadDirectory(NSString *directory, NSError **error) {
    int fd = open(directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) { if (errno != ENOENT) PosixError(error, @"Open save root"); return nil; }
    NSMutableDictionary *files = [NSMutableDictionary dictionary], *names = [NSMutableDictionary dictionary];
    NSMutableArray *directories = [NSMutableArray array]; NSUInteger total = 0;
    BOOL ok = ReadTree(fd, @"", files, directories, names, &total, error); close(fd);
    if (!ok) return nil;
    NSArray *sorted = [directories sortedArrayUsingSelector:@selector(compare:)];
    return @{@"format":@1, @"game":@DM_GAME_ID, @"files":[files copy], @"directories":sorted,
             @"guestNames":[names copy], @"digest":TreeDigest(files, sorted, names)};
}
NSDictionary *DmReadSave(NSString *directory, NSError **error) {
    if (error) *error = nil;
    if (![directory isKindOfClass:NSString.class] || !directory.isAbsolutePath) { Reject(error, @"Invalid local save root."); return nil; }
    NSDictionary *save = ReadDirectory(directory, error);
    if (!save || !HasProgress(save[@"files"])) return nil;
    return Validate(save, error) ? save : nil;
}
NSData *DmEncodeSave(NSDictionary *save, NSError **error) {
    if (error) *error = nil;
    if (!Validate(save, error)) return nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:save format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (data.length > kEncodedLimit) { Reject(error, @"Encoded save archive limit exceeded."); return nil; }
    return data;
}
NSDictionary *DmDecodeSave(NSData *data, NSError **error) {
    if (error) *error = nil;
    if (![data isKindOfClass:NSData.class] || !data.length || data.length > kEncodedLimit) { Reject(error, @"Invalid save archive size."); return nil; }
    NSDictionary *save = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:error];
    return Validate(save, error) ? save : nil;
}
static NSString *CanonicalDirectory(NSString *path, BOOL create, NSError **error) {
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath || [path isEqual:@"/"]) { Reject(error, @"Invalid restore directory."); return nil; }
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st)) {
        if (errno != ENOENT || !create) { PosixError(error, @"Inspect restore directory"); return nil; }
        if (![NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    } else if (!S_ISDIR(st.st_mode)) { Reject(error, @"Restore path is a symbolic link or not a directory."); return nil; }
    char resolved[PATH_MAX];
    if (!realpath(path.fileSystemRepresentation, resolved)) { PosixError(error, @"Resolve restore directory"); return nil; }
    return @(resolved);
}
// Resolve the nearest existing ancestor without creating anything. This catches
// a backup path entering the save through a symlink before it can mutate it.
static NSString *FutureDirectory(NSString *path, NSError **error) {
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath) { Reject(error, @"Invalid backup directory."); return nil; }
    NSString *ancestor = path.stringByStandardizingPath;
    NSMutableArray *tail = [NSMutableArray array]; struct stat st;
    while (lstat(ancestor.fileSystemRepresentation, &st)) {
        if (errno != ENOENT || [ancestor isEqual:@"/"]) { PosixError(error, @"Inspect backup ancestor"); return nil; }
        [tail insertObject:ancestor.lastPathComponent atIndex:0];
        ancestor = ancestor.stringByDeletingLastPathComponent;
    }
    char resolved[PATH_MAX];
    if (!realpath(ancestor.fileSystemRepresentation, resolved)) { PosixError(error, @"Resolve backup ancestor"); return nil; }
    NSString *result = @(resolved);
    for (NSString *part in tail) result = [result stringByAppendingPathComponent:part];
    return result;
}
static BOOL WriteStage(NSDictionary *save, NSString *stage, NSError **error) {
    for (NSString *path in [save[@"directories"] sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *output = [stage stringByAppendingPathComponent:path];
        if (mkdir(output.fileSystemRepresentation, 0700)) return PosixError(error, @"Create staged save directory");
    }
    NSDictionary *files = save[@"files"], *names = save[@"guestNames"];
    for (NSString *path in files) {
        NSString *output = [stage stringByAppendingPathComponent:path];
        int fd = open(output.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd < 0) return PosixError(error, @"Create staged save file");
        NSData *data = files[path]; NSUInteger offset = 0; BOOL ok = YES;
        while (offset < data.length) {
            ssize_t n = write(fd, (const uint8_t *)data.bytes + offset, data.length - offset);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { ok = PosixError(error, @"Write staged save file"); break; }
            offset += (NSUInteger)n;
        }
        if (ok && fsync(fd)) ok = PosixError(error, @"Flush staged save file");
        close(fd); if (!ok) return NO;
    }
    for (NSString *path in names) {
        NSString *output = [stage stringByAppendingPathComponent:path]; NSData *name = names[path];
        if (setxattr(output.fileSystemRepresentation, kGuestName, name.bytes, name.length, 0, XATTR_NOFOLLOW))
            return PosixError(error, @"Restore guest filename metadata");
    }
    return YES;
}
BOOL DmRestoreSave(NSDictionary *save, NSString *directory, NSString *backupRoot, NSError **error) {
    if (error) *error = nil;
    if (!Validate(save, error)) return NO;
    if (![directory isKindOfClass:NSString.class] || !directory.isAbsolutePath || !directory.lastPathComponent.length ||
        [directory.lastPathComponent isEqual:@"."] || [directory.lastPathComponent isEqual:@".."])
        return Reject(error, @"Invalid save restore target.");
    NSString *parent = CanonicalDirectory(directory.stringByDeletingLastPathComponent, YES, error);
    if (!parent) return NO;
    directory = [parent stringByAppendingPathComponent:directory.lastPathComponent];
    struct stat st; BOOL exists = !lstat(directory.fileSystemRepresentation, &st);
    if ((!exists && errno != ENOENT) || (exists && !S_ISDIR(st.st_mode))) return Reject(error, @"Save restore target is not a safe directory.");
    NSString *future = FutureDirectory(backupRoot, error);
    if (!future) return NO;
    if ([future isEqual:directory] || [future hasPrefix:[directory stringByAppendingString:@"/"]])
        return Reject(error, @"Backup directory must be outside the save tree.");
    NSString *backups = CanonicalDirectory(backupRoot, YES, error);
    if (!backups) return NO;
    if ([backups isEqual:directory] || [backups hasPrefix:[directory stringByAppendingString:@"/"]])
        return Reject(error, @"Backup directory must be outside the save tree.");
    NSString *identifier = NSUUID.UUID.UUIDString;
    NSString *stage = [parent stringByAppendingPathComponent:[@".save-import-" stringByAppendingString:identifier]];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (mkdir(stage.fileSystemRepresentation, 0700)) return PosixError(error, @"Create save staging tree");
    BOOL ok = WriteStage(save, stage, error);
    NSDictionary *readback = ok ? DmReadSave(stage, error) : nil;
    if (ok && ![readback[@"digest"] isEqual:save[@"digest"]]) ok = Reject(error, @"Staged save failed checksum verification.");
    if (ok && exists) {
        NSDictionary *before = ReadDirectory(directory, error);
        NSString *backup = [backups stringByAppendingPathComponent:identifier];
        if (!before) ok = NO;
        else if (clonefile(directory.fileSystemRepresentation, backup.fileSystemRepresentation, CLONE_NOFOLLOW))
            ok = PosixError(error, @"Clone recoverable save backup");
        else {
            NSDictionary *verified = ReadDirectory(backup, error);
            if (![verified[@"digest"] isEqual:before[@"digest"]]) ok = Reject(error, @"Existing save backup failed checksum verification.");
        }
    }
    if (ok && renamex_np(stage.fileSystemRepresentation, directory.fileSystemRepresentation, exists ? RENAME_SWAP : RENAME_EXCL))
        ok = PosixError(error, @"Atomically publish staged save; existing save retained");
    // On success with an existing target, stage now holds the previous tree; a
    // complete, verified clone already remains in backupRoot before publishing.
    [fm removeItemAtPath:stage error:NULL];
    return ok;
}
NSString *DmSaveDecision(NSString *local, NSString *base, NSString *remote) {
    if ([local isEqual:remote]) return @"equal";
    if (!local.length) return remote.length ? @"download" : @"empty";
    if (!remote.length) return base.length ? @"conflict" : @"upload";
    if ([local isEqual:base]) return @"download";
    if ([remote isEqual:base]) return @"upload";
    return @"conflict";
}
