//
//  VietmapLiveHook.xm
//
//  Merged into SplitCarPlay from the former standalone VietmapLiveExport
//  tweak, so installing one package is enough. This file's %hook/%ctor
//  only do anything when THIS instance of the dylib is loaded inside
//  Vietmap Live's own process -- SplitCarPlay.plist's filter now lists
//  "vn.vietmap.live" alongside "com.apple.CarPlayApp"/"com.apple.springboard",
//  so the SAME .dylib gets injected into all of them, and each source
//  file gates its own logic by checking which process it's actually
//  running in (see SplitCarPlay_BundleID() below).
//
//  Everything else is unchanged from the standalone version -- see
//  VietmapLiveExport's old README (git history) for the full mechanism
//  writeup: hooking the real, public, Google-documented
//  FlutterMethodChannel class (Vietmap Live is a Flutter app) rather than
//  scraping UILabel text, grounded in the open-source "gmaphud" tweak's
//  documented behavior for the channel/method names below.
//
#import <UIKit/UIKit.h>
#import <sys/stat.h>
#import "SplitCarPlayShared.h"

static BOOL SplitCarPlay_RunningInVietmapLive(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"vn.vietmap.live"];
}

#pragma mark - Flutter public API (real, documented — see header comment)

typedef void (^FlutterResult)(id _Nullable result);

@interface FlutterMethodCall : NSObject
@property (readonly, nonatomic) NSString *method;
@property (readonly, nonatomic, nullable) id arguments;
@end

typedef void (^FlutterMethodCallHandler)(FlutterMethodCall *call, FlutterResult result);

@interface FlutterMethodChannel : NSObject
- (void)setMethodCallHandler:(FlutterMethodCallHandler)handler;
@end

#pragma mark - Shared output (same contract SplitCarPlay's speed card reads)

static NSString * const kVMSharedStateDir = @"/var/mobile/Library/Caches/com.example.splitcarplay";
static NSString * const kVMSharedStatePath = @"/var/mobile/Library/Caches/com.example.splitcarplay/vietmap_speed.plist";
static CFStringRef const kVMUpdateNotification = (__bridge CFStringRef)@"com.example.splitcarplay/vietmap-update";

// Toggle verbose call logging at runtime — see the old VietmapLiveExport
// README (git history) for "Verify on your device" instructions.
static CFStringRef const kVMToggleLoggingNotification = (__bridge CFStringRef)@"com.example.vietmaplivexport/toggle-logging";
static NSString * const kVMCallLogPath = @"/var/mobile/Library/Logs/vietmaplivexport_calls.log";
static BOOL gVMLoggingEnabled = NO;

static double gVMLastCurrentSpeed = -1;
static double gVMLastSpeedLimit = -1;

#pragma mark - Helpers

// Pulls a numeric value out of whatever shape Vietmap Live happens to send:
// a bare NSNumber, or a dictionary keyed "speed"/"speedLimit" (optionally
// nested one level under a "samples" sub-dictionary). Logging below will
// show you which shape actually arrives on your version.
static BOOL vmExtractNumber(id args, NSArray<NSString *> *candidateKeys, double *out) {
    if ([args isKindOfClass:[NSNumber class]]) {
        *out = [(NSNumber *)args doubleValue];
        return YES;
    }
    if ([args isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = args;
        for (NSString *key in candidateKeys) {
            id value = dict[key];
            if ([value isKindOfClass:[NSNumber class]]) {
                *out = [value doubleValue];
                return YES;
            }
        }
        id samples = dict[@"samples"];
        if ([samples isKindOfClass:[NSDictionary class]]) {
            return vmExtractNumber(samples, candidateKeys, out);
        }
    }
    return NO;
}

static void vmWriteSharedState(void) {
    BOOL haveLimit = gVMLastSpeedLimit > 0;
    BOOL haveSpeed = gVMLastCurrentSpeed >= 0;
    BOOL overLimit = haveLimit && haveSpeed && (gVMLastCurrentSpeed > gVMLastSpeedLimit);

    // Runs on Flutter's platform (main) thread for every channel call.
    // Unchanged values are republished at most every 2 s (to stay "fresh"
    // for the bubble, which treats >6 s as disconnected); the file at most
    // every 2 s too, since the notify state is the main path.
    static double lastSpeed = -2, lastLimit = -2;
    static BOOL lastOver = NO;
    static CFAbsoluteTime lastPublish = 0, lastFileWrite = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL changed = llround(gVMLastCurrentSpeed) != llround(lastSpeed) || llround(gVMLastSpeedLimit) != llround(lastLimit) || overLimit != lastOver;
    if (!changed && now - lastPublish < 2.0) return;
    lastSpeed = gVMLastCurrentSpeed;
    lastLimit = gVMLastSpeedLimit;
    lastOver = overLimit;
    lastPublish = now;
    BOOL writeFile = now - lastFileWrite >= 2.0;
    if (writeFile) lastFileWrite = now;

    static dispatch_once_t dirOnce;
    if (writeFile) {
        dispatch_once(&dirOnce, ^{
            NSFileManager *fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:kVMSharedStateDir]) {
                [fm createDirectoryAtPath:kVMSharedStateDir withIntermediateDirectories:YES
                                attributes:@{NSFilePosixPermissions: @0777} error:nil];
            }
        });
    }

    NSDictionary *state = @{
        @"speedLimitText": haveLimit ? [NSString stringWithFormat:@"%.0f", gVMLastSpeedLimit] : @"",
        @"currentSpeedText": haveSpeed ? [NSString stringWithFormat:@"%.0f", gVMLastCurrentSpeed] : @"",
        @"isOverLimit": @(overLimit),
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
    };
    // May be refused by Vietmap Live's sandbox -- the notify-state publish
    // below is the path that doesn't need file access (SplitCarPlayShared.h).
    if (writeFile) {
        [state writeToFile:kVMSharedStatePath atomically:YES];
        chmod([kVMSharedStatePath fileSystemRepresentation], 0666);
    }
    SCPPublishSpeedState(SCPEncodeSpeedState(haveSpeed ? gVMLastCurrentSpeed : -1,
                                             haveLimit ? gVMLastSpeedLimit : -1,
                                             overLimit, [[NSDate date] timeIntervalSince1970]));

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          kVMUpdateNotification, NULL, NULL, YES);
}

static void vmLogCall(NSString *method, id arguments) {
    if (!gVMLoggingEnabled) return;
    NSString *line = [NSString stringWithFormat:@"[%.0f] method=%@ arguments=%@\n",
                       [[NSDate date] timeIntervalSince1970], method, arguments];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:kVMCallLogPath];
    if (!handle) {
        [[NSFileManager defaultManager] createFileAtPath:kVMCallLogPath contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:kVMCallLogPath];
    }
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

#pragma mark - Call handling (ADAPT — confirm shapes with the call logger)

static void vmHandleFlutterCall(FlutterMethodCall *call) {
    NSString *name = call.method;
    id args = call.arguments;
    vmLogCall(name, args);

    double value;
    if ([name isEqualToString:@"updateCurrentSpeed"]) {
        if (vmExtractNumber(args, @[@"speed", @"currentSpeed"], &value)) {
            gVMLastCurrentSpeed = value;
            vmWriteSharedState();
        }
    } else if ([name isEqualToString:@"updateSpeedLimit"]) {
        if (vmExtractNumber(args, @[@"speedLimit", @"limit"], &value)) {
            gVMLastSpeedLimit = value;
            vmWriteSharedState();
        }
    }
    // updateUpcommingAlerts / updateStickyAlerts reportedly carry
    // JSON-string alert objects (camera/speed-limit-sign alerts) rather
    // than plain numbers — enable the call logger and inspect a few real
    // payloads before trying to parse those; not attempted here since the
    // exact JSON schema isn't verified.
}

#pragma mark - Hook
//
//  Safe to leave unguarded by process: FlutterMethodChannel simply won't
//  exist (so Logos no-ops the hook) in any process other than Vietmap
//  Live's.

%hook FlutterMethodChannel

- (void)setMethodCallHandler:(FlutterMethodCallHandler)handler {
    // nil means "unregister" -- pass it through untouched. Wrapping nil
    // would leave a live handler that never calls `result`, so Dart-side
    // calls on that channel would hang instead of getting NotImplemented.
    if (!handler) {
        %orig(nil);
        return;
    }
    FlutterMethodCallHandler wrapped = ^(FlutterMethodCall *call, FlutterResult result) {
        @try {
            vmHandleFlutterCall(call);
        } @catch (NSException *exception) {
            NSLog(@"[SplitCarPlay/VietmapLiveHook] handleFlutterCall threw: %@", exception);
        }
        // Always forward to Vietmap Live's own handler, unmodified, so the
        // app keeps working exactly as if we weren't here.
        handler(call, result);
    };
    %orig(wrapped);
}

%end

%ctor {
    @autoreleasepool {
        if (!SplitCarPlay_RunningInVietmapLive()) return; // see header comment

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            (CFNotificationCallback)[](CFNotificationCenterRef center, void *observer, CFStringRef name,
                                        const void *object, CFDictionaryRef userInfo) {
                gVMLoggingEnabled = !gVMLoggingEnabled;
                NSLog(@"[SplitCarPlay/VietmapLiveHook] call logging %@", gVMLoggingEnabled ? @"ENABLED" : @"disabled");
            },
            kVMToggleLoggingNotification,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        // Posted by Tweak.xm (same dylib, CarPlayApp/springboard side) when
        // CarPlay disconnects and "Auto-Close Vietmap Live on CarPlay
        // Disconnect" is on. Only quits while Vietmap Live is in the
        // background -- never yank the app out from under someone who is
        // looking at it on the phone.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            (CFNotificationCallback)[](CFNotificationCenterRef center, void *observer, CFStringRef name,
                                        const void *object, CFDictionaryRef userInfo) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) return;
                    exit(0);
                });
            },
            (__bridge CFStringRef)@"com.example.splitcarplay/request-exit-source",
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        // "Keep Vietmap Live Running in Background" — ask iOS for extra
        // background execution time via the fully public
        // beginBackgroundTaskWithExpirationHandler: API, called from
        // inside Vietmap Live's own process (since this dylib is loaded
        // there). iOS still enforces its own background time limits
        // regardless — this is the standard, safe best-effort attempt at
        // "stay alive a bit longer," not a guarantee of indefinite
        // background life.
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                            object:nil
                                                             queue:nil
                                                        usingBlock:^(NSNotification *note) {
            // If the sandbox blocks reading prefs this falls back to the
            // default (on).
            if (![SCPCopyPrefs()[@"keepSourceAppAlive"] boolValue]) return;

            UIApplication *app = [UIApplication sharedApplication];
            __block UIBackgroundTaskIdentifier taskID = UIBackgroundTaskInvalid;
            taskID = [app beginBackgroundTaskWithExpirationHandler:^{
                [app endBackgroundTask:taskID];
            }];
        }];
    }
}
