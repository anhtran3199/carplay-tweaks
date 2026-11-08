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
        @"experimentalSingleApp": @YES,      // milestone 1: one app full-width
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
