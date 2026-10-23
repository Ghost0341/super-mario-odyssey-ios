// Shared, game-free iOS FPS display. Hidden text retains its exact reveal target.
#import <UIKit/UIKit.h>
#include <stdint.h>

typedef uint64_t (^DmFPSFrameCounter)(void);

@interface DmFPSOverlay : UIControl
- (instancetype)initWithPresentedFrames:(DmFPSFrameCounter)presented
                       generatedFrames:(DmFPSFrameCounter)generated
                      initiallyVisible:(BOOL)visible;
@property(nonatomic, readonly, getter=isCounterVisible) BOOL counterVisible;
- (void)placeInBounds:(CGRect)bounds safeArea:(UIEdgeInsets)insets;
@end
