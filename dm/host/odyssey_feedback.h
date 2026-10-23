// Build-gated observations of Odyssey gameplay transitions for optional controller effects.
#ifndef DM_ODYSSEY_FEEDBACK_H
#define DM_ODYSSEY_FEEDBACK_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    DM_ODYSSEY_LONG_JUMP = 1,
    DM_ODYSSEY_ROLLING_JUMP = 2,
    DM_ODYSSEY_BACKFLIP = 3,
    DM_ODYSSEY_WALL_JUMP = 4,
    DM_ODYSSEY_SIDE_FLIP = 5,
    DM_ODYSSEY_NORMAL_JUMP = 6,
    DM_ODYSSEY_LANDING = 7,
    DM_ODYSSEY_CAP_THROW = 8,
    DM_ODYSSEY_COIN = 9,
    DM_ODYSSEY_GROUND_POUND_START = 10,
    DM_ODYSSEY_GROUND_POUND_IMPACT = 11,
} dm_odyssey_feedback_kind;

typedef struct {
    uint64_t sequence;
    uint64_t timestamp_ns;
    dm_odyssey_feedback_kind kind;
    float strength;
} dm_odyssey_feedback_event;

typedef struct {
    uint64_t observed, queued, delivered, expired, overflowed, inactive;
    uint64_t classic_long_jump, rolling_jump, backflip, wall_jump, side_flip;
    int installed, active;
} dm_odyssey_feedback_stats;

// Call after relocation and before guest execution. Unsupported builds are left untouched.
void dm_odyssey_feedback_install(void);
// A disconnected or inactive front end drops pending events; reactivation never replays them.
void dm_odyssey_feedback_set_active(int active);
// Drain on the controller's serial update queue. Events older than 200 ms are discarded.
int dm_odyssey_feedback_next(dm_odyssey_feedback_event *out);
void dm_odyssey_feedback_get_stats(dm_odyssey_feedback_stats *out);
// Local-only events share sequence identity, never the controller's bounded queue.
uint64_t dm_odyssey_feedback_reserve_sequence(void);
static inline int dm_odyssey_feedback_controller_kind(dm_odyssey_feedback_kind kind) {
    return kind>=DM_ODYSSEY_LONG_JUMP&&kind<=DM_ODYSSEY_SIDE_FLIP;
}

#ifdef __cplusplus
}
#endif
#endif
