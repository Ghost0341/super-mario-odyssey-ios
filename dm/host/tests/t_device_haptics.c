// Device-local signal/lifecycle regression checks using synthetic native values.
#include "dm_device_haptics_policy.h"
#include <stdio.h>
#include <string.h>

static int checks;
#define CHECK(c) do { ++checks; if (!(c)) { fprintf(stderr, "failed line %d: %s\n", __LINE__, #c); return 1; } } while (0)
static int near(float a, float b) { return fabsf(a - b) < 0.00001f; }
static int silent(dm_handle_effect e) { return e.intensity == 0; }

int main(void) {
    const uint64_t t = 1000000000ull;
    dm_device_haptics_policy s = {.supported=1, .foreground=1, .level=1};
    dm_device_haptics_reset(&s, t);
    CHECK(dm_device_haptics_eligible(&s));
    dm_feedback_set_device(0, 1, 0, t); // touch-only; never fabricate a controller
    dm_feedback_native_output native; dm_feedback_native_poll(&native);
    dm_handle_effect effect = dm_device_haptics_effect(&s, &native, t+1, t+1);
    CHECK(silent(effect)); // transport epoch and activation boundary
    CHECK(s.armed_ns == t+1 && s.generation == 2);
    dm_vibration_value v = {.amp_low=.5f, .freq_low=160, .amp_high=.25f, .freq_high=320};
    dm_feedback_vibration_send(3, &v, t+2);
    dm_feedback_native_poll(&native);
    effect = dm_device_haptics_effect(&s, &native, t+3, t+4);
    CHECK(s.live && effect.intensity > 0 && effect.intensity < .18f);
    CHECK(near(effect.intensity, hypotf(.5f, .25f) * .85f * .20f));
    dm_feedback_output controller;
    dm_feedback_poll(t+4, &controller);
    CHECK(!controller.connected && !controller.capabilities);
    CHECK(controller.value[0].amp_low == 0 && controller.value[1].amp_high == 0);

    // Native stereo is combined by maximum, not summed; texture survives.
    native.value[1] = native.value[0]; native.updated_ns[1] = t+2;
    dm_handle_effect mono = dm_device_haptics_effect(&s, &native, t+3, t+5);
    CHECK(near(mono.intensity, effect.intensity) && near(mono.sharpness, effect.sharpness));
    native.value[0] = native.value[1] = (dm_vibration_value){1, 1250, 1, 1250};
    effect = dm_device_haptics_effect(&s, &native, t+3, t+6);
    CHECK(near(effect.intensity, .18f) && near(effect.sharpness, 1));
    s.level = 2;
    effect = dm_device_haptics_effect(&s, &native, t+3, t+7);
    CHECK(near(effect.intensity, .27f));
    s.level = 1;

    // No local double feedback with a controller unless explicitly requested.
    s.controller = 1; dm_device_haptics_reset(&s, t+10);
    native.updated_ns[0] = native.updated_ns[1] = t+11;
    CHECK(!dm_device_haptics_eligible(&s));
    CHECK(silent(dm_device_haptics_effect(&s, &native, t+12, t+13)));
    s.with_controller = 1;
    CHECK(dm_device_haptics_eligible(&s));
    CHECK(dm_device_haptics_effect(&s, &native, t+12, t+13).intensity > 0);

    // Hardware unsupported, Off, foreground loss, and permit loss all silence.
    s.supported = 0;
    CHECK(silent(dm_device_haptics_effect(&s, &native, t+14, t+15)));
    s.supported = 1; s.level = 0;
    CHECK(silent(dm_device_haptics_effect(&s, &native, t+16, t+17)));
    s.level = 1; s.foreground = 0;
    CHECK(silent(dm_device_haptics_effect(&s, &native, t+18, t+19)));
    s.foreground = 1; native.foreground = 0;
    CHECK(silent(dm_device_haptics_effect(&s, &native, t+20, t+21)));
    native.foreground = 1; native.permitted = 0;
    CHECK(silent(dm_device_haptics_effect(&s, &native, t+22, t+23)));
    native.permitted = 1;
    CHECK(silent(dm_device_haptics_effect(&s, &native, t+24, t+25))); // no replay of pre-disable output
    native.updated_ns[0] = native.updated_ns[1] = t+26;
    CHECK(dm_device_haptics_effect(&s, &native, t+27, t+28).intensity > 0);
    uint64_t generation = s.generation;
    CHECK(silent(dm_device_haptics_effect(&s, &native, t+27, t+27+DM_DEVICE_HAPTICS_HEARTBEAT_NS)));
    CHECK(s.generation > generation && !s.live);
    CHECK(silent(dm_device_haptics_effect(&s, &native, t+200000000, t+200000001))); // resumed frame, stale latched value
    native.updated_ns[0] = native.updated_ns[1] = t+200000002;
    CHECK(dm_device_haptics_effect(&s, &native, t+200000003, t+200000004).intensity > 0);
    CHECK(silent(dm_device_haptics_effect(&s, &native, t+200000006, t+200000005))); // future heartbeat

    // Fresh foreground frames may sustain an authored loop without new sends.
    native.updated_ns[0] = native.updated_ns[1] = t+300000000;
    for (unsigned frame = 1; frame <= 100; frame++) {
        uint64_t now = t+300000000+(uint64_t)frame*16000000;
        CHECK(dm_device_haptics_effect(&s, &native, now, now).intensity > 0);
    }
    native.value[0] = native.value[1] = (dm_vibration_value){0, 160, 0, 320};
    CHECK(silent(dm_device_haptics_effect(&s, &native, t+1900000001, t+1900000001))); // explicit native stop

    // A cue is a discrete verified game-state event. Fresh frames alone (or a
    // held input with no new state callback) must never manufacture feedback.
    uint64_t at=t+2000000000;
    s.controller=0;s.with_controller=0;
    for (int kind=DM_ODYSSEY_LONG_JUMP;kind<=DM_ODYSSEY_GROUND_POUND_IMPACT;kind++) {
        dm_device_haptics_reset(&s,at-1);
        CHECK(silent(dm_device_haptics_effect(&s,&native,at,at)));
        for (unsigned frame=0;frame<20;frame++)
            CHECK(!dm_device_haptics_take_transient(&s,0,at+frame*1000000ull).kind);
        dm_odyssey_feedback_event event={.sequence=(uint64_t)kind,.timestamp_ns=at+20000000,.kind=kind,.strength=1};
        dm_device_haptics_observe_cue(&s,event,at+20000000);
        CHECK(silent(dm_device_haptics_effect(&s,&native,at+20000000,at+20000000)));
        dm_device_haptics_transient cue=dm_device_haptics_take_transient(&s,0,at+20000000);
        CHECK(cue.kind==(dm_odyssey_feedback_kind)kind&&cue.sequence==(uint64_t)kind);
        CHECK(cue.effect.intensity>=.10f&&cue.effect.intensity<=.20f&&cue.effect.sharpness>=.90f);
        for (unsigned frame=1;frame<100;frame++) {
            uint64_t now=at+20000000+frame*1000000ull;
            dm_device_haptics_observe_cue(&s,event,now); // duplicate delivery cannot repeat
            CHECK(!dm_device_haptics_take_transient(&s,0,now).kind);
            CHECK(silent(dm_device_haptics_effect(&s,&native,now,now)));
        }
        at+=300000000;
    }
    CHECK(near(dm_feedback_long_jump(at,at,0).intensity,.09f)); // accepted controller unchanged
    CHECK(silent(dm_device_haptics_cue(DM_ODYSSEY_LONG_JUMP,at,at,0)));
    CHECK(silent(dm_device_haptics_cue(DM_ODYSSEY_LONG_JUMP,at,at+45000000,1)));
    CHECK(silent(dm_device_haptics_cue(DM_ODYSSEY_LONG_JUMP,at,at-1,1)));

    // Higher-priority authored rumble wins. Suppressed extras are consumed;
    // they cannot appear late when the native effect stops.
    dm_device_haptics_reset(&s,at-1);
    CHECK(silent(dm_device_haptics_effect(&s,&native,at,at)));
    dm_device_haptics_observe_cue(&s,(dm_odyssey_feedback_event){.sequence=200,.timestamp_ns=at,.kind=DM_ODYSSEY_CAP_THROW},at);
    CHECK(!dm_device_haptics_take_transient(&s,.18f,at).kind);
    CHECK(!dm_device_haptics_take_transient(&s,0,at+1).kind);
    CHECK(s.played_identity[DM_ODYSSEY_CAP_THROW]==200);

    // Same-frame events select the strongest tap, never add or queue a buzz.
    at+=200000000;dm_device_haptics_reset(&s,at-1);
    CHECK(silent(dm_device_haptics_effect(&s,&native,at,at)));
    dm_device_haptics_observe_cue(&s,(dm_odyssey_feedback_event){.sequence=302,.timestamp_ns=at,.kind=DM_ODYSSEY_COIN},at);
    dm_device_haptics_observe_cue(&s,(dm_odyssey_feedback_event){.sequence=301,.timestamp_ns=at,.kind=DM_ODYSSEY_GROUND_POUND_IMPACT},at);
    dm_device_haptics_transient cue=dm_device_haptics_take_transient(&s,0,at);
    CHECK(cue.kind==DM_ODYSSEY_GROUND_POUND_IMPACT&&near(cue.effect.intensity,.20f));
    CHECK(!dm_device_haptics_take_transient(&s,0,at+1).kind);
    CHECK(s.played_identity[DM_ODYSSEY_COIN]==302&&s.played_identity[DM_ODYSSEY_GROUND_POUND_IMPACT]==301);
    dm_device_haptics_observe_cue(&s,(dm_odyssey_feedback_event){.sequence=303,.timestamp_ns=at+10000000,.kind=DM_ODYSSEY_COIN},at+10000000);
    CHECK(!dm_device_haptics_take_transient(&s,0,at+10000000).kind);
    CHECK(!dm_device_haptics_take_transient(&s,0,at+60000000).kind); // rate-limited event never replays
    dm_device_haptics_observe_cue(&s,(dm_odyssey_feedback_event){.sequence=304,.timestamp_ns=at+60000000,.kind=DM_ODYSSEY_COIN},at+60000000);
    CHECK(dm_device_haptics_take_transient(&s,0,at+60000000).kind==DM_ODYSSEY_COIN);

    // A delayed admitted event expires. Future, pre-activation and unknown
    // callback records cannot arm output, and lifecycle reset discards pending.
    at+=200000000;dm_device_haptics_reset(&s,at-1);
    CHECK(silent(dm_device_haptics_effect(&s,&native,at,at)));
    dm_device_haptics_observe_cue(&s,(dm_odyssey_feedback_event){.sequence=400,.timestamp_ns=at,.kind=DM_ODYSSEY_NORMAL_JUMP},at);
    CHECK(!dm_device_haptics_take_transient(&s,0,at+45000000).kind);
    uint64_t previous=s.cue_sequence;
    dm_device_haptics_observe_cue(&s,(dm_odyssey_feedback_event){.sequence=401,.timestamp_ns=at+2,.kind=1},at+1);
    dm_device_haptics_observe_cue(&s,(dm_odyssey_feedback_event){.sequence=401,.timestamp_ns=at-90000000,.kind=1},at);
    dm_device_haptics_observe_cue(&s,(dm_odyssey_feedback_event){.sequence=401,.timestamp_ns=at,.kind=99},at);
    CHECK(s.cue_sequence==previous);
    generation=s.generation;dm_device_haptics_reset(&s,at+1);
    CHECK(s.generation>generation&&!s.cue_ns&&!s.live);
    CHECK(!dm_device_haptics_take_transient(&s,0,at+2).kind);
    dm_device_haptics_observe_cue(&s,(dm_odyssey_feedback_event){.sequence=402,.timestamp_ns=at,.kind=1},at+2);
    CHECK(!s.cue_ns);

    // Felt-positive capture and quiet native textures keep their original
    // continuous mapping, independent of the supplemental transient policy.
    at+=200000000;dm_device_haptics_reset(&s,at-1);
    native.value[0]=(dm_vibration_value){1,160,1,320};native.updated_ns[0]=at;
    effect=dm_device_haptics_effect(&s,&native,at,at);CHECK(near(effect.intensity,.18f));
    dm_device_haptics_observe_cue(&s,(dm_odyssey_feedback_event){.sequence=500,.timestamp_ns=at,.kind=DM_ODYSSEY_COIN},at);
    CHECK(!dm_device_haptics_take_transient(&s,effect.intensity,at).kind);
    CHECK(near(dm_device_haptics_effect(&s,&native,at,at).intensity,.18f));
    at+=200000000;dm_device_haptics_reset(&s,at-1);
    native.value[0]=(dm_vibration_value){.01f,160,0,320};native.updated_ns[0]=at;
    effect=dm_device_haptics_effect(&s,&native,at,at);CHECK(effect.intensity>0&&effect.intensity<.002f);

    // Real permit toggles clear native values; the local read is non-consuming
    // and cannot change an attached controller's values, sequences or motion.
    dm_feedback_set_device(1, 1, 3, at);
    dm_feedback_vibration_send(3, &v, at+1);
    dm_feedback_poll(at+2, &controller);
    dm_feedback_native_poll(&native);
    dm_feedback_output after; dm_feedback_poll(at+2, &after);
    CHECK(!memcmp(&controller, &after, sizeof after));
    CHECK(near(native.value[0].amp_low, .5f));
    native.value[0].amp_low = 0; // modifying the local copy cannot change host state
    dm_feedback_poll(at+2, &after); CHECK(near(after.value[0].amp_low, .5f));
    dm_feedback_vibration_permit(0); dm_feedback_native_poll(&native);
    CHECK(!native.permitted && native.value[0].amp_low == 0);
    dm_feedback_vibration_permit(1); dm_feedback_native_poll(&native);
    CHECK(native.permitted && native.value[0].amp_low == 0);
    CHECK(DM_DEVICE_HAPTICS_LEASE_NS == 100000000);
    printf("PASS: %d device-local feedback checks\n", checks);
    return 0;
}
