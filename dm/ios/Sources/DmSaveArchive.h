// Bounded, game-bound complete save trees for cloud handoff and recoverable restore.
#import <Foundation/Foundation.h>

// Snapshot keys: format, game, files (relative path -> NSData), directories,
// guestNames (relative path -> internal guest-name xattr), digest (SHA-256).
// Missing, empty or incomplete first-boot trees return nil without an error.
NSDictionary *DmReadSave(NSString *directory, NSError **error);
NSData *DmEncodeSave(NSDictionary *snapshot, NSError **error);
NSDictionary *DmDecodeSave(NSData *data, NSError **error);
// Call only before mounting the save. Staging is verified before atomic publish;
// an existing tree is cloned and verified in backupRoot before it is replaced.
BOOL DmRestoreSave(NSDictionary *snapshot, NSString *directory, NSString *backupRoot, NSError **error);
// Three-way decision: equal / empty / upload / download / conflict.
NSString *DmSaveDecision(NSString *localDigest, NSString *baseDigest, NSString *remoteDigest);
