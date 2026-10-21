// Bounded, hardware-independent conversion of the game's native rumble bands.
#pragma once
#include <math.h>
#include <stdint.h>
#include "dm_feedback.h"

typedef struct { float intensity, sharpness; } dm_handle_effect;
typedef struct { float strength; int enabled; } dm_trigger_effect;
enum { DM_JUMP_TRIGGER_PULSE_NS = 65000000 };

static inline float dm_feedback_clamp(float v, float lo, float hi) {
    return v < lo ? lo : v > hi ? hi : v;
}

// Preserve the authored time envelope and left/right separation. Band frequency
// selects texture; native vibration never implicitly drives an adaptive trigger.
static inline dm_handle_effect dm_feedback_native_effect(dm_vibration_value v, float gain) {
    dm_handle_effect out = {0};
    if (!isfinite(v.amp_low) || !isfinite(v.amp_high) || !isfinite(v.freq_low) ||
        !isfinite(v.freq_high) || !isfinite(gain)) return out;
    float lo = dm_feedback_clamp(v.amp_low, 0, 1), hi = dm_feedback_clamp(v.amp_high, 0, 1);
    if ((lo > 0 && v.freq_low <= 0) || (hi > 0 && v.freq_high <= 0)) return out;
    float weight = lo + hi;
    if (weight < 0.008f) return out;
    double hz = (lo * (double)v.freq_low + hi * (double)v.freq_high) / weight;
    hz = fmax(40, fmin(1250, hz));
    out.intensity = dm_feedback_clamp(hypotf(lo, hi) * dm_feedback_clamp(gain, 0, 1), 0, 0.9f);
    out.sharpness = (float)(log(hz / 40) / log(1250.0 / 40));
    return out;
}

// A confirmed long-jump entry supplies event_ns. Holding a trigger by itself
// supplies no event. This short kick releases fully instead of adding resistance
// throughout the airborne or crouched state.
static inline dm_handle_effect dm_feedback_long_jump(uint64_t event_ns, uint64_t now_ns, int side) {
    dm_handle_effect out = {0};
    if (!event_ns || now_ns < event_ns || now_ns - event_ns >= 90000000ull) return out;
    float t = (float)(now_ns - event_ns) / 90000000.f;
    out.intensity = (side ? 0.07f : 0.09f) * (1 - t) * (1 - t);
    out.sharpness = 0.28f;
    return out;
}

// A verified backflip takeoff gets a soft lift followed by a finer release.
// The native game graph remains responsible for the eventual landing texture.
static inline dm_handle_effect dm_feedback_backflip(uint64_t event_ns, uint64_t now_ns, int side) {
    dm_handle_effect out = {0};
    if (!event_ns || now_ns < event_ns || now_ns - event_ns >= 120000000ull) return out;
    uint64_t age = now_ns - event_ns;
    if (age < 45000000ull) {
        float t = (float)age / 45000000.f;
        out.intensity = (side ? 0.15f : 0.18f) * (1 - t) * (1 - t);
        out.sharpness = 0.32f;
    } else {
        float t = (float)(age - 45000000ull) / 75000000.f;
        out.intensity = (side ? 0.06f : 0.05f) * (1 - t) * (1 - t);
        out.sharpness = 0.68f;
    }
    return out;
}

// A wall kick compresses into a crisp grip, then gives a smaller rebound tap.
static inline dm_handle_effect dm_feedback_wall_jump(uint64_t event_ns, uint64_t now_ns, int side) {
    dm_handle_effect out = {0};
    if (!event_ns || now_ns < event_ns || now_ns - event_ns >= 85000000ull) return out;
    uint64_t age = now_ns - event_ns;
    if (age < 30000000ull) {
        float t = (float)age / 30000000.f;
        out.intensity = (side ? 0.19f : 0.22f) * (1 - t) * (1 - t);
        out.sharpness = 0.82f;
    } else if (age >= 35000000ull) {
        float t = (float)(age - 35000000ull) / 50000000.f;
        out.intensity = (side ? 0.10f : 0.08f) * (1 - t) * (1 - t);
        out.sharpness = 0.45f;
    }
    return out;
}

// A side flip sweeps a fine, light pulse between the two handles.
static inline dm_handle_effect dm_feedback_side_flip(uint64_t event_ns, uint64_t now_ns, int side) {
    dm_handle_effect out = {0};
    if (!event_ns || now_ns < event_ns || now_ns - event_ns >= 120000000ull) return out;
    uint64_t age = now_ns - event_ns, delay = side ? 30000000ull : 0;
    if (age < delay || age - delay >= 90000000ull) return out;
    float t = (float)(age - delay) / 90000000.f;
    out.intensity = (side ? 0.18f : 0.16f) * (1 - t) * (1 - t);
    out.sharpness = side ? 0.68f : 0.58f;
    return out;
}
static inline dm_trigger_effect dm_feedback_jump_trigger(uint64_t event_ns, uint64_t now_ns, float held) {
    dm_trigger_effect out = {0};
    if (!isfinite(held) || held < 0.10f || !event_ns || now_ns < event_ns ||
        now_ns - event_ns >= DM_JUMP_TRIGGER_PULSE_NS) return out;
    out.enabled = 1; out.strength = 0.60f;
    return out;
}
