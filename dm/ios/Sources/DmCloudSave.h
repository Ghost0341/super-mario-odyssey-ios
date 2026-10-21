// Private save synchronization. Restore occurs only before the game starts.
#import <UIKit/UIKit.h>
@interface DmCloudSave : NSObject
+ (instancetype)shared;
+ (BOOL)enabled;
- (void)prepareForController:(UIViewController *)controller completion:(void (^)(void))completion;
- (void)checkForChanges;
- (void)flushForBackground;
@end
void dm_front_save_committed(const char *committedDirectory);
