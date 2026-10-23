// Exact-build live camera/HUD contract. Prepared 4:3 builds install both guarded
// adapters by default; an explicit DM_ODYSSEY_DYNAMIC_DISPLAY=0 opts out.
#pragma once
#include <stdint.h>

void dm_odyssey_display_install(void);
int dm_odyssey_display_enabled(void);
int dm_odyssey_display_request(double width, double height);
int dm_odyssey_display_geometry(double width, double height, double top, double left, double bottom, double right);
double dm_odyssey_display_aspect(void);
double dm_odyssey_display_scene_aspect(void);
void dm_odyssey_display_frame_boundary(void);
double dm_odyssey_display_source_aspect(void);
uint64_t dm_odyssey_display_source_generation(void);
typedef struct { double aspect, top, left, bottom, right; } dm_odyssey_display_layout;
void dm_odyssey_display_layout_snapshot(dm_odyssey_display_layout *out);

// Called only by the independently guarded HUD adapter before guest execution.
void dm_odyssey_display_hud_ready(void);

typedef struct {
    uint64_t configurations, matrix_reads, aspect_changes;
    int camera_installed, enabled;
    double requested_aspect, last_camera_aspect;
} dm_odyssey_display_stats;
void dm_odyssey_display_snapshot(dm_odyssey_display_stats *out);
