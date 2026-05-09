# v2 Pre-Scope — NDI Full Sender (B11)

**Status**: pre-scope (planning only — no code).
**Filed**: 2026-05-08, session 27.
**Spec source**: `docs/spec/feature_spec.md` §3.6 ("Transport bindings per Screen … NDI Full sender") and §3.8 ("NDI Full sender as a transport binding for any Screen. Configurable sender name. Use cases: ATEM ingest, Tricaster, OBS contribution, redundant feed to backup machine, multi-viewer feed. NDI HX is out of scope for v1.").
**Progress source**: `docs/progress.md` B11 ("NDI Full sender as a transport binding") — listed but not started; deferred per `docs/handoff.md` "Hardware-bound" / "v2 enablement candidates".

---

## Why v2, not v1

Two coupled blockers, both operational rather than technical:

1. **NDI SDK distribution decision.** The NDI Advanced SDK (which provides the `Send` API needed for Full output) is licensed by NewTek/Vizrt; v1 doesn't ship the binary because (a) the license needs to be reviewed for redistribution-in-an-app-bundle, (b) the binary is sub-bundled and signed/notarized as part of the Simple Playback release, which touches `Distribution/` infra that's out of bounds for autonomous changes (`runbook.md` §5).
2. **No real-world receiver verification possible without hardware/software downstream.** B11 sits squarely in the hardware-bound bucket — even with the SDK in place, "the NDI Full sender works" means "an ATEM Constellation / Tricaster / vMix / OBS / a second Mac running NDI Studio Monitor receives the feed at the right resolution / frame rate / color." That's a rehearsal-cycle deliverable.

The v1 transport architecture (B5) was designed against `protocol TransportSink` in `Output/TransportSink.swift`; an NDI sender is just one more sink implementation. The protocol was specifically shaped so this work can land additively without touching the rendering hot path.

## What "NDI Full sender" means in v1 terms

Adding a `NDITransportSink: TransportSink` that:

- Implements `start(stage:)` / `stop()` / `submitVideo(...)` / `submitAudio(...)`.
- Owns an `NDIlib_send_instance_t` and converts each composed frame to an `NDIlib_video_frame_v2_t` for `NDIlib_send_send_video_v2`.
- Surfaces `sinkID` / `label` / `status` / `isRunning` / `activeStage` like every other sink.
- Registers via `PlaybackController.register(sink:)` once the operator binds an NDI output to a Screen role.

The pixel-format conversion is the meatiest part: NDI Full uses UYVY (4:2:2 8-bit packed) or PA16 (4:2:2 16-bit) for video; our compositor emits CVPixelBuffer in BGRA. A small `NDIPixelConverter` helper handles the BGRA → UYVY repack with vImage acceleration (already a system framework; no new deps).

NDI HX (the compressed long-GOP variant) stays out of scope — operators wanting bandwidth-efficient receive run NDI Tools' built-in HX bridge.

## Open product questions

These need an operator-side answer before any code lands:

1. **SDK distribution path.**
   - **A — Bundle the NDI Advanced SDK redistributable in the app bundle.** Cost: ~5 MB additional sub-bundle, license review + per-version Simple Playback release notes, sub-bundle signing/notarization. Operator install: zero — works out of the box.
   - **B — Detect installed NDI Tools / NDI SDK on the host, fall back to "NDI not available" sink state otherwise.** Cost: lower binary footprint, but the operator either has NDI Tools installed or doesn't; "go install NDI Tools first" is a real friction point at FOH.
   - **C — Both, with bundled SDK preferred.** Belt-and-suspenders; doubles the path-resolution test surface.
   - **My recommendation**: A. The 5 MB delta is dwarfed by the ProRes binary footprint already in the SDK / Sparkle delta size. The license review is a one-time cost.

2. **Sender name discovery / configurability.**
   The spec line says "Configurable sender name." Choices:
   - **A — Always project name + Screen role** (e.g., `<projectName> · Confidence`). No UI surface needed. Discoverable on the receive side without operator config.
   - **B — Operator-editable in the Output inspector**, defaulting to (A). Lets the operator hide that this is Simple Playback (e.g., name it `Program Feed` for vendor-neutral routing).
   - **C — Per-Screen + per-machine override**. Like Bonjour-name customization in macOS Sharing prefs.
   - **My recommendation**: B. One text field in the NDI binding panel of the Output inspector tab, defaulting to (A).

3. **Sender groups.**
   NDI senders can be grouped (e.g., `Public` / `Backstage`) for receiver filtering. Two operators sharing a venue subnet may want this. Choices:
   - **A — Always send on default group** (no grouping). Matches v1 simplicity.
   - **B — Operator-editable group string in the Output inspector.** Optional; empty = default group.
   - **My recommendation**: B. Cheap to add (single string field forwarded to `NDIlib_send_create`), high upside in multi-show venues.

4. **Audio embed default.**
   NDI Full carries audio inline. Send by default? Choices:
   - **A — Send audio with NDI by default**, identical to SDI-embed posture (`docs/progress.md` B10 default-on).
   - **B — Off by default, opt-in** to avoid double-routed audio when the operator runs a separate audio path.
   - **My recommendation**: A. Mirror the SDI behaviour. The operator who wants NDI-video-only mutes the audio toggle in the same panel.

5. **Color space tagging.**
   NDI carries a color-info hint per frame (BT.601 / BT.709 / BT.2020). Spec §3.9 pins working space to BT.709 limited; the NDI hint should match. Recommendation: lock to BT.709 limited at v2 launch; revisit if/when a per-Screen color override path adds BT.2020.

## Dependency map

- **`protocol TransportSink`** in `Output/TransportSink.swift` — already supports the shape of NDI; no protocol changes needed.
- **`Output/TransportSinks.swift`** — concrete `DeckLinkTransportSink` and `PreviewTransportSink` live here. Add `NDITransportSink` next to them.
- **`Compositor/CompositorPipeline.swift`** — produces the composed `CGImage`/`CVPixelBuffer` that's fanned out by `TransportSinkRouter`. No changes; the sink owns its own format conversion.
- **`OutputBindingProfile`** (B4 — schema only today) needs an NDI binding case alongside DeckLink / OS Display / NDI / Syphon / Window. Already in the abstraction; reuse.
- **`Views/RootView.swift` Output inspector tab** — adds an "NDI" sub-section with sender-name + group + audio-toggle fields. Mirrors the existing DeckLink section's shape.
- **`PreShowCheck`** — add a `network.ndi` row when an NDI binding is configured: "NDI sender running" green / "Sender create failed" red. The `Services/PreShowCheckAdapters.swift` pattern is the entry point.
- **Entitlements** — NDI mDNS discovery requires `com.apple.security.network.client` (already shipped for Bonjour-OSC discovery in D5) and `com.apple.security.network.server` for the sender side. Verify both are present in `Simple Playback.entitlements`.
- **`Distribution/`** — sub-bundle signing scripts need updating to sign the NDI redistributable. Out-of-scope for autonomous changes; flag as a release-engineering deliverable in the v2 cut-over PR.

## Suggested first-slice (assumes Option A — bundle SDK)

1. **SDK ingestion + license decision** (1 commit, doc-only).
   - Record the SDK version, license SHA, redistribution scope in `decision_log.md`.
   - Update `runbook.md` §1 if the dependency-size policy needs amending (NDI SDK is well under 100 MB).

2. **NDI bridge skeleton** (1 commit, ~150 LOC).
   - Vendor the NDI headers under `External/NDI/` (mirrors the `Blackmagic DeckLink SDK 16.0/` layout).
   - Thin Swift wrapper: `NDIBridge.send_create(name:groups:)` / `send_destroy` / `send_send_video_v2` / `send_send_audio_v3`.
   - No sink yet; just the C interop layer that's testable in isolation against a stub.

3. **NDIPixelConverter** (1 commit, ~120 LOC + 60 LOC tests).
   - BGRA → UYVY repack via vImage. Pin output stride / row-bytes / endianness.
   - Pure-logic test: synthesize a 4×2 BGRA buffer with known values, pin the 4×2 UYVY output bytes.

4. **NDITransportSink** (1 commit, ~200 LOC + 80 LOC tests).
   - Implements `protocol TransportSink`. Lifecycle: `start(stage:)` creates the NDI sender; `submitVideo(...)` repacks + sends; `stop()` destroys.
   - Test seam: `bridge` / `converter` injected so unit tests don't need a real NDI runtime.
   - Pin: start fans through to `bridge.send_create` once; stop calls `send_destroy` once; submit forwards a video frame.

5. **Audio embed** (1 commit, ~80 LOC + 40 LOC tests).
   - `submitAudio(...)` converts the float32 mix-bus to NDI's float32 planar format (no resampling — internal mix-bus is already 48 kHz / 32-bit float per spec §3.11).
   - Audio-mute toggle is consumed at the sink level (drops the audio frames; video keeps flowing).

6. **Output inspector NDI sub-section** (1 commit, ~150 LOC).
   - Sender name + group string fields; audio toggle; "NDI sender running" status pill driven by `sink.status`.
   - Wired through `OutputBindingProfile.ndiBinding` (new case).

7. **PreShowCheck `network.ndi` row** (1 commit, ~60 LOC + 40 LOC tests).
   - "NDI sender running" green / "Sender create failed" red. Fix action: the inspector NDI sub-section.

8. **Phase summary + rehearsal section** (1 commit, doc-only).
   - `docs/phase_b_summary.md` adds an NDI section with manual rehearsal items (verify sender appears in NDI Studio Monitor on a sibling Mac; verify resolution / frame rate / color / audio embed).

## Risks / unknowns

- **Receiver-side variability.** Different NDI receivers handle the color hint inconsistently; a real rehearsal against an ATEM Constellation, a Tricaster, vMix, OBS, and NDI Studio Monitor is the verification artifact. Likely produces a few "tweak the color hint per receiver class" decisions.
- **Discovery on multi-NIC hosts.** NDI's mDNS discovery binds to a NIC; show machines often have a video LAN + a control LAN. The SDK has a `groups` parameter but multi-NIC routing is in the `NDIlib_send_create_v2_t` extended struct. May need to expose NIC selection in v2.1.
- **Sub-bundle notarization first-cut.** Apple's notary occasionally rejects nested signed binaries on the first submission; budget release-engineering time.

## When to revisit

- Customers ship NDI HX-only receivers → re-scope to add NDI HX (separate SDK feature, more compression work).
- Multi-NIC routing surfaces as a real deployment problem → ship NIC selection.
- Vizrt changes the SDK license terms → re-evaluate the bundled-vs-detect choice.

## Estimated effort

7-9 commits, ~700-900 LOC + ~250-350 LOC tests. The release-engineering side (sub-bundle signing) is wall-clock-blocked on a release cycle, not commit count.
