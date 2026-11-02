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

// ADAPT — resolver for "give me an app object for this bundle id" varies by
// iOS version / process. Candidates seen in SpringBoard-family private API:
// SBApplicationController, LSApplicationWorkspace+LSApplicationProxy.
@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (id)applicationWithBundleIdentifier:(NSString *)bundleID;
@end

// ADAPT — the scene manager singleton/accessor that owns scene identities for
// a given display. carplay-cast calls it "displaySceneManager"; the exact
// accessor (ivar vs singleton vs per-window-scene delegate) needs confirming.
@interface SBDisplaySceneManager : NSObject
- (id)_sceneIdentityForApplication:(id)application createPrimaryIfRequired:(BOOL)create;
- (id)fetchOrCreateApplicationSceneHandleForRequest:(id)request;
@end

// ADAPT — the request object's real initializer/properties aren't public;
// this is a plausible shape based on common SB*Request conventions.
@interface SBApplicationSceneHandleRequest : NSObject
+ (instancetype)requestForApplication:(id)application sceneIdentity:(id)identity;
@end

// VERIFIED names (per carplay-cast + independently per DashSplit's README)
@interface SBDeviceApplicationSceneEntity : NSObject
- (instancetype)initWithApplicationSceneHandle:(id)handle;
@end

@interface SBAppViewController : UIViewController
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
//  we're "connected") comes ONLY from whatever the companion tweak
//  VietmapLiveExport last wrote to a shared file after reading it off
//  Vietmap Live's own UI — this view does not talk to GPS/CoreLocation.
//  "Connected" just means "a fresh value arrived within the last
//  kVietmapStaleAfter seconds", i.e. Vietmap Live is running and the
//  heuristic in VietmapLiveExport is currently matching something — it is
//  not a real handshake/protocol with Vietmap Live (no such thing exists
//  publicly; see VietmapLiveExport/README.md).
//
static NSString * const kVietmapSharedStatePath = @"/var/mobile/Library/Caches/com.example.splitcarplay/vietmap_speed.plist";
static NSString * const kVietmapUpdateDarwinNotification = @"com.example.splitcarplay/vietmap-update";
static const NSTimeInterval kVietmapStaleAfter = 6.0; // consider "disconnected" if no fresh update

@interface SpeedBubbleView : UIView
- (void)applyState:(NSDictionary *)state; // state may be nil (= never heard from VietmapLiveExport)
@end

@implementation SpeedBubbleView {
    UIPanGestureRecognizer *_pan;
    UIView *_speedBox;
    UILabel *_speedLabel;
    UILabel *_unitLabel;
    UIImageView *_statusIconView;
    UILabel *_statusLabel;
    UIView *_statusBar;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.96];
        self.layer.cornerRadius = 14;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.08].CGColor;

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
        _statusLabel.text = @"Chưa có dữ liệu\nVietmap Live";
        _statusLabel.textColor = [UIColor colorWithWhite:0.35 alpha:1];
        [self addSubview:_statusLabel];

        _statusBar = [[UIView alloc] init];
        _statusBar.backgroundColor = [UIColor colorWithWhite:0.8 alpha:1];
        [self addSubview:_statusBar];

        _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:_pan];
        self.userInteractionEnabled = YES;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat pad = 8;

    _speedBox.frame = CGRectMake(pad, pad, w - pad * 2, 52);
    _speedLabel.frame = CGRectMake(0, 4, _speedBox.bounds.size.width, 30);
    _unitLabel.frame = CGRectMake(0, 34, _speedBox.bounds.size.width, 14);

    CGFloat iconSize = 22;
    _statusIconView.frame = CGRectMake((w - iconSize) / 2.0, CGRectGetMaxY(_speedBox.frame) + 8, iconSize, iconSize);

    _statusLabel.frame = CGRectMake(pad, CGRectGetMaxY(_statusIconView.frame) + 4, w - pad * 2, 28);

    CGFloat barHeight = 4;
    _statusBar.frame = CGRectMake(pad, self.bounds.size.height - barHeight - 6, w - pad * 2, barHeight);
    _statusBar.layer.cornerRadius = barHeight / 2.0;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.superview];
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

    _speedLabel.text = connected ? text : @"--";
    _speedBox.layer.borderColor = (connected && overLimit)
        ? [UIColor systemRedColor].CGColor
        : [UIColor colorWithWhite:0.75 alpha:1].CGColor;

    if (@available(iOS 13.0, *)) {
        _statusIconView.image = [UIImage systemImageNamed:connected ? @"checkmark.circle.fill" : @"xmark.circle"];
    }
    _statusIconView.tintColor = connected ? [UIColor systemGreenColor] : [UIColor systemGrayColor];

    _statusLabel.text = connected ? @"Đã kết nối\nVietmap Live" : @"Chưa có dữ liệu\nVietmap Live";
    _statusBar.backgroundColor = connected
        ? (overLimit ? [UIColor systemRedColor] : [UIColor systemGreenColor])
        : [UIColor colorWithWhite:0.8 alpha:1];
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
@property (nonatomic, strong) NSTimer *speedBubbleStaleTimer;
@property (nonatomic, assign) CGFloat splitRatio; // 0..1, left width fraction
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
        @"leftBundleID": @"com.apple.Maps",
        @"rightBundleID": @"com.apple.Music",
        @"splitRatio": @0.5,
        @"showDivider": @YES,
        @"showSpeedBubble": @YES,
    } mutableCopy];
    if (prefs) [merged addEntriesFromDictionary:prefs];
    return merged;
}

- (void)reloadFromPreferences {
    NSDictionary *prefs = [self loadPreferences];
    self.splitRatio = [prefs[@"splitRatio"] doubleValue];
    self.dividerView.hidden = ![prefs[@"showDivider"] boolValue];

    if (![prefs[@"enabled"] boolValue]) {
        [self teardown];
        return;
    }

    id carPlayDisplay = getCarPlayDisplay();
    if (!carPlayDisplay) return; // not connected to a car yet

    if (!self.rootWindow) {
        [self activateOnDisplay:carPlayDisplay];
    }

    [self hostApp:prefs[@"leftBundleID"] inContainer:self.leftContainer replacingExisting:&_leftAppVC];
    [self hostApp:prefs[@"rightBundleID"] inContainer:self.rightContainer replacingExisting:&_rightAppVC];
    [self layoutContainers];

    self.speedBubble.hidden = ![prefs[@"showSpeedBubble"] boolValue];
    if (!self.speedBubble.hidden) [self refreshSpeedBubble];
}

#pragma mark Window / display setup — VERIFIED path

- (void)activateOnDisplay:(CADisplay *)carPlayDisplay {
    FBSDisplayConfiguration *config =
        [[objc_getClass("FBSDisplayConfiguration") alloc] initWithCADisplay:carPlayDisplay
                                                                isMainDisplay:NO];
    self.rootWindow = [[objc_getClass("UIRootSceneWindow") alloc] initWithDisplayConfiguration:config];
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

    CGFloat cardWidth = 116, cardHeight = 150;
    self.speedBubble = [[SpeedBubbleView alloc] initWithFrame:CGRectMake(bounds.size.width - cardWidth - 16,
                                                                           16, cardWidth, cardHeight)];

    [self.rootWindow addSubview:self.leftContainer];
    [self.rootWindow addSubview:self.rightContainer];
    [self.rootWindow addSubview:self.dividerView];
    [self.rootWindow addSubview:self.speedBubble]; // on top, so it floats over both halves

    // VietmapLiveExport only notifies us when it has a fresh value — if it
    // goes quiet (Vietmap Live closed, heuristic stops matching) nothing
    // will tell us that, so poll periodically to flip the card to
    // "disconnected" once the last value goes stale.
    [self.speedBubbleStaleTimer invalidate];
    self.speedBubbleStaleTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                                    target:self
                                                                  selector:@selector(refreshSpeedBubble)
                                                                  userInfo:nil
                                                                   repeats:YES];

    self.rootWindow.hidden = NO;
    [self.rootWindow makeKeyAndVisible];

    (void)bounds;
}

- (void)teardown {
    [self.rootWindow removeFromSuperview];
    self.rootWindow.hidden = YES;
    self.rootWindow = nil;
    self.leftAppVC = nil;
    self.rightAppVC = nil;
    self.speedBubble = nil;
    [self.speedBubbleStaleTimer invalidate];
    self.speedBubbleStaleTimer = nil;
}

#pragma mark Speed bubble (data comes from the VietmapLiveExport companion tweak)

- (void)refreshSpeedBubble {
    if (!self.speedBubble || self.speedBubble.hidden) return;
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kVietmapSharedStatePath];
    [self.speedBubble applyState:state ?: @{}]; // empty state renders as "disconnected"
}

- (void)layoutContainers {
    CGRect bounds = self.rootWindow.bounds;
    CGFloat dividerWidth = 6;
    CGFloat leftWidth = floor(bounds.size.width * self.splitRatio - dividerWidth / 2.0);
    CGFloat rightWidth = bounds.size.width - leftWidth - dividerWidth;

    self.leftContainer.frame = CGRectMake(0, 0, leftWidth, bounds.size.height);
    self.dividerView.frame = CGRectMake(leftWidth, 0, dividerWidth, bounds.size.height);
    self.rightContainer.frame = CGRectMake(leftWidth + dividerWidth, 0, rightWidth, bounds.size.height);

    // Hosted app views are laid out full-size inside their own container and
    // CLIPPED by clipsToBounds — this is simpler and more robust than
    // scaling (CGAffineTransformMakeScale) the way the single-app original
    // does for orientation changes. If you'd rather scale the *entire* app
    // UI down to fit (so nothing is cropped), apply a scale transform to
    // appVC.view here instead, matching the original's
    // resizeAppViewForOrientation:fullscreen:forceUpdate: pattern.
    self.leftAppVC.view.frame = self.leftContainer.bounds;
    self.rightAppVC.view.frame = self.rightContainer.bounds;
}

- (void)handleDividerPan:(UIPanGestureRecognizer *)pan {
    CGPoint location = [pan locationInView:self.rootWindow];
    CGFloat newRatio = location.x / self.rootWindow.bounds.size.width;
    newRatio = MAX(0.2, MIN(0.8, newRatio));
    self.splitRatio = newRatio;
    [self layoutContainers];
}

#pragma mark App hosting — ADAPT path (see header comment)

// `slot` takes the address of a strong ivar (e.g. &_leftAppVC). Declaring it
// explicitly `__strong` (rather than the implicit `__autoreleasing` ARC
// gives bare `Type **` parameters) avoids ARC's by-reference write-back
// requirement, which rejects taking the address of an ivar directly.
- (void)hostApp:(NSString *)bundleID inContainer:(UIView *)container replacingExisting:(UIViewController * __strong *)slot {
    if (bundleID.length == 0) return;
    // NOTE: a real implementation should check whether *slot is already
    // hosting this exact bundleID (and bail out early) before re-creating
    // the scene below — omitted here for brevity.

    Class appControllerClass = objc_getClass("SBApplicationController");
    Class entityClass = objc_getClass("SBDeviceApplicationSceneEntity");
    Class appViewControllerClass = objc_getClass("SBAppViewController");
    if (!appControllerClass || !entityClass || !appViewControllerClass) {
        NSLog(@"[SplitCarPlay] missing a required private class — adjust names for this iOS version");
        return;
    }

    id application = [[appControllerClass sharedInstance] applicationWithBundleIdentifier:bundleID];
    if (!application) {
        NSLog(@"[SplitCarPlay] could not resolve application object for %@", bundleID);
        return;
    }

    // NOTE: how `displaySceneManager` is actually obtained for OUR
    // UIRootSceneWindow's display is the biggest ADAPT gap here — carplay-
    // cast has it as an ivar set up during its own window construction.
    // Likely candidates: a property on UIWindowScene's delegate, or a
    // display-keyed singleton. Confirm on-device.
    id displaySceneManager = [self displaySceneManagerForCurrentDisplay];
    if (!displaySceneManager) {
        NSLog(@"[SplitCarPlay] no scene manager for this display yet");
        return;
    }

    id sceneIdentity = [displaySceneManager _sceneIdentityForApplication:application
                                                      createPrimaryIfRequired:YES];
    id request = [objc_getClass("SBApplicationSceneHandleRequest") requestForApplication:application
                                                                             sceneIdentity:sceneIdentity];
    id sceneHandle = [displaySceneManager fetchOrCreateApplicationSceneHandleForRequest:request];
    if (!sceneHandle) {
        NSLog(@"[SplitCarPlay] failed to fetch/create scene handle for %@", bundleID);
        return;
    }

    id sceneEntity = [[entityClass alloc] initWithApplicationSceneHandle:sceneHandle];
    UIViewController *appVC = [[appViewControllerClass alloc] initWithIdentifier:bundleID
                                                           andApplicationSceneEntity:sceneEntity];
    if (!appVC) return;

    [(*slot).view removeFromSuperview];
    *slot = appVC;
    appVC.view.frame = container.bounds;
    [container addSubview:appVC.view];
}

- (id)displaySceneManagerForCurrentDisplay {
    // ADAPT: placeholder. Replace with the real accessor for your iOS
    // version once found via class-dump, e.g. something hanging off
    // self.rootWindow.windowScene, or a shared SBDisplaySceneManager.
    return nil;
}

@end

#pragma mark - Entry point

%ctor {
    @autoreleasepool {
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

        // Posted by the companion tweak VietmapLiveExport whenever it
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
        [[SplitCarPlayController sharedInstance] reloadFromPreferences];
    }
}
