# Phase B — Output pipeline rework — Summary

**Status (session 24 — 2026-05-08) — Phase B holding pattern**. Phase B ships v1's renderer + compositor + REF policy + 10-bit recommendation logic + frame-rate conformance evaluator. The remaining tail (B7 format negotiation, B9 output-in-use detection, B10 audio routing UI, B11 NDI sender, B13 color pipeline, B15 hot-unplug) all sit on either real DeckLink hardware or large pure-logic surfaces that warrant their own pickup; none is autonomy-shippable today without a hardware spike or a UX product blocker. This file is the **B16 phase summary** — the v1 Phase B inventory + test surface + manual rehearsal checklist + the explicit "scoped-out" list. The session-by-session log below it is the historical narrative from sessions 1–5.

**What ships for v1 Phase B**:

- **B1-B4** (session 1) — data model: `Stage` (resolution / integer-ratio FPS / color space / range), `Screen` (typed `ScreenRole`), `TransportBinding` (`deckLink` / `osDisplay` / `ndi` / `syphon` / `operatorWindow` / `fileRecord`), `ScreenBinding` (Stage→Transport pairing + corner-pin + edge-blend + mirror), `OutputBindingProfile` (per-machine binding registry persisted in `UserDefaults` so opening the same `.splayback` in different venues doesn't dirty the show file), `PlayoutProject.stages + screens` with default-seed semantics.
- **B5** (session 2) — `TransportSink` protocol + `TransportSinkRouter` fan-out + `DeckLinkTransportSink` / `PreviewTransportSink` + driver shims (`DeckLinkVideoOutputDriver` / `PreviewVideoOutputDriver` reduced to thin wrappers). `PlaybackController.register(sink:) / unregister(sink:)` is the public API for auxiliary sinks. The compositor → driver → device hot path is now uniformly fan-out: every composed frame and every audio block goes through the router, so future B11 NDI / second-DeckLink-port / file-record sinks register a sink rather than re-touching the rendering hot path.
- **B6 + B6b** (sessions 2 + 5) — DeckLink REF lock state surfaced in `OutputStatusBar` (idle / notSupported / unlocked / locked palette); project-level `PlayoutProject.expectsExternalReference` toggle in the Output inspector tab; escalating red banner ("REF EXPECTED — Output is free-running") above the status row when the toggle is on and the bridge reports `unlocked`. Banner suppresses on `idle` / `notSupported` / `locked` — those aren't contradictions of operator expectation. **REF format-mismatch vs Stage frame rate is deferred** — the v15.3.1 `IDeckLinkOutput` interface used by `SPDeckLinkBridge` does not expose REF input timing; needs a small SDK-API spike against `IDeckLinkProfileAttributes` / `IDeckLinkProfileManager` first.
- **B8 (logic)** (session 11) — `PlayoutProject.recommendsTenBitOutput` pure-logic computed property keys off any video slide's `flags.tenBitYUV420` (Phase C C1 reuse). Yellow info hint in the Output inspector: "10-bit recommended — at least one clip uses 10-bit YUV 4:2:0." **Applying the recommendation as the default at DeckLink-binding-creation time is deferred** (no UI surface for the binding-creation step today); hardware verification of 10-bit format negotiation against a real card is also deferred (B7-coupled).
- **B12** (sessions 3 + 4) — three-layer compositor: `CompositorOverlays` data model on `Stage` (bug + message), `CompositorPipeline` pure-logic compose pass (4-corner bug placement, top/lower-third/center message, `{time_left}` countdown), `PlaybackController.submitFrame` runs every frame through compose, Overlays inspector tab + `ShowController.applyCompositorOverlays(_:)` bridge + composed-frame preview rendering. The *base* (pre-overlay) frame is cached so transitions don't double-bake the overlay (decision_log entry "B12: cache base frame, not composed frame"). Bug image cache is invalidated on `bug.media` change; folder-bookmark + bundle-Media URL changes invalidate it through C7d/C8 threading.
- **B14** — frame-rate conformance evaluator: `Models/FrameRateConformance.swift` pure-logic struct (`severity: .match / .unknown / .mismatch`, 0.1 fps tolerance catching the four canonical fractional/integer pairs). `MediaSlide.nativeFrameRate` populated at import via `AVTrackLoader` (sessions 22-23). Cue inspector renders an FPS conformance chip below the asset row when severity is `.mismatch` (`Views/RootView.swift:1291`). Pre-Show check (E1) reuses the same evaluator via `PreShowCheck.evaluateFrameRateConformance(project:)` — surfaces one row per mismatched cue. **B14 is fully shipped** (the older "pre-show check reuse pending" deferral note in progress.md was stale once E1 landed).

**What's scoped out / deferred for Phase B v1**:

- **B7 — DeckLink format negotiation** — Mid-show change requires re-arm. Requires: (1) `IDeckLinkOutput::DoesSupportVideoMode` spike to confirm we can enumerate supported modes pre-arm (vs the v15.3.1 interface used today), (2) operator-UX choice for the mid-show re-arm flow (modal alert? non-modal banner with "re-arm" affordance? dismiss-with-Esc?). Both blockers — first technical, second product. Best done after a hardware spike + a UX brief, not as a continuous-execution session.
- **B9 — "Output in use" detection + recovery** — Today a busy DeckLink port silently fails on `EnableVideoOutput`. The `bmdDeckLinkOutputBusyError` HRESULT comes back from the bridge but the surface today is a generic "Output failed to start" — no holding-process disclosure, no "release and retry" affordance. Bridge-side work + UX. Deferred.
- **B10 — Audio embed channel-pair routing** — Bridge supports SDI audio embed today (`bmdAudioOutputStreamTimestamped`); the operator-facing routing matrix UI does not exist. UX-design heavy.
- **B11 — NDI Full sender as a `TransportSink`** — Schema exists in `TransportBinding.ndi(senderName:)`; implementation needs the NDI Advanced SDK (license + binary distribution decision). Now genuinely "register an NDISink with the router" — fits the B5 scaffolding cleanly. Deferred until the SDK distribution decision lands.
- **B13 — Color pipeline** — Per-Screen range/space conversion, gamma-aware crossfade (existing crossfade is linear-RGB), NCLC/ICC respect with operator override, visible color chain in inspector. Today the renderer is BGRA premultiplied-first throughout; per-Stage color tagging is in the data model (`Stage.colorSpace + Stage.range`) but not driven through to the frame conversion path. Substantial — sits on top of B5 + B12. Not autonomy-shippable without hardware verification.
- **B15 — Hot-unplug handling** — UltraStudio Thunderbolt unplug today surfaces as a generic `bmdDeckLinkOutputDeviceLostError` and `PlaybackController.refreshDevices()` re-enumerates on the next user action. The intended UX is a non-modal "Output device disconnected" banner + automatic re-arm on reconnect. Hardware-bound.
- **B16 (mock layer)** — `MockTransportSink` test fixture exists in `Simple PlaybackTests/TransportSinkTests.swift` (sinkID, isRunning, framesSubmitted, audioSubmitted, settable startError/frameError/audioError) and is reused across the router fan-out tests. A more sophisticated `MockDeckLinkSink` mirroring the DeckLink-specific surface (referenceState, last-delivered-format, busy-state) is queued for B7/B9 coupled work and not needed today — every Phase B test surface that exists is exercised through `MockTransportSink` or via direct Swift calls into pure-logic services.

**Phase B feature inventory at v1 close**

**Data model + topology (B1-B4)**

- `Stage` — `Models/StageScreen.swift`. Resolution + integer-ratio frame rate (so 23.976 / 29.97 / 59.94 are exact via numerator+denominator) + color space (`sRGB` / `Rec.709` / `Display P3` / `Rec.2020 HLG` / `Rec.2020 PQ`) + range (`limited` / `full`) + `compositorOverlays` (B12).
- `Screen` — operator-named output destination, typed by `ScreenRole` (`program` / `confidence` / `multiviewer` / `mirror` / `auxiliary` / `streamOut`). References a `Stage.id`. Cues bind to screens by role, never by display index — venue-portable.
- `TransportBinding` — `deckLink(deviceID, modeID, fillKey, audioEmbed, tenBit)`, `osDisplay(displayID)`, `ndi(senderName)`, `syphon(serverName)`, `operatorWindow`, `fileRecord(url)`.
- `ScreenBinding` — pairs a Screen with a Transport, plus optional `CornerPin` 4-corner warp, optional `EdgeBlend` (left/right/top/bottom width + gamma + power), optional mirror-of-another-Screen, `enabled` flag.
- `OutputBindingProfile` — named collection of `ScreenBinding`s for a particular machine, persisted in `UserDefaults`. Project file stays venue-portable; per-machine binding lives separately.

**Render hot path + sink fan-out (B5)**

- `TransportSink` protocol (`Output/TransportSink.swift`) — sinkID, label, status, isRunning, activeStage, start/stop/submit(frame:)/submit(audio:sampleFrameCount:).
- `TransportSinkStage` — narrow runtime view of `Stage` (width / height / numerator / denominator). Tests can construct one without a full project.
- `TransportSinkRouter` — `NSLock`-protected sink registry; fan-out captures per-sink errors so one failing transport does not stall the rest.
- `DeckLinkTransportSink` + `PreviewTransportSink` (`Output/TransportSinks.swift`) — concrete sinks. Each `DeckLinkTransportSink` owns its own `SPDeckLinkBridge`, so multi-port (Fill+Key on a Duo 2; Program+Confidence on separate cards) is "register N sinks" rather than another rewrite.
- Driver shims — `DeckLinkVideoOutputDriver` and `PreviewVideoOutputDriver` delegate to a sink internally; their public API is unchanged so `OutputSettingsStore`, `RootView`, `OutputPreferencesView` callers compiled clean across the refactor.
- `PlaybackController.register(sink:) / unregister(sink:)` auto-starts a sink for the active stage if output is already running.

**REF lock state + project-level expectation (B6 + B6b)**

- `SPDeckLinkBridge.referenceState` (new `SPDeckLinkReferenceState` enum: idle / notSupported / unlocked / locked) refreshed via `IDeckLinkOutput_v15_3_1::GetReferenceStatus`. Polled on start and on demand.
- `DeckLinkTransportSink.referenceState + pollReferenceState()` mirror the bridge enum into a Swift type.
- `VideoOutputDriver.deckLinkReferenceState` returns the active sink's state (or `nil` for software-only drivers).
- `PlaybackController.deckLinkReferenceState` is `@Published`; refreshed on `refreshDevices()`, on output start, and cleared on stop.
- `OutputStatusBar` REF chip palette: green check for `locked`, orange triangle for `unlocked`, secondary for `notSupported` / `idle`. Tooltips explain each state.
- `PlayoutProject.expectsExternalReference: Bool` (`decodeIfPresent` so legacy projects round-trip cleanly). Output inspector tab Reliability section toggle.
- `OutputStatusBar.referenceExpected` parameter drives a full-width red banner above the status row when the toggle is on AND the bridge reports `unlocked`. `evaluateFreeRunBanner(referenceExpected:referenceState:)` is the pure helper unit-tested across all 5 (state, expectation) combinations.

**10-bit recommendation logic (B8 logic)**

- `PlayoutProject.recommendsTenBitOutput: Bool` — pure-logic computed property; `true` if any video slide's `MediaFlags.tenBitYUV420 == true`.
- Output inspector renders a yellow info hint when `recommendsTenBitOutput`: "10-bit recommended — at least one clip uses 10-bit YUV 4:2:0."

**Compositor (B12)**

- `Models/CompositorLayers.swift` — `CompositorOverlays` (`bug: BugOverlay` + `message: MessageOverlay`, `isInert` short-circuit accessor), `BugOverlay` (4-corner placement, marginPercent / sizePercent / opacity / `MediaReference?`), `MessageOverlay` (top / lower-third / center, fontSize / opacity / textColor / optional backgroundColor / optional `countdownTo: Date`), `RGBAColor` (Codable RGBA with `cgColor` accessor + `init(color: SwiftUI.Color)` via `NSColor.usingColorSpace(.sRGB)`).
- `Stage.compositorOverlays` (codable, defaults to `.empty` for legacy projects).
- `Playback/CompositorPipeline.swift` — composes media → bug → message onto a base BGRA `RenderedFrame`; inert overlays short-circuit and return the input frame unchanged (zero allocations); buffer convention matches `FrameRenderer` (BGRA premultiplied-first, `byteOrder32Little`, row 0 at visual top). 4-corner bug placement with margin/size as fractions of canvas; cached image resolver invalidated on `BugOverlay.media` change. Message rendering: top / lower-third / center, optional dark-translucent background pad, Core Text drawing with flipped textMatrix to render upright in the y-flipped context. Static helpers `formatCountdown(_:)` (M:SS under 1h, H:MM:SS past 1h, clamps negative to 0:00), `renderedMessageText(overlay:nowDate:)` (substitutes `{time_left}` token).
- `PlaybackController.compositorOverlays: CompositorOverlays` — mutable; `didSet` flushes the pipeline's bug image cache on `bug.media` change AND re-publishes the composed preview on every overlay edit so the in-app preview tile picks up edits without needing another take.
- `submitFrame` runs every frame through `CompositorPipeline.compose(...)` before driver / auxiliary-sink hand-off. Cached `currentFrame` is the *base* frame so transitions don't double-bake the overlay.
- `Views/OverlayInspectorView.swift` — bug + message inspector sections (enable switches, NSOpenPanel image picker, 4-way corner picker, sliders for size / margin / opacity, text field with `{time_left}` token hint, 3-way position picker, color pickers, countdown date/time picker).
- `RootView` segmented inspector picker (`InspectorMode.selection / .overlays / .output`). Overlays mode binds to `project.stages[0].compositorOverlays`.
- `ShowController.applyCompositorOverlays(_:)` bridge wired via `.onChange(of: document.project.stages.first?.compositorOverlays)` and called once after `configureShowController()` so freshly opened projects pick up persisted overlays.
- `firePendingPostDissolveActivation` does NOT nil-clear `transitionPreviewImage` — composed frame stays visible after a dissolve completes.
- C7d/C8 follow-on: `CompositorPipeline.bundleMediaDirectory + folderBookmarks` synchronized via the existing `cacheLock`; mirror the same lock + invalidation discipline as the bug-image cache. Bundle / folder-bookmark threading flows from `PlaybackController` `didSet` into the compositor on each property change. Read paths consume `MediaReference.resolvedURL(bundleMediaDirectory:folderBookmarks:)` so a moved bundle's managed assets render their bug image overlays correctly.

**Frame-rate conformance (B14)**

- `Models/FrameRateConformance.swift` — `severity: .match / .unknown / .mismatch`, 0.1 fps tolerance catching the four canonical fractional/integer pairs (23.976↔24, 29.97↔30, 47.952↔48, 59.94↔60) as matches.
- `MediaSlide.nativeFrameRate: Double?` populated at import via `AVTrackLoader.loadFirstVideoTrackInspection` (sessions 22-23). Legacy projects without the field decode to `nil` (severity `.unknown`).
- `Views/RootView.swift` cue inspector (line 1291) renders an FPS conformance chip below the asset row when severity is `.mismatch`.
- `Services/PreShowCheck.swift::evaluateFrameRateConformance(project:)` (E1 reuse) — one row per mismatched cue with the same `FrameRateConformance` evaluator; rendered in the Pre-Show check sheet with "Clip 23.976 ≠ Stage 59.94" detail. This is the spec-§3.7 "flag again in pre-show check" requirement.

**Phase B test inventory at v1 close**

735 tests total at HEAD on `development` (session 23). Phase B-direct test surfaces:

- `TransportSinkTests.swift` (~14) — stage derivation, frame-interval clamping, sink lifecycle, router fan-out, error isolation across sinks, removed-sink stop-on-replace, controller register/unregister hooks, `MockTransportSink` test fixture.
- `OutputStatusBarTests.swift` (~6) — REF banner suppression / visibility across all 5 (state, expectation) combos.
- `ModelTests.swift` (Phase B portions, ~12) — Stage defaults, ScreenRole completeness, CornerPin identity, TransportBinding labels, project round-trip with stages+screens, ScreenBinding round-trip with DeckLink fill+key + 10-bit, default-seed semantics, `expectsExternalReference` defaults+round-trip, `recommendsTenBitOutput` true/false matrix, B12 round-trip on `compositorOverlays`.
- `OverlayInspectorTests.swift` (~5) — `RGBAColor(color:)` round-trip, `InspectorMode` cases + labels (now includes `.output`), `ShowController.applyCompositorOverlays(_:)` forwarding, before-frame republish no-op.
- `CompositorPipelineTests.swift` (~8) — inert short-circuit, bug placement (pixel probes for top-left and bottom-right), missing-media graceful fallback, cache invalidation on `bug.media`, format/substitution edge cases, composed-frame format invariants, `bundleMediaDirectory` change invalidation pin (C7d hardening), folder-bookmark change invalidation pin (C8-6 follow-up).
- `FrameRateConformanceTests.swift` (~10) — match across all 4 fractional/integer pairs, mismatch matrix, unknown handling, `Stage` initializer convenience, summary text stability, format-helper rounding, decode-if-present legacy round-trip.

Phase E pre-show check tests (`PreShowCheckTests.swift`) reuse the conformance evaluator and are out of scope for the Phase B count.

**Consolidated manual rehearsal steps for Phase B**

These need real DeckLink hardware (the SDI output side), a REF generator (the genlock side), and an SDI reference monitor (the visual confirmation side). Each step exercises a code path that is unit-tested at the model/pipeline layer but never run against a real card at v1.

1. **Output topology venue-portability** — open a project on machine A with a DeckLink output bound, save, reopen on machine B without that DeckLink. Verify the project file decodes cleanly, the per-machine `OutputBindingProfile` falls back to the default Program stage / OS display path, and the show file itself is unchanged on disk.
2. **REF chip palette** — with a DeckLink card attached, select it as the output and start playback. Verify the REF chip appears in the lower-right of the status row. With a REF generator connected and locked, chip is **green / "REF: Locked"**. With no REF, chip is **orange / "REF: Free-run"**. On a card without external reference input (e.g. UltraStudio Mini Recorder), chip is **gray / "REF: Not supported"**. Stop output → REF chip disappears. Restart → chip re-appears at the new state.
3. **REF expectation banner** — toggle "Expects external reference (genlock)" on in the Output inspector. With REF disconnected, the red banner ("REF EXPECTED — Output is free-running") appears above the status row. Reconnect REF → banner disappears, chip turns green. On a `notSupported` card with the toggle on, no banner appears (hardware fact ≠ contradiction). Save the project, reopen — toggle persists.
4. **Compositor overlays at SDI** — open a fresh project, switch the inspector to Overlays. Enable the bug, pick a PNG → bug renders in the in-app preview after the next take, AND on the SDI feed at the chosen corner. Cycle the corner picker (TL/TR/BL/BR) → bug repositions on both surfaces without needing another take. Sliders for size / margin / opacity update both surfaces live.
5. **Message overlay + countdown at SDI** — enable the message, type `Doors in {time_left}`, set a target 60s in the future → preview shows `Doors in 1:00` and ticks down on both surfaces.
6. **Crossfade through overlays** — run a crossfade between two video cues with overlays on. Bug + message persist crisply through the dissolve on BOTH the in-app preview and the SDI output (no double-bake on the trailing frame).
7. **10-bit recommendation hint** — import a 10-bit HEVC Main-10 clip into a project. Output inspector should show the yellow "10-bit recommended" hint. Remove the clip, hint disappears.
8. **FPS conformance — cue inspector** — import a 23.976 clip into a project whose Stage is 59.94. Cue inspector renders an FPS conformance chip with "FPS: 23.976 → 59.94". Match is suppressed (no chip when within tolerance).
9. **FPS conformance — pre-show check** — open Pre-Show. The same mismatched cue surfaces a Pre-Show row "Frame rate mismatch: Clip 23.976 ≠ Stage 59.94". Multiple mismatched cues each get their own row.
10. **TransportSinkRouter fan-out (manual smoke)** — with a DeckLink card attached, start playback. Verify the existing crossfade and take semantics are unchanged — B5 was meant to preserve behavior; a quick smoke-rehearsal of two video cues with crossfade enabled confirms the router did not regress the rendering hot path.

**Hardware-only verification (still needed before promotion to "production-ready")**

These cannot be exercised by autonomy at all and require real hardware + a full rehearsal cycle:

- SDI output looks right on a real reference monitor (B5 / B12 / B13 visual confirmation).
- Genlock + fill+key on a Duo 2 (B6 / B7 hardware path).
- 10-bit YUV 4:2:2 format negotiation against a real card (B8 hardware path).
- "Output in use" recovery when another app holds the port (B9, deferred).
- Audio embed channel-pair routing against an SDI receiver (B10, deferred).
- NDI Full sender picked up by a real NDI receiver (B11, deferred).
- Hot-unplug + reconnect of an UltraStudio Thunderbolt mid-show (B15, deferred).
- Color pipeline conversion accuracy on a Rec.709 / Rec.2020 HLG / PQ reference monitor (B13, deferred).
- REF format-mismatch detection vs Stage frame rate (B6 remainder, deferred — needs SDK-API spike).

---

## Session-by-session log

**Status (session 1)**: Data model shipped (B1-B4).
**Status (session 2 — 2026-05-07)**: TransportSink fan-out shipped (B5). DeckLink REF status surfaced (B6 partial). 161 tests, all green.
**Status (session 3 — 2026-05-07)**: Compositor pipeline shipped (B12 model + pipeline + integration; UI deferred to B12d). 193 tests, all green.
**Status (session 4 — 2026-05-07)**: B12 finished — Overlays inspector tab + ShowController bridge + composed-frame preview rendering (B12d/e/f). 197 tests, all green. 3 commits on `development`.
**Status (session 5 — 2026-05-07)**: B6b (partial) — project-level "expects external reference" toggle + escalating red free-run banner. 202 tests, all green. 1 commit on `development`. Format-mismatch detection vs Stage frame rate still deferred to a future SDK spike.
**Status (sessions 6–23)**: Phase B itself didn't move further; Phase B–touching work was incidental (compositor's `bundleMediaDirectory` and `folderBookmarks` got threaded as part of C7d / C8, dropped-frame counter + status chip got added in E3+ session 15, the consolidated FPS conformance evaluator got reused in PreShowCheck in session 13). The above session-by-session log captures the active development on Phase B; the consolidated section at the top of this file is the v1 close.

The hot path (compositor → driver → device) now goes through a `TransportSinkRouter` that fans every composed frame and audio block out to N sinks. The primary user-selected output (DeckLink or software preview) still flows through the original `VideoOutputDriver` for backward compatibility, but the driver's concrete classes are now thin shims around `DeckLinkTransportSink` / `PreviewTransportSink`. Future B-phase sub-tasks (B11 NDI, second DeckLink port, file-record sink) register additional `TransportSink`s on `PlaybackController` and pick up frames automatically.

---

## What shipped in session 2 (B5–B6)

### B5 — TransportSink fan-out

- **`TransportSink` protocol** (`Output/TransportSink.swift`) — sinkID, label, status, isRunning, activeStage, start/stop/submit. The compositor stays format-agnostic; per-transport conversion (DeckLink format, NDI sender, OS display) lives in the sink.
- **`TransportSinkStage`** — narrow runtime view of `Stage`: width/height/integer-ratio frame rate. Tests can construct one without a full `PlayoutProject`. `init(stage: Stage)` derives directly from the project model.
- **`TransportSinkRouter`** — thread-safe registry of sinks; `submit(frame:)` and `submit(audio:sampleFrameCount:)` fan out to every running sink, capturing per-sink errors so one failing transport does not stall the rendering loop.
- **`DeckLinkTransportSink`** + **`PreviewTransportSink`** (`Output/TransportSinks.swift`) — concrete sinks. Each `DeckLinkTransportSink` owns its own `SPDeckLinkBridge`, so multi-port (Fill+Key on a Duo 2; Program+Confidence on separate cards) becomes "register N sinks" rather than another rewrite.
- **Driver shims** — `DeckLinkVideoOutputDriver` and `PreviewVideoOutputDriver` now delegate to a sink internally; their public API is unchanged so `OutputSettingsStore`, `RootView`, `OutputPreferencesView`, and the existing `testPreviewDriverStartsAndAcceptsFrames` test continue to work.
- **`PlaybackController.register(sink:)` / `unregister(sink:)`** — public API for adding auxiliary sinks; auto-starts the sink for the active stage if output is already running.
- 14 new tests in `TransportSinkTests.swift` cover stage derivation, frame-interval clamping, sink lifecycle, router fan-out, error isolation across sinks, removed-sink stop-on-replace, and the controller register/unregister hooks.

### B6 (partial) — DeckLink REF lock state

- **Bridge**: `SPDeckLinkBridge.referenceState` (new `SPDeckLinkReferenceState` enum: idle / notSupported / unlocked / locked) refreshed via `IDeckLinkOutput_v15_3_1::GetReferenceStatus`. Polled on start and on demand.
- **Sink**: `DeckLinkTransportSink.referenceState` + `pollReferenceState()` mirror the bridge enum into a Swift type.
- **Driver**: `VideoOutputDriver.deckLinkReferenceState` returns the active sink's state, or nil for software-only drivers.
- **Controller**: `PlaybackController.deckLinkReferenceState` is a `@Published` property; refreshed on `refreshDevices()`, on output start, and cleared on stop.
- **Status bar**: `OutputStatusBar` now shows a REF chip when a DeckLink output is active. Palette: green check for locked, orange triangle for free-run, secondary for not-supported / idle. Tooltips explain each state.

## Still deferred (session 3+)

These need another session of work; the rendering refactor scaffolding is now in place so each can be picked up independently:

- **B6b** — operator-policy on REF: project-level "expects external reference" toggle that escalates the free-run state to a red status-bar banner (today free-run is orange/informational only). Plus REF format-mismatch detection vs the Stage frame rate; the `IDeckLinkOutput_v15_3_1` interface used by the bridge does **not** expose REF-input timing, so this likely needs `IDeckLinkProfileAttributes` or a newer interface revision. Worth a small SDK-API spike before scoping.
- **B7** — DeckLink format negotiation: explicit at start, mid-show change requires re-arm. Bridge already fails on unsupported `bmdFormat8BitBGRA` modes; the operator-facing surface (UI affordance for "select mode") does not yet warn on mid-show changes.
- **B8** — 10-bit YUV 4:2:2 default when any clip in the project is >8-bit. Bridge always submits BGRA today; the `Stage.colorSpace` and codec inspector flags need to drive a 10-bit-YUV conversion path.
- **B9** — "Output in use" detection + recovery. Today a busy DeckLink port silently fails on `EnableVideoOutput`; needs to surface holding-process best-effort.
- **B10** — Audio embed channel-pair routing. Bridge supports embed; routing UI does not exist.
- **B11** — NDI Full sender as a `TransportSink`. Schema exists; implementation needs the NDI SDK. Now genuinely "register an NDISink with the router" — fits the B5 scaffolding.
- **B12** — Compositor with bug + message overlay layers. Today only the media layer renders. Recommended next session: a `CompositorPipeline` that produces the composed frame each tick, then routes via the router.
- **B13** — Color pipeline (per-Screen range/space, gamma-aware crossfade, NCLC/ICC respect with operator override, visible color chain in inspector). Sits on top of B5+B12.
- **B14** — Frame-rate conformance warnings at clip-into-show time and pre-show. Pure logic, hardware-independent.
- **B15** — Hot-unplug handling for UltraStudio Thunderbolt.
- **B16** — Phase B summary (this file becomes the final summary) + DeckLink mock layer for tests.

## Recommended next sub-task

**B12 (compositor layers)** is the highest-leverage next pick. It sits naturally on top of B5 (every overlay layer just composes into the same `RenderedFrame` the router fans out), it is purely Swift / Core Image work with no hardware dependency, and it unblocks B13 (color pipeline) and the v1 spec's three-layer compositor requirement (§3.6). After B12, B6b/B7/B8 can be done as a coupled DeckLink-hardening commit train.

## Manual verification needed (session 2 deltas)

1. With a DeckLink card attached, select it as the output and start playback. Verify the **REF chip** appears in the status bar.
2. With a REF generator connected and locked, the chip should be **green / "REF: Locked"**.
3. With no REF generator, the chip should be **orange / "REF: Free-run"**.
4. On a card without an external reference input (e.g. UltraStudio Mini Recorder), the chip should be **gray / "REF: Not supported"**.
5. Stop output → REF chip disappears. Restart → chip re-appears at the new state.
6. Verify the existing crossfade and take semantics are unchanged (B5 was meant to preserve behavior); a quick smoke-rehearsal of two video cues with crossfade enabled confirms the router did not regress the rendering hot path.

---

## What shipped in session 3 (B12 partial)

### B12a — Compositor overlay data model

- **`CompositorOverlays`** (`Models/CompositorLayers.swift`) — `bug: BugOverlay` + `message: MessageOverlay`, `isInert` accessor for short-circuit.
- **`BugOverlay`** — `enabled`, `media: MediaReference?`, `corner: BugCorner` (4 cases), `marginPercent`, `sizePercent`, `opacity`. `isVisible` requires enabled + media + opacity > 0 + size > 0.
- **`MessageOverlay`** — `enabled`, `text`, `position: MessagePosition` (top / lowerThird / center), `fontSizePercent`, `textColor`, optional `backgroundColor`, `opacity`, optional `countdownTo: Date`. `isVisible` requires enabled + opacity > 0 + (text or countdown).
- **`RGBAColor`** — Codable RGBA with `cgColor` accessor.
- **`Stage.compositorOverlays`** — persistent overlay state on Stage (codable, defaults to `.empty` for legacy projects). Round-trip + legacy-decode tests.

### B12b — `CompositorPipeline` (pure logic)

- **`Playback/CompositorPipeline.swift`** — composes the three layers (media → bug → message) onto a base BGRA `RenderedFrame`. Inert overlays short-circuit and return the input frame unchanged (zero allocations). Buffer convention matches `FrameRenderer` (BGRA premultiplied-first, byteOrder32Little, row 0 at visual top of image).
- Bug rendering: 4-corner placement with margin/size as fractions of canvas; cached image resolver (invalidated on `BugOverlay.media` change).
- Message rendering: top / lower-third / center positions, optional dark-translucent background pad behind text, Core Text drawing with flipped textMatrix to render upright in the y-flipped context.
- Static helpers: `formatCountdown(_:)` (`M:SS` under 1h, `H:MM:SS` past 1h, clamps negative to `0:00`), `renderedMessageText(overlay:nowDate:)` (substitutes `{time_left}` token).
- 13 new tests in `CompositorPipelineTests.swift` cover inert short-circuit, bug placement (pixel probes for top-left and bottom-right), missing-media graceful fallback, cache invalidation, format/substitution edge cases, and composed-frame format invariants.

### B12c — `PlaybackController` integration

- **`PlaybackController.compositorOverlays: CompositorOverlays`** — mutable; `didSet` flushes the pipeline's bug image cache when `bug.media` changes.
- **`submitFrame` runs every frame through `CompositorPipeline.compose(...)` before driver / auxiliary-sink hand-off.** Cached `currentFrame` is the *base* (pre-overlay) frame so transitions don't double-bake the overlay (see decision log "B12: cache base frame, not composed frame").
- 2 new controller-level tests: defaults-to-empty + accepts updates.

## Still deferred (session 5+)

- **B6b / B7 / B8** — DeckLink hardening commit train (REF policy, format negotiation, 10-bit YUV).
- **B11** — NDI Full sender as a `TransportSink`.
- **B13** — Color pipeline (sits on top of B5+B12).
- **B9 / B15 / B10** — long tail.
- **B16** — final Phase B summary + DeckLink mock layer for tests.

Operator-facing follow-ups not yet scheduled (small):
- Default keyboard shortcut to quick-toggle a "STAND BY" message overlay (product decision on chord — `M`? `Cmd-M`? `B` is already Blackout). Out of scope for B12 finish; file as a Phase E or "Operator UX" item when it comes up.
- Live timer ticker for `{time_left}` countdown in the inspector preview — today the inspector shows the raw text; the rendered countdown only updates as new frames hit `submitFrame`. For stills with a static `currentFrame`, the displayed countdown won't tick down. Acceptable for v1; revisit if operators ask for it.

## Manual verification needed (session 3 deltas)

The session-3 work is pure-logic and operator-invisible until B12d/e ships UI controls — there is no operator-visible pathway to enable the overlays today. So no new manual rehearsal steps. When B12d/e/f land:

1. Toggle bug overlay on with a PNG logo. Verify the bug renders in all 4 corners (top-left, top-right, bottom-left, bottom-right).
2. Set bug `sizePercent` to 0.10 vs 0.25 vs 0.40 → bug scales proportionally.
3. Set bug `opacity` to 0.5 → underlying media bleeds through.
4. Toggle message overlay on with text "STAND BY" → renders at lower-third with translucent background.
5. Set countdown target 60s in the future, text "Doors in {time_left}" → live-updating countdown.
6. Crossfade between two video cues while overlays are enabled → bug + message persist crisply through the crossfade (no double-bake, no popping).

---

## What shipped in session 4 (B12d/e/f)

### B12d — Overlays inspector tab

- **`Views/OverlayInspectorView.swift`** — new SwiftUI view bound to a `CompositorOverlays`. Two sections (Bug, Message), each with an enable switch that disables-and-dims the section when off.
  - Bug controls: enable, image picker (`NSOpenPanel` for PNG/JPEG → `MediaReference`), 4-way corner picker, size %, margin %, opacity sliders.
  - Message controls: enable, text field with `{time_left}` token hint, 3-way position picker, font size %, opacity sliders, text color and optional background color (`SwiftUI.ColorPicker`), countdown date/time picker.
- **`Views/RootView.swift`** — segmented picker at the top of the inspector pane (`Selection` / `Overlays`). Selection mode preserves existing cue and slide inspectors. Overlays mode binds to `project.stages[0].compositorOverlays`.
- **`RGBAColor(color:)`** — SwiftUI `Color` → `RGBAColor` via `NSColor.usingColorSpace(.sRGB)`. Round-trip covered by unit test.

### B12e — `ShowController` bridge

- **`ShowController.applyCompositorOverlays(_:)`** — single forwarding method into `PlaybackController.compositorOverlays`.
- **`RootView.syncCompositorOverlays()`** — wired via `.onChange(of: document.project.stages.first?.compositorOverlays)` and called once after `configureShowController()` so freshly opened projects pick up persisted overlays.

### B12f — Composed frame in the preview tile

- **`PlaybackController.compositorOverlays.didSet`** now calls `republishComposedPreview()` after invalidating the bug image cache. The helper takes the cached *base* frame, runs it through `CompositorPipeline.compose(...)` with the new overlays, and pushes the result to `transitionPreviewImage`. No-op when there's no current frame.
- **`firePendingPostDissolveActivation`** no longer nil-clears `transitionPreviewImage`. The composed frame stays visible after a dissolve completes; previously the view fell back to raw `previewImage` / `AVPlayer` and lost overlays.
- **`OutputPreviewView`** unchanged — already preferred `transitionPreviewImage` over the raw fallbacks; B12f just keeps that channel populated.

## Tests added (session 4)

| Test | What it covers |
|---|---|
| `OverlayInspectorTests.testRGBAColorRoundTripFromSwiftUIColor` | `RGBAColor(color:)` faithfully captures sRGB components and alpha. |
| `OverlayInspectorTests.testInspectorModeCasesAndLabels` | `InspectorMode` enum has the expected cases / display labels. |
| `OverlayInspectorTests.testShowControllerForwardsOverlaysToPlayback` | `ShowController.applyCompositorOverlays(_:)` writes through to `PlaybackController.compositorOverlays`; resetting to `.empty` clears it. |
| `TransportSinkTests.testControllerOverlayAssignmentBeforeAnyFrameDoesNotPublishPreview` | Setting overlays before any submit must not synthesize a preview image (republish is a no-op when `currentFrame == nil`). |

Total: 197 tests, all green (was 193 at start of session).

## Manual verification needed (session 4 deltas)

These require human eyeballs — autonomous tests don't drive SwiftUI views or compose against real DeckLink output.

1. Open a fresh project, switch the inspector to **Overlays**.
2. Enable the bug, click **Choose…**, pick a PNG → bug name appears, bug renders in the in-app preview after the next take.
3. Cycle the corner picker (TL/TR/BL/BR) → bug repositions on preview without needing another take.
4. Change size / margin / opacity sliders → preview re-composites live.
5. Enable the message, type `Doors in {time_left}`, set a target 60s in the future → preview shows `Doors in 1:00` then ticks down (NB: only ticks on stills if a video is playing; for static stills the countdown is currently latched at the time of the last submit — see "Operator-facing follow-ups").
6. Run a crossfade between two video cues with overlays on → bug + message persist through the dissolve, no double-bake on the trailing frame.
7. Save the project, reopen → overlays state persists; preview re-composites with the saved bug + message after the first take.

Hardware steps remain (still untested by autonomy):
- DeckLink output composes overlays at SDI (the bridge submits the composed BGRA frame; visual confirmation requires a card).
- Frame timing: overlays during 23.976 / 29.97 fractional crossfades.

---

## What shipped in session 5 (B6b — partial)

### B6b — project-level REF expectation + escalating banner

- **`PlayoutProject.expectsExternalReference: Bool`** (defaults to `false`, codable, `decodeIfPresent` so legacy projects round-trip cleanly).
- **`InspectorMode.output`** — third inspector tab alongside `Selection` and `Overlays`. Houses an `OutputInspectorView` with a read-only Stage summary (name / resolution / frame rate / color space / range) and a Reliability section containing the toggle. `RootView.inspectorContent` switches into it; the existing `OverlayInspectorView` stays focused on §3.6 compositor concerns.
- **`OutputStatusBar.referenceExpected: Bool`** — new parameter the view uses to compute whether to show a red banner. When the toggle is on and the bridge reports `unlocked`, a full-width red bar with the system `exclamationmark.triangle.fill` glyph and the text "REF EXPECTED — Output is free-running" / "Verify the external reference signal is connected and locked." renders **above** the existing chip+status row. The orange chip stays orange; the loud signal moves to the banner.
- **`OutputStatusBar.evaluateFreeRunBanner(referenceExpected:referenceState:)`** — pure helper extracted for unit tests; covers all 5 (state, expectation) combinations without needing a real `PlaybackController`. The banner suppresses on `idle` / `notSupported` / `locked` / `nil` — those aren't contradictions of the operator's expectation.

### Tests added (session 5)

| Test | What it covers |
|---|---|
| `ModelTests.testProjectExpectsExternalReferenceDefaultsToFalseForFreshProjects` | New field defaults to `false` for `PlayoutProject()`. |
| `ModelTests.testProjectExpectsExternalReferenceDefaultsToFalseWhenAbsentInJSON` | Legacy projects without the field decode to `false`. |
| `ModelTests.testProjectExpectsExternalReferenceRoundTripsThroughJSON` | Setting the field round-trips through encode/decode. |
| `OutputStatusBarTests.testFreeRunBannerHiddenWhenReferenceNotExpected` | Banner is suppressed for every reference state when toggle is off. |
| `OutputStatusBarTests.testFreeRunBannerVisibleOnlyForUnlockedWhenReferenceExpected` | Banner shows only on `unlocked`; suppressed on `idle` / `notSupported` / `locked` / `nil`. |
| `OverlayInspectorTests.testInspectorModeCasesAndLabels` (updated) | Now asserts `[.selection, .overlays, .output]` with all three labels. |

Total: 202 tests, all green (was 197 at start of session).

### Manual verification needed (session 5 deltas)

These need real DeckLink hardware (the SDI output side) plus a REF generator (the genlock side); autonomy can only verify the model + UI logic.

1. Open a project, switch the inspector to **Output**. Confirm the Stage summary shows the expected resolution / frame rate / color space.
2. Toggle "Expects external reference (genlock)" on. With no DeckLink output running yet, no banner appears (idle ≠ contradiction).
3. Start DeckLink output on a card with no REF generator connected (or REF disconnected). Confirm:
   - The orange "REF: Free-run" chip appears in the lower-right of the status row (existing behavior).
   - **A new red banner appears above the status row**: "REF EXPECTED — Output is free-running" with the warning glyph.
4. Connect / lock the REF generator. The banner disappears; the chip turns green ("REF: Locked").
5. Disconnect REF again — banner returns; toggle the project flag off — banner disappears even while free-run.
6. Save the project, reopen it. The toggle persists (round-trip-tested in unit tests).
7. Run the same flow on a card without external reference input (e.g. UltraStudio Mini Recorder). The chip shows "REF: Not supported"; **no banner appears** even with the toggle on. (`notSupported` is hardware fact, not an operator-expectation contradiction.) The right surface for that mismatch is pre-show check (E1).

### Still deferred (session 6+)

- **B6 (remaining)** — REF format-mismatch detection vs Stage frame rate. The `IDeckLinkOutput_v15_3_1` interface used by `SPDeckLinkBridge` does **not** expose REF input timing. Needs a small SDK-API spike against newer interfaces (`IDeckLinkProfileAttributes` / `IDeckLinkProfileManager`) before scoping; if missing entirely, blocker.
- **B7** — DeckLink format negotiation. Has product-UX questions (mid-show re-arm flow — modal? non-modal banner? dismiss-with-Esc?) that warrant a fresh session with options surfaced to the user.
- **B8** — 10-bit YUV 4:2:2 default once any clip is >8-bit. Bridge always submits 8-bit BGRA today; needs `Stage.colorSpace` and codec inspector (C1) flags to drive a 10-bit-YUV conversion path.
- **B11** — NDI Full sender as a `TransportSink`. Independent of DeckLink work; needs the NDI SDK.
- **B13** — Color pipeline (sits on top of B5+B12).
- **B9 / B15 / B10** — long tail.
- **B16** — final Phase B summary + DeckLink mock layer for tests.

Operator-facing follow-up (small):
- Pre-show check (E1) reuse: when E1 lands, the same `expectsExternalReference` flag should drive a pre-show "REF locked?" gate, not just a render-time banner. Track in the E1 design pass.

---

## Session 1 baseline (B1–B4)

## What shipped (B1-B4)

The architectural model from spec §16 is now in place. Cues reference outputs by role, the project file stays venue-portable, and the per-machine binding lives in a separate object.

- **`Stage`** (`Simple Playback/Models/StageScreen.swift`) — virtual raster the compositor renders into. Holds resolution, integer-ratio frame rate (so 23.976 / 29.97 / 59.94 are exact), color space tag (`sRGB` / `Rec.709` / `Display P3` / `Rec.2020 HLG` / `Rec.2020 PQ`), and range (`limited` / `full`).
- **`Screen`** — operator-named output destination. Typed by `ScreenRole` (`program` / `confidence` / `multiviewer` / `mirror` / `auxiliary` / `streamOut`). References a `Stage.id`. The cue list will reference screens by role, not by display index.
- **`TransportBinding`** — the actual hardware/software target: `deckLink(deviceID, modeID, fillKey, audioEmbed, tenBit)`, `osDisplay(displayID)`, `ndi(senderName)`, `syphon(serverName)`, `operatorWindow`, `fileRecord(url)`.
- **`ScreenBinding`** — pairs a Screen with a Transport, plus optional 4-corner `CornerPin` warp, optional `EdgeBlend` (left/right/top/bottom width + gamma + power), optional mirror-of-another-Screen, and an `enabled` flag.
- **`OutputBindingProfile`** — a named collection of `ScreenBinding`s for a particular machine. Persisted in `UserDefaults` so opening the same `.spb` in different venues only requires re-binding, not editing the show.
- **`PlayoutProject`** gains `stages: [Stage]` and `screens: [Screen]`. `markCurrentFormatVersion()` seeds a default Program stage + screen on first save so output topology is always non-empty.
- 7 new tests (144 total): default Stage values, ScreenRole completeness, CornerPin identity, TransportBinding labels, project round-trip with stages+screens, ScreenBinding round-trip with DeckLink fill+key + 10-bit, default-seed semantics.

## Deferred (B5-B16)

These need the rendering refactor that I'm not attempting in this session. They sit on top of the data model that just landed, so a future session has clear scaffolding:

- **B5** — Refactor `Output/VideoOutput.swift` and `DeckLinkBridge.mm` against the Stage→Screen→Transport abstraction. Today `PlaybackController.take(slide:deviceID:modeID:)` flattens the topology into a single (deviceID, modeID) pair. The refactor drives multiple Transport sinks from one cue.
- **B6** — DeckLink REF input handling: surface lock state in `OutputStatusBar`, refuse silent free-run, warn on REF format mismatch.
- **B7** — DeckLink format negotiation: explicit at start, mid-show change requires re-arm.
- **B8** — 10-bit YUV 4:2:2 default once any clip in the project is >8-bit. Today the bridge always submits 8-bit BGRA.
- **B9** — "Output in use" detection + recovery path. Today a busy DeckLink port silently fails.
- **B10** — Audio embed over SDI with channel-pair routing. The bridge supports embed today; routing UI doesn't exist.
- **B11** — NDI Full sender as a Transport implementation. Schema exists; implementation needs the NDI SDK.
- **B12** — Compositor with three layers (media, bug/logo, message/timer). Today only the media layer renders.
- **B13** — Color pipeline: per-Screen range/space conversion, gamma-aware crossfade (existing crossfade is linear-RGB), NCLC/ICC respect with operator override, visible color chain in inspector.
- **B14** — Frame-rate conformance warnings at clip-into-show time and pre-show check.
- **B15** — Hot-unplug handling for UltraStudio Thunderbolt. Today the bridge treats device-loss as a regular start failure.
- **B16** — Phase B summary + DeckLink mock layer for tests. (This file partially fulfills the summary; the mock layer is a B5 prerequisite.)

## Recommended order for the follow-up

1. **B5 first**: introduce `TransportSink` protocol, refactor `PlaybackController` to fan a frame out to N sinks, port the existing DeckLink path to a `DeckLinkSink: TransportSink`. This is a contained rewrite that preserves existing behavior while opening the door for the rest.
2. **B12** (compositor layers) on top of B5 — a CompositorPipeline that owns the media frame + bug + message and produces the final frame each tick.
3. **B6 / B7 / B8** are tightly coupled DeckLink hardening — do them in one branch.
4. **B11 NDI** is independent of the DeckLink work — could be parallelizable to a future agent.
5. **B13 color pipeline** sits on top of B5 + B12; defer until those are stable.
6. **B14 / B9 / B15** are the long tail — pick one at a time.

## How the app behaves today

- Existing v0/v1 projects open and migrate cleanly. The default Program stage/screen seeded by `markCurrentFormatVersion()` matches the existing 1080p output behavior, so nothing changes from the operator's point of view.
- Cue-fired playback still goes through `PlaybackController.take(slide:deviceID:modeID:)` — the new abstractions are present in the project file but not yet driving the rendering path. This is the cleanest possible "model-first" landing: zero behavior regression.
- 144 tests pass; all model-layer round-trips verified.
