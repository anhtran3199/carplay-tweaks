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
