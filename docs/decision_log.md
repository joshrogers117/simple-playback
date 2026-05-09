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

---

## 2026-05-08 — Compositor / palette / transcode bundle-aware resolution: thread the dir, do not introduce a resolver helper

**Decision**: The C7d punch list called for either threading `bundleMediaDirectory` to every `resolvedURL()` read site, *or* introducing a single `MediaSlideResolver` helper that all read paths go through. Session 18 chose the threading option for v1.

**Why**:
- **Each callsite already has the bundle dir at hand.** PlaybackController, RootView, and SlideGridView all know the URL; passing it down was a 1-line change per site, no new abstraction.
- **A `MediaSlideResolver` helper would need to capture the bundle dir** (closure over a `let`, or a singleton observed by the document). Either form introduces a lifecycle question (when does the helper invalidate? who owns it?) that the explicit-parameter approach sidesteps.
- **The bundle dir gets stale on Save-As** — a ref-typed helper would need to refresh on `fileURLDidChange`. Today's Combine-driven `BundleURLObserver` (Z2) does that for the canonical sites; a helper would duplicate that work.

**Alternatives considered**:
- **Single `MediaSlideResolver` helper** — cleaner abstraction but needs a lifecycle story; defer until a third bundle-aware decision (e.g., scope-specific bookmark refresh, multi-bundle inheritance) creates real coupling.
- **Promote `bundleMediaDirectory` to a global `EnvironmentKey`** — works for view-tree code but doesn't reach pure services like `TranscodeService.canTranscode`. Hybrid would split the read paths.

**Reversibility**: easy. The existing parameter sites are forwarders; refactoring to a helper is a search-and-replace once the second use case appears.

**What I'd revisit if**:
- A second "directory at the head of a resolution waterfall" appears (e.g., per-screen managed-assets root). At that point a helper amortizes the scaffolding.

**Public API impact**:
- `CompositorPipeline.bundleMediaDirectory: URL?` (didSet invalidates the bug-image cache).
- `TranscodeService.canTranscode(slide:bundleMediaDirectory:)` — defaulted nil for backward compat.
- `TranscodeCoordinator.transcode(...bundleMediaDirectory:)` — same.
- `SlideGridView.bundleMediaDirectory: URL? = nil` + `CueInspectorView.bundleMediaDirectory`.

---

## 2026-05-08 — Save-As bundle-dir refresh: BundleURLObserver, not a NotificationCenter post

**Decision**: SimplePlaybackProjectDocument owns a small `BundleURLObserver: ObservableObject` that mirrors `NSDocument.fileURL` into a SwiftUI-observable signal. The fileURL KVO observer republishes; RootView observes the value and refreshes both `playback.bundleMediaDirectory` and the C9 missing-media banner via `.onChange`.

**Why**:
- **Symmetry with `lockController.evaluate(bundleURL:)`** — the lock controller already reacts to fileURL changes via the same observer; mirroring its pattern keeps the cross-document re-evaluate logic in one mental model.
- **No window-identity filtering needed.** A `NotificationCenter.publisher(for:)` would fire across every open document; consumers would have to filter by `object` and resolve their own NSDocument reference. The observer is per-document and naturally scoped.
- **`.onChange(of: observer.bundleURL)` is the idiomatic SwiftUI re-act primitive** — the alternative (`@State` polling, `NSWindowDidBecomeMain` listening) reads as cargo-culted.

**Alternatives considered**:
- **NotificationCenter post + `.onReceive`** — tempting because it doesn't add a new type; rejected because RootView would need to filter by document identity it doesn't currently hold.
- **Closure callback registered via `makeWindowControllers`** — mutable closure on the document, set when RootView wires up. Works but trades observable-object idioms for an imperative hook.
- **Promote `bundleURLObserver.bundleURL` to a `@Published` on PlaybackController itself** — couples playback to the document's bundle, conflating concerns.

**Reversibility**: easy. The observer is a 4-line class; deleting it after promoting bundle URL to another store is a small refactor.

**Public API impact**:
- `BundleURLObserver: ObservableObject { @Published var bundleURL: URL? }`.
- `RootView.init(...bundleURLObserver:)` — defaulted to `BundleURLObserver()` for previews/tests that don't construct an NSDocument.

---

## 2026-05-08 — Late-take live integration: liveSlideID proxy, not a new "first frame" callback

**Decision**: Wire `LateTakeDetector` through `ShowController` using `playback.$liveSlideID` as the "frame submitted" signal — Path 2 from the session-17 deferred note. Do not add a "first composed frame for cue X reached SDI" callback to PlaybackController in this iteration.

**Why**:
- **Path 2 ships in 1 commit; Path 1 is an architecture change** to PlaybackController. The deferred note explicitly identified the tradeoff.
- **The proxy catches the operator-visible video-load case.** For video cues, `liveSlideID = prepared.slide.id` fires *after* `AVPlayerItemVideoOutput` preparation completes — that's the per-take video load latency, the most common late-take cause in live shows.
- **Image cues read as on-time** because `liveSlideID` flips synchronously inside `take(...)` for them. We document this limitation in the LateTakeDetector + ShowController doc-comments rather than block the ship.
- **A future Path 1 callback can replace the sink** without touching the detector or the log-emission code path. The bridge isolates the signal change to one Combine subscription.

**Alternatives considered**:
- **Path 1: Add `submitFrame` callback** — emits exactly once per cue fire when the first composed frame reaches an output. Tighter measurement; bigger change. Filed for the future.
- **Skip live integration entirely** — leaves the `.lateTake` ShowLog action unused. Worse than partial.
- **Use wall-clock timer as a proxy** — fixed delay between GO and "frame should have landed." Decoupled from real load behavior; misleading.

**Reversibility**: easy. The Combine subscription is a 4-line `wireLateTakeDetector()` method on ShowController; replacing it with a callback hook is a localized change.

**What I'd revisit if**:
- Operators report image-cue late-takes (perceived delay before a cue lights up the screen) that the detector misses. Forces Path 1.
- Per-take latency variance turns out to be the dominant signal vs the binary late/on-time threshold — would call for a histogram in the show log, not just an event.

**Public API impact**:
- `ShowController.lateTakeDetector: LateTakeDetector` — internal so tests can inject.
- `ShowController.handleLiveSlideTransition(slideID:now:)` — pure-logic test seam.
- `ShowController.setPendingLateTakeCueDescriptor(_:)` / `clearPendingLateTakeCueDescriptorForTesting()` — test seams to drive the bridge without a real cue-runtime fire.
- `ShowLog.Action.lateTake` (already shipped session 17).

---

## 2026-05-08 — C10 thumbnail storage: per-slide JPEG sidecars under Cache/Thumbnails, not inline base64

**Decision**: `MediaImporter` writes one `<bundle>/Cache/Thumbnails/<slide.id>.jpg` per imported slide. The slide model is unchanged — no inline `posterThumbnailData: Data?` field in `MediaReference` / `MediaSlide`. Untitled documents fall back to App-Support `Simple Playback/Thumbnails/<sessionID>/`.

**Why**:
- **Project files stay JSON-small.** A 200-slide deck would carry ~2 MB of base64 data inline; the sidecar approach keeps Show.json under 100 KB even for that size.
- **Spec §3.17's `Cache/` parent already houses derived assets** (`Cache/Renders/` for PDF rasters). Sibling `Cache/Thumbnails/` is the obvious location and reads as "safe to delete" the same way.
- **Bundle for Travel needs no special handling** — copying the bundle copies the cache. The C7d resolver doesn't need to know about thumbnails.
- **Slide ID as the filename is canonical and stable.** UUIDs are unique across the project; a deleted-then-re-imported source produces a new slide ID and a fresh thumbnail.

**Alternatives considered**:
- **Inline base64 on `MediaSlide`** — works for untitled documents (no bundle) but bloats project files; nudged toward sidecar after seeing 200-slide projection.
- **Single sprite-sheet per project** (one PNG with N tiles) — saves inode overhead but complicates incremental imports; deferred to C11 (filmstrip), where sprite-sheet semantics are a better fit.
- **Per-slide PNG instead of JPEG** — lossless but ~5× larger; thumbnails don't need lossless and palette legibility doesn't suffer at quality 0.75.

**Reversibility**: easy. `ThumbnailGenerator` is producer-agnostic — switching to inline storage is a model change + an importer rewrite, not a generator rewrite.

**What I'd revisit if**:
- Operators report stale thumbnails after re-import (slide ID changed, old sidecar orphaned). Would call for a "Compact project" action that walks `Cache/Thumbnails/` and removes JPEGs no MediaSlide resolves to.
- Sidecar misses turn out to be common (e.g., bundle-without-cache shipped between machines). Would call for an inline fallback on top of the sidecar.

**Public API impact**:
- `Services/ThumbnailGenerator.swift` — pure-logic JPEG encoder.
- `MediaImportContext.thumbnailRootDirectory: URL?`.
- `MediaImporter.thumbnailEncoder: (URL, MediaKind) -> Data?` — static-var test seam.
- `ProjectBundleLayout.thumbnailsDirectory = "Cache/Thumbnails"`.
- `ThumbnailLoader.cachedThumbnail(for:in:)` — pure-logic offline fallback for tests.

---

## 2026-05-08 — Synchronize CompositorPipeline.bundleMediaDirectory through cacheLock (C7d hardening)

**Decision**: Make `CompositorPipeline.bundleMediaDirectory` a lock-synchronized property backed by a private `_bundleMediaDirectory: URL?` storage, accessed through the existing `cacheLock` that already guards `bugImageCache`. Setter now swaps the value and clears the cache atomically.

**Why**:
- **Correctness.** The writer (`PlaybackController.bundleMediaDirectory.didSet` on main) and the reader (`bugImage(for:)` / `resolveImage(_:)` on the playback `outputQueue`) cross threads. Reading a heap-typed `URL?` without synchronization is undefined behavior under Swift's memory model.
- **Coupled invariant.** The cache key depends on `resolvedURL(bundleMediaDirectory:)`. Mutating the dir without invalidating the cache (or vice versa) opens a window where a reader sees the new dir keyed against the old cache. The existing two-step (set + invalidate) read those as separate writes.
- **Reuse of an existing lock.** `cacheLock` already serializes the cache; piggybacking on it avoids a second NSLock and keeps the reader path one-acquire.

**Alternatives considered**:
- **OSAllocatedUnfairLock-wrapped value** (Sendable-friendly) — heavier than necessary for the v1 surface; would require a downstream Sendable refactor of `CompositorOverlays` to land cleanly.
- **Make CompositorPipeline an actor** — the read path is in submitFrame on outputQueue; making the pipeline an actor would force every drawing call to be async, which is a significant refactor of `submitFrame` and the transition path.
- **Atomic property wrapper** — would work but adds a dependency / property wrapper for a single property. `cacheLock` is already in scope.

**Reversibility**: easy. The public `bundleMediaDirectory` API is unchanged.

**What I'd revisit if**: Swift 6 strict concurrency lights up additional Sendable diagnostics on `URL?`-typed cross-actor properties; would unify the storage under `OSAllocatedUnfairLock` then.

---

## 2026-05-08 — Late-take detector source: Path 1 callback over Path 2 $liveSlideID proxy (E3+ tail)

**Decision**: Add `PlaybackController.onFirstComposedFrameForCue: ((UUID, Date) -> Void)?` callback that fires exactly once per `take(...)` when the first composed frame for that take reaches `submitFrame`. ShowController's `wireLateTakeDetector` switches its source from `playback.$liveSlideID` to the new callback.

**Why**:
- **Closes the image-cue blind spot.** Path 2 — observing `liveSlideID` — flipped synchronously inside `take(...)` for image cues, so `recordFrameSubmitted` always saw on-time latency. Operator-visible image-load delays (rare, but real on slow disks / network mounts) were never logged.
- **Tightens the video measurement too.** Path 2 measured "time until AVPlayerItemVideoOutput preparation completes" — which IS load latency, but a video that prepared quickly then stalled in `submitFrame` (compositor allocation, transport sink contention) wouldn't surface as late. Path 1 measures "time until first frame actually went to the output driver."
- **Single uniform contract for both media kinds.** Image and video cues converge on `submitFrame`; the callback is a single signal regardless of cue type.

**Alternatives considered**:
- **Use a Combine `PassthroughSubject`.** Idiomatic match for `$liveSlideID` it replaces, but a callback property is one fewer concept to thread through and avoids the receive-on-main hop (the callback dispatches to main internally).
- **Hook the video-output renderer's frame callback** instead of `submitFrame`. Would catch transport-driver failures too, but `submitFrame` is the one funnel point all takes share — image cues never hit the video-output renderer.
- **Add a more general "frame submitted" event sequence.** Overkill for v1; the late-take detector wants exactly one signal per take, not a stream.

**Reversibility**: easy. The Path 2 wiring is one Combine subscription that can be restored if Path 1 reveals a measurement defect.

**What I'd revisit if**:
- Operators report late-take entries with implausibly high latency (e.g., > 2 s on a healthy machine). Would call for a tighter dispatch — measure `Date()` inside `submitFrame` synchronously rather than on the callback's main-queue hop.
- The compositor's overlay path significantly slows `submitFrame` (multi-ms render). The callback would conflate compositor cost with media-load cost; a separate "media decoded" callback could disentangle.

**Public API impact**:
- `PlaybackController.onFirstComposedFrameForCue: ((UUID, Date) -> Void)?` — public property.
- Test seams `armPendingCueFireSlideIDForTesting`, `peekPendingCueFireSlideIDForTesting`, `simulateFirstComposedFrameForTesting`.
- ShowController's `liveSlideIDCancellable` removed; `playback.$liveSlideID` no longer subscribed by Show Control.
- `handleLiveSlideTransition(slideID:now:)` bridge entry point unchanged so the existing `ShowControllerLateTakeLogTests` pin survives.

---

## 2026-05-08 — C11 filmstrip storage: single sprite-sheet PNG per video, not per-frame sidecars

**Decision**: `FilmstripGenerator` produces one PNG per video, written by `FilmstripCoordinator` to `<bundle>/Cache/Filmstrips/<slide.id>.png`. Default 24 frames in a 6×4 grid at 160×90 per cell → 960×360 PNG (~50 KB). Centered-sample timestamps (`D × (i + 0.5)/N`) avoid decode-at-EOF and exact-zero failures.

**Why**:
- **Access pattern matches sprite-sheet.** A future scrub UI wants ALL frames at once for a drag gesture — one PNG read is cheaper than N file opens. C10's per-slide sidecar serves the inverse pattern (one tile at a time as the operator scrolls the palette).
- **Single inode per video.** A 200-video project's `Cache/Filmstrips/` has 200 entries with sprite sheets. A per-frame sidecar approach would have 200 × 24 = 4,800 entries — measurable on slower filesystems and a churn tax for `find` / Spotlight indexing.
- **Compose-once at extract time.** Drawing N CGImages into a single CGContext is one CG state setup; encoding once is one PNG header. Per-frame would re-encode 24 times.
- **Bundle-for-travel friendly.** Already `<bundle>/Cache/Filmstrips/`; copying the bundle copies the filmstrips. No special-casing.

**Alternatives considered**:
- **Per-frame JPEG sidecars under `Cache/Filmstrips/<slide.id>/0001.jpg` …** — aligned with C10's sidecar style but inverts the access pattern (N opens for one scrub gesture). Filed as the parallel-to-C10 in the C10 decision; rejected here for filmstrip semantics.
- **Single sprite-sheet JPEG.** Lossy compression smears mid-frame artefacts; PNG keeps the per-frame edges crisp at acceptable cost (~50 KB vs ~25 KB for JPEG). The cost differential isn't significant on typical bundle sizes.
- **Store sample timestamps in the sidecar.** A `slide.id.json` alongside the PNG with the timestamp-per-frame. Skipped — the centered-sample formula is deterministic from `(durationSeconds, frameCount)` and the consumer can recompute on the fly.

**Reversibility**: medium. The PNG output format is consumed by the eventual scrub UI; switching to per-frame sidecars later means a one-time re-render pass per project.

**What I'd revisit if**:
- The scrub UI needs sub-frame precision (more than 24 samples for long videos) — would scale `frameCount` with `durationSeconds` rather than fixing at 24.
- 50 KB per video bloats `Cache/Filmstrips/` enough to matter on bundle copies (a 1000-video project = 50 MB of cache). The cache is already explicitly OK to delete; not a blocker.

---

## 2026-05-08 — C11 cancellation deferred: synchronous extraction loop is uninterruptible, typical jobs finish under a second

**Decision**: `FilmstripCoordinator` does NOT expose a cancel hook for v1. The `Task.detached` running the extraction completes its work; the result is dropped (not written, not communicated) only via weak-self capture if the coordinator is deallocated.

**Why**:
- **The hot loop is uninterruptible.** `AVAssetImageGenerator.copyCGImage` is synchronous and there's no tolerance / cancellation hook between extractions. Adding cancellation would require either (a) checking a per-job cancel flag between frames (saves the latter half of an extraction but not the active frame), or (b) refactoring to the modern `generateCGImageAsynchronouslyForTime` API.
- **Typical jobs are fast.** A 24-frame extraction against a multi-GB H.264 source is ~200-500 ms on a modern host. Cancellation latency from "operator hits cancel" to "task actually stops" would be of similar magnitude — no operator-meaningful difference.
- **Document close already handles the runtime concern.** When the coordinator is deallocated, the in-flight task's `await MainActor.run { [weak self] in }` becomes a no-op; the result is harmlessly discarded.

**Alternatives considered**:
- **Per-frame cancel-flag check.** Would save the latter half of an extraction but the API surface (cancel(slideID:)) implies more responsiveness than we'd deliver.
- **Migrate to `generateCGImageAsynchronouslyForTime`.** The modern async API supports `Task` cancellation natively. Scoped out for v1 because the deprecation warning we already eat (in ThumbnailGenerator and elsewhere) is a follow-up sweep, not a blocker. Filed for the modernization pass.

**Reversibility**: easy. Adding cancel later is a non-breaking API addition.

**What I'd revisit if**: operators report stuck progress or wedge UI on a single misbehaving source (e.g., DRM-protected H.264 that takes 60 seconds per frame). At that point cancellation becomes a UX blocker, not a polish.

---

## 2026-05-08 — MediaReference bookmark branch returns nil when resolved file is missing (C7d hardening)

**Decision**: Gate the bookmark-resolution branch in `MediaReference.resolvedURL(bundleMediaDirectory:)` on `FileManager.default.fileExists(atPath: url.path)`. A stale bookmark resolving to a deleted file now falls through to the `originalPath` fallback (which already gated on `fileExists`).

**Why**:
- **Consistency with the rest of the resolver.** The bundle-Media branch and the originalPath fallback both check `fileExists`. The bookmark branch was the lone outlier returning a non-nil URL pointing nowhere.
- **Downstream consumers trusted non-nil as "online."** `TranscodeService.canTranscode` only checked `resolvedURL(...) != nil` — a stale bookmark would enable a misleading "Transcode to ProRes" right-click that then fails in `AVAssetExportSession`.
- **`AssetLibraryProbe.liveIsOnline` re-stats the URL anyway** so its classification was correct. The fix mostly removes the redundancy and tightens consumers that don't re-stat.

**Alternatives considered**:
- **Keep the contract loose ("URL might point nowhere") and force every consumer to re-stat.** Too easy to forget; this is the third such consumer found in code review. Centralizing the gate at `resolvedURL` is the contract simplification.

**Reversibility**: easy. Reverting is a one-line change.

**What I'd revisit if**: a real consumer needs the URL even when the file is gone (e.g., to display the operator-visible last-known path). Such a consumer would call into the bookmark resolver directly rather than through `resolvedURL`.

---

## 2026-05-08 — `MediaResolver` short-circuits unfingerprinted references before the search-root walk

**Why**: pre-C7 (legacy) references have nil fingerprint, so `storedHash` AND `storedSize` are both nil. Rung 2 (content hash) requires both; rung 3 (name + size) requires `storedSize`. With nil fingerprint, neither can ever match — yet the resolver was walking every file in every search root anyway, paying O(slides × roots × files) syscalls per legacy slide for a guaranteed-offline outcome. Reviewer finding from session 19 close-out, deferred at the time and fixed in session 20.

**The fix in two lines**:
```swift
if storedHash == nil && storedSize == nil {
    return .offline
}
```

**Alternatives considered**:
- **Break after the first-root iteration when `storedHash` is nil and `nameAndSizeHit` is set** (the literal session-19-prompt suggestion). Doesn't fire in this codebase because `MediaAssetFingerprint` couples `contentHash` and `size` — if hash is nil, size is nil too, so name+size can't match. The complete short-circuit is the right form.

**Reversibility**: trivial. Removing the guard restores the walk.

**What I'd revisit if**: future fingerprint variants add a size-only mode. The contract that "nil hash ⇒ nil size" is stable today; if it loosens, the short-circuit needs to weaken.

---

## 2026-05-08 — Debouncer wraps recomputeAssetLibraryStatus on slide-change bursts

**Why**: `RootView.onChange(of: project.slides)` fired on every individual slide mutation. A drag-reorder of a 500-slide deck triggers 500 sequential `AssetLibraryProbe.evaluate` calls, each making O(slides) `FileManager.fileExists` syscalls. ~250k syscalls per drag — visible UI hitch on slow disks.

**Decision**: extract a small `Services/Debouncer.swift` `@MainActor` class with an injected sleep closure. The debouncer cancels prior pending work and arms a fresh task on each `schedule(_:)`. The asset-library path uses a 250 ms window. `.onAppear` and bundle-URL change still call recompute directly so the banner doesn't lag a Save-As.

**Alternatives considered**:
- **Inline `@State Task<Void, Never>` directly in `RootView`.** Slightly less code but no testable seam, and the same primitive will likely be wanted elsewhere (e.g., debouncing future autosave hints or Pre-Show recomputes on slide drag).
- **Memoize on `(slides.count, slides.map(\.media.originalPath).hashValue, bundleMediaDirectory)` instead of debouncing.** A drag-reorder doesn't change the hash set, so memoization would skip the recompute entirely. Cleaner outcome but harder to invalidate correctly (mtime ≠ hash; relink without count change). Debounce is the conservative choice for v1.

**Reversibility**: easy — RootView's slide-change `onChange` reverts to a direct call. The Debouncer file is reusable but trivially deletable if unused.

**What I'd revisit if**: a future test exercises burst-then-immediate-read semantics (the debouncer's coalesce window would bite). Add an explicit `flush()` method to Debouncer at that point.

---

## 2026-05-08 — AssetRelinkPlan.apply infers `.linked` vs `.managed` from bundle-Media URL containment

**Why**: pre-fix, a `.managed` slide relinked via NSOpenPanel to a file outside `<bundle>/Media/` kept its `.managed` kind. Rung 0 of `MediaResolver` then silently failed to find the file at `<bundleMedia>/<basename>` and the bundle-aware online check misclassified the asset. The kind was lying about where the file actually lived.

**Decision**: add an optional `bundleMediaDirectory: URL?` parameter to `apply(...)`. When non-nil, infer kind from URL containment: descendants of `bundleMediaDirectory` become `.managed`, anything else `.linked`. Default-nil parameter preserves backward-compat for untitled-document callers (no bundle URL known) — they keep the existing kind. `inferKind(...)` exposed as a static helper so the per-slide Locate context-menu path applies the same rule.

**Alternatives considered**:
- **Force `apply` to require `bundleMediaDirectory`.** Cleaner contract, but requires plumbing a `nil` from untitled-doc test callers — the existing `testApplyPreservesMediaReferenceKind` would have to change to pass nil explicitly, and we'd lose the "untitled docs preserve" behavior implicit today.
- **String-prefix descendant check.** Trips on `Show.spb/MediaCache` vs `Show.spb/Media` (false positive). Path-component comparison after `standardizedFileURL.resolvingSymlinksInPath()` rejects sibling-with-shared-prefix correctly.

**Reversibility**: medium. Reverting drops the parameter and restores the kind-preserves-verbatim behavior; existing pinned tests would still pass.

**What I'd revisit if**: a future workflow legitimately wants to keep `.managed` for files that left the bundle (e.g., "this asset is bundle-tracked but currently checked out to a working folder"). No such use case today; the reverse-mapping (a `.linked` slide relinked into the bundle flips to `.managed`) is the real correctness win and is what Bundle for Travel implicitly relies on.

---

## 2026-05-08 — C11 importer-hook seam: closure on `MediaImportContext`, not a static-var coordinator

**Why**: C10 thumbnail caching uses a static-var seam (`MediaImporter.thumbnailEncoder`) because the encoder is purely stateless. C11 filmstrip generation goes through a per-document `FilmstripCoordinator` (so cancellation, jobs list, and document-close lifetimes are scoped per-window). A static seam would force all RootView instances to share a single global coordinator — broken for multi-document use.

**Decision**: add `enqueueFilmstrip: ((UUID, URL) -> Void)?` to `MediaImportContext`. The host (RootView) builds the closure with its own coordinator captured. The importer fires the closure once per video import (skipped for images and PDF/Keynote-rasterized pages). Default-nil for tests + untitled docs without a fallback.

**Alternatives considered**:
- **`filmstripDispatcher` static var** mirroring the thumbnail-encoder pattern. Simpler API surface but loses per-document coordinator scoping.
- **`coordinator: FilmstripCoordinator?` on the context** so the importer enqueues directly. Couples the importer to the coordinator type; closure keeps the importer concurrency-naive.

**Reversibility**: easy — drop the field and the call site. The closure has no escaping side effects beyond the coordinator's own `Task.detached` (which would be cancelled by the document going away).

**What I'd revisit if**: a third "fire on import" hook lands (e.g., audio-waveform pre-render). At that point an array of generic post-import side-effects might be cleaner than three named closures. v1 doesn't need it.

---

## 2026-05-08 — FilmstripGenerator → async AV APIs (Option J commit J1)

**Why**: `tracks(withMediaType:)` (macOS 13), `duration` (macOS 13), and `copyCGImage(at:actualTime:)` (macOS 15) are all deprecated in current SDKs. The next-session prompt called the migration "mostly mechanical" — true for FilmstripGenerator specifically because its only synchronous caller (`FilmstripCoordinator.enqueue`) already runs the work on a `Task.detached`, so adding `await` doesn't ripple.

**Decision**: convert `generateSpriteSheet(...)` to `async throws` and migrate to `loadTracks(withMediaType:)` / `load(.duration)` / `image(at:)`. The per-frame loop now calls `try Task.checkCancellation()` between extractions so a cancelled job aborts mid-loop. CancellationError is caught at the coordinator and silently drops the job (no operator-visible failure). `FilmstripCoordinator.generator` static seam becomes `@Sendable async throws`.

**Alternatives considered**:
- **Wrap async calls in `DispatchSemaphore` to keep the sync surface.** Anti-pattern; defeats the cancellation benefit and burns a thread.
- **Migrate ThumbnailGenerator + PlaybackController + MediaImporter at the same time.** Each ripples wider — ThumbnailGenerator is called inline from sync importer paths, PlaybackController is on the video timer, MediaImporter is on the foreground import path. Async migration there is a real refactor, not gardening. Deferred.

**Reversibility**: medium. The async signature is the natural shape; reverting requires a thread-blocking semaphore wait in the coordinator's detached Task.

**What I'd revisit if**: ThumbnailGenerator's `image(at:)` migration goes through later. At that point the FilmstripGenerator + ThumbnailGenerator could share a small "decode one CGImage at time T from URL" async helper.

---

## 2026-05-08 — Path 1 token arming inside the outputQueue critical section

**Why**: pre-fix, `commitPreparedVideoTransition` and the transition branch of `commitPreparedImageTransition` called `setPendingCueFireSlideID(prepared.slide.id)` on the main thread *after* `stopMediaOnly(preservingMediaForTransition: true)` had started the outgoing-handoff timer on `outputQueue`. A handoff tick that landed between the main-side arm and the first composed-frame `submitFrame` would consume the token by submitting an outgoing-video frame, firing `onFirstComposedFrameForCue` with `firedAt` ahead of the new cue's actual first composed frame. The late-take detector would record `latency≈0` for what should have been a slow new-cue load.

**Decision**: move arming into the same `syncOutput { ... }` block that cancels the outgoing-handoff timer and submits the first composed frame. For the still-transition image branch (where the first submit happens later in `renderStillTransitionFrame` on the timer-driven outputQueue), wrap the cancel + arm in their own `syncOutput { cancelOutgoingHandoffTimer(); setPendingCueFireSlideID(...) }` block immediately before `startStillTransition` schedules its first tick.

**Alternatives considered**:
- **Cancel the outgoing handoff timer on main before arming.** Works for the non-still-transition paths; fails for the still-transition image path because `cancelOutgoingHandoffTimer` mutates `outgoingHandoffSource` and that field is also read on outputQueue from `renderStillTransitionFrame`. syncOutput-wrapping is the cleaner contract.
- **Plumb a "this submit is a primary take frame" flag through `submitFrame`.** Adds a parameter with one truthy callsite; the outputQueue serialization argument is simpler.
- **Test the race deterministically.** The race is timing-dependent and would require either a fake DispatchSource that fires synchronously on a test-controlled tick, or a refactor that exposes the handoff timer's tick callback for direct invocation. The cost vs. value tradeoff favored doc-comment pinning instead.

**Reversibility**: easy. Reverting moves the arming back to the main-side, which is the pre-fix behavior.

**What I'd revisit if**: a future test suite gains a deterministic outputQueue-time-stepping primitive (some kind of "advance the queue by N ticks" hook). At that point the race could be reproduced + pinned with a fail-then-fix test.

---

## 2026-05-08 — ThumbnailGenerator: completion-handler bridge instead of full async migration

**Why**: `copyCGImage(at:actualTime:)` was deprecated in macOS 15 in favor of the async-only `image(at:)`. ThumbnailGenerator is called synchronously from `MediaImporter.thumbnailEncoder`, which is itself a sync closure invoked from the importer's slide-construction loop. Migrating ThumbnailGenerator to `async throws` would force MediaImporter to become async, which would ripple through RootView's drop/open-panel handlers, ImageSequenceEncoder.siblingImporter, TranscodeService.siblingImporter, and ~25 tests.

**Decision**: keep the public `generateJPEG(for:mediaKind:size:quality:)` signature sync `throws -> Data`. Internally, replace `copyCGImage(at:actualTime:)` with the non-deprecated completion-handler variant `generateCGImageAsynchronously(for:completionHandler:)` and bridge to a sync result via `DispatchSemaphore` + a small `@unchecked Sendable` box. The semaphore enforces the happens-before relationship that the box doesn't express on its own.

**Alternatives considered**:
- **Make ThumbnailGenerator async + propagate through MediaImporter.** Honest async migration but ~25-test ripple and 3-5 commits of plumbing. Punted as a follow-up gardening sweep when the importer naturally needs to become async (e.g., for bulk async metadata extraction).
- **Keep `copyCGImage` and accept the deprecation warning.** Ships warnings into every clean build that's passed forward. Tolerable but not zero-cost.
- **`Task.detached { await image(at:) }` with semaphore wait at the call site.** Allocates a Task per frame extract just to sync-wait; the completion-handler API is the same primitive without the actor hop.

**Reversibility**: easy. The bridge is local to one method; reverting drops the box + semaphore + completion-handler in favor of the deprecated sync API.

**What I'd revisit if**: MediaImporter naturally becomes async (a future async fingerprint API, or a bulk pre-fetch pass that benefits from `withTaskGroup`). At that point this method also goes async and the bridge is removed.

---

## 2026-05-08 — C8 folder bookmarks: project-level registry, not inline per-MediaReference

**Why**: spec §3.10 implies a folder-level bookmark + per-file relative path so a 50-clip folder produces ONE 1–2 KB security-scoped bookmark blob shared across every slide instead of 50 copies. The deduplication value is modest in raw KB (50 × ~1 KB → ~3 KB savings) but real in operator-facing semantics: a folder rename heals every slide that came from that folder via one bookmark, rather than relying on each per-file bookmark to survive independently.

**Decision**: store FolderBookmarks on `PlayoutProject.folderBookmarks: [FolderBookmark]` keyed by `id`. `MediaReference` carries `folderBookmarkID: UUID?` + `folderRelativePath: String?` — small references back into the project's lookup. Resolution callsites that want the new rung accept a `[UUID: FolderBookmark]` parameter (cheap dict construction at call time in RootView). The bundle-only `resolvedURL(bundleMediaDirectory:)` overload continues to work for callsites that haven't been threaded yet (PlaybackController/Compositor/TranscodeService).

**Alternatives considered**:
- **Inline-per-MediaReference: each slide carries its own copy of the folder bookmark Data.** No threading required; resolution stays self-contained. Loses the dedup goal (the whole point of folder bookmarks per the spec direction); arguably also breaks the C9 "show the operator which folder bookmarks are stale" surface that a future banner could expose by enumerating `project.folderBookmarks` directly.
- **Capture the bookmark eagerly in an opt-in wrapper at every read callsite.** Forces synchronization on every access (the bookmark resolve is cheap but not zero); the once-per-pre-show dict construction is far cheaper than once-per-take.
- **Use Swift `URL.bookmarkData(options: [.withSecurityScope])` with `relativeTo:` to make per-file bookmarks folder-relative.** Apple supports this but the sandbox semantics get fragile when the folder bookmark itself is stale (the relative-to bookmark's resolve depends on the parent's resolve, so a stale parent invalidates every relative-to child even when the file itself is reachable). The two-field approach we're using is the more robust shape.

**Reversibility**: medium. Removing FolderBookmark from the model is straightforward (decode-if-present everywhere); the resolver rung removal would be a one-line patch. The Add Folder importer wiring is the largest delete (one method + one optional parameter).

**What I'd revisit if**: operator workflows need *deep* per-file bookmark recovery (file moved out of the folder, parent folder renamed, etc.). The current rung 2 only handles "file moved within its imported folder." A more general "rebuild from common-prefix-path" recovery would need a different design.

---

## 2026-05-08 — C8 v1.1: thread folderBookmarks through every read path (session 22)

**Why**: the session-21 foundation stamped folderBookmarkID + folderRelativePath at import and threaded the lookup through `MediaReference.resolvedURL(bundleMediaDirectory:folderBookmarks:)` + `AssetLibraryProbe` + `AssetRelinkPlan`. That made pre-show + Locate Folder relink folder-bookmark-aware, but the playback hot path (`PlaybackController.take`), the compositor's overlay bug-image resolver (`CompositorPipeline.bugImage`), the transcode eligibility check + entry point (`TranscodeService.canTranscode` + `TranscodeCoordinator.transcode`), and the palette tile thumbnails (`SlideGridView.SlideTile` + `ThumbnailLoader`) still called the bundle-only `resolvedURL(bundleMediaDirectory:)` overload. A clip moved within its imported folder would only recover after the next pre-show / Locate Folder pass; the live take would print "Missing media".

**Decision**: add `folderBookmarks: [UUID: FolderBookmark]` to `PlaybackController` (mirrors to compositor in `didSet`, same shape as `bundleMediaDirectory`), to `CompositorPipeline` (lock-protected like `_bundleMediaDirectory`, with the same atomic cache invalidation on swap), and to `TranscodeService.canTranscode` / `TranscodeCoordinator.transcode` as a defaulted parameter. SlideGridView gains a folderBookmarks property threaded through SlideTile → ThumbnailView → `ThumbnailLoader.thumbnail(...)`. RootView publishes `playback.folderBookmarks` from `document.project.folderBookmarks` on `.onAppear` and on every change to that array (the `.onChange(of: document.project.folderBookmarks)` hook also triggers a missing-media banner recompute since the probe consumes the same lookup).

**Alternatives considered**:
- **Singleton "FolderBookmarkResolver" service.** Removes the threading at every consumer but introduces a global-state container that makes tests harder to seed and creates a new lifetime question (when does a document close clear its bookmarks?). The defaulted-parameter shape is pure and matches the existing `bundleMediaDirectory` discipline.
- **Compute the dict inside `MediaReference.resolvedURL` from a hidden static.** Same ownership problem as singleton.
- **Defer until v1.1.x and tell operators to run pre-show after every Add Folder rename.** Ship-blocking only for cross-host workflows that aren't yet exercised; could have waited. Picked the threading because the consumer-side story for a foundation that just landed is the natural completion, the work is well-bounded (3 commits), and it mirrors the C7d threading pattern the project already has muscle memory for.

**Reversibility**: easy. Each consumer's folderBookmarks property is additive with a sensible default (`[:]` or `nil` lookup → bundle-only resolution). Reverting drops the property and the wiring without touching the foundation.

**What I'd revisit if**: a future Director View / tear-off window grows a parallel media-resolution path that also needs the lookup. At that point a small `MediaResolutionContext` value type might be cleaner than continuing to thread the two parameters everywhere.

---

## 2026-05-08 — Option J: bridge MediaImporter / MediaFlagsInspector / PlaybackController copyCGImage off deprecated AV APIs (session 22)

**Why**: the session-21 ThumbnailGenerator bridge (DispatchSemaphore + `@unchecked Sendable` carrier wrapping `generateCGImageAsynchronously`) was filed as the prescribed shape for the remaining sync-AV deprecations. Three sites had the same shape problem: `MediaImporter.nativeFrameRate` + `MediaImporter.hasVideoTrack` (sync `AVURLAsset.tracks(withMediaType:)`), `MediaFlagsInspector.inspect` (same), and `PlaybackController.renderFirstPreparedFrame` (sync `copyCGImage`). All sit on background queues / off the render hot path; full async-propagation would force the importer's slide-construction loop to become async, rippling through ~25 callsites for marginal correctness gain.

**Decision**: apply the session-21 bridge pattern uniformly. `MediaImporter.loadFirstVideoTrackSync(url:)` is the single helper for both importer sites, wrapping `loadTracks(withMediaType:completionHandler:)` in a DispatchSemaphore + private `TrackLoadBox: @unchecked Sendable` carrier. `MediaFlagsInspector` duplicates the helper locally to avoid making MediaImporter's helper public — both helpers are tiny and could be merged in a follow-up if a third site needs the same shape. `PlaybackController.renderFirstPreparedFrame` bridges via `generateCGImageAsynchronously(for:completionHandler:)` + `FirstFrameBox: @unchecked Sendable` (filemate to ThumbnailGenerator's `ThumbnailExtractionBox`).

**Alternatives considered**:
- **Make MediaImporter / MediaFlagsInspector async end-to-end.** Honest migration but the importer's slide-construction loop would ripple through every drop/open-panel call, the encode/transcode sibling-importer callbacks, and the test seam. Punted as a follow-up gardening sweep when the importer naturally needs to become async (e.g., for bulk `loadValuesAsynchronously` over many slides at once).
- **Keep the deprecated sync calls and accept the SourceKit warning.** xcodebuild build doesn't surface the deprecations today (only SourceKit does), so the warnings don't print in CI. Tolerable but ships an unbounded "we know about this" debt forward.
- **Share one helper across MediaImporter + MediaFlagsInspector.** Considered; opted to duplicate the tiny helper locally to keep MediaImporter's helper private. A future merge into a `Services/AVTrackLoader.swift` is easy if a third caller materializes.

**Reversibility**: easy. Each bridge is local to one function; reverting replaces the box + semaphore + callback with the deprecated sync property read.

**What I'd revisit if**: track-level property reads (`nominalFrameRate`, `minFrameDuration`, `formatDescriptions`) trip a future SDK's deprecation gate that xcodebuild *does* surface. At that point a property-level bridge is the next layer — likely a small `loadVideoTrackProps(url:) -> (track: AVAssetTrack, fps: Double?, duration: CMTime?, formats: [CMFormatDescription])?` helper that loads everything in one async hop and returns a value-type bundle.

---

## 2026-05-08 — Option J close: shared AVTrackLoader + AudioPump bridge

**Decision**: Land `Services/AVTrackLoader.swift` as the single shared async-bridge entry point for AVAssetTrack loading + property reads. MediaImporter, MediaFlagsInspector, and AudioPump all consume it; their per-site `loadFirstVideoTrackSync` helpers (sessions 22) and the deprecated track-property accessors (`nominalFrameRate`, `minFrameDuration`, `formatDescriptions`) leave their respective files. The video entry point returns `AVTrackInspection { track, nominalFrameRate, minFrameDuration, formatDescriptions }` — the property loads run concurrently via `async let` inside one `Task.detached` hop, then bridge back to sync via `DispatchSemaphore`. The audio entry point returns `(asset: AVURLAsset, track: AVAssetTrack)?` because AVAssetReader requires the asset that owns its tracks and `AVAssetTrack.asset` is weak.

**Why**: Session 22 had explicitly deferred the consolidation, citing that the per-site duplicates were tiny and the merge was a clean follow-up if a third site needed it. The AudioPump leftover (`tracks(withMediaType: .audio)` at line 312) was that third site, and the shared loader cleans up the duplication at the same time. The track-property reads were also flagged in session 22 as a deprecation surface that SourceKit reported but xcodebuild build didn't surface — bundling the property reads into the same async hop closes that surface preemptively (one-file change if a future SDK gate makes the deprecations hard errors). Concurrent property loading is a small but real wins on slow-disk sources where the per-property AVF parse cost adds up.

**Why `Task.detached` rather than the existing callback-based bridge**: video property reads (`track.load(_:)`) are async-only — there is no callback variant. So the shared loader has to live inside a Task. The audio variant doesn't need property reads, so it stays on the existing callback shape.

**Why return `(asset, track)` for audio rather than just `track`**: AVAssetReader's documented contract requires that the track come from the asset associated with the reader (`reader.canAdd(output)` returns false otherwise). `AVAssetTrack.asset` is weak — if the loader returns just the track, the asset goes out of scope and the track's `.asset` reads nil; the caller can't recover the parent asset. Returning the tuple gives AudioPump a strong reference to keep alive across the reader-construction call. Tested: `testAudioLoaderReturnsNilForVideoOnlyMovie` confirms the audio path returns nil rather than throwing for an asset with no audio track.

**Alternatives considered**:
- **Leave the duplicated helpers in place.** Considered. The duplicate was tiny (~10 lines each) and the consolidation isn't load-bearing for build correctness. Rejected because the shared loader also bundles the property reads (which the duplicates didn't address), and the AudioPump bridge needed an entry point anyway — going through `AVTrackLoader` for two of three sites and not the third would have been worse than going through it for all three.
- **Per-site property bridges.** Considered. Three sites × three properties = nine sequential `track.load(_:)` calls, each on its own DispatchSemaphore. Rejected because the property-load fan-out via `async let` inside one Task is uniformly faster (concurrent vs sequential) and the boilerplate would be substantially more.
- **Drop the audio bridge entirely and migrate AudioPump to async.** AudioPump's `prepareReader()` is called from `pump.start(...)` which is called from `audioSubmitter()` — the chain ripples through PlaybackController and would force `start` and `crossfade` async on the playback hot path. Rejected as too large for this scope.

**Reversibility**: easy. Each consumer's edit is local to the inspect entry point. Reverting the shared loader is a one-file delete + restoring the per-site helpers from `git show 7a11a01^`. The Option-J track-loading deprecation surface listed in the session-22 prompt is closed; future SDK gates can be addressed inside `AVTrackLoader.swift` alone.

**What I'd revisit if**: a fourth site needs track inspection that goes beyond what the bundle exposes (e.g., reads `track.naturalSize` or `track.preferredTransform`). The bundle is intentionally minimal — adding a field is additive and cheap. If callers diverge in what they need, splitting `AVTrackInspection` into per-site shapes would be the next refactor; the shared loader can return `Any` payload via a generic if it gets that bad.

**Public API impact**:
- `Services/AVTrackLoader.swift` — `enum AVTrackLoader`, `struct AVTrackInspection { track, nominalFrameRate, minFrameDuration, formatDescriptions }`, `loadFirstVideoTrackInspection(url:) -> AVTrackInspection?`, `loadFirstAudioTrack(url:) -> (asset: AVURLAsset, track: AVAssetTrack)?`.
- `MediaImporter.nativeFrameRate(for:)` and `MediaImporter.hasVideoTrack(_:)` now read via the bundle. The local `loadFirstVideoTrackSync` + `TrackLoadBox` are gone.
- `MediaFlagsInspector.inspect(url:)` reads via the bundle; `frameRateLooksVariable` now takes `(nominalFrameRate: Float, minFrameDuration: CMTime)` rather than an `AVAssetTrack`. The local helper + carrier are gone.
- `AudioPump.AudioTrack.prepareReader()` reads via the audio entry point; the asset is the loader's asset rather than a fresh `AVAsset(url: url)`.
- 5 new pin tests in `AVTrackLoaderTests` (730 → 735 tests).

**Audit (Option H — Path 1 token consumers)**: confirmed at the same time. The token is armed by `take()` direct, `commitPreparedVideoTransition`, and both branches of `commitPreparedImageTransition`; dropped by `clear()` and `stopOutput()`. Other `submitFrame` callsites — `renderCurrentVideoFrame` (video timer), `renderStillTransitionFrame` (still-transition timer), and `renderOutgoingHandoffFrame` (outgoing handoff timer) — intentionally do NOT arm. They consume tokens armed by their take origin (correctly — the still-transition and outgoing-handoff first-frame submits ARE the take's first composed frame after the syncOutput cancel + arm) or run with a nil token. No new arming was added.

---

## 2026-05-08 — Session 24: Phase B summary refresh + codec advisory pre-show row

**What shipped this session**: 2 commits, 735 → 741 tests (+6).

1. **Phase B summary refresh (B16 partial — doc-only)** — `docs/phase_b_summary.md` gains a consolidated session-24 close-out header mirroring `phase_c_summary.md` shape: feature inventory (data model + topology, render hot path + sink fan-out, REF lock state, 10-bit recommendation logic, compositor, frame-rate conformance), test surface inventory (~55 tests across 6 files), consolidated 10-step manual rehearsal checklist (some autonomy-verifiable; most hardware-bound), and explicit scoped-out tail (B7/B9/B10/B11/B13/B15 — all hardware- or UX-blocked, none autonomy-shippable today). The older sessions 1-5 narrative is preserved below as a historical log. progress.md cleanup: `B14` flipped from `[~]` to `[x]` (the "Pre-show check (E1) reuse pending" deferral note was stale once `PreShowCheck.evaluateFrameRateConformance(project:)` landed in session 13). `B16` flipped to `[~]` (summary shipped; `MockDeckLinkSink` test fixture is queued for B7/B9 coupled work and not needed today).

2. **Codec advisory pre-show row (E1+ tail)** — `PreShowCheck.evaluateCodecAdvisory(project:)` rolls up the C1 flags (`longGOP` / `variableFrameRate` / `untaggedColor`) across `project.slides` as a single info-severity row. Suppressed entirely when no clip carries an advisory. `tenBitYUV420` keeps its existing dedicated row (`output.tenBit`) because it's an output-side recommendation; `animatedImage` is excluded because it surfaces inline as a transcode chip on the cue inspector and doesn't generalize to a roll-up message. 6 new tests in `PreShowCheckTests` pin the rule.

**Why session 24 chose Option B (Phase B gardening) + E1+ tail rather than Option H (full reviewer audit) or Option A (resolve C11-4 blocker)**:

- **Option A — C11-4 cue-inspector scrub UI consumer** — the blocker is a product-decision blocker (UX choice between static strip / drag-scrub / click-to-set-inPoint) that needs operator input. Picking autonomously violates the runbook's blocker policy. Skip until the user resolves it.
- **Option H — full reviewer audit** — the next-session prompt called this "Phase B documentation pass + reviewer audit on full v1 diff so far (Phase F / F1 prep)". F1 belongs to Phase F's wrap-up sweep and the act of generating that audit is sized for a full session of its own. Picking it now would crowd out other work.
- **Option B + E1+ tail** — the Phase B summary refresh is a runbook §2.5-prescribed deliverable that had been deferred since session 5; getting it done before any Phase F work avoids stale-context-on-summary risk. The E1+ codec advisory was a small, well-bounded coda that uses the same C1 primitives the summary touches (longGOP / VFR / untaggedColor), so it stays coherent with the gardening thread.

**Public API impact session 24**:
- `Services/PreShowCheck.swift` gains `static func evaluateCodecAdvisory(project: PlayoutProject) -> Row?`. Wired into `evaluate(project:context:)` between the ten-bit row and the external-reference row. Row id `media.codec`, severity `.info`, title "Codec".
- `Simple PlaybackTests/PreShowCheckTests.swift` gains six new test cases under a `MARK: - Codec advisory (E1+ session 24)` section.
- `docs/phase_b_summary.md` gains the session-24 close-out header. Older sessions 1-5 narrative is unchanged.
- `docs/phase_e_summary.md` gains a session-24 entry at the top.
- `docs/progress.md` flips B14 to done, B16 to partial, and updates the "Last commit" pointer.

**Reversibility**: easy on both threads.
- The codec advisory row is purely additive — drop the static function and the one-line wire-up in `evaluate(...)` and pre-show is back to its session-22 surface.
- Doc reverts are git-revert-clean; no behavior couples to the doc updates.

**What I'd revisit if**:
- The codec advisory row turns out to be too noisy in real-world projects (e.g., every iPhone-imported clip flags untaggedColor, and the row becomes a "yes, we noticed" click-to-dismiss). Alternative: gate the untaggedColor count behind a `>= N` threshold or fold it into a single-pass "transcode-eligible content count" row. Defer the redesign until operator feedback.
- Phase F's reviewer audit surfaces P1s in Phase B that the session-24 summary missed (e.g., a B5 race condition the summary doesn't call out). At that point the summary gets a session-N "deferred reviewer findings" addendum, mirroring how Phase C session-19 + 20 handled C16's punch list.

---

## 2026-05-08 — Session 25: F1 reviewer sweep + F2 README + F3 api.md

**What shipped this session**: 7 commits, 741 → 747 tests (+6).

Session 25 picked the recommended Option B + Option C combo: F1 code-reviewer audit against the cumulative v1 diff plus F2/F3 doc-only deliverables. The reviewer surfaced 1 P0 + 4 P1s + 3 deferred items. All 5 actionable findings shipped as hardening commits, and F2 + F3 landed as doc-only commits in the same window.

**The 5 reviewer findings shipped (in order)**:

1. **F1 P1 #5 — `FilmstripCoordinator.writer` Sendable seam** (`Simple Playback/Services/FilmstripCoordinator.swift:53`). The static `writer` test seam was `nonisolated(unsafe)` but the closure type was plain `(Data, URL) throws -> Void`, captured implicitly inside `Task.detached`. Mismatch with the `@Sendable` shape on the sibling `generator` seam two lines above; closes a Swift 6 strict-concurrency hole. One-character fix: `@Sendable` annotation. Tests already substitute pure closures; no test churn.

2. **F1 P1 #2 — `PlaybackController.hasRenderedAnyFrame` flipped off main** (`PlaybackController.swift:1404`). `submitFrame` runs on `outputQueue`; flipping the `@Published` flag from there published a Combine notification on the wrong thread the first time a session composed a frame. Mirrored the dropped-frame-counter pattern at line 1481: dispatch the flip back to main with a re-check guard so the hop only fires once per session.

3. **F1 P1 #3 — `CompositeVideoOutputDriver.activeDriver` raced between video + audio queues** (`Simple Playback/Output/VideoOutput.swift:118`). `submitVideoFrame` runs on `PlaybackController.outputQueue`; `submitAudioPCM16` runs on a separate audio queue. Both read `activeDriver` while `start`/`stop` write it. Same Swift memory-model hazard the C16 close-out fixed for `CompositorPipeline.bundleMediaDirectory`. Mirrored the same NSLock pattern: backing storage `_activeDriver` + computed `activeDriver` going through `driverLock.lock()`.

4. **F1 P1 #4 — `ShowLog` silently dropped persistence on writer failure** (`ShowLog.swift:168-174`). On a failed CSV write (read-only volume, NAS timeout, full disk, permission flip mid-show) the writer cleared `fileURL = nil` and continued in memory with no operator-visible signal. Spec §3.16 lists the on-disk log as a v1 reliability artifact, so silent drop is not acceptable. Added `@Published var persistenceState: .healthy | .suspended(reason: String)`; failures flip the state and clear `fileURL` so subsequent appends short-circuit. `ShowLogView` renders an orange "Disk log paused — events still captured in memory" banner with the reason text. Operator re-arms by calling `setFileURL` again, which resets state to `.healthy`. 4 new pin tests cover initial state, seed-fail transition, append-fail transition, re-arm reset.

5. **F1 P0 #1 — `CueRuntime` unsynchronized across OSC/HTTP queues vs main** (`Simple Playback/Playback/CueRuntime.swift` consumed by `ShowControlDispatcher.swift:165-326`). The most consequential threading hole in the v1: OSC and HTTP arrive on `NWConnection` queues, while local operator GO/PREV/PANIC/CLEAR runs on main via `ShowController`. Without serialization a Companion fire racing an operator press could mutate `showList`, `cueStates`, `panicActive`, and the GO debounce simultaneously from two threads.

   **Fix path chosen** — wrap the host-interceptor + perform() block inside `dispatch()` in a `Thread.isMainThread` guarded `DispatchQueue.main.sync` hop. Capability check + idempotency lockout stay off main (they already use their own synchronization). The `Thread.isMainThread` guard avoids a deadlock when XCTest's test methods run on main; tests that call `dispatcher.dispatch(...)` synchronously continue working. Two new pin tests in `ShowControlTests`: off-main dispatch hops to main + returns synchronously, and on-main dispatch doesn't deadlock.

   **Alternative considered** — serialize all CueRuntime mutating entry points behind a private DispatchQueue inside the runtime itself. Rejected because the read surface is wide (every dispatcher branch reads `runtime.showList`, `runtime.state(of:)`, etc.) and would need lock guards on the read side too. The dispatcher hop is contained: one method, one indirection, no surface change for callers.

**The 3 deferred items** (logged for a future-session reviewer pass):

- **Project-lock-file hostname source canonicalization** — `ProjectLockFile.swift:198` uses `gethostname(2)` while other macOS apps may record `Host.current().localizedName`. Two writers on the same machine using the two APIs would not see each other's locks as `localLive`. Needs a manual cross-host rehearsal (queue under `docs/manual_verification.md`) before deciding which API is canonical.
- **`AVTrackLoader.loadFirstVideoTrackInspection` semaphore bridge** — `AVTrackLoader.swift:42-62` issues `Task.detached` then blocks the calling thread on a semaphore. Acceptable today because every caller is import-time / off-render-hot-path, but blocking the cooperative thread pool from a sync entry is a known footgun. Worth migrating to a true async API at the Phase F audio refactor.
- **`PlaybackController.compositorOverlays.didSet` re-publish ordering** — `PlaybackController.swift:54, 1186-1198`. Two rapid overlay edits during a take can interleave the published preview images out of order. Low real-world risk (operator-paced edits) but worth a small ordering pin if Phase F adds programmatic overlay automation.

**F2 README + F3 docs/api.md** (doc-only):
- README.md grew from a 36-line stub into a v1 feature surface walkthrough — Phase A/B/C/D/E inventories, OSC quick-reference table, project-bundle layout, hardware-verification cross-reference. Companion module path documented as a sibling-repo deliverable per `docs/phase_d/companion_module_design.md`.
- `docs/api.md` (new, 441 lines) — full integrator reference: transports + ports + Bonjour, auth + capability semantics, every OSC/HTTP/WS address with sample reply envelopes, OSCQuery handshake, timecode source-spec strings, idempotency keying table, source-attribution mapping, worked curl/websocat/oscsend examples, "not yet wired (v1 ack-only)" appendix calling out scrub / opacity / audio-level / goto / look-recall / output-freeze / workspace-save until host interceptors land.

**Why session 25 picked Option B + C over Option A (resolve C11-4) and the other E11/E9/E10 candidates**: C11-4 is still a product-decision blocker awaiting operator UX input; the briefing said "If the user resolved C11-4, Option A. Otherwise Option B is the highest-leverage gardening pick." E11 (brightness adapt) / E9 (Director View) / E10 (Saved Workspaces) all surface their own product-decision blockers. F1 has no UX questions and the reviewer-sweep punch list is the kind of well-bounded technical work that fits an autonomous session cleanly. F2 + F3 fold in alongside without overlap because they're doc-only.

**Public API impact session 25**:
- `Services/ShowLog.swift` gains `enum PersistenceState` + `@Published private(set) var persistenceState`. `setFileURL` now resets the state to `.healthy` on a non-nil URL and to `.suspended(reason)` on a seed-write failure. `append(_:)` flips to `.suspended(reason)` on writer throw and clears `fileURL`. New private `suspendPersistence(reason:)` helper.
- `Services/FilmstripCoordinator.swift` — `writer` static seam typed `@Sendable (Data, URL) throws -> Void`. No call-site change required.
- `Output/VideoOutput.swift` — `CompositeVideoOutputDriver.activeDriver` becomes a computed property over `_activeDriver` + `driverLock: NSLock`. Public surface unchanged.
- `Playback/PlaybackController.swift` — `submitFrame` flips `hasRenderedAnyFrame` via a `DispatchQueue.main.async` hop. Public surface unchanged.
- `ShowControl/ShowControlDispatcher.swift` — `dispatch(...)` runs the host-interceptor + perform block through a private `runOnMain(_:)` helper that's a no-op when on main. Public signature unchanged. Tests that called `dispatch` from the XCTest main thread continue to work.
- `Views/ShowLogView.swift` — `persistenceSuspendedBanner(reason:)` view builder + a conditional render between the filter toolbar and the row list.
- README.md — full rewrite (5 → 138 lines).
- `docs/api.md` — new file (441 lines).
- `docs/progress.md` — Phase F status updated; F1 marked partial-shipped, F2 + F3 marked done, "Last commit" pointer updated.

**Reversibility**:
- Each finding's commit is independent; any one can be reverted without touching the others.
- The README rewrite is git-revert clean; the api.md is a new file (just delete).
- The dispatcher main-hop is the only change with non-trivial behavior implications; the pin tests document the contract so a future revert would visibly break them.

**What I'd revisit if**:
- The `DispatchQueue.main.sync` hop introduces noticeable latency in a real Companion preset stress test (8+ button presses/sec). Backup plan: switch to a `runtime.serialQueue` inside CueRuntime so the dispatcher can fan dispatch off-main without main-actor entanglement. Today's hop is the smallest defensible fix; the pin tests give us a clear regression signal if the move-to-runtime-queue alternative becomes necessary.
- The ShowLog suspension banner gets in operators' way when a brief network blip flips a NAS-backed log to suspended and then immediately recovers. Could add a "retry on next event" mode (write attempt every Nth event) — defer until the operator-feedback signal lands.

---

## 2026-05-08 — F5 fixture-policy guard + F6 handoff doc + CompositorOverlays ordering pin re-evaluated (session 26)

**Decision**: F5 ships as a policy guard plus a synthesis-pattern catalogue, not as a regeneration script for committed binaries. F6 ships as `docs/handoff.md` pointing at three audiences (integrators, operators, future autonomy). The CompositorOverlays didSet ordering pin from session 25's deferred list is re-classified as redundant for v1; documented in `phase_f_summary.md` rather than committed as a test.

**Why**:

- **F5**: the audit found zero committed binary fixtures. Every test under `Simple PlaybackTests/` synthesizes its inputs at runtime — five canonical patterns (CGPDFContext PDFs, AVAssetWriter tiny .mov, CGContext bitmap PNGs, CGImageDestination GIFs/APNGs, sentinel Data blobs). Writing per-fixture regeneration scripts for fixtures that don't exist would be obviously redundant. The right shape was a guard that defends the policy + a catalogue documenting the synthesis patterns so a future contributor knows the canonical helper to copy from. `Scripts/regenerate-fixtures.sh` walks `Simple PlaybackTests/` and exits 1 if any non-Swift file appears. Reserves an `ALLOWED_FIXTURES` array for documented exceptions if synthesis genuinely won't work for a future test.
- **F6**: the runbook spec is "final phase summary + handoff document"; the natural shape is a single document a new collaborator reads first, with everything else in `docs/` referenced from there. Three explicit audiences (integrator / operator / future autonomy) avoids the "who is this for" ambiguity. Lists the deferred items + v2 candidates in one place so the next planning round can scope without re-reading the per-phase summaries.
- **CompositorOverlays didSet ordering pin**: session-25's deferred entry described "two rapid overlay edits during a take can interleave the published preview images out of order" as a low-risk Phase F concern. Tracing the publish path on session 26 — `compositorOverlays = …` on main → `syncOutput` → `compositor.compose` back on main → `publishTransitionPreview` does `DispatchQueue.main.async { transitionPreviewImage = image }` — confirms the order is FIFO-preserved by construction (main-thread writes enqueue async blocks in arrival order; main runloop drains FIFO). A meaningful pin test would need pixel-content assertion to confirm the second image actually reflects the second overlays state, which pulls in a full pipeline (CompositorPipeline is private; would need a test seam). The cost outweighs the marginal coverage; the contract is now documented in `docs/handoff.md` so a future Phase-F entry-point that adds programmatic overlay automation has the FIFO assumption pinned in prose.

**Alternatives considered**:

- **F5 as per-fixture regen scripts**: rejected — fixtures don't exist; would be writing scripts that produce nothing. Equivalent of writing `cd /tmp && true` and committing it.
- **F5 with a CI hook for the guard**: rejected per runbook §5 (no CI changes from autonomous sessions). The guard runs manually; future operators can wire it into a pre-commit hook locally if desired.
- **F6 as "Phase F summary v2"**: rejected — `phase_f_summary.md` already exists and grew session-by-session; a separate handoff document with audience-specific entry points reads better than a single chronological summary.
- **CompositorOverlays pin via test seam**: feasible if `CompositorPipeline` exposes an injectable hook, but adding test seams to passing code for an issue that's structurally non-existent is the kind of speculative-design abstraction the runbook (and `tone and style` rules) explicitly warn against.

**Reversibility**: easy. The guard script + catalogue + handoff doc are doc-only / script-only commits; reverting them costs nothing. The CompositorOverlays decision is text-only.

**What I'd revisit if**:

- A future test legitimately requires a real-world fixture (operator-supplied PowerPoint export, malformed PDF the inspector should reject, real-camera ProRes file with embedded metadata AVAssetWriter can't reproduce). Then the fixture-add checklist in `docs/test_fixtures.md` kicks in: `Simple PlaybackTests/Fixtures/<area>/<name>.<ext>` placement, per-fixture script under `Scripts/regenerate-fixtures/<name>.sh`, `ALLOWED_FIXTURES` update, decision-log rationale.
- Phase F adds programmatic overlay automation (e.g., an OSC-driven overlay edit that arrives off main). At that point the CompositorOverlays didSet ordering contract becomes load-bearing; the FIFO guarantee documented in `phase_f_summary.md` would need to either be re-verified for the new entry path, or hardened with a seam + pin.

---

## 2026-05-08 — F1 P2: ProjectLockFile hostname API lock-in (session 26)

**Decision**: Lock in `gethostname(2)` as the canonical hostname source for `.lock` records. Document the load-bearing nature of the choice in the source comment + manual-verification rehearsal step. The deferred item from the session-25 F1 reviewer sweep ("project-lock-file hostname canonicalization") closes here — no API swap, but the rationale is now load-bearing in the code.

**Why**: This app is the only writer of `<bundle>/.lock`. The hazard the deferred item flagged was hypothetical — two writers using two different APIs (`gethostname(2)` vs `Host.current().localizedName`) would disagree about whether a foreign lock matches the local hostname, mis-classifying `localStale` as `foreignStale`. Since no other process writes our lock format, the only way that hazard materializes is if a future revision of this app swaps the API and then meets a `.lock` written by an older version. The right close-out is therefore not a code change but a comment that locks in the choice with the backwards-compatibility rationale, plus a manual-verification entry pointing at the lock-in. `Host.current()` (legacy `NSHost`) is also `@MainActor`-bound on modern macOS, has been deprecated in spirit, and returns a user-visible form ("Josh's Mac") that's not what other Darwin processes see — `gethostname(2)` is the kernel's canonical answer and what every other Unix `hostname`-using tool sees.

**Alternatives considered**:

- **Swap to `Host.current().localizedName`**: rejected — adds main-actor entanglement, returns a less-stable string, and would require migrating in-flight lock files. No operator-visible upside.
- **Add a runtime hostname-source override field to the `.lock` schema** (e.g. `hostnameSource: "gethostname(2)"`): rejected — over-engineering for a hazard that doesn't exist today and could be addressed later without breaking compatibility (read-side only needs to decode current files).
- **Leave the comment as-is and move on**: rejected — the original comment said "kernel's canonical identifier" but didn't explain why an alternative would be unsafe. A future contributor reading just the comment might reasonably swap to `Host.current()` for "modernization" reasons.

**Reversibility**: easy — revert the comment + manual_verification text. The code path is unchanged.

**What I'd revisit if**:

- A cross-host NAS rehearsal surfaces operator confusion about the `.local` suffix in the foreign-host banner copy. The right fix then is to format the banner string (e.g. strip `.local` for display only) rather than swap the underlying API — keep the lock comparison stable.
- A second app or sibling-tool needs to write or read our `.lock` format. Then we'd document the schema as a public contract and pin `gethostname(2)` formally; nothing changes in this app's code.

---
