// Sensor-source arbitration and proper device-body rotations, independent of Apple APIs.
#pragma once
#include <math.h>
#include <stdint.h>
#include <string.h>

enum { DM_MOTION_OFF, DM_MOTION_CONTROLLER, DM_MOTION_DEVICE, DM_MOTION_AUTO };
enum { DM_MOTION_PORTRAIT = 1, DM_MOTION_UPSIDE_DOWN = 2, DM_MOTION_LANDSCAPE_LEFT = 3, DM_MOTION_LANDSCAPE_RIGHT = 4 };
#define DM_MOTION_LEASE_NS 200000000ull
typedef struct {
    int requested, active, controller, device, selected;
    uint64_t generation, last[3], controller_since;
} dm_motion_router;

static inline int dm_motion_fresh(uint64_t sample, uint64_t now) {
    return sample && now >= sample && now - sample <= DM_MOTION_LEASE_NS;
}
static inline void dm_motion_configure(dm_motion_router *r, int request, int active, int controller, int device) {
    uint64_t generation = r->generation + 1;
    *r = (dm_motion_router){.requested=request, .active=!!active, .controller=!!controller,
                           .device=!!device, .generation=generation};
}
static inline int dm_motion_choose(dm_motion_router *r, uint64_t now) {
    int c = r->controller && dm_motion_fresh(r->last[1], now), d = r->device && dm_motion_fresh(r->last[2], now);
    int next = 0;
    if (r->active) switch (r->requested) {
        case DM_MOTION_CONTROLLER: next = c ? 1 : 0; break;
        case DM_MOTION_DEVICE: next = d ? 2 : 0; break;
        case DM_MOTION_AUTO:
            // Recover to the controller only after 100 ms of continuous fresh
            // samples; initial controller selection need not wait for a device.
            if (c && (r->selected != 2 || (r->controller_since && r->last[1]-r->controller_since >= 100000000ull))) next = 1;
            else if (d) next = 2;
            break;
        default: break;
    }
    if (!c) r->controller_since = 0;
    r->selected = next; return next;
}
static inline int dm_motion_observe(dm_motion_router *r, uint64_t generation, int source, uint64_t sample, uint64_t now) {
    if (generation != r->generation || !r->active || source < 1 || source > 2 ||
        r->requested == DM_MOTION_OFF || (r->requested != DM_MOTION_AUTO && r->requested != source) ||
        !dm_motion_fresh(sample, now) || sample <= r->last[source] ||
        !(source == 1 ? r->controller : r->device)) return 0;
    if (source == 1 && (!r->controller_since || !dm_motion_fresh(r->last[1], sample))) r->controller_since = sample;
    r->last[source] = sample;
    return 1;
}
// CoreMotion body coordinates: x right, y toward portrait top, z out of screen.
// Rotate into the current screen's x-right/y-top/z-out basis. Determinant +1;
// apply this identical rotation to acceleration and angular velocity.
static inline int dm_motion_rotate(int orientation, const double in[3], double out[3]) {
    for (int i=0;i<3;i++) if (!isfinite(in[i])) return 0;
    switch (orientation) {
        case DM_MOTION_PORTRAIT: out[0]=in[0]; out[1]=in[1]; break;
        case DM_MOTION_UPSIDE_DOWN: out[0]=-in[0]; out[1]=-in[1]; break;
        // UIKit interface orientation is opposite UIDeviceOrientation: in
        // interface-left the portrait top points toward the screen's right.
        case DM_MOTION_LANDSCAPE_LEFT: out[0]=in[1]; out[1]=-in[0]; break;
        case DM_MOTION_LANDSCAPE_RIGHT: out[0]=-in[1]; out[1]=in[0]; break;
        default: return 0;
    }
    out[2]=in[2]; return 1;
}
// CMLogItem uses uptime seconds. Preserve the sample's age while translating
// into the host's monotonic nanoseconds; never timestamp at queue consumption.
static inline uint64_t dm_motion_timestamp(double seconds, double uptime_origin, uint64_t clock_origin, uint64_t now) {
    if (!isfinite(seconds) || !isfinite(uptime_origin) || seconds < 0) return 0;
    long double mapped = (long double)clock_origin + ((long double)seconds-uptime_origin)*1000000000.0L;
    if (mapped <= 0 || mapped > (long double)now || mapped >= 0x1p64L) return 0;
    uint64_t result = (uint64_t)mapped;
    return dm_motion_fresh(result, now) ? result : 0;
}
