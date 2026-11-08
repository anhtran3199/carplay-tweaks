//
//  SplitCarPlayShared.h
//
//  One place for things the tweak (Tweak.xm, CarPlayEnableHook.xm,
//  VietmapLiveHook.xm) and the companion app (SplitCarPlayApp/) must agree
//  on: the prefs domain, every pref's default value, and how to read/write
//  prefs. Header-only (static inline) so each Theos target just imports it.
//
//  Prefs go through CFPreferences (cfprefsd) everywhere. Mixing that with
//  direct writes to the .plist file -- what this project used to do --
//  lets cfprefsd's cached copy overwrite file writes and vice versa.
//  Existing values survive the switch: cfprefsd loads the same plist file.
//
#pragma once
#import <Foundation/Foundation.h>
#include <notify.h>

#define SCP_PREFS_DOMAIN CFSTR("com.example.splitcarplay")
#define SCP_PREFS_PATH @"/var/mobile/Library/Preferences/com.example.splitcarplay.plist"
#define SCP_RELOAD_NOTIFICATION "com.example.splitcarplay/reload"

static inline NSDictionary *SCPDefaultPrefs(void) {
    return @{
        @"enabled": @YES,
        @"experimentalHostingEnabled": @NO, // one-shot test switch, see Tweak.xm reloadFromPreferences
        @"experimentalSingleApp": @NO,       // 0.9.0: split by default (was one app full-width)
        @"leftBundleID": @"com.apple.Maps",
        @"rightBundleID": @"com.apple.Music",
        @"splitRatio": @0.5,
        @"showDivider": @YES,
        @"showSpeedBubble": @YES,
        @"bubbleStyle": @0,
        @"bubblePosition": @1, // 0 = left, 1 = right
        @"bubbleScale": @1.0,
        @"speedAudioAlert": @YES,
        @"showDate": @YES,
        @"showBattery": @YES,
        @"showNowPlaying": @YES,
        @"keepSourceAppAlive": @YES,
        @"autoExitSourceApp": @NO,
        @"carPlayAutoHost": @NO, // "Đang bật" on Trang chủ: show the apps on every CarPlay connect
        @"restoreLastLayout": @YES, // reopen the apps/split last used on the car (carLast* keys)
        @"autoDimPhone": @NO,       // dim the phone 10 s after the apps show on the car
        @"appBarAutoHide": @5,      // car app bar hides after N s; 0 = always shown
        @"carApps": @[],            // up to 12 bundle IDs offered in the car app bar
    };
}

// Defaults merged with whatever is stored. Falls back to reading the plist
// file directly if cfprefsd gives nothing back (e.g. a sandboxed process).
static inline NSDictionary *SCPCopyPrefs(void) {
    CFPreferencesAppSynchronize(SCP_PREFS_DOMAIN);
    NSDictionary *stored = nil;
    CFArrayRef keys = CFPreferencesCopyKeyList(SCP_PREFS_DOMAIN, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys) {
        stored = (__bridge_transfer NSDictionary *)CFPreferencesCopyMultiple(keys, SCP_PREFS_DOMAIN,
                                                                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFRelease(keys);
    }
    if (stored.count == 0) stored = [NSDictionary dictionaryWithContentsOfFile:SCP_PREFS_PATH];

    NSMutableDictionary *merged = [SCPDefaultPrefs() mutableCopy];
    if (stored) [merged addEntriesFromDictionary:stored];
    return merged;
}

// Writes one pref. Does NOT post the reload notification -- callers decide
// (the tweak itself must not, see Tweak.xm's one-shot disarm).
static inline void SCPSetPref(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, SCP_PREFS_DOMAIN);
    CFPreferencesAppSynchronize(SCP_PREFS_DOMAIN);
}

// "Đang bật" (Trang chủ) and "Mở khi kết nối CarPlay" (Trên xe) are one
// setting; both screens show this, so they can never disagree.
static inline BOOL SCPIsCarPlayOn(NSDictionary *prefs) {
    return [prefs[@"carPlayAutoHost"] boolValue] && [prefs[@"enabled"] boolValue];
}

static inline void SCPPostReload(void) {
    notify_post(SCP_RELOAD_NOTIFICATION);
}

#pragma mark - Hosting session flag (SpringBoard -> CarPlayApp)
//
//  SpringBoard turns experimentalHostingEnabled off the moment a session
//  starts (one-shot), which is usually BEFORE CarPlayApp builds its app
//  library -- so CarPlayEnableHook can't rely on the pref alone. SpringBoard
//  also raises this notify state for the duration of the session.
//
#define SCP_HOSTING_SESSION_NOTIFICATION "com.example.splitcarplay/hosting-session"

static inline void SCPSetHostingSessionActive(BOOL active) {
    static int token = 0;
    static BOOL registered = NO;
    if (!registered) registered = notify_register_check(SCP_HOSTING_SESSION_NOTIFICATION, &token) == NOTIFY_STATUS_OK;
    if (!registered) return;
    notify_set_state(token, active ? 1 : 0);
    notify_post(SCP_HOSTING_SESSION_NOTIFICATION);
}

static inline BOOL SCPIsHostingSessionActive(void) {
    static int token = 0;
    static BOOL registered = NO;
    if (!registered) registered = notify_register_check(SCP_HOSTING_SESSION_NOTIFICATION, &token) == NOTIFY_STATUS_OK;
    if (!registered) return NO;
    uint64_t state = 0;
    notify_get_state(token, &state);
    return state != 0;
}

#pragma mark - Vietmap speed state over Darwin notify
//
//  Vietmap Live is a sandboxed App Store app, so writing a file into
//  /var/mobile/Library/Caches from inside it may be refused. The state is
//  small enough to ride along in the notification's 64-bit state value
//  instead, which needs no file access at all. Layout:
//    bits  0-11  current speed + 1 (0 = unknown)
//    bits 12-23  speed limit + 1   (0 = unknown)
//    bit  24     over limit
//    bits 32-63  unix timestamp (seconds)
//
#define SCP_SPEED_STATE_NOTIFICATION "com.example.splitcarplay/vietmap-state"

static inline uint64_t SCPEncodeSpeedState(double speed, double limit, BOOL overLimit, NSTimeInterval timestamp) {
    // Round (not truncate) to match the file path's "%.0f".
    uint64_t s = speed >= 0 ? (uint64_t)llround(MIN(4094.0, speed)) + 1 : 0;
    uint64_t l = limit > 0 ? (uint64_t)llround(MIN(4094.0, limit)) + 1 : 0;
    return (s & 0xFFF) | ((l & 0xFFF) << 12) | ((uint64_t)(overLimit ? 1 : 0) << 24) | ((uint64_t)(uint32_t)timestamp << 32);
}

// Same dictionary shape as the old shared plist, or nil if nothing posted yet.
static inline NSDictionary *SCPReadSpeedState(void) {
    static int token = 0;
    static BOOL registered = NO;
    if (!registered) registered = notify_register_check(SCP_SPEED_STATE_NOTIFICATION, &token) == NOTIFY_STATUS_OK;
    if (!registered) {
        return nil;
    }
    uint64_t packed = 0;
    if (notify_get_state(token, &packed) != NOTIFY_STATUS_OK || packed == 0) return nil;
    uint64_t s = packed & 0xFFF, l = (packed >> 12) & 0xFFF;
    return @{
        @"currentSpeedText": s ? [NSString stringWithFormat:@"%llu", s - 1] : @"",
        @"speedLimitText": l ? [NSString stringWithFormat:@"%llu", l - 1] : @"",
        @"isOverLimit": @(((packed >> 24) & 1) != 0),
        @"timestamp": @((double)(uint32_t)(packed >> 32)),
    };
}

static inline void SCPPublishSpeedState(uint64_t packed) {
    static int token = 0;
    static BOOL registered = NO;
    if (!registered) registered = notify_register_check(SCP_SPEED_STATE_NOTIFICATION, &token) == NOTIFY_STATUS_OK;
    if (!registered) {
        return;
    }
    notify_set_state(token, packed);
    notify_post(SCP_SPEED_STATE_NOTIFICATION);
}

#pragma mark - Live preview on the phone screen (app -> SpringBoard)
//
//  The app's "Mô phỏng" tab writes the two panes' screen rects to prefs
//  (livePreviewLeftFrame / livePreviewRightFrame, NSStringFromCGRect) and
//  posts START. SpringBoard (LivePreview.xm) hosts the real apps in a
//  window over those rects and reports progress in the STATE value.
//
#define SCP_LIVE_START_NOTIFICATION "com.example.splitcarplay/live-preview-start"
#define SCP_LIVE_STOP_NOTIFICATION "com.example.splitcarplay/live-preview-stop"
#define SCP_LIVE_STATE_NOTIFICATION "com.example.splitcarplay/live-preview-state"

enum {
    SCPLiveStateIdle = 0,
    SCPLiveStateStarting = 1,
    SCPLiveStateRunning = 2,
    SCPLiveStateFailed = 3,
};

static inline void SCPSetLiveState(uint64_t state) {
    static int token = 0;
    static BOOL registered = NO;
    if (!registered) registered = notify_register_check(SCP_LIVE_STATE_NOTIFICATION, &token) == NOTIFY_STATUS_OK;
    if (!registered) return;
    notify_set_state(token, state);
    notify_post(SCP_LIVE_STATE_NOTIFICATION);
}

static inline uint64_t SCPGetLiveState(void) {
    static int token = 0;
    static BOOL registered = NO;
    if (!registered) registered = notify_register_check(SCP_LIVE_STATE_NOTIFICATION, &token) == NOTIFY_STATUS_OK;
    if (!registered) return SCPLiveStateIdle;
    uint64_t state = 0;
    notify_get_state(token, &state);
    return state;
}

// Divider dragged while live: the app sends the panes' new horizontal
// geometry (y and height don't change) in the notify state, so SpringBoard
// can follow every frame without prefs round trips. Layout, in 0.5 pt units:
//   bits  0-15  left pane width
//   bits 16-31  right pane x
//   bits 32-47  right pane width
//   bit  63     final (drag ended: also resize the apps' scenes)
#define SCP_LIVE_RESIZE_NOTIFICATION "com.example.splitcarplay/live-preview-resize"

static inline void SCPPostLiveResize(double leftWidth, double rightX, double rightWidth, BOOL final) {
    static int token = 0;
    static BOOL registered = NO;
    if (!registered) registered = notify_register_check(SCP_LIVE_RESIZE_NOTIFICATION, &token) == NOTIFY_STATUS_OK;
    if (!registered) return;
    uint64_t lw = (uint64_t)llround(MAX(0.0, MIN(32767.0, leftWidth)) * 2.0) & 0xFFFF;
    uint64_t rx = (uint64_t)llround(MAX(0.0, MIN(32767.0, rightX)) * 2.0) & 0xFFFF;
    uint64_t rw = (uint64_t)llround(MAX(0.0, MIN(32767.0, rightWidth)) * 2.0) & 0xFFFF;
    notify_set_state(token, lw | (rx << 16) | (rw << 32) | ((uint64_t)(final ? 1 : 0) << 63));
    notify_post(SCP_LIVE_RESIZE_NOTIFICATION);
}

static inline BOOL SCPReadLiveResize(double *leftWidth, double *rightX, double *rightWidth, BOOL *final) {
    static int token = 0;
    static BOOL registered = NO;
    if (!registered) registered = notify_register_check(SCP_LIVE_RESIZE_NOTIFICATION, &token) == NOTIFY_STATUS_OK;
    if (!registered) return NO;
    uint64_t packed = 0;
    if (notify_get_state(token, &packed) != NOTIFY_STATUS_OK || packed == 0) return NO;
    *leftWidth = (double)(packed & 0xFFFF) / 2.0;
    *rightX = (double)((packed >> 16) & 0xFFFF) / 2.0;
    *rightWidth = (double)((packed >> 32) & 0xFFFF) / 2.0;
    *final = ((packed >> 63) & 1) != 0;
    return YES;
}

#pragma mark - CarPlay status for the app's Trang chủ (SpringBoard -> app)
#define SCP_CARPLAY_STATE_NOTIFICATION "com.example.splitcarplay/carplay-state"

enum {
    SCPCarPlayStateDisconnected = 0,
    SCPCarPlayStateConnected = 1, // car connected, apps not shown
    SCPCarPlayStateShowing = 2,   // apps on the car screen
};

static inline void SCPSetCarPlayState(uint64_t state) {
    static int token = 0;
    static BOOL registered = NO;
    if (!registered) registered = notify_register_check(SCP_CARPLAY_STATE_NOTIFICATION, &token) == NOTIFY_STATUS_OK;
    if (!registered) return;
    notify_set_state(token, state);
    notify_post(SCP_CARPLAY_STATE_NOTIFICATION);
}

static inline uint64_t SCPGetCarPlayState(void) {
    static int token = 0;
    static BOOL registered = NO;
    if (!registered) registered = notify_register_check(SCP_CARPLAY_STATE_NOTIFICATION, &token) == NOTIFY_STATUS_OK;
    if (!registered) return SCPCarPlayStateDisconnected;
    uint64_t state = 0;
    notify_get_state(token, &state);
    return state;
}
