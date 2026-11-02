# VietmapLiveExport

A small companion tweak for SplitCarPlay's speed card. It reads Vietmap
Live's current speed + speed limit and writes them to a shared file so
another tweak (SplitCarPlay, installed separately) can show them on the
CarPlay screen too.

## v2 — corrected approach, read this if you had v1

The first version of this file hooked `-[UILabel setText:]` to scrape the
speed-limit number off screen. That was very likely **wrong**: Vietmap
Live is a **Flutter** app. Flutter draws its entire UI itself onto one
Skia canvas — the numbers you see on screen generally aren't backed by
real `UILabel` instances, so that hook would probably never fire.

This version hooks the real mechanism Flutter apps use to talk to their
own native/Dart boundary: **`FlutterMethodChannel`**, a genuinely public,
Google-documented class from the Flutter iOS embedder
(`FlutterChannels.h`/`FlutterCodecs.h`, see
[api.flutter.dev/ios-embedder](https://api.flutter.dev/ios-embedder/interface_flutter_method_channel.html)).
Hooking `-setMethodCallHandler:` lets us see every method call Vietmap
Live's Dart code sends to its native side (and vice versa) before
forwarding it on unchanged, so Vietmap Live keeps working normally.

## Where the channel/method names come from

The specific strings used (`vml_main_channel`, `vietmap_car_method_channel`,
`updateCurrentSpeed`, `updateSpeedLimit`, `updateUpcommingAlerts`,
`updateStickyAlerts`) are **not guessed**. They're documented by a real,
working, MIT-licensed tweak that does this exact job for a different
purpose — overlaying Vietmap Live's speed/limit data on Google Maps/Waze
instead of CarPlay:

> [`bechou0410/gmaphud`](https://github.com/bechou0410/gmaphud) —
> `provider/vietmap-source.x`

This file is an **original implementation** of the same real technique; I
worked from documented/summarized behavior of that file, not its actual
source, so treat the payload-parsing details (exactly which key holds the
number, whether it's nested under a `samples` dict) as the part still worth
double-checking — the *mechanism* (hooking `FlutterMethodChannel`) is
solid, the exact *shape* of each payload is the part to verify. If you want
maximum confidence, read `gmaphud`'s actual source yourself (MIT-licensed)
and compare.

## Verify on your device: the call logger

Rather than guess payload shapes, this tweak can log every intercepted
Flutter call to a file so you can read the real data:

```bash
notifyutil -p com.example.vietmaplivexport/toggle-logging   # turn ON
# ...drive around / open Vietmap Live and get a speed-limit warning...
notifyutil -p com.example.vietmaplivexport/toggle-logging   # turn OFF (don't leave it on — see note)
```

Then read `/var/mobile/Library/Logs/vietmaplivexport_calls.log` — each line
is `method=<name> arguments=<the raw Flutter arguments>`. Confirm:
- `updateCurrentSpeed` and `updateSpeedLimit` actually carry the numbers
  you expect, and in which shape (bare number vs. dict key vs. nested
  under `samples`) — adjust `extractNumber`'s candidate keys in `Tweak.xm`
  if needed.
- Whether `updateUpcommingAlerts`/`updateStickyAlerts` fire for speed-limit
  signs too (per gmaphud's notes these carry JSON-string alert objects) —
  if you want road-sign/camera alerts as well as the raw number, that's
  where to look next; this file doesn't parse those yet.

**Turn logging off when you're done** — every channel call in the whole
app gets logged while it's on, which is noisy and will grow the log file
quickly during actual navigation.

## Build

Needs [Theos](https://theos.dev/):

```bash
export THEOS=/opt/theos
make package
make install THEOS_DEVICE_IP=<device ip>
```

## Scope / legal note

This only observes calls already flowing inside Vietmap Live's own
process (the filter plist scopes the hook to bundle id `vn.vietmap.live`
only) and always forwards them to Vietmap Live's real handler unchanged —
nothing is blocked, delayed, or sent off-device. That said,
reverse-engineering a closed third-party app's internal platform-channel
traffic like this is likely outside Vietmap's Terms of Service even though
it doesn't touch their underlying map/camera-location data — fine for
personal use, worth reconsidering before redistributing.
