# SplitCarPlay

A Theos jailbreak tweak that renders two apps side by side on the physical
CarPlay display, with a draggable divider. Same category of tweak as
SidePlay/CarSplit/DashSplit — this is a from-scratch implementation you build
and adapt yourself, not a copy of any of them.

## Status

The Settings UI (Prefs.bundle — app picker, toggles, speed card wiring)
has been built, fixed, and tested through several real-device iterations
and works. The actual CarPlay split-screen window/app-hosting code in
`Tweak.xm` has **not** been tried on a real CarPlay session yet and is
split into two tiers, clearly marked in `Tweak.xm`:

- **VERIFIED** — the window-creation path (find the CarPlay `CADisplay` →
  wrap in `FBSDisplayConfiguration` → create a `UIRootSceneWindow` on it →
  use `_UISystemGestureManager` for touch routing) is cross-referenced
  against the open-source (Apache-2.0) tweak
  [`carplay-cast`](https://github.com/EthanArbuckle/carplay-cast)
  (`src/CRCarplayWindow.mm`), which does the single-app version of this.
  High confidence these class/method names are real.

- **ADAPT** — hosting a *specific app's* live UI inside your own window
  (`SBApplicationController` → scene identity → `SBApplicationSceneHandle` →
  `SBDeviceApplicationSceneEntity` → `SBAppViewController`) matches names
  independently cited by `carplay-cast` and by another split-screen tweak's
  README (DashSplit), so the *class names* are almost certainly right — but
  the exact argument shapes for the scene-manager accessor and the handle
  *request* object are undocumented and vary by iOS version. I did not
  invent fake-sounding symbols to paper over the gap; I left it as a marked
  TODO so you don't waste time debugging code built on a guess.

**You will need to close that gap yourself** with `class-dump` or Hopper
against `/System/Library/PrivateFrameworks` and the `CarPlayApp` binary on
your own jailbroken device, for your installed iOS version. That's standard
jailbreak-tweak-dev practice (it's exactly how the tweaks above were
originally built) — I just can't do it without a physical device to inspect.

## Build

Requires [Theos](https://theos.dev/) set up, and a jailbroken iOS
device/VM to deploy to (rootful or rootless — adjust `control`'s `Depends`
and the Makefile's `TARGET` if you're on a rootless jailbreak).

```bash
export THEOS=/opt/theos   # wherever Theos lives
make package              # builds SplitCarPlay + the Prefs bundle, produces a .deb
make install THEOS_DEVICE_IP=<device ip>   # or copy the .deb and install via Sileo/dpkg
```

## Configure

Settings app → SplitCarPlay (via the PreferenceLoader bundle in `Prefs.bundle/`):

- **Left/Right App** — tap to pick from a list of every installed app
  (via `LSApplicationWorkspace`, the standard private API for enumerating
  installed apps) instead of typing a bundle ID by hand. (Native CarPlay
  apps are the safe starting point; truly arbitrary non-CarPlay apps need
  something like CarBridge/carplay-cast's scene technique anyway, which is
  what the ADAPT section already uses.)
- **Split Ratio** — left-pane width as a fraction of the screen.
- **Show Divider Handle** — drag it on the CarPlay screen to resize live.

Changing a setting posts the Darwin notification
`com.example.splitcarplay/reload`, which `Tweak.xm` listens for and
re-lays-out immediately — no respring needed for ratio/divider changes
(app swaps re-create the hosted scene, which may flicker).

## Speed card (Vietmap Live)

A floating card (`SpeedBubbleView` in `Tweak.xm`) shows on top of the
split, mirroring **Vietmap Live's own current speed + speed-limit
warning** (red ring when over the limit) rather than a raw GPS reading.

This used to be a separate companion tweak (VietmapLiveExport); it's now
merged directly into this same package as **`VietmapLiveHook.xm`** —
install just this one tweak. That file injects into the same dylib but
only *acts* when it's loaded inside Vietmap Live's own process
(`vn.vietmap.live`): it hooks `FlutterMethodChannel` (Vietmap Live is a
Flutter app — a real, public, Google-documented class, not a guessed
private one) and writes what it sees to
`/var/mobile/Library/Caches/com.example.splitcarplay/vietmap_speed.plist`,
which the CarPlay-side code (`SpeedBubbleView`/`SplitCarPlayController`
in `Tweak.xm`) reads. See `VietmapLiveHook.xm`'s header comment for the
full mechanism writeup and how to verify/tune its payload-parsing on your
installed Vietmap Live version (there's a call logger —
`notifyutil -p com.example.vietmaplivexport/toggle-logging` — writing to
`/var/mobile/Library/Logs/vietmaplivexport_calls.log`).

Toggle the card from Settings → SplitCarPlay → "Show Speed Bubble". It
auto-hides if no fresh reading has arrived in the last 6 seconds (Vietmap
Live not running, or the hook isn't matching the expected channel/method
names on your installed version).

## Design notes / where to extend

- `layoutContainers` currently **clips** each app's view to its half
  (`clipsToBounds`). If you'd rather see the whole app UI shrunk to fit
  (nothing cropped), apply `CGAffineTransformMakeScale` to `appVC.view`
  instead — that's what the single-app original does for orientation
  changes, and the comment in that method shows where to swap it in.
- Touch delivery: once `SBAppViewController.view` is a real subview inside
  a real, key `UIWindow` on the CarPlay `CADisplay`, ordinary UIKit hit
  testing should route taps correctly within each half. The
  `_UISystemGestureManager` dance in the original is for *system-level*
  gestures (e.g. a dock) layered on top of that, not basic touch delivery —
  you likely only need it for your own chrome (the divider, a "swap sides"
  gesture), which is already wired via a plain `UIPanGestureRecognizer`.
- Swap-sides / long-press-to-pick-app, a live preview thumbnail while
  dragging, and remembering per-car-head-unit layouts are natural next
  features once the ADAPT section is solid on your target iOS version.

## Scope / legal note

This only affects the CarPlay UI process (`com.apple.CarPlayApp`) on a
device you own and have jailbroken yourself. It doesn't intercept, bridge,
or exfiltrate anything from other devices or accounts. Jailbreaking and
redistributing tweaks that reimplement Apple's private frameworks sits in a
legal gray area in some jurisdictions (DMCA §1201 exemptions for jailbreaking
exist in the US but vary elsewhere) — that's on you to check for your
situation if you plan to distribute this beyond personal use.
