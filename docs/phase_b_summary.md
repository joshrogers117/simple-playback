# Phase B — Output pipeline rework — Summary

**Status**: Data model shipped (B1-B4). Rendering refactor + DeckLink hardening (B5-B16) intentionally deferred to a follow-up session because they require a sustained restructure of `VideoOutput.swift` / `DeckLinkBridge.mm` that won't fit cleanly in this conversation's remaining budget.

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
