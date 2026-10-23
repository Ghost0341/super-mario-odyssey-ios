// Native HD rumble and physical motion, with game-confirmed long-jump/backflip cues.
#import <UIKit/UIKit.h>
#import <CoreHaptics/CoreHaptics.h>
#import "DmControllerFeedback.h"
#import "DmMotion.h"
#import "DmDeviceHaptics.h"
#include <stdatomic.h>
#include <math.h>
#include "dm.h"
#include "dm_feedback.h"
#include "dm_feedback_policy.h"
#include "odyssey_feedback.h"
#include "odyssey_local_feedback.h"

static dispatch_queue_t queue, diagnostics, triggerQueue;
static dispatch_source_t timer;
static char queueKey;
static GCController *selected;
static BOOL active, stereo;
static unsigned caps;
static CHHapticEngine *engines[2];
static id<CHHapticPatternPlayer> players[2];
static CHHapticPattern *pattern;
static uint64_t generation[2], retry[2], started[2], lastActive[2];
static uint64_t hapticStarts[2], updates[2], nonzero[2], lastSequence[2];
static float sentIntensity[2], sentSharpness[2], travel[2];
static BOOL triggerOn[2];
static uint64_t triggerCommands[2], triggerEventSequence[2], jumpAt, jumpSequence, jumps, backflips, wallJumps, sideFlips, frameCount, frameAt, reportAt;
static dm_odyssey_feedback_kind jumpKind;
// Only triggerQueue touches these tokens and the physical trigger modes. Its
// deadline is independent of CoreHaptics engine creation and parameter calls.
static uint64_t triggerLease[2];
static uint64_t triggerReplyToken[2];
static _Atomic uint64_t triggerActiveReplies[2];
static _Atomic uint64_t triggerStartedNs[2], triggerStoppedNs[2], triggerPulseSequence[2];
static _Atomic int triggerReplyMode[2], triggerReplyStatus[2];
static _Atomic float triggerReplyArm[2];

static void on_queue(dispatch_block_t work) {
    if (dispatch_get_specific(&queueKey)) work(); else dispatch_sync(queue, work);
}
static GCDualSenseGamepad *dualsense(void) {
    GCExtendedGamepad *g = selected.extendedGamepad;
    return [g isKindOfClass:GCDualSenseGamepad.class] ? (GCDualSenseGamepad *)g : nil;
}
static void triggers_off(void) {
    GCDualSenseGamepad *g = dualsense();
    dispatch_sync(triggerQueue, ^{
        triggerLease[0]++; triggerLease[1]++;
        [g.leftTrigger setModeOff]; [g.rightTrigger setModeOff];
        atomic_store(&triggerStoppedNs[0], now_ns()); atomic_store(&triggerStoppedNs[1], now_ns());
    });
    triggerOn[0] = triggerOn[1] = NO;
}
static void release_engine(int side) {
    generation[side]++;
    [players[side] stopAtTime:CHHapticTimeImmediate error:nil]; players[side] = nil;
    CHHapticEngine *e = engines[side]; engines[side] = nil;
    e.resetHandler = ^{}; e.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; };
    [e stopWithCompletionHandler:nil];
    started[side] = lastActive[side] = 0;
    sentIntensity[side] = sentSharpness[side] = -1;
}
static void quiet(void) {
    triggers_off();
    for (int side = 0; side < 2; side++) release_engine(side);
    jumpAt = jumpSequence = frameAt = 0; jumpKind = 0; frameCount = dm_nvn_frame_count();
    triggerEventSequence[0] = triggerEventSequence[1] = 0;
    travel[0] = travel[1] = 0;
}
static void engine_failed(int side, NSString *operation, NSError *error) {
    LOG("controller-feedback: %s %s failed: %s", side ? "right" : "left", operation.UTF8String,
        error.localizedDescription.UTF8String ?: "unavailable");
    release_engine(side); retry[side] = now_ns() + 2000000000ull;
}
static BOOL ensure_engine(int side, uint64_t now) {
    if (engines[side]) return YES;
    if (!selected.haptics || now < retry[side]) return NO;
    NSError *error = nil;
    if (!pattern) {
        CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
            parameters:@[[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
                         [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5f]]
            relativeTime:0 duration:0.20];
        pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
        if (!pattern) { engine_failed(side, @"pattern", error); return NO; }
    }
    NSSet *localities = selected.haptics.supportedLocalities;
    GCHapticsLocality locality = stereo ? (side ? GCHapticsLocalityRightHandle : GCHapticsLocalityLeftHandle) :
        ([localities containsObject:GCHapticsLocalityDefault] ? GCHapticsLocalityDefault : localities.anyObject);
    if (!locality) return NO;
    CHHapticEngine *e = [selected.haptics createEngineWithLocality:locality];
    if (!e) { engine_failed(side, @"engine creation", nil); return NO; }
    e.playsHapticsOnly = YES;
    __weak CHHapticEngine *weakEngine = e;
    uint64_t token = ++generation[side];
    void (^lost)(void) = ^{
        CHHapticEngine *lostEngine = weakEngine;
        dispatch_async(queue, ^{
            if (generation[side] == token && engines[side] == lostEngine) {
                release_engine(side); retry[side] = now_ns() + 2000000000ull;
            }
        });
    };
    e.resetHandler = lost;
    e.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; lost(); };
    if (![e startAndReturnError:&error]) { engine_failed(side, @"engine start", error); return NO; }
    engines[side] = e;
    LOG("controller-feedback: %s engine ready (%s)", side ? "right" : "left", locality.UTF8String);
    return YES;
}
static BOOL parameters(id<CHHapticPatternPlayer> player, int side, dm_handle_effect value) {
    NSError *error = nil;
    NSArray *p = @[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:value.intensity relativeTime:0],
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:value.sharpness - 0.5f relativeTime:0]];
    if (![player sendParameters:p atTime:CHHapticTimeImmediate error:&error]) {
        engine_failed(side, @"parameter update", error); return NO;
    }
    sentIntensity[side] = value.intensity; sentSharpness[side] = value.sharpness; updates[side]++;
    return YES;
}
static void handle_output(int side, dm_handle_effect value, uint64_t now) {
    if (value.intensity < 0.008f) {
        [players[side] stopAtTime:CHHapticTimeImmediate error:nil]; players[side] = nil; started[side] = 0;
        if (engines[side] && now - lastActive[side] > 2000000000ull) release_engine(side);
        return;
    }
    if (!ensure_engine(side, now)) return;
    lastActive[side] = now;
    // A 200 ms hardware lease bounds output even if the update queue stalls.
    if (!players[side] || now - started[side] >= 140000000ull) {
        NSError *error = nil;
        id<CHHapticPatternPlayer> p = [engines[side] createPlayerWithPattern:pattern error:&error];
        if (!p) { engine_failed(side, @"player creation", error); return; }
        if (!parameters(p, side, value)) return;
        if (![p startAtTime:CHHapticTimeImmediate error:&error]) { engine_failed(side, @"player start", error); return; }
        [players[side] stopAtTime:CHHapticTimeImmediate error:nil];
        players[side] = p; started[side] = now; hapticStarts[side]++;
    } else if (fabsf(value.intensity - sentIntensity[side]) >= 0.006f || fabsf(value.sharpness - sentSharpness[side]) >= 0.012f)
        parameters(players[side], side, value);
}
static void trigger_output(int side, dm_trigger_effect value, uint64_t eventSequence) {
    GCDualSenseGamepad *g = dualsense(); if (!g) return;
    GCDualSenseAdaptiveTrigger *trigger = side ? g.rightTrigger : g.leftTrigger;
    // Each actual takeoff gets a new lease even if the feedback queue stalled
    // through the previous off edge. A held button cannot create an event.
    if (value.enabled && eventSequence && eventSequence != triggerEventSequence[side]) {
        triggerEventSequence[side] = eventSequence;
        dispatch_async(triggerQueue, ^{
            uint64_t token = ++triggerLease[side];
            // Constant feedback needs a fresh pull on this controller. A slow,
            // short actuator pulse strikes the finger even during a held chain.
            [trigger setModeVibrationWithStartPosition:0.05f amplitude:value.strength frequency:0.035f];
            atomic_store(&triggerStartedNs[side], now_ns());
            atomic_store(&triggerPulseSequence[side], eventSequence);
            for (int ms = 25; ms <= 50; ms += 25) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC), triggerQueue, ^{
                    if (triggerLease[side] != token) return;
                    int mode = (int)trigger.mode, status = (int)trigger.status;
                    atomic_store(&triggerReplyMode[side], mode);
                    atomic_store(&triggerReplyStatus[side], status);
                    atomic_store(&triggerReplyArm[side], trigger.armPosition);
                    if (mode == GCDualSenseAdaptiveTriggerModeVibration &&
                        status == GCDualSenseAdaptiveTriggerStatusVibrationIsVibrating &&
                        triggerReplyToken[side] != token) {
                        triggerReplyToken[side] = token;
                        atomic_fetch_add(&triggerActiveReplies[side], 1);
                    }
                });
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, DM_JUMP_TRIGGER_PULSE_NS), triggerQueue, ^{
                if (triggerLease[side] == token) {
                    ++triggerLease[side]; [trigger setModeOff];
                    atomic_store(&triggerStoppedNs[side], now_ns());
                }
            });
        });
        triggerOn[side] = YES; triggerCommands[side]++;
    } else if (!value.enabled && triggerOn[side]) {
        dispatch_async(triggerQueue, ^{
            ++triggerLease[side]; [trigger setModeOff];
            atomic_store(&triggerStoppedNs[side], now_ns());
        });
        triggerOn[side] = NO; triggerCommands[side]++;
    }
}
static void report(dm_feedback_output sample, uint64_t now) {
    if (reportAt && now - reportAt < 2000000000ull) return;
    reportAt = now;
    dm_odyssey_feedback_stats events; dm_odyssey_feedback_get_stats(&events);
    NSDictionary *r = @{
        @"controller":selected.vendorName ?: @"none", @"build":NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"unknown",
        @"connected":@(selected != nil), @"foreground":@(active), @"stereoHaptics":@(stereo),
        @"adaptiveTriggers":@(dualsense() != nil), @"motionAvailable":@(selected.motion.hasRotationRate),
        @"motionSources":dm_motion_diagnostics(), @"motionSamples":@(sample.motion_samples), @"motionSamplesAccepted":@(sample.motion_samples),
        @"gameMotionReadCalls":@(sample.motion_reads), @"gameMotionStatesReturned":@(sample.motion_states_returned),
        @"nativeVibrationSendCalls":@(sample.vibration_sends),
        @"epoch":@(sample.epoch), @"nativeSequence":@[@(sample.sequence[0]), @(sample.sequence[1])],
        @"nativeNonzeroObserved":@[@(nonzero[0]), @(nonzero[1])],
        @"hapticStartsSucceeded":@[@(hapticStarts[0]), @(hapticStarts[1])],
        @"hapticParameterUpdatesSucceeded":@[@(updates[0]), @(updates[1])],
        @"triggerCommandsSubmitted":@[@(triggerCommands[0]), @(triggerCommands[1])],
        @"triggerPulseMs":@(DM_JUMP_TRIGGER_PULSE_NS / 1000000), @"triggerKickStrength":@0.60,
        @"triggerPulseFrequency":@0.035,
        @"triggerModeLastReported":@[@(dualsense().leftTrigger.mode), @(dualsense().rightTrigger.mode)],
        @"triggerStatusLastReported":@[@(dualsense().leftTrigger.status), @(dualsense().rightTrigger.status)],
        @"triggerArmPositionLastReported":@[@(dualsense().leftTrigger.armPosition), @(dualsense().rightTrigger.armPosition)],
        @"triggerPulseActiveReplies":@[@(atomic_load(&triggerActiveReplies[0])), @(atomic_load(&triggerActiveReplies[1]))],
        @"triggerPulseSampleMode":@[@(atomic_load(&triggerReplyMode[0])), @(atomic_load(&triggerReplyMode[1]))],
        @"triggerPulseSampleStatus":@[@(atomic_load(&triggerReplyStatus[0])), @(atomic_load(&triggerReplyStatus[1]))],
        @"triggerPulseSampleArmPosition":@[@(atomic_load(&triggerReplyArm[0])), @(atomic_load(&triggerReplyArm[1]))],
        @"triggerPulseEventSequence":@[@(atomic_load(&triggerPulseSequence[0])), @(atomic_load(&triggerPulseSequence[1]))],
        @"triggerPulseStartCommandNs":@[@(atomic_load(&triggerStartedNs[0])), @(atomic_load(&triggerStartedNs[1]))],
        @"triggerPulseStopCommandNs":@[@(atomic_load(&triggerStoppedNs[0])), @(atomic_load(&triggerStoppedNs[1]))],
        @"triggerCommandsAreNotHardwareAcknowledgements":@YES,
        @"longJumpEffectsAdmitted":@(jumps), @"longJumpObserverInstalled":@(events.installed),
        @"longJumpObserved":@(events.classic_long_jump + events.rolling_jump), @"longJumpExpired":@(events.expired),
        @"classicLongJumpObserved":@(events.classic_long_jump), @"rollingJumpObserved":@(events.rolling_jump),
        @"backflipObserved":@(events.backflip), @"backflipEffectsAdmitted":@(backflips), @"backflipTextureMs":@120,
        @"wallJumpObserved":@(events.wall_jump), @"wallJumpEffectsAdmitted":@(wallJumps), @"wallJumpTextureMs":@85,
        @"sideFlipObserved":@(events.side_flip), @"sideFlipEffectsAdmitted":@(sideFlips), @"sideFlipTextureMs":@120,
        @"takeoffsObserved":@(events.observed), @"takeoffEventsExpired":@(events.expired),
        @"lastJumpEventSequence":@(jumpSequence), @"lastJumpEventKind":@(jumpKind), @"lastJumpEventNs":@(jumpAt),
        @"gameFrame":@(frameCount), @"timestampNs":@(now)};
    dispatch_async(diagnostics, ^{
        NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSData *data = [NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:[doc stringByAppendingPathComponent:@"controller-feedback.json"] options:NSDataWritingAtomic error:nil];
    });
}
static void tick(void) {
    uint64_t now = now_ns(), frame = dm_nvn_frame_count();
    if (frame != frameCount) { frameCount = frame; frameAt = now; dm_feedback_game_tick(now); }
    dm_feedback_output sample; dm_feedback_poll(now, &sample);
    BOOL live = selected && active && frameAt && now >= frameAt && now - frameAt < 200000000ull;
    dm_odyssey_feedback_event event;
    while (dm_odyssey_feedback_next(&event)) {
        now = now_ns(); // The guest may publish after the tick's initial timestamp.
        // Fan out one drained event; the local sink never steals controller cues.
        dm_device_haptics_observe(event, now);
        if (live && dm_odyssey_feedback_controller_kind(event.kind) && event.timestamp_ns <= now &&
            now - event.timestamp_ns < 90000000ull && event.timestamp_ns > jumpAt) {
            jumpAt = event.timestamp_ns; jumpSequence = event.sequence; jumpKind = event.kind;
            uint64_t count;
            if (event.kind == DM_ODYSSEY_BACKFLIP) count = ++backflips;
            else if (event.kind == DM_ODYSSEY_WALL_JUMP) count = ++wallJumps;
            else if (event.kind == DM_ODYSSEY_SIDE_FLIP) count = ++sideFlips;
            else count = ++jumps;
            const char *label = event.kind == DM_ODYSSEY_BACKFLIP ? "backflip" :
                event.kind == DM_ODYSSEY_WALL_JUMP ? "wall-jump" : event.kind == DM_ODYSSEY_SIDE_FLIP ? "side-flip" :
                event.kind == DM_ODYSSEY_ROLLING_JUMP ? "rolling-jump" : "long-jump";
            LOG("controller-feedback: %s kick #%llu sequence %llu", label,
                (unsigned long long)count, (unsigned long long)event.sequence);
        }
    }
    dm_handle_effect value[2] = {{0}};
    for (int side = 0; side < 2; side++) {
        if (sample.sequence[side] != lastSequence[side]) {
            lastSequence[side] = sample.sequence[side];
            if (sample.value[side].amp_low > 0.008f || sample.value[side].amp_high > 0.008f) nonzero[side]++;
        }
        if (live) {
            value[side] = dm_feedback_native_effect(sample.value[side], 0.85f);
            dm_handle_effect jump;
            switch (jumpKind) {
                case DM_ODYSSEY_BACKFLIP: jump = dm_feedback_backflip(jumpAt, now, side); break;
                case DM_ODYSSEY_WALL_JUMP: jump = dm_feedback_wall_jump(jumpAt, now, side); break;
                case DM_ODYSSEY_SIDE_FLIP: jump = dm_feedback_side_flip(jumpAt, now, side); break;
                case DM_ODYSSEY_LONG_JUMP: case DM_ODYSSEY_ROLLING_JUMP: jump=dm_feedback_long_jump(jumpAt,now,side); break;
                default: jump=(dm_handle_effect){0}; break;
            }
            if (jump.intensity > value[side].intensity) value[side] = jump;
        }
        BOOL triggerJump = jumpKind == DM_ODYSSEY_LONG_JUMP || jumpKind == DM_ODYSSEY_ROLLING_JUMP || jumpKind == DM_ODYSSEY_BACKFLIP;
        trigger_output(side, live && triggerJump ? dm_feedback_jump_trigger(jumpAt, now, travel[side]) : (dm_trigger_effect){0}, jumpSequence);
    }
    if (stereo) { handle_output(0, value[0], now); handle_output(1, value[1], now); }
    else { handle_output(0, value[value[1].intensity > value[0].intensity ? 1 : 0], now); }
    // Dedicated local queue cannot evict or enter the controller jumpKind path.
    while (dm_odyssey_local_feedback_next(&event)) dm_device_haptics_observe(event,now_ns());
    now=now_ns();
    dm_device_haptics_tick(now, frameAt);
    report(sample, now);
}
static void publish_device(void);
static void refresh_output_activity(void);
static void init_feedback(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("odyssey.controller-feedback", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        diagnostics = dispatch_queue_create("odyssey.controller-diagnostics", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        triggerQueue = dispatch_queue_create("odyssey.controller-trigger-deadlines", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        dispatch_queue_set_specific(queue, &queueKey, &queueKey, NULL);
        dm_device_haptics_initialize(queue, diagnostics, ^{ refresh_output_activity(); });
        active = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timer, DISPATCH_TIME_FOREVER, 8 * NSEC_PER_MSEC, NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{ @autoreleasepool { tick(); } });
        dispatch_resume(timer);
        on_queue(^{ publish_device(); });
    });
}
static void refresh_output_activity(void) {
    dm_device_haptics_context(active, selected != nil, now_ns());
    BOOL running = active && (selected || dm_device_haptics_enabled());
    dm_odyssey_feedback_set_active(running);
    dm_odyssey_local_feedback_set_active(dm_device_haptics_enabled());
    dispatch_source_set_timer(timer, running ? dispatch_time(DISPATCH_TIME_NOW, 0) : DISPATCH_TIME_FOREVER,
                             8 * NSEC_PER_MSEC, NSEC_PER_MSEC);
}
static void publish_device(void) {
    dm_feedback_set_device(selected != nil, active, caps, now_ns());
    refresh_output_activity();
    dm_motion_controller(selected, active);
    reportAt = 0;
    dm_feedback_output sample; dm_feedback_poll(now_ns(), &sample); report(sample, now_ns());
}
void dm_controller_feedback_attach(GCController *controller) {
    init_feedback();
    on_queue(^{
        if (selected == controller) return;
        dm_odyssey_feedback_set_active(0);
        quiet();
        dm_feedback_set_device(0, active, 0, now_ns());
        selected = controller;
        NSSet *localities = controller.haptics.supportedLocalities;
        stereo = [localities containsObject:GCHapticsLocalityLeftHandle] && [localities containsObject:GCHapticsLocalityRightHandle];
        caps = controller.haptics ? DM_FEEDBACK_RUMBLE_LEFT | DM_FEEDBACK_RUMBLE_RIGHT : 0;
        if (controller.motion.hasRotationRate) caps |= DM_FEEDBACK_MOTION;
        retry[0] = retry[1] = 0;
        triggers_off(); publish_device();
        LOG("controller-feedback: %s stereo=%d adaptive=%d motion=%d", controller.vendorName.UTF8String ?: "none", stereo, dualsense() != nil, controller.motion.hasRotationRate);
    });
}
void dm_controller_feedback_focus(int foreground) {
    init_feedback();
    on_queue(^{
        if (active == (foreground != 0)) return;
        quiet(); active = foreground != 0; publish_device();
    });
}
void dm_controller_feedback_travel(float left, float right) {
    init_feedback();
    dispatch_async(queue, ^{
        travel[0] = isfinite(left) ? dm_feedback_clamp(left, 0, 1) : 0;
        travel[1] = isfinite(right) ? dm_feedback_clamp(right, 0, 1) : 0;
    });
}
UIButton *dm_controller_feedback_device_settings_button(void) {
    init_feedback();
    return dm_device_haptics_settings_button();
}
UIMenu *dm_controller_feedback_device_settings_menu(void) {
    init_feedback(); return dm_device_haptics_settings_menu();
}
