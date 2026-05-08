# Phase B — Output pipeline rework — Summary

**Status (session 1)**: Data model shipped (B1-B4).
**Status (session 2 — 2026-05-07)**: TransportSink fan-out shipped (B5). DeckLink REF status surfaced (B6 partial). 161 tests, all green.

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
