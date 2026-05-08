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

---

## 2026-05-07 — B6b: project-level REF expectation lives in Output inspector tab (not Stage)

**Decision**: Add a third inspector tab `Output` (alongside `Selection` and `Overlays`) and house the new project-level `expectsExternalReference: Bool` toggle there. The `OutputStatusBar` accepts a new `referenceExpected: Bool` parameter; when true and the active DeckLink reports `unlocked`, a full-width red banner ("REF EXPECTED — Output is free-running") renders **above** the existing chip+status row. The orange chip stays orange (the loud signal moves to the banner), keeping the layered legibility consistent with §3.15 ("color is never the only signal").

**Why**:
- Per the session prompt, the toggle is *project-level*, not per-Stage. A show file declares one REF expectation that travels between venues alongside resolution and color.
- The toggle didn't fit cleanly inside the existing `Overlays` inspector — overlays are §3.6 compositor concerns; REF is §3.7 transport hardening. Mashing them together would muddy the operator's mental model and make future B7/B13 additions awkward.
- Rather than burying the toggle behind a settings sheet (which Show Mode forbids per §3.5 anti-modal rule), surfacing it as a first-class inspector tab keeps it discoverable in both Edit and Show modes and gives B7 (format negotiation), B8 (10-bit YUV), B13 (color pipeline) a home to grow into without further tab sprawl.
- The banner-vs-chip split means the operator gets two complementary signals: the persistent chip ("REF: Free-run") and the loud above-status-row banner. Either alone could be missed in a dim booth; together they're hard to miss. The runtime cost is two `View`s, no new state.
- Banner suppression on `idle` and `notSupported` is deliberate — those states are not contradictions of the operator's expectation. `idle` ⇒ no DeckLink running yet, the red banner would be noise. `notSupported` ⇒ user-error message that belongs in pre-show check (E1), not a render-time alarm.

**Alternatives considered**:
- **Extend the `Overlays` tab with a "Reliability" section.** Rejected: semantic mismatch (§3.6 vs §3.7) and forces a future B13 color section into the same already-overloaded tab.
- **Settings sheet bound to `PlayoutProject`.** Rejected: modal-ish, conflicts with §3.5 modal-forbidden invariant in Show Mode, and operators editing the project mid-show shouldn't have to summon a sheet to verify REF expectation.
- **Per-Stage `expectsExternalReference`.** Rejected: prompt explicitly says project-level; multi-stage projects are rare in v1, and a single project-wide flag is simpler to reason about for the venue-portable show-file case (§2.2).
- **Banner replaces the chip rather than stacks above it.** Rejected: removes the persistent "REF: <state>" hint after the operator dismisses or scrolls past the banner; a chip-only layout was previously informational-only (orange) and the banner's job is escalation, not replacement.

**Reversibility**: easy. The `expectsExternalReference` field is `decodeIfPresent`-defaulted to `false`; the inspector tab's enum case is additive; the banner is a `VStack` row that disappears when the boolean is false. Reverting is a one-commit revert with no data migration.

**What I'd revisit if**: a future operator UX pass shows the banner is too easy to miss while running cues (the operator's eyes are on Program/Preview tiles, not the status bar). At that point the right move is probably a status-bar-anchored toast that fades after 5s rather than a persistent banner — but that's `OutputStatusBar` work, not an `expectsExternalReference` model change. Track in the Operator UX backlog.

**What this does NOT do** (deferred follow-ups for the next session):
- REF format-mismatch detection vs Stage frame rate. The `IDeckLinkOutput_v15_3_1` interface used by `SPDeckLinkBridge` does not expose REF input timing. A small SDK-API spike (`IDeckLinkProfileAttributes::BMDDeckLinkSupportsReferenceInputTimingOffset`?) is required before scoping, and the ground-truth verification needs real REF generator hardware. Filed as the remaining `[~]` follow-up on B6.
- Pre-show check (E1) reuse: when E1 lands, the same `expectsExternalReference` flag should drive a pre-show "REF locked?" row, not just a render-time banner.

**Public API impact**:
- `PlayoutProject.expectsExternalReference: Bool` — codable, defaults to `false` for legacy projects via `decodeIfPresent`.
- `enum InspectorMode { case selection, overlays, output }` in `Views/RootView.swift`.
- `OutputInspectorView(project: Binding<PlayoutProject>)` in `Views/OutputInspectorView.swift` — Stage summary + Reliability section housing the toggle.
- `OutputStatusBar.referenceExpected: Bool` — new parameter (defaults to `false` so existing call sites compile, but `RootView` always passes the live value from the project).
- `OutputStatusBar.evaluateFreeRunBanner(referenceExpected:referenceState:) -> Bool` — pure helper, exposed for testability without standing up a `PlaybackController`.

---

## 2026-05-08 — C3: PDF rasterize destination + import-context shape

**Decision**: Rendered PDF→PNG sidecars live inside the project bundle at `Cache/Renders/<batchUUID>/page_NNN.png` whenever the document has been saved (i.e. `NSDocument.fileURL != nil`). For untitled documents, fall back to `~/Library/Application Support/Simple Playback/Renders/<sessionUUID>/<batchUUID>/page_NNN.png` so PDF import works the moment the operator drags a deck into a fresh window. The on-disk PNG layout matches spec §3.17's `Cache/Renders/` directive.

The plumbing shape: `MediaImporter.importSlides(from:)` keeps its old signature (silently drops PDFs — back-compat) and gains an overload `importSlides(from:context:)` that takes a `MediaImportContext { rasterSize: CGSize, renderRootDirectory: URL }`. RootView builds the context per-import; the bundle URL is supplied to RootView via a `[weak self] in self?.fileURL` closure passed by `SimplePlaybackProjectDocument.makeWindowControllers`.

**Why**:
- **Bundle-relative renders match spec §2.2 venue portability.** A `Bundle for Travel` pass (still TBD) would copy linked media into the bundle; renders living inside the bundle from day one means there's nothing extra to migrate. Final Cut's `.fcpbundle` and Logic's `.logicx` follow the same pattern.
- **Untitled-doc fallback to App Support** rather than temp-dir avoids the "first launch, drop a PDF, restart, slides are gone" failure mode (`NSTemporaryDirectory()` is purged unpredictably). App Support persists; a `[sessionUUID]` keyed subdirectory keeps concurrent untitled windows independent.
- **Context-aware overload (not single-method, not new top-level service)** keeps the call shape `MediaImporter.importSlides(from:context:)` familiar and keeps non-PDF media on its existing fast path. A new top-level `PDFImporter` service would have orphaned the existing `mediaKind` UTType detection logic (UTI-aware drop targets need a single is-this-importable predicate).
- **Closure-based bundle-URL provider** (`() -> URL?`) rather than a `Binding<URL?>` because `NSDocument.fileURL` is KVO-observable but not a published Combine source; a closure is read on every import with no observation cost and stays nil-safe if the NSDocument is deallocated mid-window-lifetime.
- **Output × 2 raster (spec §3.10)**, scale-to-fit aspect-preserving (not stretch, not crop). PDF page aspect varies per source (Letter, A4, 16:9 export, 4:3 export); stretch would distort PowerPoint→PDF→PNG decks; crop would silently lose content. The compositor's `ScaleMode` is the right place to express scaling intent per cue, not the rasterizer.

**Alternatives considered**:
- **Always App Support, copy into bundle on save** — operator's filesystem stays clean but venue portability requires every save to copy potentially gigabytes of PNGs. Rejected: rejected for the same reason Final Cut keeps `Renders/` in the bundle.
- **Sidecar folder next to PDF source** (`MyDeck.pdf` + `MyDeck.pdf.renders/`) — rejected: clutters the user's filesystem; breaks portability when the source PDF moves.
- **Temp dir** — rejected: not persistent; first launch cycle of imports would vanish.
- **Render at `rasterSize` literally with stretch** — rejected for the aspect-preservation reasons above.
- **Single-method `MediaImporter.importSlides(from:rasterSize:renderRoot:)` overload** — rejected: forced every caller (UI, future automation, future CLI) to know about render-root semantics even when they're importing only video. The optional context is a smaller cognitive load.
- **Put `Cache/Renders/` path constant directly in PDFImporter** — rejected: layered separation. `ProjectBundleLayout.rendersDirectory` belongs with the other bundle path constants (`projectFilename`); PDFImporter is bundle-agnostic and can be reused outside the document-bundle world (CLI tooling, future Bundle-for-Travel logic).

**Reversibility**: easy. `MediaImportContext` and the new overload are additive. `importSlides(from:)` (no context) still works; existing tests continue to pass unchanged. Reverting C3 = delete `PDFImporter.swift` + `MediaImporterPDFTests.swift` + the `importSlides(from:context:)` overload + the RootView `currentMediaImportContext` helper. Saved projects keep their PNG references via absolute path; opening such a project after a revert just shows them as offline images.

**What I'd revisit if**:
- Operators report the App Support fallback feels unsafe (e.g., "I dropped a PDF into an untitled doc, my disk filled up, I had to find this hidden directory to clean it"). At that point either prompt-to-save before allowing PDF import, or auto-cleanup on app-quit when the session UUID never had a corresponding save.
- Stage resize mid-project leaves stale low-resolution renders (the asset library would need to track raster size per slide and offer a "Re-rasterize" action).
- `Cache/Renders/<batchUUID>/` accumulates orphaned batches when slides are deleted (no GC today). A future "Compact project" action would walk the bundle and remove batches no `MediaSlide` resolves to.

**Public API impact**:
- `enum PDFImportError: LocalizedError` — `.unreadable(URL)`, `.noPages(URL)`, `.writeFailed(URL, underlying: Error)` in `Services/PDFImporter.swift`.
- `enum PDFImporter` with `static func rasterize(pdfURL: URL, rasterSize: CGSize, destinationDirectory: URL) throws -> [URL]`.
- `struct MediaImportContext { rasterSize: CGSize; renderRootDirectory: URL }` in `Services/MediaImporter.swift`.
- `MediaImporter.importSlides(from urls: [URL], context: MediaImportContext?) -> [MediaSlide]` overload; legacy `importSlides(from:)` preserved.
- `MediaImporter.isPDF(_:)` static predicate (UTType-aware) — exposed for testability.
- `ProjectBundleLayout.rendersDirectory = "Cache/Renders"` in `Models/SimplePlaybackProjectDocument.swift`.
- `RootView.init(document:outputSettings:projectBundleURLProvider:)` — third argument is a `() -> URL?` closure (defaulted to `{ nil }` so existing test call sites compile).
- `SimplePlaybackProjectDocument.makeWindowControllers` passes `{ [weak self] in self?.fileURL }`.


---

## 2026-05-08 — C6: Keynote import shape, AppleScript driver, diagnostic surface

**Decision**: Keynote import is a thin shell that drives Keynote via `NSAppleScript` to export `.key` → PDF, then reuses the C3 `PDFImporter.rasterize` plumbing. The exporter is a `static var` on `MediaImporter` so tests can inject a stub PDF without invoking Keynote. The "Keynote not installed" diagnostic is a modal `NSAlert` triggered at import time when any dropped/picked URL is `.key` and the workspace can't resolve `com.apple.iWork.Keynote`. Hardened-runtime requires `com.apple.security.automation.apple-events` entitlement and a `NSAppleEventsUsageDescription` Info.plist string; both shipped this session.

**Why**:
- **Reuse over reinvent** — The C3 PDFImporter is exactly the rasterizer Keynote needs. Sharing the `MediaImportContext` keeps `Cache/Renders/<batchUUID>/` layout consistent across PDF and Keynote sources, so a future "Re-rasterize on Stage resize" action only has to know about one render destination shape.
- **Injectable exporter** — Real Keynote can't run in CI; the `static var keynoteExporter` lets unit tests pin the routing chain (URL → exporter → PDFImporter → image MediaSlides) end-to-end with a synthetic PDF, while the default still drives the real AppleScript at runtime. Cleaner than dependency-inverting `MediaImporter` itself, which would force every call site to thread an importer instance.
- **Modal NSAlert (not a banner)** — Spec §3.10 says "Surface a clear 'Keynote not installed' diagnostic if absent." A banner system doesn't exist yet (deferred from C3) and would be premature scope. NSAlert is honest, dismissible, and only fires from Edit Mode (addMedia is `showMode`-guarded), so the §3.5 "no modals in Show Mode" invariant holds.
- **Entitlement + usage description** — Hardened runtime (`ENABLE_HARDENED_RUNTIME: YES` on Release) blocks Apple Events without `com.apple.security.automation.apple-events`. macOS still presents its standard "Allow Simple Playback to control Keynote?" prompt on first send; the usage description is the message inside that prompt. Pre-prompt UX (custom dialog before the macOS one) was explicitly rejected by the next-session prompt — stock prompt is already prescriptive.

**Alternatives considered**:
- **Drive `osascript` via `Process`** (subprocess) instead of `NSAppleScript` — works without the Apple Events entitlement on the *parent*, but `osascript` runs as a child and *still* needs Apple Events permission, just routed through `osascript`'s own usage description. No saving; adds process-spawn overhead and error-message surface area.
- **Use the Keynote AppleScript Bridge (sdef-generated headers)** — produces stronger compile-time types but requires `sdef`/`sdp` build steps and a generated `Keynote.h` file. Strict-concurrency-warning surface is non-trivial. The simple `NSAppleScript` text path is what most third-party apps use (Hazel, Alfred, Default Folder X). Faster to ship, easier to test.
- **Rasterize Keynote's PDF export at a different `rasterSize`** (e.g. literal Stage size, not ×2). Rejected: spec §3.10 says "output × 2" for PDF rasterize-on-import; Keynote's PDF intermediate is a PDF too — same pixel target.
- **Pre-prompt before macOS's** "Allow Simple Playback to control Keynote?" — rejected. macOS's prompt is sufficient and already names the target app.
- **Banner instead of modal alert** — rejected for now (no banner system yet); revisit when the C3 import-status banner work lands.

**Reversibility**: easy. Revert = drop `KeynoteImporter.swift`, `KeynoteImporterTests.swift`, `MediaImporterKeynoteTests.swift`, the `importKeynote(at:context:)` branch in `MediaImporter`, the `keynoteExporter` static var, the open-panel `.key` content type, `presentKeynoteNotInstalledAlert`, the Apple-events entitlement key, and the `NSAppleEventsUsageDescription` string. No persisted state changes — `MediaSlide` round-trips are unaffected. Saved projects with Keynote-derived slides keep their PNG references; opening one after revert shows them as offline images at most.

**What I'd revisit if**:
- Real-Keynote rehearsal reveals the AppleScript needs an explicit `with properties {export style:IndividualSlides}` clause (Keynote occasionally exports as a single-page "handout" PDF). Add the property; pin shape in `testExportAppleScript…`.
- Keynote prompts for password on encrypted decks — current AppleScript hangs on the dialog. Add a timeout (`NSAppleScript.executeAndReturnError` is synchronous; could move to `Process` + `osascript -e` with a hard timeout) and an `.passwordProtected` error case.
- Operators report the modal alert is annoying when batch-dropping mixed media (PDF + .key + .mov). Switch to an aggregated banner once the import-status banner ships.
- The first-run macOS prompt's UX is genuinely confusing in a dim booth (operator dismisses it before reading) — add a pre-prompt then.

**Public API impact**:
- `enum KeynoteImportError: LocalizedError` — `.keynoteNotInstalled`, `.unreadable(URL)`, `.exportFailed(String)` in `Services/KeynoteImporter.swift`.
- `enum KeynoteImporter` — `static let keynoteBundleIdentifier`; `static var workspaceProvider: (String) -> URL?` (test seam); `static func isKeynoteInstalled() -> Bool`; `static func exportToPDF(keynoteURL:destinationDirectory:) throws -> URL`; `static func exportAppleScript(keynoteURL:pdfURL:) -> String` (exposed for shape tests).
- `MediaImporter.keynoteExporter: (URL, URL) throws -> URL` — test seam; default delegates to `KeynoteImporter.exportToPDF`.
- `MediaImporter.isKeynote(_:)` — UTType `com.apple.iwork.keynote.key` + extension fallback.
- `RootView` open panel includes the Keynote UTType; `addMedia` filters `.key` URLs and presents `presentKeynoteNotInstalledAlert()` when the workspace can't resolve Keynote.
- Entitlements: `com.apple.security.automation.apple-events` (true).
- Info.plist: `NSAppleEventsUsageDescription` ("Simple Playback uses Apple Events to drive Keynote so it can export .key decks to PDF for slide rasterization.").

---

## 2026-05-08 — C2: transcode coordinator shape, sibling slide, modern AVAssetExportSession API

**Decision**: ProRes transcode is a `TranscodeJob` ObservableObject (one per export) owned by a per-document `TranscodeCoordinator`. The coordinator returns a `TranscodeOutcome { sourceSlideID, preset, siblingSlide }` on success; RootView splices the sibling into `project.slides` immediately after the source. The export uses the modern async `AVAssetExportSession.export(to:as:)` + `states(updateInterval:)` AsyncSequence rather than the deprecated `exportAsynchronously`/`status`/`error` triplet. The right-click menu lives on `SlideGridView`'s `SlideTile.contextMenu`; the non-modal progress strip lives just above the existing transition controls in the palette column. Show Mode hides the menu but does not abort in-flight jobs.

**Why**:
- **Sibling not replacement** — Spec §3.10 doesn't dictate either direction, but Final Cut, DaVinci, and Premiere all add a sibling rather than replace the source on transcode. Non-destructive A/B is the operator-correct default; destructive replace would also break any existing cue references to the source slide's UUID, which is more surface to reason about than a future "Hide original" toggle.
- **Coordinator returns Outcome, doesn't write project state** — Keeps `TranscodeCoordinator` testable in isolation. The splice into `project.slides` is RootView's job; the coordinator stays free of Document/Project knowledge and can be unit-tested without standing up an `NSDocument`.
- **Injectable `siblingImporter`** — `TranscodeCoordinator.siblingImporter` defaults to `MediaImporter.importSlides(from:).first` so the sibling slide carries fresh `nativeFrameRate` + cleared `MediaFlags` (a successful ProRes transcode by definition removes long-GOP / VFR / 10-bit-4:2:0 flags — the operator wants to *see* that in the inspector). The injection point lets unit tests pin the sibling shape (UUID freshness, title format, mediaKind) without re-running AVFoundation on the transcoded artifact (already covered by C2a's end-to-end test).
- **Modern async `export(to:as:)` over deprecated `exportAsynchronously`** — macOS 26 deployment target makes the modern API safe to assume; deprecation warnings on `status`/`error`/`exportAsynchronously` are real (the deprecated trio was generating compiler diagnostics). The new `states(updateInterval:)` AsyncSequence cleanly emits `.exporting(Progress)` for the UI without a `Timer` or KVO dance.
- **Non-modal progress strip** — Spec §3.5 forbids modals while Program is non-empty; even in Edit Mode, a multi-minute transcode shouldn't gate the operator from doing other work. A strip in the palette column (where the source slide lives) keeps the progress visually paired with its source without taking screen real estate from PROGRAM/PREVIEW or the Show List.
- **Bundle `Transcoded/` per spec §3.17 + App Support fallback** — Mirrors the C3 pattern exactly. Untitled docs land transcodes in `~/Library/Application Support/Simple Playback/Transcoded/<sessionUUID>/`; Save As migrates only the *project* JSON, leaving the transcoded files at their absolute path until a future "Bundle for Travel" action sweeps them in (same future pickup as C3 PDF renders).
- **Show Mode hides menu, in-flight survives** — The §3.5 invariant is "no destructive shortcuts in Show Mode." Transcode is non-destructive (creates a sibling) but it does spin a CPU and write files; safest to gate the action surface in Show Mode while letting work the operator already started complete. Aborting in-flight jobs on Show-Mode toggle would surprise the operator more than letting them finish.

**Alternatives considered**:
- **Destructive replace** — Rejected: see "sibling not replacement" above. A future "Hide originals after transcode" toggle could ship if operators ask.
- **Modal progress sheet** — Rejected: §3.5 anti-modal rule.
- **Coordinator writes directly into a `Binding<PlayoutProject>`** — Rejected: forces `TranscodeCoordinator` to know about Document/Project, makes unit testing require a synthetic project. The Outcome-callback split keeps responsibilities clean.
- **`exportAsynchronously` + KVO on `progress`** — Rejected: deprecated as of macOS 15; modern async API is cleaner and matches Apple's current direction.
- **Per-clip transcode panel like Compressor** — Rejected for v1: the right-click + strip is the smaller surface that matches the operator's "I see a flag chip → I right-click → it transcodes" loop. A bulk-transcode action could come in a later iteration if operators ask.
- **`Transcoded/` next to source file** (sidecar) — Rejected: clutters the user's filesystem; breaks venue portability.
- **Pre-prompt before transcode** ("This will take ~N minutes; proceed?") — Rejected: operators picking the menu item already opted in; an extra modal is friction. The cancel button on the progress strip is the escape valve.

**Reversibility**: easy. Revert = drop `Services/TranscodeService.swift`, `TranscodeServiceTests.swift`, `TranscodeCoordinatorTests.swift`, the `TranscodeCoordinator` `@StateObject` in RootView, the `requestTranscode`/`transcodedRootDirectory` helpers, the SlideGridView context-menu hooks + `TranscodeProgressStrip`, and the `transcodedDirectory` constant in `ProjectBundleLayout`. No persisted-state changes — sibling MediaSlides round-trip through the existing `MediaSlide` Codable shape; opening a project after revert keeps the sibling slides as ordinary video clips referencing their absolute paths.

**What I'd revisit if**:
- Operators want a per-clip transcode panel (Compressor-style) with multiple presets queued at once, batch source selection, bitrate overrides. Today the coordinator handles N-job concurrency fine but the UI surface is one-at-a-time.
- Failures need operator feedback. Today a `TranscodeError.exportFailed` is silent (the row just disappears). Pair with the deferred "import status banner" so any media-pipeline failure (PDF parse, Keynote missing, transcode crash) surfaces consistently.
- The `<bundle>/Transcoded/<UUID>.mov` accumulation needs GC. Sibling slides can be deleted from the palette but their on-disk file lingers; a future "Compact project" action would reconcile the directory against `project.slides`. Same gap as C3 PDF renders.
- AVAssetExportSession on Apple Silicon hits the hardware ProRes encoder; on Intel it falls back to software. We don't currently surface that to the operator. If real rehearsal shows transcode times that surprise on Intel hosts, surface a "Software encoding — N minutes estimated" hint in the progress row.

**Public API impact**:
- `enum TranscodePreset { proRes422, proRes4444 }` (CaseIterable) — `label`, `avPresetName`, `fileExtension`, `avFileType` accessors.
- `enum TranscodeError: LocalizedError, Equatable` — `.sourceNotReadable(URL)`, `.presetIncompatible(String)`, `.exportFailed(String)`, `.cancelled`.
- `enum TranscodeService` — `siblingTitle(originalTitle:preset:) -> String`, `destinationFilename(preset:) -> String`, `canTranscode(slide:) -> Bool`.
- `@MainActor final class TranscodeJob: ObservableObject, Identifiable` — `progress: Double`, `state: State` (idle/running/completed(URL)/failed(String)/cancelled), `displayLabel`, `start(completion:)`, `cancel()`.
- `struct TranscodeOutcome { sourceSlideID: UUID; preset: TranscodePreset; siblingSlide: MediaSlide }`.
- `@MainActor final class TranscodeCoordinator: ObservableObject` — `jobs: [TranscodeJob]`, `transcode(slide:preset:destinationDirectory:completion:) -> TranscodeJob?`, `cancelAll()`, `static var siblingImporter: (URL) -> MediaSlide?` test seam.
- `ProjectBundleLayout.transcodedDirectory = "Transcoded"`.
- `SlideGridView` gains `transcodeJobs`, `transcodeEnabled`, `requestTranscode`, `cancelTranscode` parameters (all defaulted so existing call sites compile).
- `RootView.transcodedRootDirectory()` private helper; `requestTranscode(slide:preset:)` private callback that splices the sibling into `project.slides` after the source on success.

---

## 2026-05-08 — C4: animatedImage flag widening + ProRes 4444 default

**Decision**: Add `animatedImage: Bool` to `MediaFlags` rather than building a parallel `ImageMediaFlags` model; populate it from a separate `AnimatedImageInspector` (image branch) rather than widening `MediaFlagsInspector` (which is video-only).

**Why**: The four codec-inspector flags (longGOP / VFR / 10-bit-4:2:0 / untaggedColor) are video-only by their semantics — they describe codec behavior. The animated-image flag is image-only and the detection mechanism (`CGImageSource`) shares no code with AVFoundation's video inspection. But the *consuming* surface (cue inspector chip, `activeWarnings` list, persistence) is identical, so reusing `MediaFlags` keeps the slide-flag surface uniform. Splitting the inspector keeps the single-responsibility tight.

The widened `TranscodeService.canTranscode(slide:)` now accepts `.image` slides whose `flags.animatedImage` is true. The existing test contract — "static images return false" — is preserved because the default `animatedImage` is false. `preferredPresetOrder(for:) -> [TranscodePreset]` returns 4444-first for animated images, 422-first for everything else. Operators see ProRes 4444 as the highlighted item in the right-click menu without us depending on a SwiftUI "default" affordance that doesn't exist for context menus.

**Alternatives considered**:
- Widen `MediaFlagsInspector` to accept `.image`. Rejected — introduces an asymmetric switch inside the service and conflates two unrelated detection paths.
- Keep `canTranscode` video-only and add a separate "Convert to ProRes 4444" action item for animated images. Rejected — duplicates the menu surface for what is structurally the same operation.

**Reversibility**: easy. The flag is a strict addition; reverting would require a migration of any project that already saved with the flag set, but the `decodeIfPresent` path tolerates a missing field cleanly.

**What I'd revisit if**: a real animated GIF / APNG fails to transcode through `AVAssetExportSession`. AVFoundation has read-only support for animated GIFs as movie sources on modern macOS, but if it doesn't expose APNG that way, C5b's AVAssetWriter path may need to subsume the animated-PNG transcode too.

---

## 2026-05-08 — C-banner: import-status surface design

**Decision**: A flat `MediaImportFailure` value type (`url`, `kind`, `summary` string) instead of a discriminated union over the per-pipeline error types. New `MediaImporter.importSlidesAndReport(from:context:) -> MediaImportReport` overload; legacy `importSlides(from:)` / `importSlides(from:context:)` delegate to it and discard failures.

**Why**: PDFImportError, KeynoteImportError, and TranscodeError aren't all Equatable (PDFImportError embeds `Error`). Designing the banner around a flat string sidesteps that, keeps the value type Equatable for testability, and gives the banner exactly what it needs (an operator-readable line per failure). The `Kind` enum is a discriminator only — the banner doesn't case-split on it for behavior, only for icon variation in a future pass.

The `ImportStatusBanner` is per-document (each `RootView` has its own `@StateObject`) and append-only until dismissed. A second failed import never silently overwrites the first — operators in a live show must not lose a failure notice to a subsequent action.

Cancellation is silent by design: `TranscodeError.cancelled` lands when the operator clicked ✕ on the progress strip, so re-surfacing it in the banner would feel like the app questioning the operator's deliberate action.

**Alternatives considered**:
- Embed each pipeline's error directly. Rejected — non-Equatable types complicate testing, and operators care about the message, not the underlying enum case.
- Make the banner global (singleton). Rejected — multiple windows / documents should not share a failure surface.
- Replace the modal "Keynote not installed" alert with the banner. Deferred to C-banner-c — the modal currently fires alongside the banner, which is mildly redundant but not wrong.

**Reversibility**: easy. The banner is a pure addition; the legacy `importSlides` paths are intact.

**What I'd revisit if**: the operator wants per-failure dismissal, "retry" buttons, or persistent (across-restart) failure history. Today the banner clears on dismiss; project bundles don't track import-failure history.

---

## 2026-05-08 — C5a: image-sequence detector counter widths

**Decision**: Recognize 3-digit and 4-digit zero-padded counters (`name.001.png`, `name.0001.png`); reject 2-digit and 5-digit. Recognized extensions: `png`, `jpg`, `jpeg`, `tiff`, `tif`, `exr`. A "sequence" requires ≥2 frames sharing baseName + extension + pad width; gaps in the counter are allowed.

**Why**: 2-digit counters false-positive on common version markers (`v1.2.png`, `iPhone X.42.tiff`). 5-digit counters are unconventional in the operator-facing world (Nuke/Houdini default to 4 digits; FFmpeg's `%04d` is the de-facto convention). Padding-width split (3-digit and 4-digit treated as separate sequences when they share a basename) keeps output numbering consistent — an operator who exported the first 999 frames at 3-digit and frames 1000+ at 4-digit gets two encodes, not a confused single encode.

Recognized extensions cover the four formats operators ship sequences in: PNG (sRGB transparency), JPEG (8-bit fallback), TIFF (16-bit / floating point), EXR (HDR / floating-point linear). HEIC is intentionally excluded — sequences in HEIC are vanishingly rare and the format's metadata layout doesn't pair well with a frames-in encode.

The detector returns leftovers in their original drop order so non-sequence files preserve operator intent. Sequences are returned in `(baseName, ext)` lexical order for deterministic test output.

**Alternatives considered**:
- Accept any digit width. Rejected — the false-positive rate on 1-2 digit counters is too high.
- Use a regex (`[a-zA-Z0-9_]+\.[0-9]{3,4}\.\w+`). Rejected — operator file naming includes spaces, dots, parentheses; whitelist by extension + counter-width constraints is more permissive on the basename without false-positives.

**Reversibility**: easy. The detector is pure-logic with no on-disk artifacts.

**What I'd revisit if**: a real-world sequence ships with a 5-digit counter or a sub-frame fractional counter (`name.001.5.png`). Today the latter would parse as a 1-digit counter on `name.001` and reject it — that's the right behavior for the autonomous era; encoders that emit those use cases would need explicit operator opt-in.

---

## 2026-05-08 — E8: project lock file shape, banner UX, Read-Only deferral

**Decision**: `.lock` is JSON `{ pid, hostname, timestamp, applicationVersion }`, not a sentinel-style empty file. Liveness has five states (ours / localLive / localStale / foreignLive / foreignStale); the foreign-staleness window is 1 hour. The banner ships with two operator actions ("Open Anyway" / "Dismiss") rather than the spec's three ("Open Anyway" / "Read Only" / "Cancel"). Lock acquisition is silent for ours/stale; foreign-live blocks acquisition until the operator picks Open Anyway. Lock release happens in `NSDocument.close`.

**Why**:
- **JSON over sentinel** because the operator-debugging value of "who has it open and when" outweighs the marginal cost of a 200-byte JSON file. Spec §3.16 specifies the warning content, not the lock format; surfacing the locker's identity is what makes the warning actionable.
- **Five-state liveness** rather than a binary "live vs stale" because cross-host vs local has different staleness semantics. Same-host PID liveness is ground-truth via `kill(pid, 0)`; cross-host PID liveness is unknowable, so we fall back to a timestamp window.
- **1-hour foreign window** is a conservative compromise: too short and a peer briefly disconnected from a NAS sees us steal their lock; too long and a real crash leaves the lock blocked for hours. 1 hour matches typical show-rehearsal cadence.
- **"Read Only" deferred** to a separate v1 follow-up because it's not just a banner button — it requires document-wide read-only enforcement (palette / show-list / inspector / drop targets all gated, OSC/HTTP capabilities dropped to read+fire, autosave suppressed, etc.). Bundling that into the duplicate-open warning would conflate two unrelated v1 surfaces. Today's two-button banner closes the warning requirement; the read-only-mode requirement gets its own iteration.
- **Dismiss does not claim ownership** by design: an operator who knows the foreign owner is themselves on a different machine (e.g., laptop+booth-mac dual-up) can dismiss without contesting the lock. The foreign owner stays the lock holder; edits happen anyway. That's a pragmatic v1 default; if real-show usage shows operators surprised by "I dismissed and edited and we both saved," the right next move is escalating to the Read-Only mode rather than enforcing exclusive locks.
- **Release in NSDocument.close** (not RootView .onDisappear) because SwiftUI teardown ordering can vary; tying the release to the Cocoa document lifecycle is more deterministic.

**Alternatives considered**:
- **PID-only sentinel** — rejected; loses the "who" + "when" info that makes the warning actionable.
- **Mandatory cancel-on-foreign** — rejected; operators sometimes need to recover when a peer crashed and the timestamp says < 1h. Open Anyway is the escape hatch.
- **Auto-release on idle** — rejected for v1; an operator AFK for an hour during rehearsal shouldn't see their lock evaporate. The 1-hour foreign-staleness window is for *peers* observing us, not for self-release.

**Reversibility**: easy. The lock is informational and additive — projects opened pre-E8 just don't have a `.lock` yet, and projects opened post-E8 have one ignored by older versions.

**What I'd revisit if**:
- Real NAS rehearsals show 1 hour is wrong (probably too long if operators frequently re-cycle through a project; too short if they hold a project open for an entire show day).
- Operators want a "Read Only" path. Build it as a separate v1 follow-up with document-wide enforcement, not a banner button.

**Public API impact**:
- `struct ProjectLockFile`, `enum ProjectLockFileIO`, `struct ProjectLockFileSignals` in `Services/ProjectLockFile.swift`.
- `final class ProjectLockController: ObservableObject` in `Views/ProjectLockBannerView.swift` (companion view defined alongside).
- `RootView.init(..., lockController:)` — required parameter.
- `SimplePlaybackProjectDocument` owns `lockController`; KVO-observes `\.fileURL`; overrides `close`.

---

## 2026-05-08 — E6: split rolling autosave from event-driven checkpoint

**Decision**: NSDocument's autosave-in-place machinery handles the 30s rolling autosave (set `NSDocumentController.autosavingDelay = 30` once at app launch). Independently, `Services/AutosaveCheckpointer.swift` writes event-driven *checkpoints* to `<bundle>/Autosave/<timestamp>__<reason>.json`. Show-Mode toggle is the v1 trigger; `manual` reason is reserved. Retention 20.

**Why**:
- **Two separate mechanisms** because the spec calls out two separate things — "every 30 s of edit activity" (rolling) and "checkpoint on every Show-mode toggle" (pinned moment). Trying to unify them would either force the rolling autosave through the checkpointer (paying 20-deep retention on every 30 s tick) or force checkpoints through autosave-in-place (which writes back to the bundle URL, losing the snapshot semantic).
- **Checkpoints are reason-tagged in the filename** so a future "Restore from checkpoint" UI can show operator-readable labels ("Show Mode On — 14:32:08") without parsing the file body.
- **POSIX-UTC timestamp + no colons** in the filename so the bundle round-trips through SMB / exFAT / a tar to a Linux box without rename surprises.
- **Filename round-trip is symmetric** so prune doesn't trust filesystem mtime — networked volumes routinely drift mtime, and the autosave directory is exactly the kind of directory operators sync via Dropbox / iCloud / a NAS share.
- **Retention 20 at write time** rather than periodic GC so the disk footprint is bounded immediately. The cost (one directory list per checkpoint) is negligible compared to the Show Mode toggle's other side effects.
- **Initial nil → false load is suppressed** in the RootView .onChange hook so opening a project doesn't write a spurious `show_mode_off` snapshot. The energy-assertion hook does NOT suppress that load (different rationale — see E1+).

**Alternatives considered**:
- **Custom autosave directory** (override `NSDocument.autosavedContentsFileURL`) — rejected; it diverts the rolling-autosave path away from the bundle URL itself, which breaks `autosavesInPlace` and complicates operator mental model ("which file is the project?").
- **Single mechanism** for both rolling and checkpoint — see "Two separate mechanisms" above.
- **Periodic GC** instead of write-time prune — rejected; complicates disk-footprint reasoning.

**Reversibility**: easy. Both mechanisms are additive; deleting `Services/AutosaveCheckpointer.swift` + the RootView .onChange hook + the AppDelegate one-liner reverts cleanly. Existing `<bundle>/Autosave/` directories from a deployed E6 build become inert (unread by older binaries).

**What I'd revisit if**:
- Operators want a "Restore from checkpoint" UI. Build it as a separate sheet that lists the parsed filenames + timestamps + reasons; load via the existing `JSONDecoder.simplePlayback`.
- 20-deep retention is wrong (too few for multi-day rehearsals; too many for a small disk). Make `retentionLimit` per-project or surface it in preferences.

---

## 2026-05-08 — E1+: hold a no-idle-sleep IOPM assertion in Show Mode (action, not just check)

**Decision**: While Show Mode is on, hold an `IOPMAssertionTypeNoIdleSleep` assertion via `IOPMAssertionCreateWithName`. Release on Show Mode off. Pre-show check rule reads `EnergyAssertion.isHeld` rather than introspecting the kernel's assertion table.

**Why**:
- **Act, don't just check.** A pre-show panel that warns "the system might idle-sleep" is less valuable than a Show-Mode toggle that *prevents* idle-sleep. Operators who flip Show Mode on get the protection regardless of whether they remembered to look at Pre-Show first.
- **Hold from operator-flip, not from app launch.** The assertion is heavy-handed — battery-on laptops can't sleep. Tying it to Show Mode means it's only active when the operator is committed to a live run.
- **Read our own state** in the pre-show check rather than `IOPMCopyAssertionsByProcess`. We know better than IOKit whether *we* hold the assertion; querying IOKit is unnecessarily indirect.
- **Initial nil → false IS NOT suppressed** in the showMode .onChange hook (unlike the autosave checkpoint). If the operator's first interaction with Show Mode is to flip it on, the assertion needs to land on press one. Suppression would mean "first toggle does nothing" — surprising for a safety feature.

**Alternatives considered**:
- **`IOPMAssertionTypePreventUserIdleSystemSleep`** — similar but explicitly tied to *user* idle. NoIdleSleep is the broader version that also blocks lid-close on supported hardware in some configs.
- **NSProcessInfo `beginActivity(.userInitiated)`** — coarser; ties to a different power-management subsystem and doesn't show up in `pmset -g assertions` with our app name.
- **Always-on while document is open** — rejected; battery laptops can't sleep at all, and operators editing for hours don't need the protection.
- **Check via `IOPMCopyAssertionsByProcess`** — works but requires parsing CFArrays back; no actual benefit over reading our own `isHeld`.

**Reversibility**: easy. Drop `Services/EnergyAssertion.swift` + the RootView hook + the PreShowCheck rule + the Context field; behavior reverts to "macOS handles power management normally."

**What I'd revisit if**:
- Real laptop rehearsals show the system not sleeping when Show Mode is on (what we want) but also not sleeping when Show Mode is off (because the assertion didn't release). Diagnose via `pmset -g assertions` — if our assertion is still listed without Show Mode, the release path didn't fire.
- Operators want to keep the system awake without committing to Show Mode (e.g., a long rehearsal where they're tweaking cues). Add a separate "Keep awake" toggle alongside Show Mode that drives the assertion independently.


---

## 2026-05-08 — E3+: dropped-frame detection via timer-tick host-time deltas

**Decision**: `PlaybackController` measures dropped frames by comparing wall-clock between consecutive video-timer ticks against `activeFrameInterval`. A delta > 1.5× the interval reports `floor(delta/interval) - 1` drops. Detection is gated to non-`forceCurrentTime` paths so operator-driven seeks aren't counted. Counter resets on `stopOutput`.

**Why**:
- **Wall-clock cadence is the most direct proxy for "frame missed presentation."** AVPlayerItemVideoOutput's pixel-buffer pull doesn't reliably surface drops at the API surface — `hasNewPixelBuffer(forItemTime:)` returns a Bool but doesn't distinguish "buffer not yet decoded" (legitimate cadence) from "decoder fell behind" (a drop). Comparing tick deltas is OS-agnostic and works for both image and video paths.
- **1.5× threshold absorbs scheduler jitter.** A healthy mac scheduler delivers DispatchSourceTimer events within ~5–20 ms of the requested deadline; the leeway parameter is set to 2 ms. 1.5× of a 33 ms (30 fps) interval is 50 ms — generous enough that normal jitter doesn't fire false positives, tight enough that a real frame deficit lands.
- **`forceCurrentTime` excluded** because operator scrubs reset the player to a new item-time off-cadence. Counting that as a drop would conflate user actions with output stress.
- **Counter resets on stopOutput** rather than per-take. Operators read the counter as "how is the system holding up tonight?", not "how did Cue Q3 do?" Per-take stats would need a different surface.

**Alternatives considered**:
- **AVPlayerItem.AccessLogEvent** — Apple's official API, but only logs once per access event and is asynchronous. Operator-scale latency (events arrive seconds after the drop) makes the rolling-10s chip useless.
- **Hook the DeckLink driver's "frame submitted vs frame displayed"** — the bridge interface doesn't expose this counter as a signal we can subscribe to. Would require pulling a property each tick.
- **Skip the threshold and count every late tick** — produces noise on healthy systems. The 1.5× floor matches the operator's intuition ("the output stuttered") rather than the kernel's intuition ("a tick was 6 ms late").

**Reversibility**: easy. The detection path lives in two methods on `PlaybackController` (`detectAndRecordDroppedFrames` + the call site in `renderCurrentVideoFrame`), the counter is one file, and the chip is a `@ViewBuilder` in `OutputStatusBar`. Removing all three reverts to no drop tracking.

**What I'd revisit if**:
- Real-world rehearsal shows false positives during normal load (e.g., user scrolling the slide grid causes drops to register when output is unimpeded). Tighten the threshold or move detection into the DeckLink sink path.
- The 10-second rolling window is wrong for multi-hour shows. Consider adding a "since last GO" axis in addition to or instead of rolling-10s.

---

## 2026-05-08 — E3+ debounce: synchronous gate, not Combine `throttle`

**Decision**: `ShowController.handleDropCumulative(_:now:)` is a pure-logic predicate that decides whether to log a `.droppedFrame` event based on time-since-last-emission. The Combine subscription on `playback.droppedFrameCounter.$cumulative` calls it with `Date()`. Tests drive the function directly with synthetic timestamps.

**Why**:
- **Combine `throttle(for:scheduler:latest:)` is hostile to test pinning.** Tests would need to wait wall-clock time (or run the run loop with a virtual scheduler), and the trailing-edge emission semantics are subtly different from "emit on first burst, suppress within window." A pure function with explicit `now` lets the test own time.
- **First-burst-emits-immediately + accumulate-during-window** is what operators want. A long stall should land as one log entry, but a single short burst should still register.
- **Reset re-baselines** by setting `lastReportedDropCumulative = cumulative` and clearing `lastDropLogTime` on a counter-reset (cumulative goes backward). Without this, the next burst after a reset would log the *cumulative-since-reset* delta as if it were the burst since the previous emission.
- **The `.system` source label** matches the existing convention for runtime-internal events (`.missingMedia`).

**Alternatives considered**:
- **Combine `throttle`** — see above. The first round of tests sat on real time and produced 3-second test cases.
- **Emit one event per drop** — drowns the show log; a 2-second stall at 30 fps adds 60 entries.
- **Emit once at output stop with the total** — too late to be actionable during the show.

**Reversibility**: easy. `handleDropCumulative` is a single function; reverting the wiring is a one-line subscription removal.

**What I'd revisit if**:
- Operators want the rolling-10s number in the log too (right now we log delta + cumulative; rolling-10s is a snapshot the chip surfaces). Add it to the detail string.

---

## 2026-05-08 — E5: take-history captures cue title at fire time (snapshot, not reference)

**Decision**: `TakeHistoryEntry` stores `cueTitle: String` (a copy) rather than `cueID: UUID` only. Same for `cueNumber`.

**Why**:
- **History pins what was on screen at the moment of fire.** Renaming a cue later shouldn't rewrite the past.
- **Cross-document survival.** If the cue is deleted from the show list, the history still shows what played.
- **`cueID` is also kept** so a future "scroll to this cue" affordance can navigate to the live cue if it still exists.

**Alternatives considered**:
- **Keep only `cueID`, look up title at render time** — fast for typical use but fails the rename / delete cases.
- **Look up via a captured `(UUID) -> Cue?` closure** — same look-up problem, plus retain-cycle risk on the controller.

**Reversibility**: easy. The struct is one file; replacing string fields with closures is mechanical.

**What I'd revisit if**:
- Memory becomes a concern at much larger histories (>10k entries). Strings are small but the natural fix is a deduplicated string table inside `TakeHistory`.

---

## 2026-05-08 — E7: equal-mtime checkpoints don't trigger recovery

**Decision**: `CrashRecoveryDetector.findRecoverableCheckpoint` returns nil when the newest checkpoint's timestamp equals Show.json's mtime (only strictly-newer triggers recovery).

**Why**:
- **Clean shutdowns commonly have checkpoint timestamp == Show.json mtime.** A Save-on-Show-Mode-toggle workflow writes the checkpoint and the bundle JSON essentially simultaneously. We don't want to surface a recovery banner on every project re-open following a normal Show-Mode session.
- **The recovery banner is a *suspicion* signal.** False positives drown the operator's attention; we'd rather miss a borderline edge case (where someone genuinely lost work but the autosave timestamp lined up exactly with Show.json) than nag on every open.

**Alternatives considered**:
- **Newer-or-equal** — produces nuisance banners on routine reopens.
- **Compare body hashes** — strictly correct (recovery if and only if the bytes differ), but requires reading both files for every open. The mtime fence is cheap and correct enough.

**Reversibility**: easy. One inequality in the detector.

**What I'd revisit if**:
- A recurring crash leaves checkpoint mtime exactly equal to Show.json mtime (unusual on real file systems with millisecond resolution but possible on networked stores with second-resolution mtime). Bump to `<=` and add a hash check to suppress nuisance banners.


---

## 2026-05-08 — C7a: SHA-256 streaming + size + mtime as the fingerprint shape

**Decision**: `MediaAssetFingerprint` carries hex-encoded SHA-256 + size + mtime. The hash is streamed (1 MiB default chunk) so multi-GB ProRes files don't load into RAM. Failure is non-blocking — `try? AssetFingerprinter.fingerprint(url:)` returns nil and the importer creates the slide anyway.

**Why**:
- **SHA-256 is the right durability/cost tradeoff** for an operator-facing identity check. MD5 is faster but the collision surface in a venue-portable bundle (multiple sources copy-deduped on a NAS) is non-trivial; SHA-256 closes the door without making import unbearably slow.
- **Size + mtime are the cheap pre-flight** for stale-link detection. The pre-show check needs to ask "did this file change since import?" without re-hashing every file every open. Stat-only comparison answers that for the typical case; a full re-hash is a future operator action when stat ambiguity bites.
- **Streaming I/O** because import-time hashing of multi-GB ProRes hits real machines hard. Loading the file into memory before hashing would push 4–8 GB RAM allocations; `InputStream` at 1 MiB chunks holds 1 MB.
- **Non-blocking failure** because a fingerprint is a relink-ladder *aid*, not a load-bearing primitive. A slide whose fingerprint failed to compute (unreadable, transient I/O glitch, race with the operator deleting the file mid-import) is still importable and playable; the C9 relink waterfall just falls through to name+size on that slide.

**Alternatives considered**:
- **xxHash / BLAKE3** — faster, but introduces a non-standard dependency for marginal gain. SHA-256 is in CryptoKit; no third-party code.
- **Compute fingerprint at first-resolve rather than at import** — defers cost but means project files can be edited without ever capturing a baseline; the stale-fingerprint check loses its ground truth.
- **Skip mtime, hash on every check** — would force a several-second pause every Pre-Show open on big libraries.

**Reversibility**: easy. The struct is one file; the importer wiring is two callsites. Removing both reverts cleanly; existing projects ignore the new fields on decode (decode-if-present).

**What I'd revisit if**:
- Real rehearsals show the 1 s mtime tolerance false-positives on SMB volumes (some SMB servers report mtime at 2 s precision). Bump to 2 s, or read filesystem-precision capability.
- Hash performance becomes a problem on huge project imports. Move fingerprinting off the import hot path into a background queue with a "fingerprint pending" placeholder.

**Public API impact**:
- `struct MediaAssetFingerprint { contentHash: String, size: Int64, mtime: Date }` (Codable, Hashable).
- `enum AssetFingerprintError: LocalizedError, Equatable` (`.unreadable`, `.missingAttributes`).
- `enum AssetFingerprinter` — `fingerprint(url:chunkSize:)`, `sha256Hex(_:)`.
- `enum MediaReferenceKind: String, Codable, CaseIterable, Identifiable { case linked, managed }`.
- `MediaReference` gains `kind` and `fingerprint` fields, both decode-if-present.
- `MediaImporter.fingerprinter: (URL) -> MediaAssetFingerprint?` — test seam, default delegates to `AssetFingerprinter.fingerprint`.

---

## 2026-05-08 — C7c: bookmark resolution lives inside the resolver, not just `MediaReference.resolvedURL()`

**Decision**: `MediaResolver.resolve` re-implements the bookmark / originalPath check internally using its injected `fileExists` closure rather than delegating to `MediaReference.resolvedURL()`. The convenience method on `MediaReference` stays — it's the production-fast-path used everywhere else — but it isn't load-bearing inside the resolver.

**Why**:
- **`resolvedURL()` does its own real-filesystem check** in the absolute-path fallback branch. That couples the resolver to `FileManager.default` and breaks pure-logic testability — the first cut routed through `resolvedURL()` and the resolver's tests immediately failed because the absolute path didn't exist on disk.
- **Bookmark data is still resolved via Foundation** (`URL(resolvingBookmarkData:)`), which is real I/O but tolerant — invalid bookmarks return nil rather than throwing or stat'ing. Tests pass empty bookmarks and the resolver falls through to the absolute-path branch (where the injected `fileExists` takes over).
- **Cost**: the resolver duplicates ~6 lines of bookmark/path resolution that already exist in `MediaReference.resolvedURL()`. Worth it for the testability gain; the duplication is small and stable.

**Alternatives considered**:
- **Refactor `MediaReference.resolvedURL()` to take an injectable `fileExists`** — more invasive, propagates a closure-arg through every existing caller. Rejected: too much surface change for one resolver feature.
- **Tests use real temp files** — works but every hash/name+size scenario would need fixture creation. The injected closures are dramatically faster and clearer.

**Reversibility**: easy. The duplicated lines are scoped to `MediaResolver.resolve`; collapsing back into `resolvedURL()` is a refactor, not a feature change.

**What I'd revisit if**:
- The resolver and the convenience method drift. Track via a comment cross-reference; if the resolver picks up new bookmark-handling logic that `resolvedURL()` doesn't have, audit both before merging.

---

## 2026-05-08 — C7c: search roots iterate in caller order; first hash-hit wins

**Decision**: `MediaResolver.resolve` walks `searchRoots` in the order the caller passed them. The first `.contentHash` match wins immediately; `.nameAndSize` matches are remembered as "last resort" and only used if no hash match surfaces in any root. The resolver does not search beyond the first hash match.

**Why**:
- **Caller order encodes operator intent**. The host typically passes `[bundle Media/, project-relink folder, Documents/Media/]` — bundle-local media should win because it's the venue-portable copy.
- **Hash > name+size** because hashes are authoritative (identical bytes ⇒ identical asset); name+size is heuristic. The resolver promotes the harder-evidence match unconditionally.
- **First hash match wins without a tiebreaker** because a content-hash collision across multiple search roots would imply identical files in two locations — picking either is correct; picking the first preserves caller intent.

**Reversibility**: easy. The loop is one function; reordering or adding tiebreakers is a localized change.

**What I'd revisit if**:
- Operators want a "find all matches" view to disambiguate. Today the resolver picks one; a future surface could return all candidates and ask the operator. That's a separate API (`resolveAll(...)`) layered on top.

---

## 2026-05-08 — C7c stale-fingerprint: 1 s mtime tolerance on the pre-show row

**Decision**: `AssetLibraryProbe.isStale` accepts a 1-second mtime tolerance window before flagging a slide as stale. Smaller drifts are silently treated as identical.

**Why**:
- **HFS+ rounds mtime to whole seconds.** A file copied between APFS and HFS+ volumes will show a sub-second drift even though the bytes are identical.
- **SMB drops to 2 s precision** on some servers. Real rehearsal venues have NAS shares whose mtime changes by 0–2 s on every open.
- **Stale is a warning, not an error**, so a tolerance window's downside is minimal — a true content change still differs at the byte / size axis, which the predicate also checks.
- **1 s is the conservative floor** that catches HFS+ but doesn't suppress real edits (a legitimate edit takes more than a second to make + save).

**Alternatives considered**:
- **0 s tolerance** — false positives on every venue-portable bundle move.
- **2 s tolerance** — survives SMB but starts swallowing fast-edit cycles in normal use.
- **Read filesystem-precision capability** — possible via `URLResourceKey`, but the implementation surface isn't worth it for a pre-show signal that's already a warning.

**Reversibility**: easy. One scalar parameter on `isStale`.

**What I'd revisit if**: real SMB rehearsals show 1 s isn't enough — bump to 2 s or read the precision capability.


## 2026-05-08 — C7d: filename-collision dedup is a stable per-position counter, not UUID

**Decision**: When two slides in a Bundle for Travel plan have the same source basename (e.g. `intro.mov` from two different folders), the planner deduplicates by appending `-1`, `-2`, … to the *stem* before the extension. Order is the slide-list order; the first slide to claim `intro.mov` keeps the unsuffixed name. Re-running the planner on the same project produces the same destination filenames (deterministic).

**Why**:
- **Operators expect filenames they can read in Finder.** UUID-suffixed names work for `<bundle>/Transcoded/` (C2 / C5) because those are codec-conversion outputs the operator never browses by name; Bundle for Travel's whole point is that the bundle is venue-portable, and a person opening `<bundle>/Media/` should see `intro.mov`, `intro-1.mov` rather than two opaque UUIDs.
- **Determinism matters for re-runs.** If the operator runs Bundle for Travel, deletes a file in Media/ accidentally, and re-runs, the second plan must produce the same filenames so the per-slide `MediaReference` originalPath the apply step rewrote is still correct. UUIDs would re-randomize and orphan the previous-run apply.
- **The collision case is rare.** Real shows mostly have one source file per name; the suffix path only fires when the operator imported the same basename from two different folders. The rare-case ergonomic cost is low.

**Alternatives considered**:
- **UUID-prefixed filenames** — clean for collisions but ugly for the common case and breaks Finder-readability.
- **Hash-based filenames** — `<short-hash>-intro.mov` — readable but every re-run produces new names because the hash changes if the source's bytes drift.
- **Reject the second slide instead of renaming** — operator-hostile; the second slide is just as legitimate.

**Reversibility**: easy. The dedup function is one helper; switching to UUIDs is a one-line change.

**What I'd revisit if**: real rehearsals show operators get confused about which `intro-1.mov` belongs to which cue. Could surface the source path in a tooltip on the managed slide.

**Public API impact**:
- `BundleForTravelPlan.uniqueFilename(for:claimed:)` — pure helper exposed for tests.
- `BundleForTravelOperation.destinationFilename` — String, the deduplicated name.

---

## 2026-05-08 — C7d: bundle-aware resolution adds a rung 0, doesn't replace rung 1

**Decision**: `MediaResolver.resolve` and `MediaReference.resolvedURL(bundleMediaDirectory:)` consult `<bundleMediaDirectory>/<basename>` *only when `kind == .managed` and the bundle URL is supplied*. The bookmark + originalPath waterfall still runs for managed assets if the bundle Media/ candidate is missing.

**Why**:
- **A moved bundle should keep playing.** When a `.splayback` bundle moves to a new machine, the absolute path (which we wrote at C7d apply time as `<bundle>/Media/<filename>`) becomes wrong because the bundle's parent directory changed. The security-scoped bookmark is also stale on the new host. The bundle-relative rung is what saves the play path in this case.
- **Same-machine bundles should not regress.** Before C7d, managed didn't exist; now that it does, managed assets on the same machine resolve via *both* the bundle path and the absolute path (which point at the same file). Rung 0 short-circuits early; rung 1 is the safety net if for some reason the bundle URL isn't known yet (e.g. mid-init).
- **Linked references are deliberately excluded.** A linked file with the same basename as a bundled file would otherwise silently swap in the bundled copy on any project — a horrible failure mode for operator trust. Gated on `kind == .managed`.

**Alternatives considered**:
- **Replace rung 1 entirely for managed** — cleaner conceptually but loses the safety net when bundleMediaDirectory is briefly nil during view setup.
- **Store paths as bundle-relative for managed** — would obviate rung 0 entirely. Rejected because it changes the on-disk schema (today every `MediaReference.originalPath` is an absolute path); the rung-0 approach is purely additive.
- **Cache the resolved URL on `MediaReference`** — premature optimization; the rung 0 check is one `FileManager.fileExists` call.

**Reversibility**: easy. The rung is one closure call in `MediaResolver` and a six-line branch in `MediaReference.resolvedURL(bundleMediaDirectory:)`.

**What I'd revisit if**:
- Operators want managed assets to resolve via bundle Media/ *only*, refusing to fall back to a stale absolute path. Today the fallback is permissive; a strict mode would surface a different `.fileNotInBundle` step for the missing-media UX.

**Public API impact**:
- `MediaResolutionStep.bundleMedia` — new case (existing exhaustive switches in `AssetRelinkPlan` updated to treat as "unchanged").
- `MediaResolver.resolve(bundleMediaDirectory:)` — new optional parameter.
- `MediaReference.resolvedURL(bundleMediaDirectory:)` — new overload; the existing `.resolvedURL()` forwards with nil for backwards compatibility.
- `PlaybackController.bundleMediaDirectory: URL?` — new property; `RootView.onAppear` sets it.
- `AssetLibraryProbe.makeIsOnline(bundleMediaDirectory:)` / `makeResolveURL(bundleMediaDirectory:)` — host-injectable bundle-aware probes; pre-show check uses these so a moved bundle correctly classifies its managed assets as online.

---

## 2026-05-08 — C7d: copies run sequentially on the main actor, no chunk-level cancel

**Decision**: `BundleForTravelCoordinator` runs `FileManager.default.copyItem(at:to:)` calls one at a time inside a `Task @MainActor`. Cancel sets a flag that's checked between operations — the active copy completes before the cancel takes effect.

**Why**:
- **Copies are short relative to the import-time hashing they replace.** A 1 GB ProRes file on a local SSD copies in ~5 s; aborting mid-copy would leave a partial file and a ragged `MediaReference` to clean up. The per-operation cancel boundary keeps the state machine honest.
- **Sequential keeps progress predictable.** Operators expect the progress bar to advance file-by-file. Concurrent copies would parallelize wall-clock but blur the "what's currently happening?" feedback.
- **`Task @MainActor` matches the rest of the app's coordinator conventions** (TranscodeCoordinator, ImageSequenceEncodeCoordinator). The actual `copyItem` blocks the main thread per file, but only briefly, and the alternative (`Task.detached`) introduces actor-hopping that hasn't been needed elsewhere.

**Alternatives considered**:
- **Concurrent copies via `withTaskGroup`** — faster on multi-disk volumes but invites partial-file races on cancel and complicates progress UI.
- **Background `DispatchQueue` + DispatchSource** — pre-async-await pattern; this app prefers Task/actor primitives.
- **Mid-copy cancel via `FileManager` + `Progress.cancellationHandler`** — `FileManager.copyItem` doesn't expose mid-copy cancellation in the Foundation API; would need a chunked rewrite.

**Reversibility**: medium. Switching to a TaskGroup or a chunked copy is a refactor inside the coordinator; no public-API surface changes.

**What I'd revisit if**:
- Real rehearsals show that bundling 50 GB of media takes long enough that mid-copy cancel matters. The chunked-copy path is then the next iteration.
- Multi-disk parallelism gives a meaningful win (probably only on RAID / NAS sources).

**Public API impact**:
- `BundleForTravelCoordinator.State` (`.idle`, `.running(BundleForTravelProgress)`, `.finished`, `.failed`, `.cancelled`).
- `BundleForTravelProgress { completedCount, totalCount, bytesCopied, totalBytes, currentFilename }`.
- `BundleForTravelError` (`.mediaDirectoryUnwriteable`, `.copyFailed`, `.cancelled`).
- `BundleForTravelCoordinator.copyFile / ensureDirectory / removeItem` — static test seams.
