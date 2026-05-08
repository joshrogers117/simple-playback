# Phase B — Output pipeline rework — Summary

**Status (session 1)**: Data model shipped (B1-B4).
**Status (session 2 — 2026-05-07)**: TransportSink fan-out shipped (B5). DeckLink REF status surfaced (B6 partial). 161 tests, all green.
**Status (session 3 — 2026-05-07)**: Compositor pipeline shipped (B12 model + pipeline + integration; UI deferred to B12d). 193 tests, all green.
**Status (session 4 — 2026-05-07)**: B12 finished — Overlays inspector tab + ShowController bridge + composed-frame preview rendering (B12d/e/f). 197 tests, all green. 3 commits on `development`.
**Status (session 5 — 2026-05-07)**: B6b (partial) — project-level "expects external reference" toggle + escalating red free-run banner. 202 tests, all green. 1 commit on `development`. Format-mismatch detection vs Stage frame rate still deferred to a future SDK spike.

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
