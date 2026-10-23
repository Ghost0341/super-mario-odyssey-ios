// Independent UIKit overlay: no gameplay input, haptic, clock or renderer mutation.
#import "DmFPSOverlay.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

static NSString *const DmFPSHiddenKey = @"DmFPSOverlayHidden";

@interface DmFPSOverlay ()
@property(nonatomic, strong) UILabel *readout;
@property(nonatomic, strong) NSTimer *sampleTimer;
@property(nonatomic, copy) DmFPSFrameCounter presented;
@property(nonatomic, copy) DmFPSFrameCounter generated;
@property(nonatomic) uint64_t previousPresented;
@property(nonatomic) uint64_t previousGenerated;
@property(nonatomic) CFTimeInterval previousTime;
@end

@implementation DmFPSOverlay
- (instancetype)initWithPresentedFrames:(DmFPSFrameCounter)presented
                       generatedFrames:(DmFPSFrameCounter)generated
                      initiallyVisible:(BOOL)visible {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.presented = presented;
        self.generated = generated;
        self.backgroundColor = UIColor.clearColor;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.exclusiveTouch = NO; // another finger may keep operating the game.
        self.readout = [UILabel new];
        self.readout.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];
        self.readout.textColor = UIColor.whiteColor;
        self.readout.textAlignment = NSTextAlignmentCenter;
        self.readout.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        self.readout.layer.cornerRadius = 4;
        self.readout.layer.masksToBounds = YES;
        self.readout.adjustsFontSizeToFitWidth = YES;
        self.readout.minimumScaleFactor = 0.65;
        self.readout.userInteractionEnabled = NO;
        self.readout.text = @"-- fps";
        [self addSubview:self.readout];
        NSNumber *hidden = [NSUserDefaults.standardUserDefaults objectForKey:DmFPSHiddenKey];
        self.readout.hidden = hidden ? hidden.boolValue : !visible;
        [self updateAccessibility];
        [self addTarget:self action:@selector(toggleCounter) forControlEvents:UIControlEventTouchUpInside];
        self.previousPresented = presented ? presented() : 0;
        self.previousGenerated = generated ? generated() : 0;
        self.previousTime = CACurrentMediaTime();
        __weak DmFPSOverlay *weakSelf = self;
        self.sampleTimer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            [weakSelf sampleFrames];
        }];
        [NSRunLoop.mainRunLoop addTimer:self.sampleTimer forMode:NSRunLoopCommonModes];
    }
    return self;
}
- (void)dealloc { [_sampleTimer invalidate]; }
- (BOOL)isCounterVisible { return !self.readout.hidden; }
- (void)layoutSubviews {
    [super layoutSubviews];
    self.readout.frame = self.bounds;
}
- (void)placeInBounds:(CGRect)bounds safeArea:(UIEdgeInsets)insets {
    CGRect safe = UIEdgeInsetsInsetRect(bounds, insets);
    // At short landscape heights, leave the reference L3 center reachable.
    CGFloat unit = MIN(MIN(bounds.size.height / 430.0, 1.3), MAX(0, safe.size.width) / 600.0);
    CGFloat width = MIN(80, MIN(MAX(0, safe.size.width - 8), MAX(0, 102 * unit - 9)));
    CGFloat height = MIN(22, MAX(0, safe.size.height - 4));
    self.frame = CGRectMake(floor(CGRectGetMinX(safe) + 4), floor(CGRectGetMinY(safe) + 2), width, height);
}
- (void)updateAccessibility {
    self.accessibilityLabel = self.isCounterVisible ? @"Hide frame rate" : @"Show frame rate";
    self.accessibilityValue = self.isCounterVisible ? self.readout.text : @"Hidden";
}
- (void)toggleCounter {
    // Never hide/disable this control: it remains the reveal target.
    self.readout.hidden = !self.readout.hidden;
    [NSUserDefaults.standardUserDefaults setBool:self.readout.hidden forKey:DmFPSHiddenKey];
    [self updateAccessibility];
    NSLog(@"[fps-hud] %@", self.isCounterVisible ? @"visible" : @"hidden; corner target retained");
}
- (BOOL)accessibilityActivate { [self toggleCounter]; return YES; }
- (void)sampleFrames {
    uint64_t count = self.presented ? self.presented() : 0;
    uint64_t generated = self.generated ? self.generated() : 0;
    CFTimeInterval now = CACurrentMediaTime(), elapsed = now - self.previousTime;
    if (elapsed > 0 && elapsed < 1.5 && count >= self.previousPresented && generated >= self.previousGenerated) {
        self.readout.text = [NSString stringWithFormat:@"%.0f fps%@",
            (count - self.previousPresented) / elapsed,
            generated > self.previousGenerated ? @" · FG" : @""];
    } else {
        self.readout.text = @"-- fps";
    }
    self.previousPresented = count;
    self.previousGenerated = generated;
    self.previousTime = now;
    [self updateAccessibility];
}
@end
