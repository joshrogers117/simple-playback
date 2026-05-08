# Phase E — Reliability — Summary

**Status (session 19 — 2026-05-08) — E3+ Path 1 callback upgrade shipped**. The session-18 Path-2 limitation (image cues always read as on-time because `liveSlideID` flips synchronously inside `take(...)`) is closed. New `PlaybackController.onFirstComposedFrameForCue` callback fires exactly once per `take(...)` when the first composed frame for that take reaches `submitFrame`. ShowController's `wireLateTakeDetector` now subscribes to that callback instead of `playback.$liveSlideID`. Both image and video cues get accurate first-frame-reached-output latency.

Mechanics:
- `PlaybackController._pendingCueFireSlideID` (lock-protected) is armed in `take(slide:)` next to the `liveSlideID = slide.id` assignment, plus the same arming in the two transition-commit paths (`commitPreparedVideoTransition` / `commitPreparedImageTransition`). `clear()` and `stopOutput()` drop the token before any black-frame submit so a stale arm doesn't masquerade as the cleared cue's first frame.
- `submitFrame` consumes the token after a successful submit and dispatches `(slideID, Date())` to main via `onFirstComposedFrameForCue`. One-shot — subsequent frames in the same take don't refire.
- ShowController's bridge entry point `handleLiveSlideTransition(slideID:now:)` is unchanged so the existing `ShowControllerLateTakeLogTests` (6 cases — pinned in the runbook) survive the refactor.

Tests: `PlaybackControllerCueFireTests` (6 new cases — arm + simulate fires once with the right slideID; subsequent simulations on the same take don't refire; no fire when token isn't armed; stopOutput drops the token; clear() drops the token; missing callback leaves the token armed so a late-attached callback still receives its inaugural emission). Test seams `armPendingCueFireSlideIDForTesting`, `peekPendingCueFireSlideIDForTesting`, `simulateFirstComposedFrameForTesting` let the suite drive the contract without going through AVFoundation.

---

**Status (session 18 — 2026-05-08)**: **Late-take live integration (E3+ tail) shipped**. The session-17 pure-logic `LateTakeDetector` is now wired through ShowController:

- `handleCueFired` calls `lateTakeDetector.recordGoFired(cueID:, slideID:, at: Date())` just before `playback.take(...)`. The cue's number-or-title is cached in `pendingLateTakeCueDescriptor` so the eventual log entry can name the cue.
- `playback.$liveSlideID` Combine sink hops to the main queue and calls `handleLiveSlideTransition(slideID:now:)` on the first non-nil publish. The bridge calls `recordFrameSubmitted(slideID:, at:)`; late verdicts append a `.lateTake` show-log event with detail `latency=Nms cue=<descriptor>` (source `.system`).
- `onPanicChanged(active: true)` calls `lateTakeDetector.clearPending()` + clears the descriptor cache so an interrupted take doesn't leak into the next GO's measurement.

**Path-2 limitation** (matches the session-17 deferred note): `liveSlideID` flips synchronously inside `take(...)` for image cues — they always read as on-time. For videos the flip happens after `AVPlayerItemVideoOutput` preparation, so per-take video load latency IS measured. A future "first composed frame for cue X reached SDI" callback would tighten the measurement; today the proxy at least catches operator-visible video-load delays.

Tests: `ShowControllerLateTakeLogTests` (6 cases — late vs on-time emission, no-pending gate, slide-mismatch keeps pending alive, PANIC clears pending, second GO supersedes first). The bridge exposes `setPendingLateTakeCueDescriptor(_:)` and `clearPendingLateTakeCueDescriptorForTesting()` test seams + a public `handleLiveSlideTransition(slideID:now:)` so tests can drive the bridge by injecting an explicit `now` rather than synthesizing a real publish.

---

**Status (session 16 — 2026-05-08)**: Phase E gets a small but high-value addition tied to C7's new asset-library primitives — Pre-Show now has a `media.files` row that flags slides whose linked file is offline (error) or whose size/mtime drifted since import (warning). The same row carries a Fix button (E2) that opens NSOpenPanel and runs the C7c MediaResolver waterfall against the chosen folder, splicing resolved URLs back into `project.slides` with refreshed fingerprints. This closes the long-deferred E2 `media.resolution` Fix gap. Late-take detection (E3+ tail) remains deferred — needs a "first frame submitted for cue X" callback that PlaybackController doesn't expose yet.

**Status (session 15 — 2026-05-08)**: **Phase E mostly landed**. Session 15 picked off the four most contained leftovers: E3+ dropped-frame counter, E5 take history (in-memory v1), E7 crash recovery on next launch. 4 commits, 498 → 543 tests (+45).

The reliability surface now covers: pre-show check (live signals + Fix actions); show log (writer + filter UI); autosave (rolling + checkpoint); project lock (duplicate-open warning); no-idle-sleep (energy assertion); dropped-frame instrumentation (status chip + debounced log entries); take history (last 200 fires, viewer sheet); crash recovery (Restore/Discard banner on autosave-newer-than-Show.json).

Remaining Phase E pickups are the long-tail UX features (Director View, Workspaces, brightness adapt, late-take detection) plus a handful of fragile / privacy-blocked macOS-condition adapters and the E8 read-only-mode banner option.

---

## What shipped in session 15

### E3+ — dropped-frame counter

**`Services/DroppedFrameCounter.swift`** — pure-logic. `record(count:at:)` appends timestamps and accumulates; `observe(now:)` re-prunes the rolling window without recording; `reset()` clears both axes. Window default 10 s. Out-of-order timestamps (host-clock adjustment, batch flush after a stall) are handled via full-list filter rather than monotonic assumption.

`PlaybackController.detectAndRecordDroppedFrames(at:)` runs at the top of `renderCurrentVideoFrame` (gated to non-`forceCurrentTime` paths). Compares `CACurrentMediaTime()` to the prior tick; deficit > 1.5× `activeFrameInterval` records `floor(delta/interval) - 1` drops via `Task { @MainActor }` to satisfy the counter's actor isolation. Counter resets on `stopOutput`; `lastTimerTickHostTime` is reset on every `startVideoTimer` so a take boundary never reads as a drop.

`OutputStatusBar.droppedFrameChip` — hidden when cumulative=0; orange + warning glyph when rolling > 0; secondary + checkmark when cumulative > 0 but rolling = 0 (drops earlier in the session, recovered now). Tooltip explains the two numbers.

`ShowController.handleDropCumulative(_:now:)` is the pure-logic debounce. Combine subscription on `playback.droppedFrameCounter.$cumulative` (with `receive(on: .main)`) calls it with `Date()`. First burst emits a `.droppedFrame` log entry immediately; further publishes within `dropFlushInterval = 1 s` are suppressed and accumulate; the next emission past the window batches the deficit. Counter reset re-baselines without a phantom event.

### E5 — take history (in-memory v1)

**`Services/TakeHistory.swift`** — bounded chronological buffer. `TakeHistoryEntry { id, timestamp, cueID, cueNumber, cueTitle, durationSecondsAtFire? }`. Capacity defaults to 200; clamped to ≥1; `append` drops oldest on overflow. `cueTitle`/`cueNumber` are copied at fire time so renaming or deleting a cue doesn't rewrite history. `recordFire(cue:durationSecondsAtFire:)` is the convenience entry point used by `ShowController.handleCueFired` (samples `playback.videoDuration` — nil for images / pre-resolution).

**`Views/TakeHistoryView.swift`** — read-only sheet. Toolbar button on the main window reveals it; rows render newest-first (`history.latestEntries`) with timestamp / cue number / title / duration. Empty-state uses `ContentUnavailableView`. **Replay scrub deferred** — runtime would need a "fire cue X with original parameters at offset" entry point that doesn't exist.

### E7 — crash recovery on next launch

**`Services/CrashRecoveryDetector.swift`** — pure-logic detector. `findRecoverableCheckpoint(bundleURL:)` lists `<bundle>/Autosave/`, parses each filename via `AutosaveCheckpoint.parse`, and returns the newest checkpoint *strictly newer* than Show.json's mtime. Equal mtimes don't trigger (clean Show-Mode-toggle saves write the checkpoint and Show.json simultaneously). Missing autosave directory / unparseable filenames / older checkpoints all return nil. `readCheckpointData(bundleURL:filename:)` reads bytes; `discardCheckpoints(bundleURL:)` removes the directory.

**`Views/CrashRecoveryBannerView.swift`** holds both the `CrashRecoveryController` (`evaluate / loadRecoverableData / didRestore / discard`) and the banner (yellow background, "Autosave newer than saved project — Snapshot from <date> (<reason>)", Restore / Discard buttons).

**`SimplePlaybackProjectDocument`** owns the controller, KVO-observes `fileURL` (same hook used for E8), implements `restoreProjectFromRecoverableCheckpoint()` that decodes the checkpoint via `JSONDecoder.simplePlayback`, replaces `playbackDocument.project`, marks the doc dirty (so the next save persists the recovered state), and notifies the controller. RootView's banner Restore button calls back into the document via the injected `restoreFromCheckpoint: () -> Bool` closure.

**"What changed" summary deferred** — the v1 banner ships Restore + Discard. A future iteration can compute a diff between the checkpoint and Show.json and surface "5 cues changed, 2 added" in the banner copy.

---

## Tests added (session 15)

| Test file | Tests | What it covers |
|---|---|---|
| `DroppedFrameCounterTests` | 12 | Initial state / record / record≤0 noop / cumulative monotone / window-edge inclusive / window-eviction / observe-only prune / reset / sliding window / out-of-order / batched record |
| `ShowControllerDroppedFrameLogTests` | 7 | First burst emits / debounce inside window / batched delta on next burst / reset re-baselines / new burst after reset / zero-cumulative no-emit / end-to-end via Combine |
| `TakeHistoryTests` | 9 | Append below capacity / drop oldest at cap / capacity across 400 / capacity ≥1 clamp / latestEntries reverses / reset / recordFire captures / mutated cue not reflected / unique IDs |
| `CrashRecoveryDetectorTests` | 10 | Missing dir / empty / unparseable / no Show.json / all older / equal mtime / strictly newer / mixed parseable+garbage / read bytes / discard removes dir |
| `CrashRecoveryControllerTests` | 7 | Nil URL clears / detector candidate / reader plumbing / reader-throws nil / didRestore clears / discard plumbing / discard swallows error |

Total: **543 tests, all green** (was 498 at session start; +45).

---

## Manual verification needed (session-15 deltas)

1. **Dropped-frame chip — clean show**: open a project, take a slide, watch the status bar — chip should remain hidden. Toggle through several cues; chip stays hidden as long as no drops are detected.
2. **Dropped-frame chip — induced stall**: with a video cue running, deliberately stress the system (open Activity Monitor's "All Processes, Hierarchically" and let it CPU-pin a core; or run `yes >/dev/null` in Terminal). The chip should appear, escalate to orange when a stall happens, and return to secondary checkmark when rolling resets to 0 after 10 seconds.
3. **Dropped-frame log debounce**: with a video cue running, induce a stall. Open the show log — there should be at most one `.droppedFrame` row per ~1 s of stall, with detail `drops=N cumulative=M`. Long stall → still one row per second, not one per frame.
4. **Dropped-frame counter resets on output stop**: after drops have accumulated, click "Clear Output". The chip disappears. Take another cue; chip stays hidden until new drops happen.
5. **Take history — empty / first take**: open a fresh project. Click Take History; sheet shows "No takes yet". Take a cue; reopen — one row with that cue's number/title.
6. **Take history — capacity**: in a project with at least one cue, fire it 250 times via OSC or by repeated GO. Open Take History; should show exactly 200 rows, most recent at top.
7. **Take history — title pin**: fire a cue named "Opener". In edit mode, rename the cue to "Renamed". Take History should still show "Opener" for the prior fire.
8. **Crash recovery — happy path**: open a saved `.spb` project. Toggle Show Mode on (writes a checkpoint), then toggle off (writes another). Force-quit the app (`kill -9 <pid>` from Terminal). Reopen the project. The yellow recovery banner should appear above OutputStatusBar with "Snapshot from <recent date> (Show Mode off)". Click Restore; the project state from the checkpoint loads. Save; the banner stays away on next reopen.
9. **Crash recovery — Discard path**: same setup as #8 but click Discard on the banner. Verify `<bundle>/Autosave/` is gone (`ls <bundle>/Autosave` → "No such file or directory"). Reopen the project; banner does not appear.
10. **Crash recovery — equal mtime no banner**: open a saved project. Toggle Show Mode on, then save normally (Cmd-S). Force-quit and reopen. The banner should NOT appear (the autosave timestamp is older than the post-Save Show.json mtime).
11. **Crash recovery — restored doc is dirty**: Restore from a checkpoint. The window title should show the unsaved-changes dot; Cmd-S writes the recovered state to Show.json.

---

## Still deferred (session 16+)

- **Pre-show E1+ macOS-condition tail** — DND, screensaver, Spotlight, Time Machine. Each is fragile or privacy-blocked on modern macOS. Same status as session 14.
- **E3+ tail — late-take detection** — show log can record dropped frames now; "GO arrived but cue didn't fire within N ms" is an independent cue-runtime instrumentation that hasn't been wired.
- **E5 — replay scrub** — sheet shows the history; the runtime can't yet "fire cue X with original parameters at offset Y." Needs a new runtime entry point.
- **E7 — "what changed" summary** — banner today says "snapshot from <date> (<reason>)". A future iteration could decode the checkpoint and Show.json, diff them, and surface "5 cues changed, 2 added" in the banner.
- **E8 read-only-mode** — the third banner option from spec §3.16 still needs document-wide read-only enforcement. Same status as session 14.
- **E9 — Director View tear-off window** — read-only Program + next 3 + notes.
- **E10 — Saved Workspaces** — Edit / Rehearsal / Show / Single-Screen.
- **E11 — Brightness adapt key** — booth-dim key separate from system brightness.
- **E12 — Phase E summary cleanup pass** — the closing summary doc.

---

## Recommended next pick

- **C7 (asset library — linked vs managed media + security-scoped bookmarks)** — Phase C tail. Bigger surface than Phase E pickups but unlocks C8 / C9 / C10 / C11 and the deferred E2 `media.resolution` Fix handler. Multi-session.
- **B7 (DeckLink format negotiation)** — Phase B leftover; hardware-bound for verification.
- **E9 Director View** — read-only tear-off window. Needs UX decisions about layout (product blocker territory if not already specified — re-read §3 for guidance).

---

## Session 14 deltas (recap — see git log e129164 for full text)

Session 14 shipped E8 (project lock file at `<bundle>/.lock` with five-state liveness + foreign-lock banner + NSDocument lifecycle wiring), E6 (30s autosave-in-place + Show-Mode checkpoint), E4 (filter UI on the show-log viewer), E1+ (no-idle-sleep IOPM assertion in Show Mode). 6 commits, 430 → 498 tests (+68).

_(See "What shipped in session 15" below for the latest deltas.)_

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
