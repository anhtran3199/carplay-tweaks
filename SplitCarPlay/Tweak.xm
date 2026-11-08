//
//  SplitCarPlay — Tweak.xm
//
//  Puts two apps side by side on the physical CarPlay display, with a
//  draggable divider to resize the split.
//
//  ─────────────────────────────────────────────────────────────────────────
//  HOW THIS IS GROUNDED
//
//  The window-creation path below (CADisplay → FBSDisplayConfiguration →
//  UIRootSceneWindow, plus _UISystemGestureManager for routing touches on a
//  non-key display) mirrors the technique used by the open-source,
//  Apache-2.0-licensed tweak "carplay-cast" (EthanArbuckle/carplay-cast),
//  specifically its CRCarPlayWindow class. That project injects into the
//  real CarPlay process bundle id "com.apple.CarPlayApp", which is why the
//  filter plist here targets the same process.
//
//  The per-app content hosting path (SBApplicationController →
//  SBApplicationSceneHandle → SBDeviceApplicationSceneEntity →
//  SBAppViewController) matches the same project's live-app-view mechanism,
//  cross-referenced against another split-screen tweak's own README
//  (DashSplit), which independently names SBApplicationSceneHandle and
//  SBAppViewController for the identical purpose.
//
//  WHAT IS NOT VERIFIED — read before you build
//
//  I have not run or compiled this against a jailbroken device, and the
//  pieces marked "ADAPT" below are the parts where the exact private
//  selector/argument shape is genuinely undocumented (closed internals that
//  shift between iOS versions). Treat every ADAPT block as a starting point:
//  confirm the real signatures with `class-dump`/Hopper against
//  /System/Library/PrivateFrameworks on YOUR device and iOS version before
//  you trust it. Everything marked VERIFIED is cross-referenced against the
//  public source above rather than guessed.
//
//  This tweak only touches the CarPlay UI process on a device you own/
//  jailbreak yourself — it does not affect, bridge into, or exfiltrate data
//  from any other device or account.
//
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>
#import "SplitCarPlayShared.h"
#import "SCPHosting.h"

#pragma mark - MediaRemote (now-playing widget) — real private API, dlopen'd (no framework stub needed)
//
//  MediaRemote.framework is how countless jailbreak tweaks (lockscreen
//  widgets, menu-bar now-playing displays) read what's ACTUALLY playing
//  system-wide from a different process — MPNowPlayingInfoCenter only
//  reflects YOUR OWN process's now-playing info, not another app's.
//  Loaded via dlopen/dlsym rather than linked, same reasoning as every
//  other private-framework workaround in this project: no SDK stub
//  needed, and a missing/renamed symbol degrades to "no now-playing
//  info" instead of a build or runtime failure.
//
typedef void (^SplitCarPlayNowPlayingHandler)(NSDictionary *information);
typedef void (*SplitCarPlayMRGetNowPlayingInfoFunc)(dispatch_queue_t queue, SplitCarPlayNowPlayingHandler handler);
static SplitCarPlayMRGetNowPlayingInfoFunc SplitCarPlayMRGetNowPlayingInfo = NULL;

// Write-side counterpart to -loadPreferences below -- used only for the
// pinch-to-resize callback, since that's the one piece of state this
// process needs to persist on its own rather than just reading what
// Settings already wrote.
static void SplitCarPlayWritePref(NSString *key, id value) {
    SCPSetPref(key, value); // see SplitCarPlayShared.h
}

// File-based logging for the CarPlay hosting path (activateOnDisplay:/
// hostApp:inContainer:) -- there's no way to attach a console to a real
// car's CarPlay session, so NSLog alone is useless for debugging what
// actually happens there. Same pattern CarPlayEnableHook.xm already
// uses for the same reason. Every step gets logged (success AND
// failure), not just failures, so a log with nothing useful in it is
// itself informative (means we never even reached that code).
static void SplitCarPlayHostingLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *path = @"/var/mobile/Library/Logs/splitcarplay_hosting.log";
    NSString *timestamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                           dateStyle:NSDateFormatterNoStyle
                                                           timeStyle:NSDateFormatterMediumStyle];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
    // Also to the system log, in case this process can't write the file.
    NSLog(@"[SplitCarPlay/hosting] %@", message);
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

// Lists a class's class (+) and instance (-) methods, for the hosting log
// when a guessed selector isn't there -- saves a class-dump round trip.
static NSString *SplitCarPlayDescribeMethods(Class cls) {
    if (!cls) return @"(nil class)";
    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    for (int pass = 0; pass < 2; pass++) {
        Class target = pass == 0 ? object_getClass(cls) : cls;
        unsigned int count = 0;
        Method *methods = class_copyMethodList(target, &count);
        for (unsigned int i = 0; i < count; i++) {
            [lines addObject:[NSString stringWithFormat:@"    %@%s", pass == 0 ? @"+" : @"-", sel_getName(method_getName(methods[i]))]];
        }
        free(methods);
    }
    return [lines componentsJoinedByString:@"\n"];
}

static void SplitCarPlayLoadMediaRemote(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!handle) return;
    SplitCarPlayMRGetNowPlayingInfo = (SplitCarPlayMRGetNowPlayingInfoFunc)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
}

#pragma mark - Private class / method forward declarations
// None of these headers ship publicly; these are just enough surface for the
// compiler. Verify real signatures with class-dump on-device (ADAPT where noted).

// VERIFIED shape (per carplay-cast)
@interface CADisplay : NSObject
+ (NSArray *)displays;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) CGRect frame;
@end

@interface FBSDisplayConfiguration : NSObject
- (instancetype)initWithCADisplay:(CADisplay *)display isMainDisplay:(BOOL)isMain;
@end

@interface UIRootSceneWindow : UIWindow
- (instancetype)initWithDisplayConfiguration:(FBSDisplayConfiguration *)config;
@end

// VERIFIED (per carplay-cast, and independently confirmed by extracting the
// literal ObjC selector strings out of SidePlay2's actual shipped
// SidePlay2.dylib — a real commercial tweak doing this exact job — via
// `ar`/`tar`/regex over its data.tar.xz; see git history around where this
// comment was added for the extraction method). SBApplicationController's
// own method list is only "sharedInstance"/"applicationWithBundleIdentifier:"
// in SidePlay2's string table too, matching exactly what we already had.
@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (id)applicationWithBundleIdentifier:(NSString *)bundleID;
@end

// VERIFIED class + accessor name (same string-extraction method as above):
// "+SBSceneManagerCoordinator mainDisplaySceneManager" is a real selector
// string in SidePlay2.dylib. This was our biggest ADAPT gap before -- we
// didn't know how a scene manager for OUR window's display was obtained at
// all. This class only exists in SpringBoard, where "main display" means
// the PHONE's screen: the approach (as in carplay-cast) is to host the
// app's phone scene and re-parent its view into our window on the CarPlay
// display. That's why the hosting code runs in SpringBoard only (%ctor).
@interface SBSceneManagerCoordinator : NSObject
+ (instancetype)mainDisplaySceneManager;
@end

@interface SBDisplaySceneManager : NSObject
- (id)_sceneIdentityForApplication:(id)application createPrimaryIfRequired:(BOOL)create;
- (id)fetchOrCreateApplicationSceneHandleForRequest:(id)request;
@end

// ADAPT still — the CLASS name "SBApplicationSceneHandleRequest" is
// confirmed real (present verbatim in SidePlay2.dylib's string table), but
// no selector matching an init/factory pattern for it showed up in that
// same extraction, so its exact construction API remains a guess. If this
// turns out wrong, class-dumping just this one class on-device (now that
// you at least know the real name to look for) is a much smaller task than
// finding it from scratch.
@interface SBApplicationSceneHandleRequest : NSObject
+ (instancetype)requestForApplication:(id)application sceneIdentity:(id)identity;
@end

// VERIFIED (carplay-cast + DashSplit's README + SidePlay2.dylib's strings
// all agree on these two names and initWithApplicationSceneHandle:).
@interface SBDeviceApplicationSceneEntity : NSObject
- (instancetype)initWithApplicationSceneHandle:(id)handle;
@end

@interface SBAppViewController : UIViewController
// VERIFIED: "-SBAppViewController appView" is a real selector string in
// SidePlay2.dylib -- use this as the actual content view to add as a
// subview, not the inherited UIViewController.view (which may just be an
// empty container the real content gets added to internally; appView is
// what a real shipping tweak doing this exact job reads instead).
@property (nonatomic, readonly) UIView *appView;
// VERIFIED selector strings, exact calling convention (who's the receiver,
// what triggers them) still ADAPT: the scene likely needs to be told it's
// foreground (to receive touches/render actively) and given a real size
// (instead of some default) before it looks right inside a half-width
// container. Guarded with respondsToSelector: everywhere this is used, so
// a wrong guess about which object answers these just skips the call
// rather than crashing.
- (void)setForeground:(BOOL)foreground;
- (void)_updateReferenceSize:(CGSize)size andOrientation:(NSInteger)orientation;
- (instancetype)initWithIdentifier:(NSString *)identifier andApplicationSceneEntity:(id)entity;
@end

static id getCarPlayDisplay(void) {
    Class displayClass = objc_getClass("CADisplay");
    if (!displayClass) return nil;
    for (CADisplay *display in [displayClass displays]) {
        // VERIFIED pattern from carplay-cast's getCarplayCADisplay(): the
        // CarPlay external display's name contains "CarPlay".
        if ([display.name rangeOfString:@"CarPlay" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return display;
        }
    }
    return nil;
}

#pragma mark - Speed card
//
//  A small floating card on top of the split view, styled after Vietmap
//  Live's own "Mô phỏng" preview screen: a boxed speed readout, a
//  connected/disconnected status row, and a thin status bar at the
//  bottom. Every value here (speed number, over-limit color, and whether
//  we're "connected") comes ONLY from whatever VietmapLiveHook.xm (this
//  same dylib, running inside Vietmap Live's own process — see its
//  header comment) last wrote to a shared file. This view does not talk
//  to GPS/CoreLocation itself. "Connected" just means "a fresh value
//  arrived within the last kVietmapStaleAfter seconds", i.e. Vietmap
//  Live is running and the hook is currently seeing calls — it is not a
//  real handshake/protocol with Vietmap Live.
//
static NSString * const kVietmapSharedStatePath = @"/var/mobile/Library/Caches/com.example.splitcarplay/vietmap_speed.plist";
static NSString * const kVietmapUpdateDarwinNotification = @"com.example.splitcarplay/vietmap-update";
static const NSTimeInterval kVietmapStaleAfter = 6.0; // consider "disconnected" if no fresh update

// Bubble "look" — SidePlay2 (a commercial tweak in the same category;
// see ROADMAP.md) offers several shapes picked in Settings. These three
// are our own layouts, not a copy of theirs — just matching the idea
// that one shape doesn't fit everyone's dashboard.
typedef NS_ENUM(NSInteger, SplitCarPlayBubbleStyle) {
    SplitCarPlayBubbleStyleCard = 0,
    SplitCarPlayBubbleStyleRing = 1,
    SplitCarPlayBubbleStyleBar = 2,
};

// "T5, 5/11" -- weekday abbreviation + day/month, matching the reference
// screenshot's date format exactly (not the generic HH:mm clock this
// used to show).
static NSString *SplitCarPlayWeekdayDateString(NSDate *date) {
    NSDateComponents *comps = [[NSCalendar currentCalendar] components:(NSCalendarUnitWeekday | NSCalendarUnitDay | NSCalendarUnitMonth)
                                                                fromDate:date];
    NSArray<NSString *> *weekdayNames = @[@"CN", @"T2", @"T3", @"T4", @"T5", @"T6", @"T7"]; // NSDateComponents.weekday: 1=Sunday
    NSString *weekday = weekdayNames[(comps.weekday - 1) % 7];
    return [NSString stringWithFormat:@"%@, %ld/%ld", weekday, (long)comps.day, (long)comps.month];
}

// SF Symbol battery glyph matched to the current level -- nil-safe (an
// unavailable symbol name just means no icon, not a crash).
static UIImage *SplitCarPlayBatteryIcon(CGFloat level) {
    NSString *name = level >= 0.95 ? @"battery.100"
                    : level >= 0.70 ? @"battery.75"
                    : level >= 0.45 ? @"battery.50"
                    : level >= 0.20 ? @"battery.25"
                    : @"battery.0";
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:name];
    }
    return nil;
}

@interface SpeedBubbleView : UIView
@property (nonatomic, assign) SplitCarPlayBubbleStyle style; // changing this re-lays-out, no need to recreate the view
@property (nonatomic, assign) BOOL showDate;
@property (nonatomic, assign) BOOL showBattery;
@property (nonatomic, assign) BOOL showNowPlaying;
// Uniform resize via pinch, applied as a CGAffineTransform (not a frame/
// bounds resize) -- scales everything, fonts included, without needing
// -layoutSubviews' per-style code to know about a separate size scale.
// Clamped to [0.6, 1.6]. onScaleChanged fires once per gesture (on end),
// not on every pinch delta, so the caller can persist without spamming
// disk writes.
@property (nonatomic, assign) CGFloat scale;
@property (nonatomic, copy) void (^onScaleChanged)(CGFloat scale);
- (void)applyState:(NSDictionary *)state; // state may be nil (= never heard from VietmapLiveHook.xm)
- (void)applyNowPlayingText:(NSString *)text; // nil/empty hides the row
- (void)tick; // called on the existing refresh timer to update date/battery
@end

@implementation SpeedBubbleView {
    UIPanGestureRecognizer *_pan;
    UIPinchGestureRecognizer *_pinch;
    CGFloat _currentScale;
    UIView *_speedBox;
    UILabel *_speedLabel;
    UILabel *_unitLabel;
    UIImageView *_statusIconView;
    UILabel *_statusLabel;
    UIView *_statusBar;
    UILabel *_extrasLabel;       // "Card" style: date, its own line
    UIImageView *_batteryIconView; // "Card" style: battery glyph (SF Symbol, level-matched)
    UILabel *_batteryLabel;      // "Card" style: battery %, its own line (next to the icon)
    UIView *_compassView;        // "Card" style: dashed circle, matches the reference screenshot's heading indicator
    CAShapeLayer *_compassDashLayer;
    UILabel *_compassLabel;      // "--" -- no real heading data source, so always the placeholder dashes
    UILabel *_nowPlayingLabel;   // "Card" style: now-playing, one line
    CAShapeLayer *_ringLayer;    // "Ring" style only
    CAShapeLayer *_maskLayer;    // rounded-corner clip (a mask, not masksToBounds, so the shadow below isn't clipped too)
    UILabel *_barExtrasLabel;    // "Bar" style: date/battery/now-playing combined
    BOOL _connected;
    BOOL _overLimit;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.96];
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.08].CGColor;

        // Rounded-corner clipping via a mask layer rather than
        // masksToBounds=YES, so the drop shadow just below isn't clipped
        // away along with everything else outside the rounded rect.
        self.layer.masksToBounds = NO;
        _maskLayer = [CAShapeLayer new];
        self.layer.mask = _maskLayer;

        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.25;
        self.layer.shadowRadius = 6;
        self.layer.shadowOffset = CGSizeMake(0, 2);


        _speedBox = [[UIView alloc] init];
        _speedBox.backgroundColor = [UIColor whiteColor];
        _speedBox.layer.cornerRadius = 8;
        _speedBox.layer.borderWidth = 1.5;
        [self addSubview:_speedBox];

        _speedLabel = [[UILabel alloc] init];
        _speedLabel.textAlignment = NSTextAlignmentCenter;
        _speedLabel.font = [UIFont boldSystemFontOfSize:28];
        _speedLabel.textColor = [UIColor blackColor];
        _speedLabel.text = @"--";
        [_speedBox addSubview:_speedLabel];

        _unitLabel = [[UILabel alloc] init];
        _unitLabel.textAlignment = NSTextAlignmentCenter;
        _unitLabel.font = [UIFont systemFontOfSize:11];
        _unitLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];
        _unitLabel.text = @"km/h";
        [_speedBox addSubview:_unitLabel];

        _statusIconView = [[UIImageView alloc] init];
        _statusIconView.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_statusIconView];

        _statusLabel = [[UILabel alloc] init];
        _statusLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        _statusLabel.textAlignment = NSTextAlignmentCenter;
        _statusLabel.numberOfLines = 2;
        _statusLabel.text = @"Chưa kết nối";
        _statusLabel.textColor = [UIColor colorWithWhite:0.35 alpha:1];
        [self addSubview:_statusLabel];

        _statusBar = [[UIView alloc] init];
        _statusBar.backgroundColor = [UIColor colorWithWhite:0.8 alpha:1];
        [self addSubview:_statusBar];

        // Date on its own line, left-aligned -- matches the reference
        // screenshot ("T5, 5/11" / "77%" stacked, not combined) rather
        // than the single centered "date · battery" line this used to be.
        _extrasLabel = [[UILabel alloc] init];
        _extrasLabel.textAlignment = NSTextAlignmentLeft;
        _extrasLabel.font = [UIFont systemFontOfSize:11];
        _extrasLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];
        [self addSubview:_extrasLabel];

        // Battery row: SF Symbol glyph (level-matched in -extrasText/
        // -tick, not a fixed icon) + percentage text, its own line.
        _batteryIconView = [[UIImageView alloc] init];
        _batteryIconView.contentMode = UIViewContentModeScaleAspectFit;
        _batteryIconView.tintColor = [UIColor colorWithWhite:0.4 alpha:1];
        [self addSubview:_batteryIconView];

        _batteryLabel = [[UILabel alloc] init];
        _batteryLabel.textAlignment = NSTextAlignmentLeft;
        _batteryLabel.font = [UIFont systemFontOfSize:11];
        _batteryLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];
        [self addSubview:_batteryLabel];

        // Dashed-circle heading indicator below the speed, matching the
        // reference screenshot -- always shows "--" since there's no real
        // compass/heading data source hooked up (Vietmap Live's shared
        // state file only has speed/limit, see VietmapLiveHook.xm), but
        // included for visual parity rather than left out entirely.
        _compassView = [[UIView alloc] init];
        _compassView.backgroundColor = [UIColor clearColor];
        [self addSubview:_compassView];

        _compassDashLayer = [CAShapeLayer new];
        _compassDashLayer.fillColor = [UIColor clearColor].CGColor;
        _compassDashLayer.strokeColor = [UIColor colorWithWhite:0.6 alpha:1].CGColor;
        _compassDashLayer.lineWidth = 1.5;
        _compassDashLayer.lineDashPattern = @[@3, @3];
        [_compassView.layer addSublayer:_compassDashLayer];

        _compassLabel = [[UILabel alloc] init];
        _compassLabel.text = @"--";
        _compassLabel.textAlignment = NSTextAlignmentCenter;
        _compassLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        _compassLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1];
        [_compassView addSubview:_compassLabel];

        _nowPlayingLabel = [[UILabel alloc] init];
        _nowPlayingLabel.textAlignment = NSTextAlignmentCenter;
        _nowPlayingLabel.font = [UIFont systemFontOfSize:10];
        _nowPlayingLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1];
        _nowPlayingLabel.numberOfLines = 1;
        _nowPlayingLabel.adjustsFontSizeToFitWidth = YES;
        [self addSubview:_nowPlayingLabel];

        _ringLayer = [CAShapeLayer new];
        _ringLayer.fillColor = [UIColor clearColor].CGColor;
        _ringLayer.lineWidth = 5;
        _ringLayer.hidden = YES;
        [self.layer addSublayer:_ringLayer];

        _barExtrasLabel = [[UILabel alloc] init];
        _barExtrasLabel.textAlignment = NSTextAlignmentRight;
        _barExtrasLabel.font = [UIFont systemFontOfSize:11];
        _barExtrasLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];
        [self addSubview:_barExtrasLabel];

        _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:_pan];
        _pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
        [self addGestureRecognizer:_pinch];
        self.userInteractionEnabled = YES;
        _currentScale = 1.0;
    }
    return self;
}

- (void)setScale:(CGFloat)scale {
    _currentScale = MAX(0.6, MIN(1.6, scale));
    self.transform = CGAffineTransformMakeScale(_currentScale, _currentScale);
}

- (CGFloat)scale {
    return _currentScale;
}

- (void)handlePinch:(UIPinchGestureRecognizer *)pinch {
    if (pinch.state == UIGestureRecognizerStateChanged) {
        CGFloat candidate = MAX(0.6, MIN(1.6, _currentScale * pinch.scale));
        self.transform = CGAffineTransformMakeScale(candidate, candidate);
    } else if (pinch.state == UIGestureRecognizerStateEnded || pinch.state == UIGestureRecognizerStateCancelled) {
        _currentScale = MAX(0.6, MIN(1.6, _currentScale * pinch.scale));
        self.transform = CGAffineTransformMakeScale(_currentScale, _currentScale);
        if (self.onScaleChanged) self.onScaleChanged(_currentScale);
    }
}

- (void)setStyle:(SplitCarPlayBubbleStyle)style {
    _style = style;
    [self setNeedsLayout];
}

- (void)updateMaskWithCornerRadius:(CGFloat)radius {
    self.layer.cornerRadius = radius; // kept in sync too, even though masksToBounds=NO means this alone wouldn't clip
    _maskLayer.frame = self.bounds;
    _maskLayer.path = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius].CGPath;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    switch (self.style) {
        case SplitCarPlayBubbleStyleRing: [self layoutRingStyle]; return;
        case SplitCarPlayBubbleStyleBar: [self layoutBarStyle]; return;
        case SplitCarPlayBubbleStyleCard: default: [self layoutCardStyle]; return;
    }
}

- (void)layoutCardStyle {
    [self updateMaskWithCornerRadius:14];
    _ringLayer.hidden = YES;
    _barExtrasLabel.hidden = YES;
    _speedBox.hidden = NO;
    _compassView.hidden = NO;
    _statusIconView.hidden = NO;
    _statusLabel.hidden = NO;
    _statusBar.hidden = NO;

    // Ring/Bar styles re-parent these onto `self` directly (see below) --
    // move them back into _speedBox, whose bounds the frames just below
    // are expressed relative to.
    [_speedBox addSubview:_speedLabel];
    [_speedBox addSubview:_unitLabel];
    _speedLabel.font = [UIFont boldSystemFontOfSize:28];
    _statusLabel.numberOfLines = 1; // compact single-line status, not the old 2-line paragraph
    _statusLabel.textAlignment = NSTextAlignmentLeft;
    _statusLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];

    CGFloat w = self.bounds.size.width;
    CGFloat pad = 8;
    CGFloat y = pad;

    // Date and battery on their OWN lines (matches the reference
    // screenshot's "T5, 5/11" / "77%" stacked rows, not a single combined
    // "date · battery" line), above the speed readout -- same placement
    // idea as before, just split in two.
    _extrasLabel.hidden = !self.showDate;
    if (!_extrasLabel.hidden) {
        _extrasLabel.frame = CGRectMake(pad, y, w - pad * 2, 14);
        y = CGRectGetMaxY(_extrasLabel.frame) + 1;
    }
    BOOL showBatteryRow = self.showBattery && !_batteryLabel.hidden;
    if (showBatteryRow) {
        CGFloat iconSize = 12;
        _batteryIconView.frame = CGRectMake(pad, y + 1, iconSize, iconSize);
        _batteryLabel.frame = CGRectMake(CGRectGetMaxX(_batteryIconView.frame) + 4, y, w - pad - CGRectGetMaxX(_batteryIconView.frame) - 4, 14);
        y = CGRectGetMaxY(_batteryLabel.frame) + 4;
    }

    _speedBox.frame = CGRectMake(pad, y, w - pad * 2, 52);
    _speedLabel.frame = CGRectMake(0, 4, _speedBox.bounds.size.width, 30);
    _unitLabel.frame = CGRectMake(0, 34, _speedBox.bounds.size.width, 14);
    y = CGRectGetMaxY(_speedBox.frame) + 8;

    // Dashed-circle heading indicator, matching the reference screenshot
    // -- see the ivar comment on _compassView for why it's always "--".
    CGFloat compassSize = MIN(60, w - pad * 2);
    _compassView.frame = CGRectMake((w - compassSize) / 2.0, y, compassSize, compassSize);
    _compassLabel.frame = _compassView.bounds;
    _compassDashLayer.frame = _compassView.bounds;
    _compassDashLayer.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(_compassView.bounds, 1, 1)].CGPath;
    y = CGRectGetMaxY(_compassView.frame) + 8;

    // Compact one-line status: a small dot-style icon + short text,
    // instead of a big icon with two lines of text underneath it.
    CGFloat statusIconSize = 14;
    _statusIconView.frame = CGRectMake(pad, y + 1, statusIconSize, statusIconSize);
    _statusLabel.frame = CGRectMake(CGRectGetMaxX(_statusIconView.frame) + 4, y, w - pad - CGRectGetMaxX(_statusIconView.frame) - 4, statusIconSize + 2);
    y += statusIconSize + 6;

    _nowPlayingLabel.hidden = !self.showNowPlaying || _nowPlayingLabel.text.length == 0;
    if (!_nowPlayingLabel.hidden) {
        _nowPlayingLabel.frame = CGRectMake(pad, y, w - pad * 2, 12);
        y = CGRectGetMaxY(_nowPlayingLabel.frame);
    }

    CGFloat barHeight = 4;
    _statusBar.frame = CGRectMake(pad, self.bounds.size.height - barHeight - 6, w - pad * 2, barHeight);
    _statusBar.layer.cornerRadius = barHeight / 2.0;
}

- (void)layoutRingStyle {
    // A compact circle: just the speed number + a colored ring. Extras
    // (date/battery/now-playing) are deliberately omitted here — the
    // whole point of this style is to be small.
    CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height);
    [self updateMaskWithCornerRadius:side / 2.0];
    _ringLayer.hidden = NO;
    _barExtrasLabel.hidden = YES;
    _speedBox.hidden = YES;
    _extrasLabel.hidden = YES;
    _batteryIconView.hidden = YES;
    _batteryLabel.hidden = YES;
    _compassView.hidden = YES;
    _nowPlayingLabel.hidden = YES;

    CGRect ringFrame = CGRectMake((self.bounds.size.width - side) / 2.0, (self.bounds.size.height - side) / 2.0, side, side);
    CGFloat inset = _ringLayer.lineWidth / 2.0 + 2;
    _ringLayer.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(ringFrame, inset, inset)].CGPath;
    _ringLayer.frame = self.bounds;

    _speedLabel.frame = CGRectMake(0, side / 2.0 - 20, self.bounds.size.width, 28);
    [self addSubview:_speedLabel]; // re-parent out of the (hidden) speedBox so it still shows
    _unitLabel.frame = CGRectMake(0, side / 2.0 + 6, self.bounds.size.width, 14);
    [self addSubview:_unitLabel];

    _statusIconView.hidden = NO;
    CGFloat iconSize = 16;
    _statusIconView.frame = CGRectMake((self.bounds.size.width - iconSize) / 2.0, side - iconSize - 10, iconSize, iconSize);
    _statusLabel.hidden = YES;
    _statusBar.hidden = YES;
}

- (void)layoutBarStyle {
    [self updateMaskWithCornerRadius:self.bounds.size.height / 2.0];
    _ringLayer.hidden = YES;
    _speedBox.hidden = YES;
    _extrasLabel.hidden = YES;
    _batteryIconView.hidden = YES;
    _batteryLabel.hidden = YES;
    _compassView.hidden = YES;
    _nowPlayingLabel.hidden = YES;
    _statusLabel.hidden = YES;

    CGFloat h = self.bounds.size.height;
    CGFloat pad = 10;

    CGFloat iconSize = MIN(16, h - 8);
    _statusIconView.hidden = NO;
    _statusIconView.frame = CGRectMake(pad, (h - iconSize) / 2.0, iconSize, iconSize);
    [self addSubview:_statusIconView];

    CGFloat speedWidth = 70;
    _speedLabel.frame = CGRectMake(CGRectGetMaxX(_statusIconView.frame) + 8, 0, speedWidth, h);
    _speedLabel.font = [UIFont boldSystemFontOfSize:MIN(22, h * 0.5)];
    [self addSubview:_speedLabel];
    _unitLabel.frame = CGRectMake(CGRectGetMaxX(_speedLabel.frame), 0, 36, h);
    [self addSubview:_unitLabel];

    _barExtrasLabel.hidden = !(self.showDate || self.showBattery || self.showNowPlaying);
    if (!_barExtrasLabel.hidden) {
        CGFloat x = CGRectGetMaxX(_unitLabel.frame) + 4;
        _barExtrasLabel.frame = CGRectMake(x, 0, self.bounds.size.width - x - pad, h);
    }

    CGFloat barHeight = 3;
    _statusBar.hidden = NO;
    _statusBar.frame = CGRectMake(pad, h - barHeight - 3, self.bounds.size.width - pad * 2, barHeight);
    _statusBar.layer.cornerRadius = barHeight / 2.0;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];
}

// Used only by the "Bar" style's single combined line -- "Card" style
// shows date and battery as two separate rows instead (see -tick below).
- (NSString *)extrasText {
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    if (self.showDate) [parts addObject:SplitCarPlayWeekdayDateString([NSDate date])];
    if (self.showBattery) {
        UIDevice *device = [UIDevice currentDevice];
        if (device.batteryState != UIDeviceBatteryStateUnknown) {
            [parts addObject:[NSString stringWithFormat:@"%.0f%%", device.batteryLevel * 100]];
        }
    }
    return [parts componentsJoinedByString:@" · "];
}

- (void)tick {
    // Re-render the date/battery text on a timer (there's no notification
    // for "a minute passed" or "battery % changed by exactly this much",
    // so this piggybacks on the existing 2s refresh timer rather than
    // adding a second one).
    _extrasLabel.text = self.showDate ? SplitCarPlayWeekdayDateString([NSDate date]) : nil;

    UIDevice *device = [UIDevice currentDevice];
    BOOL hasBattery = self.showBattery && device.batteryState != UIDeviceBatteryStateUnknown;
    if (hasBattery) {
        _batteryLabel.text = [NSString stringWithFormat:@"%.0f%%", device.batteryLevel * 100];
        _batteryIconView.image = SplitCarPlayBatteryIcon(device.batteryLevel);
    }
    _batteryLabel.hidden = !hasBattery;
    _batteryIconView.hidden = !hasBattery;

    NSMutableArray<NSString *> *barParts = [NSMutableArray new];
    NSString *extras = [self extrasText];
    if (extras.length > 0) [barParts addObject:extras];
    if (self.showNowPlaying && _nowPlayingLabel.text.length > 0) [barParts addObject:_nowPlayingLabel.text];
    _barExtrasLabel.text = [barParts componentsJoinedByString:@" · "];
    [self setNeedsLayout];
}

- (void)applyNowPlayingText:(NSString *)text {
    _nowPlayingLabel.text = text;
    [self tick]; // refresh the bar-style combined label too
    [self setNeedsLayout];
}

- (void)applyState:(NSDictionary *)state {
    // Prefer the actual current vehicle speed (matches the "0 km/h" style
    // readout in Vietmap Live's own preview); fall back to the speed
    // LIMIT if current speed isn't available yet for some reason.
    NSString *currentSpeedText = state[@"currentSpeedText"];
    NSString *limitText = state[@"speedLimitText"];
    NSString *text = currentSpeedText.length > 0 ? currentSpeedText : limitText;
    BOOL overLimit = [state[@"isOverLimit"] boolValue];
    NSNumber *timestamp = state[@"timestamp"];
    BOOL connected = timestamp && text.length > 0 &&
        ([[NSDate date] timeIntervalSince1970] - timestamp.doubleValue) < kVietmapStaleAfter;
    _connected = connected;
    _overLimit = overLimit;

    _speedLabel.text = connected ? text : @"--";
    UIColor *accentColor = (connected && overLimit) ? [UIColor systemRedColor] : [UIColor colorWithWhite:0.75 alpha:1];
    _speedBox.layer.borderColor = accentColor.CGColor;
    _ringLayer.strokeColor = ((connected && overLimit) ? [UIColor systemRedColor] : [UIColor systemGrayColor]).CGColor;

    if (@available(iOS 13.0, *)) {
        _statusIconView.image = [UIImage systemImageNamed:connected ? @"checkmark.circle.fill" : @"xmark.circle"];
    }
    _statusIconView.tintColor = connected ? [UIColor systemGreenColor] : [UIColor systemGrayColor];

    _statusLabel.text = connected ? @"Vietmap Live" : @"Chưa kết nối";
    _statusBar.backgroundColor = connected
        ? (overLimit ? [UIColor systemRedColor] : [UIColor systemGreenColor])
        : [UIColor colorWithWhite:0.8 alpha:1];
    [self tick];
}

@end

#pragma mark - Controller
//
//  0.8.0: the CarPlay window hosts apps the same way the phone preview
//  does (LivePreview.xm, through SCPHosting.h), because that way works on
//  the device: launch suspended, SBDeviceApplicationSceneEntity
//  initWithApplicationForMainDisplay: + SBAppViewController, setRequestedMode:2,
//  keep the scene foreground and phone-width (view scaled to the pane),
//  never free a view controller, close one app at a time.
//
//  The window itself (CADisplay -> FBSDisplayConfiguration ->
//  UIRootSceneWindow) is the part that already worked in the first car test.
//
//  Still unknown until a car test: whether touches on the car screen reach
//  the hosted apps (the log lists _UISystemGestureManager's display-related
//  methods for that), and whether the scenes stay foreground while the
//  phone is locked.

@interface SplitCarPlayCarSlot : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, strong) UIView *container;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) id application;
@property (nonatomic, strong) UIViewController *appViewController;
@property (nonatomic, strong) id sceneHandle;
@property (nonatomic, strong) id scene;
@property (nonatomic, assign) BOOL hosted;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) NSInteger deadStrikes;
@property (nonatomic, assign) NSInteger reassertStreak;
@property (nonatomic, assign) NSInteger reassertCount;
@end

@implementation SplitCarPlayCarSlot
@end

@interface SplitCarPlayController : NSObject
@property (nonatomic, strong) UIWindow *rootWindow;
@property (nonatomic, strong) NSMutableArray<SplitCarPlayCarSlot *> *slots;
@property (nonatomic, strong) UIView *dividerView;
@property (nonatomic, strong) SpeedBubbleView *speedBubble;
@property (nonatomic, strong) NSTimer *speedBubbleStaleTimer;
@property (nonatomic, strong) NSTimer *keepAliveTimer;
@property (nonatomic, assign) CGFloat splitRatio; // 0..1, left width fraction
@property (nonatomic, assign) BOOL speedAudioAlertEnabled;
@property (nonatomic, assign) BOOL autoExitSourceAppEnabled;
@property (nonatomic, strong) NSDate *lastSpeedAudioAlertAt;
@property (nonatomic, assign) BOOL hostingSessionActive; // keeps the session alive after the pref is auto-disarmed
@property (nonatomic, assign) BOOL singleAppMode;        // one app full-width, no split
@property (nonatomic, assign) BOOL tearingDown;
@property (nonatomic, assign) NSTimeInterval hostDelay;
@property (nonatomic, assign) BOOL dismissedUntilReconnect; // ✕ / watchdog: no auto start until the car reconnects
@property (nonatomic, assign) BOOL lastAutoHost;
@property (nonatomic, assign) BOOL sessionFromAutoHost;
- (void)publishCarPlayState;
@property (nonatomic, assign) NSUInteger sessionGeneration; // invalidates pending callbacks after teardown
@property (nonatomic, strong) UIButton *carCloseButton;
+ (instancetype)sharedInstance;
- (void)teardown;
- (void)reloadFromPreferences;
- (void)refreshSpeedBubble;
@end

@implementation SplitCarPlayController

+ (instancetype)sharedInstance {
    static SplitCarPlayController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [SplitCarPlayController new];
        shared.splitRatio = 0.5;
    });
    return shared;
}

#pragma mark Preferences

- (NSDictionary *)loadPreferences {
    return SCPCopyPrefs(); // defaults + stored values, see SplitCarPlayShared.h
}

// Called on CarPlay connect, on every pref change (the app posts reload)
// and 3 s after SpringBoard starts. A session starts when "Đang bật" on
// Trang chủ (carPlayAutoHost) is on -- on every connect -- or once when
// the one-shot test switch "⚠️ Bật thử nghiệm (1 lần)" is on. Once
// running, pref changes only restyle the bubble.
- (void)reloadFromPreferences {
    NSDictionary *prefs = [self loadPreferences];

    self.autoExitSourceAppEnabled = [prefs[@"autoExitSourceApp"] boolValue];
    self.speedAudioAlertEnabled = [prefs[@"speedAudioAlert"] boolValue];

    BOOL autoHost = [prefs[@"carPlayAutoHost"] boolValue];
    BOOL oneShot = [prefs[@"experimentalHostingEnabled"] boolValue];
    if (autoHost && !self.lastAutoHost) self.dismissedUntilReconnect = NO; // just switched on
    self.lastAutoHost = autoHost;
    if (oneShot) self.dismissedUntilReconnect = NO; // explicit retry

    // A running session ends if "Đang bật" (what started it) goes off.
    BOOL keepRunning = self.hostingSessionActive && (!self.sessionFromAutoHost || autoHost);
    BOOL armed = oneShot || (autoHost && !self.dismissedUntilReconnect) || keepRunning;
    if (!armed || ![prefs[@"enabled"] boolValue]) {
        [self teardown]; // no window: just clears flags a crash may have left
        [self publishCarPlayState];
        return;
    }
    if (self.tearingDown) return;

    id carPlayDisplay = getCarPlayDisplay();
    [self publishCarPlayState];
    if (!carPlayDisplay) return; // not connected to a car yet

    if (!self.rootWindow) {
        // The one-shot test switch turns itself off BEFORE anything risky.
        // "Đang bật" stays on; if SpringBoard dies mid-session, the marker
        // below makes the next SpringBoard start turn it off (%ctor), so a
        // crash can't repeat on every connect.
        self.sessionFromAutoHost = !oneShot;
        if (oneShot) SplitCarPlayWritePref(@"experimentalHostingEnabled", @NO);
        SplitCarPlayWritePref(@"carPlaySessionActive", @YES);
        SCPSetHostingSessionActive(YES);       // CarPlayEnableHook reads this
        BOOL phonePreviewWasRunning = SCPHostSetCarPlaySessionActive(YES); // closes the phone preview, blocks it meanwhile
        self.hostDelay = phonePreviewWasRunning ? 3.0 : 0.0; // let the phone preview let go of the apps first
        double ratio = [prefs[@"splitRatio"] doubleValue];
        self.splitRatio = (ratio > 0) ? MAX(0.2, MIN(0.8, ratio)) : 0.5;
        self.singleAppMode = [prefs[@"experimentalSingleApp"] boolValue];
        [self startSessionOnDisplay:carPlayDisplay prefs:prefs];
        if (!self.rootWindow) {
            SCPSetHostingSessionActive(NO);
            SCPHostSetCarPlaySessionActive(NO);
            SplitCarPlayWritePref(@"carPlaySessionActive", @NO);
            self.dismissedUntilReconnect = YES;
            return;
        }
        self.hostingSessionActive = YES;
    }

    self.dividerView.hidden = self.singleAppMode || ![prefs[@"showDivider"] boolValue];
    [self applyBubblePrefs:prefs];
}

- (void)applyBubblePrefs:(NSDictionary *)prefs {
    if (!self.speedBubble) return;
    self.speedBubble.hidden = ![prefs[@"showSpeedBubble"] boolValue];
    self.speedBubble.style = (SplitCarPlayBubbleStyle)[prefs[@"bubbleStyle"] integerValue];
    self.speedBubble.showDate = [prefs[@"showDate"] boolValue];
    self.speedBubble.showBattery = [prefs[@"showBattery"] boolValue];
    self.speedBubble.showNowPlaying = [prefs[@"showNowPlaying"] boolValue];
    self.speedBubble.scale = prefs[@"bubbleScale"] ? [prefs[@"bubbleScale"] doubleValue] : 1.0;

    // bounds + center, not frame: the bubble carries a pinch scale transform.
    CGPoint center = self.speedBubble.center;
    CGRect bounds = self.speedBubble.bounds;
    switch (self.speedBubble.style) {
        case SplitCarPlayBubbleStyleRing: bounds.size = CGSizeMake(100, 100); break;
        case SplitCarPlayBubbleStyleBar: bounds.size = CGSizeMake(220, 44); break;
        case SplitCarPlayBubbleStyleCard: default: bounds.size = CGSizeMake(116, 266); break;
    }
    BOOL bubbleOnLeft = [prefs[@"bubblePosition"] integerValue] == 0;
    CGFloat screenWidth = self.rootWindow.bounds.size.width;
    CGFloat originX = bubbleOnLeft ? 16 : (screenWidth - bounds.size.width - 16);
    self.speedBubble.bounds = bounds;
    self.speedBubble.center = CGPointMake(originX + bounds.size.width / 2.0, center.y);
    if (!self.speedBubble.hidden) [self refreshSpeedBubble];
}

#pragma mark Window on the CarPlay display

- (void)startSessionOnDisplay:(CADisplay *)carPlayDisplay prefs:(NSDictionary *)prefs {
    NSUInteger generation = ++self.sessionGeneration;
    SplitCarPlayHostingLog(@"[car] start: display=%@ single=%d left=%@ right=%@",
                            carPlayDisplay, self.singleAppMode, prefs[@"leftBundleID"], prefs[@"rightBundleID"]);
    @try {
        FBSDisplayConfiguration *config =
            [[objc_getClass("FBSDisplayConfiguration") alloc] initWithCADisplay:carPlayDisplay isMainDisplay:NO];
        SplitCarPlayHostingLog(@"[car]   FBSDisplayConfiguration = %@", config);
        self.rootWindow = [[objc_getClass("UIRootSceneWindow") alloc] initWithDisplayConfiguration:config];
        SplitCarPlayHostingLog(@"[car]   rootWindow = %@ bounds=%@", self.rootWindow, NSStringFromCGRect(self.rootWindow.bounds));
        if (!self.rootWindow) return;
        self.rootWindow.backgroundColor = [UIColor blackColor];
        [self logTouchRoutingCandidates];

        // Slots: left always; right unless single-app mode or same app.
        NSString *leftID = prefs[@"leftBundleID"];
        NSString *rightID = prefs[@"rightBundleID"];
        NSMutableArray<NSString *> *ids = [NSMutableArray new];
        if (leftID.length) [ids addObject:leftID];
        if (!self.singleAppMode && rightID.length && ![rightID isEqualToString:leftID]) [ids addObject:rightID];
        if (ids.count == 0) {
            SplitCarPlayHostingLog(@"[car]   ABORT: no app picked");
            [self dropWindowNow];
            return;
        }
        if (ids.count == 1) self.singleAppMode = YES;

        self.slots = [NSMutableArray new];
        for (NSString *bundleID in ids) {
            SplitCarPlayCarSlot *slot = [SplitCarPlayCarSlot new];
            slot.bundleID = bundleID;
            slot.container = [[UIView alloc] initWithFrame:CGRectZero];
            slot.container.clipsToBounds = YES;
            slot.container.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
            [self.rootWindow addSubview:slot.container];
            [self.slots addObject:slot];
        }

        self.dividerView = [[UIView alloc] initWithFrame:CGRectZero];
        self.dividerView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.35];
        self.dividerView.layer.cornerRadius = 3;
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDividerPan:)];
        [self.dividerView addGestureRecognizer:pan];
        [self.rootWindow addSubview:self.dividerView];

        CGRect bounds = self.rootWindow.bounds;
        self.speedBubble = [[SpeedBubbleView alloc] initWithFrame:CGRectMake(bounds.size.width - 116 - 16, 16, 116, 266)];
        self.speedBubble.onScaleChanged = ^(CGFloat scale) {
            SplitCarPlayWritePref(@"bubbleScale", @(scale));
        };
        [self.rootWindow addSubview:self.speedBubble];

        // Always-available way out on the car screen: ✕ and a two-finger
        // long press. Both give the normal CarPlay UI back.
        self.carCloseButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.carCloseButton setTitle:@"✕" forState:UIControlStateNormal];
        self.carCloseButton.titleLabel.font = [UIFont boldSystemFontOfSize:22];
        self.carCloseButton.tintColor = [UIColor whiteColor];
        self.carCloseButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        self.carCloseButton.layer.cornerRadius = 22;
        self.carCloseButton.frame = CGRectMake(12, 12, 44, 44);
        [self.carCloseButton addTarget:self action:@selector(closeFromCar) forControlEvents:UIControlEventTouchUpInside];
        [self.rootWindow addSubview:self.carCloseButton];

        UILongPressGestureRecognizer *escape = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleEscapeGesture:)];
        escape.numberOfTouchesRequired = 2;
        escape.minimumPressDuration = 1.0;
        escape.cancelsTouchesInView = NO;
        [self.rootWindow addGestureRecognizer:escape];

        [self.speedBubbleStaleTimer invalidate];
        self.speedBubbleStaleTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self
                                                                      selector:@selector(refreshSpeedBubble)
                                                                      userInfo:nil repeats:YES];

        [self layoutContainers];
        // Hidden until an app view is attached: an opaque empty window is
        // what blanked the CarPlay screen in the first test.
        self.rootWindow.hidden = YES;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.hostDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self hostSlotAtIndex:0 generation:generation];
        });

        // Nothing hosted after 12 s: give the CarPlay screen back.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((12 + self.hostDelay) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != self.sessionGeneration || !self.rootWindow) return;
            BOOL anyHosted = NO;
            for (SplitCarPlayCarSlot *slot in self.slots) anyHosted = anyHosted || slot.hosted;
            if (!anyHosted) {
                SplitCarPlayHostingLog(@"[car] WATCHDOG: nothing hosted after 12 s");
                [self teardown];
            }
        });
    } @catch (NSException *exception) {
        SplitCarPlayHostingLog(@"[car]   EXCEPTION in start: %@ -- %@\n%@", exception.name, exception.reason, exception.callStackSymbols);
        [self teardown];
    }
}

// For the touch question: what the system gesture manager offers for
// extra displays on this iOS version. Logged once; nothing is called.
- (void)logTouchRoutingCandidates {
    static BOOL logged = NO;
    if (logged) return;
    logged = YES;
    Class manager = objc_getClass("_UISystemGestureManager");
    NSMutableArray<NSString *> *matches = [NSMutableArray new];
    for (NSString *line in [SplitCarPlayDescribeMethods(manager) componentsSeparatedByString:@"\n"]) {
        if ([line rangeOfString:@"isplay" options:NSCaseInsensitiveSearch].location != NSNotFound) [matches addObject:line];
    }
    SplitCarPlayHostingLog(@"[car]   _UISystemGestureManager=%@ display methods:\n%@", manager, [matches componentsJoinedByString:@"\n"]);
}

- (void)layoutContainers {
    if (!self.rootWindow) return;
    CGRect bounds = self.rootWindow.bounds;
    SplitCarPlayCarSlot *left = self.slots.count > 0 ? self.slots[0] : nil;
    SplitCarPlayCarSlot *right = self.slots.count > 1 ? self.slots[1] : nil;
    if (!right) {
        left.container.frame = bounds;
        self.dividerView.hidden = YES;
    } else {
        CGFloat dividerWidth = 6;
        CGFloat leftWidth = floor(bounds.size.width * self.splitRatio - dividerWidth / 2.0);
        CGFloat rightWidth = bounds.size.width - leftWidth - dividerWidth;
        left.container.frame = CGRectMake(0, 0, leftWidth, bounds.size.height);
        self.dividerView.frame = CGRectMake(leftWidth, 0, dividerWidth, bounds.size.height);
        right.container.frame = CGRectMake(leftWidth + dividerWidth, 0, rightWidth, bounds.size.height);
    }
    for (SplitCarPlayCarSlot *slot in self.slots) {
        SCPHostLayoutContent(slot.appViewController.view, slot.container.bounds.size);
        slot.messageLabel.frame = CGRectInset(slot.container.bounds, 12, 0);
    }
}

- (void)handleDividerPan:(UIPanGestureRecognizer *)pan {
    CGPoint location = [pan locationInView:self.rootWindow];
    self.splitRatio = MAX(0.2, MIN(0.8, location.x / MAX(1, self.rootWindow.bounds.size.width)));
    [self layoutContainers]; // views follow right away (scaled)
    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        SplitCarPlayWritePref(@"splitRatio", @(self.splitRatio));
        for (SplitCarPlayCarSlot *slot in self.slots) {
            if (slot.hosted && SCPHostAppLooksAlive(slot.application, slot.sceneHandle, slot.scene)) {
                SCPHostSetSceneForeground(slot.scene, YES, SCPHostVirtualSize(slot.container.bounds.size));
            }
        }
    }
}

- (void)showMessage:(NSString *)message inSlot:(SplitCarPlayCarSlot *)slot {
    if (!slot.messageLabel) {
        slot.messageLabel = [[UILabel alloc] init];
        slot.messageLabel.numberOfLines = 0;
        slot.messageLabel.textAlignment = NSTextAlignmentCenter;
        slot.messageLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
        slot.messageLabel.font = [UIFont systemFontOfSize:15];
        [slot.container addSubview:slot.messageLabel];
    }
    slot.messageLabel.text = message;
    slot.messageLabel.frame = CGRectInset(slot.container.bounds, 12, 0);
}

#pragma mark Hosting (same steps as the phone preview)

- (void)hostSlotAtIndex:(NSUInteger)index generation:(NSUInteger)generation {
    if (generation != self.sessionGeneration || index >= self.slots.count) return;
    SplitCarPlayCarSlot *slot = self.slots[index];
    if (index > 0) {
        SplitCarPlayCarSlot *previous = self.slots[index - 1];
        if (previous.hosted && !SCPHostAppLooksAlive(previous.application, previous.sceneHandle, previous.scene)) {
            SplitCarPlayHostingLog(@"[car] host[%lu] %@: skipped, the first app is no longer running", (unsigned long)index, slot.bundleID);
            slot.finished = YES;
            [self showMessage:@"Không mở app thứ 2: app thứ nhất vừa bị iOS đóng (thiếu RAM)." inSlot:slot];
            return;
        }
    }
    SplitCarPlayHostingLog(@"[car] host[%lu] %@: launching suspended", (unsigned long)index, slot.bundleID);
    [self showMessage:@"Đang mở…" inSlot:slot];
    __weak __typeof__(self) weakSelf = self;
    SCPHostLaunchSuspended(slot.bundleID, ^(NSError *error) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.sessionGeneration) return;
            if (error) {
                slot.finished = YES;
                [strongSelf showMessage:@"Không khởi động được app này." inSlot:slot];
            } else {
                [strongSelf attachSlot:slot];
            }
            if (index + 1 < strongSelf.slots.count) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [weakSelf hostSlotAtIndex:index + 1 generation:generation];
                });
            }
        });
    });
}

- (void)attachSlot:(SplitCarPlayCarSlot *)slot {
    @try {
        NSString *bundleID = slot.bundleID;
        id application = SCPHostApplication(bundleID);
        SplitCarPlayHostingLog(@"[car]   attach %@: application=%@", bundleID, application);
        if (!application) {
            slot.finished = YES;
            [self showMessage:@"Không tìm thấy app này." inSlot:slot];
            return;
        }
        slot.application = application;
        UIViewController *appVC = SCPHostAppViewController(bundleID, application);
        SplitCarPlayHostingLog(@"[car]   attach %@: appVC=%@", bundleID, appVC);
        if (!appVC) {
            slot.finished = YES;
            [self showMessage:@"Không hiển thị được app này (xem log)." inSlot:slot];
            return;
        }
        SplitCarPlayHostingLog(@"[car]   attach %@: setting live mode", bundleID);
        if ([appVC respondsToSelector:NSSelectorFromString(@"setIgnoresOcclusions:")]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(appVC, NSSelectorFromString(@"setIgnoresOcclusions:"), YES);
        }
        if ([appVC respondsToSelector:NSSelectorFromString(@"setRequestedMode:")]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(appVC, NSSelectorFromString(@"setRequestedMode:"), 2);
        }
        UIView *content = appVC.view;
        content.hidden = NO;
        [slot.container insertSubview:content atIndex:0]; // moves it out of any earlier window
        slot.appViewController = appVC;
        SCPHostLayoutContent(content, slot.container.bounds.size);

        id sceneHandle = [appVC respondsToSelector:NSSelectorFromString(@"sceneHandle")]
            ? ((id (*)(id, SEL))objc_msgSend)(appVC, NSSelectorFromString(@"sceneHandle")) : nil;
        id scene = nil;
        if ([sceneHandle respondsToSelector:NSSelectorFromString(@"sceneIfExists")]) {
            scene = ((id (*)(id, SEL))objc_msgSend)(sceneHandle, NSSelectorFromString(@"sceneIfExists"));
        }
        slot.sceneHandle = sceneHandle;
        slot.scene = scene;
        SplitCarPlayHostingLog(@"[car]   attach %@: sceneHandle=%@ scene=%@", bundleID, sceneHandle, scene);
        SCPHostSetSceneForeground(scene, YES, SCPHostVirtualSize(slot.container.bounds.size));

        slot.hosted = YES;
        if (self.rootWindow.hidden) {
            self.rootWindow.hidden = NO;
            SplitCarPlayHostingLog(@"[car]   window shown");
        }
        [self publishCarPlayState];
        [self startKeepAlive];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!slot.hosted) return;
            slot.messageLabel.hidden = YES;
            SplitCarPlayHostingLog(@"[car]   attach %@: after 1.5 s bounds=%@ scale=%.2f window=%@",
                                    bundleID, NSStringFromCGRect(content.bounds), content.transform.a, content.window);
        });
    } @catch (NSException *exception) {
        SplitCarPlayHostingLog(@"[car]   attach %@ EXCEPTION %@ -- %@\n%@", slot.bundleID, exception.name, exception.reason, exception.callStackSymbols);
        slot.finished = YES;
    }
}

- (void)startKeepAlive {
    if (self.keepAliveTimer) return;
    __weak __typeof__(self) weakSelf = self;
    self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *timer) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { [timer invalidate]; return; }
        [strongSelf keepAliveTick];
    }];
}

- (void)keepAliveTick {
    @try {
        for (SplitCarPlayCarSlot *slot in [self.slots copy]) {
            if (!slot.hosted) continue;
            if (!slot.scene && [slot.sceneHandle respondsToSelector:NSSelectorFromString(@"sceneIfExists")]) {
                slot.scene = ((id (*)(id, SEL))objc_msgSend)(slot.sceneHandle, NSSelectorFromString(@"sceneIfExists"));
                if (!slot.scene) continue;
                SplitCarPlayHostingLog(@"[car]   keepAlive %@: scene appeared", slot.bundleID);
            }
            if (!SCPHostAppLooksAlive(slot.application, slot.sceneHandle, slot.scene)) {
                if (++slot.deadStrikes >= 2) [self dropSlot:slot message:@"App đã bị iOS đóng (có thể do thiếu RAM)."];
                continue;
            }
            slot.deadStrikes = 0;
            id settings = [slot.scene respondsToSelector:NSSelectorFromString(@"settings")]
                ? ((id (*)(id, SEL))objc_msgSend)(slot.scene, NSSelectorFromString(@"settings")) : nil;
            BOOL foreground = [settings respondsToSelector:NSSelectorFromString(@"isForeground")]
                ? ((BOOL (*)(id, SEL))objc_msgSend)(settings, NSSelectorFromString(@"isForeground")) : YES;
            if (foreground) {
                slot.reassertStreak = 0;
                continue;
            }
            slot.reassertCount++;
            if (++slot.reassertStreak > 20) {
                [self dropSlot:slot message:@"iOS không cho app này chạy trên màn hình xe."];
                continue;
            }
            if (slot.reassertCount <= 5 || slot.reassertCount % 20 == 0) {
                SplitCarPlayHostingLog(@"[car]   keepAlive %@: scene went background, re-asserting (#%ld)", slot.bundleID, (long)slot.reassertCount);
            }
            SCPHostSetSceneForeground(slot.scene, YES, SCPHostVirtualSize(slot.container.bounds.size));
        }
    } @catch (NSException *exception) {
        SplitCarPlayHostingLog(@"[car]   keepAlive EXCEPTION %@ -- %@", exception.name, exception.reason);
    }
    BOOL anyLeft = NO;
    for (SplitCarPlayCarSlot *slot in self.slots) anyLeft = anyLeft || slot.hosted || !slot.finished;
    if (self.rootWindow && self.slots.count && !anyLeft) {
        SplitCarPlayHostingLog(@"[car] no app left running");
        [self teardown];
    }
}

// The app is gone: hide its view, don't touch its scene, never free it.
- (void)dropSlot:(SplitCarPlayCarSlot *)slot message:(NSString *)message {
    SplitCarPlayHostingLog(@"[car]   drop %@: %@", slot.bundleID, message);
    slot.hosted = NO;
    slot.finished = YES;
    slot.appViewController.view.hidden = YES;
    SCPHostForgetAppViewController(slot.bundleID, slot.appViewController);
    slot.appViewController = nil;
    slot.scene = nil;
    slot.sceneHandle = nil;
    slot.messageLabel.hidden = NO;
    [self showMessage:message inSlot:slot];
}

- (void)closeFromCar {
    SplitCarPlayHostingLog(@"[car] closed from the car screen (✕ / two-finger long press)");
    [self teardown];
}

- (void)handleEscapeGesture:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) [self closeFromCar];
}

#pragma mark Teardown (one app at a time, nothing freed)

- (void)dropWindowNow {
    self.rootWindow.hidden = YES;
    SCPHostKeepForever(self.rootWindow);
    self.rootWindow = nil;
}

- (void)teardown {
    self.sessionGeneration++;
    [self.keepAliveTimer invalidate];
    self.keepAliveTimer = nil;
    [self.speedBubbleStaleTimer invalidate];
    self.speedBubbleStaleTimer = nil;
    self.hostingSessionActive = NO;
    if (self.tearingDown) return;
    if (!self.rootWindow) {
        SCPSetHostingSessionActive(NO); // also clears a flag left by a crash mid-session
        SCPHostSetCarPlaySessionActive(NO);
        return;
    }
    SplitCarPlayHostingLog(@"[car] stop");
    self.tearingDown = YES;
    // ✕, watchdog, no app left: don't auto-start again until the car
    // reconnects (UIScreenDidDisconnect clears this) or "Đang bật" is
    // switched off and on.
    self.dismissedUntilReconnect = YES;
    NSArray<SplitCarPlayCarSlot *> *slots = [self.slots copy] ?: @[];
    self.slots = nil;
    UIWindow *window = self.rootWindow;
    self.rootWindow = nil;
    self.speedBubble = nil;
    self.carCloseButton = nil;
    self.dividerView = nil;
    window.hidden = YES; // the normal CarPlay UI is back right away
    SCPHostKeepForever(window);
    [self releaseSlots:slots index:0];
}

- (void)releaseSlots:(NSArray<SplitCarPlayCarSlot *> *)slots index:(NSUInteger)index {
    if (index >= slots.count) {
        self.tearingDown = NO;
        SCPSetHostingSessionActive(NO);
        SCPHostSetCarPlaySessionActive(NO);
        [self publishCarPlayState];
        SplitCarPlayHostingLog(@"[car] stop: done");
        // Marker cleared a bit later, so a crash right after closing counts.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self.rootWindow && !self.tearingDown) SplitCarPlayWritePref(@"carPlaySessionActive", @NO);
        });
        return;
    }
    SplitCarPlayCarSlot *slot = slots[index];
    BOOL alive = NO;
    @try {
        alive = slot.hosted && slot.appViewController && SCPHostAppLooksAlive(slot.application, slot.sceneHandle, slot.scene);
        if (alive && [slot.appViewController respondsToSelector:NSSelectorFromString(@"setRequestedMode:")]) {
            SplitCarPlayHostingLog(@"[car]   stop %@: setRequestedMode:0", slot.bundleID);
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(slot.appViewController, NSSelectorFromString(@"setRequestedMode:"), 0);
            SplitCarPlayHostingLog(@"[car]   stop %@: setRequestedMode:0 done", slot.bundleID);
        }
    } @catch (NSException *exception) {
        SplitCarPlayHostingLog(@"[car]   stop %@ EXCEPTION %@ -- %@", slot.bundleID, exception.name, exception.reason);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((alive ? 0.6 : 0.1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            if (alive && SCPHostAppLooksAlive(slot.application, slot.sceneHandle, slot.scene)) {
                id settings = [slot.scene respondsToSelector:NSSelectorFromString(@"settings")]
                    ? ((id (*)(id, SEL))objc_msgSend)(slot.scene, NSSelectorFromString(@"settings")) : nil;
                BOOL foreground = [settings respondsToSelector:NSSelectorFromString(@"isForeground")]
                    && ((BOOL (*)(id, SEL))objc_msgSend)(settings, NSSelectorFromString(@"isForeground"));
                if (foreground) {
                    SplitCarPlayHostingLog(@"[car]   stop %@: backgrounding", slot.bundleID);
                    SCPHostSetSceneForeground(slot.scene, NO, [UIScreen mainScreen].bounds.size);
                }
            }
        } @catch (NSException *exception) {
            SplitCarPlayHostingLog(@"[car]   stop %@ EXCEPTION %@ -- %@", slot.bundleID, exception.name, exception.reason);
        }
        slot.appViewController = nil; // still kept by the hosting core
        slot.scene = nil;
        slot.sceneHandle = nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((alive ? 0.6 : 0.0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self releaseSlots:slots index:index + 1];
        });
    });
}

// For the app's Trang chủ: not connected / connected / apps on the car.
- (void)publishCarPlayState {
    uint64_t state = SCPCarPlayStateDisconnected;
    if (getCarPlayDisplay()) {
        state = (self.rootWindow && !self.rootWindow.hidden) ? SCPCarPlayStateShowing : SCPCarPlayStateConnected;
    }
    if (state != SCPGetCarPlayState()) SCPSetCarPlayState(state);
}

#pragma mark Speed bubble (data comes from VietmapLiveHook.xm, same dylib)

- (void)refreshSpeedBubble {
    if (!self.speedBubble || self.speedBubble.hidden) return;
    // Two possible sources: the shared file (may be blocked by Vietmap
    // Live's sandbox) and the Darwin-notify state (see
    // SplitCarPlayShared.h). Use whichever is newer.
    NSDictionary *fileState = [NSDictionary dictionaryWithContentsOfFile:kVietmapSharedStatePath];
    NSDictionary *notifyState = SCPReadSpeedState();
    NSDictionary *state = fileState;
    if ([notifyState[@"timestamp"] doubleValue] > [fileState[@"timestamp"] doubleValue]) state = notifyState;
    [self.speedBubble applyState:state ?: @{}]; // empty state renders as "disconnected"
    [self.speedBubble tick];

    BOOL overLimit = [state[@"isOverLimit"] boolValue];
    if (self.speedAudioAlertEnabled && overLimit) {
        NSTimeInterval sinceLastAlert = self.lastSpeedAudioAlertAt ? -[self.lastSpeedAudioAlertAt timeIntervalSinceNow] : INFINITY;
        if (sinceLastAlert > 8.0) {
            AudioServicesPlaySystemSound(1057); // "Tink"
            self.lastSpeedAudioAlertAt = [NSDate date];
        }
    } else if (!overLimit) {
        self.lastSpeedAudioAlertAt = nil; // next over-limit episode alerts immediately
    }

    if (self.speedBubble.showNowPlaying && SplitCarPlayMRGetNowPlayingInfo) {
        __weak SpeedBubbleView *weakBubble = self.speedBubble;
        SplitCarPlayMRGetNowPlayingInfo(dispatch_get_main_queue(), ^(NSDictionary *information) {
            NSString *title = information[@"kMRMediaRemoteNowPlayingInfoTitle"];
            NSString *artist = information[@"kMRMediaRemoteNowPlayingInfoArtist"];
            NSString *text = nil;
            if (title.length > 0) {
                text = artist.length > 0 ? [NSString stringWithFormat:@"%@ — %@", title, artist] : title;
            }
            [weakBubble applyNowPlayingText:text];
        });
    } else if (!self.speedBubble.showNowPlaying) {
        [self.speedBubble applyNowPlayingText:nil];
    }
}

@end

#pragma mark - Entry point

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

        // The window/hosting code runs in SpringBoard ONLY. The SB* classes
        // hostApp: needs exist only there (in CarPlayApp they're nil, so
        // every attempt failed after an empty window was already up), and
        // running in both processes meant two windows on the CarPlay
        // display. CarPlayApp still loads this dylib for
        // CarPlayEnableHook.xm; Vietmap Live for VietmapLiveHook.xm.
        if (![bundleID isEqualToString:@"com.apple.springboard"]) {
            return;
        }

        SplitCarPlayLoadMediaRemote();

        // SpringBoard died during a CarPlay session: switch "Đang bật" off
        // so the same thing can't crash it on every connect, and tell the
        // app (Trang chủ shows it once).
        NSDictionary *prefs = SCPCopyPrefs();
        if ([prefs[@"carPlaySessionActive"] boolValue]) {
            SCPSetPref(@"carPlaySessionActive", @NO);
            SCPSetPref(@"carPlayAutoHost", @NO);
            SCPSetPref(@"carPlayCrashNotice", @YES);
            SplitCarPlayHostingLog(@"[car] SpringBoard restarted during a CarPlay session: \"Đang bật\" switched off");
        }
        SCPSetCarPlayState(SCPCarPlayStateDisconnected);

        // Re-check whenever a display connects/disconnects (CarPlay plug/unplug)
        // and whenever the user changes a preference.
        [[NSNotificationCenter defaultCenter] addObserverForName:UIScreenDidConnectNotification
                                                            object:nil
                                                             queue:nil
                                                        usingBlock:^(NSNotification *note) {
            [[SplitCarPlayController sharedInstance] reloadFromPreferences];
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIScreenDidDisconnectNotification
                                                            object:nil
                                                             queue:nil
                                                        usingBlock:^(NSNotification *note) {
            [[SplitCarPlayController sharedInstance] teardown];
            // The car went away: next connect may auto-start again.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (getCarPlayDisplay()) return;
                [SplitCarPlayController sharedInstance].dismissedUntilReconnect = NO;
                [[SplitCarPlayController sharedInstance] publishCarPlayState];
            });
            if (![[SplitCarPlayController sharedInstance] autoExitSourceAppEnabled]) return;
            // Only react to CarPlay going away, not e.g. an AirPlay screen:
            // give the display list a moment to update, then check whether a
            // CarPlay display is still there.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (getCarPlayDisplay()) return;
                // Handled by VietmapLiveHook.xm (this same dylib, running
                // inside Vietmap Live's own process).
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                      (__bridge CFStringRef)@"com.example.splitcarplay/request-exit-source",
                                                      NULL, NULL, YES);
            });
        }];

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            (CFNotificationCallback)[](CFNotificationCenterRef center, void *observer, CFStringRef name,
                                        const void *object, CFDictionaryRef userInfo) {
                [[SplitCarPlayController sharedInstance] reloadFromPreferences];
            },
            (__bridge CFStringRef)@"com.example.splitcarplay/reload",
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        // Posted by VietmapLiveHook.xm (same dylib, running inside Vietmap
        // Live's own process) whenever it
        // picks up a new speed-limit reading from Vietmap Live.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            (CFNotificationCallback)[](CFNotificationCenterRef center, void *observer, CFStringRef name,
                                        const void *object, CFDictionaryRef userInfo) {
                [[SplitCarPlayController sharedInstance] refreshSpeedBubble];
            },
            (__bridge CFStringRef)kVietmapUpdateDarwinNotification,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            (CFNotificationCallback)[](CFNotificationCenterRef center, void *observer, CFStringRef name,
                                        const void *object, CFDictionaryRef userInfo) {
                [[SplitCarPlayController sharedInstance] refreshSpeedBubble];
            },
            CFSTR(SCP_SPEED_STATE_NOTIFICATION),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        // In case CarPlay is already connected when we're injected.
        // Deferred, not called inline: %ctor runs before UIApplicationMain,
        // and creating windows / touching SpringBoard classes that early
        // can crash on every respawn (-> safe mode).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[SplitCarPlayController sharedInstance] reloadFromPreferences];
        });
    }
}
