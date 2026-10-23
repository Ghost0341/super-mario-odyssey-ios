// Exact-build, device-only action observers; no controller output or button cues.
#pragma once
#include "odyssey_feedback.h"
typedef struct {
    uint64_t observed[6], delivered, expired, overflowed;
    int installed, active;
} dm_odyssey_local_stats;
void dm_odyssey_local_feedback_install(void);
void dm_odyssey_local_feedback_set_active(int active);
int dm_odyssey_local_feedback_next(dm_odyssey_feedback_event *event);
void dm_odyssey_local_feedback_stats(dm_odyssey_local_stats *stats);
