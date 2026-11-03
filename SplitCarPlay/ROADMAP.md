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
- [x] **Preview/simulation screen** — Settings → "Mô phỏng (Preview)"
      renders the real bubble (all 3 styles, switchable live) plus
      placeholder app boxes, without needing an actual CarPlay
      connection — same idea as Vietmap Live's own "Mô phỏng" tab and
      SidePlay2's static mockup images. Uses live Vietmap data when
      available, clearly-labeled demo numbers otherwise. See
      `Prefs.bundle/SplitCarPlayPreviewController.m`.

## Data source

- [ ] **Multiple speed-source apps, not just Vietmap Live** (Waze, GOFA,
      WYN). **Deliberately not attempted** — Waze and GOFA aren't Flutter
      apps like Vietmap Live, so `VietmapLiveHook.xm`'s technique doesn't
      transfer; each needs its own from-scratch reverse-engineering
      (unknown mechanism per app) the way Vietmap Live's was done
      earlier in this project. Guessing a hook mechanism blind for an
      app we have no reference for is how the UILabel-scraping v1 of
      `VietmapLiveHook.xm` went wrong the first time — not repeating that
      without something to ground it in. Settings already explains this
      (see the "Source App" group's footer text).
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
