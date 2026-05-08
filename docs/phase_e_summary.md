# Phase E — Reliability — Summary

**Status (session 14 — 2026-05-08)**: **Phase E broadly landed**. Sessions 12 / 13 / 14 together took Phase E from "started E1" to "E1+ / E2 / E3 / E3-filter / E6 / E8 all green, plus E1+ energy assertion." 6 commits this session, 430 → 498 tests (+68).

The pre-show panel now reads as live data, records every operator + remote action with source attribution, persists checkpoints at meaningful operator moments, prevents the show machine from idle-sleeping, and warns on duplicate-open of NAS-shared show files. The remaining Phase E pickups are the deferred long-tail (dropped-frame instrumentation, take history, crash recovery, Director View, Workspaces, brightness adapt key) and a handful of fragile / privacy-blocked macOS-condition adapters.

---

## What shipped in session 14

### E8 — project lock file (spec §3.16 duplicate-open warning)

**`Services/ProjectLockFile.swift`** — pure-logic + IO seams. The lock at `<bundle>/.lock` is JSON: `{ pid, hostname, timestamp, applicationVersion }`. `liveness(now:currentPID:currentHostname:isPIDAlive:)` covers all five branches:

- `.ours` — same PID + hostname (idempotent reopen).
- `.localLive` — same hostname, different PID, `kill(pid, 0) == 0`.
- `.localStale` — same hostname, different PID, PID dead.
- `.foreignLive` — different hostname, timestamp within `foreignStaleAfter` (1 hour default).
- `.foreignStale` — different hostname, timestamp past the window.

`ProjectLockFileIO` (read / write / remove) takes injectable file-IO closures. `ProjectLockFileSignals.current()` reads `getpid()` + `gethostname()` + the bundle short-version string.

**`ProjectLockController`** is the per-document state machine over those primitives. `evaluate(bundleURL:)` reads → categorizes → either acquires (ours / stale) or surfaces a `foreignBanner` (live). `openAnyway()` overwrites the foreign lock with ours; `dismissBanner()` keeps editing without claiming. `release()` removes the lock and clears state.

**`Views/ProjectLockBannerView.swift`** mounts above `OutputStatusBar` with the foreign-lock summary (`Opened on <hostname> (PID N) at <date>`), an Open Anyway button, and a dismiss control.

**`SimplePlaybackProjectDocument`** owns the controller, KVO-observes `fileURL` so initial-open and Save-As both trigger `evaluate`, and `release()`s on `close`.

**Spec follow-up deferred**: the third "Read Only" option from spec §3.16 needs document-wide read-only enforcement (no edits → palette / show-list / inspector all gated). That's a substantial separate feature; today's two-button banner closes the duplicate-open *warning* requirement, not the read-only-mode requirement.

### E6 — autosave + Show-Mode checkpoint

`NSDocumentController.shared.autosavingDelay = 30` set in `AppDelegate.applicationDidFinishLaunching`. Combined with `SimplePlaybackProjectDocument.autosavesInPlace = true`, NSDocument's autosave-in-place writes the bundle every 30 s of pending edits.

**`Services/AutosaveCheckpointer.swift`** is the *checkpoint* side — a separate snapshot pinned to operator moments rather than time intervals. `writeCheckpoint(projectData:bundleURL:reason:)` writes `<bundle>/Autosave/<timestamp>__<reason>.json`. Filename is POSIX-UTC, no colons (SMB / exFAT-safe), reason-suffixed (`show_mode_on` / `show_mode_off` / `manual`). After every write, the directory is listed and the oldest items past the 20-item retention limit are pruned. Filename round-trip is symmetric so prune doesn't trust filesystem mtime (which drifts on networked volumes).

`SimplePlaybackProjectDocument.writeAutosaveCheckpoint(reason:)` encodes the project + calls the checkpointer; `RootView.handleShowModeChange` drives it via the existing `.onChange(of: showController.controller?.showMode)` hook. Initial nil → false (controller becoming available on document load) is suppressed by tracking `lastShowMode` in `@State`.

### E4 — show-log filter UI

`ShowLog.SourceFilter` (All/Local/OSC/HTTP/TC/System — Local groups `localHotkey + operatorButton`) and `ActionFilter` (All/Show verbs/Remote API/System) are pure-logic predicates with one `matches(_:)` case per source/action variant. `ShowLog.filteredEvents(source:action:since:)` ANDs them with an optional `since` cutoff for "events after this Date" filtering.

`ShowLogView` mounts a top toolbar with three menu pickers + a Reset button (visible when any filter is active). The header label switches from `N events` to `N of M events` when filtered. Empty filtered result renders a distinct `ContentUnavailableView` so an empty filter doesn't read as an empty log.

### E1+ — no-idle-sleep IOPM assertion

**`Services/EnergyAssertion.swift`** wraps `IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep)` + `IOPMAssertionRelease` behind injectable `assertor` / `releaser` closures so unit tests can pin the state machine without engaging the kernel. Acquire + release are idempotent. The assertion name `Simple Playback — Show Mode` is what operators see in `pmset -g assertions`.

`RootView.handleShowModeChange` engages the assertion on Show Mode → on, releases on Show Mode → off. Unlike the autosave checkpoint, the assertion does NOT suppress the initial nil → false load — Show Mode flipping true on the first observation should land the assertion immediately.

`PreShowCheck.evaluateEnergy(context:)` is a new optional row driven by `Context.systemPreventsIdleSleep` — `RootView.preShowCheckContext` samples `energyAssertion.isHeld` into the field. Pre-show panel reads OK when Show Mode is on, warning when off.

---

## Tests added (session 14)

| Test file | Tests | What it covers |
|---|---|---|
| `ProjectLockFileTests` | 17 | Liveness branches (5) + IO seams + banner copy + signals smoke |
| `ProjectLockControllerTests` | 13 | State machine: acquire / refresh / openAnyway / dismiss / release / URL change |
| `AutosaveCheckpointerTests` | 13 | Filename round-trip + prune (limit / 1-keeps-latest / malformed-ignored) + writer plumbing |
| `ShowLogFilterTests` | 15 | Source / Action / combined / since predicates |
| `EnergyAssertionTests` | 7 | Acquire idempotent + release idempotent + failure path + reacquire + assertion-name pin |
| `PreShowCheckTests` (extended) | 3 | Energy row suppressed / OK / warning |

Total: **498 tests, all green** (was 430 at session start; +68).

---

## Manual verification needed (session-14 deltas)

1. **Project lock file — same-host duplicate open**: open a saved `.spb` project. Verify `<bundle>/.lock` exists and contains your pid + hostname. Open the same project a second time (e.g., Cmd-O on the file). The banner reads "This show is open elsewhere — Opened on <hostname> (PID <N>) at <date>". Click Open Anyway; the lock is overwritten with the new instance's pid (verify via `cat <bundle>/.lock`). Close the second window; the lock is removed. Reopen the first window's project; lock returns.
2. **Project lock file — close releases**: open a project. Quit the app. Verify `<bundle>/.lock` is gone after quit.
3. **Project lock file — stale local PID**: write a synthetic lock with `pid: 99999, hostname: <yours>` (use a small Swift test or `echo` JSON). Open the project. Banner should NOT appear (PID is dead → stale → silently overwritten with our lock). Verify the lock now has our pid.
4. **Project lock file — foreign-host live**: write a synthetic lock with `hostname: someotherhost.local, timestamp: <now>`. Open the project; banner appears. Click Dismiss; the foreign lock stays in place (verify via `cat`). Click Open Anyway; the lock now reads our hostname.
5. **Autosave — 30 s rolling**: open a project, edit a slide title, idle 35 s. Verify the bundle's `Show.json` mtime advanced. (NSDocument writes back to the bundle URL once `autosavingDelay` elapses with pending edits.)
6. **Autosave — Show-Mode checkpoint**: open a project. Toggle Show Mode on. Verify `<bundle>/Autosave/<timestamp>__show_mode_on.json` was created. Toggle off; verify `<timestamp>__show_mode_off.json`. Repeat 21 times; verify only the newest 20 remain.
7. **Show-log filter — narrow live show**: open a project, fire a few cues via the local UI, fire a few via OSC (`oscsend localhost 53000 /sp/go ,s "Q1"`). Open the show log viewer. Pick Source = OSC; only the OSC rows render and the header reads "N of M events". Reset; full log returns.
8. **Show-log filter — Since window**: open a project, fire a cue, wait 90 s, fire another. Pick Since = "Last minute"; only the second cue renders.
9. **Energy assertion — pmset visibility**: open a project, toggle Show Mode on. Run `pmset -g assertions` in Terminal. Look for a `NoIdleSleep` assertion named `Simple Playback — Show Mode`. Toggle Show Mode off; the assertion drops. Verify on a laptop on battery: with Show Mode on, the system should not idle-sleep even after the configured idle timeout elapses.
10. **Pre-show energy row**: open Pre-Show. With Show Mode off the row reads `.warning` ("macOS could idle-sleep mid-show — Show Mode engages a no-idle-sleep assertion"). Toggle Show Mode on, reopen Pre-Show; row reads `.ok`.

---

## Still deferred (session 15+)

- **Pre-show E1+ macOS-condition tail** — DND, screensaver, Spotlight, Time Machine. Each is fragile or privacy-blocked on modern macOS:
  - DND / Focus: privacy-restricted; requires private API or Apple Events to System Events.
  - Screensaver: `defaults read com.apple.screensaver askForPassword` reads user defaults, not active state.
  - Spotlight: `mdutil -s <volume>` via Process; output parsing is brittle.
  - Time Machine: `tmutil status` similarly Process-spawned + parsed.
  - Recommendation: ship these as a pack only after picking one fragile-but-acceptable strategy, and only if real-rehearsal shows operators want them.
- **E3+ — dropped-frame + late-take instrumentation** — both events listed in spec §3.16 but require instrumentation in `PlaybackController` (compositor frame timing, dropped-frame counter — A9 dropped-frame counter is currently deferred too) and `CueRuntime` (late-take: GO arrived but cue didn't fire within N ms). Independent of the writer infrastructure already shipped.
- **E5 — take history (recent 200) with replay scrub** — separate surface from the show log. Replay needs the runtime to accept "fire cue X with the original parameters at this offset."
- **E7 — crash recovery on next launch** — load the last autosave with a "what changed since last save" summary. Today no UI surface for that.
- **E8 read-only-mode** — third banner option from spec §3.16. Needs document-wide read-only enforcement (palette + show list + inspector + drop-targets all gated; show control over OSC/HTTP also drops to read+fire). Substantial standalone feature.
- **E9 — Director View tear-off window** — read-only Program + next 3 + notes. Multi-display.
- **E10 — Saved Workspaces** — Edit / Rehearsal / Show / Single-Screen. UX-design heavy; product blocker territory.
- **E11 — Brightness adapt key** — booth-dim key separate from system brightness.
- **E12 — Phase E summary + manual rehearsal steps** — the cleanup pass at the end of E.

---

## Recommended next pick

- **E3+ dropped-frame counter (A9 too)** — the show log can now record a `.droppedFrame` event, but `PlaybackController` doesn't emit one yet. Wiring a Published `droppedFrameCount` + a status-bar chip is a contained Phase B/E intersection. ~2 commits.
- **E5 take history (in-memory v1)** — a circular buffer of the last 200 cue fires with timestamp + cue id + duration. Replay scrub deferred. ~1–2 commits.
- **C7 (asset library — linked vs managed media + security-scoped bookmarks)** — Phase C tail. Foundation for C8 / C9 / C10 / C11 and the deferred E2 `media.resolution` Fix handler.
- **B7 (DeckLink format negotiation)** — Phase B leftover, hardware-bound.

Phase B leftovers (B7, B11, B13) and Phase C tail (C7+) remain background work that can be picked off between Phase E iterations.

---

## Session 13 deltas (recap — see git log f4474bb for full text)

Session 13 shipped E1+ live system-signal adapters (DeckLink lock state, audio device, render-path-warmed), E2 per-row Fix actions (audio Sound deep-link, disk Finder reveal, reference DVS launch), and E3 end-to-end (CSV writer + ShowController + dispatcher integration + read-only viewer + toolbar entry). 9 commits, 383 → 430 tests (+47).

## Session 12 deltas (recap)

Session 12 shipped C5c (Add Folder folder-drop UX), Option B (Show-Mode gate on inline transcode), Option E (Apple-events deep-link on import banner), E1 first slice (PreShowCheck pure-logic + sheet UI + toolbar entry), and a cancel-cleanup partial-file fix. 11 commits, 372 → 383 tests.
