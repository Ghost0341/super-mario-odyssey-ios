// Portable physical-feedback tests. No controller, game data or platform API is
// needed. Expected ABI offsets, handles, units and lease boundaries are explicit.
#include "dm_feedback.h"
#include <assert.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

static int checks;
#define CHECK(c) do { ++checks; if (!(c)) { fprintf(stderr, "failed line %d: %s\n", __LINE__, #c); return 1; } } while (0)
static int near(float a, float b) { return fabsf(a-b) < 0.00001f; }
static int silent(const dm_vibration_value *v) { return v->amp_low == 0 && v->amp_high == 0; }
int main(void) {
    const uint64_t t = 1000000000;
    const double acc[3] = {0, 0, -1}, still[3] = {0, 0, 0}, rotate[3] = {0, 0, 6.2831853071795864769};
    uint32_t h[3] = {0xaaaaaaaa, 0xbbbbbbbb, 0xcccccccc};
    CHECK(sizeof(dm_six_axis_state) == 0x60);
    CHECK(offsetof(dm_six_axis_state, delta_ns) == 0 && offsetof(dm_six_axis_state, sampling) == 8);
    CHECK(offsetof(dm_six_axis_state, acc) == 0x10 && offsetof(dm_six_axis_state, gyro) == 0x1c);
    CHECK(offsetof(dm_six_axis_state, angle) == 0x28 && offsetof(dm_six_axis_state, dir) == 0x34);
    CHECK(offsetof(dm_six_axis_state, attributes) == 0x58 && offsetof(dm_six_axis_state, reserved) == 0x5c);
    CHECK(dm_feedback_vibration_handles(h, 3, 0, 1, 0) == 2);
    CHECK(h[0] == 0x00000003 && h[1] == 0x00010003 && h[2] == 0xcccccccc);
    CHECK(dm_feedback_vibration_handles(h, 1, 0x20, 2, 0x20) == 1 && h[0] == 0x00002004);
    CHECK(dm_feedback_vibration_handles(h, 2, 1, 1, 0) == 0);
    CHECK(dm_feedback_vibration_handles(h, 2, 0, 2, 0) == 0);
    CHECK(dm_feedback_vibration_handles(h, -1, 0, 1, 0) == 0);
    CHECK(dm_feedback_six_handles(h, 3, 0, 1, 0) == 1 && h[0] == 0x00020003);
    CHECK(dm_feedback_six_handles(h, 1, 0x20, 2, 0x20) == 1 && h[0] == 0x00022004);
    dm_vibration_info info;
    dm_feedback_vibration_info(3, &info); CHECK(info.type == 1 && info.position == 1);
    dm_feedback_vibration_info(0x10003, &info); CHECK(info.type == 1 && info.position == 2);
    dm_feedback_vibration_info(0xff000003, &info); CHECK(info.type == 0 && info.position == 0);
    dm_feedback_vibration_info(0x103, &info); CHECK(info.type == 0 && info.position == 0);

    uint64_t e = dm_feedback_set_device(1, 1, 7, t);
    CHECK(e == dm_feedback_epoch());
    CHECK(dm_feedback_set_device(1, 1, 7, t+1) == e);
    dm_vibration_value v[2] = {{0.25f, 100, 0.75f, 500}, {0.5f, 200, 0.125f, 300}}, got;
    uint32_t vh[2] = {3, 0x10003};
    CHECK(dm_feedback_vibration_send_many(vh, v, 2, t+10));
    dm_feedback_output out;
    dm_feedback_poll(t+10, &out);
    CHECK(out.epoch == e && out.connected && out.foreground && out.capabilities == 7);
    CHECK(!memcmp(&out.value[0], &v[0], sizeof got) && !memcmp(&out.value[1], &v[1], sizeof got));
    CHECK(out.updated_ns[0] == t+10 && out.updated_ns[1] == t+10);
    dm_feedback_vibration_actual(3, &got, t+11); CHECK(!memcmp(&got, &v[0], sizeof got));
    CHECK(!dm_feedback_vibration_send_many(vh, v, 17, t+12));
    CHECK(!dm_feedback_vibration_send_many(NULL, v, 1, t+12));
    CHECK(!dm_feedback_vibration_send_many(vh, v, -1, t+12));
    CHECK(dm_feedback_vibration_send_many(NULL, NULL, 0, t+12));
    dm_feedback_vibration_permit(0); CHECK(!dm_feedback_vibration_permitted());
    dm_feedback_poll(t+13, &out); CHECK(silent(&out.value[0]) && silent(&out.value[1]));
    dm_feedback_vibration_permit(1); CHECK(dm_feedback_vibration_permitted());
    dm_feedback_poll(t+14, &out); CHECK(silent(&out.value[0]));
    CHECK(dm_feedback_vibration_send_many(vh, v, 2, t+10));
    dm_feedback_poll(t+250000011, &out); CHECK(silent(&out.value[0]) && silent(&out.value[1]));
    dm_feedback_game_tick(t+1000000000);
    dm_feedback_poll(t+1000000001, &out); CHECK(near(out.value[0].amp_low, .25f));
    dm_feedback_poll(t+1250000001, &out); CHECK(silent(&out.value[0]));
    dm_vibration_value unsafe = {-1, -1, 2, 99999};
    dm_feedback_vibration_send(3, &unsafe, t+2);
    dm_feedback_vibration_actual(3, &got, t+3);
    CHECK(got.amp_low == 0 && got.freq_low == 40 && got.amp_high == 1 && got.freq_high == 1253);
    unsafe.amp_low = NAN;
    dm_feedback_vibration_send(3, &unsafe, t+4); dm_feedback_vibration_actual(3, &got, t+5);
    CHECK(silent(&got) && got.freq_low == 160 && got.freq_high == 320);
    dm_feedback_vibration_send(0x20003, &v[0], t+6); dm_feedback_vibration_actual(3, &got, t+7); CHECK(silent(&got));

    dm_six_axis_state states[20]; memset(states, 0xff, sizeof states);
    CHECK(dm_feedback_six_read(0x20003, states, 20, t) == 0);
    CHECK(states[0].attributes == 0 && states[0].sampling == 0 && states[0].acc[2] == -1 && states[0].dir[8] == 1);
    dm_feedback_six_start(0x20003);
    CHECK(dm_feedback_motion_push(e, acc, still, NULL, t+100));
    CHECK(dm_feedback_six_read(0x20003, states, 20, t+100) == 1);
    CHECK(states[0].sampling == 1 && states[0].delta_ns == 4000000 && states[0].attributes == 1);
    CHECK(states[0].acc[2] == -1 && states[0].dir[0] == 1 && states[0].dir[4] == 1 && states[0].dir[8] == 1);
    CHECK(dm_feedback_six_at_rest(0x20003, t+100));
    int64_t sample = states[0].sampling;
    CHECK(dm_feedback_six_read(0x20003, states, 1, t+101) == 1 && states[0].sampling == sample);
    CHECK(!dm_feedback_motion_push(e, acc, still, NULL, t+100));
    CHECK(dm_feedback_motion_push(e, acc, rotate, NULL, t+10000100));
    CHECK(dm_feedback_six_read(0x20003, states, 20, t+10000100) == 2);
    CHECK(states[0].sampling == 2 && states[1].sampling == 1 && states[0].delta_ns == 10000000);
    CHECK(near(states[0].gyro[2], 1) && near(states[0].angle[2], 0.01f));
    CHECK(near(states[0].dir[0], 0.998026728f) && near(states[0].dir[1], 0.062790520f));
    CHECK(!dm_feedback_six_at_rest(0x20003, t+10000100));
    CHECK(dm_feedback_six_read(0x20003, states, 2, t+210000101) == 0 && states[0].attributes == 0);
    CHECK(dm_feedback_motion_push(e, acc, still, NULL, t+220000000));
    CHECK(dm_feedback_six_read(0x20003, states, 2, t+220000000) == 1 && states[0].sampling == 3);
    CHECK(states[0].angle[2] == 0 && states[0].dir[0] == 1);
    double bad_acc[3] = {NAN, 0, -1};
    CHECK(!dm_feedback_motion_push(e, bad_acc, still, NULL, t+221000000));
    dm_feedback_six_stop(0x20003); CHECK(dm_feedback_six_read(0x20003, states, 1, t+220000001) == 0);
    dm_feedback_six_start(0x20003);
    const double q[4] = {0, 0, 1, 1};
    CHECK(dm_feedback_motion_push(e, acc, still, q, t+230000000));
    CHECK(dm_feedback_six_read(0x20003, states, 1, t+230000001) == 1);
    CHECK(near(states[0].dir[0], 0) && near(states[0].dir[1], 1) && near(states[0].dir[3], -1));
    for (int i = 1; i <= 100; i++) CHECK(dm_feedback_motion_push(e, acc, still, NULL, t+230000000+i*4000000ull));
    CHECK(dm_feedback_six_read(0x20003, states, 20, t+630000000) == 16);
    for (int i = 1; i < 16; i++) CHECK(states[i-1].sampling-states[i].sampling == 1);
    CHECK(dm_feedback_six_read(0x000003, states, 2, t+630000001) == 0);
    dm_feedback_six_set_fusion(0x20003, 0); CHECK(!dm_feedback_six_fusion(0x20003));
    dm_feedback_six_set_fusion(0x20003, 1); CHECK(dm_feedback_six_fusion(0x20003));
    dm_feedback_six_set_drift(0x20003, 2); CHECK(dm_feedback_six_drift(0x20003) == 2);
    dm_feedback_six_set_drift(0x20003, 99); CHECK(dm_feedback_six_drift(0x20003) == 2);
    float a, b; dm_feedback_six_set_fusion_parameters(0x20003, .2f, .3f);
    dm_feedback_six_get_fusion_parameters(0x20003, &a, &b); CHECK(near(a, .2f) && near(b, .3f));

    uint64_t old = e;
    e = dm_feedback_set_device(1, 0, 7, t+640000000); CHECK(e != old);
    CHECK(!dm_feedback_motion_push(old, acc, rotate, NULL, t+641000000));
    CHECK(!dm_feedback_motion_push(e, acc, rotate, NULL, t+641000000));
    CHECK(dm_feedback_six_read(0x20003, states, 1, t+641000000) == 0 && !states[0].attributes);
    dm_feedback_vibration_send(3, &v[0], t+642000000); dm_feedback_game_tick(t+642000000);
    dm_feedback_poll(t+642000001, &out); CHECK(silent(&out.value[0]));
    e = dm_feedback_set_device(1, 1, 7, t+650000000);
    dm_feedback_poll(t+650000001, &out); CHECK(silent(&out.value[0]));
    CHECK(!dm_feedback_motion_push(old, acc, still, NULL, t+651000000));
    CHECK(dm_feedback_motion_push(e, acc, still, NULL, t+651000000));
    CHECK(dm_feedback_six_read(0x20003, states, 1, t+651000001) == 1);
    CHECK(states[0].sampling == 105 && states[0].angle[2] == 0);
    e = dm_feedback_set_device(0, 1, 0, t+660000000);
    dm_feedback_poll(t+660000001, &out); CHECK(!out.connected && !out.capabilities && silent(&out.value[0]));
    CHECK(!dm_feedback_motion_push(e, acc, still, NULL, t+661000000));
    CHECK(dm_feedback_six_read(0x20003, states, 1, t+661000000) == 0);
    dm_feedback_poll(t+661000001, &out);
    printf("transport counters: sends=%llu reads=%llu states=%llu\n", (unsigned long long)out.vibration_sends, (unsigned long long)out.motion_reads, (unsigned long long)out.motion_states_returned);
    CHECK(out.vibration_sends == 7 && out.motion_reads >= 15 && out.motion_states_returned > out.motion_reads);
    printf("feedback: %d checks passed\n", checks);
    return 0;
}
