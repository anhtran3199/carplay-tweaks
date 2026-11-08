# SplitCarPlay

A Theos jailbreak tweak + companion app aiming to render two apps side by
side on the physical CarPlay display, with a draggable divider and a
floating speed card fed by Vietmap Live. Same category of tweak as
SidePlay/CarSplit/DashSplit; this is a from-scratch implementation.

Target device so far: iPhone 7, iOS 15.8.8, Dopamine 2 (rootless).

## Status

| Part | State |
|---|---|
| Companion app (`SplitCarPlayApp/`: Trang chủ / Trên xe / Mô phỏng / Tài khoản) | Builds in CI; not yet confirmed on-device |
| Speed card data from Vietmap Live (`VietmapLiveHook.xm`) | Written, payload shape still to confirm with the call logger |
| On-car hosting (`Tweak.xm`) | **Not working yet.** Opt-in, one-shot experiment with fail-safes |
| "Enable any app" for CarPlay (`CarPlayEnableHook.xm`) | Best-effort reconstruction; only active while the experiment is armed |

The Settings-app panel (`Prefs.bundle`) was removed in 0.6.0: the app
replaced it, and the two copies of the preview screen had drifted apart.

### How on-car hosting works (and what's still unknown)

All window/hosting code runs **in SpringBoard only**. The `SB*` classes it
needs (`SBApplicationController`, `SBSceneManagerCoordinator`,
`SBAppViewController`) don't exist in CarPlayApp; the first hardware test
ran in CarPlayApp, every step failed, and the empty black window it had
already shown blanked the CarPlay screen.

The approach (as in the open-source
[`carplay-cast`](https://github.com/EthanArbuckle/carplay-cast)) is to get
the app's normal phone scene from `+[SBSceneManagerCoordinator
mainDisplaySceneManager]` and re-parent its view into a `UIRootSceneWindow`
on the CarPlay `CADisplay`.

Still unconfirmed on iOS 15: how `SBApplicationSceneHandleRequest` is
constructed. The code tries `requestForApplication:sceneIdentity:` and
`defaultRequestForApplication:sceneIdentity:displayIdentity:`; if neither
exists it writes the class's real method list to the log, so the next
build can use the right one. The app may also need to be launched first.

### Fail-safes (why it's now safe to try)

- Off unless "⚠️ Bật thử nghiệm (1 lần)" is switched on in the app. The
  switch turns itself **off** as soon as an attempt starts, so a failed
  attempt can't repeat on the next CarPlay connect.
- The CarPlay window stays hidden until an app view with a real size is
  attached. If nothing is hosted within **6 seconds**, it's torn down.
- On the car screen: a **✕** button (top-left) and a **two-finger long
  press** (1 s) both close it and give the normal CarPlay UI back.
- First milestone is one app full-width ("Chỉ 1 app toàn màn hình",
  default on, hosts "Ô 1" — Maps if unset). Turn it off to try the split.
- The first reload after SpringBoard starts is deferred 3 s, so nothing
  runs before SpringBoard has finished launching.

## Live preview on the phone ("Chạy thật", 0.7.0, experimental)

App → Mô phỏng → **▶ Chạy thật** runs the picked app(s) for real inside the
preview panes, on the phone screen. Switch on "2 app" for both panes
(start with one: two live apps is a lot for 2 GB of RAM).

`LivePreview.xm` (SpringBoard only) launches each app suspended
(`FBSSystemService`), wraps its main-display scene in an
`SBAppViewController` (`SBDeviceApplicationSceneEntity
initWithApplicationForMainDisplay:`), puts it in a window over the pane
and keeps the scene foreground and pane-sized. It's the same hosting
problem as CarPlay, testable without a car; once it works, Tweak.xm's
CarPlay path should reuse it.

Exits: red ✕ over the panes, "■ Dừng", leaving the tab or app, locking the
phone, or a 12 s watchdog if nothing could be hosted. Every step is logged
with a `[live]` prefix in `splitcarplay_hosting.log`.

Closing (0.7.3). Tapping ✕ with two apps crashed SpringBoard in 0.7.2,
which let every app go in the same instant. Now the window hides at once
and the apps are released one at a time: `setRequestedMode:0`, wait,
background the scene only if it's still foreground, wait, next app; the
view controllers are freed a second after the last one. Each step is
logged before it runs (`stop <bundle id>: …`), so after a crash the last
`[live]` line names the step. The crash marker is cleared only when
closing is done. SpringBoard also draws its own copy of the app's
left-edge show/hide handle for the bubble, which the hosted apps cover.

Sizing (0.7.2). Each app is told it has a phone-width screen with the
pane's aspect ratio (scene `setFrame:`), and its view is scaled down to
the pane, so the whole app shows instead of its top-left corner. Dragging
the ≡ divider while live no longer stops the session: the app posts the new
pane geometry in `SCP_LIVE_RESIZE_NOTIFICATION`'s state on every move;
SpringBoard moves/rescales the views live and resizes the scenes when the
drag ends.

The speed bubble is drawn by SpringBoard in the same window, on top of the
hosted apps (the app's own bubble sits underneath them). It starts where
the app's bubble was; where you drag or pinch it to goes back to the app.

Crash safety (0.7.1). The first 2-app test crashed SpringBoard, which put
Dopamine into safe mode. `@try` can't catch FrontBoard assertions, so:

- Before re-asserting foreground, each app is checked for still running
  and still having the same, valid scene. An app iOS killed (low RAM) is
  dropped after two dead readings, with a message in its pane, and its
  scene is never touched again. The second app isn't started if the first
  already died.
- A slot that SpringBoard backgrounds again and again for ~30 s is dropped.
- The same app in both panes is refused (app) and hosted once (SpringBoard).
- `livePreviewSessionActive` is set at start and cleared at stop. If a
  SpringBoard start finds it still set, SpringBoard died mid-session: it
  turns "2 app" off and the app shows a notice once.

## Testing on the car

1. Install the build from the Sileo repo (respring happens automatically).
2. App → Trên xe → switch on "⚠️ Bật thử nghiệm (1 lần)".
3. Plug into CarPlay. Wait ~6 s. Use ✕ if needed.
4. App → Trên xe → "Xem log debug", or collect:
   - `/var/mobile/Library/Logs/splitcarplay_hosting.log`
   - `/var/mobile/Library/Logs/splitcarplay_carplayenable.log`
   - Console/`oslog` filtered on `SplitCarPlay` (everything is also NSLog'd)
   - any `.ips` crash reports for SpringBoard / CarPlayApp

Before plugging in, you can confirm the unknown selectors without a car,
e.g. with FLEX or Frida attached to SpringBoard:
`ObjC.classes.SBApplicationSceneHandleRequest.$ownMethods`.

## Build

CI (`.github/workflows/build-and-publish.yml`) builds on a macOS runner
with `THEOS_PACKAGE_SCHEME=rootless` and publishes to GitHub Pages. To
build locally:

```bash
export THEOS=/opt/theos
THEOS_PACKAGE_SCHEME=rootless make package
```

## Preferences

Domain `com.example.splitcarplay`, read and written through CFPreferences
everywhere. Every key and its default lives in one place:
`SplitCarPlayShared.h` (`SCPDefaultPrefs`). The app posts the Darwin
notification `com.example.splitcarplay/reload` after each change.

## Speed card (Vietmap Live)

`VietmapLiveHook.xm` runs inside Vietmap Live (`vn.vietmap.live`, a
Flutter app), hooks `FlutterMethodChannel`'s `setMethodCallHandler:`, and
publishes the current speed/limit two ways:

- packed into the 64-bit state of the Darwin notification
  `com.example.splitcarplay/vietmap-state`, which needs no file access
  (Vietmap Live is sandboxed);
- the older shared file
  `/var/mobile/Library/Caches/com.example.splitcarplay/vietmap_speed.plist`,
  which the sandbox may refuse.

The card uses whichever is newer. To check what Vietmap Live actually
sends: `notifyutil -p com.example.vietmaplivexport/toggle-logging`, then
read `/var/mobile/Library/Logs/vietmaplivexport_calls.log`.

The card lives in the CarPlay window, so for now it's only visible while
the hosting experiment is running.

## Scope / legal note

Runs on a device you own and jailbroke yourself; injects into SpringBoard,
CarPlayApp and Vietmap Live. It doesn't bridge to or exfiltrate anything
from other devices or accounts. Redistributing tweaks built on private
frameworks is a legal gray area in some places; check yours before
distributing beyond personal use.
