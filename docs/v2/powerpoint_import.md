# v2 Pre-Scope — PowerPoint `.pptx` Import

**Status**: pre-scope (planning only — no code).
**Filed**: 2026-05-08, session 27.
**Spec source**: `docs/spec/feature_spec.md` §3.10 ("Out of v1: PowerPoint .pptx import — operators export to PDF first. Re-evaluate in v2 (see §4)") and §4 item 12 ("PowerPoint `.pptx` import — bundled LibreOffice headless → PDF → bitmaps, or detect installed Office. Deferred from v1 to keep the install footprint small.").
**Runbook source**: `docs/runbook.md` §1 ("PowerPoint import: Out of scope for v1. Moved to v2 roadmap").

---

## Why v2, not v1

The v1 runbook chose to ship Keynote import (AppleScript-driven, zero install footprint, free with macOS) and defer PowerPoint to v2 because every PowerPoint code path drags in either:

- **A bundled LibreOffice runtime** (~250 MB unpacked; license: MPL 2.0 — compatible, but the binary distribution is the operational problem).
- **A "detect installed Office" path** that only helps the subset of operators who already license Microsoft 365 / Office for Mac, and even then has the same AppleScript-fragility as Keynote.
- **A pure-Swift `.pptx` parser** (Open XML SpreadsheetML / PresentationML) that re-implements Office's render engine — large surface area for a feature that operators bypass by exporting to PDF.

The corporate-AV target operator already exports `.pptx` → PDF in PowerPoint before the show; v1 ships PDF import via PDFKit (C3) and the operator's authoring loop is unblocked. v2 is for the operators who arrive at FOH with `.pptx` in hand and no laptop running Office.

## What "PowerPoint import" means in v1 terms

The shape mirrors C6 (Keynote): drop a `.pptx` on the palette, get one slide per page rasterized at output × 2, ProRes-trans­codable like any other still. The deliverable is *not* live-rendered PowerPoint output (that's authoring; out of scope per §5).

Specifically:

- **Input**: `.pptx` (the modern Open XML format). `.ppt` (legacy binary CFB) is explicitly out of scope — operators with `.ppt` decks save-as `.pptx` first.
- **Output**: a sequence of `MediaSlide` rows in the palette, each backed by a rasterized PNG in `Cache/Renders/<deck>/<NNNN>.png`, dimensions = `Stage × 2`. Same path as PDF / Keynote import.
- **Failure mode**: a single non-modal banner row (the `ImportStatusBanner` from C-banner) when the conversion fails: "PowerPoint not installed" / "LibreOffice unavailable" / "deck unreadable" — same error-mapping shape as `KeynoteImportError`.

## Open product questions

These need an operator-side answer before any code lands:

1. **Bundled LibreOffice vs detect-installed-Office vs both?**
   - **A — Bundle LibreOffice**: works for every operator, every machine. Cost: ~250 MB extra binary, notarization story complicates (sub-bundle signing, hardened runtime per LO subprocess), Sparkle delta sizes balloon. Real-world export quality is "very good for static decks, occasional font fallback on uncommon corporate fonts."
   - **B — Detect installed Office**: zero install footprint cost, but only ~40 % of corporate-AV operators have Office for Mac licensed on the show machine. AppleScript driving PowerPoint (`tell application "Microsoft PowerPoint"`) is the same fragile path as Keynote — works when it works, breaks on Office update cadence.
   - **C — Both, with Office preferred when present**: maximizes coverage, doubles test surface, doubles maintenance.
   - **D — `.pptx` only via cloud render** (e.g., a small operator-controlled service): out of scope for v2 (network dependency in a v1 product whose value prop is "no network at show time").

2. **Font fallback policy.**
   PowerPoint decks routinely embed fonts the show machine doesn't have. LibreOffice substitutes silently; PowerPoint's AppleScript export honors the embed if licensed for distribution and falls back to "best match" otherwise. Both produce a deck that *renders* but may have layout shifts. Should the importer surface a "fonts substituted" warning per page (requires diff-against-source-font-list, non-trivial), or treat font fidelity as the operator's pre-show responsibility (status quo for Keynote)?

3. **Slide-master / hidden-slide handling.**
   PowerPoint decks often have hidden slides (speaker drafts, build variants). LibreOffice exports them as PDF pages; PowerPoint AppleScript respects the hidden flag. Hidden-slide-as-rasterized-page is a footgun (operator hits Space and an unintended slide goes live). Recommended default: **skip hidden slides on export**, surface a per-deck "N hidden slides skipped" line in the import banner.

4. **Animation-on-slide handling.**
   PowerPoint slides with build-on animations export as the *final* state in PDF (PowerPoint does this by design). Operators who want intermediate states must duplicate the slide, but most don't. Recommended default: match PowerPoint behaviour (final state only); document this in the README import section. A future "export each animation step as a separate slide" toggle is a v3 feature.

5. **Speaker notes.**
   PowerPoint exports notes as inline text under each slide in PDF (operator-toggleable on export). For our purposes notes are operator territory (per-cue notes field, populated manually). Recommended default: **strip notes from export** so the rasterized slide is just the slide.

## Dependency map

- **C3 PDFImporter** — the leaf of the path; PowerPoint converts to PDF and the existing rasterize plumbing finishes the job. No PDFImporter changes needed.
- **C6 KeynoteImporter pattern** — the structural twin. Reuse:
  - `enum PowerPointImportError: LocalizedError` (mirrors `KeynoteImportError` cases: `.notInstalled`, `.unreadable`, `.exportFailed`).
  - `static var workspaceProvider` test seam (mirrors `KeynoteImporter.workspaceProvider`).
  - `static func isPowerPointInstalled() -> Bool`.
  - `static func exportToPDF(pptxURL:destinationDirectory:) throws -> URL`.
  - AppleScript shape: `tell application "Microsoft PowerPoint" → set theDoc to open … → save theDoc in … as save as PDF`.
- **C-banner `ImportStatusBanner`** — single uniform failure surface; PowerPoint failure rows queue here like every other import failure.
- **MediaImporter routing** — `.pptx` extension dispatches to `PowerPointImporter.exportToPDF(...)` then hands the resulting PDF to `PDFImporter`, mirroring `MediaImporter.importSlides` Keynote routing. Test seam matches the existing `keynoteExporter` pattern.
- **Entitlements** — if Office route is used, `com.apple.security.automation.apple-events` already shipped for Keynote; same entitlement covers PowerPoint AppleScript. If LibreOffice route is used, no entitlements needed (it's a sub-process invocation, not a scripting bridge).
- **Project-bundle layout** — `Cache/Renders/<deck>/<NNNN>.png` is the existing PDF output location; reuse without change.

## Suggested first-slice (assumes Option C — both paths, Office preferred when present)

1. **PowerPointImporter skeleton + tests** (1 commit, ~300 LOC + ~150 LOC tests).
   - `Services/PowerPointImporter.swift` mirroring `KeynoteImporter.swift`.
   - `enum PowerPointImportError`; `isPowerPointInstalled()`; `exportToPDF(...)`.
   - AppleScript shape pin tests; install-detection branch; error mapping; same shape as `KeynoteImporterTests`.
   - **No MediaImporter wiring yet** — service is leaf-only until route ships.

2. **MediaImporter routing for `.pptx`** (1 commit).
   - Inject `powerPointExporter` test seam alongside `keynoteExporter`.
   - Route `.pptx` extension through `PowerPointImporter` → `PDFImporter`, surface failures via `MediaImportFailure`.
   - Update `MediaImporterTests` with the routing pin.

3. **LibreOffice fallback** (2-3 commits, **only if Option A or C chosen**).
   - SDK distribution decision recorded in `decision_log.md` (license, binary-size delta, notarization plan).
   - `LibreOfficeRunner` Process-launch wrapper invoking `soffice --headless --convert-to pdf <pptx> --outdir <dir>`.
   - Test fixture: synthesize a tiny `.pptx` via XML synthesis (Open XML is just zip+XML; ~50 LOC). Pin the round-trip.
   - Wire as fallback in `PowerPointImporter.exportToPDF` when `isPowerPointInstalled() == false`.

4. **Hidden-slide / notes / font-fallback policy commit** (1 commit, doc + small AppleScript flag tweaks).
   - Update the AppleScript shape to skip-hidden + strip-notes per the recommended defaults above.
   - Update `docs/manual_verification.md` with a PowerPoint rehearsal section: open a representative deck, verify slide count, verify hidden slides excluded, verify no notes in render.

5. **C-banner integration + import-status row format** (1 commit).
   - "PowerPoint not installed — install Microsoft PowerPoint or enable bundled LibreOffice in Settings" (or whatever the resolution is).
   - "PowerPoint deck `<name>` failed to export: <reason>".

## Risks / unknowns

- **PowerPoint AppleScript surface drift.** Microsoft updates Office on its own cadence; the AppleScript bridge has historically been less stable than Keynote's. Mitigation: same as Keynote — pin the AppleScript shape in tests, file-issue-and-fall-through if a future Office update breaks the bridge.
- **LibreOffice notarization / sub-bundle signing.** If the bundled-LO route lands, the LibreOffice binary tree needs to be signed and notarized as part of the Simple Playback bundle. This is a release-engineering problem, not a code problem; the decision lives in the `Distribution/` infra (which is autonomous-write off-limits per the runbook).
- **Real-world deck variety.** Keynote's "I've seen everything" rehearsal items (per `docs/manual_verification.md`) are specific corporate decks; PowerPoint will need its own version of that list, including macros / embedded fonts / hidden slides / animation-build pages.

## When to revisit

- Operators consistently arrive at FOH with `.pptx` and no Office license → bias toward Option A (bundled LibreOffice).
- Office for Mac becomes free / bundled with macOS → bias toward Option B (detect-installed).
- A pure-Swift `.pptx` rasterizer becomes available (e.g., via a community SwiftPM package) → re-scope around it; remove the bundled-runtime decision entirely.

## Estimated effort

5-8 commits, ~1200-1800 LOC including tests. Depends on the bundled-LibreOffice path being in scope (adds ~600 LOC + the binary distribution infra).
