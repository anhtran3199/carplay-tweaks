//
//  VietmapLiveExport — Tweak.xm  (v2 — corrected approach)
//
//  v1 of this file hooked `-[UILabel setText:]` to scrape Vietmap Live's
//  on-screen speed-limit number. That was very likely WRONG: Vietmap Live
//  is written in Flutter, which draws its entire UI itself onto a single
//  Skia canvas — there generally are no real UILabel instances carrying
//  that text for a setText: hook to ever see.
//
//  THE REAL MECHANISM (grounded in a real, working, MIT-licensed tweak)
//
//  Flutter apps talk to their host app's native code over named
//  "platform channels" — `FlutterMethodChannel`, a genuinely PUBLIC,
//  Google-documented Flutter-engine class (FlutterChannels.h /
//  FlutterCodecs.h, see api.flutter.dev/ios-embedder/). Vietmap Live's own
//  Dart code registers a handler on specific channels to receive speed/
//  navigation data from its native side; if we hook
//  `-[FlutterMethodChannel setMethodCallHandler:]` we can wrap whatever
//  handler block Vietmap Live installs and see every call before it does,
//  without breaking Vietmap Live itself (we always forward to the real
//  handler afterwards).
//
//  The specific channel names and method names below —
//  "vml_main_channel", "vietmap_car_method_channel", "updateCurrentSpeed",
//  "updateSpeedLimit", "updateUpcommingAlerts", "updateStickyAlerts" — are
//  not guessed. They're documented by the open-source (MIT), working
//  tweak "gmaphud" (github.com/bechou0410/gmaphud), which does this exact
//  job (pulling Vietmap Live's speed/limit data) for a different purpose
//  (overlaying it on Google Maps/Waze instead of a CarPlay split view).
//  This file is an original implementation of the same real technique,
//  not a copy of their code — I did not have their actual source, only
//  documented behavior, so the payload-parsing details below are
//  defensive/flexible and you should confirm the exact shape on your
//  installed version using the call logger described below before
//  trusting this while driving.
//
//  SAFETY / SCOPE
//
//  Everything stays on-device: we only observe calls already flowing
//  inside Vietmap Live's own process (scoped there by the filter plist)
//  and forward them to Vietmap Live's real handler unchanged — nothing is
//  blocked, delayed, or sent off-device. Reverse-engineering a closed
//  third-party app's internals like this is still worth treating as
//  personal-use-only; see README.md.
//
#import <UIKit/UIKit.h>

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

static NSString * const kSharedStateDir = @"/var/mobile/Library/Caches/com.example.splitcarplay";
static NSString * const kSharedStatePath = @"/var/mobile/Library/Caches/com.example.splitcarplay/vietmap_speed.plist";
static CFStringRef const kUpdateNotification = (__bridge CFStringRef)@"com.example.splitcarplay/vietmap-update";

// Toggle verbose call logging at runtime — see README "Verify on your device".
static CFStringRef const kToggleLoggingNotification = (__bridge CFStringRef)@"com.example.vietmaplivexport/toggle-logging";
static NSString * const kCallLogPath = @"/var/mobile/Library/Logs/vietmaplivexport_calls.log";
static BOOL gLoggingEnabled = NO;

static double gLastCurrentSpeed = -1;
static double gLastSpeedLimit = -1;

#pragma mark - Helpers

// Pulls a numeric value out of whatever shape Vietmap Live happens to send:
// a bare NSNumber, or a dictionary keyed "speed"/"speedLimit" (optionally
// nested one level under a "samples" sub-dictionary). Logging below will
// show you which shape actually arrives on your version.
static BOOL extractNumber(id args, NSArray<NSString *> *candidateKeys, double *out) {
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
            return extractNumber(samples, candidateKeys, out);
        }
    }
    return NO;
}

static void writeSharedState(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kSharedStateDir]) {
        [fm createDirectoryAtPath:kSharedStateDir withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions: @0777} error:nil];
    }

    BOOL haveLimit = gLastSpeedLimit > 0;
    BOOL haveSpeed = gLastCurrentSpeed >= 0;
    BOOL overLimit = haveLimit && haveSpeed && (gLastCurrentSpeed > gLastSpeedLimit);

    NSDictionary *state = @{
        @"speedLimitText": haveLimit ? [NSString stringWithFormat:@"%.0f", gLastSpeedLimit] : @"",
        @"currentSpeedText": haveSpeed ? [NSString stringWithFormat:@"%.0f", gLastCurrentSpeed] : @"",
        @"isOverLimit": @(overLimit),
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
    };
    [state writeToFile:kSharedStatePath atomically:YES];
    chmod([kSharedStatePath fileSystemRepresentation], 0666);

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          kUpdateNotification, NULL, NULL, YES);
}

static void logCall(NSString *method, id arguments) {
    if (!gLoggingEnabled) return;
    NSString *line = [NSString stringWithFormat:@"[%.0f] method=%@ arguments=%@\n",
                       [[NSDate date] timeIntervalSince1970], method, arguments];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:kCallLogPath];
    if (!handle) {
        [[NSFileManager defaultManager] createFileAtPath:kCallLogPath contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:kCallLogPath];
    }
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

#pragma mark - Call handling (ADAPT — confirm shapes with the call logger)

static void handleFlutterCall(FlutterMethodCall *call) {
    NSString *name = call.method;
    id args = call.arguments;
    logCall(name, args);

    double value;
    if ([name isEqualToString:@"updateCurrentSpeed"]) {
        if (extractNumber(args, @[@"speed", @"currentSpeed"], &value)) {
            gLastCurrentSpeed = value;
            writeSharedState();
        }
    } else if ([name isEqualToString:@"updateSpeedLimit"]) {
        if (extractNumber(args, @[@"speedLimit", @"limit"], &value)) {
            gLastSpeedLimit = value;
            writeSharedState();
        }
    }
    // updateUpcommingAlerts / updateStickyAlerts reportedly carry
    // JSON-string alert objects (camera/speed-limit-sign alerts) rather
    // than plain numbers — enable the call logger and inspect a few real
    // payloads before trying to parse those; not attempted here since the
    // exact JSON schema isn't verified.
}

#pragma mark - Hook

%hook FlutterMethodChannel

- (void)setMethodCallHandler:(FlutterMethodCallHandler)handler {
    FlutterMethodCallHandler wrapped = ^(FlutterMethodCall *call, FlutterResult result) {
        @try {
            handleFlutterCall(call);
        } @catch (NSException *exception) {
            NSLog(@"[VietmapLiveExport] handleFlutterCall threw: %@", exception);
        }
        // Always forward to Vietmap Live's own handler, unmodified, so the
        // app keeps working exactly as if we weren't here.
        if (handler) handler(call, result);
    };
    %orig(wrapped);
}

%end

%ctor {
    @autoreleasepool {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            (CFNotificationCallback)[](CFNotificationCenterRef center, void *observer, CFStringRef name,
                                        const void *object, CFDictionaryRef userInfo) {
                gLoggingEnabled = !gLoggingEnabled;
                NSLog(@"[VietmapLiveExport] call logging %@", gLoggingEnabled ? @"ENABLED" : @"disabled");
            },
            kToggleLoggingNotification,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
