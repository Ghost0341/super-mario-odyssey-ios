// Deterministic, inert UI surface plus observable background-task lifetime.
#import <UIKit/UIKit.h>
@implementation UIView
- (void)addSubview:(UIView *)view { (void)view; }
- (void)removeFromSuperview {}
@end
@implementation UIFont
+ (instancetype)systemFontOfSize:(CGFloat)size { (void)size; return [self new]; }
@end
@implementation UIColor
+ (instancetype)whiteColor { return [self new]; }
@end
@implementation UILabel
@end
@implementation UIViewController
- (instancetype)init { if ((self=[super init])) _view=[UIView new]; return self; }
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    (void)animated; self.presentedViewController=controller; if(completion)completion();
}
@end
@implementation UIAlertAction
+ (instancetype)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler {
    (void)style; UIAlertAction *action=[self new]; action.title=title; action.handler=handler; return action;
}
@end
@implementation UIAlertController
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(UIAlertControllerStyle)style {
    (void)title;(void)message;(void)style; UIAlertController *alert=[self new];alert.actions=[NSMutableArray new];return alert;
}
- (void)addAction:(UIAlertAction *)action { [self.actions addObject:action]; }
@end
@implementation UIDevice
+ (instancetype)currentDevice { static UIDevice *d;static dispatch_once_t once;dispatch_once(&once,^{d=[self new];});return d; }
- (NSString *)model { return @"Host-test iPad"; }
@end
@implementation UIApplication
+ (instancetype)sharedApplication {
    static UIApplication *a;static dispatch_once_t once;
    dispatch_once(&once,^{a=[self new];a.activeTasks=[NSMutableSet new];});return a;
}
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)name expirationHandler:(void (^)(void))handler {
    (void)name; NSAssert(NSThread.isMainThread,@"background task begins on main queue");
    UIBackgroundTaskIdentifier identifier=++self.beganTasks;[self.activeTasks addObject:@(identifier)];self.expirationHandler=handler;return identifier;
}
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)identifier {
    NSAssert(NSThread.isMainThread,@"background task ends on main queue");
    void (^barrier)(void)=self.beforeEnd;self.beforeEnd=nil;if(barrier)barrier();
    NSAssert([self.activeTasks containsObject:@(identifier)],@"task must end exactly once");
    [self.activeTasks removeObject:@(identifier)];++self.endedTasks;
}
@end
