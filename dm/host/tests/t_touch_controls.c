// Canonical geometry and gear gesture boundaries, with no game or UIKit input.
#include "dm_touch_controls.h"
#include <stdio.h>
#include <string.h>
static int checks;
#define CHECK(c) do { ++checks; if (!(c)) { fprintf(stderr,"failed line %d: %s\n",__LINE__,#c); return 1; } } while (0)
static int near(double a,double b) { return fabs(a-b)<.000001; }
int main(void) {
    CHECK(DM_TC_VERSION==6);
    CHECK(near(DM_TC_IDLE_ALPHA,.06)&&near(DM_TC_PRESSED_ALPHA,.18));
    CHECK(near(DM_TC_TEXT_ALPHA,.32)&&near(DM_TC_RING_ALPHA,.025));
    CHECK(!strcmp(DM_TC_GEAR_SYMBOL,"gearshape")&&DM_TC_GEAR_ICON_SIZE==20&&DM_TC_GEAR_REGULAR_WEIGHT);
    for (int height=280;height<=1100;height+=10) {
        dm_tc_layout l=dm_tc_make_layout(1.8*height,height,(dm_tc_insets){0,30,21,40});
        CHECK(near(l.unit,fmin(height/430.0,1.3)));
        CHECK(l.gear.width==44&&l.gear.height==44&&l.gear.y>=l.safe.y);
        dm_tc_rect minus=dm_tc_pill_hit(l,0),plus=dm_tc_pill_hit(l,1);
        CHECK(l.gear.x-(minus.x+minus.width)>=DM_TC_GEAR_GAP-.000001);
        CHECK(plus.x-(l.gear.x+l.gear.width)>=DM_TC_GEAR_GAP-.000001);
        CHECK(near(l.face.y,l.left_stick.y));
        CHECK(l.dpad.x>l.left_stick.x&&l.dpad.y>l.left_stick.y);
        dm_tc_point a=dm_tc_face_position(l,0),b=dm_tc_face_position(l,1),x=dm_tc_face_position(l,2),y=dm_tc_face_position(l,3);
        CHECK(a.x>l.face.x&&b.y>l.face.y&&x.y<l.face.y&&y.x<l.face.x);
        CHECK(near(a.x-y.x,100*l.unit)&&near(b.y-x.y,100*l.unit));
        CHECK(dm_tc_shoulder(l,0,1).y<dm_tc_shoulder(l,0,0).y);
        CHECK(dm_tc_click(l,0).x>dm_tc_shoulder(l,0,1).x);
    }
    // Both local Duo display profiles, rotated forms and narrow resize samples.
    const double sizes[][2]={{678,466},{951,669},{466,678},{669,951},{320,700}};
    for (unsigned n=0;n<sizeof sizes/sizeof *sizes;n++) {
        dm_tc_layout l=dm_tc_make_layout(sizes[n][0],sizes[n][1],(dm_tc_insets){0,20,21,20});
        CHECK(isfinite(l.unit)&&l.unit>0);
        CHECK(l.gear.x>=l.safe.x&&l.gear.x+44<=l.safe.x+l.safe.width);
        CHECK(l.dpad.x+DM_TC_DPAD_R*l.unit<l.face.x-(DM_TC_FACE_GAP+DM_TC_FACE_R)*l.unit);
        CHECK(l.left_stick.x-DM_TC_STICK_R*l.unit>=0);
        CHECK(l.face.x+(DM_TC_FACE_GAP+DM_TC_FACE_R)*l.unit<=sizes[n][0]);
    }
    CHECK(dm_tc_make_layout(NAN,440,(dm_tc_insets){0}).unit==0);
    CHECK(dm_tc_make_layout(440,0,(dm_tc_insets){0}).unit==0);
    dm_tc_layout phone=dm_tc_make_layout(956,440,(dm_tc_insets){0,62,21,62});
    CHECK(near(phone.left_stick.x,31+81*phone.unit));
    CHECK(near(phone.left_stick.y,419-82*phone.unit));
    CHECK(dm_tc_contains(phone.gear,(dm_tc_point){phone.gear.x,phone.gear.y}));
    CHECK(!dm_tc_contains(phone.gear,(dm_tc_point){phone.gear.x+44,phone.gear.y}));
    dm_tc_gear gear={0}; const uint64_t t=1000000000;
    uint64_t token=dm_tc_gear_begin(&gear,(dm_tc_point){5,5},t,0);
    CHECK(!dm_tc_gear_ready(&gear,token,t+DM_TC_GEAR_HOLD_NS-1,0));
    CHECK(dm_tc_gear_ready(&gear,token,t+DM_TC_GEAR_HOLD_NS,0));
    CHECK(!dm_tc_gear_ready(&gear,token,t+DM_TC_GEAR_HOLD_NS+1,0)); // one opening
    dm_tc_gear_cancel(&gear);
    CHECK(!dm_tc_gear_ready(&gear,token,t+1000000000,0));
    token=dm_tc_gear_begin(&gear,(dm_tc_point){0,0},t,0);
    dm_tc_gear_move(&gear,(dm_tc_point){12,0});
    CHECK(dm_tc_gear_ready(&gear,token,t+DM_TC_GEAR_HOLD_NS,0));
    token=dm_tc_gear_begin(&gear,(dm_tc_point){0,0},t,0);
    dm_tc_gear_move(&gear,(dm_tc_point){12.01,0});
    dm_tc_gear_move(&gear,(dm_tc_point){0,0}); // returning cannot rearm a swipe
    CHECK(!dm_tc_gear_ready(&gear,token,t+DM_TC_GEAR_HOLD_NS,0));
    token=dm_tc_gear_begin(&gear,(dm_tc_point){0,0},t,1);
    CHECK(!dm_tc_gear_ready(&gear,token,t+DM_TC_GEAR_HOLD_NS,0));
    token=dm_tc_gear_begin(&gear,(dm_tc_point){0,0},t,0);
    dm_tc_gear_block(&gear);
    CHECK(!dm_tc_gear_ready(&gear,token,t+DM_TC_GEAR_HOLD_NS,0));
    token=dm_tc_gear_begin(&gear,(dm_tc_point){0,0},t,0);
    CHECK(!dm_tc_gear_ready(&gear,token,t+DM_TC_GEAR_HOLD_NS,1));
    CHECK(!dm_tc_gear_ready(&gear,token,t+DM_TC_GEAR_HOLD_NS+1,0));
    token=dm_tc_gear_begin(&gear,(dm_tc_point){0,0},t,0);
    dm_tc_gear_cancel(&gear); // quick tap, touch cancel, background, rotation
    CHECK(!dm_tc_gear_ready(&gear,token,t+DM_TC_GEAR_HOLD_NS,0));
    uint64_t newer=dm_tc_gear_begin(&gear,(dm_tc_point){1,1},t+1,0);
    CHECK(!dm_tc_gear_ready(&gear,token,t+1000000000,0));
    CHECK(dm_tc_gear_ready(&gear,newer,t+1000000000,0));
    token=dm_tc_gear_begin(&gear,(dm_tc_point){NAN,0},t,0);
    CHECK(!dm_tc_gear_ready(&gear,token,t+DM_TC_GEAR_HOLD_NS,0));
    // Current v5 activation is tap/release; legacy hold helpers above remain
    // covered for historical receivers but are not called by current adapters.
    dm_tc_rect hit={0,0,44,44};
    token=dm_tc_gear_begin(&gear,(dm_tc_point){22,22},t,0);
    CHECK(dm_tc_gear_tap(&gear,token,(dm_tc_point){22,22},hit));
    CHECK(!dm_tc_gear_tap(&gear,token,(dm_tc_point){22,22},hit));
    token=dm_tc_gear_begin(&gear,(dm_tc_point){22,22},t,0);
    dm_tc_gear_move(&gear,(dm_tc_point){34.01,22});dm_tc_gear_move(&gear,(dm_tc_point){22,22});
    CHECK(!dm_tc_gear_tap(&gear,token,(dm_tc_point){22,22},hit));
    token=dm_tc_gear_begin(&gear,(dm_tc_point){43,22},t,0);
    CHECK(!dm_tc_gear_tap(&gear,token,(dm_tc_point){45,22},hit));
    token=dm_tc_gear_begin(&gear,(dm_tc_point){22,22},t,0);dm_tc_gear_block(&gear);
    CHECK(!dm_tc_gear_tap(&gear,token,(dm_tc_point){22,22},hit));
    token=dm_tc_gear_begin(&gear,(dm_tc_point){22,22},t,0);dm_tc_gear_cancel(&gear);
    CHECK(!dm_tc_gear_tap(&gear,token,(dm_tc_point){22,22},hit));
    token=dm_tc_gear_begin(&gear,(dm_tc_point){22,22},t,0);
    newer=dm_tc_gear_begin(&gear,(dm_tc_point){22,22},t+1,0);
    CHECK(!dm_tc_gear_tap(&gear,token,(dm_tc_point){22,22},hit));
    CHECK(dm_tc_gear_tap(&gear,newer,(dm_tc_point){34,22},hit));
    printf("PASS: %d canonical touch/gear checks\n",checks); return 0;
}
