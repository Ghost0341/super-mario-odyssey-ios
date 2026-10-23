// Observe selected shipped Odyssey 1.4.1 takeoffs for optional controller accents.
// Native HD rumble remains the comprehensive baseline. Extra takeoff events drive
// brief controller accents only when the game actually enters the selected jump.
#include "dm.h"
#include "odyssey_feedback.h"

enum { EVENT_CAPACITY = 32 };
static const uint64_t EVENT_LIFETIME_NS = 200000000;
static const char k_build[] = "b424be150a8e7d78701cbe7a439d9ebf";
typedef void (*nerve_execute_fn)(const void *nerve, void *spine);
enum { CLASSIC_JUMP, ROLLING_JUMP, BACKFLIP_JUMP, WALL_JUMP, SIDE_FLIP, JUMP_SOURCE_COUNT };
typedef struct {
    const char *name, *label;
    uint32_t name_off, typeinfo_off, slot_off, nerve_off, execute_off;
    uint32_t words[2];
    dm_odyssey_feedback_kind kind;
} nerve_profile;
static const nerve_profile k_jumps[JUMP_SOURCE_COUNT] = {
    { "N12_GLOBAL__N_126PlayerStateLongJumpNrvJumpE", "classic long jump",
      0xef2370, 0x12b7910, 0x12b78f8, 0x12b7908, 0x415660,
      { 0xf9400020, 0x17ffff3b }, DM_ODYSSEY_LONG_JUMP },
    { "N12_GLOBAL__N_125PlayerStateRollingNrvJumpE", "rolling jump",
      0xef2970, 0x12b8260, 0x12b8248, 0x12b83d0, 0x41cad0,
      { 0xf9400020, 0x17fffc83 }, DM_ODYSSEY_ROLLING_JUMP },
    { "N12_GLOBAL__N_126PlayerStateJumpNrvJumpBackE", "backflip",
      0xef2200, 0x12b76e0, 0x12b76c8, 0x12b7850, 0x415120,
      { 0xf9400020, 0x17fffe23 }, DM_ODYSSEY_BACKFLIP },
    { "N12_GLOBAL__N_132PlayerStateNormalWallJumpNrvJumpE", "wall jump",
      0xef23c0, 0x12b79c0, 0x12b79a8, 0x12b79b8, 0x415aa0,
      { 0xf9400020, 0x17ffff37 }, DM_ODYSSEY_WALL_JUMP },
    { "N12_GLOBAL__N_126PlayerStateJumpNrvJumpTurnE", "side flip",
      0xef2230, 0x12b7720, 0x12b7708, 0x12b7858, 0x415130,
      { 0xf9400020, 0x17fffd5b }, DM_ODYSSEY_SIDE_FLIP },
};
static const nerve_profile k_wall_context = {
    "N12_GLOBAL__N_125PlayerStateWallAirNrvJumpE", "wall jump context",
    0xef3980, 0x12b99d0, 0x12b99b8, 0x12b99f0, 0x42d5a0,
    { 0xf81e0ff3, 0xa9017bfd }, 0,
};
// The whole outer callback is checked: its synchronous substate update at +0x14
// is the permission scope for the inner launch. It never emits an event itself.
static const uint32_t k_wall_context_words[] = {
    0xf81e0ff3, 0xa9017bfd, 0x910043fd, 0xf9400033, 0xaa1303e0,
    0x940a6de3, 0x360000e0, 0xf9400268, 0xf9401501, 0xaa1303e0,
    0xa9417bfd, 0xf84207f3, 0xd61f0020, 0xf9401e60, 0x94033736,
    0x360000e0, 0xa9417bfd, 0x90007461, 0x9127a021, 0xaa1303e0,
    0xf84207f3, 0x140a694b, 0xa9417bfd, 0xf84207f3, 0xd65f03c0,
};
// Original callbacks are ldr x0,[x1]; b <state body>. Signed text is untouched.
static nerve_execute_fn g_original[JUMP_SOURCE_COUNT];
static nerve_execute_fn g_wall_context_original;
static _Thread_local const void *g_wall_context_child;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static dm_odyssey_feedback_event g_events[EVENT_CAPACITY];
static unsigned g_head, g_count;
static uint64_t g_sequence, g_epoch;
static dm_odyssey_feedback_stats g_stats;

// A lifecycle epoch also prevents an in-flight guest callback from adding a stale
// cue after disconnect/background and a rapid foreground/reconnect.
static uint64_t observe_begin(void) {
    pthread_mutex_lock(&g_lock);
    uint64_t epoch = g_epoch;
    pthread_mutex_unlock(&g_lock);
    return epoch;
}
static void observe_jump(unsigned source, uint64_t epoch, uint64_t timestamp) {
    pthread_mutex_lock(&g_lock);
    g_stats.observed++;
    if (source == CLASSIC_JUMP) g_stats.classic_long_jump++;
    else if (source == ROLLING_JUMP) g_stats.rolling_jump++;
    else if (source == BACKFLIP_JUMP) g_stats.backflip++;
    else if (source == WALL_JUMP) g_stats.wall_jump++;
    else g_stats.side_flip++;
    if (!g_stats.active || epoch != g_epoch) {
        g_stats.inactive++;
        pthread_mutex_unlock(&g_lock);
        return;
    }
    if (g_count == EVENT_CAPACITY) {
        g_head = (g_head + 1) % EVENT_CAPACITY;
        g_count--;
        g_stats.overflowed++;
    }
    dm_odyssey_feedback_event event = {
        .sequence = ++g_sequence, .timestamp_ns = timestamp,
        .kind = k_jumps[source].kind, .strength = 1.0f,
    };
    g_events[(g_head + g_count++) % EVENT_CAPACITY] = event;
    g_stats.queued++;
    uint64_t observed = g_stats.observed;
    pthread_mutex_unlock(&g_lock);
    if (observed <= 24 || !(observed % 64))
        LOG("Odyssey feedback: %s first step #%llu queued sequence %llu",
            k_jumps[source].label, (unsigned long long)observed, (unsigned long long)event.sequence);
}
static void execute_jump(unsigned source, const void *nerve, void *spine) {
    // main+0x6c7650 passes its own Spine pointer in x1 and increments its signed
    // step field at +0x18 after execute returns. The game's isFirstStep helper
    // main+0x6c7cc0 tests this exact field for zero. No button or animation guess.
    int32_t step = -1;
    if (spine) memcpy(&step, (const uint8_t *)spine + 0x18, sizeof step);
    int first = step == 0;
    if (first && source == WALL_JUMP) {
        const void *state = NULL;
        memcpy(&state, spine, sizeof state);
        // NormalWallJump is also used for pole dismounts. Only the exact child
        // currently executing inside WallAir Jump may produce the wall accent.
        first = state && state == g_wall_context_child;
    }
    uint64_t epoch = first ? observe_begin() : 0;
    uint64_t timestamp = first ? now_ns() : 0;
    g_original[source](nerve, spine);
    // These are separate state takeoff bodies, each with its own first step and
    // velocity initialization. They do not call each other. Do not add an outer
    // actor nerve hook or a time cooldown that would duplicate/drop chain cues.
    if (first) observe_jump(source, epoch, timestamp);
}
static void long_jump_execute(const void *nerve, void *spine) { execute_jump(CLASSIC_JUMP, nerve, spine); }
static void rolling_jump_execute(const void *nerve, void *spine) { execute_jump(ROLLING_JUMP, nerve, spine); }
static void backflip_execute(const void *nerve, void *spine) { execute_jump(BACKFLIP_JUMP, nerve, spine); }
// Only the inner state emits. The outer scope below excludes both pole variants.
static void wall_jump_execute(const void *nerve, void *spine) { execute_jump(WALL_JUMP, nerve, spine); }
static void side_flip_execute(const void *nerve, void *spine) { execute_jump(SIDE_FLIP, nerve, spine); }
static void wall_context_execute(const void *nerve, void *spine) {
    const void *state = NULL, *child = NULL;
    if (spine) memcpy(&state, spine, sizeof state);
    // WallAir constructor main+0x42d140 stores its NormalWallJump child at +0x30.
    // The original callback dereferences this live state and updates that child.
    if (state) memcpy(&child, (const uint8_t *)state + 0x30, sizeof child);
    const void *previous = g_wall_context_child;
    g_wall_context_child = child;
    g_wall_context_original(nerve, spine);
    g_wall_context_child = previous;
}

static int source_guard(const module_t *m, const nerve_profile *p) {
    const uint8_t *b = m->base;
    size_t name_size = strlen(p->name) + 1;
    uint64_t name = p->name_off, typeinfo = p->typeinfo_off;
    uint64_t slot = p->slot_off, nerve = p->nerve_off;
    uint64_t execute = p->execute_off;
    return b && m->text_end <= m->size && name <= m->size && name_size <= m->size - name &&
        typeinfo <= m->size && 16 <= m->size - typeinfo &&
        slot >= 8 && slot <= m->size && 8 <= m->size - slot &&
        nerve <= m->size && 8 <= m->size - nerve &&
        m->data_off <= slot && slot >= m->text_end &&
        execute <= m->text_end && sizeof p->words <= m->text_end - execute &&
        memcmp(b + name, p->name, name_size) == 0 &&
        memcmp(b + execute, p->words, sizeof p->words) == 0 &&
        *(const uintptr_t *)(b + typeinfo + 8) == (uintptr_t)(b + name) &&
        *(const uintptr_t *)(b + slot - 8) == (uintptr_t)(b + typeinfo) &&
        *(const uintptr_t *)(b + nerve) == (uintptr_t)(b + slot) &&
        *(const uintptr_t *)(b + slot) == (uintptr_t)(b + execute);
}

void dm_odyssey_feedback_install(void) {
    // Must run before guest threads: the verified execute data slot is replaced
    // atomically once, and the guest's original function remains the delegate.
    if (g_original[CLASSIC_JUMP]) return;
    module_t *m = NULL;
    for (int i = 0; i < g_nmod; i++)
        if (!strcmp(g_mod[i].name, "main")) { m = &g_mod[i]; break; }
    if (!m || strcmp(m->build_id, k_build)) return;
    uint8_t *b = m->base;
    // Validate every source before writing any slot. A damaged or unsupported
    // profile never leaves a partial observer installation behind.
    for (unsigned i = 0; i < JUMP_SOURCE_COUNT; i++) {
        if (!source_guard(m, &k_jumps[i])) {
            LOG("[RED] Odyssey feedback: verified %s data/ABI guard failed; extra takeoff cues disabled", k_jumps[i].label);
            return;
        }
    }
    if (!source_guard(m, &k_wall_context) ||
        sizeof k_wall_context_words > m->text_end - k_wall_context.execute_off ||
        memcmp(b + k_wall_context.execute_off, k_wall_context_words, sizeof k_wall_context_words)) {
        LOG("[RED] Odyssey feedback: verified wall context data/ABI guard failed; extra takeoff cues disabled");
        return;
    }
    nerve_execute_fn wrappers[JUMP_SOURCE_COUNT] = {
        long_jump_execute, rolling_jump_execute, backflip_execute, wall_jump_execute, side_flip_execute,
    };
    for (unsigned i = 0; i < JUMP_SOURCE_COUNT; i++) {
        g_original[i] = (nerve_execute_fn)(b + k_jumps[i].execute_off);
        *(nerve_execute_fn *)(b + k_jumps[i].slot_off) = wrappers[i];
    }
    g_wall_context_original = (nerve_execute_fn)(b + k_wall_context.execute_off);
    *(nerve_execute_fn *)(b + k_wall_context.slot_off) = wall_context_execute;
    pthread_mutex_lock(&g_lock);
    g_stats.installed = 1;
    pthread_mutex_unlock(&g_lock);
    LOG("Odyssey feedback: exact 1.4.1 classic/rolling/backflip/wall/side takeoffs observed through data vtables; original code preserved");
}
void dm_odyssey_feedback_set_active(int active) {
    pthread_mutex_lock(&g_lock);
    active = !!active;
    if (g_stats.active != active || !active) {
        g_epoch++;
        g_head = g_count = 0;
    }
    g_stats.active = active;
    pthread_mutex_unlock(&g_lock);
}
int dm_odyssey_feedback_next(dm_odyssey_feedback_event *out) {
    if (!out) return 0;
    pthread_mutex_lock(&g_lock);
    uint64_t now = now_ns(); // A producer may enqueue while this consumer waits for the lock.
    while (g_stats.active && g_count) {
        dm_odyssey_feedback_event event = g_events[g_head];
        g_head = (g_head + 1) % EVENT_CAPACITY;
        g_count--;
        if (now < event.timestamp_ns || now - event.timestamp_ns > EVENT_LIFETIME_NS) {
            g_stats.expired++;
            continue;
        }
        *out = event;
        g_stats.delivered++;
        pthread_mutex_unlock(&g_lock);
        return 1;
    }
    pthread_mutex_unlock(&g_lock);
    return 0;
}
void dm_odyssey_feedback_get_stats(dm_odyssey_feedback_stats *out) {
    if (!out) return;
    pthread_mutex_lock(&g_lock);
    *out = g_stats;
    pthread_mutex_unlock(&g_lock);
}
uint64_t dm_odyssey_feedback_reserve_sequence(void) {
    pthread_mutex_lock(&g_lock); uint64_t sequence=++g_sequence; pthread_mutex_unlock(&g_lock); return sequence;
}
