// UIKit adapter: include after UIKit (or synthetic declarations in the test).
// Inspect only reported real/coalesced samples, never predicted positions.
#pragma once
#include "dm_touch_controls.h"
static inline void dm_gear_observe_actual_samples(dm_tc_gear *gear,UITouch *touch,UIEvent *event,UIView *view) {
    for (UITouch *sample in [event coalescedTouchesForTouch:touch]) {
        CGPoint p=[sample locationInView:view];dm_tc_gear_move(gear,(dm_tc_point){p.x,p.y});
    }
    CGPoint latest=[touch locationInView:view];dm_tc_gear_move(gear,(dm_tc_point){latest.x,latest.y});
}
