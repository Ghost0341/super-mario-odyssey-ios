// Presentation/interpolation geometry belongs to the recorded game frame.
#pragma once
#include <math.h>
#include <stdint.h>
static inline int nvn_frame_geometry_equal(double a, uint64_t ag, double b, uint64_t bg) {
    return isfinite(a) && isfinite(b) && a >= 0 && b >= 0 && a == b && ag == bg;
}
