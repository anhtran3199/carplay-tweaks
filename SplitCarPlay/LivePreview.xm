//
//  LivePreview.xm  (SpringBoard only)
//
//  "Chạy thật" on the app's "Mô phỏng" tab: runs the picked apps for real,
//  side by side, on the PHONE screen, inside the preview's two panes.
//
//  How: the app writes the panes' screen rects to prefs and posts
//  SCP_LIVE_START_NOTIFICATION. Here, in SpringBoard, we
//    1. launch each app suspended (FBSSystemService),
//    2. wrap its main-display scene in an SBAppViewController
//       (SBDeviceApplicationSceneEntity initWithApplicationForMainDisplay:),
//    3. put that view controller's view in a window that sits exactly over
//       the pane, and
//    4. keep the app's scene foreground and sized to the pane.
//  This is the carplay-cast approach, pointed at the phone screen instead
//  of CarPlay, so it can be tested without a car. The same code is meant
//  to replace the CarPlay hosting in Tweak.xm once it works.
//
//  The speed bubble is drawn here too, on top of the hosted apps: the
//  app's own bubble lives in the app's window, which this window covers.
//
//  Every private selector is called through objc_msgSend after a
//  respondsToSelector: check, every step is logged to
//  /var/mobile/Library/Logs/splitcarplay_hosting.log (prefix "[live]").
//  @try only catches Objective-C exceptions, not FrontBoard assertions
//  (abort), so the code also avoids the known way to hit one: talking to
//  the scene of an app that iOS has already killed (two apps at once on
//  2 GB of RAM). If SpringBoard still dies mid-session, the next
//  SpringBoard start sees the session marker, turns "2 app" off and tells
//  the app (livePreviewCrashNotice).
//
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "SplitCarPlayShared.h"
#import "SCPHosting.h"

#pragma mark - Logging

void SCPHostAppendLog(NSString *line) {
    static dispatch_queue_t queue;
    static NSFileHandle *handle;
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.example.splitcarplay.log", DISPATCH_QUEUE_SERIAL);
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"HH:mm:ss";
    });
    NSDate *now = [NSDate date];
    dispatch_async(queue, ^{
        NSString *path = @"/var/mobile/Library/Logs/splitcarplay_hosting.log";
        if (!handle) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            }
            handle = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        @try {
            unsigned long long size = [handle seekToEndOfFile];
            if (size > 512 * 1024) {
                // Keep the newest half.
                [handle closeFile];
                NSData *data = [NSData dataWithContentsOfFile:path];
                NSData *tail = data.length > 256 * 1024 ? [data subdataWithRange:NSMakeRange(data.length - 256 * 1024, 256 * 1024)] : data;
                [tail writeToFile:path atomically:YES];
                handle = [NSFileHandle fileHandleForWritingAtPath:path];
                [handle seekToEndOfFile];
            }
            NSString *stamped = [NSString stringWithFormat:@"[%@] %@\n", [formatter stringFromDate:now], line];
            [handle writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (NSException *exception) {
            handle = nil; // reopen next time (file deleted from the app, etc.)
        }
    });
}

static void SCPLiveLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[SplitCarPlay/live] %@", message);
    SCPHostAppendLog([@"[live] " stringByAppendingString:message]);
}

// Class (+) and instance (-) method names, for the log when a guessed
// selector is missing on this iOS version.
static NSString *SCPLiveMethods(Class cls) {
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

#pragma mark - objc_msgSend helpers (no private headers needed)

static BOOL SCPResponds(id target, NSString *selName) {
    return target && [target respondsToSelector:NSSelectorFromString(selName)];
}

static id SCPSendId(id target, NSString *selName) {
    if (!SCPResponds(target, selName)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(selName));
}

static id SCPSendIdId(id target, NSString *selName, id arg) {
    if (!SCPResponds(target, selName)) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(target, NSSelectorFromString(selName), arg);
}

static BOOL SCPSendBool(id target, NSString *selName, BOOL value) {
    if (!SCPResponds(target, selName)) return NO;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(target, NSSelectorFromString(selName), value);
    return YES;
}

static BOOL SCPSendInteger(id target, NSString *selName, NSInteger value) {
    if (!SCPResponds(target, selName)) return NO;
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(target, NSSelectorFromString(selName), value);
    return YES;
}

static BOOL SCPSendRect(id target, NSString *selName, CGRect value) {
    if (!SCPResponds(target, selName)) return NO;
    ((void (*)(id, SEL, CGRect))objc_msgSend)(target, NSSelectorFromString(selName), value);
    return YES;
}

static BOOL SCPGetBool(id target, NSString *selName, BOOL fallback) {
    if (!SCPResponds(target, selName)) return fallback;
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(selName));
}

#pragma mark - Speed bubble (same class as the CarPlay one, Tweak.xm)

// Implemented in Tweak.xm (same dylib). Looked up with objc_getClass so
// this file doesn't need its symbol at link time.
@interface SpeedBubbleView : UIView
@property (nonatomic, assign) NSInteger style; // SplitCarPlayBubbleStyle: 0 card, 1 ring, 2 bar
@property (nonatomic, assign) BOOL showDate;
@property (nonatomic, assign) BOOL showBattery;
@property (nonatomic, assign) BOOL showNowPlaying;
@property (nonatomic, assign) CGFloat scale;
@property (nonatomic, copy) void (^onScaleChanged)(CGFloat scale);
- (void)applyState:(NSDictionary *)state;
@end

static NSString * const kSCPLiveVietmapStatePath = @"/var/mobile/Library/Caches/com.example.splitcarplay/vietmap_speed.plist";

// Natural (unscaled) size of SpeedBubbleView per style, as in Tweak.xm.
static CGSize SCPLiveBubbleNaturalSize(NSInteger style) {
    switch (style) {
        case 1: return CGSizeMake(100, 100);
        case 2: return CGSizeMake(220, 44);
        default: return CGSizeMake(116, 266);
    }
}

#pragma mark - Never free what SpringBoard may still be using

// Freeing an SBAppViewController aborts SpringBoard (0.7.4 crash report:
// SIGABRT from an Objective-C exception, right after "freeing view
// controller"; it likely holds something that has to be invalidated
// through SpringBoard's own code first). So every view controller and
// window made here is kept for the life of SpringBoard, and a stopped
// app's view controller is reused the next time that app is shown.
static NSMutableArray *SCPLiveKeptObjects(void) {
    static NSMutableArray *kept;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ kept = [NSMutableArray new]; });
    return kept;
}

static NSMutableDictionary<NSString *, UIViewController *> *SCPLiveReusableControllers(void) {
    static NSMutableDictionary *controllers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controllers = [NSMutableDictionary new]; });
    return controllers;
}

static void SCPLiveKeepForever(id object) {
    if (object && ![SCPLiveKeptObjects() containsObject:object]) [SCPLiveKeptObjects() addObject:object];
}

NSUInteger SCPHostKeptObjectCount(void) {
    return SCPLiveKeptObjects().count;
}

// Every drop of a dead app leaves one more view controller alive for good.
// After 3 for the same app, stop making new ones for it until SpringBoard
// restarts, so memory can't keep growing on a phone that keeps killing it.
static NSMutableDictionary<NSString *, NSNumber *> *SCPLiveDropCounts(void) {
    static NSMutableDictionary *counts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ counts = [NSMutableDictionary new]; });
    return counts;
}

static void SCPLiveNoteDrop(NSString *bundleID) {
    if (bundleID.length == 0) return;
    SCPLiveDropCounts()[bundleID] = @([SCPLiveDropCounts()[bundleID] integerValue] + 1);
}

static BOOL SCPLiveDroppedTooOften(NSString *bundleID) {
    return bundleID.length > 0 && [SCPLiveDropCounts()[bundleID] integerValue] >= 3;
}

// Removes our own views (bubble, buttons, labels, empty containers) from a
// window we stop using, leaving only the containers that hold an app's view
// (those views must stay attached to something; their controllers are kept).
void SCPHostStripOwnViews(UIView *root) {
    NSMutableSet<UIView *> *appViews = [NSMutableSet new];
    for (id object in SCPLiveKeptObjects()) {
        if ([object isKindOfClass:[UIViewController class]] && [object isViewLoaded]) [appViews addObject:[object view]];
    }
    for (UIView *child in [root.subviews copy]) {
        BOOL holdsApp = [appViews containsObject:child];
        for (UIView *grandchild in child.subviews) holdsApp = holdsApp || [appViews containsObject:grandchild];
        if (!holdsApp) {
            [child removeFromSuperview];
            continue;
        }
        for (UIView *grandchild in [child.subviews copy]) {
            if (![appViews containsObject:grandchild]) [grandchild removeFromSuperview];
        }
    }
}

#pragma mark - Window that only takes touches on its panes

@interface SCPLivePassthroughWindow : UIWindow
@end

@implementation SCPLivePassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // Empty areas fall through to the app underneath (the preview screen).
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

#pragma mark - One hosted app

@interface SCPLiveSlot : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, strong) UIView *container;
@property (nonatomic, strong) UIView *loadingView;
@property (nonatomic, strong) id application;       // SBApplication
@property (nonatomic, strong) UIViewController *appViewController; // SBAppViewController
@property (nonatomic, strong) id sceneHandle;
@property (nonatomic, strong) id scene;             // FBScene
@property (nonatomic, assign) BOOL isRight;         // which pane: follows that pane on divider drags
@property (nonatomic, assign) BOOL hosted;
@property (nonatomic, assign) BOOL finished;        // gave up on this slot (failed or app died)
@property (nonatomic, assign) NSInteger reassertCount;
@property (nonatomic, assign) NSInteger reassertStreak; // consecutive ticks found background
@property (nonatomic, assign) NSInteger deadStrikes;    // consecutive ticks it looked dead
@end

@implementation SCPLiveSlot
@end

#pragma mark - Controller

@interface SCPLivePreviewController : NSObject
+ (instancetype)sharedInstance;
- (void)start;
- (void)stopWithState:(uint64_t)state reason:(NSString *)reason;
- (void)applyResizeFromApp;
// Shared with the CarPlay window through SCPHosting.h.
- (void)launchSuspended:(NSString *)bundleID completion:(void (^)(NSError *))completion;
- (UIViewController *)makeAppViewControllerForSlot:(SCPLiveSlot *)slot application:(id)application;
- (BOOL)slotLooksAlive:(SCPLiveSlot *)slot;
@end

@implementation SCPLivePreviewController {
    SCPLivePassthroughWindow *_window;
    NSMutableArray<SCPLiveSlot *> *_slots;
    NSTimer *_keepAliveTimer;
    SpeedBubbleView *_bubble;
    NSTimer *_bubbleTimer;
    UIButton *_closeButton;
    UIImageView *_edgeChevron;  // on the bubble show/hide handle
    BOOL _tearingDown;          // stop is letting the apps go, step by step
    BOOL _pendingStart;         // START arrived during teardown; run it after

    NSUInteger _generation; // bumps on every start/stop; stale callbacks compare against it
}

+ (instancetype)sharedInstance {
    static SCPLivePreviewController *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [SCPLivePreviewController new]; });
    return instance;
}

- (void)start {
    if (SCPHostIsCarPlaySessionActive()) {
        // The apps are on the car screen; their views can't be in two places.
        SCPLiveLog(@"start: ignored, a CarPlay session is running");
        SCPSetLiveState(SCPLiveStateIdle);
        return;
    }
    if (_tearingDown) {
        SCPLiveLog(@"start: previous session still closing, starting after it");
        _pendingStart = YES;
        return;
    }
    if (_window) {
        // Close the running session gently first; start again when done.
        _pendingStart = YES;
        [self stopWithState:SCPLiveStateIdle reason:@"restart"];
        return;
    }
    NSUInteger generation = ++_generation;

    @try {
        NSDictionary *prefs = SCPCopyPrefs();
        BOOL both = [prefs[@"livePreviewBoth"] boolValue];
        NSString *leftID = prefs[@"leftBundleID"];
        NSString *rightID = prefs[@"rightBundleID"];
        CGRect leftFrame = CGRectFromString(prefs[@"livePreviewLeftFrame"] ?: @"");
        CGRect rightFrame = CGRectFromString(prefs[@"livePreviewRightFrame"] ?: @"");
        SCPLiveLog(@"[mem] live-start %@ kept=%lu", SCPMemLine(), (unsigned long)SCPLiveKeptObjects().count);
        SCPLiveLog(@"start: left=%@ %@ right=%@ %@ both=%d", leftID, NSStringFromCGRect(leftFrame),
                    rightID, NSStringFromCGRect(rightFrame), both);

        if (both && leftID.length && [leftID isEqualToString:rightID]) {
            // Two view controllers on one app's single scene: never do that.
            SCPLiveLog(@"start: both panes are %@, hosting it once", leftID);
            both = NO;
        }

        NSMutableArray<NSDictionary *> *wanted = [NSMutableArray new];
        if (leftID.length && leftFrame.size.width > 20 && leftFrame.size.height > 20) {
            [wanted addObject:@{@"id": leftID, @"frame": [NSValue valueWithCGRect:leftFrame], @"right": @NO}];
        }
        if (both && rightID.length && rightFrame.size.width > 20 && rightFrame.size.height > 20) {
            [wanted addObject:@{@"id": rightID, @"frame": [NSValue valueWithCGRect:rightFrame], @"right": @YES}];
        }
        if (wanted.count == 0) {
            SCPLiveLog(@"start: ABORT nothing to host (no app picked or bad frames)");
            SCPSetLiveState(SCPLiveStateFailed);
            return;
        }
        SCPSetLiveState(SCPLiveStateStarting);

        // Crash marker: cleared in stop. If SpringBoard dies before that,
        // the next SpringBoard start finds it (see %ctor).
        SCPSetPref(@"livePreviewSessionActive", @YES);
        SCPSetPref(@"livePreviewSessionBoth", @(wanted.count > 1));

        [self createWindow];
        if (!_window) {
            [self stopWithState:SCPLiveStateFailed reason:@"no window"];
            return;
        }

        _slots = [NSMutableArray new];
        CGRect unionFrame = CGRectNull;
        for (NSDictionary *item in wanted) {
            CGRect frame = [item[@"frame"] CGRectValue];
            unionFrame = CGRectUnion(unionFrame, frame);
            SCPLiveSlot *slot = [SCPLiveSlot new];
            slot.bundleID = item[@"id"];
            slot.isRight = [item[@"right"] boolValue];
            slot.container = [[UIView alloc] initWithFrame:frame];
            slot.container.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
            slot.container.layer.cornerRadius = 10;
            slot.container.clipsToBounds = YES;
            [_window.rootViewController.view addSubview:slot.container];
            slot.loadingView = [self makeLoadingViewForBundleID:slot.bundleID size:frame.size];
            [slot.container addSubview:slot.loadingView];
            [_slots addObject:slot];
        }
        [self addSpeedBubbleWithPrefs:prefs];  // above the panes
        [self addEdgeHandleWithPrefs:prefs];   // the app's own handle is covered too
        [self addCloseButtonNear:unionFrame];  // above everything

        // Launch one after another; the second launch waits for the first
        // to settle (two cold launches at once is a lot for 2 GB of RAM).
        [self hostSlotAtIndex:0 generation:generation];

        // Watchdog: if nothing is hosted after 12 s, give up cleanly.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != self->_generation) return;
            BOOL anyHosted = NO;
            for (SCPLiveSlot *slot in self->_slots) anyHosted = anyHosted || slot.hosted;
            if (!anyHosted) [self stopWithState:SCPLiveStateFailed reason:@"watchdog: nothing hosted after 12 s"];
        });
    } @catch (NSException *exception) {
        SCPLiveLog(@"start: EXCEPTION %@ -- %@\n%@", exception.name, exception.reason, exception.callStackSymbols);
        [self stopWithState:SCPLiveStateFailed reason:@"exception in start"];
    }
}

- (void)createWindow {
    UIScreen *mainScreen = [UIScreen mainScreen];
    UIWindowScene *windowScene = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && ((UIWindowScene *)scene).screen == mainScreen) {
            windowScene = (UIWindowScene *)scene;
            break;
        }
    }
    SCPLiveLog(@"createWindow: windowScene=%@", windowScene);
    _window = windowScene ? [[SCPLivePassthroughWindow alloc] initWithWindowScene:windowScene]
                          : [[SCPLivePassthroughWindow alloc] initWithFrame:mainScreen.bounds];
    _window.frame = mainScreen.bounds;
    _window.windowLevel = UIWindowLevelStatusBar + 1;
    _window.backgroundColor = [UIColor clearColor];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = [UIColor clearColor];
    _window.rootViewController = root;
    _window.hidden = NO; // not key: keyboard and focus stay with the app underneath
    SCPLiveLog(@"createWindow: window=%@ level=%.0f", _window, _window.windowLevel);
}

- (UIView *)makeLoadingViewForBundleID:(NSString *)bundleID size:(CGSize)size {
    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size.width, size.height)];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.color = [UIColor whiteColor];
    spinner.center = CGPointMake(size.width / 2.0, size.height / 2.0 - 10);
    [spinner startAnimating];
    [view addSubview:spinner];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8, size.height / 2.0 + 10, size.width - 16, 16)];
    label.text = @"Đang mở…";
    label.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    label.font = [UIFont systemFontOfSize:12];
    label.textAlignment = NSTextAlignmentCenter;
    [view addSubview:label];
    return view;
}

// Replaces whatever is in the pane with a short message (app died, etc.).
- (void)showMessage:(NSString *)message inSlot:(SCPLiveSlot *)slot {
    [slot.loadingView removeFromSuperview];
    CGSize size = slot.container.bounds.size;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, size.width - 24, size.height)];
    label.text = message;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    label.font = [UIFont systemFontOfSize:13];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [slot.container addSubview:label];
    slot.loadingView = label;
}

- (void)addCloseButtonNear:(CGRect)unionFrame {
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    CGFloat size = 30;
    closeButton.frame = CGRectMake(CGRectGetMaxX(unionFrame) - size - 6, CGRectGetMinY(unionFrame) + 6, size, size);
    _closeButton = closeButton;
    closeButton.backgroundColor = [UIColor colorWithRed:1.0 green:0.30 blue:0.27 alpha:0.95];
    closeButton.layer.cornerRadius = size / 2.0;
    closeButton.layer.borderWidth = 1.5;
    closeButton.layer.borderColor = [UIColor whiteColor].CGColor;
    [closeButton setTitle:@"✕" forState:UIControlStateNormal];
    [closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    closeButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [_window.rootViewController.view addSubview:closeButton];
}

- (void)closeTapped {
    [self stopWithState:SCPLiveStateIdle reason:@"✕ tapped"];
}

#pragma mark Sizing

// The size the app is told it has: phone width, pane aspect ratio. The
// app lays out like on a phone and the result is scaled down to fit the
// pane, so the whole app is visible instead of its top-left corner.
static CGSize SCPLiveVirtualSize(CGSize pane) {
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat phoneWidth = MIN(screen.size.width, screen.size.height);
    CGFloat width = MAX(pane.width, phoneWidth);
    CGFloat height = pane.width > 0 ? pane.height * width / pane.width : screen.size.height;
    return CGSizeMake(width, height);
}

- (void)layoutContentOfSlot:(SCPLiveSlot *)slot {
    UIView *content = slot.appViewController.view;
    if (!content) return;
    CGSize pane = slot.container.bounds.size;
    CGSize virtualSize = SCPLiveVirtualSize(pane);
    CGFloat scale = virtualSize.width > 0 ? pane.width / virtualSize.width : 1.0;
    content.autoresizingMask = UIViewAutoresizingNone;
    content.transform = CGAffineTransformIdentity;
    content.bounds = CGRectMake(0, 0, virtualSize.width, virtualSize.height);
    content.center = CGPointMake(pane.width / 2.0, pane.height / 2.0);
    content.transform = CGAffineTransformMakeScale(scale, scale);
}

- (void)positionCloseButton {
    CGRect unionFrame = CGRectNull;
    for (SCPLiveSlot *slot in _slots) unionFrame = CGRectUnion(unionFrame, slot.container.frame);
    if (CGRectIsNull(unionFrame) || !_closeButton) return;
    CGFloat size = _closeButton.bounds.size.width;
    _closeButton.frame = CGRectMake(CGRectGetMaxX(unionFrame) - size - 6, CGRectGetMinY(unionFrame) + 6, size, size);
}

// The divider in the app was dragged (SCP_LIVE_RESIZE_NOTIFICATION).
// During the drag only the scaled views follow (cheap); when it ends the
// apps' scenes get the new size too, so they re-layout for it.
- (void)applyResizeFromApp {
    double leftWidth = 0, rightX = 0, rightWidth = 0;
    BOOL final = NO;
    if (!_window || !SCPReadLiveResize(&leftWidth, &rightX, &rightWidth, &final)) return;
    @try {
        for (SCPLiveSlot *slot in _slots) {
            CGRect frame = slot.container.frame;
            if (slot.isRight) {
                frame.origin.x = rightX;
                frame.size.width = rightWidth;
            } else {
                frame.size.width = leftWidth;
            }
            if (frame.size.width < 20) continue;
            slot.container.frame = frame;
            [self layoutContentOfSlot:slot];
            if (final && slot.hosted && slot.scene && [self slotLooksAlive:slot]) {
                [self applyForeground:YES toSlot:slot];
            }
        }
        [self positionCloseButton];
        if (final) SCPLiveLog(@"resize: left w=%.1f right x=%.1f w=%.1f", leftWidth, rightX, rightWidth);
    } @catch (NSException *exception) {
        SCPLiveLog(@"resize EXCEPTION %@ -- %@", exception.name, exception.reason);
    }
}

#pragma mark Speed bubble

// Same place and size as the app's own bubble (the app sends its screen
// center and scaled width). Draggable and pinchable; the final position
// goes back to the app in stop.
- (void)addSpeedBubbleWithPrefs:(NSDictionary *)prefs {
    if (prefs[@"livePreviewBubble"] && ![prefs[@"livePreviewBubble"] boolValue]) return;
    Class bubbleClass = objc_getClass("SpeedBubbleView");
    if (!bubbleClass) {
        SCPLiveLog(@"bubble: SpeedBubbleView class not found");
        return;
    }
    @try {
        NSInteger style = [prefs[@"bubbleStyle"] integerValue];
        CGSize natural = SCPLiveBubbleNaturalSize(style);
        SpeedBubbleView *bubble = [[bubbleClass alloc] initWithFrame:CGRectMake(0, 0, natural.width, natural.height)];
        bubble.style = style;
        bubble.showDate = prefs[@"showDate"] ? [prefs[@"showDate"] boolValue] : YES;
        bubble.showBattery = prefs[@"showBattery"] ? [prefs[@"showBattery"] boolValue] : YES;
        bubble.showNowPlaying = NO;

        CGFloat width = [prefs[@"livePreviewBubbleWidth"] doubleValue];
        bubble.scale = width > 0 ? width / natural.width : 1.0;

        CGRect screen = [UIScreen mainScreen].bounds;
        NSString *centerString = prefs[@"livePreviewBubbleCenter"];
        CGPoint center = centerString.length ? CGPointFromString(centerString)
                                             : CGPointMake(CGRectGetMaxX(screen) - natural.width / 2.0 - 16, 140);
        center.x = MAX(24, MIN(screen.size.width - 24, center.x));
        center.y = MAX(24, MIN(screen.size.height - 24, center.y));
        bubble.center = center;
        bubble.hidden = [prefs[@"livePreviewBubbleHidden"] boolValue]; // hidden with the edge handle in the app

        CGFloat appBaseWidth = [prefs[@"livePreviewBubbleBaseWidth"] doubleValue];
        bubble.onScaleChanged = ^(CGFloat scale) {
            // Back to the app bubble's own scale units.
            if (appBaseWidth > 0) SCPSetPref(@"bubbleScale", @(scale * natural.width / appBaseWidth));
        };

        if ([UIDevice currentDevice].batteryMonitoringEnabled == NO) {
            [UIDevice currentDevice].batteryMonitoringEnabled = YES;
        }
        [_window.rootViewController.view addSubview:bubble];
        _bubble = bubble;
        [self refreshBubble];
        __weak __typeof__(self) weakSelf = self;
        _bubbleTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) { [timer invalidate]; return; }
            [strongSelf refreshBubble];
        }];
        SCPLiveLog(@"bubble: style=%ld center=%@ scale=%.2f", (long)style, NSStringFromCGPoint(center), bubble.scale);
    } @catch (NSException *exception) {
        SCPLiveLog(@"bubble EXCEPTION %@ -- %@", exception.name, exception.reason);
        [_bubble removeFromSuperview];
        _bubble = nil;
    }
}

// Copy of the app's left-edge half-capsule (shows/hides the bubble), at the
// same screen spot: the app's one is under the hosted apps now.
- (void)addEdgeHandleWithPrefs:(NSDictionary *)prefs {
    if (!_bubble) return;
    CGRect frame = CGRectFromString(prefs[@"livePreviewEdgeFrame"] ?: @"");
    if (frame.size.width < 4 || frame.size.height < 4) return;
    UIButton *handle = [UIButton buttonWithType:UIButtonTypeCustom];
    handle.frame = frame;
    handle.accessibilityLabel = @"Ẩn/hiện thẻ tốc độ";
    [handle addTarget:self action:@selector(edgeHandleTapped) forControlEvents:UIControlEventTouchUpInside];

    CGFloat visualW = MAX(10, frame.size.width - 10); // the app adds 10 pt of extra touch area
    UIView *visual = [[UIView alloc] initWithFrame:CGRectMake(0, 0, visualW, frame.size.height)];
    visual.userInteractionEnabled = NO;
    visual.backgroundColor = [UIColor whiteColor];
    visual.layer.cornerRadius = 8;
    visual.layer.maskedCorners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    visual.layer.borderWidth = 1.0 / MAX(1.0, [UIScreen mainScreen].scale);
    visual.layer.borderColor = [UIColor colorWithWhite:0.80 alpha:1].CGColor;
    visual.layer.shadowColor = [UIColor blackColor].CGColor;
    visual.layer.shadowOpacity = 0.12;
    visual.layer.shadowRadius = 3;
    visual.layer.shadowOffset = CGSizeMake(1, 1);
    [handle addSubview:visual];

    _edgeChevron = [[UIImageView alloc] initWithFrame:CGRectMake(floor((visualW - 9) / 2.0), floor((frame.size.height - 12) / 2.0), 9, 12)];
    _edgeChevron.contentMode = UIViewContentModeScaleAspectFit;
    _edgeChevron.tintColor = [UIColor colorWithWhite:0.35 alpha:1];
    [visual addSubview:_edgeChevron];
    [self updateEdgeChevron];
    [_window.rootViewController.view addSubview:handle];
}

- (void)updateEdgeChevron {
    NSString *name = _bubble.hidden ? @"chevron.right" : @"chevron.left";
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightSemibold];
    _edgeChevron.image = [[UIImage systemImageNamed:name withConfiguration:config] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (void)edgeHandleTapped {
    _bubble.hidden = !_bubble.hidden;
    [self updateEdgeChevron];
}

- (void)refreshBubble {
    if (!_bubble || _bubble.hidden) return;
    // Newer of the shared file and the notify state, as in Tweak.xm.
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kSCPLiveVietmapStatePath];
    NSDictionary *notifyState = SCPReadSpeedState();
    if ([notifyState[@"timestamp"] doubleValue] > [state[@"timestamp"] doubleValue]) state = notifyState;
    @try {
        [_bubble applyState:state ?: @{}];
    } @catch (NSException *exception) {
        SCPLiveLog(@"bubble refresh EXCEPTION %@ -- %@", exception.name, exception.reason);
    }
}

#pragma mark Hosting

- (void)hostSlotAtIndex:(NSUInteger)index generation:(NSUInteger)generation {
    if (generation != _generation || index >= _slots.count) return;
    SCPLiveSlot *slot = _slots[index];

    // Before starting the second app, make sure the first one survived.
    // If iOS killed it already, RAM is too tight for two.
    if (index > 0) {
        SCPLiveSlot *previous = _slots[index - 1];
        if (previous.hosted && ![self slotLooksAlive:previous]) {
            SCPLiveLog(@"host[%lu] %@: skipped, %@ is no longer running (low memory?)",
                        (unsigned long)index, slot.bundleID, previous.bundleID);
            slot.finished = YES;
            [self showMessage:@"Không mở app thứ 2: app thứ nhất vừa bị iOS đóng (thiếu RAM)." inSlot:slot];
            return;
        }
    }

    SCPLiveLog(@"host[%lu] %@: launching suspended", (unsigned long)index, slot.bundleID);
    __weak __typeof__(self) weakSelf = self;
    void (^afterLaunch)(NSError *) = ^(NSError *error) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf->_generation) return;
            if (error) {
                // Don't wrap a scene for an app that didn't start.
                slot.finished = YES;
                [strongSelf showMessage:@"Không khởi động được app này." inSlot:slot];
                [strongSelf stopIfNothingLeft];
            } else {
                [strongSelf attachSlot:slot];
            }
            if (index + 1 < strongSelf->_slots.count) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [weakSelf hostSlotAtIndex:index + 1 generation:generation];
                });
            }
        });
    };
    [self launchSuspended:slot.bundleID completion:afterLaunch];
}

// FBSSystemService openApplication:options:withResult: with the
// "__ActivateSuspended" option (FBSOpenApplicationOptionKeyActivateSuspended):
// starts the app process without bringing it to the front.
- (void)launchSuspended:(NSString *)bundleID completion:(void (^)(NSError *))completion {
    @try {
        Class serviceClass = objc_getClass("FBSSystemService");
        id service = SCPSendId(serviceClass, @"sharedService");
        NSDictionary *options = @{@"__ActivateSuspended": @YES, @"__UnlockDevice": @NO};
        void (^result)(NSError *) = ^(NSError *error) {
            SCPLiveLog(@"  launch %@ result: %@", bundleID, (id)error ?: @"ok");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
        };
        SEL three = NSSelectorFromString(@"openApplication:options:withResult:");
        SEL four = NSSelectorFromString(@"openApplication:options:clientPort:withResult:");
        if ([service respondsToSelector:three]) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(service, three, bundleID, options, result);
        } else if ([service respondsToSelector:four] && SCPResponds(service, @"createClientPort")) {
            unsigned int port = ((unsigned int (*)(id, SEL))objc_msgSend)(service, NSSelectorFromString(@"createClientPort"));
            ((void (*)(id, SEL, id, id, unsigned int, id))objc_msgSend)(service, four, bundleID, options, port, result);
        } else {
            SCPLiveLog(@"  launch: FBSSystemService=%@ service=%@ has no openApplication. Methods:\n%@",
                        serviceClass, service, SCPLiveMethods(serviceClass));
            completion(nil); // try to host anyway; works if the app is already running
        }
    } @catch (NSException *exception) {
        SCPLiveLog(@"  launch EXCEPTION %@ -- %@", exception.name, exception.reason);
        completion(nil);
    }
}

- (void)attachSlot:(SCPLiveSlot *)slot {
    @try {
        NSString *bundleID = slot.bundleID;
        id appController = SCPSendId(objc_getClass("SBApplicationController"), @"sharedInstance");
        id application = SCPSendIdId(appController, @"applicationWithBundleIdentifier:", bundleID);
        SCPLiveLog(@"  attach %@: application=%@", bundleID, application);
        if (!application) {
            slot.finished = YES;
            [self showMessage:@"Không tìm thấy app này." inSlot:slot];
            return;
        }
        slot.application = application;

        Class appVCClass = objc_getClass("SBAppViewController");
        UIViewController *appVC = SCPLiveReusableControllers()[bundleID];
        if (appVC) {
            SCPLiveLog(@"  attach %@: reusing %@", bundleID, appVC);
        } else {
            if (SCPLiveDroppedTooOften(bundleID)) {
                SCPLiveLog(@"  attach %@: refused, dropped 3 times since SpringBoard started", bundleID);
                slot.finished = YES;
                [self showMessage:@"App này bị iOS đóng nhiều lần. Respring để thử lại." inSlot:slot];
                return;
            }
            appVC = [self makeAppViewControllerForSlot:slot application:application];
            if (!appVC) {
                slot.finished = YES;
                return;
            }
            SCPLiveKeepForever(appVC);
            SCPLiveReusableControllers()[bundleID] = appVC;
        }

        SCPLiveLog(@"  attach %@: setting live mode", bundleID);
        BOOL occl = SCPSendBool(appVC, @"setIgnoresOcclusions:", YES);
        BOOL mode = SCPSendInteger(appVC, @"setRequestedMode:", 2); // 2 = live content (carplay-cast)
        SCPLiveLog(@"  attach %@: setIgnoresOcclusions=%d setRequestedMode=%d", bundleID, occl, mode);

        UIView *content = appVC.view;
        content.hidden = NO;
        [slot.container insertSubview:content belowSubview:slot.loadingView]; // moves it out of an old session's window
        slot.appViewController = appVC;
        [self layoutContentOfSlot:slot]; // phone-sized, scaled down to the pane

        id sceneHandle = SCPSendId(appVC, @"sceneHandle");
        id scene = SCPSendId(sceneHandle, @"sceneIfExists") ?: SCPSendId(sceneHandle, @"scene");
        slot.sceneHandle = sceneHandle;
        slot.scene = scene;
        SCPLiveLog(@"  attach %@: sceneHandle=%@ scene=%@", bundleID, sceneHandle, scene);
        if (!scene) {
            SCPLiveLog(@"  attach: no scene yet. SBAppViewController methods:\n%@", SCPLiveMethods(appVCClass));
        }
        [self applyForeground:YES toSlot:slot];

        slot.hosted = YES;
        SCPSetLiveState(SCPLiveStateRunning);
        [self startKeepAlive];

        // Drop the "Đang mở…" overlay once the hosted view has had time to
        // draw; log the hierarchy so a blank result is diagnosable.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!slot.hosted) return;
            [UIView animateWithDuration:0.2 animations:^{ slot.loadingView.alpha = 0; }];
            SCPLiveLog(@"  attach %@: after 1.5 s content bounds=%@ scale=%.2f subviews=%@ sceneForeground=%d",
                        bundleID, NSStringFromCGRect(content.bounds), content.transform.a, content.subviews,
                        SCPGetBool(SCPSendId(slot.scene, @"settings"), @"isForeground", NO));
        });
    } @catch (NSException *exception) {
        SCPLiveLog(@"  attach %@ EXCEPTION %@ -- %@\n%@", slot.bundleID, exception.name, exception.reason, exception.callStackSymbols);
        slot.finished = YES;
    }
}

// New SBAppViewController for the app's main-display scene; nil on failure.
- (UIViewController *)makeAppViewControllerForSlot:(SCPLiveSlot *)slot application:(id)application {
    NSString *bundleID = slot.bundleID;
    {
        Class entityClass = objc_getClass("SBDeviceApplicationSceneEntity");
        SCPLiveLog(@"  attach %@: creating scene entity", bundleID);
        id entity = nil;
        if ([entityClass instancesRespondToSelector:NSSelectorFromString(@"initWithApplicationForMainDisplay:")]) {
            entity = ((id (*)(id, SEL, id))objc_msgSend)([entityClass alloc], NSSelectorFromString(@"initWithApplicationForMainDisplay:"), application);
        }
        SCPLiveLog(@"  attach %@: entity=%@", bundleID, entity);
        if (!entity) {
            SCPLiveLog(@"  attach: ABORT no initWithApplicationForMainDisplay:. SBDeviceApplicationSceneEntity methods:\n%@",
                        SCPLiveMethods(entityClass));
            return nil;
        }

        Class appVCClass = objc_getClass("SBAppViewController");
        SEL initSel = NSSelectorFromString(@"initWithIdentifier:andApplicationSceneEntity:");
        if (![appVCClass instancesRespondToSelector:initSel]) {
            SCPLiveLog(@"  attach: ABORT SBAppViewController has no %@. Methods:\n%@",
                        NSStringFromSelector(initSel), SCPLiveMethods(appVCClass));
            return nil;
        }
        // A fresh identifier every time. The view controller registers a
        // presenter on the app's scene under this name, and the previous
        // session's one may still be registered: reusing the name (it used
        // to be the bundle ID) crashed SpringBoard on the second start.
        static NSUInteger presenterCounter = 0;
        NSString *identifier = [NSString stringWithFormat:@"SplitCarPlayLive-%@-%lu", bundleID, (unsigned long)++presenterCounter];
        SCPLiveLog(@"  attach %@: creating SBAppViewController %@", bundleID, identifier);
        UIViewController *appVC = ((id (*)(id, SEL, id, id))objc_msgSend)([appVCClass alloc], initSel, identifier, entity);
        SCPLiveLog(@"  attach %@: appVC=%@", bundleID, appVC);
        if (!appVC) {
            return nil;
        }

        return appVC;
    }
}

// NO when iOS has killed the app or torn its scene down. Talking to a dead
// scene is what can trip a FrontBoard assertion and take SpringBoard (and
// the jailbreak, into safe mode) down with it.
- (BOOL)slotLooksAlive:(SCPLiveSlot *)slot {
    id application = slot.application;
    if (SCPResponds(application, @"isRunning") && !SCPGetBool(application, @"isRunning", YES)) return NO;
    id processState = SCPSendId(application, @"processState");
    if (SCPResponds(processState, @"isRunning") && !SCPGetBool(processState, @"isRunning", YES)) return NO;
    if (SCPResponds(slot.sceneHandle, @"sceneIfExists")) {
        id current = SCPSendId(slot.sceneHandle, @"sceneIfExists");
        if (slot.scene && current != slot.scene) return NO; // destroyed or replaced
    }
    if (SCPResponds(slot.scene, @"isValid") && !SCPGetBool(slot.scene, @"isValid", YES)) return NO;
    return YES;
}

// Tells the app's scene it's foreground (so it renders and takes touches)
// and gives it the pane's size (so it lays out for that width, like iPad
// split view). Restores the full-screen frame when going background.
- (void)applyForeground:(BOOL)foreground toSlot:(SCPLiveSlot *)slot {
    id scene = slot.scene;
    if (!scene) return;
    SEL updateSel = NSSelectorFromString(@"updateSettingsWithBlock:");
    if (![scene respondsToSelector:updateSel]) {
        SCPLiveLog(@"  applyForeground: scene %@ has no updateSettingsWithBlock:. Methods:\n%@", [scene class], SCPLiveMethods([scene class]));
        return;
    }
    CGSize size = foreground ? SCPLiveVirtualSize(slot.container.bounds.size) : [UIScreen mainScreen].bounds.size;
    void (^block)(id) = ^(id settings) {
        SCPSendBool(settings, @"setForeground:", foreground);
        SCPSendRect(settings, @"setFrame:", CGRectMake(0, 0, size.width, size.height));
    };
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(scene, updateSel, block);
    } @catch (NSException *exception) {
        SCPLiveLog(@"  applyForeground EXCEPTION %@ -- %@", exception.name, exception.reason);
    }
}

// Lets go of a slot whose app is gone, without touching its scene again.
- (void)dropSlot:(SCPLiveSlot *)slot message:(NSString *)message reason:(NSString *)reason {
    SCPLiveLog(@"  drop %@: %@", slot.bundleID, reason);
    SCPLiveLog(@"[mem] live-drop %@ kept=%lu", SCPMemLine(), (unsigned long)SCPLiveKeptObjects().count);
    SCPLiveNoteDrop(slot.bundleID);
    slot.hosted = NO;
    slot.finished = YES;
    [slot.appViewController view].hidden = YES;
    // Next time this app gets a fresh view controller; this one stays alive
    // (SCPLiveKeptObjects), because freeing it aborts SpringBoard.
    if (SCPLiveReusableControllers()[slot.bundleID] == slot.appViewController) {
        [SCPLiveReusableControllers() removeObjectForKey:slot.bundleID];
    }
    slot.appViewController = nil;
    slot.scene = nil;
    slot.sceneHandle = nil;
    [self showMessage:message inSlot:slot];
}

// Ends the session once no slot is running or still on its way.
- (void)stopIfNothingLeft {
    if (!_window || _slots.count == 0) return; // already stopped
    for (SCPLiveSlot *slot in _slots) {
        if (slot.hosted || !slot.finished) return;
    }
    [self stopWithState:SCPLiveStateFailed reason:@"no app left running"];
}

// SpringBoard will try to background the hosted apps (they aren't the
// frontmost app). Re-assert foreground when that happens, but only while
// the app is alive, and stop fighting if SpringBoard keeps refusing.
- (void)startKeepAlive {
    if (_keepAliveTimer) return;
    __weak __typeof__(self) weakSelf = self;
    _keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *timer) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { [timer invalidate]; return; }
        [strongSelf keepAliveTick];
    }];
}

- (void)keepAliveTick {
    @try {
        for (SCPLiveSlot *slot in [_slots copy]) {
            if (!slot.hosted) continue;
            if (!slot.scene) {
                slot.scene = SCPSendId(slot.sceneHandle, @"sceneIfExists");
                if (!slot.scene) continue;
                SCPLiveLog(@"  keepAlive %@: scene appeared %@", slot.bundleID, slot.scene);
            }
            if (![self slotLooksAlive:slot]) {
                // Two ticks in a row, so one odd reading doesn't drop a
                // working app. Nothing is sent to the scene meanwhile.
                slot.deadStrikes++;
                if (slot.deadStrikes >= 2) {
                    [self dropSlot:slot message:@"App đã bị iOS đóng (có thể do thiếu RAM). Thử chạy 1 app."
                            reason:@"app or scene gone (low memory?)"];
                }
                continue;
            }
            slot.deadStrikes = 0;
            BOOL isForeground = SCPGetBool(SCPSendId(slot.scene, @"settings"), @"isForeground", YES);
            if (isForeground) {
                slot.reassertStreak = 0;
                continue;
            }
            slot.reassertCount++;
            slot.reassertStreak++;
            if (slot.reassertStreak > 20) { // ~30 s of SpringBoard backgrounding it every time
                [self dropSlot:slot message:@"iOS không cho app này chạy trong khung."
                        reason:@"scene keeps going background"];
                continue;
            }
            if (slot.reassertCount <= 5 || slot.reassertCount % 20 == 0) {
                SCPLiveLog(@"  keepAlive %@: scene went background, re-asserting (#%ld)", slot.bundleID, (long)slot.reassertCount);
            }
            [self applyForeground:YES toSlot:slot];
        }
    } @catch (NSException *exception) {
        SCPLiveLog(@"  keepAlive EXCEPTION %@ -- %@", exception.name, exception.reason);
    }
    [self stopIfNothingLeft];
}

#pragma mark Teardown

// Closing used to let every app go at once: background the scene, drop
// the live mode and free the view controller in the same instant. With two
// apps that crashed SpringBoard (0.7.2, ✕ tapped). Now the window hides
// right away, then one app at a time: live mode off, wait, background the
// scene only if it's still foreground, wait, next app; the view
// controllers are freed a second after the last one. Every step is logged
// BEFORE it runs, so after a crash the log's last line names the step.
- (void)stopWithState:(uint64_t)state reason:(NSString *)reason {
    _generation++;
    if (_tearingDown) {
        SCPLiveLog(@"stop: already closing (%@)", reason);
        return;
    }
    if (!_window && _slots.count == 0) {
        SCPSetPref(@"livePreviewSessionActive", @NO);
        SCPSetLiveState(state);
        return;
    }
    SCPLiveLog(@"stop: %@", reason);
    _tearingDown = YES;
    [_keepAliveTimer invalidate];
    _keepAliveTimer = nil;
    [_bubbleTimer invalidate];
    _bubbleTimer = nil;
    if (_bubble) {
        // Hand the bubble's final spot and visibility back to the app.
        SCPSetPref(@"livePreviewBubbleCenter", NSStringFromCGPoint(_bubble.center));
        SCPSetPref(@"livePreviewBubbleHidden", @(_bubble.hidden));
        _bubble = nil;
    }
    _edgeChevron = nil;
    _closeButton = nil;

    NSArray<SCPLiveSlot *> *slots = [_slots copy] ?: @[];
    _slots = nil;
    UIWindow *window = _window;
    _window = nil;
    window.hidden = YES; // looks closed now; the views inside stay until each app is let go
    SCPSetLiveState(state); // the app's UI can move on; a new START waits for _tearingDown
    [self releaseSlots:slots index:0 window:window state:state];
}

- (void)releaseSlots:(NSArray<SCPLiveSlot *> *)slots index:(NSUInteger)index window:(UIWindow *)window state:(uint64_t)state {
    if (index >= slots.count) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // Nothing that SpringBoard may use is freed: the view
            // controllers stay (reused next time) and so does the hidden
            // window holding their views. Our own views are removed.
            SCPHostStripOwnViews(window.rootViewController.view);
            SCPLiveKeepForever(window);
            for (SCPLiveSlot *slot in slots) {
                slot.appViewController = nil; // still held by SCPLiveKeptObjects
                slot.scene = nil;
                slot.sceneHandle = nil;
            }
            self->_tearingDown = NO;
            SCPLiveLog(@"stop: done (kept %lu objects for reuse)", (unsigned long)SCPLiveKeptObjects().count);
            SCPLiveLog(@"[mem] live-stop %@", SCPMemLine());
            // Clear the crash marker a bit later, so a crash right after
            // closing (as in 0.7.4) is still noticed on the next start.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!self->_window && !self->_tearingDown) SCPSetPref(@"livePreviewSessionActive", @NO);
            });
            if (self->_pendingStart) {
                self->_pendingStart = NO;
                [self start];
            }
        });
        return;
    }

    SCPLiveSlot *slot = slots[index];
    BOOL alive = NO;
    @try {
        alive = slot.hosted && slot.appViewController && [self slotLooksAlive:slot];
        if (alive) {
            SCPLiveLog(@"  stop %@: setRequestedMode:0", slot.bundleID);
            SCPSendInteger(slot.appViewController, @"setRequestedMode:", 0);
            SCPLiveLog(@"  stop %@: setRequestedMode:0 done", slot.bundleID);
        } else {
            SCPLiveLog(@"  stop %@: not running, nothing to put back", slot.bundleID);
        }
    } @catch (NSException *exception) {
        SCPLiveLog(@"  stop %@ EXCEPTION %@ -- %@", slot.bundleID, exception.name, exception.reason);
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((alive ? 0.6 : 0.1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            if (alive && slot.scene && [self slotLooksAlive:slot]) {
                BOOL foreground = SCPGetBool(SCPSendId(slot.scene, @"settings"), @"isForeground", NO);
                if (foreground) {
                    SCPLiveLog(@"  stop %@: scene still foreground, backgrounding", slot.bundleID);
                    [self applyForeground:NO toSlot:slot];
                    SCPLiveLog(@"  stop %@: backgrounded", slot.bundleID);
                }
            }
        } @catch (NSException *exception) {
            SCPLiveLog(@"  stop %@ EXCEPTION %@ -- %@", slot.bundleID, exception.name, exception.reason);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((alive ? 0.6 : 0.0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self releaseSlots:slots index:index + 1 window:window state:state];
        });
    });
}

@end

#pragma mark - Hosting core for the CarPlay window (SCPHosting.h)

static BOOL gSCPCarPlaySessionActive = NO;

BOOL SCPHostSetCarPlaySessionActive(BOOL active) {
    gSCPCarPlaySessionActive = active;
    if (!active) return NO;
    uint64_t state = SCPGetLiveState();
    BOOL wasRunning = state == SCPLiveStateStarting || state == SCPLiveStateRunning;
    [[SCPLivePreviewController sharedInstance] stopWithState:SCPLiveStateIdle reason:@"CarPlay session starting"];
    return wasRunning;
}

BOOL SCPHostIsCarPlaySessionActive(void) {
    return gSCPCarPlaySessionActive;
}

void SCPHostLaunchSuspended(NSString *bundleID, void (^completion)(NSError *error)) {
    [[SCPLivePreviewController sharedInstance] launchSuspended:bundleID completion:completion];
}

id SCPHostApplication(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    id appController = SCPSendId(objc_getClass("SBApplicationController"), @"sharedInstance");
    return SCPSendIdId(appController, @"applicationWithBundleIdentifier:", bundleID);
}

UIViewController *SCPHostAppViewController(NSString *bundleID, id application) {
    if (bundleID.length == 0 || !application) return nil;
    UIViewController *controller = SCPLiveReusableControllers()[bundleID];
    if (controller) return controller;
    if (SCPLiveDroppedTooOften(bundleID)) {
        SCPLiveLog(@"host core: %@ refused, dropped 3 times since SpringBoard started", bundleID);
        return nil;
    }
    @try {
        SCPLiveSlot *slot = [SCPLiveSlot new];
        slot.bundleID = bundleID;
        controller = [[SCPLivePreviewController sharedInstance] makeAppViewControllerForSlot:slot application:application];
    } @catch (NSException *exception) {
        SCPLiveLog(@"host core: EXCEPTION making view controller for %@: %@ -- %@", bundleID, exception.name, exception.reason);
        controller = nil;
    }
    if (controller) {
        SCPLiveKeepForever(controller);
        SCPLiveReusableControllers()[bundleID] = controller;
    }
    return controller;
}

void SCPHostForgetAppViewController(NSString *bundleID, UIViewController *controller) {
    SCPLiveNoteDrop(bundleID);
    if (bundleID.length && SCPLiveReusableControllers()[bundleID] == controller) {
        [SCPLiveReusableControllers() removeObjectForKey:bundleID];
    }
}

BOOL SCPHostAppLooksAlive(id application, id sceneHandle, id scene) {
    SCPLiveSlot *slot = [SCPLiveSlot new];
    slot.application = application;
    slot.sceneHandle = sceneHandle;
    slot.scene = scene;
    return [[SCPLivePreviewController sharedInstance] slotLooksAlive:slot];
}

void SCPHostSetSceneForeground(id scene, BOOL foreground, CGSize size) {
    SEL updateSel = NSSelectorFromString(@"updateSettingsWithBlock:");
    if (!scene || ![scene respondsToSelector:updateSel]) return;
    void (^block)(id) = ^(id settings) {
        SCPSendBool(settings, @"setForeground:", foreground);
        SCPSendRect(settings, @"setFrame:", CGRectMake(0, 0, size.width, size.height));
    };
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(scene, updateSel, block);
    } @catch (NSException *exception) {
        SCPLiveLog(@"host core: setForeground EXCEPTION %@ -- %@", exception.name, exception.reason);
    }
}

CGSize SCPHostVirtualSize(CGSize pane) {
    return SCPLiveVirtualSize(pane);
}

void SCPHostLayoutContent(UIView *content, CGSize pane) {
    if (!content) return;
    CGSize virtualSize = SCPLiveVirtualSize(pane);
    CGFloat scale = virtualSize.width > 0 ? pane.width / virtualSize.width : 1.0;
    content.autoresizingMask = UIViewAutoresizingNone;
    content.transform = CGAffineTransformIdentity;
    content.bounds = CGRectMake(0, 0, virtualSize.width, virtualSize.height);
    content.center = CGPointMake(pane.width / 2.0, pane.height / 2.0);
    content.transform = CGAffineTransformMakeScale(scale, scale);
}

void SCPHostKeepForever(id object) {
    SCPLiveKeepForever(object);
}

#pragma mark - Entry point

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
        SCPSetLiveState(SCPLiveStateIdle); // a SpringBoard restart ends any session

        // The marker is still set: SpringBoard died during a session.
        // Don't let the same setup crash it (and drop into safe mode) again.
        NSDictionary *prefs = SCPCopyPrefs();
        if ([prefs[@"livePreviewSessionActive"] boolValue]) {
            BOOL wasBoth = [prefs[@"livePreviewSessionBoth"] boolValue];
            SCPSetPref(@"livePreviewSessionActive", @NO);
            if (wasBoth) SCPSetPref(@"livePreviewBoth", @NO);
            SCPSetPref(@"livePreviewCrashNotice", @(wasBoth ? 2 : 1));
            SCPLiveLog(@"SpringBoard restarted during a live session (both=%d); %@",
                        wasBoth, wasBoth ? @"turned \"2 app\" off" : @"will tell the app");
        }

        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(darwin, NULL,
            (CFNotificationCallback)[](CFNotificationCenterRef center, void *observer, CFStringRef name,
                                        const void *object, CFDictionaryRef userInfo) {
                dispatch_async(dispatch_get_main_queue(), ^{ [[SCPLivePreviewController sharedInstance] start]; });
            },
            CFSTR(SCP_LIVE_START_NOTIFICATION), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(darwin, NULL,
            (CFNotificationCallback)[](CFNotificationCenterRef center, void *observer, CFStringRef name,
                                        const void *object, CFDictionaryRef userInfo) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[SCPLivePreviewController sharedInstance] stopWithState:SCPLiveStateIdle reason:@"stop requested by app"];
                });
            },
            CFSTR(SCP_LIVE_STOP_NOTIFICATION), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(darwin, NULL,
            (CFNotificationCallback)[](CFNotificationCenterRef center, void *observer, CFStringRef name,
                                        const void *object, CFDictionaryRef userInfo) {
                dispatch_async(dispatch_get_main_queue(), ^{ [[SCPLivePreviewController sharedInstance] applyResizeFromApp]; });
            },
            CFSTR(SCP_LIVE_RESIZE_NOTIFICATION), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        // Never draw over the lock screen.
        CFNotificationCenterAddObserver(darwin, NULL,
            (CFNotificationCallback)[](CFNotificationCenterRef center, void *observer, CFStringRef name,
                                        const void *object, CFDictionaryRef userInfo) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[SCPLivePreviewController sharedInstance] stopWithState:SCPLiveStateIdle reason:@"device locked"];
                });
            },
            CFSTR("com.apple.springboard.lockcomplete"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
