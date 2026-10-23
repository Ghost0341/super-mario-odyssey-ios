// Concurrent callback, SDK writer, output poll and lifecycle stress. Run with
// ThreadSanitizer; the portable transport must never expose a torn ABI state.
#include "dm_feedback.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>

static _Atomic uint64_t time_ns = 1000000000;
static uint64_t tick(void) { return atomic_fetch_add(&time_ns, 100000) + 100000; }
static void *producer(void *unused) {
    (void)unused;
    const double acc[3] = {0, 0, -1}, gyro[3] = {0, .1, 0};
    for (int i = 0; i < 20000; i++) {
        dm_feedback_output state; dm_feedback_poll(tick(), &state);
        dm_feedback_motion_push(state.motion_epoch, acc, gyro, NULL, tick());
    }
    return NULL;
}
static void *sdk(void *unused) {
    (void)unused;
    const uint32_t h[2] = {3, 0x10003};
    for (int i = 0; i < 20000; i++) {
        float a = (i % 100) / 100.f;
        dm_vibration_value v[2] = {{a, 160, a, 320}, {a, 160, a, 320}};
        dm_feedback_vibration_send_many(h, v, 2, tick());
        dm_six_axis_state s[16];
        int n = dm_feedback_six_read(0x20003, s, 16, tick());
        assert(n >= 0 && n <= 16);
        for (int j = 1; j < n; j++) assert(s[j-1].sampling-s[j].sampling == 1);
    }
    return NULL;
}
static void *lifecycle(void *unused) {
    (void)unused;
    for (int i = 0; i < 2000; i++) {
        dm_feedback_set_device(i & 1, !(i % 3), 7, tick());
        dm_feedback_motion_begin(i & 1);
        dm_feedback_game_tick(tick());
    }
    return NULL;
}
int main(void) {
    dm_feedback_set_device(1, 1, 7, tick()); dm_feedback_six_start(0x20003);
    pthread_t a,b,c;
    assert(!pthread_create(&a, NULL, producer, NULL));
    assert(!pthread_create(&b, NULL, sdk, NULL));
    assert(!pthread_create(&c, NULL, lifecycle, NULL));
    uint64_t last_epoch = 0, last_samples = 0;
    for (int i = 0; i < 20000; i++) {
        dm_feedback_output out; dm_feedback_poll(tick(), &out);
        assert(out.epoch >= last_epoch && out.motion_samples >= last_samples);
        last_epoch = out.epoch; last_samples = out.motion_samples;
        for (int j = 0; j < 2; j++) {
            assert(isfinite(out.value[j].amp_low) && out.value[j].amp_low >= 0 && out.value[j].amp_low <= 1);
            assert(isfinite(out.value[j].freq_high));
            assert(out.connected && out.foreground || (out.value[j].amp_low == 0 && out.value[j].amp_high == 0));
        }
    }
    pthread_join(a, NULL); pthread_join(b, NULL); pthread_join(c, NULL);
    puts("feedback concurrent stress passed");
    return 0;
}
