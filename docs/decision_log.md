# Decision Log

Append-only. Every non-obvious choice made during the autonomous build, with rationale and alternatives. Most recent entries at the bottom (newest commits at the bottom of git log; mirror that here so a `tail` reads the latest).

Format per entry:

```
## YYYY-MM-DD HH:MM — <topic>

**Decision**: <what>

**Why**: <rationale>

**Alternatives considered**: <list>

**Reversibility**: easy / medium / hard

**What I'd revisit if**: <signal>
```

---

## 2026-05-07 — Pre-kickoff decisions

The decisions captured in `docs/runbook.md` §1 are recorded there as the starting contract. This log records decisions made *during* the build.

---

## 2026-05-07 — A1: bundle format approach

**Decision**: One UTI (`com.josh.simpleplayback.project`) re-declared as conforming to `com.apple.package` + `public.composite-content`. NSDocument always writes a directory bundle containing `Show.json`. Read accepts both legacy regular-file `.spb` and v2 directory `.spb`.

**Why**: The two-UTI approach (separate identifiers for legacy vs v2) doubles the Info.plist surface and confuses Finder when both extensions overlap. A single UTI with permissive read is simpler and matches how Final Cut migrated `.fcpbundle`.

**Alternatives considered**:
- Two-UTI scheme with explicit "legacy" type → more surface, marginal benefit at v0.1.x.
- Stay flat JSON, defer bundle to a later phase → would force a second migration round-trip; fixed schema cost up front is cheaper.

**Reversibility**: medium. Could revert by removing `com.apple.package` from `UTTypeConformsTo`, but any users who have already saved a directory `.spb` would need a manual upgrade. Low risk at v0.1.x install base.

**What I'd revisit if**: Finder ever shows directory `.spb` files as folders rather than packages — would imply the UTI conformance isn't taking effect. Look at `lsregister -dump | grep simpleplayback` for diagnosis.

**Public API impact**:
- `PlayoutProject.formatVersion` now exists; defaults to `currentFormatVersion` (2) on init, decodes as 1 when the field is absent.
- `PlayoutProject.markCurrentFormatVersion()` upgrades a loaded legacy project. Called automatically inside `fileWrapper(ofType:)`.
- `SimplePlaybackProjectDocument.projectData(from:)` is the bundle-or-flat extraction helper exposed for tests.
- `ProjectBundleLayout.projectFilename` ("Show.json") names the central JSON inside the bundle.

---

## 2026-05-07 — B5: contained rewrite vs full driver replacement

**Decision**: Keep `VideoOutputDriver`/`CompositeVideoOutputDriver` as the (deviceID, modeID) primary-output surface used by `OutputSettingsStore` and the existing UI. Reimplement the concrete drivers as thin shims around the new `DeckLinkTransportSink` / `PreviewTransportSink`. Add a `TransportSinkRouter` to `PlaybackController` for *auxiliary* sinks; primary still flows through the driver, but every composed frame and audio block now also fans out to the router's auxiliary sinks.

**Why**: The recommended Phase B order said "contained rewrite that preserves existing behavior while opening the door for the rest." A clean primary→router migration would touch `OutputSettingsStore`, `RootView`, `OutputStatusBar`, the existing `PreviewVideoOutputDriver` test, and `PlaybackController` in one commit — tightly coupled, hard to land green per sub-task. The shim approach gets the same fan-out capability (B11 NDI can register a sink today) at a fraction of the diff, and a future B-phase can fully retire the driver layer in a second pass without breaking the rendering hot path.

**Alternatives considered**:
- Replace the driver layer wholesale with a `VideoOutputDeviceCatalog` + router-as-primary architecture. Rejected — too many touchpoints in one phase, and the existing `PreviewVideoOutputDriver` test would need to change shape.
- Skip auxiliary sinks for now and just ship the `TransportSink` protocol. Rejected — the protocol without a fan-out path is nominal-only; the `PlaybackController` integration is what proves the protocol works.

**Reversibility**: easy. The auxiliary router is purely additive — `PlaybackController.register(sink:)` is a new public API, and existing callers' rendering path is unchanged. Deleting it is a one-commit revert.

**What I'd revisit if**: a second DeckLink port (B6/B7) needs to drive its own primary output — at that point the driver-as-primary cap becomes painful and the catalog/router-as-primary refactor pays for itself. Track this in B6.

**Public API impact**:
- `protocol TransportSink` (sinkID, label, status, isRunning, activeStage, start/stop/submit).
- `struct TransportSinkStage` — Stage parameters as a sink needs them; init from `Stage`.
- `final class TransportSinkRouter` — fan-out + per-sink error capture.
- `PlaybackController.register(sink:)` / `unregister(sink:)` — register an aux sink; auto-starts if output is already running.

---

## 2026-05-07 — B12: cache base frame, not composed frame

**Decision**: `PlaybackController.submitFrame` runs the input frame through `CompositorPipeline.compose(...)` before handing off to driver/router, but the cached `currentFrame` (which seeds the *start* of the next crossfade) is the **base** frame, never the composed one. The composed frame is also what's published to `transitionPreviewImage`.

**Why**: Bug/message overlays are persistent across takes — they need to render on every frame at submit time. If the cache held the composed frame, the next crossfade would (a) blend "previous-with-overlay" against "next-base", and (b) re-composite the overlay on top of the result, double-baking the bug. By caching the base, every transition blends base→base, and the overlay is applied exactly once at submit.

This also means the overlay "snaps in" instantly when toggled on (the cached base is overlay-free, so the next submit composites on the live overlays). That matches operator expectations more than the alternative (waiting until the next take to see overlays appear).

**Alternatives considered**:
- **Cache composed, skip composite when serving cached frames**. Adds branching in `submitFrame` and breaks down for blended transitions where the source is *partially* cached. Rejected.
- **Move the composite step to a higher layer (between renderer and submit)**. Would force every code path that calls `submitFrame` (clear, still-transition, video-frame, outgoing-handoff, prepared-image-commit) to remember to composite. The single composite point inside `submitFrame` is the choke point that catches all of them.

**Reversibility**: easy. The composite call lives in one method; reverting is one edit.

**What I'd revisit if**: Phase B13 (color pipeline) needs to see the *base* frame in linear-light before overlays land — at that point the composite step likely splits into "color → media+bug → text" and the cache decision moves accordingly.

**Public API impact**:
- `struct CompositorOverlays`, `struct BugOverlay`, `struct MessageOverlay`, `enum BugCorner`, `enum MessagePosition`, `struct RGBAColor` in `Models/CompositorLayers.swift`.
- `Stage.compositorOverlays` (codable, defaults to `.empty` for legacy projects).
- `final class CompositorPipeline` in `Playback/CompositorPipeline.swift` — `compose(baseFrame:overlays:canvasSize:nowDate:)`, `formatCountdown`, `renderedMessageText(overlay:nowDate:)`, `invalidateBugImageCache()`.
- `PlaybackController.compositorOverlays: CompositorOverlays` — mutable, `didSet` flushes the bug image cache on media change.

---

## 2026-05-07 — B12d: Overlays inspector layout (segmented mode picker)

**Decision**: Add a `Selection` / `Overlays` segmented picker at the top of the right-hand inspector pane in `RootView`. Selection mode keeps the existing cue / slide inspectors (whichever is selected). Overlays mode binds to `project.stages[0].compositorOverlays` and shows the new `OverlayInspectorView` (bug + message sections).

**Why**: The session prompt flagged this as "stop-and-ask territory" because operator UX is at stake. Two reasonable options were considered:

- **A: Segmented mode picker (chosen).** One inspector pane, a small picker at the top toggles between selection-driven inspector and overlays-driven inspector. No new tear-off, no new column.
- **B: Always-visible "Stage Overlays" section appended below the cue/slide inspector.** Simpler discoverability, but pollutes the inspector when the operator is editing a cue and adds vertical pressure.

A went out under Auto Mode because: (a) `Overlays` is project-level state, not selection-level, so blending it with cue/slide inspectors is conceptually muddy; (b) the operator's mental model already has a "what's selected vs what's the project doing" split (the cue inspector vs slide inspector swap is the same pattern); (c) keyboard shortcuts (e.g. quick-toggle "STAND BY") are a separate, larger product decision and weren't bundled into this change.

If operators dislike the discovery cost ("they didn't notice the picker"), the right next move is a status-bar indicator that says "Overlays: bug + message active" with a click-to-jump affordance — not folding overlays into the selection inspector.

**Alternatives considered**:

- **Always-visible section**: rejected, see above.
- **Tear-off Overlays window**: too heavy for v1; matches the spec's "tear-off" pattern but adds windowing complexity for a panel the operator visits once per show.
- **Settings sheet**: rejected — modal-ish, and Show Mode forbids modals (spec §3.5).

**Reversibility**: easy. Picker is two states; either could be dropped without affecting the data model.

**What I'd revisit if**: operators ask for one-keystroke "STAND BY" toggling during show — that probably wants a hotkey + status-bar toggle rather than going through the inspector at all. Bundle with a future "Operator UX" task; do not retrofit into the inspector.

**Public API impact**:
- `OverlayInspectorView(overlays: Binding<CompositorOverlays>)` in `Views/OverlayInspectorView.swift`.
- `enum InspectorMode { case selection, overlays }` in `Views/RootView.swift`.
- `RGBAColor(color: SwiftUI.Color)` extension for the inspector's color pickers (sRGB-anchored via `NSColor.usingColorSpace(.sRGB)`).
- `ShowController.applyCompositorOverlays(_ overlays: CompositorOverlays)` — single forwarder into `PlaybackController.compositorOverlays`. Called by `RootView` on `.onChange` of the first stage's overlays and once at controller configuration.

