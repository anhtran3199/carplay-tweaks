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
//  Every private selector is called through objc_msgSend after a
//  respondsToSelector: check, every step is logged to
//  /var/mobile/Library/Logs/splitcarplay_hosting.log (prefix "[live]"),
//  and the whole thing is wrapped in @try. Failure = log + teardown, never
//  a SpringBoard crash. Safety exits: the ✕ button, the app's own "Dừng"
//  button, the app leaving the screen, and the device locking.
//
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "SplitCarPlayShared.h"

#pragma mark - Logging

static void SCPLiveLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[SplitCarPlay/live] %@", message);

    NSString *path = @"/var/mobile/Library/Logs/splitcarplay_hosting.log";
    NSString *timestamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                           dateStyle:NSDateFormatterNoStyle
                                                           timeStyle:NSDateFormatterMediumStyle];
    NSString *line = [NSString stringWithFormat:@"[%@] [live] %@\n", timestamp, message];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
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
@property (nonatomic, strong) UIViewController *appViewController; // SBAppViewController
@property (nonatomic, strong) id scene;             // FBScene
@property (nonatomic, assign) BOOL hosted;
@property (nonatomic, assign) NSInteger reassertCount;
@end

@implementation SCPLiveSlot
@end

#pragma mark - Controller

@interface SCPLivePreviewController : NSObject
+ (instancetype)sharedInstance;
- (void)start;
- (void)stopWithState:(uint64_t)state reason:(NSString *)reason;
@end

@implementation SCPLivePreviewController {
    SCPLivePassthroughWindow *_window;
    NSMutableArray<SCPLiveSlot *> *_slots;
    NSTimer *_keepAliveTimer;
    NSUInteger _generation; // bumps on every start/stop; stale callbacks compare against it
}

+ (instancetype)sharedInstance {
    static SCPLivePreviewController *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [SCPLivePreviewController new]; });
    return instance;
}

- (void)start {
    if (_window) [self stopWithState:SCPLiveStateIdle reason:@"restart"];
    NSUInteger generation = ++_generation;

    @try {
        NSDictionary *prefs = SCPCopyPrefs();
        BOOL both = [prefs[@"livePreviewBoth"] boolValue];
        NSString *leftID = prefs[@"leftBundleID"];
        NSString *rightID = prefs[@"rightBundleID"];
        CGRect leftFrame = CGRectFromString(prefs[@"livePreviewLeftFrame"] ?: @"");
        CGRect rightFrame = CGRectFromString(prefs[@"livePreviewRightFrame"] ?: @"");
        SCPLiveLog(@"start: left=%@ %@ right=%@ %@ both=%d", leftID, NSStringFromCGRect(leftFrame),
                    rightID, NSStringFromCGRect(rightFrame), both);

        NSMutableArray<NSDictionary *> *wanted = [NSMutableArray new];
        if (leftID.length && leftFrame.size.width > 20 && leftFrame.size.height > 20) {
            [wanted addObject:@{@"id": leftID, @"frame": [NSValue valueWithCGRect:leftFrame]}];
        }
        if (both && rightID.length && rightFrame.size.width > 20 && rightFrame.size.height > 20) {
            [wanted addObject:@{@"id": rightID, @"frame": [NSValue valueWithCGRect:rightFrame]}];
        }
        if (wanted.count == 0) {
            SCPLiveLog(@"start: ABORT nothing to host (no app picked or bad frames)");
            SCPSetLiveState(SCPLiveStateFailed);
            return;
        }
        SCPSetLiveState(SCPLiveStateStarting);

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
            slot.container = [[UIView alloc] initWithFrame:frame];
            slot.container.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
            slot.container.layer.cornerRadius = 10;
            slot.container.clipsToBounds = YES;
            [_window.rootViewController.view addSubview:slot.container];
            slot.loadingView = [self makeLoadingViewForBundleID:slot.bundleID size:frame.size];
            [slot.container addSubview:slot.loadingView];
            [_slots addObject:slot];
        }
        [self addCloseButtonNear:unionFrame];

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

- (void)addCloseButtonNear:(CGRect)unionFrame {
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    CGFloat size = 30;
    closeButton.frame = CGRectMake(CGRectGetMaxX(unionFrame) - size - 6, CGRectGetMinY(unionFrame) + 6, size, size);
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

#pragma mark Hosting

- (void)hostSlotAtIndex:(NSUInteger)index generation:(NSUInteger)generation {
    if (generation != _generation || index >= _slots.count) return;
    SCPLiveSlot *slot = _slots[index];
    SCPLiveLog(@"host[%lu] %@: launching suspended", (unsigned long)index, slot.bundleID);

    __weak __typeof__(self) weakSelf = self;
    void (^afterLaunch)(void) = ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf->_generation) return;
            [strongSelf attachSlot:slot];
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
- (void)launchSuspended:(NSString *)bundleID completion:(void (^)(void))completion {
    @try {
        Class serviceClass = objc_getClass("FBSSystemService");
        id service = SCPSendId(serviceClass, @"sharedService");
        NSDictionary *options = @{@"__ActivateSuspended": @YES, @"__UnlockDevice": @NO};
        void (^result)(NSError *) = ^(NSError *error) {
            SCPLiveLog(@"  launch %@ result: %@", bundleID, (id)error ?: @"ok");
            dispatch_async(dispatch_get_main_queue(), completion);
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
            completion(); // try to host anyway; works if the app is already running
        }
    } @catch (NSException *exception) {
        SCPLiveLog(@"  launch EXCEPTION %@ -- %@", exception.name, exception.reason);
        completion();
    }
}

- (void)attachSlot:(SCPLiveSlot *)slot {
    @try {
        NSString *bundleID = slot.bundleID;
        id appController = SCPSendId(objc_getClass("SBApplicationController"), @"sharedInstance");
        id application = SCPSendIdId(appController, @"applicationWithBundleIdentifier:", bundleID);
        SCPLiveLog(@"  attach %@: application=%@", bundleID, application);
        if (!application) return;

        Class entityClass = objc_getClass("SBDeviceApplicationSceneEntity");
        id entity = nil;
        if ([entityClass instancesRespondToSelector:NSSelectorFromString(@"initWithApplicationForMainDisplay:")]) {
            entity = ((id (*)(id, SEL, id))objc_msgSend)([entityClass alloc], NSSelectorFromString(@"initWithApplicationForMainDisplay:"), application);
        }
        SCPLiveLog(@"  attach %@: entity=%@", bundleID, entity);
        if (!entity) {
            SCPLiveLog(@"  attach: ABORT no initWithApplicationForMainDisplay:. SBDeviceApplicationSceneEntity methods:\n%@",
                        SCPLiveMethods(entityClass));
            return;
        }

        Class appVCClass = objc_getClass("SBAppViewController");
        SEL initSel = NSSelectorFromString(@"initWithIdentifier:andApplicationSceneEntity:");
        if (![appVCClass instancesRespondToSelector:initSel]) {
            SCPLiveLog(@"  attach: ABORT SBAppViewController has no %@. Methods:\n%@",
                        NSStringFromSelector(initSel), SCPLiveMethods(appVCClass));
            return;
        }
        UIViewController *appVC = ((id (*)(id, SEL, id, id))objc_msgSend)([appVCClass alloc], initSel, bundleID, entity);
        SCPLiveLog(@"  attach %@: appVC=%@", bundleID, appVC);
        if (!appVC) return;

        BOOL occl = SCPSendBool(appVC, @"setIgnoresOcclusions:", YES);
        BOOL mode = SCPSendInteger(appVC, @"setRequestedMode:", 2); // 2 = live content (carplay-cast)
        SCPLiveLog(@"  attach %@: setIgnoresOcclusions=%d setRequestedMode=%d", bundleID, occl, mode);

        UIView *content = appVC.view;
        content.frame = slot.container.bounds;
        content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [slot.container insertSubview:content belowSubview:slot.loadingView];
        slot.appViewController = appVC;

        id sceneHandle = SCPSendId(appVC, @"sceneHandle");
        id scene = SCPSendId(sceneHandle, @"sceneIfExists") ?: SCPSendId(sceneHandle, @"scene");
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
            [UIView animateWithDuration:0.2 animations:^{ slot.loadingView.alpha = 0; }];
            SCPLiveLog(@"  attach %@: after 1.5 s content=%@ subviews=%@ sceneForeground=%d",
                        bundleID, NSStringFromCGRect(content.frame), content.subviews,
                        SCPGetBool(SCPSendId(slot.scene, @"settings"), @"isForeground", NO));
        });
    } @catch (NSException *exception) {
        SCPLiveLog(@"  attach %@ EXCEPTION %@ -- %@\n%@", slot.bundleID, exception.name, exception.reason, exception.callStackSymbols);
    }
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
    CGRect frame = foreground ? slot.container.bounds : [UIScreen mainScreen].bounds;
    void (^block)(id) = ^(id settings) {
        SCPSendBool(settings, @"setForeground:", foreground);
        SCPSendRect(settings, @"setFrame:", CGRectMake(0, 0, frame.size.width, frame.size.height));
    };
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(scene, updateSel, block);
    } @catch (NSException *exception) {
        SCPLiveLog(@"  applyForeground EXCEPTION %@ -- %@", exception.name, exception.reason);
    }
}

// SpringBoard will try to background the hosted apps (they aren't the
// frontmost app). Re-assert foreground when that happens.
- (void)startKeepAlive {
    if (_keepAliveTimer) return;
    __weak __typeof__(self) weakSelf = self;
    _keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *timer) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { [timer invalidate]; return; }
        for (SCPLiveSlot *slot in strongSelf->_slots) {
            if (!slot.hosted) continue;
            if (!slot.scene) {
                id handle = SCPSendId(slot.appViewController, @"sceneHandle");
                slot.scene = SCPSendId(handle, @"sceneIfExists");
                if (!slot.scene) continue;
                SCPLiveLog(@"  keepAlive %@: scene appeared %@", slot.bundleID, slot.scene);
            }
            BOOL isForeground = SCPGetBool(SCPSendId(slot.scene, @"settings"), @"isForeground", YES);
            if (!isForeground) {
                slot.reassertCount++;
                if (slot.reassertCount <= 5 || slot.reassertCount % 20 == 0) {
                    SCPLiveLog(@"  keepAlive %@: scene went background, re-asserting (#%ld)", slot.bundleID, (long)slot.reassertCount);
                }
                [strongSelf applyForeground:YES toSlot:slot];
            }
        }
    }];
}

#pragma mark Teardown

- (void)stopWithState:(uint64_t)state reason:(NSString *)reason {
    _generation++;
    if (!_window && _slots.count == 0) {
        SCPSetLiveState(state);
        return;
    }
    SCPLiveLog(@"stop: %@", reason);
    [_keepAliveTimer invalidate];
    _keepAliveTimer = nil;
    for (SCPLiveSlot *slot in _slots) {
        @try {
            if (slot.scene) [self applyForeground:NO toSlot:slot];
            if (slot.appViewController) SCPSendInteger(slot.appViewController, @"setRequestedMode:", 0);
        } @catch (NSException *exception) {
            SCPLiveLog(@"  stop %@ EXCEPTION %@ -- %@", slot.bundleID, exception.name, exception.reason);
        }
        [[slot.appViewController view] removeFromSuperview];
        slot.appViewController = nil;
        slot.scene = nil;
    }
    _slots = nil;
    _window.hidden = YES;
    _window = nil;
    SCPSetLiveState(state);
}

@end

#pragma mark - Entry point

%ctor {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
        SCPSetLiveState(SCPLiveStateIdle); // a SpringBoard restart ends any session

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
