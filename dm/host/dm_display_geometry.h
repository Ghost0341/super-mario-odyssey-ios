// Scene geometry contract: preserve the verified camera/HUD aspect during live
// resize unless the title has independently qualified a dynamic aspect path.
#pragma once
#include <math.h>
#include <stdint.h>

typedef struct { double x, y, width, height; } dm_display_rect;
typedef struct {
    int valid;
    dm_display_rect picture;
    double scale;
    uint32_t pixel_width, pixel_height;
} dm_display_geometry;

static inline dm_display_geometry dm_display_make(double width, double height, double scale, double aspect) {
    dm_display_geometry g = {0};
    if (!isfinite(width) || !isfinite(height) || !isfinite(scale) || !isfinite(aspect) ||
        width <= 0 || height <= 0 || scale <= 0 || aspect <= 0 ||
        width*scale > 16384 || height*scale > 16384) return g;
    double w=width, h=height;
    if (w/h > aspect) w=h*aspect; else h=w/aspect;
    if (w*scale < 1 || h*scale < 1) return g;
    g.valid=1; g.scale=scale;
    g.picture=(dm_display_rect){(width-w)/2, (height-h)/2, w, h};
    g.pixel_width=(uint32_t)floor(w*scale+.5);
    g.pixel_height=(uint32_t)floor(h*scale+.5);
    return g;
}

static inline int dm_display_drawable_changed(dm_display_geometry a, dm_display_geometry b) {
    return b.valid && (!a.valid || a.pixel_width!=b.pixel_width || a.pixel_height!=b.pixel_height || a.scale!=b.scale);
}
