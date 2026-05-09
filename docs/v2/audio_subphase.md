# v2 Pre-Scope — Audio Sub-Phase (C12 / C13 / C14 / C15)

**Status**: pre-scope (planning only — no code).
**Filed**: 2026-05-08, session 27.
**Spec source**: `docs/spec/feature_spec.md` §3.11 (Audio model — engine, channels, cue types, varispeed, routing) and §3.18 (Subtitles / overlay captions). Coverage in `docs/progress.md`: C12 (audio engine refactor), C13 (audio cue types), C14 (per-cue audio), C15 (SRT/WebVTT subtitle sidecar render) — all marked `~ scoped out of v1`.
**Runbook source**: explicitly out of v1 per kickoff. The corporate-AV target operator's primary audio path is through a downstream switcher / audio mixer — Simple Playback's v1 audio is "play the embedded audio of the cue, route to a single CoreAudio device, that's it."

---

## Why v2, not v1

The runbook scoped the audio sub-phase out of v1 because:

1. **The v1 audio path works for the corporate-AV target.** `AudioPump` (`Simple Playback/Playback/AudioPump.swift`) decodes embedded audio from the active cue and routes to a single CoreAudio sink. Operators with AV mixers downstream don't need a routing matrix; they take the program output stereo pair into the mixer and route from there.
2. **The audio matrix is large.** Spec §3.11 calls for 48 kHz / 32-bit float internal, 8 internal channels (16 advanced-later), per-clip + audio-only + background-bed cue types, per-cue per-output volume / mute / fade / crossfade override / routing override, varispeed via `AVAudioUnitTimePitch`, multi-device output (CoreAudio main / aggregate / DeckLink SDI embed up to 16 ch HD), and a project-level routing matrix. That's a coherent sub-phase that must land together — partial delivery (engine without cue types, cue types without per-cue audio) is worse than v1's "embedded-audio-of-current-cue" simplicity.
3. **C15 subtitles are coupled to the engine.** SRT/WebVTT sidecar rendering is conceptually visual but the sidecar parsing + per-output toggle is the same shape as audio routing — both are per-clip metadata streams the compositor layers on top of media. Once the audio engine ships, subtitles slot in as the next concrete layer.

## What "audio sub-phase" means in v1+ terms

Four interlocking deliverables, each multi-commit:

### C12 — Audio engine refactor

A new internal mix-bus that replaces the current `AudioPump` direct-to-CoreAudio shape:

- 48 kHz / 32-bit float internal sample format. Today's `AudioPump` runs at the source sample rate and resamples at the CoreAudio device interface. Mixing multiple cues into a single bus needs a normalized internal rate.
- 8 internal channels (16 in v2.1). Each cue's audio decodes onto a configurable subset of internal channels; the routing matrix at project level maps internal channels onto device output channels.
- **Routing matrix data model**: `[InternalChannel × DeviceChannel] → Float (gain)` per `OutputDevice`. Persisted in the project bundle. UI is a checkerboard editor in the Output inspector.
- **Multi-device output**: a single internal mix-bus fans out to ≥1 `AudioOutputDevice` simultaneously (CoreAudio main, aggregate, DeckLink SDI embed). Each device subscribes to a subset of internal channels per the routing matrix.
- **`AVAudioEngine` is the natural backbone**: nodes for each cue source, a mixer node holding the internal mix-bus, multiple output nodes for multi-device. Today's `AudioPump` is a hand-rolled `AudioQueue`-shape; the migration replaces it.
- **Parity test surface**: the existing AudioPump audio output (per `docs/manual_verification.md`) still works for embedded-audio-of-current-cue, byte-identical to v1, when no audio cues / per-cue audio overrides exist.

### C13 — Audio cue types

Three new cue kinds that compose with existing video cues:

- **Audio-only cue** (`AudioCue`): plays a `.wav` / `.aiff` / `.caf` / `.aac` / `.mp3` file with no associated video. Same continuation / pre-wait / post-wait semantics as a video cue. Renders no video output.
- **Background-bed cue**: plays an audio file *underneath* whatever video cue is active. Survives video-cue changes (until explicitly stopped). One bed channel reserved per project; future per-bed-slot extension v2.1.
- **Per-clip embedded audio cue**: today's behaviour, formalized as the third category. The video cue's audio track is treated as a logical stream that can be muted / faded / re-routed without affecting the video.

### C14 — Per-cue audio overrides

Each cue gains:

- **Volume (dB)** offset from the global cue volume.
- **Mute** toggle.
- **Fade-in / fade-out** independent of the video crossfade (per spec — "per-cue, per-output: volume (dB), mute, fade-in/out, crossfade override, routing override").
- **Crossfade override** lets an audio cue ride a different crossfade duration than the visual transition (e.g., quick visual cut with a slow audio bed transition).
- **Routing override**: this cue's audio goes to internal-channel-subset X regardless of project default.

### C15 — SRT / WebVTT subtitle sidecar

Per spec §3.18:

- Sidecar `.srt` / `.vtt` per clip, auto-detected at import (same basename, conventional extensions).
- Renders in compositor as a **subtitle layer** with style template (font, size, position, drop-shadow).
- Per-output toggle: e.g., burn into stream output, suppress on stage screen.
- Live captions stay v3.

The subtitle layer sits on top of the existing 3-layer compositor (media / bug / message) — making it logically a fourth layer is the right call; spec §3.6 is explicit about the cap of three composited layers in v1, so this requires a spec update first.

## Open product questions

These need an operator-side answer before any code lands:

1. **Routing matrix UX surface — is it the right abstraction for the corporate-AV operator?**
   The matrix is the right *engineering* answer. The operator answer might be: "I just want stereo from the cue, mapped 1:1 to my device's first stereo pair." For 80% of corporate AV uses, the matrix UI is overkill. Choices:
   - **A — Always show the matrix** (simple cases use the diagonal-only matrix).
   - **B — Show "Stereo to default output" by default, expose matrix as an Advanced disclosure**.
   - **C — Two project modes** (Simple / Advanced) with the matrix only available in Advanced.
   - **My recommendation**: B. Most projects never touch the matrix.

2. **Background-bed slots — 1, fixed; or N, configurable?**
   - **A — One bed slot.** Matches QLab's "one bed at a time" posture and the corporate-AV "lobby music + show music" two-slot reality: lobby music is on slot 1 from doors-open; show music takes over slot 1 at house-go.
   - **B — Up to 4 named bed slots.** Lets ambience-on-top-of-music workflows work without juggling.
   - **My recommendation**: B with default 1 (operator configures as needed). Cheap to add at the data-model level; UI can default to "1 bed channel" until operator presses "+ Add Bed Slot."

3. **Sample-rate conversion policy.**
   When the source audio is 44.1 kHz and the internal bus is 48 kHz: resample silently? Surface a warning chip on the cue (like the existing flag warnings)?
   - **My recommendation**: Resample silently with a low-priority info chip in the cue inspector (`MediaFlagWarningChip` extension). The conversion is unavoidable and inaudible; the chip lets a fastidious operator swap a pre-converted file.

4. **DeckLink SDI audio embed channel mapping.**
   SDI carries up to 16 channels per link. v1 ships embed-on by default (B10) but channel-pair routing is hardware-bound and not actually wired. Choices:
   - **A — Default to channels 1-2 only** (stereo program). Operator extends via routing matrix.
   - **B — Default to channels 1-8** (matches internal bus width). Devices that don't carry 8 channels ignore the upper pairs.
   - **My recommendation**: A. Stereo is the dominant case; multi-channel embed is the operator's deliberate choice.

5. **Subtitles: burn-in vs out-of-band.**
   For OBS / Tricaster receivers consuming an NDI stream, burned-in subtitles are usually wrong (the receiver has its own caption rendering). Spec §3.18 says "per-output toggle." Confirm: subtitle layer is rendered into the composed frame *only on Screens whose binding has the toggle on*, default off everywhere except a future "Stream Output" role. Recommend: ship default-off; operator opts in per Screen.

## Dependency map

- **`Playback/AudioPump.swift`** — deprecated by the new `AudioMixBus`. Plan: parity-mode shim during the transition (mix-bus drives a single audio output node, behaviorally identical to AudioPump for the embedded-audio-only case), then retire AudioPump.
- **`Services/AVTrackLoader.swift`** — already shared; the F1 P2 deferred async-API migration (`AVTrackLoader.loadFirstVideoTrackInspection` → true async, no semaphore bridge) is **scoped to land alongside C12** per the session-26 decision-log entry. Doing the migration in isolation reshapes the audio prep path twice; doing it with C12 reshapes it once.
- **`Playback/PlaybackController.swift`** — the `PlaybackController` owns AudioPump today; in v2 it owns the `AudioMixBus` and registers `AudioOutputSink`s in parallel to the existing `TransportSinkRouter`. (Or: a single Sink router that handles video and audio. Decision pending; recommend separate routers — the lifecycles aren't coupled.)
- **`Output/TransportSink.swift`** — sink protocol already carries `submitAudioPCM16(...)`; the v2 redesign should formalize submission as a separate `AudioSinkRouter` because audio device endpoints have different lifecycle / format negotiation than video sinks.
- **`PlayoutProject` data model** — adds `audioRoutingMatrix`, `audioOutputDevices`, `Cue.audioOverrides`, `Cue.kind: .video | .audio | .backgroundBed`, `Slide.subtitleSidecar?: SubtitleSidecar`.
- **`Compositor/CompositorPipeline.swift`** — adds a `subtitleLayer` rendering pass *if and only if* the per-Screen subtitle toggle is on. Sits between the media layer and bug overlay (operator-bug logos overlay subtitles, not vice versa).
- **PreShowCheck** — adds `audio.routing` (does the matrix produce a non-silent output?) and `audio.devices` (every routed device is online).
- **OSC / HTTP API** — `/sp/cue/{id}/audio/level f dB` is already documented in the v1 API as "ack-only, not yet wired" (per `docs/api.md` "not yet wired" appendix); the audio sub-phase is what wires it. Same for `/sp/cue/{id}/scrub/seconds f` for audio cues.
- **Spec update** — §3.6 ("Compositor with three layers") needs amending to four when subtitles land.
- **Existing manual_verification rehearsal** — the AudioPump section (per `docs/manual_verification.md`) becomes the parity-mode rehearsal during transition; new sections cover routing matrix, multi-device, audio-only cues, background bed, subtitles.

## Suggested first-slice (4 sub-phases, in order)

### Phase 1 — C12 mix-bus parity-mode (5-7 commits)

1. **AVTrackLoader async migration** (1 commit) — pre-req per the session-26 decision-log entry. Introduce true `async` entry points on `AVTrackLoader.loadFirstVideoTrackInspection` and `AVTrackLoader.loadFirstAudioTrackInspection`. Migrate MediaImporter / MediaFlagsInspector / AudioPump in parallel.
2. **AudioMixBus skeleton** (1 commit, ~250 LOC + ~150 LOC tests). Pure-logic 48 kHz / 32-bit float mix-bus; pure-logic routing matrix; injectable output sink protocol.
3. **AudioOutputSink protocol + CoreAudioMainSink** (1 commit). Mirrors `TransportSink` shape.
4. **AudioPump → AudioMixBus shim** (1 commit). The mix-bus drives a single sink (CoreAudio main); embedded-audio-of-current-cue routes through. Existing AudioPump tests adapted to drive the mix-bus.
5. **Project schema migration** (1 commit). `audioRoutingMatrix` defaults to identity 1-1; `audioOutputDevices` defaults to `[CoreAudio main]`. Legacy projects decode with defaults.
6. **PlaybackController integration** (1 commit). Replaces AudioPump owner with AudioMixBus owner. Behavior parity verified against existing AudioPump tests.
7. **AudioPump retirement** (1 commit). Delete AudioPump after parity verified. Tests retained against the new shape.

### Phase 2 — C14 per-cue overrides (3-4 commits)

1. **`AudioOverrides` data model** + project schema migration.
2. **AudioMixBus per-cue volume / mute / fade application**.
3. **Cue inspector audio overrides surface** (volume slider, mute toggle, fade pickers).
4. **OSC `/sp/cue/{id}/audio/level f dB` wired through** — finally retires the v1 ack-only stub.

### Phase 3 — C13 audio cue types (4-6 commits)

1. **`Cue.kind: .video | .audio | .backgroundBed`** schema migration.
2. **AudioCue runtime** — fires through CueRuntime same path as video, but the runtime branch differs at "render frame" time (audio-only cues skip the compositor pipeline).
3. **BackgroundBed cue lifecycle** — separate slot in the mix-bus; survives video-cue changes; explicit stop verb (`/sp/bed/stop`).
4. **Inspector + palette UI** for audio cues (different color in the Show List per spec §3.2).
5. **PreShowCheck audio cue resolution** rows.

### Phase 4 — C15 subtitles (3-5 commits)

1. **`SubtitleSidecar` import** — auto-detect `.srt` / `.vtt` next to a video file at import.
2. **Subtitle parser** — pure-logic SRT + WebVTT → cue-time-table. Ship the subtitle parser as a leaf service first, with a fixture-synthesis test pattern (mirrors `MediaImporter` test seam shape).
3. **Compositor subtitle layer** — fourth layer between media and bug, gated per-Screen.
4. **Per-Screen subtitle toggle** in the Output inspector.
5. **Spec update**: §3.6 layers cap moves from 3 to 4.

### Phase 5 — Multi-device output + DeckLink SDI embed (3-4 commits)

1. **DeckLinkAudioSink** alongside the existing DeckLink video sink. Wires SDI audio embed channel-pair routing (B10 unblocked).
2. **AggregateDeviceSink** / generic CoreAudioSink covering aggregate devices.
3. **Routing matrix UI** — checkerboard in the Output inspector advanced disclosure.
4. **Multi-device manual-verification section** in `docs/manual_verification.md`.

## Risks / unknowns

- **CoreAudio device-disconnect handling.** Operators hot-plug Thunderbolt audio interfaces (Apollo Twin, etc.) mid-show; the mix-bus needs a "device went away" recovery path. Mirror the v1 hot-unplug story for video (B15, hardware-bound).
- **Latency budget.** Audio adds tens of ms of buffering on top of the v1 video pipeline; matching A/V phase across multiple devices is an open problem (per-device output latency offsets per project). Recommend punting to v2.1 once a real rehearsal surfaces the offset values needed.
- **CoreMIDI / MTC chase implications.** D13 MTC chase routes through CoreMIDI today; the audio refactor doesn't touch it, but a shared audio queue between AudioMixBus and the LTC input listener (D12) wants verification.
- **Subtitle font / Unicode coverage.** WebVTT supports color/position cues that map awkwardly onto a SwiftUI text rendering. Recommend: ship plain text rendering first, ignore unsupported VTT directives, log "directive ignored" once.

## When to revisit

- Audio sub-phase becomes a marketing differentiator → bias toward shipping all four sub-phases together.
- Operators ask for >16 internal channels → expand to 32 (cheap; just a constant).
- Live captions land as a v3 ask → C15 subtitle layer is the foundation; revise to support a real-time stream input alongside the sidecar.

## Estimated effort

20-26 commits across the four phases (parallelizable across sessions but not within a single session — each sub-phase needs its own integration window). ~3500-4500 LOC + ~1500-2000 LOC tests. The largest single piece is the C12 mix-bus refactor (~7 commits).
