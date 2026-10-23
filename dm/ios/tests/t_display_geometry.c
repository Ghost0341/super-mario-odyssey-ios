// Pure geometry regression: repeated posture changes, invalid intermediates,
// display-scale migration and qualified/aspect-preserving title paths.
#include "dm_display_geometry.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    const double sizes[][2]={{678,466},{951,669},{466,678},{669,951},{1376,1032},{956,440}};
    const double aspects[]={4.0/3,239.0/110,16.0/9};
    unsigned transitions=0;
    for (unsigned a=0;a<sizeof aspects/sizeof *aspects;a++) {
        dm_display_geometry last={0};
        for (unsigned loop=0;loop<20;loop++) for (unsigned n=0;n<sizeof sizes/sizeof *sizes;n++) {
            dm_display_geometry g=dm_display_make(sizes[n][0],sizes[n][1],3,aspects[a]);
            assert(g.valid && g.picture.width>0 && g.picture.height>0);
            assert(g.picture.x>=0 && g.picture.y>=0);
            assert(g.picture.x+g.picture.width<=sizes[n][0]+.001);
            assert(g.picture.y+g.picture.height<=sizes[n][1]+.001);
            assert(fabs(g.picture.width/g.picture.height-aspects[a])<1e-9);
            assert(dm_display_drawable_changed(last,g)); transitions++;
            assert(!dm_display_drawable_changed(g,g));
            assert(!dm_display_drawable_changed(g,dm_display_make(0,0,3,aspects[a])));
            last=g;
        }
    }
    dm_display_geometry g=dm_display_make(678,466,3,4.0/3);
    assert(dm_display_drawable_changed(g,dm_display_make(678,466,2,4.0/3)));
    assert(!dm_display_make(NAN,466,3,4.0/3).valid);
    assert(!dm_display_make(678,INFINITY,3,4.0/3).valid);
    assert(!dm_display_make(678,466,0,4.0/3).valid);
    assert(!dm_display_make(678,466,3,0).valid);
    assert(!dm_display_make(20000,466,3,4.0/3).valid);
    dm_display_geometry native=dm_display_make(951,669,3,951.0/669);
    assert(native.picture.x==0 && native.picture.y==0);
    printf("PASS: %u live geometry transitions, scale changes and invalid intermediates\n",transitions);
}
