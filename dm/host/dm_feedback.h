// Portable controller feedback transport. Framework callbacks publish physical samples;
// nn::hid consumes SDK-shaped states, and the front end polls native rumble bands.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    DM_FEEDBACK_RUMBLE_LEFT = 1u << 0,
    DM_FEEDBACK_RUMBLE_RIGHT = 1u << 1,
    DM_FEEDBACK_MOTION = 1u << 2,
    DM_FEEDBACK_MOTION_MAX = 16
};
typedef struct { float amp_low, freq_low, amp_high, freq_high; } dm_vibration_value;
typedef struct { uint32_t type, position; } dm_vibration_info;
// SDK 7 SixAxisSensorState: acceleration in G, angular velocity / angle in
// revolutions per second / revolutions, direction vectors of the controller axes.
typedef struct {
    int64_t delta_ns, sampling;
    float acc[3], gyro[3], angle[3], dir[9];
    uint32_t attributes, reserved;
} dm_six_axis_state;
typedef struct {
    uint64_t epoch;
    unsigned connected, foreground, capabilities;
    dm_vibration_value value[2];
    uint64_t updated_ns[2], sequence[2];
    uint64_t motion_samples, motion_updated_ns;
    uint64_t vibration_sends, motion_reads, motion_states_returned;
    uint64_t motion_epoch;
    unsigned motion_available;
} dm_feedback_output;

// Read-only native signal for a separate device-local sink. It does not claim
// physical controller capabilities or change SDK/controller output. The sink
// must enforce its own foreground, heartbeat, activation and hardware leases.
typedef struct {
    uint64_t epoch;
    unsigned foreground, permitted;
    dm_vibration_value value[2];
    uint64_t updated_ns[2], sequence[2];
} dm_feedback_native_output;
void dm_feedback_native_poll(dm_feedback_native_output *out);

// Every lifecycle/capability transition clears pending output and motion history.
// Capture the returned epoch when binding a motion callback: old callbacks cannot
// publish into a reconnected device. For same-capability controller replacement,
// publish disconnected before publishing the replacement.
uint64_t dm_feedback_set_device(int connected, int foreground, unsigned capabilities, uint64_t now_ns);
uint64_t dm_feedback_epoch(void);
// Independently owned motion, including touch-only device sensors. Each call
// invalidates sensor history/callbacks without changing actuator output.
uint64_t dm_feedback_motion_begin(int enabled);
// Keep a latched native value alive while the game actually presents. Without a
// fresh game tick or a fresh value for 250 ms, physical rumble becomes silent.
void dm_feedback_game_tick(uint64_t now_ns);
void dm_feedback_poll(uint64_t now_ns, dm_feedback_output *out);
// GCMotion controller coordinates: x right, y toward top, z out of face. Include
// gravity (face up: 0,0,-1 G). Angular units are rad/s. Quaternion is optional,
// normalized xyzw, controller-to-reference; NULL enables gyro/gravity fusion.
// Producer timestamps must use the same monotonic clock as poll/game_tick.
int dm_feedback_motion_push(uint64_t epoch, const double accel_g[3], const double angular_rad_s[3],
                            const double quaternion_xyzw[4], uint64_t now_ns);

// SDK adapter entry points. Logical capabilities exist before a physical pad is
// attached, so the game's vibration/motion targets survive reconnects.
int dm_feedback_vibration_handles(uint32_t *out, int max, uint32_t id, uint32_t style, uint32_t connected_id);
int dm_feedback_six_handles(uint32_t *out, int max, uint32_t id, uint32_t style, uint32_t connected_id);
void dm_feedback_vibration_initialize(uint32_t handle);
void dm_feedback_vibration_permit(int permitted);
int dm_feedback_vibration_permitted(void);
void dm_feedback_vibration_send(uint32_t handle, const dm_vibration_value *value, uint64_t now_ns);
int dm_feedback_vibration_send_many(const uint32_t *handles, const dm_vibration_value *values, int count, uint64_t now_ns);
void dm_feedback_vibration_actual(uint32_t handle, dm_vibration_value *out, uint64_t now_ns);
void dm_feedback_vibration_info(uint32_t handle, dm_vibration_info *out);
void dm_feedback_six_start(uint32_t handle);
void dm_feedback_six_stop(uint32_t handle);
int dm_feedback_six_read(uint32_t handle, dm_six_axis_state *out, int max, uint64_t now_ns);
int dm_feedback_six_at_rest(uint32_t handle, uint64_t now_ns);
void dm_feedback_six_set_fusion(uint32_t handle, int enabled);
int dm_feedback_six_fusion(uint32_t handle);
void dm_feedback_six_set_fusion_parameters(uint32_t handle, float gain, float bias);
void dm_feedback_six_get_fusion_parameters(uint32_t handle, float *gain, float *bias);
void dm_feedback_six_set_drift(uint32_t handle, int mode);
int dm_feedback_six_drift(uint32_t handle);

#ifdef __cplusplus
}
#endif
