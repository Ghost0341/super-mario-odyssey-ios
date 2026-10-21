// Hardware-independent checks for native texture conversion and event-only kicks.
#include "../dm_feedback_policy.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    dm_handle_effect none = dm_feedback_native_effect((dm_vibration_value){0, 0, 0, 0}, 0.85f);
    assert(none.intensity == 0);
    dm_handle_effect low = dm_feedback_native_effect((dm_vibration_value){0.2f, 80, 0, 320}, 0.85f);
    dm_handle_effect high = dm_feedback_native_effect((dm_vibration_value){0, 160, 0.2f, 640}, 0.85f);
    assert(low.intensity > 0 && high.intensity > 0 && high.sharpness > low.sharpness);
    assert(fabsf(high.intensity - low.intensity) < 0.00001f);
    dm_handle_effect loud = dm_feedback_native_effect((dm_vibration_value){1, 160, 1, 320}, 0.85f);
    assert(loud.intensity <= 0.9f);
    assert(dm_feedback_native_effect((dm_vibration_value){NAN, 160, 1, 320}, 1).intensity == 0);
    assert(dm_feedback_native_effect((dm_vibration_value){1, -1, 0, 320}, 1).intensity == 0);
    assert(dm_feedback_native_effect((dm_vibration_value){0.4f, 160, 0, 320}, 0).intensity == 0);
    uint64_t event = 1000000000ull;
    assert(!dm_feedback_jump_trigger(0, event, 1).enabled); // held trigger cannot invent a jump
    assert(!dm_feedback_jump_trigger(event, event - 1, 1).enabled);
    assert(!dm_feedback_jump_trigger(event, event, 0).enabled);
    assert(!dm_feedback_jump_trigger(event, event, NAN).enabled);
    assert(dm_feedback_jump_trigger(event, event, 0.5f).enabled);
    assert(dm_feedback_jump_trigger(event, event + DM_JUMP_TRIGGER_PULSE_NS - 1, 1).enabled);
    assert(!dm_feedback_jump_trigger(event, event + DM_JUMP_TRIGGER_PULSE_NS, 1).enabled);
    assert(!dm_feedback_jump_trigger(event, event + 1000000000ull, 1).enabled);
    dm_handle_effect start = dm_feedback_long_jump(event, event, 0);
    dm_handle_effect tail = dm_feedback_long_jump(event, event + 45000000, 0);
    assert(start.intensity > tail.intensity && tail.intensity > 0);
    assert(dm_feedback_long_jump(event, event + 90000000, 0).intensity == 0);
    assert(dm_feedback_backflip(0, event, 0).intensity == 0);
    assert(dm_feedback_backflip(event, event - 1, 0).intensity == 0);
    dm_handle_effect lift = dm_feedback_backflip(event, event, 0);
    dm_handle_effect release = dm_feedback_backflip(event, event + 45000000, 0);
    assert(lift.intensity > release.intensity && release.intensity > 0);
    assert(release.sharpness > lift.sharpness);
    assert(dm_feedback_backflip(event, event + 119999999, 1).intensity >= 0);
    assert(dm_feedback_backflip(event, event + 120000000, 1).intensity == 0);
    // Backflip texture is bounded and finite throughout both phases.
    for (uint64_t age = 0; age < 140000000; age += 1000000) {
        for (int side = 0; side < 2; side++) {
            dm_handle_effect v = dm_feedback_backflip(event, event + age, side);
            assert(isfinite(v.intensity) && v.intensity >= 0 && v.intensity <= 0.18f);
            assert(isfinite(v.sharpness) && v.sharpness >= 0 && v.sharpness <= 1);
        }
    }
    assert(dm_feedback_wall_jump(0, event, 0).intensity == 0);
    assert(dm_feedback_wall_jump(event, event - 1, 0).intensity == 0);
    assert(dm_feedback_wall_jump(event, event + 32000000, 0).intensity == 0);
    assert(dm_feedback_wall_jump(event, event + 35000000, 0).intensity > 0);
    assert(dm_feedback_wall_jump(event, event + 85000000, 0).intensity == 0);
    assert(dm_feedback_wall_jump(event, event, 0).sharpness > lift.sharpness);
    assert(dm_feedback_side_flip(0, event, 0).intensity == 0);
    assert(dm_feedback_side_flip(event, event - 1, 0).intensity == 0);
    assert(dm_feedback_side_flip(event, event, 0).intensity > 0);
    assert(dm_feedback_side_flip(event, event, 1).intensity == 0);
    assert(dm_feedback_side_flip(event, event + 30000000, 1).intensity >
           dm_feedback_side_flip(event, event + 30000000, 0).intensity);
    assert(dm_feedback_side_flip(event, event + 120000000, 1).intensity == 0);
    for (uint64_t age = 0; age < 150000000; age += 1000000) {
        for (int side = 0; side < 2; side++) {
            dm_handle_effect w = dm_feedback_wall_jump(event, event + age, side);
            dm_handle_effect s = dm_feedback_side_flip(event, event + age, side);
            assert(isfinite(w.intensity) && w.intensity >= 0 && w.intensity <= 0.22f);
            assert(isfinite(s.intensity) && s.intensity >= 0 && s.intensity <= 0.18f);
            assert(w.sharpness >= 0 && w.sharpness <= 1 && s.sharpness >= 0 && s.sharpness <= 1);
        }
    }
    puts("feedback policy: native bands, bounded backflip/wall/side textures, and event-only trigger kick passed");
    return 0;
}
