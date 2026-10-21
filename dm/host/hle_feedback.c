// Native SDK vibration and six-axis transport, shared by all game profiles.
// No platform calls: GameController/CoreHaptics live in the front end.
#include "dm_feedback.h"
#include <math.h>
#include <pthread.h>
#include <stddef.h>
#include <string.h>

_Static_assert(sizeof(dm_vibration_value) == 0x10, "VibrationValue ABI");
_Static_assert(sizeof(dm_vibration_info) == 8, "VibrationDeviceInfo ABI");
_Static_assert(sizeof(dm_six_axis_state) == 0x60, "SixAxisSensorState ABI");
_Static_assert(offsetof(dm_six_axis_state, acc) == 0x10 && offsetof(dm_six_axis_state, dir) == 0x34 &&
               offsetof(dm_six_axis_state, attributes) == 0x58, "SixAxisSensorState field offsets");

enum { STYLE_FULLKEY = 1, STYLE_HANDHELD = 2, SENSOR_CONNECTED = 1, RING_SIZE = 64 };
static const uint64_t output_lease_ns = 250000000, motion_lease_ns = 200000000;
static const double tau = 6.2831853071795864769;
static const dm_vibration_value neutral = {0, 160, 0, 320};
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t epoch = 1, last_game_tick, produced, last_motion_ns;
static uint64_t vibration_sends, motion_reads, motion_states_returned;
static unsigned connected, foreground, capabilities;
static unsigned permitted = 1;
static dm_vibration_value last[2] = {{0, 160, 0, 320}, {0, 160, 0, 320}};
static uint64_t updated[2], sequence[2];
static dm_six_axis_state ring[RING_SIZE];
static unsigned have, started[2], fusion[2] = {1, 1};
static int drift[2] = {1, 1};
static float fusion_parameters[2][2] = {{0.03f, 0.4f}, {0.03f, 0.4f}};
static double rotation[3][3], angles[3];
static int aligned;

static int fresh(uint64_t now, uint64_t then, uint64_t limit) { return then && now >= then && now - then <= limit; }
static float clampf(float x, float lo, float hi) { return x < lo ? lo : x > hi ? hi : x; }
static double norm3(const double v[3]) { return sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]); }
static void cross3(const double a[3], const double b[3], double out[3]) {
    out[0] = a[1]*b[2] - a[2]*b[1]; out[1] = a[2]*b[0] - a[0]*b[2]; out[2] = a[0]*b[1] - a[1]*b[0];
}
// Handle byte 0 is the SDK device type (3 full-key, 4 handheld), byte 1
// the Npad id, byte 2 the actuator/sensor index. Reject unused high bits.
// Verified in Odyssey SDK build fcf93a41b08c5193a1410d262602dc62:
// +0x2426c4/+0x242714 constructs left/right vibration handles; +0x23ab08/
// +0x23ab38 constructs full-key/handheld sensor index 2; +0x235e1c..
// +0x235f04 copies six-axis states in 0x60-byte strides, sampling at +8.
static int handle_style(uint32_t h) {
    if (h & 0xff000000u) return -1;
    unsigned type = h & 255, id = (h >> 8) & 255;
    if (type == 3 && id == 0) return 0;
    if (type == 4 && id == 0x20) return 1;
    return -1;
}
static int vib_side(uint32_t h) { return handle_style(h) >= 0 && ((h >> 16) & 255) < 2 ? (int)((h >> 16) & 255) : -1; }
static int six_style(uint32_t h) { return ((h >> 16) & 255) == 2 ? handle_style(h) : -1; }
static uint32_t handle_base(uint32_t id, uint32_t style, uint32_t current) {
    if (id != current) return 0;
    if (id == 0 && (style & STYLE_FULLKEY)) return 3;
    if (id == 0x20 && (style & STYLE_HANDHELD)) return 4 | (id << 8);
    return 0;
}
int dm_feedback_vibration_handles(uint32_t *out, int max, uint32_t id, uint32_t style, uint32_t current) {
    uint32_t base = handle_base(id, style, current);
    if (!out || max <= 0 || !base) return 0;
    int n = max < 2 ? max : 2;
    for (int i = 0; i < n; i++) out[i] = base | (uint32_t)i << 16;
    return n;
}
int dm_feedback_six_handles(uint32_t *out, int max, uint32_t id, uint32_t style, uint32_t current) {
    uint32_t base = handle_base(id, style, current);
    if (!out || max <= 0 || !base) return 0;
    out[0] = base | 2u << 16;
    return 1;
}
static void clear_motion(void) { have = 0; last_motion_ns = 0; aligned = 0; memset(angles, 0, sizeof angles); }
uint64_t dm_feedback_set_device(int c, int f, unsigned caps, uint64_t now) {
    pthread_mutex_lock(&lock);
    unsigned nc = !!c, nf = !!f, ncap = caps & 7;
    if (nc != connected || nf != foreground || ncap != capabilities) {
        connected = nc; foreground = nf; capabilities = ncap;
        ++epoch; last_game_tick = 0; clear_motion();
        for (int i = 0; i < 2; i++) { last[i] = neutral; updated[i] = now; ++sequence[i]; }
    }
    uint64_t result = epoch;
    pthread_mutex_unlock(&lock);
    return result;
}
uint64_t dm_feedback_epoch(void) {
    pthread_mutex_lock(&lock); uint64_t e = epoch; pthread_mutex_unlock(&lock); return e;
}
void dm_feedback_game_tick(uint64_t now) {
    pthread_mutex_lock(&lock);
    if (connected && foreground && now > last_game_tick) last_game_tick = now;
    pthread_mutex_unlock(&lock);
}
static dm_vibration_value effective(int side, uint64_t now) {
    if (!permitted || !connected || !foreground || !(capabilities & (1u << side))) return neutral;
    // Native values latch until changed while the game is alive. A hung game,
    // suspension or device loss must never leave a controller vibrating.
    if (!fresh(now, updated[side], output_lease_ns) && !fresh(now, last_game_tick, output_lease_ns)) return neutral;
    return last[side];
}
void dm_feedback_poll(uint64_t now, dm_feedback_output *out) {
    if (!out) return;
    pthread_mutex_lock(&lock);
    *out = (dm_feedback_output){.epoch = epoch, .connected = connected, .foreground = foreground,
                                .capabilities = capabilities, .motion_samples = produced,
                                .motion_updated_ns = last_motion_ns, .vibration_sends = vibration_sends,
                                .motion_reads = motion_reads, .motion_states_returned = motion_states_returned};
    for (int i = 0; i < 2; i++) { out->value[i] = effective(i, now); out->updated_ns[i] = updated[i]; out->sequence[i] = sequence[i]; }
    pthread_mutex_unlock(&lock);
}
static dm_vibration_value clean_value(const dm_vibration_value *v) {
    if (!isfinite(v->amp_low) || !isfinite(v->freq_low) || !isfinite(v->amp_high) || !isfinite(v->freq_high)) return neutral;
    return (dm_vibration_value){clampf(v->amp_low, 0, 1), clampf(v->freq_low, 40, 626),
                                 clampf(v->amp_high, 0, 1), clampf(v->freq_high, 80, 1253)};
}
void dm_feedback_vibration_initialize(uint32_t handle) { (void)vib_side(handle); }
void dm_feedback_vibration_permit(int value) {
    pthread_mutex_lock(&lock);
    if (permitted != !!value) {
        permitted = !!value;
        for (int i = 0; i < 2; i++) { last[i] = neutral; updated[i] = 0; ++sequence[i]; }
    }
    pthread_mutex_unlock(&lock);
}
int dm_feedback_vibration_permitted(void) {
    pthread_mutex_lock(&lock); int result = (int)permitted; pthread_mutex_unlock(&lock); return result;
}
static void send_locked(uint32_t h, const dm_vibration_value *v, uint64_t now) {
    int side = vib_side(h);
    if (side < 0 || !v) return;
    last[side] = clean_value(v); updated[side] = now; ++sequence[side]; ++vibration_sends;
}
void dm_feedback_vibration_send(uint32_t h, const dm_vibration_value *v, uint64_t now) {
    if (!v) return;
    pthread_mutex_lock(&lock); send_locked(h, v, now); pthread_mutex_unlock(&lock);
}
int dm_feedback_vibration_send_many(const uint32_t *handles, const dm_vibration_value *values, int count, uint64_t now) {
    // HID's native batch limit is 16 devices. Bounds are checked before touching
    // memory; a malformed/unsupported request must not walk arbitrary buffers.
    if (count < 0 || count > 16 || (count && (!handles || !values))) return 0;
    pthread_mutex_lock(&lock);
    for (int i = 0; i < count; i++) send_locked(handles[i], &values[i], now);
    pthread_mutex_unlock(&lock);
    return 1;
}
void dm_feedback_vibration_actual(uint32_t h, dm_vibration_value *out, uint64_t now) {
    if (!out) return;
    int side = vib_side(h);
    pthread_mutex_lock(&lock); *out = side < 0 ? neutral : effective(side, now); pthread_mutex_unlock(&lock);
}
void dm_feedback_vibration_info(uint32_t h, dm_vibration_info *out) {
    if (!out) return;
    int side = vib_side(h); *out = (dm_vibration_info){side < 0 ? 0u : 1u, side < 0 ? 0u : (uint32_t)side + 1};
}
static void orthonormalize(void) {
    double n = norm3(rotation[2]);
    for (int j = 0; j < 3; j++) rotation[2][j] /= n;
    double d = rotation[0][0]*rotation[2][0] + rotation[0][1]*rotation[2][1] + rotation[0][2]*rotation[2][2];
    for (int j = 0; j < 3; j++) rotation[0][j] -= d*rotation[2][j];
    n = norm3(rotation[0]);
    for (int j = 0; j < 3; j++) rotation[0][j] /= n;
    cross3(rotation[2], rotation[0], rotation[1]);
}
static void align_gravity(const double acc[3]) {
    memset(rotation, 0, sizeof rotation); rotation[0][0] = rotation[1][1] = rotation[2][2] = 1;
    double n = norm3(acc);
    if (n > 0.5) for (int j = 0; j < 3; j++) rotation[2][j] = -acc[j]/n;
    if (fabs(rotation[2][0]) > 0.9) { rotation[0][0] = 0; rotation[0][1] = 1; }
    orthonormalize();
}
static int quaternion_matrix(const double q[4]) {
    if (!q) return 0;
    double n = 0;
    for (int i = 0; i < 4; i++) { if (!isfinite(q[i])) return 0; n += q[i]*q[i]; }
    if (!isfinite(n) || n < 1e-12) return 0;
    n = sqrt(n); double x=q[0]/n, y=q[1]/n, z=q[2]/n, w=q[3]/n;
    rotation[0][0]=1-2*(y*y+z*z); rotation[0][1]=2*(x*y-z*w); rotation[0][2]=2*(x*z+y*w);
    rotation[1][0]=2*(x*y+z*w); rotation[1][1]=1-2*(x*x+z*z); rotation[1][2]=2*(y*z-x*w);
    rotation[2][0]=2*(x*z-y*w); rotation[2][1]=2*(y*z+x*w); rotation[2][2]=1-2*(x*x+y*y);
    return 1;
}
static void integrate(const double gyro[3], const double acc[3], double dt) {
    double w[3] = {gyro[0], gyro[1], gyro[2]}, n = norm3(acc);
    int style = started[0] ? 0 : 1;
    if (fusion[style] && fabs(n - 1) < 0.15) {
        double measured[3] = {acc[0]/n, acc[1]/n, acc[2]/n};
        double estimated[3] = {-rotation[2][0], -rotation[2][1], -rotation[2][2]}, e[3];
        cross3(measured, estimated, e);
        for (int j = 0; j < 3; j++) w[j] += 0.5*e[j];
    }
    double rate = norm3(w), theta = rate*dt;
    if (theta < 1e-12) return;
    double k[3] = {w[0]/rate, w[1]/rate, w[2]/rate}, s = sin(theta), c = 1-cos(theta);
    double K[3][3] = {{0,-k[2],k[1]}, {k[2],0,-k[0]}, {-k[1],k[0],0}}, E[3][3], result[3][3];
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) {
        double kk = 0; for (int m = 0; m < 3; m++) kk += K[i][m]*K[m][j];
        E[i][j] = (i == j) + s*K[i][j] + c*kk;
    }
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) {
        result[i][j] = 0;
        for (int m = 0; m < 3; m++) result[i][j] += rotation[i][m]*E[m][j];
    }
    memcpy(rotation, result, sizeof rotation); orthonormalize();
}
int dm_feedback_motion_push(uint64_t e, const double acc[3], const double gyro[3], const double q[4], uint64_t now) {
    if (!acc || !gyro || !now) return 0;
    for (int i = 0; i < 3; i++) if (!isfinite(acc[i]) || !isfinite(gyro[i]) || fabs(acc[i]) > 64 || fabs(gyro[i]) > 100) return 0;
    pthread_mutex_lock(&lock);
    if (e != epoch || !connected || !foreground || !(capabilities & DM_FEEDBACK_MOTION) || (last_motion_ns && now <= last_motion_ns)) {
        pthread_mutex_unlock(&lock); return 0;
    }
    uint64_t delta = last_motion_ns ? now-last_motion_ns : 4000000;
    if (delta > motion_lease_ns) { clear_motion(); delta = 4000000; }
    // Sample duration is sensor time, not game polling time. Do not integrate
    // across a scheduling stall; physical acceleration/rate is still reported.
    double dt = delta <= 50000000 ? delta/1e9 : 0;
    if (!quaternion_matrix(q)) {
        if (!aligned) align_gravity(acc);
        else integrate(gyro, acc, dt);
    }
    aligned = 1; last_motion_ns = now;
    dm_six_axis_state *state = &ring[produced % RING_SIZE];
    *state = (dm_six_axis_state){.delta_ns = (int64_t)delta, .sampling = (int64_t)++produced, .attributes = SENSOR_CONNECTED};
    for (int i = 0; i < 3; i++) {
        angles[i] += gyro[i]/tau*dt;
        state->acc[i]=(float)acc[i]; state->gyro[i]=(float)(gyro[i]/tau); state->angle[i]=(float)angles[i];
        for (int j = 0; j < 3; j++) state->dir[i*3+j] = (float)rotation[j][i];
    }
    if (have < RING_SIZE) ++have;
    pthread_mutex_unlock(&lock); return 1;
}
void dm_feedback_six_start(uint32_t h) {
    int style = six_style(h); if (style < 0) return;
    pthread_mutex_lock(&lock);
    if (!started[style]) { started[style] = 1; clear_motion(); }
    pthread_mutex_unlock(&lock);
}
void dm_feedback_six_stop(uint32_t h) {
    int style = six_style(h); if (style < 0) return;
    pthread_mutex_lock(&lock); started[style] = 0; pthread_mutex_unlock(&lock);
}
static void disconnected_state(dm_six_axis_state *s) {
    *s = (dm_six_axis_state){.acc = {0,0,-1}, .dir = {1,0,0, 0,1,0, 0,0,1}};
}
int dm_feedback_six_read(uint32_t h, dm_six_axis_state *out, int max, uint64_t now) {
    if (!out || max <= 0) return 0;
    int style = six_style(h), n = 0;
    pthread_mutex_lock(&lock);
    ++motion_reads;
    if (style >= 0 && started[style] && connected && foreground && (capabilities & DM_FEEDBACK_MOTION) && fresh(now, last_motion_ns, motion_lease_ns)) {
        n = max < DM_FEEDBACK_MOTION_MAX ? max : DM_FEEDBACK_MOTION_MAX;
        if ((unsigned)n > have) n = (int)have;
        for (int i = 0; i < n; i++) out[i] = ring[(produced-1-(uint64_t)i) % RING_SIZE];
    }
    motion_states_returned += (uint64_t)n;
    if (!n) disconnected_state(&out[0]);
    pthread_mutex_unlock(&lock); return n;
}
int dm_feedback_six_at_rest(uint32_t h, uint64_t now) {
    dm_six_axis_state s;
    if (!dm_feedback_six_read(h, &s, 1, now)) return 1;
    double speed = 0, force = 0;
    for (int i = 0; i < 3; i++) { speed += s.gyro[i]*s.gyro[i]; force += s.acc[i]*s.acc[i]; }
    return speed < 0.0025*0.0025 && fabs(sqrt(force)-1) < 0.08;
}
void dm_feedback_six_set_fusion(uint32_t h, int enabled) {
    int s = six_style(h); if (s < 0) return;
    pthread_mutex_lock(&lock); fusion[s] = !!enabled; pthread_mutex_unlock(&lock);
}
int dm_feedback_six_fusion(uint32_t h) {
    int s = six_style(h); if (s < 0) return 0;
    pthread_mutex_lock(&lock); int result = (int)fusion[s]; pthread_mutex_unlock(&lock); return result;
}
void dm_feedback_six_set_fusion_parameters(uint32_t h, float gain, float bias) {
    int s = six_style(h); if (s < 0 || !isfinite(gain) || !isfinite(bias)) return;
    pthread_mutex_lock(&lock); fusion_parameters[s][0] = clampf(gain, 0, 1); fusion_parameters[s][1] = clampf(bias, 0, 1); pthread_mutex_unlock(&lock);
}
void dm_feedback_six_get_fusion_parameters(uint32_t h, float *gain, float *bias) {
    int s = six_style(h);
    pthread_mutex_lock(&lock);
    if (gain) *gain = s < 0 ? 0 : fusion_parameters[s][0];
    if (bias) *bias = s < 0 ? 0 : fusion_parameters[s][1];
    pthread_mutex_unlock(&lock);
}
void dm_feedback_six_set_drift(uint32_t h, int mode) {
    int s = six_style(h); if (s < 0 || mode < 0 || mode > 2) return;
    pthread_mutex_lock(&lock); drift[s] = mode; pthread_mutex_unlock(&lock);
}
int dm_feedback_six_drift(uint32_t h) {
    int s = six_style(h); if (s < 0) return 1;
    pthread_mutex_lock(&lock); int result = drift[s]; pthread_mutex_unlock(&lock); return result;
}
