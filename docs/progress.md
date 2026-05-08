# Progress — Simple Playback v1 Autonomous Build

Living checklist. Sub-tasks marked `pending` / `in_progress` / `done` / `blocked`. I update this every iteration.

Source of truth for what's left: this file. Source of truth for *why* it's broken into these tasks: `docs/spec/feature_spec.md` §7. Source of truth for how I work: `docs/runbook.md`.

---

## Current state

- **Active phase**: A and D complete; B mostly done (B1–B5, B12 shipped; B6 mostly done; B8 pure-logic recommendation + inspector hint shipped; B14 partial); Phase C substantially done (C1–C6 + C-banner all in; **C7 fully landed**: C7a/b/c in session 16, **C7d Bundle for Travel landed in session 17** — pure-logic plan + apply, BundleForTravelCoordinator, toolbar action + confirm/progress/result sheet, bundle-aware MediaReference.resolvedURL + PlaybackController.bundleMediaDirectory + AssetLibraryProbe bundle-aware online check); **C9 both first + second slice landed in session 16** (relink-folder Fix handler + per-slide Locate context menu); **Phase E**: E1 done + E1+ energy adapter (session 16 added the asset-library `media.files` row + stale-fingerprint detection); E2 done; E3 done; E3+ done (DroppedFrameCounter pure-logic + PlaybackController detection + status-bar chip + ShowController log debounce — late-take detection still deferred); E4 done; E5 done (TakeHistory in-memory v1 + viewer sheet — replay scrub deferred); E6 done; E7 done (crash recovery — Restore/Discard banner on autosave newer than Show.json); E8 done. Remaining E items: more E1+ macOS-condition adapters (Spotlight / DND / Time Machine / screensaver — fragile / privacy-blocked); late-take detection (E3+ tail), E8 read-only-mode banner option, E9 (Director View), E10 (Workspaces), E11 (brightness adapt key). Remaining Phase C items: C8 folder bookmarks; C9 persistent banner above OutputStatusBar; C10/C11 thumbnails; C12-C15 audio.
- **Last commit**: asset-library: bundle-aware MediaReference.resolvedURL + playback wiring (C7d-3c)
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
- [~] B8: 10-bit YUV 4:2:2 default when any clip in the project is >8-bit. `PlayoutProject.recommendsTenBitOutput` pure-logic computed property + yellow info hint in Output inspector when true (session 11). **Still deferred**: applying the recommendation as the actual default at DeckLink-binding-creation time (no UI surface for that yet) and hardware verification of 10-bit format negotiation against a real card.
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
- [x] C4: Animated GIF / APNG detect → offer convert-to-ProRes-4444
  - [x] C4a: `MediaFlags.animatedImage` + `.animatedImage` WarningKind + spec-§3.10 warning copy
  - [x] C4b: `Services/AnimatedImageInspector.swift` (`CGImageSourceGetCount > 1`) wired into `MediaImporter` image branch
  - [x] C4c: `TranscodeService.canTranscode` widened to animated-image slides; `preferredPresetOrder(for:)` leads ProRes 4444 for animated images; `SlideGridView` right-click menu uses preferred order
- [x] C5: Image-sequence detect (`name.0001.png`) → offer encode-to-ProRes-4444 via `AVAssetWriter`
  - [x] C5a: `Services/ImageSequenceDetector.swift` pure-logic — groups `name.NNN[N].(png|jpg|jpeg|tiff|tif|exr)` into Sequences vs leftovers; supports 3- or 4-digit counters, multi-dot basenames, multiple sequences in one batch, gaps in counter
  - [x] C5b: `Services/ImageSequenceEncoder.swift` — `@MainActor ObservableObject` wrapping `AVAssetWriter` (frames in → ProRes 4444 .mov out); state enum mirrors `TranscodeJob`; FourCC pinned to `ap4h`/`ap4x` end-to-end. Plus `ImageSequenceEncodeCoordinator` mirroring `TranscodeCoordinator` (jobs list + injectable `siblingImporter` test seam). Frame rate is operator-supplied; default committal deferred to C5c.
  - [x] C5c: Add Folder…  toolbar button + `AddFolderImporter` folder-walk pure-logic + `AddFolderImportSheet` confirm sheet (per-sequence frame-rate picker — preset menu 24/25/30/48/50/60 plus custom integer field; Encode button gated on every encode-checked sequence having a non-zero rate). Standalone media routes through `MediaImporter`; sequences route through `ImageSequenceEncodeCoordinator.encode(...)`. `BackgroundJobsStrip` (renamed from `TranscodeProgressStrip`) renders both transcode and encode jobs side-by-side in the palette progress strip. **No frame-rate default committed at any layer** — operator picks per import.
- [x] C6: Keynote import — AppleScript-driven `.key` → PDF → bitmaps; "Keynote not installed" diagnostic
  - [x] C6a: `Services/KeynoteImporter.swift` (NSAppleScript export-to-PDF, install detection, error mapping) + 9 tests
  - [x] C6b: `MediaImporter.importSlides(from:context:)` routes `.key` via injectable `keynoteExporter` → PDFImporter + 5 tests
  - [x] C6c: Open panel/drop accept `.key`; modal `Keynote not installed` alert; `NSAppleEventsUsageDescription` + `com.apple.security.automation.apple-events` entitlement
- [x] C7: Asset library — linked vs managed media; security-scoped bookmark + path + content hash + size + mtime
  - [x] C7a: `Services/AssetFingerprinter.swift` (SHA-256 streaming + size + mtime); `MediaReference` gains decode-if-present `kind: .linked | .managed` and `fingerprint: MediaAssetFingerprint?` fields; legacy projects default to `.linked` with nil fingerprint.
  - [x] C7b: `MediaImporter.fingerprinter` static-var test seam; every direct image/video import and PDF/Keynote rasterized page populates `media.fingerprint` at import time. Failure non-blocking — nil fingerprint still imports.
  - [x] C7c: `Services/MediaResolver.swift` pure-logic waterfall — bookmark/originalPath → contentHash search → name+size search → offline. Every I/O dependency injected; live wrapper uses `FileManager.default.enumerator`. Foundation for C9 missing-media UX.
  - [x] C7d: Bundle for Travel (session 17) — `Services/BundleForTravelPlan.swift` pure-logic plan + apply (filename-collision dedup, already-managed skip, offline skip), `Services/BundleForTravelCoordinator.swift` (state machine + injectable copy/ensure/remove), `Views/BundleForTravelSheet.swift` (idle summary → progress → result), toolbar action gated on saved bundle, `MediaReference.resolvedURL(bundleMediaDirectory:)` overload + bundle-aware `MediaResolver` rung 0 + bundle-aware `AssetLibraryProbe.makeIsOnline/makeResolveURL` so a moved bundle still plays + pre-show-classifies its managed media. `ProjectBundleLayout.mediaDirectory = "Media"`.
- [ ] C8: Folder-level bookmarks for batch imports
- [~] C9: Missing-media UX — non-modal banner, per-clip Locate, project-level Relink folder, hash-based auto-relink
  - [x] C9 first slice (session 16): `Services/AssetRelinkPlan.swift` pure-logic plan + apply over MediaResolver. RootView Pre-Show fix handler for `media.files` row opens NSOpenPanel and applies the plan to `project.slides` (refreshes fingerprint per relinked file). Empty match surfaces via the import-status banner.
  - [x] C9 second slice (session 16): per-slide Locate context menu in `SlideGridView` (right-click → Locate…) wired through `RootView.relinkSlideViaOpenPanel` for one-shot file picks; rebuilds the slide's `MediaReference` with a refreshed fingerprint.
  - [ ] Persistent banner above OutputStatusBar that shows offline-count without requiring the operator to open Pre-Show.
- [ ] C10: Embedded poster-frame thumbnails (palette loads with media offline)
- [ ] C11: Filmstrip thumbnail sprite-sheets (background queue)
- [ ] C12: Audio engine refactor — 48 kHz / 32-bit float, 8 internal channels, routing matrix
- [ ] C13: Audio cue types — embedded, audio-only cue, background bed
- [ ] C14: Per-cue audio: volume, mute, fade-in/out, crossfade override, varispeed with pitch correction
- [ ] C15: SRT/WebVTT subtitle sidecar render (subtitle layer in compositor)
- [x] C-banner: Import status banner across PDF / Keynote / transcode failures (session 10–11)
  - [x] C-banner-a: `MediaImportFailure` value type + `MediaImportReport` + `MediaImporter.importSlidesAndReport(from:context:)` overload
  - [x] C-banner-b: `ImportStatusBanner` ObservableObject + `ImportStatusBannerView` rendered above `OutputStatusBar`; PDF / Keynote / unsupported / transcode (non-cancel) failure paths feed in
  - [x] C-banner-c: Modal "Keynote not installed" `NSAlert` removed; banner is the single uniform non-modal failure surface (session 11).
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

- [x] E1: Pre-show check panel — `Services/PreShowCheck.swift` pure-logic evaluator + `Views/PreShowCheckView.swift` sheet + toolbar "Pre-Show" button. Rules: media resolution (cue→slide pointer integrity), media files (on-disk file existence per slide via `Services/AssetLibraryProbe.swift` — session 16; offline shown as error, stale-fingerprint as warning), FPS conformance (B14 reuse), 10-bit recommendation (B8 reuse), external-reference vs DeckLink lock (live via `PreShowCheckAdapters.from(_:)`), disk space, audio device (live via `Services/AudioDeviceProbe.swift`), render-path-warmed (live via `PlaybackController.hasRenderedAnyFrame`), energy / no-idle-sleep (live via `Services/EnergyAssertion.swift` — assertion held while Show Mode on). **Still deferred**: macOS DND / screensaver / Spotlight / Time Machine checks (each fragile or privacy-blocked on modern macOS).
- [x] E2: "Fix" actions per pre-show row — `PreShowCheckFixHandlers` keyed by row.id; ships handlers for `system.audio` (Sound deep-link), `system.disk` (reveal bundle in Finder), `output.reference` (Blackmagic Desktop Video Setup), and `media.files` (NSOpenPanel relink folder + AssetRelinkPlan apply — session 16). `media.resolution` (cue→slide integrity) and `fps.conformance` / `output.tenBit` are project-edit territory and intentionally have no system fix.
- [x] E3: Show log writer — `Services/ShowLog.swift` model + CSV writer (RFC 4180); `ShowController` integration (every verb logs with default `.operatorButton` source, hotkey/OSC/HTTP/TC paths can override); dispatcher → log routing via `onActionDispatched` with `ShowControlSource → ShowLogEvent.Source` translator (HTTP tokens collapse to last 4 chars); read-only `Views/ShowLogView.swift` viewer with chronological list + Export CSV via `NSSavePanel`; toolbar "Show Log" button. Persistence: `<bundle>/Logs/<yyyy-MM-dd>.log` (untitled documents stay in-memory until first save). **Still deferred**: dropped-frame events, late-take detection.
- [x] E4: Show log viewer filter UI — `ShowLog.SourceFilter` (All/Local/OSC/HTTP/TC/System) + `ActionFilter` (All/Show verbs/Remote API/System) + a "Since" relative window picker (Last minute / 5 minutes / Hour / All time). Filter logic on `ShowLog.filteredEvents(source:action:since:)`; view mounts the picker toolbar + a Reset button; header label switches from "N events" to "N of M events" when filtered.
- [x] E3+: Dropped-frame counter — `Services/DroppedFrameCounter.swift` (pure-logic rolling-10s + cumulative). `PlaybackController.renderCurrentVideoFrame` measures host-time gap between consecutive timer ticks; deficit > 1.5× `activeFrameInterval` records `floor(delta/interval) - 1` drops. Counter resets on `stopOutput`. `OutputStatusBar` renders a chip `Drops <rolling>/10s · <cumulative> total` (hidden when cumulative=0; orange when rolling>0, secondary otherwise). `ShowController.handleDropCumulative(_:now:)` is the pure-logic debounce (1 s quiet window) — emits one `.droppedFrame` log entry per burst with detail `drops=<delta> cumulative=<total>`; resets re-baseline without a phantom event. Wired through `playback.droppedFrameCounter.$cumulative`. Late-take detection (E3+ tail): pure-logic `Services/LateTakeDetector.swift` + `ShowLog.Action.lateTake` shipped session 17; **live integration into ShowController/PlaybackController deferred** — needs a "first operator-visible frame for cue X" callback that doesn't yet exist (session-17 spike found that observing `liveSlideID` would only catch load-latency for video and zero-latency for images, not operator-visible-frame latency).
- [x] E5: Take history — `Services/TakeHistory.swift` circular buffer (capacity 200; clamped to ≥1; oldest dropped on overflow). `TakeHistoryEntry { id, timestamp, cueID, cueNumber, cueTitle, durationSecondsAtFire? }`. `ShowController.handleCueFired` records on every fire (samples `playback.videoDuration` as the duration hint — nil when zero, i.e. images). `Views/TakeHistoryView.swift` toolbar sheet renders newest-first with timestamp / cue number / title / duration. **Replay scrub deferred** — runtime would need a "fire cue X with original parameters at offset" entry point that doesn't exist.
- [x] E6: Autosave every 30 s + checkpoint on Show-Mode toggle. `NSDocumentController.autosavingDelay = 30` set in AppDelegate; `Services/AutosaveCheckpointer.swift` writes `<bundle>/Autosave/<timestamp>__<reason>.json` snapshots driven by `RootView.handleShowModeChange`. Retention 20 (oldest pruned at write time). The 30s-rolling autosave-in-place mechanism is NSDocument's default once autosavingDelay is set.
- [x] E7: Crash recovery on next launch — `Services/CrashRecoveryDetector.swift` (pure-logic `findRecoverableCheckpoint(bundleURL:)` returns the newest autosave file strictly newer than Show.json's mtime; nil otherwise). `CrashRecoveryController` state machine evaluates on `fileURL` change; banner in `Views/CrashRecoveryBannerView.swift` offers Restore / Discard. `SimplePlaybackProjectDocument.restoreProjectFromRecoverableCheckpoint()` decodes the checkpoint JSON, replaces the project, marks the doc dirty. **"What changed" summary deferred** — minimum v1 ships Restore + Discard.
- [x] E8: Project lock file — `Services/ProjectLockFile.swift` (model + injectable IO) + `ProjectLockController` state machine + `Views/ProjectLockBannerView.swift`. Lock at `<bundle>/.lock` records pid + hostname + timestamp + applicationVersion. Liveness checker covers ours / localLive / localStale / foreignLive / foreignStale; live foreign locks surface a banner with Open Anyway / Dismiss (Read Only deferred — needs document-wide read-only enforcement). Released on `NSDocument.close`.
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
