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
    NSString *path = @"/var/mobile/Library/Preferences/com.example.splitcarplay.plist";
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary new];
    prefs[key] = value;
    [prefs writeToFile:path atomically:YES];
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

@interface SplitCarPlayController : NSObject
@property (nonatomic, strong) UIWindow *rootWindow;
@property (nonatomic, strong) UIView *leftContainer;
@property (nonatomic, strong) UIView *rightContainer;
@property (nonatomic, strong) UIView *dividerView;
@property (nonatomic, strong) UIViewController *leftAppVC;
@property (nonatomic, strong) UIViewController *rightAppVC;
@property (nonatomic, strong) SpeedBubbleView *speedBubble;
@property (nonatomic, strong) UIButton *closeOverlayButton; // live preview overlay only (see showLivePreviewOverlayWithLeft:right:)
@property (nonatomic, strong) NSTimer *speedBubbleStaleTimer;
@property (nonatomic, assign) CGFloat splitRatio; // 0..1, left width fraction
@property (nonatomic, assign) BOOL speedAudioAlertEnabled;
@property (nonatomic, assign) BOOL autoExitSourceAppEnabled;
@property (nonatomic, strong) NSDate *lastSpeedAudioAlertAt;
// Experimental hosting session state (see reloadFromPreferences).
@property (nonatomic, assign) BOOL hostingSessionActive; // keeps the session alive after the pref is auto-disarmed
@property (nonatomic, assign) BOOL singleAppMode;        // milestone 1: one app full-width, no split
@property (nonatomic, assign) NSUInteger sessionGeneration; // invalidates a pending watchdog after teardown
@property (nonatomic, strong) UIButton *carCloseButton;
+ (instancetype)sharedInstance;
- (void)activateOnDisplay:(id)carPlayDisplay;
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
    NSString *path = @"/var/mobile/Library/Preferences/com.example.splitcarplay.plist";
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
    NSMutableDictionary *merged = [@{
        @"enabled": @YES,
        @"experimentalHostingEnabled": @NO, // see reloadFromPreferences -- opt-in only, default off since the real CarPlay path is known-broken
        @"leftBundleID": @"com.apple.Maps",
        @"rightBundleID": @"com.apple.Music",
        @"splitRatio": @0.5,
        @"showDivider": @YES,
        @"showSpeedBubble": @YES,
        @"bubbleStyle": @0,
        @"bubblePosition": @1, // 0 = left, 1 = right (matches the original top-right placement)
        @"bubbleScale": @1.0, // pinch-to-resize; also a "Bubble Scale" slider in Settings
        @"speedAudioAlert": @YES,
        @"showDate": @YES,
        @"showBattery": @YES,
        @"showNowPlaying": @YES,
        @"keepSourceAppAlive": @YES,
        @"autoExitSourceApp": @NO,
    } mutableCopy];
    if (prefs) [merged addEntriesFromDictionary:prefs];
    return merged;
}

- (void)reloadFromPreferences {
    // DISABLED BY DEFAULT pending an architecture pivot -- see
    // ROADMAP.md. First real-CarPlay-hardware test of hostApp:/
    // activateOnDisplay: left the CarPlay screen blank (the window got
    // created -- the VERIFIED part -- but every app-hosting call
    // silently failed, the ADAPT part), which actively breaks normal
    // CarPlay use while driving.
    //
    // "experimentalHostingEnabled" is a SEPARATE flag from "enabled" --
    // deliberately not reusing "enabled" so this can't get silently
    // re-armed by anything that still writes the old key. Must be
    // turned on explicitly (via "Trên xe"'s clearly-labeled warning
    // toggle) for this to run at all; every step is now logged to
    // /var/mobile/Library/Logs/splitcarplay_hosting.log (see
    // SplitCarPlayHostingLog) so a next real-CarPlay test actually
    // produces debuggable evidence instead of just "blank again."
    NSDictionary *prefs = [self loadPreferences];

    // Settings that don't depend on the CarPlay window -- read them before
    // the experimental gate so they work even while hosting is off.
    self.autoExitSourceAppEnabled = [prefs[@"autoExitSourceApp"] boolValue];
    self.speedAudioAlertEnabled = [prefs[@"speedAudioAlert"] boolValue];
    // Clamp like the divider pan does: a missing/0 value would otherwise
    // give negative container widths.
    double ratio = [prefs[@"splitRatio"] doubleValue];
    self.splitRatio = (ratio > 0) ? MAX(0.2, MIN(0.8, ratio)) : 0.5;

    // A session that already started stays alive even though the pref was
    // auto-disarmed when it began (one-shot, see below).
    BOOL armed = [prefs[@"experimentalHostingEnabled"] boolValue] || self.hostingSessionActive;
    if (!armed || ![prefs[@"enabled"] boolValue]) {
        [self teardown];
        return;
    }

    id carPlayDisplay = getCarPlayDisplay();
    if (!carPlayDisplay) return; // not connected to a car yet

    if (!self.rootWindow) {
        [self activateOnDisplay:carPlayDisplay];
        if (!self.rootWindow) return; // activation failed and tore itself down
        self.hostingSessionActive = YES;
        // One-shot: turn the switch off now, so if this attempt goes wrong
        // the NEXT CarPlay connect is back to normal without touching the
        // phone. Re-arm it in the app for each test.
        SplitCarPlayWritePref(@"experimentalHostingEnabled", @NO);
        [self startWatchdog];
    }

    self.singleAppMode = prefs[@"experimentalSingleApp"] ? [prefs[@"experimentalSingleApp"] boolValue] : YES;
    self.dividerView.hidden = self.singleAppMode || ![prefs[@"showDivider"] boolValue];
    self.rightContainer.hidden = self.singleAppMode;

    // Lay out first so the containers have a real size when hostApp: reads
    // container.bounds (they start at CGRectZero).
    [self layoutContainers];
    [self hostApp:prefs[@"leftBundleID"] inContainer:self.leftContainer replacingExisting:&_leftAppVC];
    if (!self.singleAppMode) {
        [self hostApp:prefs[@"rightBundleID"] inContainer:self.rightContainer replacingExisting:&_rightAppVC];
    }
    [self layoutContainers];
    [self revealIfHosted];

    self.speedBubble.hidden = ![prefs[@"showSpeedBubble"] boolValue];
    self.speedBubble.style = (SplitCarPlayBubbleStyle)[prefs[@"bubbleStyle"] integerValue];
    self.speedBubble.showDate = [prefs[@"showDate"] boolValue];
    self.speedBubble.showBattery = [prefs[@"showBattery"] boolValue];
    self.speedBubble.showNowPlaying = [prefs[@"showNowPlaying"] boolValue];
    self.speedBubble.scale = prefs[@"bubbleScale"] ? [prefs[@"bubbleScale"] doubleValue] : 1.0;

    // Resize to fit whichever style is active (a Card needs more vertical
    // room than a compact Ring or a wide-short Bar), and re-apply the
    // left/right side pref every reload -- that's a deliberate placement
    // choice from Settings, not something a one-off drag should silently
    // override. Vertical position (y) is left alone so dragging the
    // bubble up/down still sticks.
    //
    // Uses bounds+center rather than .frame: the bubble now carries a
    // pinch-driven scale transform (see SpeedBubbleView.scale above), and
    // per Apple's docs, -frame (both reading AND writing it) is undefined
    // once a view's transform isn't the identity transform.
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

#pragma mark Window / display setup — VERIFIED path

- (void)activateOnDisplay:(CADisplay *)carPlayDisplay {
    SplitCarPlayHostingLog(@"activateOnDisplay: begin, carPlayDisplay=%@", carPlayDisplay);
    @try {
    FBSDisplayConfiguration *config =
        [[objc_getClass("FBSDisplayConfiguration") alloc] initWithCADisplay:carPlayDisplay
                                                                isMainDisplay:NO];
    SplitCarPlayHostingLog(@"  FBSDisplayConfiguration = %@", config);
    self.rootWindow = [[objc_getClass("UIRootSceneWindow") alloc] initWithDisplayConfiguration:config];
    SplitCarPlayHostingLog(@"  rootWindow = %@ bounds=%@", self.rootWindow, NSStringFromCGRect(self.rootWindow.bounds));
    self.rootWindow.backgroundColor = [UIColor blackColor];

    CGRect bounds = self.rootWindow.bounds;

    self.leftContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.leftContainer.clipsToBounds = YES;
    self.rightContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.rightContainer.clipsToBounds = YES;

    self.dividerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.dividerView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.35];
    self.dividerView.layer.cornerRadius = 3;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                           action:@selector(handleDividerPan:)];
    [self.dividerView addGestureRecognizer:pan];
    self.dividerView.userInteractionEnabled = YES;

    CGFloat cardWidth = 116, cardHeight = 266;
    self.speedBubble = [[SpeedBubbleView alloc] initWithFrame:CGRectMake(bounds.size.width - cardWidth - 16,
                                                                           16, cardWidth, cardHeight)];
    self.speedBubble.onScaleChanged = ^(CGFloat scale) {
        SplitCarPlayWritePref(@"bubbleScale", @(scale));
    };

    [self.rootWindow addSubview:self.leftContainer];
    [self.rootWindow addSubview:self.rightContainer];
    [self.rootWindow addSubview:self.dividerView];
    [self.rootWindow addSubview:self.speedBubble]; // on top, so it floats over both halves

    // Always-available way out on the car screen itself: a ✕ button, plus
    // a two-finger long press anywhere. Both just tear the window down,
    // which gives the normal CarPlay UI back.
    self.carCloseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.carCloseButton setTitle:@"✕" forState:UIControlStateNormal];
    self.carCloseButton.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    self.carCloseButton.tintColor = [UIColor whiteColor];
    self.carCloseButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    self.carCloseButton.layer.cornerRadius = 22;
    self.carCloseButton.frame = CGRectMake(12, 12, 44, 44);
    [self.carCloseButton addTarget:self action:@selector(closeFromCar) forControlEvents:UIControlEventTouchUpInside];
    [self.rootWindow addSubview:self.carCloseButton]; // topmost

    UILongPressGestureRecognizer *escape = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleEscapeGesture:)];
    escape.numberOfTouchesRequired = 2;
    escape.minimumPressDuration = 1.0;
    escape.cancelsTouchesInView = NO;
    [self.rootWindow addGestureRecognizer:escape];

    // VietmapLiveHook.xm only notifies us when it has a fresh value — if it
    // goes quiet (Vietmap Live closed, heuristic stops matching) nothing
    // will tell us that, so poll periodically to flip the card to
    // "disconnected" once the last value goes stale.
    [self.speedBubbleStaleTimer invalidate];
    self.speedBubbleStaleTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                                    target:self
                                                                  selector:@selector(refreshSpeedBubble)
                                                                  userInfo:nil
                                                                   repeats:YES];

    // Stay HIDDEN until an app view is actually attached (revealIfHosted).
    // Showing an opaque empty window first is exactly what blanked the
    // CarPlay screen last time. Also no makeKeyAndVisible: in SpringBoard
    // that would steal key-window status from the phone's own UI.
    self.rootWindow.hidden = YES;
    SplitCarPlayHostingLog(@"  activateOnDisplay: done, window built (hidden until an app is hosted)");

    (void)bounds;
    } @catch (NSException *exception) {
        SplitCarPlayHostingLog(@"  EXCEPTION in activateOnDisplay:: %@ -- %@\n%@", exception.name, exception.reason, exception.callStackSymbols);
        [self teardown]; // never leave a half-built window behind
    }
}

// Shows the window only if at least one hosted view has a real size.
- (BOOL)revealIfHosted {
    if (!self.rootWindow) return NO;
    BOOL hosted = NO;
    for (UIView *container in @[self.leftContainer, self.rightContainer]) {
        if (container.hidden) continue;
        for (UIView *sub in container.subviews) {
            if (sub.bounds.size.width > 1 && sub.bounds.size.height > 1) hosted = YES;
        }
    }
    if (hosted && self.rootWindow.hidden) {
        self.rootWindow.hidden = NO;
        SplitCarPlayHostingLog(@"  revealIfHosted: app view attached -- window shown");
    }
    return hosted;
}

// If nothing got hosted shortly after the window was built, give the
// CarPlay screen back instead of leaving an invisible-but-present window.
- (void)startWatchdog {
    NSUInteger generation = self.sessionGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.sessionGeneration || !self.rootWindow) return; // already torn down
        if (![self revealIfHosted]) {
            SplitCarPlayHostingLog(@"WATCHDOG: no app view hosted after 6s -- tearing down");
            [self teardown];
        }
    });
}

- (void)closeFromCar {
    SplitCarPlayHostingLog(@"closed from the car screen (✕ / two-finger long press)");
    [self teardown];
}

- (void)handleEscapeGesture:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) [self closeFromCar];
}

- (void)teardown {
    self.sessionGeneration++;
    self.hostingSessionActive = NO;
    [self.rootWindow removeFromSuperview];
    self.rootWindow.hidden = YES;
    self.rootWindow = nil;
    self.leftAppVC = nil;
    self.rightAppVC = nil;
    self.speedBubble = nil;
    self.closeOverlayButton = nil;
    self.carCloseButton = nil;
    [self.speedBubbleStaleTimer invalidate];
    self.speedBubbleStaleTimer = nil;
}

#pragma mark Live preview overlay (Preferences.app only) — EXPERIMENTAL

// Triggered from the Settings "Mô phỏng" screen's new "thử chạy app thật"
// button. Unlike activateOnDisplay: above (which targets the CarPlay
// external display via FBSDisplayConfiguration/UIRootSceneWindow), this
// targets a plain window on the phone's own main screen -- an ordinary,
// unprivate way any tweak adds a floating overlay (no different from a
// "floating button" tweak). The only private-API part reused here is the
// *existing* hostApp:inContainer: below; displaySceneManagerForCurrentDisplay
// already calls +[SBSceneManagerCoordinator mainDisplaySceneManager] (not
// anything CarPlay-specific), which should resolve to the phone's own
// display when called from here instead of from CarPlayApp -- the premise
// this whole experiment rests on, prompted by evidence that SidePlay's own
// "Mô phỏng" tab hosts real, live app content without a CarPlay connection.
- (void)showLivePreviewOverlayWithLeft:(NSString *)leftBundleID right:(NSString *)rightBundleID {
    // DISABLED -- same hostApp:/displaySceneManagerForCurrentDisplay
    // mechanism that just failed its first real-CarPlay test (see
    // reloadFromPreferences above); no reason to believe this Settings-
    // triggered variant of the identical call would fare any better.
    // Left in place rather than deleted in case the broader pivot (see
    // ROADMAP.md) ends up reusing pieces of it.
    return;

    if (self.rootWindow) return; // already showing

    NSDictionary *prefs = [self loadPreferences];
    self.splitRatio = [prefs[@"splitRatio"] doubleValue] ?: 0.5;

    self.rootWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.rootWindow.windowLevel = UIWindowLevelAlert + 1;
    self.rootWindow.backgroundColor = [UIColor blackColor];

    CGRect bounds = self.rootWindow.bounds;
    self.leftContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.leftContainer.clipsToBounds = YES;
    self.rightContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.rightContainer.clipsToBounds = YES;

    self.dividerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.dividerView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.35];
    self.dividerView.layer.cornerRadius = 3;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                           action:@selector(handleDividerPan:)];
    [self.dividerView addGestureRecognizer:pan];
    self.dividerView.userInteractionEnabled = YES;

    CGFloat cardWidth = 116, cardHeight = 266;
    self.speedBubble = [[SpeedBubbleView alloc] initWithFrame:CGRectMake(bounds.size.width - cardWidth - 16,
                                                                           56, cardWidth, cardHeight)];
    self.speedBubble.scale = prefs[@"bubbleScale"] ? [prefs[@"bubbleScale"] doubleValue] : 1.0;
    self.speedBubble.onScaleChanged = ^(CGFloat scale) {
        SplitCarPlayWritePref(@"bubbleScale", @(scale));
    };

    self.closeOverlayButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeOverlayButton setTitle:@"✕ Đóng thử nghiệm" forState:UIControlStateNormal];
    self.closeOverlayButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    self.closeOverlayButton.tintColor = [UIColor whiteColor];
    self.closeOverlayButton.layer.cornerRadius = 8;
    self.closeOverlayButton.frame = CGRectMake(12, 44, 170, 36);
    [self.closeOverlayButton addTarget:self action:@selector(hideLivePreviewOverlay)
                       forControlEvents:UIControlEventTouchUpInside];

    [self.rootWindow addSubview:self.leftContainer];
    [self.rootWindow addSubview:self.rightContainer];
    [self.rootWindow addSubview:self.dividerView];
    [self.rootWindow addSubview:self.speedBubble]; // on top, so it floats over both halves
    [self.rootWindow addSubview:self.closeOverlayButton]; // topmost -- always reachable to get out

    [self hostApp:leftBundleID inContainer:self.leftContainer replacingExisting:&_leftAppVC];
    [self hostApp:rightBundleID inContainer:self.rightContainer replacingExisting:&_rightAppVC];
    [self layoutContainers];

    self.rootWindow.hidden = NO;
    [self.rootWindow makeKeyAndVisible];
}

- (void)hideLivePreviewOverlay {
    [self teardown];
}

#pragma mark Speed bubble (data comes from VietmapLiveHook.xm, same dylib)

- (void)refreshSpeedBubble {
    if (!self.speedBubble || self.speedBubble.hidden) return;
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kVietmapSharedStatePath];
    [self.speedBubble applyState:state ?: @{}]; // empty state renders as "disconnected"
    [self.speedBubble tick]; // date/battery/now-playing text — see SpeedBubbleView.tick's own comment

    BOOL overLimit = [state[@"isOverLimit"] boolValue];
    if (self.speedAudioAlertEnabled && overLimit) {
        NSTimeInterval sinceLastAlert = self.lastSpeedAudioAlertAt ? -[self.lastSpeedAudioAlertAt timeIntervalSinceNow] : INFINITY;
        if (sinceLastAlert > 8.0) {
            AudioServicesPlaySystemSound(1057); // "Tink" — a real, standard SystemSoundID; just an alert tone, nothing fancy
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

- (void)layoutContainers {
    if (!self.rootWindow || !self.leftContainer || !self.rightContainer) return;
    CGRect bounds = self.rootWindow.bounds;
    if (self.singleAppMode) {
        self.leftContainer.frame = bounds;
    } else {
        CGFloat dividerWidth = 6;
        CGFloat leftWidth = floor(bounds.size.width * self.splitRatio - dividerWidth / 2.0);
        CGFloat rightWidth = bounds.size.width - leftWidth - dividerWidth;

        self.leftContainer.frame = CGRectMake(0, 0, leftWidth, bounds.size.height);
        self.dividerView.frame = CGRectMake(leftWidth, 0, dividerWidth, bounds.size.height);
        self.rightContainer.frame = CGRectMake(leftWidth + dividerWidth, 0, rightWidth, bounds.size.height);
    }

    // Hosted app views are laid out full-size inside their own container and
    // CLIPPED by clipsToBounds — this is simpler and more robust than
    // scaling (CGAffineTransformMakeScale) the way the single-app original
    // does for orientation changes. If you'd rather scale the *entire* app
    // UI down to fit (so nothing is cropped), apply a scale transform to
    // appVC.view here instead, matching the original's
    // resizeAppViewForOrientation:fullscreen:forceUpdate: pattern.
    //
    // Resize whatever hostApp: actually added (appView, not appVC.view).
    for (UIView *container in @[self.leftContainer, self.rightContainer]) {
        for (UIView *sub in container.subviews) sub.frame = container.bounds;
    }
}

- (void)handleDividerPan:(UIPanGestureRecognizer *)pan {
    CGPoint location = [pan locationInView:self.rootWindow];
    CGFloat newRatio = location.x / self.rootWindow.bounds.size.width;
    newRatio = MAX(0.2, MIN(0.8, newRatio));
    self.splitRatio = newRatio;
    [self layoutContainers];
}

#pragma mark App hosting — now grounded in real selector strings pulled
#pragma mark from SidePlay2.dylib; see the class forward-declarations
#pragma mark above for exactly what's VERIFIED vs still ADAPT.

// `slot` takes the address of a strong ivar (e.g. &_leftAppVC). Declaring it
// explicitly `__strong` (rather than the implicit `__autoreleasing` ARC
// gives bare `Type **` parameters) avoids ARC's by-reference write-back
// requirement, which rejects taking the address of an ivar directly.
- (void)hostApp:(NSString *)bundleID inContainer:(UIView *)container replacingExisting:(UIViewController * __strong *)slot {
    if (bundleID.length == 0) return;
    // NOTE: a real implementation should check whether *slot is already
    // hosting this exact bundleID (and bail out early) before re-creating
    // the scene below — omitted here for brevity.

    SplitCarPlayHostingLog(@"hostApp: begin for %@", bundleID);

    // Wraps the whole ADAPT chain below: if any guessed selector's real
    // argument/return shape is wrong, calling it on an object that
    // doesn't actually respond would normally raise an uncaught
    // NSException and crash/respawn CarPlayApp -- which, with no visible
    // crash UI on a car's screen, could look identical to "just blank"
    // to whoever's driving. Catching it here guarantees a log entry
    // explaining what actually happened, and a plain failed hostApp:
    // call instead of a process respawn.
    @try {
        Class appControllerClass = objc_getClass("SBApplicationController");
        Class entityClass = objc_getClass("SBDeviceApplicationSceneEntity");
        Class appViewControllerClass = objc_getClass("SBAppViewController");
        SplitCarPlayHostingLog(@"  classes resolved: controller=%@ entity=%@ appVC=%@",
                                appControllerClass, entityClass, appViewControllerClass);
        if (!appControllerClass || !entityClass || !appViewControllerClass) {
            SplitCarPlayHostingLog(@"  ABORT: missing a required private class — adjust names for this iOS version");
            return;
        }

        id appController = [appControllerClass respondsToSelector:@selector(sharedInstance)] ? [appControllerClass sharedInstance] : nil;
        SplitCarPlayHostingLog(@"  SBApplicationController sharedInstance = %@", appController);
        if (!appController) {
            SplitCarPlayHostingLog(@"  ABORT: SBApplicationController has no +sharedInstance on this iOS version");
            return;
        }

        id application = [appController respondsToSelector:@selector(applicationWithBundleIdentifier:)]
            ? [appController applicationWithBundleIdentifier:bundleID] : nil;
        SplitCarPlayHostingLog(@"  applicationWithBundleIdentifier:%@ = %@", bundleID, application);
        if (!application) {
            SplitCarPlayHostingLog(@"  ABORT: could not resolve application object for %@", bundleID);
            return;
        }

        id displaySceneManager = [self displaySceneManagerForCurrentDisplay];
        SplitCarPlayHostingLog(@"  displaySceneManagerForCurrentDisplay = %@", displaySceneManager);
        if (!displaySceneManager) {
            SplitCarPlayHostingLog(@"  ABORT: no scene manager for this display (SBSceneManagerCoordinator missing or mainDisplaySceneManager unavailable)");
            return;
        }

        if (![displaySceneManager respondsToSelector:@selector(_sceneIdentityForApplication:createPrimaryIfRequired:)]) {
            SplitCarPlayHostingLog(@"  ABORT: displaySceneManager does not respond to _sceneIdentityForApplication:createPrimaryIfRequired: (class is %@)", [displaySceneManager class]);
            return;
        }
        id sceneIdentity = [displaySceneManager _sceneIdentityForApplication:application
                                                          createPrimaryIfRequired:YES];
        SplitCarPlayHostingLog(@"  sceneIdentity = %@", sceneIdentity);

        // Still ADAPT: SBApplicationSceneHandleRequest's real construction API
        // (see forward-declaration comment above). Try the known candidate
        // shapes in order; on failure, dump the class's real method list to
        // the log so the next build can use the right one.
        Class requestClass = objc_getClass("SBApplicationSceneHandleRequest");
        if (!requestClass) {
            SplitCarPlayHostingLog(@"  ABORT: SBApplicationSceneHandleRequest class not found");
            return;
        }
        id request = nil;
        SEL twoArg = @selector(requestForApplication:sceneIdentity:);
        SEL threeArg = NSSelectorFromString(@"defaultRequestForApplication:sceneIdentity:displayIdentity:");
        if ([requestClass respondsToSelector:twoArg]) {
            request = [requestClass requestForApplication:application sceneIdentity:sceneIdentity];
            SplitCarPlayHostingLog(@"  request via requestForApplication:sceneIdentity: = %@", request);
        } else if ([requestClass respondsToSelector:threeArg]) {
            id displayIdentity = [displaySceneManager respondsToSelector:NSSelectorFromString(@"displayIdentity")]
                ? [displaySceneManager valueForKey:@"displayIdentity"] : nil;
            request = ((id (*)(id, SEL, id, id, id))objc_msgSend)(requestClass, threeArg, application, sceneIdentity, displayIdentity);
            SplitCarPlayHostingLog(@"  request via defaultRequestForApplication:sceneIdentity:displayIdentity: (displayIdentity=%@) = %@", displayIdentity, request);
        }
        if (!request) {
            SplitCarPlayHostingLog(@"  ABORT: no known constructor on SBApplicationSceneHandleRequest. Its methods on this iOS version:\n%@",
                                    SplitCarPlayDescribeMethods(requestClass));
            return;
        }

        if (![displaySceneManager respondsToSelector:@selector(fetchOrCreateApplicationSceneHandleForRequest:)]) {
            SplitCarPlayHostingLog(@"  ABORT: displaySceneManager does not respond to fetchOrCreateApplicationSceneHandleForRequest:");
            return;
        }
        id sceneHandle = [displaySceneManager fetchOrCreateApplicationSceneHandleForRequest:request];
        SplitCarPlayHostingLog(@"  sceneHandle = %@", sceneHandle);
        if (!sceneHandle) {
            SplitCarPlayHostingLog(@"  ABORT: failed to fetch/create scene handle for %@", bundleID);
            return;
        }

        id sceneEntity = [[entityClass alloc] initWithApplicationSceneHandle:sceneHandle];
        SplitCarPlayHostingLog(@"  sceneEntity = %@", sceneEntity);
        if (![appViewControllerClass instancesRespondToSelector:@selector(initWithIdentifier:andApplicationSceneEntity:)]) {
            SplitCarPlayHostingLog(@"  ABORT: SBAppViewController has no initWithIdentifier:andApplicationSceneEntity:. Its methods:\n%@",
                                    SplitCarPlayDescribeMethods(appViewControllerClass));
            return;
        }
        SBAppViewController *appVC = [[appViewControllerClass alloc] initWithIdentifier:bundleID
                                                               andApplicationSceneEntity:sceneEntity];
        SplitCarPlayHostingLog(@"  appVC = %@", appVC);
        if (!appVC) {
            SplitCarPlayHostingLog(@"  ABORT: SBAppViewController init returned nil");
            return;
        }

        // Prefer the real content view (appView) over the inherited
        // UIViewController.view -- see the VERIFIED note on the forward
        // declaration above. Falls back to .view if appView isn't actually
        // there on this iOS version.
        BOOL hasAppView = [appVC respondsToSelector:@selector(appView)];
        UIView *contentView = hasAppView ? appVC.appView : appVC.view;
        SplitCarPlayHostingLog(@"  hasAppView=%d contentView=%@ bounds=%@", hasAppView, contentView, NSStringFromCGRect(contentView.bounds));

        // Clear out whatever was hosted here before (that was appView, not
        // the old appVC.view, so remove the container's subviews directly).
        for (UIView *old in [container.subviews copy]) [old removeFromSuperview];
        *slot = appVC;
        contentView.frame = container.bounds;
        [container addSubview:contentView];

        // Both ADAPT (selector names are real, but which object answers them
        // and exactly what's needed to make a hosted scene actually render/
        // receive touches isn't independently confirmed) -- guarded so a wrong
        // guess just skips the call instead of crashing.
        BOOL hasSetForeground = [appVC respondsToSelector:@selector(setForeground:)];
        if (hasSetForeground) [appVC setForeground:YES];
        BOOL hasUpdateReferenceSize = [appVC respondsToSelector:@selector(_updateReferenceSize:andOrientation:)];
        if (hasUpdateReferenceSize) [appVC _updateReferenceSize:container.bounds.size andOrientation:0];
        SplitCarPlayHostingLog(@"  hostApp: done for %@ (setForeground=%d updateReferenceSize=%d)", bundleID, hasSetForeground, hasUpdateReferenceSize);
    } @catch (NSException *exception) {
        SplitCarPlayHostingLog(@"  EXCEPTION for %@: %@ -- %@\n%@", bundleID, exception.name, exception.reason, exception.callStackSymbols);
    }
}

- (id)displaySceneManagerForCurrentDisplay {
    // VERIFIED class/selector ("+SBSceneManagerCoordinator
    // mainDisplaySceneManager" is a real string in SidePlay2.dylib) -- see
    // the forward-declaration comment above for the one remaining
    // uncertainty (whether "main" scopes correctly to the CarPlay display
    // from inside this process).
    Class coordinatorClass = objc_getClass("SBSceneManagerCoordinator");
    SplitCarPlayHostingLog(@"  displaySceneManagerForCurrentDisplay: coordinatorClass=%@", coordinatorClass);
    if (![coordinatorClass respondsToSelector:@selector(mainDisplaySceneManager)]) {
        SplitCarPlayHostingLog(@"  displaySceneManagerForCurrentDisplay: ABORT -- doesn't respond to +mainDisplaySceneManager");
        return nil;
    }
    id manager = [coordinatorClass mainDisplaySceneManager];
    SplitCarPlayHostingLog(@"  displaySceneManagerForCurrentDisplay: mainDisplaySceneManager = %@ (class %@)", manager, [manager class]);
    return manager;
}

@end

#pragma mark - Entry point

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

        if ([bundleID isEqualToString:@"com.apple.Preferences"]) {
            // EXPERIMENTAL: lets the Settings "Mô phỏng" screen trigger a
            // real hostApp: attempt in a plain overlay on the phone's own
            // screen instead of requiring an actual CarPlay connection --
            // see showLivePreviewOverlayWithLeft:right:'s header comment.
            SplitCarPlayLoadMediaRemote();

            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL,
                (CFNotificationCallback)[](CFNotificationCenterRef center, void *observer, CFStringRef name,
                                            const void *object, CFDictionaryRef userInfo) {
                    NSDictionary *prefs = [[SplitCarPlayController sharedInstance] loadPreferences];
                    [[SplitCarPlayController sharedInstance] showLivePreviewOverlayWithLeft:prefs[@"leftBundleID"]
                                                                                        right:prefs[@"rightBundleID"]];
                },
                (__bridge CFStringRef)@"com.example.splitcarplay/show-live-preview",
                NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);

            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL,
                (CFNotificationCallback)[](CFNotificationCenterRef center, void *observer, CFStringRef name,
                                            const void *object, CFDictionaryRef userInfo) {
                    [[SplitCarPlayController sharedInstance] hideLivePreviewOverlay];
                },
                (__bridge CFStringRef)@"com.example.splitcarplay/hide-live-preview",
                NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);

            // Safety net: don't leave the overlay stuck on top of Settings
            // if the user leaves the app some other way than the close
            // button (e.g. the home indicator / app switcher).
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                                object:nil
                                                                 queue:nil
                                                            usingBlock:^(NSNotification *note) {
                [[SplitCarPlayController sharedInstance] hideLivePreviewOverlay];
            }];
            return;
        }

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

        // In case CarPlay is already connected when we're injected.
        // Deferred, not called inline: %ctor runs before UIApplicationMain,
        // and creating windows / touching SpringBoard classes that early
        // can crash on every respawn (-> safe mode).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[SplitCarPlayController sharedInstance] reloadFromPreferences];
        });
    }
}
