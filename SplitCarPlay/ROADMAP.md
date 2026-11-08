# SplitCarPlay — feature roadmap

Checklist of ideas pulled from studying SidePlay2's real, shipped
Settings UI (metadata/plist structure only — `.deb` downloaded from
sideplay.pages.dev, control/Root.plist/Entry.plist/license files read for
reference; their compiled `.dylib`/binary logic was deliberately **not**
disassembled, since it's a commercial product). SidePlay2 itself credits
[GMapHUD](https://github.com/bechou0410/gmaphud) in its own Settings
footer — the same open-source project `VietmapLiveHook.xm` is grounded
in, so this list builds on work already validated as the right direction.

## Speed card

- [x] **Over-speed-limit audio alert** — `AudioServicesPlaySystemSound`,
      repeats every 8s while over the limit, resets so the next episode
      alerts immediately. Toggle: Settings → "Over-Limit Alert Sound".
- [x] **Show date on the card** — `NSDateFormatter`. Toggle: "Show Date/Time".
- [x] **Show battery % on the card** — `UIDevice.batteryLevel`. Toggle:
      "Show Battery %".
- [x] **Multiple card "looks"** — Card (original), Ring (compact circle),
      Bar (wide short pill). Picked via Settings → "Bubble Style"
      (`PSLinkListCell`, same pattern as SidePlay2's own source picker).
      Resizes the bubble in place (keeps wherever you dragged it).
- [x] **Now-playing music widget on the card** — `MediaRemote.framework`
      (dlopen'd, not linked — see `Tweak.xm`'s header comment), shown as
      "Title — Artist" text in the Card/Bar extras row. Toggle:
      "Show Now Playing".
- [x] **Preview shows a real app-switcher snapshot, not just an icon** —
      traced the "SidePlay2 shows a live app" question down to its real
      binary: its "Mô phỏng" actually uses Apple's **public** CarPlay
      framework (`CPTemplateApplicationScene`/`CPInterfaceController` —
      confirmed real strings in `SidePlay2.app`'s own executable), which
      can only show Apple's own templates, not arbitrary video/WebView
      content — so the YouTube-looking content in the screenshot that
      prompted this almost certainly wasn't a live render at all. Far
      more likely: iOS's own **app-switcher snapshot** feature (every
      backgrounded app's last-seen appearance is cached to disk,
      normally just for multitasking — readable by any process on a
      jailbroken device). `SplitCarPlayPreviewController.m` now finds and
      decodes that cached image (iOS 13+ stores it as a GPU-compressed
      `.ktx` texture, decoded via MetalKit; plain `.png`/`.jpg` also
      handled) for each picked app, filling the placeholder box
      edge-to-edge like a real screenshot — falls back to the plain icon
      on any failure (app never backgrounded, decode error, ...).
- [x] **Preview/simulation screen** — Settings → "Mô phỏng (Preview)"
      renders the real bubble (all 3 styles + left/right position,
      switchable live) plus app placeholders showing the real app icon
      (not just text), without needing an actual CarPlay connection —
      same idea as Vietmap Live's own "Mô phỏng" tab and SidePlay2's
      static mockup images. Uses live Vietmap data when available,
      clearly-labeled demo numbers otherwise. **Not** attempted: actually
      rendering the picked apps' live UI (what SidePlay2's own preview
      does) — Settings.app/Preferences.app has no way to host another
      app's scene the way CarPlayApp can; see the file's header comment.
      See `Prefs.bundle/SplitCarPlayPreviewController.m`.
- [x] **Bubble position (left/right)** — Settings → "Bubble Position".
      Re-applied every reload (a deliberate Settings choice, not
      overridden by a one-off drag); vertical position still follows
      wherever you've dragged it.
- [x] **Card style visual polish** — date/battery moved to the top (above
      the speed readout, matching Vietmap Live's own preview layout), the
      old two-line status paragraph replaced with a compact one-line
      status row, and a real drop shadow (via a mask layer, so rounding
      the corners doesn't clip the shadow away too).

## Data source

- [ ] **Multiple speed-source apps, not just Vietmap Live** (Waze, GOFA,
      WYN). Previously deliberately not attempted (no reference to ground
      a hook mechanism in). **Update:** extracted string tables from
      SidePlay2's own HUD dylibs (one per source app — same metadata-only
      extraction method as above, not a disassembly) actually confirm
      real, concrete targets for all three:
        - **Waze** (`com.waze.iphone`) — hooks a real, named Waze-internal
          method, `updateSpeed:timestamp:now:uptime:optionalLimit:`, via
          `MSHookMessageEx` (classic Substrate function hooking, not
          Logos `%hook`, since the target class is presumably found at
          runtime rather than declared at compile time).
        - **GOFA** (`com.lumi.GOFA`) — thinner evidence: `MSHookMessageEx`
          + `NSNotificationCenter` + a `locationHook`-named symbol, but no
          single confirmed selector the way Waze has one.
        - **WYN** (`com.wynauto.wyn`) — also a Flutter app, same
          `FlutterMethodChannel`/`setMethodCallHandler:` technique as
          Vietmap Live. One of their own debug strings is worth noting:
          *"FlutterMethodChannel setMethodCallHandler: not as expected,
          just_audio / tts not read"* — i.e. other Flutter plugins in the
          same app (audio, text-to-speech) register their own channels
          too, and a global hook can catch the wrong one. The same risk
          applies to `VietmapLiveHook.xm`, which is exactly why it ships
          a call logger to verify on-device rather than assume.
      Waze now has enough to actually attempt (a named method, not a
      guess); GOFA and WYN are thinner but no longer "nothing to go on."
      Not implemented yet — this is a sizeable addition (likely one file
      per app, matching SidePlay2's own one-dylib-per-source structure)
      better done as its own next step than folded into this pass.
- [x] **Keep the source app alive in the background** — Vietmap Live
      calls the public `beginBackgroundTaskWithExpirationHandler:` API on
      itself (from `VietmapLiveHook.xm`, injected into its process) when
      it enters background. iOS still enforces its own time limits
      regardless of this call — it's the standard best-effort, not a
      guarantee of indefinite background life. Toggle: "Keep Vietmap Live
      Running in Background" (on by default).
- [x] **Auto-exit the source app when CarPlay disconnects** — `Tweak.xm`
      posts a Darwin notification on `UIScreenDidDisconnectNotification`;
      `VietmapLiveHook.xm` calls `exit(0)` on itself on receiving it (a
      normal app-initiated quit, not a force-kill). Toggle: "Auto-Close
      Vietmap Live on CarPlay Disconnect" (off by default — opt-in since
      it's a more surprising action than the others).

- [x] **EXPERIMENTAL: "thử chạy app thật" button in Preview** — prompted
      by screenshots of SidePlay's own "Mô phỏng" tab showing real, live
      app content (a real Vietmap Live splash screen with its actual
      version string and "Đang tải dữ liệu bản đồ..." loading state; a
      real YouTube header/tab-bar chrome) **with no CarPlay connected at
      all** — contradicting the earlier assumption in this file that live
      hosting requires an actual CarPlay display. The likely explanation:
      `displaySceneManagerForCurrentDisplay` already only ever calls
      `+[SBSceneManagerCoordinator mainDisplaySceneManager]` (not
      anything CarPlay-specific) — so calling the existing `hostApp:
      inContainer:` from a process on the phone's own main display,
      instead of from CarPlayApp, might resolve to the phone's screen
      instead and just work. Implemented as: `com.apple.Preferences`
      added to `SplitCarPlay.plist`'s injected bundles; a Darwin
      notification from the new button in
      `SplitCarPlayPreviewController.m` triggers
      `showLivePreviewOverlayWithLeft:right:` (`Tweak.xm`) to build a
      plain full-screen `UIWindow` (ordinary overlay-window technique,
      not CarPlay's `UIRootSceneWindow`/`FBSDisplayConfiguration` path)
      and attempt the exact same `hostApp:inContainer:` used for the real
      feature. **Still ADAPT** — no new private API beyond what Tweak.xm
      already used, but never confirmed from this entry point; failure
      mode is contained to Preferences.app (worst case: force-quit
      Settings and reopen).

- [x] **Preview UI restyled after SidePlay's own "Mô phỏng" screenshots**
      — two concrete things the user pointed at directly:
        - **Grid-style "Chọn app ô 1/2" picker** — tapping either box in
          the Preview now opens an in-place card (not a pushed nav
          screen) with a "GẦN ĐÂY" row and a "TẤT CẢ" icon grid, matching
          the reference screenshots' layout. Reuses the exact same
          enumerate/filter/sort logic as the original table picker (now
          exported from `SplitCarPlayAppPickerController.m` as
          `SplitCarPlayUserInstalledBundleIDsSorted()`) rather than a
          second copy of it. "Gần đây" is a simplification: just the two
          currently-picked apps, not a persisted history.
        - **"Tab mới" empty state** — a box with nothing picked yet now
          looks like an empty browser tab ("+ Tab mới" in the title bar,
          a small "Gần đây" row of icons, a "Tất cả app >" link) instead
          of a blank placeholder with "(chưa chọn)" text.
      Both are purely cosmetic/UI, same category as the title-bar dots
      above — no new private API involved.

- [x] **Speed bubble: drag anywhere + pinch to resize** — the real
      `SpeedBubbleView` (`Tweak.xm`) already supported free dragging;
      the Settings "Mô phỏng" bubble didn't (it was always re-positioned
      by the Left/Right formula on every layout pass). Added:
        - A pinch gesture on the bubble in both places, applied as a
          `CGAffineTransform` scale (not a frame/bounds resize) so
          everything — text included — scales uniformly; clamped to
          [0.6, 1.6]. Persisted to a shared `bubbleScale` pref (also a
          new "Bubble Scale" slider in Settings, same pattern as "Split
          Ratio"), read by the real CarPlay bubble too.
        - A pan gesture on the Preview's bubble (the real one already
          had this) that stops the Left/Right auto-positioning once the
          user has actually dragged it — picking a new Left/Right or
          style still re-homes it, matching the real bubble's existing
          behavior.
      Fixed a related correctness issue this surfaced: code that read or
      set `.frame` directly is undefined (per Apple's own docs) once a
      view's `.transform` isn't the identity transform — switched the
      bubble-resize-on-style-change code in both `Tweak.xm` and the
      Preview to `.bounds`/`.center` instead.
- [x] **Speed card visual pass matching reference screenshots** — split
      the single "date · battery" line into two stacked rows ("T5,
      5/11" / a battery-level-matched SF Symbol + "77%"), replaced the
      generic HH:mm clock with a weekday+date format matching the
      screenshots exactly, and added a dashed-circle heading indicator
      below the speed (always shows "--" — there's no real compass/
      heading data source wired up, Vietmap Live's shared state file
      only has speed/limit; included for visual parity, not a feature
      claim). Also: the title bar (3 dots etc.) now hides itself once a
      real app-switcher snapshot is showing, matching screenshots where
      a *loaded* app has no such bar but a *still-loading/picker* one
      does.

## ⚠️ Architecture pivot (2026-11-05)

First real-CarPlay-hardware test of `hostApp:inContainer:` (the private
`SBApplicationController`/`SBSceneManagerCoordinator`/`SBAppViewController`
chain) came back: **the CarPlay screen just goes blank** when connected.
Most likely explanation: the VERIFIED part (creating a `UIRootSceneWindow`
on the CarPlay display) worked and took over the screen, but every
ADAPT-level call in `hostApp:` (resolving an application object, getting a
scene manager, fetching a scene handle, reading `appView`) silently failed
— so the window exists, is key/visible, and has nothing in it. That's
actively worse than not having the tweak at all (it breaks normal CarPlay
use while connected), so as of this version:

- [x] **`reloadFromPreferences` and `showLivePreviewOverlayWithLeft:right:`
      in `Tweak.xm` are both hard-disabled** (short-circuited with an
      early `return`, code left in place rather than deleted) — plugging
      into CarPlay with this tweak installed should now be a no-op again,
      same as not having it installed.
- [x] **Standalone companion app scaffolded** (`SplitCarPlayApp/`, a real
      Theos `application.mk` target, not a Settings preferences bundle)
      with SidePlay's own tab structure:
        - **Trang chủ** -- short status screen (current left/right pick,
          enabled state) + an honest banner that real on-car hosting is
          disabled right now.
        - **Trên xe** -- native UIKit re-implementation of the old
          Root.plist settings (app pickers, split ratio, bubble style/
          position/scale, speed-card toggles, source-app toggles) --
          same shared prefs file/keys, just a plain `UITableViewController`
          instead of PSSpecifiers now that there's no Settings-navigation
          constraint.
        - **Mô phỏng** -- the exact same preview (bubble styles, drag/
          pinch-resize, app-switcher snapshots, "Tab mới" empty state)
          ported from `Prefs.bundle/SplitCarPlayPreviewController.m`,
          minus the now-removed "thử chạy app thật" experiment.
        - **Tài khoản** -- stub (version/credits) -- SplitCarPlay has no
          account system and needs none; this tab exists only to match
          the shape.
      The grid-style "Chọn app..." picker is now a single shared
      `AppPickerController`, presented modally, reused by both "Trên xe"
      and "Mô phỏng" (previously two separate copies across different
      processes; this app is one binary, so genuine reuse is possible
      now). Installs a real SpringBoard icon via a `uicache` post-install
      hook. **Not yet tested on-device** -- built without access to a
      macOS/Theos toolchain locally, so this is unverified until CI
      builds it and it's actually installed. The real on-car split-screen
      mechanism is still an open question (see above); this app is the
      new home for picking apps, previewing, and (eventually)
      controlling that feature once there's a working replacement for
      the broken private-API path.

- [x] **"Mô phỏng" re-themed to match the reference screenshots' light
      look** — the screen (and the shared app picker) was dark-themed;
      SidePlay's actual screenshots are consistently light (white page,
      bold black "Mô phỏng" heading, light-gray app-box cards with a
      thin border instead of a shadow, dark text throughout). Also adds
      a real large heading label and hides the nav bar for this tab
      (the reference has no visible nav bar, just the big title). Kept
      deliberately at the layout/color level only — no logos, icons, or
      branding copied; see the "Explicitly not planning to copy" note
      below, which still applies.

- [x] **Diagnostic logging + explicit opt-in for the broken CarPlay path**
      — rather than keep guessing blind, `hostApp:inContainer:` and
      `activateOnDisplay:` now log every step (class resolution,
      intermediate return values, which `respondsToSelector:` check
      failed if any) to `/var/mobile/Library/Logs/splitcarplay_hosting.log`
      via the new `SplitCarPlayHostingLog` helper, and both are wrapped
      in `@try`/`@catch` — if a guessed selector's real signature is
      wrong, calling it used to risk an uncaught NSException crashing/
      respawning CarPlayApp (which, with no visible crash UI on a car's
      screen, could *look* like "just blank" to the driver); now it's
      caught and logged instead. The whole path stays off by default
      behind a new, separate `experimentalHostingEnabled` pref (not
      reusing `enabled`, so nothing can silently re-arm it) — surfaced
      in "Trên xe" as a clearly-labeled "⚠️ Bật thử nghiệm" switch plus
      a "Xem log debug" button that reads the log file in-app. Next
      real-CarPlay test should at minimum produce evidence of exactly
      which step fails, instead of nothing.

- [x] **Outer "car screen" frame around both app boxes** — the two app
      boxes now sit inside one shared light-gray bordered frame
      (`_carScreenFrame`, a `CGRectUnion` of both boxes' frames with
      some padding) instead of being two independent cards placed next
      to each other, representing the single physical CarPlay display
      they're splitting. Layout/color only.

## 0.6.0: review fixes (2026-11-08)

Corrections to entries above, after a code review:

- "Hard-disabled" was only half true: `reloadFromPreferences` was gated
  on `experimentalHostingEnabled`, not disabled, and `CarPlayEnableHook`
  ran unconditionally (adding a fake CarPlay entry for every third-party
  app). Both are now behind the experiment switch.
- "Auto-close Vietmap Live" never fired: its flag was read after the
  experiment gate. Fixed; also only fires when the CarPlay display is
  really gone, and Vietmap Live only quits itself while in the background.
- The pickers in Settings and in the app were separate copies, not one
  shared picker. Moot now: Prefs.bundle is gone.

Done in this version:

- [x] Hosting runs in SpringBoard only (the SB* classes don't exist in
      CarPlayApp; both processes used to build a window).
- [x] Fail-safes: window hidden until an app is attached, 6 s watchdog
      tear-down, ✕ button + two-finger long press on the car screen,
      one-shot arming, tear-down on exceptions, first reload deferred
      3 s after SpringBoard starts.
- [x] Milestone mode: one app full-width (`experimentalSingleApp`).
- [x] Hosting fixes: lay out before hosting, resize `appView` (not
      `appVC.view`), try both known `SBApplicationSceneHandleRequest`
      constructors, dump real method lists to the log on failure.
- [x] Flutter hook passes nil handlers through (no hung channels).
- [x] Prefs: one defaults table + CFPreferences everywhere
      (`SplitCarPlayShared.h`); fixes the app's 1.1 bubble-scale default
      and "(chưa chọn)" vs Maps/Music mismatch.
- [x] Speed state also published via Darwin notify state (no file
      access needed from sandboxed Vietmap Live).
- [x] Removed Prefs.bundle, the PreferenceLoader entry and dependency,
      the Settings injection and the dead "thử chạy app thật" overlay code.

Next:

- [ ] Run one car test; read `splitcarplay_hosting.log` to see which
      hosting step fails on iOS 15.8.8 and fix that selector.
- [ ] Possibly launch the app before fetching its scene.
- [ ] Show the speed card on CarPlay without the hosting experiment
      (needs its own small window on the CarPlay display).
- [ ] Replace the `com.example.*` package/prefs identifiers. Changing
      the package ID makes Sileo treat it as a new package and changing
      the prefs domain resets settings, so do it deliberately, once.

## CarPlay app-hosting foundation

- [x] **"Enable any app" layer** (`CarPlayEnableHook.xm`) — without this,
      `hostApp:inContainer:replacingExisting:` can likely only ever work
      for apps that already declare native CarPlay support (Maps, Music,
      Spotify, Waze, ...); resolving an arbitrary app like YouTube almost
      certainly fails at iOS's own CarPlay-eligibility check before scene
      creation is even attempted. Hooks `+[CARApplication
      _newApplicationLibrary]` and synthesizes a `CRCarPlayAppDeclaration`
      + a `"CarPlayEnable"` tag for every third-party app, grounded in the
      open-source (Apache-2.0) carplay-cast project. **Lower confidence
      than the SidePlay2.dylib-derived parts of this project** — I didn't
      have carplay-cast's literal source, only a paraphrased description
      of its class/property names (an AI tool declined to reproduce the
      file verbatim), so exactly how a declaration gets registered into
      the library object is a best-effort reconstruction, not confirmed.
      Logs every step to
      `/var/mobile/Library/Logs/splitcarplay_carplayenable.log` so a
      failure is debuggable rather than silent.

## Other

- [ ] **In-app notifications surfaced on the card** — still not
      attempted. Would need hooking `UNUserNotificationCenter`/adjacent
      private API *inside the source app's own process* to see its
      notifications, which is a separate, unresearched reverse-
      engineering task with no reference implementation to ground it in
      (unlike the Flutter-channel technique, which had gmaphud as a real
      example) — the riskiest remaining item, left for when there's an
      actual reference to check it against.

## Explicitly not planning to copy

- SidePlay2's actual compiled hook/rendering logic (their `.dylib`s) —
  not disassembled, not a goal. Everything above is reimplemented from
  scratch using public APIs where possible, same approach as the rest of
  this project.
