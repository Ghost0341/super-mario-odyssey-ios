// Included after pq_item. Owned snapshots release the game's swapchain before
// the independent, bounded interpolation worker runs. All queue state uses g_pq_mu.
@interface NVNFGPending : NSObject
@property(nonatomic, strong) NVNFrameGenCapture *capture;
@property(nonatomic) uint64_t epoch;
@end
@implementation NVNFGPending
@end

static NVNFrameGenerator *g_fg;
static NSMutableArray<NVNFGPending *> *g_fg_captures;
static NSMutableArray<NVNFrameGenOutput *> *g_fg_outputs;
static NVNFrameGenOutput *g_fg_latest;
static int g_fg_owner, g_fg_capture_busy, g_native_present_busy, g_fg_disabled, g_fg_capture_failures;
static int g_fg_paused, g_fg_display_submit_busy;
static uint64_t g_fg_epoch = 1, g_fg_last_native, g_fg_captured, g_fg_capture_dropped, g_fg_output_dropped;
static double g_fg_refresh = 120, g_fg_last_target, g_fg_cooldown, g_fg_last_submit;
static uint64_t g_fg_starvation_fallbacks;
static int g_fg_slow;
static _Atomic uint64_t g_fg_generated, g_fg_native_displayed;
static _Atomic double g_fg_latency_ms;

static int fg_requested(void) {
    static int value = -1;
    if (value < 0) {
        const char *e = getenv("DM_FRAMEGEN");
        value = e ? atoi(e) != 0 : DM_GAME_FRAME_GENERATION;
    }
    return value;
}
uint64_t mtl_framegen_generated_count(void) { return atomic_load(&g_fg_generated); }

static void fg_invalidate_locked(void) {
    g_fg_epoch++;
    [g_fg_captures removeAllObjects]; [g_fg_outputs removeAllObjects];
    g_fg_latest = nil; g_fg_last_native = 0;
    g_fg_last_submit = 0; g_fg_last_target = 0; g_fg_refresh = 120; g_fg_slow = 0;
    pthread_cond_broadcast(&g_pq_cv);
}

// A reservation, rather than a lock held across Metal, closes the lifecycle
// race. Presented handlers are allowed to synchronously reenter queue state.
static void fg_suspend_submissions(void) {
    pthread_mutex_lock(&g_pq_mu);
    g_fg_paused = 1; atomic_store(&g_present_discard, 1); fg_invalidate_locked();
    pthread_mutex_unlock(&g_pq_mu);
    g_fg.suspended = YES;
}
static void fg_resume_submissions(void) {
    pthread_mutex_lock(&g_pq_mu); BOOL disabled = g_fg_disabled != 0; pthread_mutex_unlock(&g_pq_mu);
    g_fg.suspended = disabled;
    pthread_mutex_lock(&g_pq_mu);
    g_fg_paused = 0; atomic_store(&g_present_discard, 0);
    pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);
}

static void *fg_process_main(void *arg) {
    (void)arg; pthread_setname_np("nvn-framegen-model");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    uint64_t history_epoch = 0;
    for (;;) @autoreleasepool {
        pthread_mutex_lock(&g_pq_mu);
        while (!g_fg_captures.count || g_fg_paused || atomic_load(&g_present_discard)) pthread_cond_wait(&g_pq_cv, &g_pq_mu);
        NVNFGPending *pending = g_fg_captures.firstObject; [g_fg_captures removeObjectAtIndex:0];
        uint64_t epoch = g_fg_epoch;
        BOOL interpolate = g_fg_refresh >= 100 && CACurrentMediaTime() >= g_fg_cooldown && mtl_fps_target() == 60;
        pthread_mutex_unlock(&g_pq_mu);
        if (pending.epoch != epoch) continue;
        if (history_epoch && history_epoch != epoch) [g_fg resetHistory];
        history_epoch = epoch;
        g_fg.interpolationEnabled = interpolate;
        double start = CACurrentMediaTime();
        NSArray<NVNFrameGenOutput *> *outputs = [g_fg processCapture:pending.capture];
        double elapsed = CACurrentMediaTime() - start;
        BOOL modelReady = g_fg.interpolationReady;
        pthread_mutex_lock(&g_pq_mu);
        // Repeated model overruns degrade to native snapshots for five seconds.
        // Neither the game thread nor the capture worker waits for this worker.
        if (interpolate && modelReady && elapsed > 0.022) g_fg_slow++;
        else if (outputs.count == 2) g_fg_slow = 0; // Fast native-only calls between overruns are not successful model samples.
        if (g_fg_slow >= 3) { g_fg_cooldown = CACurrentMediaTime() + 5; g_fg_slow = 0; }
        if (pending.epoch == g_fg_epoch && !g_fg_paused && !atomic_load(&g_present_discard)) {
            double now = CACurrentMediaTime();
            for (NVNFrameGenOutput *out in outputs) {
                if (out.ticket > g_fg_last_native && now - out.enqueuedTime < 0.075) [g_fg_outputs addObject:out];
                else g_fg_output_dropped++;
            }
            // Drop complete oldest pairs, preserving midpoint-before-source order.
            while (g_fg_outputs.count > 4) {
                uint64_t obsolete = g_fg_outputs.firstObject.ticket;
                while (g_fg_outputs.count && g_fg_outputs.firstObject.ticket == obsolete) {
                    [g_fg_outputs removeObjectAtIndex:0]; g_fg_output_dropped++;
                }
            }
        }
        pthread_mutex_unlock(&g_pq_mu);
    }
    return NULL;
}

static void fg_write_stats(void) {
    NSMutableDictionary *stats = [[g_fg stats] mutableCopy];
    pthread_mutex_lock(&g_pq_mu);
    [stats addEntriesFromDictionary:@{
        @"mode": @"60 Hz simulation; optional 120 Hz generated presentation",
        @"captureOwner": @(g_fg_owner), @"epoch": @(g_fg_epoch),
        @"paused": @(g_fg_paused), @"displaySubmitBusy": @(g_fg_display_submit_busy),
        @"nativeFallback": @(g_fg_disabled), @"consecutiveCaptureFailures": @(g_fg_capture_failures),
        @"sourceSnapshots": @(g_fg_captured), @"pendingCaptures": @(g_fg_captures.count),
        @"pendingOutputs": @(g_fg_outputs.count), @"captureDrops": @(g_fg_capture_dropped),
        @"outputDrops": @(g_fg_output_dropped), @"callbackHz": @(g_fg_refresh),
        @"starvationFallbacks": @(g_fg_starvation_fallbacks),
        @"displayedFrames": @(atomic_load(&g_fg_displayed)),
        @"generatedFramesDisplayed": @(atomic_load(&g_fg_generated)),
        @"nativeFramesDisplayed": @(atomic_load(&g_fg_native_displayed)),
        @"latestDisplayLatencyMs": @(atomic_load(&g_fg_latency_ms)),
        @"cooldownSeconds": @(fmax(0, g_fg_cooldown - CACurrentMediaTime())),
        @"timestamp": @(CACurrentMediaTime()) }];
    pthread_mutex_unlock(&g_pq_mu);
    NSString *path = nil;
    const char *e = getenv("DM_FRAMEGEN_STATS"); if (e) path = @(e);
#if TARGET_OS_IPHONE
    if (!path) path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"frame-generation.json"];
#endif
    if (path) [[NSJSONSerialization dataWithJSONObject:stats options:NSJSONWritingPrettyPrinted error:nil] writeToFile:path options:NSDataWritingAtomic error:nil];
}

static void fg_start(void) {
    if (!fg_requested() || mtl_display_hz() < 100) return;
    g_fg = [[NVNFrameGenerator alloc] initWithDevice:g_dev];
    g_fg_captures = [NSMutableArray new]; g_fg_outputs = [NSMutableArray new];
    g_dm_present_link = 2;
    pthread_t th; if (pthread_create(&th, NULL, fg_process_main, NULL)) MDIE("cannot start frame generation worker"); pthread_detach(th);
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{ @autoreleasepool { fg_write_stats(); } }); dispatch_resume(timer);
    MLOG("frame generation requested: independent 60 Hz game pacing, up to 120 Hz output; DM_FRAMEGEN=0 disables");
}

// Capture worker only: source is copied behind the rendering event into owned
// RGB storage. Returning from this function makes the original swapchain reusable.
static void fg_capture(pq_item it, uint64_t ticket, uint64_t epoch) {
    NVNFrameGenCapture *capture = nil;
    @autoreleasepool {
        id<MTLTexture> src = tex_mtl(&it.t);
        if (src) {
            MTLRegion crop = MTLRegionMake2D(0, 0, src.width, src.height);
            BOOL valid = YES;
            if (it.crop[2] || it.crop[3]) {
                valid = it.crop[0] >= 0 && it.crop[1] >= 0 && it.crop[2] > 0 && it.crop[3] > 0 &&
                    (uint64_t)it.crop[0] + it.crop[2] <= src.width && (uint64_t)it.crop[1] + it.crop[3] <= src.height;
                if (valid) crop = MTLRegionMake2D(it.crop[0], it.crop[1], it.crop[2], it.crop[3]);
            }
            if (valid) capture = [g_fg captureSource:src crop:crop originLowerLeft:it.origin_ll
                ticket:ticket gameFrame:it.frame enqueuedTime:it.t_in
                waitEvent:it.ev_val && g_ext_ev ? g_ext_ev : g_ev waitValue:it.ev_val ?: it.render_fence];
        }
    }
    pthread_mutex_lock(&g_pq_mu);
    BOOL failed = !capture && epoch == g_fg_epoch && !g_fg_paused && !atomic_load(&g_present_discard);
    if (failed) g_fg_capture_failures++; else if (capture) g_fg_capture_failures = 0;
    if (g_fg_capture_failures >= 3) {
        // Persistent format/allocation/GPU failure returns ownership to the
        // proven native presenter after all independent GPU work is quiescent.
        g_fg_disabled = 1; g_fg_paused = 1; fg_invalidate_locked();
        pthread_mutex_unlock(&g_pq_mu); g_fg.suspended = YES; pthread_mutex_lock(&g_pq_mu);
        while (g_fg_display_submit_busy) pthread_cond_wait(&g_pq_cv, &g_pq_mu);
        pthread_mutex_unlock(&g_pq_mu); [g_fg drainGPU]; pthread_mutex_lock(&g_pq_mu);
        g_fg_owner = 0;
        g_fg_paused = atomic_load(&g_present_discard) != 0;
        MLOG("frame generation capture failed repeatedly; native 60 Hz presentation restored");
    }
    g_fg_capture_busy = 0;
    if (ticket > g_pq_done) g_pq_done = ticket;
    if (capture && epoch == g_fg_epoch && !g_fg_paused && !atomic_load(&g_present_discard)) {
        g_fg_captured++; g_fg_latest = capture.sourceOutput;
        // No waiting for the model: discard older *owned copies*, never game storage.
        while (g_fg_captures.count >= 2) { [g_fg_captures removeObjectAtIndex:0]; g_fg_capture_dropped++; }
        NVNFGPending *pending = [NVNFGPending new]; pending.capture = capture; pending.epoch = epoch;
        [g_fg_captures addObject:pending];
    }
    pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);
}

// Display-link worker only. No GPU waits or model work; consume one ready output.
static int fg_display(CAMetalDisplayLinkUpdate *update) {
    BOOL modelReady = g_fg.interpolationReady;
    pthread_mutex_lock(&g_pq_mu);
    if (!g_fg_owner) { pthread_mutex_unlock(&g_pq_mu); return 0; }
    if (g_fg_disabled || g_fg_paused || atomic_load(&g_present_discard)) { pthread_mutex_unlock(&g_pq_mu); return 1; }
    double now = CACurrentMediaTime(), target = update.targetPresentationTimestamp;
    if (g_fg_last_target > 0 && target - g_fg_last_target > 0.004 && target - g_fg_last_target < 0.04)
        g_fg_refresh = 0.9 * g_fg_refresh + 0.1 / (target - g_fg_last_target);
    g_fg_last_target = target;
    BOOL nativeOnly = g_fg_refresh < 100 || now < g_fg_cooldown || !modelReady || mtl_fps_target() != 60;
    NVNFrameGenOutput *out = nil;
    while (g_fg_outputs.count) {
        NVNFrameGenOutput *candidate = g_fg_outputs.firstObject; [g_fg_outputs removeObjectAtIndex:0];
        if (candidate.ticket <= g_fg_last_native || now - candidate.enqueuedTime > 0.075 || (nativeOnly && candidate.generated)) { g_fg_output_dropped++; continue; }
        out = candidate; break;
    }
    if (!out && g_fg_latest.ticket > g_fg_last_native) {
        // A continuously refreshed latest snapshot never becomes "old". Measure
        // silence at the display output instead, then remain native for a while.
        if (!nativeOnly && g_fg_last_submit > 0 && now - g_fg_last_submit > 0.035) {
            g_fg_cooldown = now + 5; g_fg_starvation_fallbacks++; nativeOnly = YES;
        }
        if (nativeOnly || g_fg_last_submit == 0) out = g_fg_latest;
    }
    if (!out) { pthread_mutex_unlock(&g_pq_mu); return 1; }
    uint64_t previous_native = g_fg_last_native;
    if (!out.generated) g_fg_last_native = out.ticket;
    uint64_t epoch = g_fg_epoch;
    g_fg_display_submit_busy++;
    pthread_mutex_unlock(&g_pq_mu);
    // No queue mutex spans Metal: command-buffer allocation, submission, or a
    // presented handler may wait for or synchronously invoke another callback.
    MTLViewport vp = present_viewport(out.texture.width, out.texture.height, update.drawable.texture.width, update.drawable.texture.height);
    BOOL submitted = [g_fg presentOutput:out drawable:update.drawable viewport:vp completion:^(double time) {
        if (time <= 0) return;
        atomic_fetch_add(&g_fg_displayed, 1);
        atomic_fetch_add(out.generated ? &g_fg_generated : &g_fg_native_displayed, 1);
        atomic_store(&g_fg_latency_ms, fmax(0, (time - out.enqueuedTime) * 1000));
        if (!out.generated) {
            pthread_mutex_lock(&g_pq_mu);
            if (epoch == g_fg_epoch) g_pres[out.ticket % PRING] = (pres_ent){out.ticket, time};
            pthread_mutex_unlock(&g_pq_mu);
        }
    }];
    pthread_mutex_lock(&g_pq_mu);
    g_fg_display_submit_busy--;
    if (epoch == g_fg_epoch) {
        if (submitted) g_fg_last_submit = now;
        else if (!out.generated && g_fg_last_native == out.ticket) g_fg_last_native = previous_native;
    }
    pthread_cond_broadcast(&g_pq_cv);
    pthread_mutex_unlock(&g_pq_mu);
    return 1;
}
