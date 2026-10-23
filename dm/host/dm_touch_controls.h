// Canonical portable touch geometry, palette and deliberate settings gesture.
// Derived from Odyssey's accepted DmGamepad layout; units scale with height.
#pragma once
#include <math.h>
#include <stdint.h>

#define DM_TC_VERSION 6
#define DM_TC_ZL_X 44.0
#define DM_TC_ZL_Y 40.0
#define DM_TC_ZL_R 26.0
#define DM_TC_L_X 44.0
#define DM_TC_L_Y 108.0
#define DM_TC_L_R 24.0
#define DM_TC_DROP_TIP 1.45
#define DM_TC_CORNER_IN 0.5
#define DM_TC_FACE_X 81.0
#define DM_TC_PAD_Y 82.0
#define DM_TC_FACE_GAP 50.0
#define DM_TC_FACE_R 27.0
#define DM_TC_PILL_DX 60.0
#define DM_TC_PILL_HIT_PAD 8.0
#define DM_TC_GEAR_GAP 5.0
#define DM_TC_PILL_Y 22.0
#define DM_TC_PILL_W 50.0
#define DM_TC_PILL_H 28.0
#define DM_TC_STICK_X 81.0
#define DM_TC_STICK_R 77.0
#define DM_TC_KNOB_R 30.0
#define DM_TC_STICK_GRAB 1.4
#define DM_TC_FULL 0.8
#define DM_TC_DEAD 0.1
#define DM_TC_LOW_X 231.0
#define DM_TC_LOW_Y 64.0
#define DM_TC_DPAD_R 48.0
#define DM_TC_ARM_W 17.0
#define DM_TC_ARM_IN 11.0
#define DM_TC_DPAD_GRAB 1.3
#define DM_TC_RSTICK_R 60.0
#define DM_TC_RSWIPE (1.0 / 3.0)
#define DM_TC_CLICK_X 102.0
#define DM_TC_CLICK_R 17.0
#define DM_TC_IDLE_ALPHA 0.06
#define DM_TC_PRESSED_ALPHA 0.18
#define DM_TC_STROKE_ALPHA 0.18
#define DM_TC_TEXT_ALPHA 0.32
#define DM_TC_PRESSED_TEXT_ALPHA 0.46
#define DM_TC_RING_ALPHA 0.025
#define DM_TC_SHADOW_ALPHA 0.08
#define DM_TC_GEAR_SIZE 44.0
#define DM_TC_GEAR_SYMBOL "gearshape"
#define DM_TC_GEAR_ICON_SIZE 20.0
#define DM_TC_GEAR_ALPHA 0.38
#define DM_TC_GEAR_REGULAR_WEIGHT 1
#define DM_TC_GEAR_HOLD_NS UINT64_C(450000000)
#define DM_TC_GEAR_SLOP 12.0

typedef struct { double x, y; } dm_tc_point;
typedef struct { double x, y, width, height; } dm_tc_rect;
typedef struct { double top, left, bottom, right; } dm_tc_insets;
typedef struct {
    double unit;
    dm_tc_rect safe, corner, gear;
    dm_tc_point face, left_stick, dpad;
} dm_tc_layout;

static inline dm_tc_layout dm_tc_make_layout(double width, double height, dm_tc_insets i) {
    dm_tc_layout l = {0};
    if (!isfinite(width) || !isfinite(height) || width <= 0 || height <= 0) return l;
    i.top = isfinite(i.top) ? fmax(0, fmin(i.top, height)) : 0;
    i.bottom = isfinite(i.bottom) ? fmax(0, fmin(i.bottom, height-i.top)) : 0;
    i.left = isfinite(i.left) ? fmax(0, fmin(i.left, width)) : 0;
    i.right = isfinite(i.right) ? fmax(0, fmin(i.right, width-i.left)) : 0;
    l.safe = (dm_tc_rect){i.left, i.top, width-i.left-i.right, height-i.top-i.bottom};
    // Narrow/intermediate scenes must not grow controls from height alone.
    // Normal landscape phone/tablet geometry retains the accepted scale.
    l.unit = fmin(fmin(height / 430.0, 1.3), l.safe.width / 600.0);
    l.corner = (dm_tc_rect){i.left*DM_TC_CORNER_IN, i.top,
        width-(i.left+i.right)*DM_TC_CORNER_IN, height-i.top-i.bottom};
    double bottom = l.corner.y+l.corner.height;
    l.face = (dm_tc_point){l.corner.x+l.corner.width-DM_TC_FACE_X*l.unit, bottom-DM_TC_PAD_Y*l.unit};
    l.left_stick = (dm_tc_point){l.corner.x+DM_TC_STICK_X*l.unit, bottom-DM_TC_PAD_Y*l.unit};
    l.dpad = (dm_tc_point){l.corner.x+DM_TC_LOW_X*l.unit, bottom-DM_TC_LOW_Y*l.unit};
    l.gear = (dm_tc_rect){l.safe.x+l.safe.width/2-DM_TC_GEAR_SIZE/2,
        l.safe.y+fmax(DM_TC_PILL_Y*l.unit-DM_TC_GEAR_SIZE/2, 0), DM_TC_GEAR_SIZE, DM_TC_GEAR_SIZE};
    return l;
}
static inline dm_tc_point dm_tc_face_position(dm_tc_layout l, int index) {
    double gap = DM_TC_FACE_GAP*l.unit;
    return (dm_tc_point){l.face.x+(index == 0 ? gap : index == 3 ? -gap : 0),
                         l.face.y+(index == 1 ? gap : index == 2 ? -gap : 0)};
}
static inline dm_tc_point dm_tc_shoulder(dm_tc_layout l, int right, int trigger) {
    return (dm_tc_point){right ? l.safe.x+l.safe.width-(trigger?DM_TC_ZL_X:DM_TC_L_X)*l.unit :
        l.safe.x+(trigger?DM_TC_ZL_X:DM_TC_L_X)*l.unit, l.safe.y+(trigger?DM_TC_ZL_Y:DM_TC_L_Y)*l.unit};
}
static inline dm_tc_point dm_tc_click(dm_tc_layout l, int right) {
    return (dm_tc_point){right ? l.safe.x+l.safe.width-DM_TC_CLICK_X*l.unit : l.safe.x+DM_TC_CLICK_X*l.unit,
        l.safe.y+DM_TC_ZL_Y*l.unit};
}
static inline dm_tc_rect dm_tc_pill(dm_tc_layout l, int plus) {
    double w=DM_TC_PILL_W*l.unit, h=DM_TC_PILL_H*l.unit;
    double dx=fmax(DM_TC_PILL_DX*l.unit, DM_TC_GEAR_SIZE/2+w/2+DM_TC_PILL_HIT_PAD*l.unit+DM_TC_GEAR_GAP);
    return (dm_tc_rect){l.safe.x+l.safe.width/2+(plus?1:-1)*dx-w/2,
        l.safe.y+DM_TC_PILL_Y*l.unit-h/2, w, h};
}
static inline dm_tc_rect dm_tc_pill_hit(dm_tc_layout l, int plus) {
    dm_tc_rect r=dm_tc_pill(l,plus); double pad=DM_TC_PILL_HIT_PAD*l.unit;
    return (dm_tc_rect){r.x-pad,r.y-pad,r.width+2*pad,r.height+2*pad};
}
static inline int dm_tc_contains(dm_tc_rect r, dm_tc_point p) {
    return p.x >= r.x && p.x < r.x+r.width && p.y >= r.y && p.y < r.y+r.height;
}

// A gear-owned touch remains consumed until it ends, even after invalidation.
// The host must test the exclusive gear rectangle before ANY gameplay hit test,
// pass only conflicting gear touches as blockers. A resting gameplay thumb
// may stay down; presentation clears owned input. Invalidate on background,
// rotation, controller changes and settings dismissal.
typedef struct {
    uint64_t generation, began_ns;
    dm_tc_point origin;
    unsigned tracking, blocked, opened;
} dm_tc_gear;
static inline void dm_tc_gear_cancel(dm_tc_gear *g) {
    ++g->generation; g->tracking=0; g->blocked=1; g->opened=0;
}
static inline uint64_t dm_tc_gear_begin(dm_tc_gear *g, dm_tc_point p, uint64_t now, unsigned other_touches) {
    ++g->generation; g->origin=p; g->began_ns=now;
    g->tracking=1; g->blocked=!!other_touches || !isfinite(p.x) || !isfinite(p.y); g->opened=0; return g->generation;
}
static inline void dm_tc_gear_block(dm_tc_gear *g) { g->blocked=1; }
static inline void dm_tc_gear_move(dm_tc_gear *g, dm_tc_point p) {
    if (!isfinite(p.x) || !isfinite(p.y) || hypot(p.x-g->origin.x, p.y-g->origin.y)>DM_TC_GEAR_SLOP) g->blocked=1;
}
static inline int dm_tc_gear_ready(dm_tc_gear *g, uint64_t token, uint64_t now, unsigned other_touches) {
    if (other_touches) g->blocked=1;
    if (token != g->generation || !g->tracking || g->blocked || g->opened ||
        now < g->began_ns || now-g->began_ns<DM_TC_GEAR_HOLD_NS) return 0;
    g->opened=1; return 1;
}

// v5: a normal gear tap activates on release. Hosts retain exclusive touch
// ownership, inspect actual/coalesced samples, and cancel on lifecycle changes.
static inline int dm_tc_gear_tap(dm_tc_gear *g,uint64_t token,dm_tc_point released,dm_tc_rect hit) {
    dm_tc_gear_move(g,released);
    if (token!=g->generation||!g->tracking||g->blocked||g->opened||!dm_tc_contains(hit,released)) return 0;
    g->tracking=0;g->opened=1;return 1;
}
