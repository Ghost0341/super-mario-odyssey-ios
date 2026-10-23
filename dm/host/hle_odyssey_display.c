// Odyssey 1.4.1: update the game's perspective and cached frustum together.
// Offline observation gates retain signed text; callbacks only edit the live
// projection objects configured by al::Projection::set, never arbitrary cameras.
#include "dm.h"
#include "odyssey_display.h"
#include <math.h>
#include <stdatomic.h>

static const char k_build[] = "b424be150a8e7d78701cbe7a439d9ebf";
static uintptr_t g_vptr;
static _Atomic int g_camera_ready, g_hud_ready;
static _Atomic double g_requested;
static _Atomic double g_active;
static pthread_mutex_t g_display_lock = PTHREAD_MUTEX_INITIALIZER;
static dm_odyssey_display_layout g_requested_layout, g_active_layout;
static _Thread_local double g_source_aspect;
static uint64_t g_requested_generation, g_active_generation;
static _Thread_local uint64_t g_source_generation;
static _Atomic uint64_t g_configurations, g_matrix_reads, g_aspect_changes;
static _Atomic double g_last_camera_aspect;

int dm_odyssey_display_enabled(void) {
    double aspect = atomic_load(&g_requested);
    return atomic_load(&g_camera_ready) && atomic_load(&g_hud_ready) && aspect >= 1 && aspect <= 16.0 / 9.0;
}
void dm_odyssey_display_hud_ready(void) {
    pthread_mutex_lock(&g_display_lock);
    g_active_layout = g_requested_layout;
    g_active_generation = g_requested_generation;
    atomic_store(&g_active, g_active_layout.aspect);
    pthread_mutex_unlock(&g_display_lock);
    atomic_store(&g_hud_ready, 1);
}
int dm_odyssey_display_request(double width, double height) {
    return dm_odyssey_display_geometry(width,height,0,0,0,0);
}
int dm_odyssey_display_geometry(double width, double height, double top, double left, double bottom, double right) {
    if (!isfinite(width) || !isfinite(height) || width <= 0 || height <= 0 || width > 16384 || height > 16384) return 0;
    if (!isfinite(top) || !isfinite(left) || !isfinite(bottom) || !isfinite(right) ||
        top<0 || left<0 || bottom<0 || right<0 || top+bottom>=height || left+right>=width) return 0;
    double aspect = width / height;
    // Landscape only. Keep pathological intermediate scene sizes on the last
    // valid geometry instead of admitting unbounded projection/UI coefficients.
    if (!isfinite(aspect)) return 0;
    int supported = aspect >= 1 && aspect <= 16.0 / 9.0;
    if (!supported) aspect = 0; // A valid unsupported scene restores prepared geometry.
    dm_odyssey_display_layout next = supported ? (dm_odyssey_display_layout){
        aspect,top/height*720,left/width*1280,bottom/height*720,right/width*1280,
    } : (dm_odyssey_display_layout){0};
    pthread_mutex_lock(&g_display_lock);
    int changed = memcmp(&next,&g_requested_layout,sizeof next) != 0;
    if (changed) ++g_requested_generation;
    g_requested_layout = next;
    atomic_store(&g_requested, aspect);
    pthread_mutex_unlock(&g_display_lock);
    if (changed && atomic_load(&g_camera_ready) && atomic_load(&g_hud_ready)) {
        void mtl_present_geometry_changed(void);
        mtl_present_geometry_changed(); // Publish only; no drawable/GPU waits.
    }
    return supported;
}
double dm_odyssey_display_aspect(void) {
    double aspect = atomic_load(&g_active);
    return atomic_load(&g_camera_ready) && atomic_load(&g_hud_ready) && aspect >= 1 && aspect <= 16.0 / 9.0 ? aspect : DM_GAME_DISPLAY_ASPECT;
}
double dm_odyssey_display_scene_aspect(void) {
    double aspect = atomic_load(&g_requested);
    return dm_odyssey_display_enabled() && aspect >= 1 && aspect <= 16.0 / 9.0 ? aspect : DM_GAME_DISPLAY_ASPECT;
}
void dm_odyssey_display_frame_boundary(void) {
    // The NVN present has finished recording the old frame. Camera and HUD now
    // share one immutable ratio throughout the next guest rendering interval.
    pthread_mutex_lock(&g_display_lock);
    g_source_aspect = atomic_load(&g_camera_ready) && atomic_load(&g_hud_ready) &&
        g_active_layout.aspect>=1 && g_active_layout.aspect<=16.0/9 ? g_active_layout.aspect : DM_GAME_PRESENT_ASPECT;
    g_source_generation = atomic_load(&g_camera_ready) && atomic_load(&g_hud_ready) ? g_active_generation : 0;
    g_active_layout = g_requested_layout;
    g_active_generation = g_requested_generation;
    atomic_store(&g_active, g_active_layout.aspect);
    pthread_mutex_unlock(&g_display_lock);
}
double dm_odyssey_display_source_aspect(void) {
    return g_source_aspect>0 ? g_source_aspect : DM_GAME_PRESENT_ASPECT;
}
uint64_t dm_odyssey_display_source_generation(void) { return g_source_generation; }
void dm_odyssey_display_layout_snapshot(dm_odyssey_display_layout *out) {
    if (!out) return;
    pthread_mutex_lock(&g_display_lock); *out = g_active_layout; pthread_mutex_unlock(&g_display_lock);
    if (!atomic_load(&g_camera_ready) || !atomic_load(&g_hud_ready) || out->aspect<1 || out->aspect>16.0/9)
        *out = (dm_odyssey_display_layout){.aspect=DM_GAME_DISPLAY_ASPECT};
}
static void update_camera(void *object, int configuring) {
    // Both gates belong to typed al::Projection methods. The generic sead
    // getters also accept smaller objects and must never write AL extensions.
    // No persistent object registry or destructor/lifetime inference is needed.
    if (!atomic_load(&g_camera_ready) || !atomic_load(&g_hud_ready) ||
        !object || *(const uintptr_t *)object != g_vptr) return;
    uint8_t *p = object;
    float aspect = (float)dm_odyssey_display_aspect(), previous;
    if (configuring) atomic_fetch_add(&g_configurations, 1); else atomic_fetch_add(&g_matrix_reads, 1);
    memcpy(&previous, p + 0xb0, sizeof previous);
    memcpy(p + 0xb0, &aspect, sizeof aspect);
    memcpy(p + 0x1e0, &aspect, sizeof aspect);
    if (previous != aspect) {
        p[8] = 1; // sead's next matrix read rebuilds both caches.
        atomic_fetch_add(&g_aspect_changes, 1);
    }
    double logged = atomic_exchange(&g_last_camera_aspect, aspect);
    if (logged != aspect) LOG("Odyssey display camera: aspect=%.6f object=%p configured=%d", aspect, object, configuring);
    if (configuring) return; // Original set computes the new frustum immediately.
    // The same horizontal frustum equations as the shipped set body. Preserve
    // vertical FOV, near/far, off-axis offsets and the game's culling behavior.
    float near_plane, tangent, offset;
    memcpy(&near_plane, p + 0x98, sizeof near_plane);
    memcpy(&tangent, p + 0x1dc, sizeof tangent);
    memcpy(&offset, p + 0x1e4, sizeof offset);
    if (!isfinite(near_plane) || !isfinite(tangent) || !isfinite(offset)) return;
    float width = (near_plane + near_plane) * tangent * aspect;
    float left = width * offset - width * .5f;
    float right = width * .5f + width * offset;
    if (!isfinite(left) || !isfinite(right)) return;
    memcpy(p + 0x1c0, &left, sizeof left);
    memcpy(p + 0x1cc, &right, sizeof right);
}
void dm_odyssey_display_snapshot(dm_odyssey_display_stats *out) {
    if (!out) return;
    *out = (dm_odyssey_display_stats){
        .configurations = atomic_load(&g_configurations), .matrix_reads = atomic_load(&g_matrix_reads),
        .aspect_changes = atomic_load(&g_aspect_changes), .camera_installed = atomic_load(&g_camera_ready),
        .enabled = dm_odyssey_display_enabled(), .requested_aspect = atomic_load(&g_requested),
        .last_camera_aspect = atomic_load(&g_last_camera_aspect),
    };
}
static void camera_configured(const uint64_t *regs) { update_camera((void *)(uintptr_t)regs[19], 1); }
static void camera_matrix(const uint64_t *regs) { update_camera((void *)(uintptr_t)regs[0], 0); }

typedef struct { uint32_t offset, gate, words[3]; } display_gate;
static const display_gate k_gates[] = {
    {0x73de9c, OBS_ODYSSEY_PROJECTION_SET, {0x1e2c1008, 0x1e280920, 0xbd01da69}},
    {0x73da10, OBS_ODYSSEY_PROJECTION_CALC, {0xa9be4ff4, 0xa9017bfd, 0x910043fd}},
};
static int gate_guard(const module_t *m, const display_gate *gate) {
    if (!gate_obs_present(gate->gate) || gate->offset > m->text_end ||
        sizeof gate->words > m->text_end - gate->offset) return 0;
    uint32_t branch;
    memcpy(&branch, m->base + gate->offset, sizeof branch);
    int64_t displacement = ((int64_t)(int32_t)(branch << 6)) >> 4;
    int64_t target = (int64_t)gate->offset + displacement;
    return (branch & 0xfc000000u) == 0x14000000u && target >= m->patch_off &&
        target >= 0 && (uint64_t)target < m->size &&
        !memcmp(m->base + gate->offset + 4, gate->words + 1, sizeof gate->words - 4);
}
void dm_odyssey_display_install(void) {
    const char *option = getenv("DM_ODYSSEY_DYNAMIC_DISPLAY");
    if ((option && strcmp(option, "1")) || atomic_load(&g_camera_ready) ||
        fabs(DM_GAME_DISPLAY_ASPECT - 4.0 / 3.0) > 0.00001) return;
    module_t *m = NULL;
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) { m = &g_mod[i]; break; }
    if (!m || strcmp(m->build_id, k_build) || !m->base || m->size <= 0x1354310) return;
    const uint8_t *b = m->base;
    static const char name[] = "N4sead21PerspectiveProjectionE";
    if (memcmp(b + 0xf67440, name, sizeof name) ||
        *(const uintptr_t *)(b + 0x1354308) != (uintptr_t)(b + 0xf67440) ||
        *(const uintptr_t *)(b + 0x13540f0) != (uintptr_t)(b + 0x1354300) ||
        *(const uintptr_t *)(b + 0x1354150) != (uintptr_t)(b + 0x9683c0)) return;
    for (unsigned i = 0; i < sizeof k_gates / sizeof *k_gates; i++) if (!gate_guard(m, &k_gates[i])) {
        LOG("[RED] Odyssey display: camera observation guard failed; prepared composition retained");
        return;
    }
    g_vptr = (uintptr_t)(b + 0x13540f8);
    gate_obs_set(OBS_ODYSSEY_PROJECTION_SET, camera_configured);
    gate_obs_set(OBS_ODYSSEY_PROJECTION_CALC, camera_matrix);
    atomic_store(&g_camera_ready, 1);
    LOG("Odyssey display: exact1.4.1 camera/cache/frustum adapters installed; paired HUD required");
}
