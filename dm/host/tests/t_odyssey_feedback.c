// Actual selected takeoff first steps produce separate events. No trigger
// input is consulted, original state execution is preserved, and guards fail closed.
#include "../hle_odyssey_feedback.c"
#include <assert.h>

module_t g_mod[MAX_MOD];
int g_nmod;
static uint64_t test_time;
uint64_t now_ns(void) { return test_time; }
static unsigned calls[JUMP_SOURCE_COUNT];
static int deactivate_in_original;
static unsigned outer_calls;
static int wall_has_context, wrong_wall_child, cross_thread_wall;
static void *test_inner_spine;
static void delegate(unsigned source) {
    calls[source]++;
    if (deactivate_in_original) {
        dm_odyssey_feedback_set_active(0);
        dm_odyssey_feedback_set_active(1);
    }
}
static void classic_original(const void *nerve, void *spine) { (void)nerve; (void)spine; delegate(CLASSIC_JUMP); }
static void rolling_original(const void *nerve, void *spine) { (void)nerve; (void)spine; delegate(ROLLING_JUMP); }
static void backflip_original(const void *nerve, void *spine) { (void)nerve; (void)spine; delegate(BACKFLIP_JUMP); }
static void wall_original(const void *nerve, void *spine) { (void)nerve; (void)spine; delegate(WALL_JUMP); }
static void side_original(const void *nerve, void *spine) { (void)nerve; (void)spine; delegate(SIDE_FLIP); }
static void *outside_thread_wall(void *spine) {
    assert(!g_wall_context_child);
    wall_jump_execute(NULL, spine);
    return NULL;
}
static void wall_outer_original(const void *nerve, void *spine) {
    const void *state, *child;
    memcpy(&state, spine, sizeof state);
    memcpy(&child, (const uint8_t *)state + 0x30, sizeof child);
    assert(g_wall_context_child == child);
    outer_calls++;
    if (cross_thread_wall) {
        pthread_t thread;
        assert(!pthread_create(&thread, NULL, outside_thread_wall, test_inner_spine));
        assert(!pthread_join(thread, NULL));
    }
    wall_jump_execute(nerve, test_inner_spine);
}
static void reset(void) {
    memset(&g_stats, 0, sizeof g_stats);
    g_head = g_count = 0; g_sequence = g_epoch = 0;
    g_original[CLASSIC_JUMP] = classic_original;
    g_original[ROLLING_JUMP] = rolling_original;
    g_original[BACKFLIP_JUMP] = backflip_original;
    g_original[WALL_JUMP] = wall_original;
    g_original[SIDE_FLIP] = side_original;
    g_wall_context_original = wall_outer_original;
    g_wall_context_child = NULL;
    outer_calls = 0; wall_has_context = 1; wrong_wall_child = cross_thread_wall = 0;
    memset(calls, 0, sizeof calls);
    test_time = 1000000000; deactivate_in_original = 0;
}
static void run_step(unsigned source, int step) {
    uint8_t spine[0x30] = {0};
    uint8_t state[0x70] = {0}, different_child[0x70] = {0};
    const void *state_ptr = state;
    memcpy(spine, &state_ptr, sizeof state_ptr);
    memcpy(spine + 0x18, &step, sizeof step);
    if (source == CLASSIC_JUMP) long_jump_execute(NULL, spine);
    else if (source == ROLLING_JUMP) rolling_jump_execute(NULL, spine);
    else if (source == BACKFLIP_JUMP) backflip_execute(NULL, spine);
    else if (source == WALL_JUMP && wall_has_context) {
        uint8_t outer[0x38] = {0}, outer_spine[0x30] = {0};
        const void *outer_ptr = outer, *child = wrong_wall_child ? different_child : state;
        memcpy(outer_spine, &outer_ptr, sizeof outer_ptr);
        memcpy(outer + 0x30, &child, sizeof child);
        test_inner_spine = spine;
        const void *previous = g_wall_context_child;
        wall_context_execute(NULL, outer_spine);
        assert(g_wall_context_child == previous);
    }
    else if (source == WALL_JUMP) wall_jump_execute(NULL, spine);
    else side_flip_execute(NULL, spine);
}
enum { PROFILE_COUNT = JUMP_SOURCE_COUNT + 1 };
static const nerve_profile *profile_at(unsigned i) {
    return i < JUMP_SOURCE_COUNT ? &k_jumps[i] : &k_wall_context;
}
static void prepare_module(void) {
    g_nmod = 1;
    module_t *m = &g_mod[0];
    memset(m, 0, sizeof *m);
    strcpy(m->name, "main"); strcpy(m->build_id, k_build);
    m->size = 0x12ba100; m->base = calloc(1, m->size);
    m->text_end = 0xa2ad60; m->data_off = 0x119a000;
    uint8_t *b = m->base;
    for (unsigned i = 0; i < PROFILE_COUNT; i++) {
        const nerve_profile *p = profile_at(i);
        memcpy(b + p->name_off, p->name, strlen(p->name) + 1);
        memcpy(b + p->execute_off, p->words, sizeof p->words);
        *(uintptr_t *)(b + p->typeinfo_off + 8) = (uintptr_t)(b + p->name_off);
        *(uintptr_t *)(b + p->slot_off - 8) = (uintptr_t)(b + p->typeinfo_off);
        *(uintptr_t *)(b + p->nerve_off) = (uintptr_t)(b + p->slot_off);
        *(uintptr_t *)(b + p->slot_off) = (uintptr_t)(b + p->execute_off);
    }
    memcpy(b + k_wall_context.execute_off, k_wall_context_words, sizeof k_wall_context_words);
}
static void assert_rejected(void) {
    uintptr_t before[PROFILE_COUNT];
    for (unsigned i = 0; i < PROFILE_COUNT; i++)
        before[i] = *(uintptr_t *)(g_mod[0].base + profile_at(i)->slot_off);
    dm_odyssey_feedback_install();
    assert(!g_stats.installed);
    for (unsigned i = 0; i < JUMP_SOURCE_COUNT; i++) assert(!g_original[i]);
    assert(!g_wall_context_original);
    for (unsigned i = 0; i < PROFILE_COUNT; i++)
        assert(*(uintptr_t *)(g_mod[0].base + profile_at(i)->slot_off) == before[i]);
}
int main(void) {
    dm_odyssey_feedback_event event;
    // Each state delegates every step, and only step zero emits one takeoff.
    for (unsigned source = 0; source < JUMP_SOURCE_COUNT; source++) {
        reset(); dm_odyssey_feedback_set_active(1);
        run_step(source, -1); run_step(source, 0); run_step(source, 1); run_step(source, 20);
        for (unsigned i = 0; i < JUMP_SOURCE_COUNT; i++) assert(calls[i] == (i == source ? 4 : 0));
        assert(dm_odyssey_feedback_next(&event));
        assert(event.kind == k_jumps[source].kind && event.sequence == 1);
        assert(event.timestamp_ns == test_time && event.strength == 1);
        assert(!dm_odyssey_feedback_next(&event));
        run_step(source, 0);
        assert(dm_odyssey_feedback_next(&event) && event.sequence == 2);
        assert(g_stats.observed == 2 && g_stats.delivered == 2);
        assert(g_stats.classic_long_jump == (source == CLASSIC_JUMP ? 2 : 0));
        assert(g_stats.rolling_jump == (source == ROLLING_JUMP ? 2 : 0));
        assert(g_stats.backflip == (source == BACKFLIP_JUMP ? 2 : 0));
        assert(g_stats.wall_jump == (source == WALL_JUMP ? 2 : 0));
        assert(g_stats.side_flip == (source == SIDE_FLIP ? 2 : 0));
        assert(outer_calls == (source == WALL_JUMP ? 5 : 0));
    }
    // Shared pole dismounts execute the same inner state outside WallAir, and
    // must preserve the delegate without adding the wall texture or a count.
    reset(); dm_odyssey_feedback_set_active(1); wall_has_context = 0;
    run_step(WALL_JUMP, 0); run_step(WALL_JUMP, 1);
    assert(calls[WALL_JUMP] == 2 && !g_stats.observed && !dm_odyssey_feedback_next(&event));
    wall_has_context = 1; wrong_wall_child = 1; run_step(WALL_JUMP, 0);
    assert(calls[WALL_JUMP] == 3 && outer_calls == 1 && !g_stats.observed);
    wrong_wall_child = 0;
    const void *prior_scope = (const void *)(uintptr_t)0x1234;
    g_wall_context_child = prior_scope;
    for (unsigned i = 0; i < 3; i++) {
        run_step(WALL_JUMP, 0); run_step(WALL_JUMP, 1);
        assert(g_wall_context_child == prior_scope);
        assert(dm_odyssey_feedback_next(&event) && event.kind == DM_ODYSSEY_WALL_JUMP && event.sequence == i + 1);
        assert(!dm_odyssey_feedback_next(&event));
    }
    assert(calls[WALL_JUMP] == 9 && outer_calls == 7 && g_stats.wall_jump == 3);
    g_wall_context_child = NULL; wall_has_context = 0; run_step(WALL_JUMP, 0);
    assert(g_stats.wall_jump == 3 && !dm_odyssey_feedback_next(&event));

    // Even the same child pointer cannot borrow another thread's active scope.
    reset(); dm_odyssey_feedback_set_active(1); cross_thread_wall = 1;
    run_step(WALL_JUMP, 0);
    assert(calls[WALL_JUMP] == 2 && outer_calls == 1 && g_stats.wall_jump == 1);
    assert(dm_odyssey_feedback_next(&event) && event.kind == DM_ODYSSEY_WALL_JUMP);
    assert(!dm_odyssey_feedback_next(&event) && !g_wall_context_child);
    // A held-crouch continuation changes takeoff state: first classic, then four
    // rolling jumps. One event per new first step, no extra outer-state hook.
    reset(); dm_odyssey_feedback_set_active(1);
    run_step(CLASSIC_JUMP, 0); run_step(CLASSIC_JUMP, 1);
    for (int jump = 0; jump < 4; jump++) {
        run_step(ROLLING_JUMP, 0); run_step(ROLLING_JUMP, 1); run_step(ROLLING_JUMP, 45);
    }
    for (int i = 1; i <= 5; i++) {
        assert(dm_odyssey_feedback_next(&event) && event.sequence == (uint64_t)i);
        assert(event.kind == (i == 1 ? DM_ODYSSEY_LONG_JUMP : DM_ODYSSEY_ROLLING_JUMP));
    }
    assert(!dm_odyssey_feedback_next(&event));
    assert(g_stats.observed == 5 && g_stats.classic_long_jump == 1 && g_stats.rolling_jump == 4);
    assert(g_stats.backflip == 0 && g_stats.wall_jump == 0 && g_stats.side_flip == 0);

    // Backflips have their own source and never increment either accepted long
    // jump counter. Mixed takeoffs preserve order through the same bounded queue.
    reset(); dm_odyssey_feedback_set_active(1);
    const unsigned mixed[] = { BACKFLIP_JUMP, CLASSIC_JUMP, ROLLING_JUMP, BACKFLIP_JUMP, ROLLING_JUMP, BACKFLIP_JUMP };
    const dm_odyssey_feedback_kind kinds[] = { DM_ODYSSEY_BACKFLIP, DM_ODYSSEY_LONG_JUMP, DM_ODYSSEY_ROLLING_JUMP,
        DM_ODYSSEY_BACKFLIP, DM_ODYSSEY_ROLLING_JUMP, DM_ODYSSEY_BACKFLIP };
    for (unsigned i = 0; i < sizeof mixed / sizeof mixed[0]; i++) {
        run_step(mixed[i], 0); run_step(mixed[i], 1); run_step(mixed[i], 45);
    }
    for (unsigned i = 0; i < sizeof mixed / sizeof mixed[0]; i++) {
        assert(dm_odyssey_feedback_next(&event) && event.sequence == i + 1);
        assert(event.kind == kinds[i]);
    }
    assert(!dm_odyssey_feedback_next(&event));
    assert(g_stats.observed == 6 && g_stats.classic_long_jump == 1 && g_stats.rolling_jump == 2 && g_stats.backflip == 3);
    assert(g_stats.wall_jump == 0 && g_stats.side_flip == 0);

    // New wall/side takeoffs preserve all accepted sources and source order.
    // An outer WallAir observer is intentionally absent: it updates the exact
    // inner NormalWallJump whose first step is already represented here.
    reset(); dm_odyssey_feedback_set_active(1);
    const unsigned all_sources[] = { WALL_JUMP, SIDE_FLIP, BACKFLIP_JUMP, CLASSIC_JUMP, ROLLING_JUMP,
        WALL_JUMP, SIDE_FLIP, WALL_JUMP };
    for (unsigned i = 0; i < sizeof all_sources / sizeof all_sources[0]; i++) {
        run_step(all_sources[i], 0); run_step(all_sources[i], 1); run_step(all_sources[i], 45);
    }
    for (unsigned i = 0; i < sizeof all_sources / sizeof all_sources[0]; i++) {
        assert(dm_odyssey_feedback_next(&event) && event.sequence == i + 1);
        assert(event.kind == k_jumps[all_sources[i]].kind);
    }
    assert(!dm_odyssey_feedback_next(&event));
    assert(g_stats.observed == 8 && g_stats.classic_long_jump == 1 && g_stats.rolling_jump == 1 &&
        g_stats.backflip == 1 && g_stats.wall_jump == 3 && g_stats.side_flip == 2);
    for (unsigned i = 0; i < JUMP_SOURCE_COUNT; i++)
        assert(calls[i] == (i == WALL_JUMP ? 9 : i == SIDE_FLIP ? 6 : 3));

    for (unsigned source = 0; source < JUMP_SOURCE_COUNT; source++) {
        reset(); run_step(source, 0);
        assert(g_stats.inactive == 1 && !dm_odyssey_feedback_next(&event));
        dm_odyssey_feedback_set_active(1); run_step(source, 0);
        dm_odyssey_feedback_set_active(0); dm_odyssey_feedback_set_active(1);
        assert(!dm_odyssey_feedback_next(&event));
        deactivate_in_original = 1; run_step(source, 0);
        assert(g_stats.inactive == 2 && !dm_odyssey_feedback_next(&event));
        reset(); dm_odyssey_feedback_set_active(1); run_step(source, 0);
        test_time += 200000001;
        assert(!dm_odyssey_feedback_next(&event) && g_stats.expired == 1);
        run_step(source, 0); test_time--;
        assert(!dm_odyssey_feedback_next(&event) && g_stats.expired == 2);
    }
    assert(!dm_odyssey_feedback_next(NULL));
    reset(); dm_odyssey_feedback_set_active(1);
    for (int i = 0; i < 40; i++) run_step(i % 2, 0);
    assert(g_stats.overflowed == 8);
    for (int i = 9; i <= 40; i++) {
        assert(dm_odyssey_feedback_next(&event) && event.sequence == (uint64_t)i);
        assert(event.kind == ((i % 2) ? DM_ODYSSEY_LONG_JUMP : DM_ODYSSEY_ROLLING_JUMP));
    }
    assert(!dm_odyssey_feedback_next(&event));

    reset(); dm_odyssey_feedback_set_active(1);
    for (unsigned i = 0; i < 40; i++) run_step(i % JUMP_SOURCE_COUNT, 0);
    assert(g_stats.overflowed == 8 && g_stats.observed == 40);
    for (unsigned i = 8; i < 40; i++) {
        assert(dm_odyssey_feedback_next(&event) && event.sequence == i + 1);
        assert(event.kind == k_jumps[i % JUMP_SOURCE_COUNT].kind);
    }
    assert(!dm_odyssey_feedback_next(&event));

    reset(); memset(g_original, 0, sizeof g_original); g_wall_context_original = NULL; prepare_module();
    strcpy(g_mod[0].build_id, "00000000000000000000000000000000"); assert_rejected();
    strcpy(g_mod[0].build_id, k_build);
    for (unsigned i = 0; i < PROFILE_COUNT; i++) {
        const nerve_profile *p = profile_at(i);
        uint32_t offsets[] = { p->execute_off, p->execute_off + 4, p->name_off,
            p->typeinfo_off + 8, p->slot_off - 8, p->nerve_off, p->slot_off };
        for (unsigned j = 0; j < sizeof offsets / sizeof offsets[0]; j++) {
            g_mod[0].base[offsets[j]] ^= 1; assert_rejected(); g_mod[0].base[offsets[j]] ^= 1;
        }
    }
    for (unsigned word = 2; word < sizeof k_wall_context_words / sizeof k_wall_context_words[0]; word++) {
        uint32_t offset = k_wall_context.execute_off + word * 4;
        g_mod[0].base[offset] ^= 1; assert_rejected(); g_mod[0].base[offset] ^= 1;
    }
    size_t saved_size = g_mod[0].size;
    g_mod[0].size = 0x12b7900; assert_rejected(); g_mod[0].size = saved_size;
    uint64_t saved_data = g_mod[0].data_off;
    g_mod[0].data_off = 0x12b8500; assert_rejected(); g_mod[0].data_off = saved_data;
    uint32_t code[JUMP_SOURCE_COUNT][2];
    for (unsigned i = 0; i < JUMP_SOURCE_COUNT; i++)
        memcpy(code[i], g_mod[0].base + k_jumps[i].execute_off, sizeof code[i]);
    dm_odyssey_feedback_install(); assert(g_stats.installed);
    nerve_execute_fn expected[JUMP_SOURCE_COUNT] = {
        long_jump_execute, rolling_jump_execute, backflip_execute, wall_jump_execute, side_flip_execute,
    };
    for (unsigned i = 0; i < JUMP_SOURCE_COUNT; i++) {
        assert(*(nerve_execute_fn *)(g_mod[0].base + k_jumps[i].slot_off) == expected[i]);
        assert(g_original[i] == (nerve_execute_fn)(g_mod[0].base + k_jumps[i].execute_off));
        assert(!memcmp(code[i], g_mod[0].base + k_jumps[i].execute_off, sizeof code[i]));
    }
    assert(*(nerve_execute_fn *)(g_mod[0].base + k_wall_context.slot_off) == wall_context_execute);
    assert(g_wall_context_original == (nerve_execute_fn)(g_mod[0].base + k_wall_context.execute_off));
    assert(!memcmp(g_mod[0].base + k_wall_context.execute_off, k_wall_context_words, sizeof k_wall_context_words));
    dm_odyssey_feedback_install(); assert(g_stats.installed);
    free(g_mod[0].base);
    puts("PASS Odyssey: classic/rolling/backflip/wall/side first steps, pole exclusion and scoped wall context, unchanged five-long-jump and backflip regressions, mixed takeoffs/counters/delegates, expiry, ordering, lifecycle, all-or-none six-slot build/data/code guards");
    return 0;
}
