// Device-only mono authored rumble and one-shot verified gameplay events.
// Controller handle and trigger tuning stays in dm_feedback_policy.h.
#pragma once
#include "dm_feedback_policy.h"
#include "odyssey_feedback.h"

enum { DM_DEVICE_HAPTICS_LEASE_NS = 100000000, DM_DEVICE_HAPTICS_HEARTBEAT_NS = 150000000,
       DM_DEVICE_HAPTICS_TRANSIENT_WINDOW_NS = 45000000,
       DM_DEVICE_HAPTICS_TRANSIENT_SPACING_NS = 50000000 };
typedef struct {
    uint64_t generation, armed_ns, native_epoch, cue_ns, cue_sequence;
    uint64_t cue_at[12], cue_identity[12];
    uint64_t played_identity[12], transient_at;
    dm_odyssey_feedback_kind cue_kind;
    unsigned supported, foreground, controller, with_controller, level, live;
} dm_device_haptics_policy;

static inline int dm_device_haptics_eligible(const dm_device_haptics_policy *s) {
    return s->supported && s->foreground && s->level && (!s->controller || s->with_controller);
}
// Invalidate pending output and all asynchronous engine callbacks. Enabling,
// changing sinks, recovering from a stall or an engine failure needs new native
// output after this boundary; a latched pre-transition value never replays.
static inline void dm_device_haptics_reset(dm_device_haptics_policy *s, uint64_t now) {
    ++s->generation; s->armed_ns = now; s->cue_ns = s->cue_sequence = 0; s->cue_kind = 0; s->live = 0;
    s->transient_at=0;
    for (int i=0;i<12;i++) s->cue_at[i]=s->cue_identity[i]=s->played_identity[i]=0;
}
static inline void dm_device_haptics_observe_cue(dm_device_haptics_policy *s,
                                                dm_odyssey_feedback_event event, uint64_t now) {
    if (!dm_device_haptics_eligible(s) || !s->live || !event.sequence ||
        event.timestamp_ns <= s->armed_ns || event.timestamp_ns > now ||
        now - event.timestamp_ns >= 90000000ull ||
        event.kind < DM_ODYSSEY_LONG_JUMP || event.kind > DM_ODYSSEY_GROUND_POUND_IMPACT) return;
    unsigned kind=(unsigned)event.kind;
    if (event.sequence<=s->cue_identity[kind]||event.timestamp_ns<s->cue_at[kind]) return;
    s->cue_at[kind]=event.timestamp_ns;s->cue_identity[kind]=event.sequence;
    if (event.timestamp_ns>=s->cue_ns) { s->cue_ns=event.timestamp_ns;s->cue_kind=event.kind; }
    if (event.sequence>s->cue_sequence) s->cue_sequence=event.sequence;
}
// One discrete tap per verified game-state transition. These values are never
// sampled into a continuous envelope, renewed by a held button, or replayed.
static inline dm_handle_effect dm_device_haptics_cue(dm_odyssey_feedback_kind kind,
        uint64_t at, uint64_t now, unsigned level) {
    dm_handle_effect out={0};
    if (!at||now<at||now-at>=DM_DEVICE_HAPTICS_TRANSIENT_WINDOW_NS||!level) return out;
    out.sharpness=.95f;
    switch (kind) {
        case DM_ODYSSEY_LONG_JUMP: case DM_ODYSSEY_ROLLING_JUMP:
            out.intensity=.17f; break;
        case DM_ODYSSEY_BACKFLIP: out.intensity=.17f; break;
        case DM_ODYSSEY_WALL_JUMP: out.intensity=.18f; break;
        case DM_ODYSSEY_SIDE_FLIP: out.intensity=.16f; break;
        case DM_ODYSSEY_NORMAL_JUMP: out.intensity=.17f; break;
        case DM_ODYSSEY_LANDING: out.intensity=.16f; out.sharpness=.90f; break;
        case DM_ODYSSEY_CAP_THROW: out.intensity=.15f; break;
        case DM_ODYSSEY_COIN: out.intensity=.10f; out.sharpness=1; break;
        case DM_ODYSSEY_GROUND_POUND_START: out.intensity=.10f; break;
        case DM_ODYSSEY_GROUND_POUND_IMPACT: out.intensity=.20f; out.sharpness=.90f; break;
        default: return out;
    }
    return out;
}
typedef struct {
    dm_handle_effect effect;
    uint64_t sequence;
    dm_odyssey_feedback_kind kind;
} dm_device_haptics_transient;
// Consume all newly admitted identities even when suppressed. Never queue an
// old impact behind native rumble, a coin burst, a pause or a controller change.
// Strong authored output wins; supplemental events cannot double a felt effect.
static inline dm_device_haptics_transient dm_device_haptics_take_transient(
        dm_device_haptics_policy *s, float native_intensity, uint64_t now) {
    dm_device_haptics_transient result={0};
    for (int kind=DM_ODYSSEY_LONG_JUMP;kind<=DM_ODYSSEY_GROUND_POUND_IMPACT;kind++) {
        uint64_t identity=s->cue_identity[kind];
        if (!identity||identity==s->played_identity[kind]) continue;
        s->played_identity[kind]=identity;
        dm_handle_effect cue=dm_device_haptics_cue(kind,s->cue_at[kind],now,s->level);
        if (cue.intensity>result.effect.intensity)
            result=(dm_device_haptics_transient){cue,identity,kind};
    }
    if (!dm_device_haptics_eligible(s)||!s->live||native_intensity>=.055f||
        (s->transient_at&&(now<s->transient_at||now-s->transient_at<DM_DEVICE_HAPTICS_TRANSIENT_SPACING_NS)))
        return (dm_device_haptics_transient){0};
    if (result.kind) s->transient_at=now;
    return result;
}
static inline dm_handle_effect dm_device_haptics_effect(dm_device_haptics_policy *s,
        const dm_feedback_native_output *native, uint64_t frame_at, uint64_t now) {
    dm_handle_effect result = {0};
    if (native->epoch != s->native_epoch) {
        s->native_epoch = native->epoch; dm_device_haptics_reset(s, now);
    }
    int live = dm_device_haptics_eligible(s) && native->foreground && native->permitted &&
        frame_at > s->armed_ns && now >= frame_at && now - frame_at < DM_DEVICE_HAPTICS_HEARTBEAT_NS;
    if (!live) {
        if (s->live || s->cue_ns) dm_device_haptics_reset(s, now);
        return result;
    }
    s->live = 1;
    for (int side = 0; side < 2; side++) {
        dm_handle_effect value = {0};
        if (native->updated_ns[side] > s->armed_ns && native->updated_ns[side] <= now)
            value = dm_feedback_native_effect(native->value[side], 0.85f);
        // One local actuator: select the stronger composed side, never sum.
        if (value.intensity > result.intensity) result = value;
    }
    float gain = s->level == 1 ? 0.20f : 0.30f, cap = s->level == 1 ? 0.18f : 0.27f;
    result.intensity = dm_feedback_clamp(result.intensity * gain, 0, cap);
    // Continuous playback belongs only to the original authored vibration.
    // Supplemental state transitions use take_transient exactly once instead.
    return result;
}
