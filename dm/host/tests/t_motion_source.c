// Source selection, frame transforms, event age and touch-only guest motion.
#include "dm_motion_source.h"
#include "dm_feedback.h"
#include <stdio.h>
#include <math.h>

static int checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr, "motion check %d at line %d: %s\n", checks, __LINE__, #x); return 1; } } while (0)
static int close_to(double a, double b) { return fabs(a-b)<1e-6; }
int main(void) {
    const uint64_t t=5000000000ull;
    double out[3], v[3]={1,2,3};
    CHECK(dm_motion_rotate(DM_MOTION_LANDSCAPE_LEFT,v,out));
    CHECK(out[0]==2 && out[1]==-1 && out[2]==3);
    CHECK(dm_motion_rotate(DM_MOTION_LANDSCAPE_RIGHT,v,out));
    CHECK(out[0]==-2 && out[1]==1 && out[2]==3);
    for (int o=1;o<=4;o++) {
        double basis[3][3], axis[3]={0};
        for (int i=0;i<3;i++) { axis[i]=1; CHECK(dm_motion_rotate(o,axis,basis[i])); axis[i]=0; }
        CHECK(close_to(basis[0][0]*(basis[1][1]*basis[2][2]-basis[1][2]*basis[2][1])-
                       basis[0][1]*(basis[1][0]*basis[2][2]-basis[1][2]*basis[2][0])+
                       basis[0][2]*(basis[1][0]*basis[2][1]-basis[1][1]*basis[2][0]),1));
        double gravity[3]={0,0,-1}; CHECK(dm_motion_rotate(o,gravity,out)); CHECK(out[2]==-1);
        CHECK(dm_motion_rotate(o,v,out)); CHECK(close_to(out[0]*out[0]+out[1]*out[1]+out[2]*out[2],14));
    }
    double bad[3]={NAN,0,0}; CHECK(!dm_motion_rotate(3,bad,out)); CHECK(!dm_motion_rotate(0,v,out));
    CHECK(dm_motion_timestamp(10,10,t,t)==t);
    CHECK(dm_motion_timestamp(9.9,10,t,t)==t-100000000);
    CHECK(!dm_motion_timestamp(9.7,10,t,t)); CHECK(!dm_motion_timestamp(10.1,10,t,t));
    CHECK(!dm_motion_timestamp(INFINITY,10,t,t)); CHECK(!dm_motion_timestamp(-1,10,t,t));
    dm_motion_router r={0};
    dm_motion_configure(&r,DM_MOTION_AUTO,1,1,1); uint64_t gen=r.generation;
    CHECK(dm_motion_observe(&r,gen,1,t,t)); CHECK(dm_motion_choose(&r,t)==1);
    CHECK(dm_motion_observe(&r,gen,2,t,t)); CHECK(dm_motion_choose(&r,t)==1);
    CHECK(dm_motion_observe(&r,gen,2,t+210000000,t+210000000)); CHECK(dm_motion_choose(&r,t+210000000)==2);
    CHECK(dm_motion_observe(&r,gen,1,t+220000000,t+220000000)); CHECK(dm_motion_choose(&r,t+220000000)==2);
    CHECK(dm_motion_choose(&r,t+325000000)==2); // one cached probe sample cannot prove recovery
    CHECK(dm_motion_observe(&r,gen,1,t+330000000,t+330000000)); CHECK(dm_motion_choose(&r,t+330000000)==1);
    CHECK(dm_motion_choose(&r,t+600000000)==0);
    dm_motion_configure(&r,DM_MOTION_DEVICE,1,1,1);
    CHECK(!dm_motion_observe(&r,gen,2,t+700000000,t+700000000));
    CHECK(!dm_motion_observe(&r,r.generation,1,t+700000000,t+700000000));
    CHECK(dm_motion_observe(&r,r.generation,2,t+700000000,t+700000000)); CHECK(dm_motion_choose(&r,t+700000000)==2);
    dm_motion_configure(&r,DM_MOTION_CONTROLLER,1,0,1);
    CHECK(!dm_motion_observe(&r,r.generation,2,t,t)); CHECK(dm_motion_choose(&r,t)==0);
    dm_motion_configure(&r,DM_MOTION_OFF,1,1,1); CHECK(!dm_motion_observe(&r,r.generation,1,t,t));
    dm_motion_configure(&r,DM_MOTION_DEVICE,0,1,1); CHECK(!dm_motion_observe(&r,r.generation,2,t,t));
    dm_motion_configure(&r,DM_MOTION_DEVICE,1,0,1); gen=r.generation;
    CHECK(!dm_motion_observe(&r,gen,2,t+1,t)); CHECK(!dm_motion_observe(&r,gen,2,t,t+DM_MOTION_LEASE_NS+1));
    CHECK(dm_motion_observe(&r,gen,2,t,t)); CHECK(!dm_motion_observe(&r,gen,2,t,t));
    dm_motion_configure(&r,DM_MOTION_DEVICE,1,0,1); CHECK(r.selected==0 && !r.last[2]);

    const double acc[3]={0,0,-1}, gyro[3]={0,0,6.283185307179586};
    dm_six_axis_state state[2];
    dm_feedback_set_device(0,1,0,t); dm_feedback_six_start(0x20003);
    uint64_t e=dm_feedback_motion_begin(1);
    CHECK(dm_feedback_motion_push(e,acc,gyro,NULL,t));
    CHECK(dm_feedback_six_read(0x20003,state,2,t)==1 && state[0].attributes==1 && close_to(state[0].gyro[2],1));
    CHECK(dm_feedback_six_read(0x20003,state,2,t+DM_MOTION_LEASE_NS+1)==0 && state[0].attributes==0);
    uint64_t old=e; e=dm_feedback_motion_begin(1);
    CHECK(dm_feedback_six_read(0x20003,state,2,t)==0);
    CHECK(!dm_feedback_motion_push(old,acc,gyro,NULL,t+1)); CHECK(dm_feedback_motion_push(e,acc,gyro,NULL,t+2));
    CHECK(dm_feedback_six_read(0x20003,state,2,t+2)==1);
    CHECK(close_to(state[0].angle[2],.004)); // reference reset, not the prior source's accumulated angle
    e=dm_feedback_motion_begin(0); CHECK(!dm_feedback_motion_push(e,acc,gyro,NULL,t+3));
    CHECK(dm_feedback_six_read(0x20003,state,2,t+3)==0);
    dm_feedback_set_device(1,1,7,t+10);
    dm_vibration_value rumble={.2f,160,.3f,320}; dm_feedback_vibration_send(3,&rumble,t+11);
    dm_feedback_output before,after; dm_feedback_poll(t+12,&before);
    e=dm_feedback_motion_begin(1); CHECK(dm_feedback_motion_push(e,acc,gyro,NULL,t+13));
    dm_feedback_poll(t+14,&after); CHECK(before.epoch==after.epoch && after.value[0].amp_low==.2f && after.value[0].amp_high==.3f);
    dm_feedback_set_device(1,0,7,t+15); CHECK(!dm_feedback_motion_push(e,acc,gyro,NULL,t+16));
    CHECK(dm_feedback_six_read(0x20003,state,2,t+16)==0);
    dm_feedback_set_device(1,1,7,t+17); CHECK(!dm_feedback_motion_push(e,acc,gyro,NULL,t+18));
    e=dm_feedback_motion_begin(1); CHECK(dm_feedback_motion_push(e,acc,gyro,NULL,t+19));
    printf("PASS: %d motion source/transform/lease checks\n",checks); return 0;
}
