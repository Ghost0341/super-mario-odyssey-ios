// Local authored rumble plus discrete transients from verified game events.
// No GameController engine, adaptive trigger, audio route or vibration fallback.
#import <CoreHaptics/CoreHaptics.h>
#import <AVFAudio/AVFAudio.h>
#import "DmDeviceHaptics.h"
#include "dm.h"
#include "dm_device_haptics_policy.h"
#include "odyssey_local_feedback.h"

static dispatch_queue_t outputQueue, diagnosticsQueue;
static dispatch_block_t settingsChanged;
static dm_device_haptics_policy policy;
static CHHapticEngine *engine;
static id<CHHapticPatternPlayer> player;
static id<CHHapticPatternPlayer> transientPlayer;
static uint64_t transientUntil,transientToken,transientStarts;
static uint64_t engineGeneration, started, lastActive, retryAt, reportAt;
static uint64_t starts, updates, failures, cues, nativeChanges, lastSequence[2];
static uint64_t cueAdmitted[12],cueTransientStarts[12];
static float cuePeakSubmitted[12];
static float sentIntensity, sentSharpness, maxAdmittedIntensity, maxSubmittedIntensity;
static float baseIntensity, baseSharpness;
static uint64_t lastActiveDurationNs, maxActiveDurationNs, shortStops, lastStopNs;
static NSString *lastStopReason = @"none";
static id<CHHapticPatternPlayer> probePlayer;
static uint64_t probeUntil, probeToken, probeRequests, probeStarts, probeFinished, probeAt;
static NSString *lastError = @"none";
static NSString *const levelKey = @"DmDeviceHapticsLevel";
static NSString *const controllerKey = @"DmDeviceHapticsWithController";

static void report(uint64_t now);
static void stop_transient(void) {
    ++transientToken;
    [transientPlayer stopAtTime:CHHapticTimeImmediate error:nil];
    transientPlayer=nil;transientUntil=0;
}
static void stop_player(NSString *reason) {
    if (player && started) {
        uint64_t now=now_ns(); lastActiveDurationNs=now>=started?MIN(now-started,DM_DEVICE_HAPTICS_LEASE_NS):0;
        maxActiveDurationNs=MAX(maxActiveDurationNs,lastActiveDurationNs);
        if (lastActiveDurationNs<20000000ull) ++shortStops;
        lastStopReason=reason; lastStopNs=now;
    }
    [player stopAtTime:CHHapticTimeImmediate error:nil]; player = nil; started = 0;
    sentIntensity = sentSharpness = baseIntensity = baseSharpness = 0;
}
static void release_engine(void) {
    ++engineGeneration;
    stop_player(@"engine-release/context-reset");
    stop_transient();
    ++probeToken; [probePlayer stopAtTime:CHHapticTimeImmediate error:nil]; probePlayer=nil; probeUntil=0;
    CHHapticEngine *old = engine; engine = nil;
    old.resetHandler = ^{};
    old.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; };
    [old stopWithCompletionHandler:nil]; lastActive = 0;
}
static void failed(NSString *operation, NSError *error) {
    ++failures;
    lastError = [NSString stringWithFormat:@"%@: %@", operation, error.localizedDescription ?: @"engine interrupted"];
    LOG("device-haptics: %s", lastError.UTF8String);
    release_engine();
    uint64_t now = now_ns(); dm_device_haptics_reset(&policy, now); retryAt = now + 2000000000ull;
}
static BOOL ensure_engine(uint64_t now) {
    if (engine) return YES;
    if ((!dm_device_haptics_eligible(&policy) && !(policy.supported&&policy.foreground&&probeUntil>now)) || now < retryAt) return NO;
    NSError *error = nil;
    CHHapticEngine *created = [[CHHapticEngine alloc] initAndReturnError:&error];
    if (!created) { failed(@"engine creation", error); return NO; }
    created.playsHapticsOnly = YES;
    created.autoShutdownEnabled = YES;
    engine = created;
    uint64_t token = ++engineGeneration;
    __weak CHHapticEngine *weakEngine = created;
    void (^lost)(void) = ^{
        CHHapticEngine *lostEngine = weakEngine;
        dispatch_async(outputQueue, ^{
            if (token == engineGeneration && engine == lostEngine) failed(@"engine reset/stopped", nil);
        });
    };
    created.resetHandler = lost;
    created.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; lost(); };
    if (![created startAndReturnError:&error]) { failed(@"engine start", error); return NO; }
    return YES;
}
static BOOL send_parameters(id<CHHapticPatternPlayer> target, dm_handle_effect value) {
    NSError *error = nil;
    NSArray *parameters = @[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:baseIntensity>0?fminf(value.intensity/baseIntensity,1):0 relativeTime:0],
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:value.sharpness-baseSharpness relativeTime:0]];
    if (![target sendParameters:parameters atTime:CHHapticTimeImmediate error:&error]) {
        failed(@"parameter update", error); return NO;
    }
    sentIntensity = value.intensity; sentSharpness = value.sharpness; ++updates;
    maxSubmittedIntensity=fmaxf(maxSubmittedIntensity,value.intensity);
    return YES;
}
static void output(dm_handle_effect value, uint64_t now) {
    if (value.intensity < 0.0015f) {
        stop_player(@"native-zero-or-ineligible");
        if (engine && now >= lastActive && now - lastActive > 2000000000ull) release_engine();
        return;
    }
    if (!ensure_engine(now)) return;
    lastActive = now;
    // Independent, finite 100 ms hardware lease. No looped/unbounded pattern;
    // a stalled output queue cannot leave the phone vibrating indefinitely.
    if (!player || now - started >= 70000000ull || value.intensity>baseIntensity+0.00001f) {
        NSError *error = nil;
        // Put the initial value in the event itself. Dynamic intensity is a
        // multiplier of that base, so a rising peak requires a new finite event.
        CHHapticEvent *event=[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
            parameters:@[[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:value.intensity],
                         [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:value.sharpness]]
            relativeTime:0 duration:DM_DEVICE_HAPTICS_LEASE_NS/1e9];
        CHHapticPattern *initial=[[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
        if (!initial) { failed(@"pattern",error);return; }
        id<CHHapticPatternPlayer> next = [engine createPlayerWithPattern:initial error:&error];
        if (!next) { failed(@"player creation", error); return; }
        stop_player(@"lease-renewal");
        if (![next startAtTime:CHHapticTimeImmediate error:&error]) { failed(@"player start", error); return; }
        player = next; started = now_ns(); ++starts;
        baseIntensity=value.intensity; baseSharpness=value.sharpness;
        sentIntensity=value.intensity; sentSharpness=value.sharpness;
        maxSubmittedIntensity=fmaxf(maxSubmittedIntensity,value.intensity);
    } else if (fabsf(value.intensity - sentIntensity) >= 0.001f || fabsf(value.sharpness - sentSharpness) >= 0.012f) {
        send_parameters(player, value);
    }
}
// State callbacks, never touch/controller button edges, admit these events.
// A transient is emitted once per consumed identity, with no continuous tail.
static BOOL output_transient(dm_device_haptics_transient cue,uint64_t now) {
    if (!cue.kind||!ensure_engine(now)) return NO;
    NSError *error=nil;
    CHHapticEvent *event=[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
        parameters:@[[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:cue.effect.intensity],
                     [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:cue.effect.sharpness]] relativeTime:0];
    CHHapticPattern *pattern=[[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
    if (!pattern) { failed(@"game-event transient pattern",error);return NO; }
    id<CHHapticPatternPlayer> next=[engine createPlayerWithPattern:pattern error:&error];
    if (!next) { failed(@"game-event transient player",error);return NO; }
    // One actuator owner. Quiet native texture pauses briefly for the tap;
    // stronger authored output suppresses or immediately preempts the tap.
    stop_player(@"game-event transient");stop_transient();
    if (![next startAtTime:CHHapticTimeImmediate error:&error]) { failed(@"game-event transient start",error);return NO; }
    transientPlayer=next;transientUntil=now+30000000ull;lastActive=now;
    ++transientStarts;++cueTransientStarts[cue.kind];
    cuePeakSubmitted[cue.kind]=fmaxf(cuePeakSubmitted[cue.kind],cue.effect.intensity);
    maxSubmittedIntensity=fmaxf(maxSubmittedIntensity,cue.effect.intensity);
    uint64_t token=transientToken,generation=engineGeneration;
    // The hardware transient ends itself. This bound only releases its player;
    // it cannot renew a cue if the output queue stalls or gameplay stops.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_MSEC),outputQueue,^{
        if (token==transientToken&&generation==engineGeneration) stop_transient();
    });
    return YES;
}
static void report(uint64_t now) {
    if (reportAt && now >= reportAt && now - reportAt < 2000000000ull) return;
    reportAt = now;
    NSString *reason = probePlayer ? @"user-invoked-probe" : !policy.supported ? @"hardware-unsupported" : !policy.level ? @"off" :
        !policy.foreground ? @"background" : policy.controller && !policy.with_controller ? @"controller-selected" :
        !policy.live ? @"waiting-for-fresh-game-frame" : now < retryAt ? @"engine-retry-backoff" : @"ready";
    AVAudioSession *audio=AVAudioSession.sharedInstance;
    dm_odyssey_local_stats local;dm_odyssey_local_feedback_stats(&local);
    NSMutableArray *byKind=[NSMutableArray new];
    for (unsigned kind=1;kind<12;kind++) [byKind addObject:@{@"kind":@(kind),@"admitted":@(cueAdmitted[kind]),
        @"transientStarts":@(cueTransientStarts[kind]),@"peakSubmittedIntensity":@(cuePeakSubmitted[kind])}];
    NSDictionary *snapshot = @{
        @"build":NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"unknown",
        @"hardwareSupportsHaptics":@(policy.supported), @"capabilitySource":@"CHHapticEngine.capabilitiesForHardware.supportsHaptics",
        @"foreground":@(policy.foreground), @"controllerConnected":@(policy.controller),
        @"allowWithController":@(policy.with_controller), @"level":@(policy.level), @"reason":reason,
        @"generation":@(policy.generation), @"armedNs":@(policy.armed_ns),
        @"gameHeartbeatLive":@(policy.live), @"hardwareLeaseMs":@(DM_DEVICE_HAPTICS_LEASE_NS / 1000000),
        @"intensityCap":@(policy.level==1?.20:.27), @"nativeIntensityCap":@(policy.level == 1 ? 0.18 : 0.27), @"verifiedCueIntensityCap":@0.20, @"nativeSignalChanges":@(nativeChanges),
        @"verifiedCueOutputType":@"one transient per verified in-game event; no button synthesis", @"transientStartsSucceeded":@(transientStarts),
        @"transientActive":@(transientPlayer!=nil),
        @"verifiedCuesAdmitted":@(cues), @"verifiedCueByKind":byKind, @"playerStartsSucceeded":@(starts), @"parameterUpdatesSucceeded":@(updates),
        @"engineFailures":@(failures), @"lastError":lastError,
        @"lastSubmittedIntensity":@(sentIntensity), @"lastSubmittedSharpness":@(sentSharpness),
        @"maxAdmittedIntensity":@(maxAdmittedIntensity), @"maxSubmittedIntensity":@(maxSubmittedIntensity),
        @"lastPlayerActiveMs":@(lastActiveDurationNs/1e6), @"maxPlayerActiveMs":@(maxActiveDurationNs/1e6),
        @"playersStoppedBefore20Ms":@(shortStops), @"lastStopReason":lastStopReason, @"lastStopNs":@(lastStopNs),
        @"engineExists":@(engine!=nil), @"engineMutedForHaptics":@(engine.isMutedForHaptics),
        @"enginePlaysAudioOnly":@(engine.playsAudioOnly), @"playerMuted":@(player.isMuted),
        @"audioCategory":audio.category?:@"unknown", @"audioMode":audio.mode?:@"unknown",
        @"audioRouteInputs":@(audio.currentRoute.inputs.count), @"audioRouteOutputs":@(audio.currentRoute.outputs.count),
        @"audioOutputPortTypes":[audio.currentRoute.outputs valueForKey:@"portType"]?:@[],
        @"audioInputPortTypes":[audio.currentRoute.inputs valueForKey:@"portType"]?:@[],
        @"allowHapticsDuringRecording":@(audio.allowHapticsAndSystemSoundsDuringRecording),
        @"probeRequests":@(probeRequests), @"probeStartsSucceeded":@(probeStarts), @"probeFinished":@(probeFinished),
        @"probeLastNs":@(probeAt), @"probeActive":@(probePlayer!=nil), @"probeIntensity":@0.30,
        @"probePlayerMuted":@(probePlayer.isMuted),
        @"localObserverInstalled":@(local.installed), @"localNormalJumps":@(local.observed[0]),
        @"localLandings":@(local.observed[1]), @"localCapThrows":@(local.observed[2]),
        @"localCoins":@(local.observed[3]), @"localGroundPoundStarts":@(local.observed[4]),
        @"localGroundPoundImpacts":@(local.observed[5]), @"localEventsExpired":@(local.expired),
        @"submissionDoesNotProvePhysicalFeel":@YES, @"timestampNs":@(now)};
    dispatch_async(diagnosticsQueue, ^{
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:[documents stringByAppendingPathComponent:@"device-haptics.json"] options:NSDataWritingAtomic error:nil];
    });
}
void dm_device_haptics_initialize(dispatch_queue_t queue, dispatch_queue_t diagnostics, dispatch_block_t changed) {
    outputQueue = queue; diagnosticsQueue = diagnostics; settingsChanged = [changed copy];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{levelKey:@1, controllerKey:@NO}];
    NSInteger level = [defaults integerForKey:levelKey];
    // The simple On switch always uses the subtle device-only envelope. Keep
    // legacy preference bytes until a user changes the switch.
    policy.level = level == 0 ? 0 : 1;
    policy.with_controller = [defaults boolForKey:controllerKey];
    // Ask actual hardware even on iPad. Linking Core Haptics never proves an
    // actuator exists; unsupported devices do not create an engine or fallback.
    policy.supported = CHHapticEngine.capabilitiesForHardware.supportsHaptics;
    dm_device_haptics_reset(&policy, now_ns());
    LOG("device-haptics: measured hardware support=%d", policy.supported);
}
void dm_device_haptics_context(BOOL foreground, BOOL controller, uint64_t now) {
    if (policy.foreground != foreground || policy.controller != controller) {
        policy.foreground = foreground; policy.controller = controller;
        dm_device_haptics_reset(&policy, now); release_engine();
    }
    reportAt = 0; report(now);
}
BOOL dm_device_haptics_enabled(void) { return dm_device_haptics_eligible(&policy)||(policy.supported&&policy.foreground&&probeUntil>now_ns()); }
void dm_device_haptics_observe(dm_odyssey_feedback_event event, uint64_t now) {
    if (event.kind<DM_ODYSSEY_LONG_JUMP||event.kind>DM_ODYSSEY_GROUND_POUND_IMPACT) return;
    uint64_t previous = policy.cue_identity[event.kind];
    dm_device_haptics_observe_cue(&policy, event, now);
    if (previous != policy.cue_identity[event.kind]) { ++cues;++cueAdmitted[event.kind]; }
}
void dm_device_haptics_tick(uint64_t now, uint64_t frameAt) {
    if (probePlayer&&probeUntil>now) { report(now); return; }
    dm_feedback_native_output native; dm_feedback_native_poll(&native);
    for (int side = 0; side < 2; side++) if (native.sequence[side] != lastSequence[side]) {
        lastSequence[side] = native.sequence[side]; ++nativeChanges;
    }
    uint64_t generation = policy.generation;
    dm_handle_effect value = dm_device_haptics_effect(&policy, &native, frameAt, now);
    maxAdmittedIntensity=fmaxf(maxAdmittedIntensity,value.intensity);
    if (generation != policy.generation) release_engine();
    dm_device_haptics_transient cue=dm_device_haptics_take_transient(&policy,value.intensity,now);
    if (cue.kind) maxAdmittedIntensity=fmaxf(maxAdmittedIntensity,cue.effect.intensity);
    if (cue.kind&&output_transient(cue,now)) { report(now);return; }
    if (transientPlayer&&now<transientUntil&&value.intensity<.055f) { report(now);return; }
    if (transientPlayer) stop_transient();
    output(value, now);
    report(now);
}
static void request_probe(void) {
    ++probeRequests;
    if (!policy.supported||!policy.foreground) { reportAt=0; report(now_ns()); return; }
    release_engine(); retryAt=0; dm_device_haptics_reset(&policy,now_ns());
    probeAt=now_ns(); probeUntil=probeAt+120000000ull;
    if (!ensure_engine(probeAt)) { settingsChanged(); return; }
    NSError *error=nil;
    CHHapticEvent *event=[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
        parameters:@[[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:0.30],
                     [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.55]] relativeTime:0];
    CHHapticPattern *probePattern=[[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
    if (!probePattern) { failed(@"probe pattern",error); settingsChanged(); return; }
    probePlayer=[engine createPlayerWithPattern:probePattern error:&error];
    if (!probePlayer||![probePlayer startAtTime:CHHapticTimeImmediate error:&error]) { failed(@"probe start",error); settingsChanged(); return; }
    ++probeStarts; uint64_t token=++probeToken, generation=engineGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,120*NSEC_PER_MSEC),outputQueue,^{
        if (token!=probeToken||generation!=engineGeneration) return;
        [probePlayer stopAtTime:CHHapticTimeImmediate error:nil]; probePlayer=nil; probeUntil=0; ++probeFinished;
        dm_device_haptics_reset(&policy,now_ns());
        if (!dm_device_haptics_eligible(&policy)) release_engine();
        settingsChanged(); reportAt=0; report(now_ns());
    });
    settingsChanged(); reportAt=0; report(probeAt);
}
static UIMenu *settings_menu(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    // This immutable hardware property is initialized before creating the UI.
    if (!policy.supported) {
        UIAction *unsupported = [UIAction actionWithTitle:@"Unavailable on this device" image:nil identifier:nil handler:^(UIAction *a) { (void)a; }];
        unsupported.attributes = UIMenuElementAttributesDisabled;
        return [UIMenu menuWithTitle:@"Device haptics" children:@[unsupported]];
    }
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    NSArray *labels = @[@"Off", @"Subtle", @"Light"];
    for (NSUInteger level = 0; level < labels.count; level++) {
        UIAction *action = [UIAction actionWithTitle:labels[level] image:nil identifier:nil handler:^(UIAction *a) {
            (void)a; [defaults setInteger:level forKey:levelKey];
            dispatch_async(outputQueue, ^{
                policy.level = (unsigned)level; dm_device_haptics_reset(&policy, now_ns());
                release_engine(); retryAt = 0; settingsChanged();
            });
        }];
        action.state = [defaults integerForKey:levelKey] == (NSInteger)level ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    UIAction *withController = [UIAction actionWithTitle:@"Also when using a controller" image:nil identifier:nil handler:^(UIAction *a) {
        (void)a; BOOL enabled = ![defaults boolForKey:controllerKey]; [defaults setBool:enabled forKey:controllerKey];
        dispatch_async(outputQueue, ^{
            policy.with_controller = enabled; dm_device_haptics_reset(&policy, now_ns());
            release_engine(); retryAt = 0; settingsChanged();
        });
    }];
    withController.state = [defaults boolForKey:controllerKey] ? UIMenuElementStateOn : UIMenuElementStateOff;
    [actions addObject:withController];
    [actions addObject:[UIAction actionWithTitle:@"Test device vibration" image:nil identifier:nil handler:^(UIAction *action) {
        (void)action; dispatch_async(outputQueue,^{ request_probe(); });
    }]];
    return [UIMenu menuWithTitle:@"Device haptics" children:actions];
}
UIMenu *dm_device_haptics_settings_menu(void) { return settings_menu(); }
BOOL dm_device_haptics_settings_supported(void) { return policy.supported; }
BOOL dm_device_haptics_settings_enabled(void) {
    return [NSUserDefaults.standardUserDefaults integerForKey:levelKey]!=0;
}
BOOL dm_device_haptics_settings_with_controller(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:controllerKey];
}
void dm_device_haptics_settings_set_enabled(BOOL enabled) {
    if (!outputQueue||!policy.supported) return;
    [NSUserDefaults.standardUserDefaults setInteger:enabled?1:0 forKey:levelKey];
    dispatch_async(outputQueue, ^{
        policy.level=enabled?1:0; dm_device_haptics_reset(&policy,now_ns());
        release_engine(); retryAt=0; settingsChanged();
    });
}
void dm_device_haptics_settings_set_with_controller(BOOL enabled) {
    if (!outputQueue||!policy.supported) return;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:controllerKey];
    dispatch_async(outputQueue, ^{
        policy.with_controller=enabled; dm_device_haptics_reset(&policy,now_ns());
        release_engine(); retryAt=0; settingsChanged();
    });
}
UIButton *dm_device_haptics_settings_button(void) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"Haptics" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35]; button.layer.cornerRadius = 8;
    button.accessibilityLabel = @"Device haptics intensity";
    button.showsMenuAsPrimaryAction = YES;
    button.menu = [UIMenu menuWithChildren:@[[UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        completion(@[settings_menu()]);
    }]]];
    return button;
}
