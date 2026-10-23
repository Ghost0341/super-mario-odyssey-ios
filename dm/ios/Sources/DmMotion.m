// Device and controller gyro share one serialized, epoch-checked guest sensor path.
#import "DmMotion.h"
#import <CoreMotion/CoreMotion.h>
#include "dm.h"
#include "dm_feedback.h"
#include "dm_motion_source.h"

static dispatch_queue_t motionQueue, diagnosticsQueue;
static dispatch_source_t watchdog;
static CMMotionManager *manager;
static NSOperationQueue *sensorQueue;
static GCController *controller;
static dm_motion_router router;
static int orientation, requested = DM_MOTION_AUTO;
static BOOL foreground, controllerRunning, deviceRunning, deviceFailed;
static uint64_t controllerToken, deviceToken, backendEpoch, clockOrigin, nextProbe, probeUntil;
static double uptimeOrigin;
static uint64_t raw[3], accepted[3], rejected[3], calibration, errors;
static uint64_t diagnosticAt;
static NSString *lastError = @"";
static NSString *const preference = @"DmMotionSource";
static void update_acquisition(uint64_t now);
static void configure(void);
static NSDictionary *snapshot(void);
static void write_diagnostics(void);

static NSString *source_name(int value) {
    return @[@"Off", @"Controller", @"Device", @"Auto"][(value >= 0 && value <= 3) ? value : 0];
}
static void select_source(uint64_t now) {
    int prior = router.selected;
    dm_motion_choose(&router, now);
    if (prior != router.selected) {
        backendEpoch = dm_feedback_motion_begin(router.selected != DM_MOTION_OFF);
        ++calibration;
        LOG("motion: selected %s (generation %llu)", source_name(router.selected).UTF8String, (unsigned long long)router.generation);
    }
}
static void ingest(int source, uint64_t generation, uint64_t token, const double acc[3], const double gyro[3],
                   double deviceSeconds, uint64_t controllerTime) {
    ++raw[source];
    uint64_t now = now_ns();
    uint64_t current = source == 1 ? controllerToken : deviceToken;
    uint64_t sample = source == 2 ? dm_motion_timestamp(deviceSeconds, uptimeOrigin, clockOrigin, now) : controllerTime;
    double a[3], g[3];
    BOOL valid = token == current && generation == router.generation && sample && sample >= clockOrigin;
    for (int i=0;i<3;i++) if (!isfinite(acc[i]) || !isfinite(gyro[i]) || fabs(acc[i]) > 64 || fabs(gyro[i]) > 100) valid = NO;
    if (source == 2) valid = valid && dm_motion_rotate(orientation, acc, a) && dm_motion_rotate(orientation, gyro, g);
    else { memcpy(a, acc, sizeof a); memcpy(g, gyro, sizeof g); }
    if (!valid || !dm_motion_observe(&router, generation, source, sample, now)) { ++rejected[source]; return; }
    select_source(now);
    if (router.selected == source && dm_feedback_motion_push(backendEpoch, a, g, NULL, sample)) ++accepted[source];
    update_acquisition(now);
}
static void stop_controller(void) {
    ++controllerToken;
    controller.motion.valueChangedHandler = nil;
    if (controller.motion.sensorsRequireManualActivation) controller.motion.sensorsActive = NO;
    controllerRunning = NO;
}
static void stop_device(void) {
    ++deviceToken; [manager stopDeviceMotionUpdates]; deviceRunning = NO;
}
static void start_controller(void) {
    if (controllerRunning || !controller.motion.hasRotationRate) return;
    controllerRunning = YES;
    uint64_t token = ++controllerToken, generation = router.generation;
    GCMotion *motion = controller.motion;
    motion.valueChangedHandler = ^(GCMotion *v) {
        uint64_t timestamp = now_ns();
        GCAcceleration a = v.acceleration;
        if (v.hasGravityAndUserAcceleration) {
            a.x = v.gravity.x + v.userAcceleration.x;
            a.y = v.gravity.y + v.userAcceleration.y;
            a.z = v.gravity.z + v.userAcceleration.z;
        }
        const double ax=a.x, ay=a.y, az=a.z, gx=v.rotationRate.x, gy=v.rotationRate.y, gz=v.rotationRate.z;
        dispatch_async(motionQueue, ^{
            const double acc[3]={ax,ay,az}, gyro[3]={gx,gy,gz};
            ingest(1, generation, token, acc, gyro, 0, timestamp);
        });
    };
    if (motion.sensorsRequireManualActivation) motion.sensorsActive = YES;
}
static void start_device(void) {
    if (deviceRunning || deviceFailed || !manager.deviceMotionAvailable || !orientation) return;
    CMAttitudeReferenceFrame frames = [CMMotionManager availableAttitudeReferenceFrames];
    if (!(frames & CMAttitudeReferenceFrameXArbitraryZVertical)) {
        deviceFailed = YES; router.device = 0; ++errors; lastError = @"Device motion reference is unavailable"; return;
    }
    deviceRunning = YES;
    uint64_t token = ++deviceToken, generation = router.generation;
    manager.deviceMotionUpdateInterval = 0.01;
    [manager startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryZVertical
        toQueue:sensorQueue withHandler:^(CMDeviceMotion *v, NSError *error) {
        if (error || !v) {
            NSString *message = error.localizedDescription ?: @"No device motion sample";
            dispatch_async(motionQueue, ^{
                if (token != deviceToken || generation != router.generation) return;
                ++errors; lastError = message; deviceFailed = YES; router.device = 0; router.last[2] = 0;
                stop_device(); select_source(now_ns()); update_acquisition(now_ns()); write_diagnostics();
            });
            return;
        }
        const double stamp=v.timestamp, ax=v.gravity.x+v.userAcceleration.x, ay=v.gravity.y+v.userAcceleration.y,
                     az=v.gravity.z+v.userAcceleration.z, gx=v.rotationRate.x, gy=v.rotationRate.y, gz=v.rotationRate.z;
        dispatch_async(motionQueue, ^{
            const double acc[3]={ax,ay,az}, gyro[3]={gx,gy,gz};
            ingest(2, generation, token, acc, gyro, stamp, 0);
        });
    }];
}
static void update_acquisition(uint64_t now) {
    BOOL wantController = NO, wantDevice = NO;
    if (foreground && requested != DM_MOTION_OFF) {
        if (requested == DM_MOTION_CONTROLLER) wantController = router.controller;
        if (requested == DM_MOTION_DEVICE) wantDevice = router.device;
        if (requested == DM_MOTION_AUTO) {
            if (!router.controller) wantDevice = router.device;
            else if (router.selected == DM_MOTION_CONTROLLER || (probeUntil && now <= probeUntil)) wantController = YES;
            else {
                wantDevice = router.device;
                // Bounded recovery probe, not two streams feeding the guest.
                // Device continues serving while a controller proves 100 ms
                // of fresh samples; explicit Device never activates the pad.
                if (now >= nextProbe) {
                    probeUntil = now + 400000000ull; nextProbe = now + 2000000000ull;
                    wantController = YES;
                }
            }
            if (router.selected != DM_MOTION_CONTROLLER && !wantController) wantDevice = router.device;
            if (wantController && router.selected == DM_MOTION_DEVICE) wantDevice = router.device;
        }
    }
    if (!wantController && controllerRunning) stop_controller();
    if (!wantDevice && deviceRunning) stop_device();
    if (wantController) start_controller();
    if (wantDevice) start_device();
}
static void configure(void) {
    stop_controller(); stop_device();
    deviceFailed = NO;
    dm_motion_configure(&router, requested, foreground, controller.motion.hasRotationRate,
                        manager.deviceMotionAvailable && orientation != 0);
    backendEpoch = dm_feedback_motion_begin(0); ++calibration;
    // Bind the clocks for this lifecycle epoch; callbacks retain their sensor
    // timestamps instead of being relabeled as fresh when this queue drains.
    // CMLogItem.timestamp is Mach absolute seconds (verified in the SDK),
    // exactly the clock used by now_ns(). Avoid a different uptime clock that
    // might count sleep differently. Keep one origin for the entire epoch.
    clockOrigin = now_ns(); uptimeOrigin = (double)clockOrigin / 1e9;
    uint64_t now = now_ns(); probeUntil = now + 400000000ull; nextProbe = now + 2000000000ull;
    dispatch_source_set_timer(watchdog, foreground && requested != DM_MOTION_OFF ? DISPATCH_TIME_NOW : DISPATCH_TIME_FOREVER,
                             25 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    diagnosticAt = 0;
    update_acquisition(now);
    write_diagnostics();
}
static void initialize(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        motionQueue = dispatch_queue_create("odyssey.motion-source", DISPATCH_QUEUE_SERIAL);
        diagnosticsQueue = dispatch_queue_create("odyssey.motion-diagnostics", DISPATCH_QUEUE_SERIAL);
        manager = [CMMotionManager new]; sensorQueue = [NSOperationQueue new];
        sensorQueue.name = @"odyssey.device-motion"; sensorQueue.maxConcurrentOperationCount = 1;
        sensorQueue.qualityOfService = NSQualityOfServiceUserInteractive;
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:preference];
        NSInteger value = saved ? saved.integerValue : DM_MOTION_AUTO;
        requested = value >= 0 && value <= 3 ? (int)value : DM_MOTION_AUTO;
        watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, motionQueue);
        dispatch_source_set_timer(watchdog, DISPATCH_TIME_FOREVER, 25 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(watchdog, ^{
            uint64_t now=now_ns(); select_source(now); update_acquisition(now);
            if (!diagnosticAt || now-diagnosticAt >= 1000000000ull) {
                write_diagnostics();
            }
        });
        dispatch_resume(watchdog);
    });
}
void dm_motion_controller(GCController *pad, int active) {
    initialize();
    dispatch_async(motionQueue, ^{
        stop_controller(); // Detach the old owner before replacing the pointer.
        controller = pad; foreground = active != 0; configure();
    });
}
void dm_motion_orientation(UIInterfaceOrientation value) {
    initialize();
    int o = 0;
    switch (value) {
        case UIInterfaceOrientationPortrait: o=DM_MOTION_PORTRAIT; break;
        case UIInterfaceOrientationPortraitUpsideDown: o=DM_MOTION_UPSIDE_DOWN; break;
        case UIInterfaceOrientationLandscapeLeft: o=DM_MOTION_LANDSCAPE_LEFT; break;
        case UIInterfaceOrientationLandscapeRight: o=DM_MOTION_LANDSCAPE_RIGHT; break;
        default: break;
    }
    dispatch_async(motionQueue, ^{ if (orientation != o) { orientation=o; configure(); } });
}
static NSDictionary *snapshot(void) {
        uint64_t now=now_ns(), last=router.last[router.selected];
        dm_feedback_output guest; dm_feedback_poll(now, &guest);
        return @{ @"requestedSource":source_name(requested), @"selectedSource":source_name(router.selected),
            @"controllerAvailable":@(router.controller), @"deviceAvailable":@(router.device),
            @"sourceGeneration":@(router.generation), @"sourceEpoch":@(backendEpoch),
            @"calibrationGeneration":@(calibration), @"interfaceBasis":@(orientation),
            @"sampleAgeMs":last && now>=last ? @((now-last)/1e6) : @(-1),
            @"controllerSampleAgeMs":router.last[1] && now>=router.last[1] ? @((now-router.last[1])/1e6) : @(-1),
            @"deviceSampleAgeMs":router.last[2] && now>=router.last[2] ? @((now-router.last[2])/1e6) : @(-1),
            @"rawSamples":@[@(raw[1]),@(raw[2])], @"acceptedSamples":@[@(accepted[1]),@(accepted[2])],
            @"rejectedSamples":@[@(rejected[1]),@(rejected[2])], @"errors":@(errors), @"lastError":lastError,
            @"guestReadCalls":@(guest.motion_reads), @"guestStatesReturned":@(guest.motion_states_returned),
            @"controllerSampling":@(controllerRunning), @"deviceSampling":@(deviceRunning)};
}
static void write_diagnostics(void) {
    diagnosticAt=now_ns(); NSDictionary *state=snapshot();
    dispatch_async(diagnosticsQueue, ^{
        NSString *doc=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSData *data=[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:[doc stringByAppendingPathComponent:@"motion-source.json"] options:NSDataWritingAtomic error:nil];
    });
}
NSDictionary *dm_motion_diagnostics(void) {
    initialize(); __block NSDictionary *result;
    dispatch_sync(motionQueue, ^{ result=snapshot(); });
    return result;
}
static UIMenu *settings_menu(void) {
    NSInteger current = [NSUserDefaults.standardUserDefaults objectForKey:preference] ?
        [NSUserDefaults.standardUserDefaults integerForKey:preference] : DM_MOTION_AUTO;
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray new];
    for (int i=0;i<=3;i++) {
        int choice = i;
        UIAction *action = [UIAction actionWithTitle:source_name(i) image:nil identifier:nil handler:^(UIAction *a) {
            (void)a; [NSUserDefaults.standardUserDefaults setInteger:choice forKey:preference];
            dispatch_async(motionQueue, ^{ requested=choice; configure(); });
        }];
        action.state = current == i ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    [actions addObject:[UIAction actionWithTitle:@"Recenter" image:nil identifier:nil handler:^(UIAction *a) {
        (void)a; dispatch_async(motionQueue, ^{ configure(); });
    }]];
    return [UIMenu menuWithTitle:@"Gyro source" children:actions];
}
UIButton *dm_motion_settings_button(void) {
    initialize();
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"Gyro" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35]; button.layer.cornerRadius=8;
    button.accessibilityLabel = @"Gyro source and recenter";
    button.showsMenuAsPrimaryAction = YES;
    button.menu = [UIMenu menuWithChildren:@[[UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        completion(@[settings_menu()]);
    }]]];
    return button;
}
UIMenu *dm_motion_settings_menu(void) { initialize(); return settings_menu(); }
BOOL dm_motion_settings_enabled(void) {
    initialize();
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    return ![defaults objectForKey:preference] || [defaults integerForKey:preference]!=DM_MOTION_OFF;
}
void dm_motion_settings_set_enabled(BOOL enabled) {
    initialize(); int choice=enabled?DM_MOTION_AUTO:DM_MOTION_OFF;
    [NSUserDefaults.standardUserDefaults setInteger:choice forKey:preference];
    dispatch_async(motionQueue, ^{ requested=choice; configure(); });
}
