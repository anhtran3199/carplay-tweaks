# SplitCarPlay — feature roadmap

Checklist of ideas pulled from studying SidePlay2's real, shipped
Settings UI (metadata/plist structure only — `.deb` downloaded from
sideplay.pages.dev, control/Root.plist/Entry.plist/license files read for
reference; their compiled `.dylib`/binary logic was deliberately **not**
disassembled, since it's a commercial product). SidePlay2 itself credits
[GMapHUD](https://github.com/bechou0410/gmaphud) in its own Settings
footer — the same open-source project `VietmapLiveHook.xm` is grounded
in, so this list builds on work already validated as the right direction.

Nothing here is started yet unless checked off. Pick items in any order —
they're independent of each other.

## Speed card

- [ ] **Over-speed-limit audio alert** — play a short tone when current
      speed exceeds the limit. Public API (`AudioServicesPlaySystemSound`
      or `AVAudioPlayer`), no extra entitlement/private API needed. Likely
      the easiest item on this list.
- [ ] **Show date on the card** — `NSDate`/`NSDateFormatter`, fully public.
- [ ] **Show battery % on the card** — `UIDevice.batteryLevel` (needs
      `batteryMonitoringEnabled = YES`), fully public.
- [ ] **Multiple card "looks"** — SidePlay2 ships several shapes (bar,
      horizontal, vertical, ring) × light/dark variants, picked in
      Settings. Ours only has the one rounded-rect card shape today;
      would need a few alternate `SpeedBubbleView`-style layouts plus a
      Settings picker (`PSLinkListCell`, same pattern as their "Nguồn dữ
      liệu" source picker below).
- [ ] **Now-playing music widget on the card** — show track/artist and
      maybe playback controls. `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter`
      are public frameworks; feasible without new private API surface.

## Data source

- [ ] **Multiple speed-source apps, not just Vietmap Live** — SidePlay2
      supports VietMap Live, Waze, GOFA, and WYN, each via its own hook
      dylib, selectable in Settings (`PSLinkListCell` + `validTitles`/
      `validValues`, same pattern already used informally in our
      `Root.plist`). Waze and GOFA are NOT Flutter apps like Vietmap Live
      — each would need its own reverse-engineered hook (different
      mechanism per app, not a drop-in reuse of `VietmapLiveHook.xm`).
      Biggest single item here; worth doing one additional source at a
      time, Waze first (most commonly used alternative).
- [ ] **Keep the source app alive in the background** ("Giữ app nguồn
      chạy nền") — likely a private API (something like preventing
      suspension / background task extension). Not yet researched.
- [ ] **Auto-exit the source app when CarPlay disconnects** — simpler:
      already have the `UIScreenDidDisconnectNotification` hook pattern
      in `Tweak.xm`; just needs to additionally terminate/background the
      source app via a documented-enough mechanism (e.g.
      `-[UIApplication suspend]`-style private call, or a plain
      `exit(0)` sent to that app's process) once device-tested.

## Other

- [ ] **In-app notifications surfaced on the card** — showing e.g.
      message previews. Likely needs hooking `UNUserNotificationCenter`/
      `SBNotificationCenter`-adjacent private API inside the source app's
      process; not yet researched, probably the riskiest item here.

## Explicitly not planning to copy

- SidePlay2's actual compiled hook/rendering logic (their `.dylib`s) —
  not disassembled, not a goal. Everything above is reimplemented from
  scratch using public APIs where possible, same approach as the rest of
  this project.
