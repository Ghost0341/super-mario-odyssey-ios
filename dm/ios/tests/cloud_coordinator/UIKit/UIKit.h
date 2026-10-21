// Host-test surface only. The production coordinator is compiled unchanged;
// CloudKit, Foundation, dispatch and the archive codec remain Apple's real APIs.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
// Foundation loads private UI classes on macOS. Prefix every shim class to
// avoid colliding with those classes in the Objective-C runtime.
#define UIView DMTestView
#define UIFont DMTestFont
#define UIColor DMTestColor
#define UILabel DMTestLabel
#define UIViewController DMTestViewController
#define UIAlertAction DMTestAlertAction
#define UIAlertController DMTestAlertController
#define UIDevice DMTestDevice
#define UIApplication DMTestApplication
typedef NSUInteger UIBackgroundTaskIdentifier;
static const UIBackgroundTaskIdentifier UIBackgroundTaskInvalid = NSUIntegerMax;
typedef NS_OPTIONS(NSUInteger, UIViewAutoresizing) { UIViewAutoresizingFlexibleWidth=2, UIViewAutoresizingFlexibleHeight=16 };
typedef NS_ENUM(NSInteger, NSTextAlignment) { NSTextAlignmentCenter=1 };
typedef NS_ENUM(NSInteger, UIAlertControllerStyle) { UIAlertControllerStyleAlert=1 };
typedef NS_ENUM(NSInteger, UIAlertActionStyle) { UIAlertActionStyleDefault=0, UIAlertActionStyleCancel=1 };
typedef NS_ENUM(NSInteger, UIApplicationState) { UIApplicationStateActive=0, UIApplicationStateInactive=1, UIApplicationStateBackground=2 };
@interface UIView : NSObject
@property CGRect bounds;
@property CGRect frame;
@property UIViewAutoresizing autoresizingMask;
- (void)addSubview:(UIView *)view;
- (void)removeFromSuperview;
@end
@interface UIFont : NSObject
+ (instancetype)systemFontOfSize:(CGFloat)size;
@end
@interface UIColor : NSObject
+ (instancetype)whiteColor;
@end
@interface UILabel : UIView
@property(copy) NSString *text;
@property(strong) UIFont *font;
@property(strong) UIColor *textColor;
@property NSTextAlignment textAlignment;
@end
@interface UIViewController : NSObject
@property(strong) UIView *view;
@property(strong) UIViewController *presentedViewController;
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion;
@end
@interface UIAlertAction : NSObject
@property(copy) NSString *title;
@property(copy) void (^handler)(UIAlertAction *);
+ (instancetype)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler;
@end
@interface UIAlertController : UIViewController
@property(strong) NSMutableArray<UIAlertAction *> *actions;
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(UIAlertControllerStyle)style;
- (void)addAction:(UIAlertAction *)action;
@end
@interface UIDevice : NSObject
+ (instancetype)currentDevice;
@property(readonly) NSString *model;
@end
@interface UIApplication : NSObject
+ (instancetype)sharedApplication;
@property NSUInteger beganTasks;
@property NSUInteger endedTasks;
@property(strong) NSMutableSet<NSNumber *> *activeTasks;
@property(copy) void (^expirationHandler)(void);
@property(copy) void (^beforeEnd)(void); // one-shot deterministic race barrier
@property UIApplicationState applicationState;
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)name expirationHandler:(void (^)(void))handler;
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)identifier;
@end
