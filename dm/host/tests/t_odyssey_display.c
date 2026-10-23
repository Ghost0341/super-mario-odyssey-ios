// Synthetic receiving-game camera objects exercise the actual guarded adapter.
#include <assert.h>
#include <math.h>
#include "../hle_odyssey_display.c"

module_t g_mod[MAX_MOD];
int g_nmod;
static void (*callbacks[OBS_MAX])(const uint64_t *);
static int have[OBS_MAX], notifications;
void gate_obs_set(int id, void (*callback)(const uint64_t *)) { callbacks[id] = callback; }
int gate_obs_present(int id) { return have[id]; }
void mtl_present_geometry_changed(void) { notifications++; }
static void put_float(void *object, unsigned offset, float value) { memcpy((uint8_t *)object + offset, &value, 4); }
static float get_float(void *object, unsigned offset) { float result; memcpy(&result, (uint8_t *)object + offset, 4); return result; }
int main(void) {
    module_t *m = g_mod; g_nmod = 1;
    strcpy(m->name, "main"); strcpy(m->build_id, k_build);
    m->size = 0x1500000; m->text_end = 0xa2c000; m->data_off = 0x1280000; m->patch_off = 0x14c0000;
    m->base = calloc(1, m->size); assert(m->base);
    uint8_t *b = m->base;
    memcpy(b + 0xf67440, "N4sead21PerspectiveProjectionE", 30);
    *(uintptr_t *)(b + 0x1354308) = (uintptr_t)(b + 0xf67440);
    *(uintptr_t *)(b + 0x13540f0) = (uintptr_t)(b + 0x1354300);
    *(uintptr_t *)(b + 0x1354150) = (uintptr_t)(b + 0x9683c0);
    for (unsigned i = 0; i < sizeof k_gates / sizeof *k_gates; i++) {
        const display_gate *p = &k_gates[i];
        uint32_t branch = 0x14000000u | ((uint32_t)(m->patch_off - p->offset) >> 2);
        memcpy(b + p->offset, &branch, 4);
        memcpy(b + p->offset + 4, p->words + 1, sizeof p->words - 4);
        have[p->gate] = 1;
    }
    assert(!dm_odyssey_display_enabled());
    setenv("DM_ODYSSEY_DYNAMIC_DISPLAY", "0", 1);
    dm_odyssey_display_install(); assert(!atomic_load(&g_camera_ready));
    setenv("DM_ODYSSEY_DYNAMIC_DISPLAY", "invalid", 1);
    dm_odyssey_display_install(); assert(!atomic_load(&g_camera_ready));
    unsetenv("DM_ODYSSEY_DYNAMIC_DISPLAY"); // Shipping default still requires every exact gate.
    b[0x73da18] ^= 1; dm_odyssey_display_install(); assert(!atomic_load(&g_camera_ready));
    b[0x73da18] ^= 1;
    dm_odyssey_display_install(); assert(atomic_load(&g_camera_ready));
    assert(!dm_odyssey_display_enabled());
    dm_odyssey_display_hud_ready(); assert(!dm_odyssey_display_enabled());
    assert(!dm_odyssey_display_request(NAN, 1)); assert(!dm_odyssey_display_request(1, 0));
    assert(!dm_odyssey_display_request(2, 1)); assert(!dm_odyssey_display_request(1, INFINITY));
    _Alignas(8) uint8_t object[0x200] = {0}, unknown[0x200] = {0};
    *(uintptr_t *)object = (uintptr_t)(b + 0x13540f8);
    *(uintptr_t *)unknown = (uintptr_t)(b + 0x1354168); // A different projection ABI is rejected.
    put_float(object, 0xb0, 4.f / 3.f); put_float(object, 0x98, 10); put_float(object, 0x9c, 10000);
    put_float(object, 0xa0, .7f); put_float(object, 0x1dc, .3f); put_float(object, 0x1e4, .1f);
    uint64_t regs[31] = {0}; regs[0] = (uintptr_t)unknown;
    assert(dm_odyssey_display_request(678, 466)); assert(dm_odyssey_display_enabled());
    dm_odyssey_display_frame_boundary();
    callbacks[OBS_ODYSSEY_PROJECTION_CALC](regs); assert(get_float(unknown, 0xb0) == 0);
    regs[19] = (uintptr_t)object;
    callbacks[OBS_ODYSSEY_PROJECTION_SET](regs); assert(object[8] == 1);
    regs[0] = (uintptr_t)object;
    for (int i = 0; i < 1000; i++) {
        double w = i & 1 ? 678 : 951, h = i & 1 ? 466 : 669;
        double prior = dm_odyssey_display_aspect();
        assert(dm_odyssey_display_request(w, h)); assert(dm_odyssey_display_aspect() == prior);
        dm_odyssey_display_frame_boundary(); object[8] = 0;
        callbacks[OBS_ODYSSEY_PROJECTION_CALC](regs);
        float aspect = (float)(w / h), span = 20.f * .3f * aspect;
        assert(fabsf(get_float(object, 0xb0) - aspect) < .000001f);
        assert(fabsf(get_float(object, 0x1e0) - aspect) < .000001f);
        assert(fabsf(get_float(object, 0x1c0) - (span * .1f - span * .5f)) < .00001f);
        assert(fabsf(get_float(object, 0x1cc) - (span * .1f + span * .5f)) < .00001f);
        assert(object[8] == 1);
        assert(get_float(object, 0x98) == 10 && get_float(object, 0x9c) == 10000 && get_float(object, 0xa0) == .7f);
    }
    assert(notifications == 1001);
    assert(!dm_odyssey_display_request(239, 110)); assert(!dm_odyssey_display_enabled());
    dm_odyssey_display_frame_boundary();
    callbacks[OBS_ODYSSEY_PROJECTION_CALC](regs);
    assert(get_float(object, 0xb0) == (float)DM_GAME_DISPLAY_ASPECT);
    dm_odyssey_display_layout layout;
    assert(dm_odyssey_display_geometry(678,466,0,84,34,0));
    dm_odyssey_display_layout_snapshot(&layout);
    assert(layout.aspect == DM_GAME_DISPLAY_ASPECT && layout.left == 0);
    dm_odyssey_display_frame_boundary();
    assert(dm_odyssey_display_source_aspect() == DM_GAME_DISPLAY_ASPECT);
    dm_odyssey_display_layout_snapshot(&layout);
    assert(fabs(layout.aspect-678.0/466)<1e-12);
    assert(fabs(layout.left-84.0/678*1280)<1e-12 && fabs(layout.bottom-34.0/466*720)<1e-12);
    dm_odyssey_display_frame_boundary();
    uint64_t generation=dm_odyssey_display_source_generation();
    assert(dm_odyssey_display_geometry(678,466,0,0,34,84));
    assert(dm_odyssey_display_source_generation()==generation);
    dm_odyssey_display_frame_boundary(); // Old completed raster retains its inset generation.
    assert(dm_odyssey_display_source_generation()==generation);
    dm_odyssey_display_layout_snapshot(&layout); assert(layout.left==0 && layout.right>0);
    dm_odyssey_display_frame_boundary();
    assert(dm_odyssey_display_source_generation()==generation+1);
    assert(!dm_odyssey_display_geometry(678,466,0,NAN,34,0));
    assert(!dm_odyssey_display_geometry(678,466,0,678,34,0));
    dm_odyssey_display_layout_snapshot(&layout); assert(layout.right>0);
    free(b); puts("PASS: 1000 live camera/cache/frustum transitions, fail-closed installation, typed AL scope, inset generations and paired activation");
    return 0;
}
