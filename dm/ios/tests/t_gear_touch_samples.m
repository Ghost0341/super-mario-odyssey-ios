// Run the real gear adapter with synthetic UIKit-shaped samples on macOS.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <assert.h>
@interface UIView : NSObject @end
@implementation UIView @end
@interface UITouch : NSObject
@property CGPoint point;
- (CGPoint)locationInView:(UIView *)view;
@end
@implementation UITouch
- (CGPoint)locationInView:(UIView *)view { (void)view;return self.point; }
@end
@interface UIEvent : NSObject
@property NSArray<UITouch *> *samples;
@property unsigned predictedRequests;
- (NSArray<UITouch *> *)coalescedTouchesForTouch:(UITouch *)touch;
- (NSArray<UITouch *> *)predictedTouchesForTouch:(UITouch *)touch;
@end
@implementation UIEvent
- (NSArray<UITouch *> *)coalescedTouchesForTouch:(UITouch *)touch { (void)touch;return self.samples; }
- (NSArray<UITouch *> *)predictedTouchesForTouch:(UITouch *)touch { (void)touch;++self.predictedRequests;return @[]; }
@end
#include "../Sources/DmGearTouch.h"
static UITouch *touch(double x,double y) { UITouch *t=[UITouch new];t.point=CGPointMake(x,y);return t; }
int main(void) { @autoreleasepool {
    UIView *view=[UIView new];UIEvent *event=[UIEvent new];dm_tc_gear gear={0};
    uint64_t at=1000000000;
    uint64_t token=dm_tc_gear_begin(&gear,(dm_tc_point){10,10},at,0);
    UITouch *latest=touch(10,10);event.samples=@[touch(10,10),touch(23,10),latest];
    dm_gear_observe_actual_samples(&gear,latest,event,view);
    assert(gear.blocked&&!dm_tc_gear_ready(&gear,token,at+DM_TC_GEAR_HOLD_NS,0));
    token=dm_tc_gear_begin(&gear,(dm_tc_point){10,10},at,0);
    event.samples=@[touch(12,10),touch(22,10),latest];dm_gear_observe_actual_samples(&gear,latest,event,view);
    assert(!gear.blocked&&dm_tc_gear_ready(&gear,token,at+DM_TC_GEAR_HOLD_NS,0));
    token=dm_tc_gear_begin(&gear,(dm_tc_point){10,10},at,0);
    event.samples=nil;latest=touch(22.01,10);dm_gear_observe_actual_samples(&gear,latest,event,view);
    assert(gear.blocked&&!dm_tc_gear_ready(&gear,token,at+DM_TC_GEAR_HOLD_NS,0));
    token=dm_tc_gear_begin(&gear,(dm_tc_point){10,10},at,0);
    event.samples=@[touch(10,10)];dm_gear_observe_actual_samples(&gear,latest,event,view);
    assert(gear.blocked&&!dm_tc_gear_ready(&gear,token,at+DM_TC_GEAR_HOLD_NS,0));
    dm_tc_gear_cancel(&gear);latest=touch(10,10);dm_gear_observe_actual_samples(&gear,latest,event,view);
    assert(!dm_tc_gear_ready(&gear,token,at+DM_TC_GEAR_HOLD_NS,0));
    assert(!event.predictedRequests);
    puts("PASS: actual gear adapter catches coalesced out-and-back, exact12pt boundary, nil history, endpoint escape and cancellation; no predicted input");
    return 0;
} }
