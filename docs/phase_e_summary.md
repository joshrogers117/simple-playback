# Phase E — Reliability — Summary

**Status (session 13 — 2026-05-08)**: **Phase E meaningfully advanced**. E1 (pre-show check) is now end-to-end with live system signals — DeckLink lock state, audio device, and render-path-warmed are all sampled and feed into the evaluator. E2 (per-row Fix actions) shipped the first slice of system-deep-link handlers. E3 (show log) shipped end-to-end: append-only CSV writer, ShowController integration for every verb (GO / PREVIOUS / PANIC / CLEAR / BLACKOUT / Show-Mode / missing-media), dispatcher integration so OSC / HTTP / TC actions are recorded with their source attribution, and a read-only viewer with CSV export. Tests: 383 → 430 (+47 across 9 commits this session).

The Pre-Show panel now reads as live data on a real machine, not a hand-supplied Context — the operator opens it and sees actual disk space, an actual audio-device check, an actual DeckLink REF state if armed, and an actual render-path-warm/cold signal. The Show Log panel now records every operator action with source attribution (local UI / OSC ip:port / HTTP token suffix / TC) for replay and forensics.

---

## What shipped in session 13

### E1+ — system-signal adapters

**`Services/PreShowCheckAdapters.swift`** — `PreShowCheck.DeckLinkReferenceStatus.from(_:)` translates `DeckLinkTransportSink.ReferenceState` into the pure-logic enum. RootView's `preShowCheckContext()` plumbs `playback.deckLinkReferenceState` (the same source the B6 status-bar chip reads) through the adapter. Reference rows escalate from `.info` ("not yet sampled") to live data once the DeckLink is armed.

**`Services/AudioDeviceProbe.swift`** — `AudioDeviceProbe.isDefaultOutputDeviceAvailable()` wraps `kAudioHardwarePropertyDefaultOutputDevice` behind an injectable provider. Production reads the system answer; tests pin both branches without mutating host audio.

**`PlaybackController.hasRenderedAnyFrame`** — Published bool that flips true on the first successful `submitFrame` and clears on `stopOutput()`. Plumbed into `PreShowCheck.Context.renderPathWarmed`; new `evaluateRenderPath` rule emits OK when warm, warning when cold.

### E2 — fix actions per row

**`Services/PreShowCheckFixHandlers.swift`** — `PreShowCheckFixHandlers` is a dictionary keyed by `PreShowCheck.Row.id`. Pre-Show view renders a "Fix" button only for rows the host has registered something for; rules without a sensible automatable resolution stay read-only. RootView wires three handlers:

- `system.audio` → `x-apple.systempreferences:com.apple.preference.sound`
- `system.disk` → `NSWorkspace.shared.activateFileViewerSelecting([bundleURL])` (suppressed for untitled documents)
- `output.reference` → opens `/Applications/Blackmagic Desktop Video Setup.app` if installed (suppressed otherwise — the operator path is hardware-side at that point)

`media.resolution` deliberately has no Fix handler this iteration; the relink path belongs to C7 (asset library). `fps.conformance` and `output.tenBit` are project-edit territory the operator addresses inside the app.

### E3 — show log

**`Services/ShowLog.swift`** — `ShowLogEvent` (timestamp + optional chase TC + action + source + optional detail) and `ShowLog` ObservableObject. Source attribution is first-class: every event records *who* fired it (local hotkey / operator UI button / OSC `host:port` / HTTP token-suffix-only / TC / system). RFC 4180 CSV serialization; `ShowLog` seeds a header row when binding to a fresh URL and appends one CSV line per event. File-writer is injectable for testability — production uses a FileHandle append; failed writes drop the URL but keep the in-memory log alive (a transient I/O error doesn't lose events).

**`ShowController` integration** — Each verb method now records a corresponding event. Default source `.operatorButton` keeps existing UI call sites compiling unchanged; hotkey / OSC / HTTP / TC sites can override. `handleCueFired` missing-asset path logs a `.missingMedia` event with `.system` attribution. `weak var showLog: ShowLog?` is set by RootView after configuration; tests construct an isolated log directly.

**Dispatcher integration** — `ShowControlSource.toShowLogSource()` extension translates the dispatcher's source enum (HTTP tokens collapse to their last 4 characters so a leaked log file can't be replayed). ShowController sets `ShowControlHub.shared.stack.dispatcher.onActionDispatched = { ... }` to its own `recordDispatchedAction`; verbs map onto the matching `ShowLog` action; non-verb cue / output / TC / workspace actions collapse onto a generic `.oscAction` row with a short human-readable name. Diagnostic chatter (ping / subscribe) deliberately never logs.

**`Views/ShowLogView.swift`** — Read-only viewer rendering the per-document log as a chronological list (timestamp / TC / action / source / detail). High-signal actions get colour: PANIC + MISSING_MEDIA red, CLEAR + BLACKOUT orange, GO/PREVIOUS primary, Show-Mode accent, OSC chatter secondary. Empty state renders a `ContentUnavailableView`. Export CSV button funnels `ShowLog.exportCSV()` into an `NSSavePanel`; the action is swappable for tests.

**RootView wiring** — Per-document `@StateObject ShowLog` instance; bound to `<bundle>/Logs/<yyyy-MM-dd>.log` once the document has a fileURL on disk. Untitled documents keep events in memory until the first save. Toolbar "Show Log" button (`list.bullet.rectangle`) opens the viewer sheet.

---

## Tests added (session 13)

| Test file | Test | What it covers |
|---|---|---|
| `PreShowCheckTests` | `testDeckLinkAdapterMaps{Idle,NotSupported,Unlocked,Locked}` | Adapter mapping pinned per-case. |
| `PreShowCheckTests` | `testRenderPathRow{Suppressed,OKWhenWarmed,WarningWhenCold}` | Render-path rule's three states. |
| `AudioDeviceProbeTests` | 4 tests | Probe-level branches + real-CoreAudio smoke. |
| `PreShowCheckFixHandlersTests` | 7 tests | Dispatch behaviour + URL contracts (Sound deep-link, DVS path). |
| `ShowLogTests` | 12 tests | CSV shape, source labels, in-memory append, file-writer hook (header on first write, append after, failure suppression). |
| `ShowControllerLogTests` | 14 tests | Verb-level logging (8) + source translation (5) + dispatcher integration (5) + missing-media. |

Total: **430 tests, all green** (was 383 at session start; +47).

---

## Manual verification needed (session-13 deltas)

1. **Pre-Show DeckLink rows** — open Pre-Show with a DeckLink armed and `expectsExternalReference == true`; the reference row should escalate from `.info` ("not yet sampled") to live data (locked → `.ok`, unlocked → `.error`, notSupported → `.warning`).
2. **Pre-Show audio row** — open Pre-Show on a host with built-in speakers; the audio row should read `.ok`. Disconnect every audio device (rare in practice — virtual machines or headless minis) and the row should read `.error`.
3. **Pre-Show render-path row** — open Pre-Show on a fresh document with output armed but no cues fired yet; row reads `.warning`. Fire a cue, reopen Pre-Show; row reads `.ok`. Stop output; row goes back to `.warning` on next open (since `hasRenderedAnyFrame` clears on stopOutput).
4. **E2 Fix actions**:
   - Click "Fix" on the audio row when it's `.error` — System Settings → Sound should open.
   - Click "Fix" on the disk row when the document is saved — Finder should reveal the project bundle.
   - Click "Fix" on the reference row with Blackmagic Desktop Video Setup installed — DVS should launch.
   - Untitled document: the disk row's Fix button should not appear.
   - Without Blackmagic Desktop Video Setup installed: the reference row's Fix button should not appear.
5. **Show Log viewer** — open the viewer toolbar button. With no events, empty-state renders. Fire a cue; the GO row appears. Hit Escape (panic); a PANIC row appears in red. Toggle Show Mode twice; the SHOW_MODE_ON / SHOW_MODE_OFF rows appear.
6. **Show Log CSV export** — click "Export CSV…" with events present. Save to a `.csv` file. Open in any spreadsheet; verify the header row + one row per event with the five-column shape.
7. **Show Log on-disk persistence** — save a project. Fire a cue. Inspect `<bundle>/Logs/<today>.log` — the file should contain the CSV header + the GO row. Quit and reopen the project; old events are not re-loaded into the in-memory list (the file is the source of truth for past sessions; the view is the source of truth for the current session). The next event appended writes to the same file (today) or a fresh dated file (next day).
8. **OSC source attribution** — fire a cue via OSC from a remote IP. The event in the log should read `osc <host>:<port>` for source. Same path via HTTP should read `http …<last4>`.

---

## Still deferred (session 14+)

- **Pre-show E1+** — macOS energy / DND / screensaver / Spotlight / Time Machine checks. Each is a small `IOKit` / `NSWorkspace` / `NSUserNotification` query. Spec §3.16 lists them as separate rows.
- **E2 fix-action expansions** — `media.resolution` "Fix" gets a relink-folder picker once C7 (asset library) lands. `output.reference` could fall back to Sound deep-link when DVS isn't installed.
- **E3 — dropped-frame + late-take** — both events listed in spec §3.16 but require instrumentation in the playback path (compositor / output driver) before they can be logged. Independent of the writer infrastructure already shipped.
- **E4 — log filtering** — by source / action type / time range. View-side; the model already has the data.
- **E5 — take history (recent 200) with replay scrub** — a separate surface, not just the log. Replay needs the runtime to accept "fire cue X with the original parameters at this offset."
- **E6 — autosave every 30 s** — `NSDocument.autosavingDelay` is the API; checkpoint on Show-mode toggle is custom.
- **E7 — crash recovery** — load the last autosave on launch with a "what changed since last save" summary.
- **E8 — project lock file** — small. Write `<bundle>/.lock` with PID + hostname on open; warn on duplicate-open if the file exists and the PID is still alive.
- **E9 — Director View tear-off window** — read-only Program + next 3 + notes. Multi-display.
- **E10 — Saved Workspaces** — Edit / Rehearsal / Show / Single-Screen. UX-design heavy; product blocker territory.
- **E11 — Brightness adapt key** — booth-dim key separate from system brightness.
- **E12 — Phase E summary + manual rehearsal steps** — the cleanup pass at the end of E.

---

## Recommended next pick

- **E8 (project lock file)** — small, no UX blockers, ships in one commit. A clean win on its own.
- **E6 (autosave)** — `NSDocument.autosavingDelay = 30` plus a checkpoint hook on Show-Mode toggle. 1-2 commits.
- **More pre-show macOS-condition checks** — DND, screensaver, energy, Spotlight. Each adapter is independent and tests cleanly.
- **E4 (filter UI on the log)** — the model has all the data; the view needs a small toolbar with source/action picker + a date range. ~1 commit.
- **C7 (asset library — linked vs managed)** — bigger surface. Foundation for C8 (folder bookmarks), C9 (missing-media UX with a real "Locate…" affordance), C10/C11 (thumbnails). Multi-session item but unlocks a chunk of Phase C.
- **B7 (DeckLink format negotiation)** — Phase B leftover. Hardware-bound for verification but the API surface is well-defined.

Phase B leftovers (B7, B11, B13) and Phase C tail (C7+) remain background work that can be picked off between Phase E iterations.
