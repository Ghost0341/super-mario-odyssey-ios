// Fit the logical picture independently of its render raster's pixel aspect.
#pragma once
#include <math.h>
typedef struct { double x, y, width, height; } dm_present_rect;
static inline dm_present_rect dm_present_fit(double sw, double sh, double dw, double dh, double aspect) {
    // Explicit aspect is only supplied with a game's matching projection/HUD
    // correction. Other profiles retain the actual source crop's aspect ratio.
    double logical_w = aspect > 0 ? sh * aspect : sw;
    double scale = fmin(dw / logical_w, dh / sh);
    dm_present_rect rect = {floor((dw - logical_w * scale) / 2), floor((dh - sh * scale) / 2),
                           round(logical_w * scale), round(sh * scale)};
    if (fabs((dw / dh) / (logical_w / sh) - 1) < 0.01) rect = (dm_present_rect){0, 0, dw, dh};
    return rect;
}
