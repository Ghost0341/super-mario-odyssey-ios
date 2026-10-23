// Synthetic first steps, exact-profile fail-closed guards, and controller isolation.
#include "../hle_odyssey_feedback.c"
#include "../hle_odyssey_local_feedback.c"
#include <assert.h>
module_t g_mod[MAX_MOD]; int g_nmod;
static uint64_t time_ns=1000000000;
uint64_t now_ns(void) { return time_ns; }
static unsigned delegate_calls;
static int transition;
static void original(const void *nerve,void *spine) {
    (void)nerve;(void)spine;++delegate_calls;
    if (transition) { dm_odyssey_local_feedback_set_active(0);dm_odyssey_local_feedback_set_active(1); }
}
static void step(unsigned index,int32_t value) {
    uint8_t spine[0x30]={0};memcpy(spine+0x18,&value,sizeof value);local_execute(index,NULL,spine);
}
static void fixture(void) {
    memset(originals,0,sizeof originals);memset(&stats,0,sizeof stats);head=count=0;
    uint8_t *b=g_mod[0].base;
    for (unsigned i=0;i<LOCAL_SOURCES;i++) {
        const local_profile *p=&profiles[i];uint32_t words[]={0xf9400020,p->branch};
        memcpy(b+p->name_off,p->name,strlen(p->name)+1);memcpy(b+p->execute,words,sizeof words);
        *(uintptr_t *)(b+p->typeinfo+8)=(uintptr_t)(b+p->name_off);
        *(uintptr_t *)(b+p->slot-8)=(uintptr_t)(b+p->typeinfo);
        *(uintptr_t *)(b+p->slot)=(uintptr_t)(b+p->execute);
        *(uintptr_t *)(b+p->singleton)=(uintptr_t)(b+p->slot);
    }
}
int main(void) {
    dm_odyssey_feedback_event event;
    for (unsigned i=0;i<LOCAL_SOURCES;i++) originals[i]=original;
    dm_odyssey_local_feedback_set_active(1);
    for (unsigned i=0;i<LOCAL_SOURCES;i++) {
        unsigned before=delegate_calls;
        step(i,-1);step(i,0);step(i,1);step(i,30);
        assert(delegate_calls==before+4);
        assert(dm_odyssey_local_feedback_next(&event));
        assert(event.kind==profiles[i].kind&&event.timestamp_ns==time_ns&&event.strength==1);
        assert(!dm_odyssey_feedback_controller_kind(event.kind));
        assert(!dm_odyssey_local_feedback_next(&event));++time_ns;
    }
    transition=1;step(0,0);assert(!dm_odyssey_local_feedback_next(&event));transition=0;
    step(0,0);dm_odyssey_local_feedback_set_active(0);dm_odyssey_local_feedback_set_active(1);
    assert(!dm_odyssey_local_feedback_next(&event));
    step(0,0);time_ns+=200000001;assert(!dm_odyssey_local_feedback_next(&event)&&stats.expired==1);
    step(0,0);--time_ns;assert(!dm_odyssey_local_feedback_next(&event)&&stats.expired==2);++time_ns;
    // Flood local coins while one controller takeoff is pending. Both actual
    // queues share monotonically increasing identities, never capacity/eviction.
    dm_odyssey_feedback_set_active(1);observe_jump(CLASSIC_JUMP,observe_begin(),time_ns);
    uint64_t controller_sequence=g_sequence;
    for (unsigned i=0;i<50;i++) step(3,0);
    assert(stats.overflowed==18&&g_count==1);
    assert(dm_odyssey_feedback_next(&event)&&event.kind==DM_ODYSSEY_LONG_JUMP&&event.sequence==controller_sequence);
    assert(!dm_odyssey_feedback_next(&event));
    uint64_t previous=controller_sequence;unsigned n=0;
    while (dm_odyssey_local_feedback_next(&event)) {
        assert(event.sequence>previous&&event.kind==DM_ODYSSEY_COIN);previous=event.sequence;++n;
    }
    assert(n==32);
    // All-or-none local installation. A malformed optional local profile never
    // changes a controller slot or leaves only part of the local set installed.
    g_nmod=1;strcpy(g_mod[0].name,"main");strcpy(g_mod[0].build_id,k_build);
    g_mod[0].size=0x12c0000;g_mod[0].text_end=0xa30000;g_mod[0].data_off=0x1100000;
    g_mod[0].base=calloc(1,g_mod[0].size);assert(g_mod[0].base);
    for (unsigned i=0;i<LOCAL_SOURCES;i++) for (unsigned field=0;field<4;field++) {
        fixture();const local_profile *p=&profiles[i];
        uintptr_t before[LOCAL_SOURCES];for (unsigned j=0;j<LOCAL_SOURCES;j++) before[j]=*(uintptr_t *)(g_mod[0].base+profiles[j].slot);
        uint32_t off=field==0?p->name_off:field==1?p->execute:field==2?p->typeinfo+8:p->singleton;
        g_mod[0].base[off]^=1;dm_odyssey_local_feedback_install();assert(!stats.installed);
        for (unsigned j=0;j<LOCAL_SOURCES;j++) assert(!originals[j]&&*(uintptr_t *)(g_mod[0].base+profiles[j].slot)==before[j]);
    }
    fixture();dm_odyssey_local_feedback_install();assert(stats.installed);
    for (unsigned i=0;i<LOCAL_SOURCES;i++) assert(originals[i]&&(uintptr_t)originals[i]==(uintptr_t)(g_mod[0].base+profiles[i].execute));
    free(g_mod[0].base);
    puts("PASS: 7 local observer sources, first-step/delegate/expiry/epoch/guard checks and controller queue isolation");return 0;
}
