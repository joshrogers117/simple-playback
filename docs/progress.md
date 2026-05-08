# Progress — Simple Playback v1 Autonomous Build

Living checklist. Sub-tasks marked `pending` / `in_progress` / `done` / `blocked`. I update this every iteration.

Source of truth for what's left: this file. Source of truth for *why* it's broken into these tasks: `docs/spec/feature_spec.md` §7. Source of truth for how I work: `docs/runbook.md`.

---

## Current state

- **Active phase**: A and D complete; B mostly done (B1–B5, B12 shipped; B6 mostly done; B14 partial); Phase C in progress — C1 (codec inspector flags), C2 (ProRes transcode action), C3 (PDF rasterize-on-import), and C6 (Keynote AppleScript→PDF→bitmaps) shipped end-to-end.
- **Last commit**: C2c — RootView right-click → Transcode menu + non-modal progress strip in palette
- **Branch**: `development`

---

## Phase A — Show runtime + UX scaffolding

- [x] A1: Convert `.splayback` to bundle format with `formatVersion` and read-flat / write-bundle migration
- [x] A2: Cue model — id (any non-empty string, case-insensitive uniqueness), continuation (hold/auto-continue/auto-follow), pre-wait, post-wait, notes
- [x] A3: Per-cue overrides — fade in/out, crossfade duration, hold-last-frame, loop, in/out points; defaults inherit from project
- [x] A4: Playhead + GO / PREV / PANIC / CLEAR / BLACKOUT semantics, with debounce
  - [x] A4a: ShowList struct (ordered cues, lookup by id/number, validation, playhead, mutation helpers)
  - [x] A4b: CueRuntime state machine — GO / PREV / PANIC / CLEAR / BLACKOUT with debounce
  - [x] A4c: Continuation timing — autoContinue (immediate chain) and autoFollow (postWait on cue-end)
- [x] A5: Show List view alongside `SlideGridView`; drag-from-palette-to-list; per-cue inspector
- [~] A6: Edit / Show Mode toggle (toolbar toggle + Cmd-Shift-L hotkey + edit-disable wiring done; confirm-on-quit while live and modal-forbidden invariant deferred to A6b after live-state hookup)
- [~] A7: Hotkey scheme — Space/GO, Esc/Panic, ←/Previous, Cmd-Shift-L/Show Mode, Cmd-./Clear wired via SwiftUI .keyboardShortcut. Rebinding + printable export deferred to A7b.
- [~] A8: Single-output default — already true (PreviewVideoOutputDriver is present); Preview/Program opt-in deferred to A8b after Phase B compositor refactor.
- [~] A9: Status bar — existing OutputStatusBar reused; dropped-frame counter and TC/log shortcuts deferred to Phase E.
- [x] A10: Per-cue notes field (CueInspectorView uses TextEditor, full visibility)
- [x] A11: Show List integration tests (covered in CueRuntime/ShowList tests in A4)
- [x] A12: Project-bundle round-trip tests (showLists round-trip + legacy migration verified)
- [x] A13: Phase A summary + manual rehearsal steps (`docs/phase_a_summary.md`)

## Phase B — Output pipeline rework

- [x] B1: Stage abstraction (resolution, frame rate, color space, range)
- [x] B2: Screen abstraction with typed roles (Program, Confidence, Multiviewer, Mirror, Auxiliary, StreamOut)
- [x] B3: Transport binding layer — DeckLink, OS Display, NDI Full, Syphon, Operator-Mac window, file-record
- [x] B4: Per-machine local config mapping role → device (`OutputBindingProfile` — schema only; UI defers)
- [x] B5: Refactor `VideoOutput.swift` and `DeckLinkBridge` against the new abstraction
  - [x] B5a: TransportSink protocol + TransportSinkRouter + TransportSinkStage
  - [x] B5b: DeckLinkTransportSink + PreviewTransportSink (drivers reduced to thin shims)
  - [x] B5c: PlaybackController fans frames + audio out to auxiliary TransportSinks
  - [x] B5d: Router/sink unit tests + PlaybackController register/unregister hooks
- [~] B6: DeckLink REF input handling — surface lock state via `IDeckLinkOutput::GetReferenceStatus`, status-bar REF chip with idle/locked/free-run/not-supported palette (B6 session-2). Project-level `expectsExternalReference` toggle on `PlayoutProject` + Output inspector tab + escalating red "REF EXPECTED — Output is free-running" banner above the status row when the toggle is on and the bridge reports `unlocked` (B6b session-5). **Still deferred**: REF format-mismatch warning vs Stage frame rate (needs incoming-REF frame-rate query, which the v15.3.1 `IDeckLinkOutput` interface does not expose — likely needs `IDeckLinkProfileAttributes::BMDDeckLinkSupportsReferenceInputTimingOffset` or input-side enumeration; small SDK-API spike required before scoping).
- [ ] B7: DeckLink format negotiation — explicit at start, mid-show change requires re-arm
- [ ] B8: 10-bit YUV 4:2:2 default when any clip in the project is >8-bit
- [ ] B9: "Output in use" detection + recovery path
- [ ] B10: Audio embed over SDI with channel-pair routing
- [ ] B11: NDI Full sender as a transport binding
- [x] B12: Compositor — three layers (media, bug/logo, message/timer). `CompositorOverlays`/`BugOverlay`/`MessageOverlay` data model on `Stage` (B12a), `CompositorPipeline` with corner-bug + lower-third/top/center text + `{time_left}` countdown (B12b), `PlaybackController.submitFrame` runs every output through the pipeline (B12c), Overlays inspector tab with bug image picker + corner/size/margin/opacity sliders + message text/position/fontSize/colors/countdown (B12d), `ShowController.applyCompositorOverlays(_:)` bridges `project.stages.first?.compositorOverlays` → `PlaybackController.compositorOverlays` via `.onChange` in `RootView` (B12e), and the in-app preview tile keeps the composed frame visible past dissolve completion + re-composites on inspector edits (B12f).
- [ ] B13: Color pipeline — per-Screen range/space; visible color chain in inspector; NCLC/ICC respect with overrides; gamma-aware crossfade
- [~] B14: Frame-rate conformance warning surfaced in CueInspectorView when a video cue's native frame rate differs from the active Stage. `MediaSlide.nativeFrameRate` populated at import via AVAsset. Pure-logic `FrameRateConformance` evaluator with 0.1 fps tolerance (catches the four canonical fractional/integer pairs as matches). **Pre-show check (E1) reuse pending.**
- [ ] B15: Hot-unplug handling (UltraStudio Thunderbolt)
- [ ] B16: Phase B summary + DeckLink mock layer for tests + manual rehearsal steps

## Phase C — Media pipeline

- [x] C1: Codec inspector — long-GOP / VFR / 10-bit 4:2:0 / untagged color flags
  - [x] C1a: `MediaFlags` model + pure-logic `MediaFlagsEvaluator` + spec-§3.10 warning copy
  - [x] C1b: `MediaFlagsInspector.inspect(url:)` populates `MediaSlide.flags` at import; `decodeIfPresent` for legacy projects
  - [x] C1c: `MediaFlagWarningChip` renders each active flag below the FPS conformance warning in `CueInspectorView`
- [x] C2: Right-click "Transcode to ProRes 422" / "Transcode to ProRes 4444" action; writes to project-relative `Transcoded/`
  - [x] C2a: `Services/TranscodeService.swift` — `TranscodePreset`, `TranscodeError`, `TranscodeJob` (modern AVAssetExportSession `export(to:as:)` + `states(updateInterval:)` progress)
  - [x] C2b: `TranscodeCoordinator` (job lifecycle + sibling-slide construction via injectable `siblingImporter`); `ProjectBundleLayout.transcodedDirectory = "Transcoded"`
  - [x] C2c: `SlideGridView` context menu + non-modal progress strip; `RootView` `transcodedRootDirectory()` (bundle vs App Support fallback) + sibling-slide splice on completion
- [x] C3: PDF import via PDFKit → bitmap-per-page at output × 2
  - [x] C3a: `Services/PDFImporter.swift` rasterize service + 8 tests (PDFKit pure logic)
  - [x] C3b: `MediaImporter.importSlides(from:context:)` routes PDFs via `MediaImportContext` + 4 tests
  - [x] C3c: `RootView` drop / open-panel build the context (Stage × 2 raster; bundle `Cache/Renders/` or app-support fallback for untitled docs); `ProjectBundleLayout.rendersDirectory` pinned
- [ ] C4: Animated GIF / APNG detect → offer convert-to-ProRes-4444
- [ ] C5: Image-sequence detect (`name.0001.png`) → offer encode-to-ProRes-4444 via `AVAssetWriter`
- [x] C6: Keynote import — AppleScript-driven `.key` → PDF → bitmaps; "Keynote not installed" diagnostic
  - [x] C6a: `Services/KeynoteImporter.swift` (NSAppleScript export-to-PDF, install detection, error mapping) + 9 tests
  - [x] C6b: `MediaImporter.importSlides(from:context:)` routes `.key` via injectable `keynoteExporter` → PDFImporter + 5 tests
  - [x] C6c: Open panel/drop accept `.key`; modal `Keynote not installed` alert; `NSAppleEventsUsageDescription` + `com.apple.security.automation.apple-events` entitlement
- [ ] C7: Asset library — linked vs managed media; security-scoped bookmark + path + content hash + size + mtime
- [ ] C8: Folder-level bookmarks for batch imports
- [ ] C9: Missing-media UX — non-modal banner, per-clip Locate, project-level Relink folder, hash-based auto-relink
- [ ] C10: Embedded poster-frame thumbnails (palette loads with media offline)
- [ ] C11: Filmstrip thumbnail sprite-sheets (background queue)
- [ ] C12: Audio engine refactor — 48 kHz / 32-bit float, 8 internal channels, routing matrix
- [ ] C13: Audio cue types — embedded, audio-only cue, background bed
- [ ] C14: Per-cue audio: volume, mute, fade-in/out, crossfade override, varispeed with pitch correction
- [ ] C15: SRT/WebVTT subtitle sidecar render (subtitle layer in compositor)
- [ ] C16: Phase C summary + manual rehearsal steps

## Phase D — Show control

- [x] D1: OSC server (UDP + TCP) on `/sp` with curated namespace
- [x] D2: HTTP/JSON twin (`/api/v1/...`) mirroring every OSC address
- [x] D3: WebSocket `/api/v1/events` for state push
- [x] D4: OSCQuery server publishing namespace with type/range/value/description
- [x] D5: Bonjour/mDNS discovery (`_simpleplayback._udp` + `_simpleplayback._tcp`)
- [x] D6: Bearer-token auth + capability flags (`read` / `fire` / `edit`); Show-Mode capability stripping
- [x] D7: Subscription state push at 10 Hz when subscribed
- [x] D8: Per-cue feedbacks (running, standby, is-playhead, elapsed > X, remaining < X)
- [x] D9: Per-cue variables + globals (cue_id, cue_name, playhead_id, tc_locked, tc_now, onair, …)
- [x] D10: Ping/heartbeat (`/sp/ping` → `/sp/pong f uptime`)
- [x] D11: Versioned API (`apiVersion` in every reply); idempotent action retrigger lockout (50 ms)
- [x] D12: LTC chase via Core Audio input — engagement state machine, per-cue trigger/offset, drop-frame handling, jam-sync
- [x] D13: MTC chase via Core MIDI input
- [x] D14: Internal TC generator for rehearsal
- [x] D15: Companion module — design doc only (`docs/phase_d/companion_module_design.md`); JS module is a sibling-repo deliverable
- [x] D16: Headless OSC client integration tests covering full action surface
- [x] D17: Phase D summary + ShowControlStack/Hub wiring into SimplePlaybackApp + ShowController

## Phase E — Reliability

- [ ] E1: Pre-show check panel — media, DeckLink, disk, macOS energy/DND/screensaver/Spotlight, audio device, render path warmed
- [ ] E2: "Fix" actions per pre-show row where automatable
- [ ] E3: Show log writer — append-only, persisted in bundle `Logs/`
- [ ] E4: Show log viewer with filtering (source, action type, time range)
- [ ] E5: Take history (recent 200) with replay scrub
- [ ] E6: Autosave every 30 s + checkpoint on Show-mode toggle
- [ ] E7: Crash recovery on next launch with "what changed" summary
- [ ] E8: Project lock file — warn on duplicate-open
- [ ] E9: Director View tear-off window (read-only, Program + next 3 + notes)
- [ ] E10: Saved Workspaces ("Edit", "Rehearsal", "Show", "Single Screen")
- [ ] E11: Brightness adapt key (booth dimming separate from system brightness)
- [ ] E12: Phase E summary + manual rehearsal steps

## Phase F — v2 enablement (likely stops here for review)

This phase is intentionally light — by spec §4 the v2 items are large enough that each deserves its own planning round. Phase F is the cleanup pass:

- [ ] F1: Code-reviewer subagent against the full v1 diff; act on P0/P1 findings
- [ ] F2: README.md update — feature list, screenshots, OSC API quickref, Companion install
- [ ] F3: docs/api.md — OSC + HTTP API reference for integrators
- [ ] F4: docs/manual_verification.md — consolidated list of every "needs hardware" verification step from phases A–E
- [ ] F5: Test fixture audit — every fixture committed has a script that regenerates it
- [ ] F6: Final phase summary + handoff document
