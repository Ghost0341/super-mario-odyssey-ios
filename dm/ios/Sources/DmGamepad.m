// Virtual gamepad (Nintendo button positions) + physical controllers (GameController). Both are merged and handed to the host through dm_input_set (hle_hid.c, bit layout in dm_input.h).
//   Full Odyssey controls are permanent. Legacy DmPadLayout values are ignored
//   without changing stored data: corner left stick and ABXY, D-pad, invisible
//   floating right stick, shoulders, +/- and L3/R3. The deliberate gear opens
//   only gyro, device haptics and device haptics with a controller switches.
//   Touch-down ownership: exclusive gear first, then locked keys (shoulders,
//   − / +, L3 / R3), then the nearest diamond, D-pad or left stick grab radius,
//     then in 3D the right stick for a touch in the right third.
//   Everything hugs the edges and corners to leave the picture room; controls sit over the picture, one CAShapeLayer each: a press only swaps the fill, a stick only moves its knob, nothing redraws the whole screen.
//   Touches no control takes (in 3D, those outside the right third) go to the game's touch screen (pushGame; Super Mario Galaxy's pointer in handheld mode).
//   Gameplay drawings hide with a controller; the gear remains available and
//   consumes its own touches. Physical buttons remain mapped by position.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreText/CoreText.h>
#include <pthread.h>
#include "dm_input.h"
#include "dm.h"
#include "front.h"
#include "game_profile.h"
#include "dm_touch_controls.h"
#include "dm_display_geometry.h"
#include "odyssey_display.h"
#import "DmGearTouch.h"
#import "DmControllerFeedback.h"
#import "DmSettings.h"
#include <stdatomic.h>

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_GEAR, C_GAME };

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn, g_pad_btn;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry, g_pad_lx, g_pad_ly, g_pad_rx, g_pad_ry;
static GCController *g_selected_pad;
static _Atomic uint64_t g_pad_epoch;
static _Atomic int g_settings_visible;
static int tilted(int32_t x, int32_t y) { return (int64_t)x * x + (int64_t)y * y > (int64_t)4000 * 4000; }
static void publish(void) {
    pthread_mutex_lock(&g_mu);
    if (atomic_load(&g_settings_visible)) {
        dm_input_set(0,0,0,0,0);pthread_mutex_unlock(&g_mu);return;
    }
    int32_t lx = g_touch_lx, ly = g_touch_ly, rx = g_touch_rx, ry = g_touch_ry;
    if (tilted(g_pad_lx, g_pad_ly)) { lx = g_pad_lx; ly = g_pad_ly; }   // a tilted physical stick wins
    if (tilted(g_pad_rx, g_pad_ry)) { rx = g_pad_rx; ry = g_pad_ry; }
    dm_input_set(g_touch_btn | g_pad_btn, lx, ly, rx, ry);
    pthread_mutex_unlock(&g_mu);
}

static const int k_btns[] = {B_ZL, B_L, B_ZR, B_R, B_MINUS, B_PLUS, B_LS, B_RS};   // keys locked at touch-down (L3 / R3 only in the 3D layout)

@interface DmGamepad : UIView
- (void)openSettings;
- (BOOL)fullLayout;
@end
static __weak DmGamepad *g_view;
@interface DmGearAccessibility : UIAccessibilityElement
@property (weak) DmGamepad *pad;
@end
@implementation DmGearAccessibility
- (BOOL)accessibilityActivate { [self.pad openSettings]; return YES; }
@end

// Small ordered receipt distinguishes touch delivery from presenter rejection.
static uint64_t gearBegins,gearReady,gearRejected,presented;
static void settings_report(NSString *reason) {
    NSDictionary *state=@{@"build":NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"]?:@"unknown",
        @"gearBegins":@(gearBegins),@"tapReleasesAccepted":@(gearReady),@"tapReleasesRejected":@(gearRejected),@"gesture":@"tap-release",
        @"presented":@(presented),@"visible":@(atomic_load(&g_settings_visible)),@"fullControls":@YES,@"reason":reason};
    static dispatch_queue_t queue;static dispatch_once_t once;
    dispatch_once(&once,^{queue=dispatch_queue_create("odyssey.touch-settings-diagnostics",DISPATCH_QUEUE_SERIAL);});
    dispatch_async(queue,^{
        NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSData *data=[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:[docs stringByAppendingPathComponent:@"touch-settings.json"] options:NSDataWritingAtomic error:nil];
    });
}

@implementation DmGamepad {
    NSMapTable<UITouch *, NSNumber *> *_owner;     // touch → control (with the key for C_BTN or the stick for C_STICK, << 8)
    UITouch *_stick[2]; CGPoint _stickNow[2];      // the touch holding each stick and where it is now (0 left, 1 right)
    CGPoint _rCentre;                              // the right stick's centre: where its touch landed, dragged along past DM_TC_RSTICK_R
    uint64_t _faceBits, _dpadBits, _btnBits, _gearToken;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;    // which keys each touch on the diamond currently holds
    CAShapeLayer *_key[B_N]; CATextLayer *_label[B_N];   // one layer per key
    CAShapeLayer *_ring, *_knob;                   // the left stick (the right one is not drawn)
    UIImageView *_gearIcon;
    dm_tc_gear _gear;
    UITouch *_gearTouch;
    CGRect _previousBounds; UIEdgeInsets _previousInsets;
    DmGearAccessibility *_gearAccessibility;
    BOOL _stickShown;                              // the left stick was held at the last refresh
    BOOL _full;                                    // the 3D layout is current
    CALayer *_controls;                            // holds every control layer: hidden while a physical controller is connected (the view itself stays, for game touches)
    BOOL _padOff;                                  // a physical controller is connected: every touch goes to the game
    UITouch *_game[16];                            // touches on the game's touch screen by finger slot
}

static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_text, *k_textOn;
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = DM_TC_SHADOW_ALPHA; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}
static CATextLayer *label(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor; t.contentsScale = UIScreen.mainScreen.scale;
    [parent addSublayer:t]; return t;
}
static BOOL fullOnly(int b) { return b == B_LS || b == B_RS || b >= B_LEFT; }   // keys shown only in the 3D layout

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _faceOf = [NSMapTable strongToStrongObjectsMapTable];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // each colour carries its own low opacity instead of lowering the whole view's alpha (that would add an off-screen pass for the full-screen layer)
            k_idle = [UIColor colorWithWhite:1 alpha:DM_TC_IDLE_ALPHA]; k_on = [UIColor colorWithWhite:1 alpha:DM_TC_PRESSED_ALPHA]; k_line = [UIColor colorWithWhite:1 alpha:DM_TC_STROKE_ALPHA];
            k_ringFill = [UIColor colorWithWhite:1 alpha:DM_TC_RING_ALPHA]; k_text = [UIColor colorWithWhite:1 alpha:DM_TC_TEXT_ALPHA]; k_textOn = [UIColor colorWithWhite:1 alpha:DM_TC_PRESSED_TEXT_ALPHA];
        });
        _controls = [CALayer layer]; [self.layer addSublayer:_controls];
        _ring = shape(_controls); _ring.fillColor = k_ringFill.CGColor;
        _knob = shape(_controls);
        CAShapeLayer *in = [CAShapeLayer layer]; in.fillColor = nil; in.strokeColor = k_line.CGColor; in.lineWidth = 1.5;   // inner ring of the knob
        [_knob addSublayer:in];
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−"};
        for (int b = 0; b < B_N; b++) {
            _key[b] = shape(_controls);
            if (names[b]) _label[b] = label(_key[b], names[b]);   // the D-pad arms carry no label
        }
        UIImageSymbolConfiguration *symbol=[UIImageSymbolConfiguration configurationWithPointSize:DM_TC_GEAR_ICON_SIZE weight:UIImageSymbolWeightRegular];
        _gearIcon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@DM_TC_GEAR_SYMBOL withConfiguration:symbol]];
        _gearIcon.tintColor=UIColor.whiteColor; _gearIcon.contentMode=UIViewContentModeScaleAspectFit;
        _gearIcon.alpha=DM_TC_GEAR_ALPHA; _gearIcon.userInteractionEnabled=NO;
        [self addSubview:_gearIcon];
        _gearAccessibility = [[DmGearAccessibility alloc] initWithAccessibilityContainer:self];
        _gearAccessibility.pad = self; _gearAccessibility.accessibilityLabel = @"Settings";
        _gearAccessibility.accessibilityHint = @"Tap to open settings";
        _gearAccessibility.accessibilityTraits = UIAccessibilityTraitButton;
        _gearAccessibility.accessibilityCustomActions = @[[[UIAccessibilityCustomAction alloc] initWithName:@"Open settings" actionHandler:^BOOL(UIAccessibilityCustomAction *action) {
            (void)action; [g_view openSettings]; return YES;
        }]];
        self.accessibilityElements = @[_gearAccessibility];
        _full = YES; // Old compact preferences must never remove camera controls.
        [self applyLayout];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(padsChanged) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged) name:GCControllerDidDisconnectNotification object:nil];
        [self padsChanged];
    }
    return self;
}
- (void)applyLayout {   // show / hide the controls for the current layout
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) _key[b].hidden = fullOnly(b) && !_full;
    [CATransaction commit];
}
- (BOOL)fullLayout { return _full; }
- (NSUInteger)gameplayTouchCount {
    NSUInteger count = 0;
    for (UITouch *touch in _owner) if (([_owner objectForKey:touch].unsignedLongLongValue & 0xff) != C_GEAR) ++count;
    return count;
}
- (void)openSettings {
    if (UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) { settings_report(@"application-inactive"); return; }
    if (atomic_load(&g_settings_visible)) { settings_report(@"already-visible"); return; }
    UIViewController *presenter=self.window.rootViewController;
    if (!presenter) { settings_report(@"no-window-presenter"); return; }
    if (presenter.presentedViewController) { settings_report(@"another-modal-presented"); return; }
    [self reset];
    dm_settings_present(presenter);
    if (presenter.presentedViewController) { ++presented; settings_report(@"presented"); }
    else { dm_gamepad_settings_visible(NO); settings_report(@"presentation-rejected"); }
}
- (BOOL)openSettingsAccessibility:(UIAccessibilityCustomAction *)action { (void)action; [self openSettings]; return YES; }

// ---- Layout (points; computed inside the safe area) ----
- (dm_tc_layout)touchLayout {
    UIEdgeInsets i=self.safeAreaInsets;
    return dm_tc_make_layout(self.bounds.size.width, self.bounds.size.height, (dm_tc_insets){i.top,i.left,i.bottom,i.right});
}
static CGPoint cgPoint(dm_tc_point p) { return CGPointMake(p.x,p.y); }
static CGRect cgRect(dm_tc_rect r) { return CGRectMake(r.x,r.y,r.width,r.height); }
- (CGFloat)u { return self.touchLayout.unit; }
- (CGPoint)faceCenter { return cgPoint(self.touchLayout.face); }
- (CGFloat)faceGap { return DM_TC_FACE_GAP * self.u; }
- (CGFloat)faceR { return DM_TC_FACE_R * self.u; }
- (CGPoint)facePos:(int)b { return cgPoint(dm_tc_face_position(self.touchLayout,b)); }
- (CGPoint)stickHome { return cgPoint(self.touchLayout.left_stick); }
- (CGPoint)stickCentre:(int)i { return i ? _rCentre : self.stickHome; }
- (CGFloat)stickR:(int)i { return (i ? DM_TC_RSTICK_R : DM_TC_STICK_R) * self.u; }
- (BOOL)inRightArea:(CGPoint)p { CGRect b = self.bounds; return p.x >= CGRectGetMaxX(b) - b.size.width * DM_TC_RSWIPE; }
- (CGPoint)dpadCenter { return cgPoint(self.touchLayout.dpad); }
- (CGFloat)dpadR { return DM_TC_DPAD_R * self.u; }
static BOOL isDrop(int b) { return b == B_ZL || b == B_L || b == B_ZR || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
- (CGPoint)dropCenter:(int)b { return cgPoint(dm_tc_shoulder(self.touchLayout,b==B_ZR||b==B_R,b==B_ZL||b==B_ZR)); }
- (CGFloat)dropR:(int)b { return (b == B_ZL || b == B_ZR ? DM_TC_ZL_R : DM_TC_L_R) * self.u; }
- (CGPoint)clickCenter:(int)b { return cgPoint(dm_tc_click(self.touchLayout,b==B_RS)); }
- (CGRect)pillRect:(int)b { return cgRect(dm_tc_pill(self.touchLayout,b==B_PLUS)); }

static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
- (int)btnAt:(CGPoint)p {   // locked keys (tested on touch-down only, then locked)
    CGFloat u = self.u;
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (fullOnly(b) && !_full) continue;
        BOOL hit = isDrop(b) ? dist(p, [self dropCenter:b]) <= [self dropR:b] * 1.35
                 : isClick(b) ? dist(p, [self clickCenter:b]) <= DM_TC_CLICK_R * u * 1.35
                 : CGRectContainsPoint(cgRect(dm_tc_pill_hit(self.touchLayout,b==B_PLUS)),p);
        if (hit) return b; }
    return -1;
}
- (uint64_t)faceAt:(CGPoint)p {   // keys under the finger in the diamond (between two keys both count)
    uint64_t m = 0; CGFloat r = self.faceR * 1.25;
    for (int b = B_A; b <= B_Y; b++) if (dist(p, [self facePos:b]) <= r) m |= 1ull << b;
    return m;
}
- (uint64_t)dpadAt:(CGPoint)p {   // 8 directions: 45° each, diagonals press two keys; a small centre circle counts as none
    CGPoint c = self.dpadCenter; CGFloat dx = p.x - c.x, dy = p.y - c.y;
    if (hypot(dx, dy) < self.dpadR * 0.25) return 0;
    double a = atan2(-dy, dx) * 180 / M_PI; uint64_t m = 0;
    if (a > -67.5 && a < 67.5) m |= 1ull << B_RIGHT;
    if (a > 22.5 && a < 157.5) m |= 1ull << B_UP;
    if (a > 112.5 || a < -112.5) m |= 1ull << B_LEFT;
    if (a < -22.5 && a > -157.5) m |= 1ull << B_DOWN;
    return m;
}
- (CGPoint)knobOffset:(int)i {   // knob offset from the stick centre (clamped to the stick radius)
    if (!_stick[i]) return CGPointZero;
    CGPoint h = [self stickCentre:i]; CGFloat dx = _stickNow[i].x - h.x, dy = _stickNow[i].y - h.y, d = hypot(dx, dy), R = [self stickR:i];
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}

// ---- Touch ----
- (void)recompute {
    uint64_t face = 0; for (UITouch *t in _faceOf) face |= [_faceOf objectForKey:t].unsignedLongLongValue;
    uint64_t btn = 0, dpad = 0;
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff);
        if (c == C_BTN) btn |= 1ull << (v >> 8);
        else if (c == C_DPAD) dpad |= [self dpadAt:[t locationInView:self]]; }
    int32_t ax[4] = {0};
    for (int i = 0; i < 2; i++) {
        CGPoint o = [self knobOffset:i]; CGFloat R = [self stickR:i], d = hypot(o.x, o.y), dz = R * DM_TC_DEAD;
        if (d <= dz) continue;
        CGFloat m = fmin((d - dz) / (R * DM_TC_FULL - dz), 1) / d;   // outside the dead zone: 0 rising to full at the full-tilt radius
        ax[i * 2] = (int32_t)lrint(o.x * m * 32767); ax[i * 2 + 1] = (int32_t)lrint(-o.y * m * 32767);   // host: up is positive; rounded so full tilt is exactly 32767
    }
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits;
    _faceBits = face; _dpadBits = dpad; _btnBits = btn;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = face | dpad | btn; g_touch_lx = ax[0]; g_touch_ly = ax[1]; g_touch_rx = ax[2]; g_touch_ry = ax[3];
    pthread_mutex_unlock(&g_mu);
    publish();
    BOOL stick = _stick[0] != nil;   // only the left stick is drawn: the right one needs no refresh
    if (changed || stick || _stickShown) [self refresh];   // also refresh on the stick release so the knob returns to the centre
    _stickShown = stick;
}
// Touches no control takes (all of them while a physical controller is connected) go to the game's touch screen, normalized on the 16:9 picture that front_ios.m
// centres in the screen: Super Mario Galaxy's pointer in handheld mode (profile op_mode). The host reports them only in handheld mode, as on the Switch (hle_hid.c touch_read)
- (void)pushGame {
    if (atomic_load(&g_settings_visible)) { dm_touch_set(NULL,0);return; }
    CGRect b = self.bounds;
    dm_display_geometry geometry=dm_display_make(b.size.width,b.size.height,1,dm_odyssey_display_scene_aspect());
    if (!geometry.valid) { dm_touch_set(NULL,0); return; }
    double w=geometry.picture.width, h=geometry.picture.height;
    double x0=geometry.picture.x, y0=geometry.picture.y;
    dm_touch t[16]; int n = 0;
    for (int i = 0; i < 16; i++) if (_game[i]) {
        CGPoint p = [_game[i] locationInView:self];
        t[n++] = (dm_touch){(uint32_t)i, (float)fmin(fmax((p.x - x0) / w, 0), 0.999), (float)fmin(fmax((p.y - y0) / h, 0), 0.999)};
    }
    dm_touch_set(t, n);
}
- (BOOL)gameBegin:(UITouch *)t {
    for (int i = 0; i < 16; i++) if (!_game[i]) { _game[i] = t; [_owner setObject:@(C_GAME | (uint64_t)i << 8) forKey:t]; return YES; }
    return NO;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    BOOL game = NO;
    for (UITouch *t in ts) {
        CGPoint p = [t locationInView:self];
        if (dm_tc_contains(self.touchLayout.gear,(dm_tc_point){p.x,p.y})) {
            ++gearBegins;settings_report(@"gear-touch-began");
            [_owner setObject:@(C_GEAR) forKey:t];
            if (!_gearTouch) {
                _gearTouch=t;
                // A resting gameplay thumb must not silently reject a deliberate
                // hold. Presentation neutralizes all current input.
                _gearToken=dm_tc_gear_begin(&_gear,(dm_tc_point){p.x,p.y},now_ns(),0);
            } else dm_tc_gear_block(&_gear);
            continue;
        }
        if (_padOff) { game |= [self gameBegin:t]; continue; }
        int hit = [self btnAt:p];
        if (hit >= 0) { [_owner setObject:@(C_BTN | (uint64_t)hit << 8) forKey:t]; continue; }
        // diamond, D-pad, left stick: take the one with the smallest distance / grab radius, if it is <= 1
        CGFloat best = 1; int kind = C_NONE, idx = 0;
        CGFloat f = dist(p, self.faceCenter) / (self.faceGap + self.faceR * 1.6); if (f <= best) { best = f; kind = C_FACE; }
        if (_full) { CGFloat d = dist(p, self.dpadCenter) / (self.dpadR * DM_TC_DPAD_GRAB); if (d < best) { best = d; kind = C_DPAD; } }
        if (!_stick[0]) { CGFloat s = dist(p, self.stickHome) / ([self stickR:0] * DM_TC_STICK_GRAB); if (s < best) { best = s; kind = C_STICK; } }
        if (kind == C_NONE && _full && !_stick[1] && [self inRightArea:p]) { kind = C_STICK; idx = 1; _rCentre = p; }   // the right stick: centred where the touch lands
        if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD) forKey:t];
        else if (kind == C_STICK) { [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p; }
        else game |= [self gameBegin:t];
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (c == C_GEAR) dm_gear_observe_actual_samples(&_gear,t,e,self);
        else if (c == C_FACE) [_faceOf setObject:@([self faceAt:p]) forKey:t];
        else if (c == C_STICK) { _stickNow[v >> 8] = p;
            if ((v >> 8) == 1) { CGFloat d = dist(p, _rCentre), R = [self stickR:1];   // the right stick's centre follows a finger past its radius, so turning back responds at once
                if (d > R) _rCentre = CGPointMake(p.x - (p.x - _rCentre.x) * R / d, p.y - (p.y - _rCentre.y) * R / d); } }
        else if (c == C_GAME) game = YES;
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts tapped:(BOOL)ended event:(UIEvent *)event {
    BOOL game = NO, open=NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if ((v & 0xff)==C_GEAR) {
            if (t==_gearTouch) {
                dm_gear_observe_actual_samples(&_gear,t,event,self);
                CGPoint p=[t locationInView:self];
                if (ended&&dm_tc_gear_tap(&_gear,_gearToken,(dm_tc_point){p.x,p.y},self.touchLayout.gear)) open=YES;
                else { ++gearRejected;settings_report(@"tap-moved-cancelled-or-conflicted"); }
                _gearTouch=nil;
            }
            dm_tc_gear_cancel(&_gear);
        }
        if ((v & 0xff) == C_GAME && (v >> 8) < 16) { _game[v >> 8] = nil; game = YES; }
        [_owner removeObjectForKey:t]; [_faceOf removeObjectForKey:t]; for (int i = 0; i < 2; i++) if (t == _stick[i]) _stick[i] = nil;
    }
    if (game) [self pushGame];
    [self recompute];
    if (open) { ++gearReady;[self openSettings]; }
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:YES event:e]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:NO event:e]; }
- (void)reset { dm_tc_gear_cancel(&_gear); _gearTouch=nil; [_owner removeAllObjects]; [_faceOf removeAllObjects]; _stick[0] = _stick[1] = nil; for (int i = 0; i < 16; i++) _game[i] = nil; [self pushGame]; [self recompute]; }

// ---- Shapes ----
static CGPathRef circlePath(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
static CGPathRef dropPath(CGPoint c, CGFloat r, CGFloat tipAngle, CGFloat round) {   // teardrop: circle + two tangents meeting at the tip, tip slightly rounded
    CGFloat d = r * DM_TC_DROP_TIP, th = acos(r / d);
    CGPoint tip = CGPointMake(c.x + d * cos(tipAngle), c.y + d * sin(tipAngle));
    CGPoint p1 = CGPointMake(c.x + r * cos(tipAngle + th), c.y + r * sin(tipAngle + th)), p2 = CGPointMake(c.x + r * cos(tipAngle - th), c.y + r * sin(tipAngle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, round);
    CGPathAddArc(p, NULL, c.x, c.y, r, tipAngle + th, tipAngle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p); return p;
}
static CGPathRef armPath(CGPoint c, CGFloat R, CGFloat w, CGFloat in, CGFloat angle, CGFloat round) {   // one D-pad arm: an upward pentagon (tip toward the centre) rotated by angle around the centre
    CGPoint v[5] = {{-w, -R}, {w, -R}, {w, -(in + w)}, {0, -in}, {-w, -(in + w)}};
    CGFloat cs = cos(angle), sn = sin(angle);
    for (int i = 0; i < 5; i++) v[i] = CGPointMake(c.x + v[i].x * cs - v[i].y * sn, c.y + v[i].x * sn + v[i].y * cs);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[4].x + v[0].x) / 2, (v[4].y + v[0].y) / 2);
    for (int i = 0; i < 5; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 5].x, v[(i + 1) % 5].y, round);
    CGPathCloseSubpath(p); return p;
}
static void setPath(CAShapeLayer *l, CGPathRef p) { l.path = p; l.shadowPath = p; CGPathRelease(p); }
static void placeLabel(CATextLayer *t, CGPoint c, CGFloat fs) {
    CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fs, NULL);
    t.font = f; t.fontSize = fs;
    CGFloat h = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f), w = fs * 3;
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CFRelease(f);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!CGRectEqualToRect(_previousBounds,self.bounds)||!UIEdgeInsetsEqualToEdgeInsets(_previousInsets,self.safeAreaInsets)) {
        [self reset]; _previousBounds=self.bounds; _previousInsets=self.safeAreaInsets;
    }
    CGFloat u = self.u;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _controls.frame = self.layer.bounds;
    for (int b = B_A; b <= B_Y; b++) { CGPoint c = [self facePos:b]; setPath(_key[b], circlePath(c, self.faceR)); placeLabel(_label[b], c, 20 * u); }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            setPath(_key[b], dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * u)); placeLabel(_label[b], c, 16 * u);   // tip toward the near top corner
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; setPath(_key[b], circlePath(c, DM_TC_CLICK_R * u)); placeLabel(_label[b], c, 13 * u);
        } else {
            CGRect rc = [self pillRect:b];
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 18 * u);
        }
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // the same arm in 90° steps
    for (int i = 0; i < 4; i++) setPath(_key[arms[i].b], armPath(self.dpadCenter, self.dpadR, DM_TC_ARM_W * u, DM_TC_ARM_IN * u, arms[i].angle, 6 * u));
    CGRect gear=cgRect(self.touchLayout.gear);
    _gearIcon.frame=CGRectInset(gear,(DM_TC_GEAR_SIZE-DM_TC_GEAR_ICON_SIZE)/2,(DM_TC_GEAR_SIZE-DM_TC_GEAR_ICON_SIZE)/2);
    _gearAccessibility.accessibilityFrameInContainerSpace=gear;
    setPath(_ring, circlePath(self.stickHome, [self stickR:0]));
    CGFloat k = DM_TC_KNOB_R * u; _knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k);
    setPath(_knob, circlePath(CGPointMake(k, k), k));
    CAShapeLayer *in = (CAShapeLayer *)_knob.sublayers.firstObject; CGPathRef ip = circlePath(CGPointMake(k, k), k * 0.62);
    in.frame = _knob.bounds; in.path = ip; CGPathRelease(ip);
    [CATransaction commit];
    [self refresh];
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
- (void)refresh {   // pressed state → fill, sticks → knob position
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) { BOOL on = (all >> b) & 1;
        _key[b].fillColor = (on ? k_on : k_idle).CGColor; _label[b].foregroundColor = (on ? k_textOn : k_text).CGColor; }
    CGPoint h = self.stickHome, o = [self knobOffset:0];
    _knob.position = CGPointMake(h.x + o.x, h.y + o.y); _knob.fillColor = (_stick[0] ? k_on : k_idle).CGColor;
    [CATransaction commit];
}

// ---- Physical controllers ----
static int32_t axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
static void read_pad(GCExtendedGamepad *g) {
    uint64_t m = 0;
    #define K(btn, bit) if (btn.isPressed) m |= 1ull << bit
    K(g.buttonB, B_A); K(g.buttonA, B_B); K(g.buttonY, B_X); K(g.buttonX, B_Y);   // by position: right A, bottom B, top X, left Y
    K(g.leftShoulder, B_L); K(g.rightShoulder, B_R);
    pthread_mutex_lock(&g_mu); uint64_t prior = g_pad_btn; pthread_mutex_unlock(&g_mu);
    if (g.leftTrigger.value > ((prior & DM_BTN_ZL) ? 0.08f : 0.14f)) m |= DM_BTN_ZL;
    if (g.rightTrigger.value > ((prior & DM_BTN_ZR) ? 0.08f : 0.14f)) m |= DM_BTN_ZR;
    K(g.buttonMenu, B_PLUS); if (g.buttonOptions) K(g.buttonOptions, B_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, B_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, B_RS);
    K(g.dpad.left, B_LEFT); K(g.dpad.up, B_UP); K(g.dpad.right, B_RIGHT); K(g.dpad.down, B_DOWN);
    #undef K
    pthread_mutex_lock(&g_mu);
    g_pad_btn = m; g_pad_lx = axis(g.leftThumbstick.xAxis.value); g_pad_ly = axis(g.leftThumbstick.yAxis.value);
    g_pad_rx = axis(g.rightThumbstick.xAxis.value); g_pad_ry = axis(g.rightThumbstick.yAxis.value);
    pthread_mutex_unlock(&g_mu);
    dm_controller_feedback_travel(g.leftTrigger.value, g.rightTrigger.value);
    publish();
}
- (void)padsChanged {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self padsChanged]; }); return; }
    NSArray<GCController *> *controllers = GCController.controllers;
    GCController *chosen = g_selected_pad && [controllers containsObject:g_selected_pad] ? g_selected_pad : nil;
    for (GCController *c in controllers) if (c.extendedGamepad) {
        if (!chosen) chosen = c;
        if ([c.extendedGamepad isKindOfClass:GCDualSenseGamepad.class]) { chosen = c; break; }
    }
    if (chosen != g_selected_pad) {
        uint64_t epoch = atomic_fetch_add(&g_pad_epoch, 1) + 1;
        g_selected_pad.extendedGamepad.valueChangedHandler = nil;
        g_selected_pad = chosen;
        pthread_mutex_lock(&g_mu); g_pad_btn = 0; g_pad_lx = g_pad_ly = g_pad_rx = g_pad_ry = 0; pthread_mutex_unlock(&g_mu);
        dm_controller_feedback_attach(chosen);
        chosen.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) {
            (void)el; if (atomic_load(&g_pad_epoch) == epoch) read_pad(g);
        };
    }
    if (chosen) read_pad(chosen.extendedGamepad); else publish();
    self->_padOff = chosen != nil; self->_controls.hidden = chosen != nil; [self reset];
}
@end

UIView *dm_gamepad_view(CGRect frame) { DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v; return v; }
void dm_gamepad_geometry_changed(void) {
    // Reflow cancels touches/gear only. Keep physical input, selected controller
    // ownership, motion and feedback epochs intact while folding or resizing.
    if (NSThread.isMainThread) [g_view reset]; else dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; });
}
void dm_gamepad_reset(void) {   // On resign active: release everything (a key held while switching away and released in background gets no "release")
    if (NSThread.isMainThread) [g_view reset];else dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; });
    pthread_mutex_lock(&g_mu); g_pad_btn = 0; g_pad_lx = g_pad_ly = g_pad_rx = g_pad_ry = 0; pthread_mutex_unlock(&g_mu); publish();
}
void dm_gamepad_settings_visible(BOOL visible) {
    atomic_store(&g_settings_visible,visible);[g_view reset];settings_report(visible?@"opening":@"dismissed");
    if (!visible&&g_selected_pad) read_pad(g_selected_pad.extendedGamepad);else publish();
}
