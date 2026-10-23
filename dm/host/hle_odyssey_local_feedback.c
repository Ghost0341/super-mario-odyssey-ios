// Device-only cues from guarded Odyssey 1.4.1 Nerve first steps. Original
// delegates and the legacy controller observer/queue/policy remain separate.
#include "dm.h"
#include "odyssey_local_feedback.h"
typedef void (*local_execute_fn)(const void *,void *);
typedef struct {
    const char *name;
    uint32_t name_off,typeinfo,slot,singleton,execute,branch;
    dm_odyssey_feedback_kind kind;
} local_profile;
static const local_profile profiles[]={
 {"N12_GLOBAL__N_122PlayerStateJumpNrvJumpE",0xef2150,0x12b7620,0x12b7608,0x12b7838,0x4150f0,0x17fff9b7,DM_ODYSSEY_NORMAL_JUMP},
 {"N12_GLOBAL__N_122PlayerStateWaitNrvLandE",0xef36b0,0x12b9610,0x12b95f8,0x12b98b8,0x42d090,0x17fffa5f,DM_ODYSSEY_LANDING},
 {"N12_GLOBAL__N_120HackCapNrvThrowStartE",0xeef1c0,0x12b0710,0x12b06f8,0x12b0b38,0x3af160,0x17ffd62b,DM_ODYSSEY_CAP_THROW},
 {"N12_GLOBAL__N_110CoinNrvGotE",0xec3320,0x11faca0,0x11fac88,0x11fb020,0x1a0040,0x17fffe9f,DM_ODYSSEY_COIN},
 {"N12_GLOBAL__N_112Coin2DNrvGotE",0xec3640,0x11fb550,0x11fb538,0x11fb610,0x1a09d0,0x17ffff67,DM_ODYSSEY_COIN},
 {"N12_GLOBAL__N_126PlayerStateHipDropNrvStartE",0xef2040,0x12b74e0,0x12b74c8,0x12b7578,0x411e80,0x17fffebf,DM_ODYSSEY_GROUND_POUND_START},
 {"N12_GLOBAL__N_125PlayerStateHipDropNrvLandE",0xef2070,0x12b7520,0x12b7508,0x12b7518,0x411e90,0x17ffff83,DM_ODYSSEY_GROUND_POUND_IMPACT},
};
enum { LOCAL_SOURCES=sizeof profiles/sizeof *profiles, LOCAL_CAPACITY=32 };
static local_execute_fn originals[LOCAL_SOURCES];
static pthread_mutex_t local_lock=PTHREAD_MUTEX_INITIALIZER;
static dm_odyssey_feedback_event pending[LOCAL_CAPACITY];
static dm_odyssey_local_stats stats;
static unsigned head,count;
static uint64_t local_epoch;
static void local_execute(unsigned index,const void *nerve,void *spine) {
    int32_t step=-1;
    if (spine) memcpy(&step,(const uint8_t *)spine+0x18,sizeof step);
    pthread_mutex_lock(&local_lock); uint64_t epoch=local_epoch; pthread_mutex_unlock(&local_lock);
    uint64_t at=step==0?now_ns():0;
    originals[index](nerve,spine);
    if (step!=0) return;
    pthread_mutex_lock(&local_lock);
    unsigned kind=profiles[index].kind;
    ++stats.observed[kind-DM_ODYSSEY_NORMAL_JUMP];
    if (stats.active&&epoch==local_epoch) {
        if (count==LOCAL_CAPACITY) { head=(head+1)%LOCAL_CAPACITY;--count;++stats.overflowed; }
        pending[(head+count++)%LOCAL_CAPACITY]=(dm_odyssey_feedback_event){
            .sequence=dm_odyssey_feedback_reserve_sequence(),.timestamp_ns=at,.kind=kind,.strength=1};
    }
    pthread_mutex_unlock(&local_lock);
}
#define LOCAL_WRAPPER(n) static void local_##n(const void *nerve,void *spine) { local_execute(n,nerve,spine); }
LOCAL_WRAPPER(0) LOCAL_WRAPPER(1) LOCAL_WRAPPER(2) LOCAL_WRAPPER(3)
LOCAL_WRAPPER(4) LOCAL_WRAPPER(5) LOCAL_WRAPPER(6)
static int local_guard(const module_t *m,const local_profile *p) {
    uint64_t name=p->name_off,ti=p->typeinfo,slot=p->slot,singleton=p->singleton,execute=p->execute;
    const uint8_t *b=m->base; size_t length=strlen(p->name)+1;
    uint32_t words[2]={0xf9400020,p->branch};
    return b&&m->text_end<=m->size&&name<=m->size&&length<=m->size-name&&
        ti<=m->size&&16<=m->size-ti&&slot>=8&&slot<=m->size&&8<=m->size-slot&&
        singleton<=m->size&&8<=m->size-singleton&&slot>=m->data_off&&slot>=m->text_end&&
        execute<=m->text_end&&sizeof words<=m->text_end-execute&&
        !memcmp(b+name,p->name,length)&&!memcmp(b+execute,words,sizeof words)&&
        *(const uintptr_t *)(b+ti+8)==(uintptr_t)(b+name)&&
        *(const uintptr_t *)(b+slot-8)==(uintptr_t)(b+ti)&&
        *(const uintptr_t *)(b+slot)==(uintptr_t)(b+execute)&&
        *(const uintptr_t *)(b+singleton)==(uintptr_t)(b+slot);
}
void dm_odyssey_local_feedback_install(void) {
    if (originals[0]) return;
    module_t *m=NULL;
    for (int i=0;i<g_nmod;i++) if (!strcmp(g_mod[i].name,"main")) { m=&g_mod[i];break; }
    if (!m||strcmp(m->build_id,"b424be150a8e7d78701cbe7a439d9ebf")) return;
    for (unsigned i=0;i<LOCAL_SOURCES;i++) if (!local_guard(m,&profiles[i])) {
        LOG("[RED] Odyssey local feedback guard failed; local additions disabled, controller observers preserved");return;
    }
    local_execute_fn wrappers[]={local_0,local_1,local_2,local_3,local_4,local_5,local_6};
    for (unsigned i=0;i<LOCAL_SOURCES;i++) {
        originals[i]=(local_execute_fn)(m->base+profiles[i].execute);
        *(local_execute_fn *)(m->base+profiles[i].slot)=wrappers[i];
    }
    pthread_mutex_lock(&local_lock);stats.installed=1;pthread_mutex_unlock(&local_lock);
}
void dm_odyssey_local_feedback_set_active(int active) {
    pthread_mutex_lock(&local_lock);
    if (stats.active!=!!active||!active) { ++local_epoch; head=count=0; }
    stats.active=!!active;pthread_mutex_unlock(&local_lock);
}
int dm_odyssey_local_feedback_next(dm_odyssey_feedback_event *event) {
    if (!event) return 0;
    pthread_mutex_lock(&local_lock);uint64_t now=now_ns();
    while (stats.active&&count) {
        dm_odyssey_feedback_event next=pending[head]; head=(head+1)%LOCAL_CAPACITY;--count;
        if (!next.timestamp_ns||next.timestamp_ns>now||now-next.timestamp_ns>200000000ull) { ++stats.expired;continue; }
        *event=next;++stats.delivered;pthread_mutex_unlock(&local_lock);return 1;
    }
    pthread_mutex_unlock(&local_lock);return 0;
}
void dm_odyssey_local_feedback_stats(dm_odyssey_local_stats *out) {
    if (!out) return;pthread_mutex_lock(&local_lock);*out=stats;pthread_mutex_unlock(&local_lock);
}
