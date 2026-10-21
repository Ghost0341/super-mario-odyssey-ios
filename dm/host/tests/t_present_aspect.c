// Regression: a corrected projection may have a nonsquare render raster.
#include "../../gfx/nvn/nvn_present_viewport.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    dm_present_rect native = dm_present_fit(1600, 900, 2752, 2064, 0);
    assert(native.x == 0 && native.y == 258 && native.width == 2752 && native.height == 1548);
    dm_present_rect corrected = dm_present_fit(1600, 900, 2752, 2064, 4.0 / 3.0);
    assert(corrected.x == 0 && corrected.y == 0 && corrected.width == 2752 && corrected.height == 2064);
    dm_present_rect wide = dm_present_fit(1600, 900, 1920, 1080, 0);
    assert(wide.x == 0 && wide.y == 0 && wide.width == 1920 && wide.height == 1080);
    dm_present_rect square = dm_present_fit(900, 900, 1920, 1080, 0);
    assert(square.x == 420 && square.y == 0 && square.width == 1080 && square.height == 1080);
    puts("presentation: 4:3 logical geometry fills iPad; default raster/crop aspects preserved");
}
