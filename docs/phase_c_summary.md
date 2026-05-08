# Phase C — Media pipeline — Summary

**Status (session 7 — 2026-05-08)**: C3 shipped end-to-end (PDF rasterize-on-import). 243 tests, all green (was 233 at session start). 3 new commits on `development` (C3a / C3b / C3c).

**Status (session 6 — 2026-05-08)**: C1 shipped end-to-end (codec inspector flags). 233 tests, all green (was 202 at session start). 3 commits on `development`.

Phase C is just starting. The codec inspector (C1) is the first piece because it has zero hardware dependency and unblocks B8 (10-bit YUV default once any clip is >8-bit) — the `MediaSlide.flags.tenBitYUV420` boolean is now the project-wide signal B8 will key off of.

The remaining Phase C items (C2 transcode action, C3 PDF import, C4 GIF/APNG detect-and-convert, C5 image-sequence detect-and-encode, C6 Keynote import, C7+ asset library / audio / subtitles) are all autonomy-friendly with no hardware exposure — Phase C should be the workhorse phase for autonomous-build cycles.

---

## What shipped in session 7 (C3)

### C3a — `PDFImporter.rasterize(...)`

- **`Services/PDFImporter.swift`** — `rasterize(pdfURL:rasterSize:destinationDirectory:) throws -> [URL]`. PDFKit-backed; opens a `PDFDocument`, walks pages, scales each page's mediaBox to fit within the caller's `rasterSize` while preserving aspect, draws into a `CGContext`-backed bitmap, writes a PNG sidecar per page. The destination directory is created on demand; per-page filenames are zero-padded (`page_001.png`, `page_012.png`, ...) so lexicographic sort matches page order at any future "Asset Library" listing.
- **Pixel target convention**: the output PNG dimensions are the *scaled-to-fit* size, not literal `rasterSize`. For a Letter PDF (612×792) at 1920×1080 raster, the PNG comes out ~834×1080 — height-limited at 1080, aspect-preserved. For a 16:9 PDF (1600×900) at 3840×2160 raster, it lands at exactly 3840×2160. The compositor still applies `ScaleMode.fit/fill/stretch` on top per cue.
- **Why scale-to-fit not scale-to-fill**: PDF page aspect varies (Letter portrait, A4 portrait, 16:9 export, 4:3 export). Stretching would distort PowerPoint→PDF→PNG decks; cropping (fill) would silently lose content. The compositor downstream is the right place to express scaling intent per cue.
- **Errors**: `PDFImportError.unreadable(URL)` for a corrupt or non-existent PDF, `.noPages(URL)` for an empty PDF, `.writeFailed(URL, underlying:)` for filesystem errors. Per-page render failures (`makeImage()` returning nil) are silently skipped — better to import 11 of 12 pages than throw mid-batch.
- 8 tests cover happy path (file count, leading-zero naming, fit aspect preserved, output × 2 pixel target on a matched-aspect page, missing-directory creation) and the `.unreadable` error.

### C3b — `MediaImporter.importSlides(from:context:)`

- **`Services/MediaImporter.swift`** — new `MediaImportContext { rasterSize: CGSize, renderRootDirectory: URL }`, new `importSlides(from urls: [URL], context: MediaImportContext?) -> [MediaSlide]` overload. PDFs route through `PDFImporter.rasterize`; non-PDFs go through the existing `mediaKind` path unchanged. Each PDF batch lands in `<renderRootDirectory>/<UUID>/page_NNN.png` so concurrent imports don't collide.
- **Backwards-compat**: `importSlides(from:)` (no context) still exists and silently drops PDFs (no place to write rasters without a context). Callers that need PDF support pass the context-aware overload. This keeps existing tests immutable and gives non-UI callers (future automation, CLI) a path that works without UI plumbing.
- **Public `MediaImporter.isPDF(_:)`** — UTType-aware PDF detection (content type → extension → fallback to lowercased extension match). Used by the importer; testable in isolation.
- 4 tests pin the contract: PDF + context → N image slides with resolvable URLs, PDF without context → empty array, non-PDF inputs unchanged across both overloads, `isPDF` recognizes `.pdf` / `.PDF` and rejects `.png` / `.mov`.

### C3c — RootView wiring

- **`Views/RootView.swift`** — drop handler and Add Media open panel both call `currentMediaImportContext()`, which builds:
  - `rasterSize = (Stage.first.width, Stage.first.height) × 2` (spec §3.10's "output × 2"); falls back to `outputWidth`/`outputHeight` if no Stage is configured.
  - `renderRootDirectory = projectBundle/Cache/Renders` when the document has a `fileURL`, else `Application Support/Simple Playback/Renders/<sessionUUID>` for untitled documents (the `sessionUUID` is `@State`-stable per window so concurrent untitled windows don't collide).
- **`ProjectBundleLayout.rendersDirectory = "Cache/Renders"`** — pinned to spec §3.17 layout.
- **`SimplePlaybackProjectDocument.makeWindowControllers`** — passes a `[weak self] in self?.fileURL` closure as `projectBundleURLProvider`. RootView reads the bundle URL on every import, so the path stays current after first-save (where `fileURL` flips from nil to the saved bundle path). Existing untitled-doc imports in the app-support fallback continue to resolve via their absolute paths in `MediaSlide.media`; a future "Bundle for Travel" command (§3.17) would migrate them into the bundle.
- **Open panel** — `.allowedContentTypes` now includes `.pdf` alongside `.image` / `.movie` / `.video`.

---

## Tests added (session 7)

| Test | What it covers |
|---|---|
| `PDFImporterTests.testRasterizeWritesOnePNGPerPage` | 3-page PDF → 3 PNG files exist on disk. |
| `PDFImporterTests.testRasterizeNamesPagesInOrderWithLeadingZeros` | `page_001.png` … `page_012.png` — zero-padded so lexicographic sort matches page order. |
| `PDFImporterTests.testRasterizeFitsWithinRasterSizePreservingAspect` | Letter (612×792) at 1920×1080 raster → height-limited at 1080, aspect ≈ 612/792 within 0.005. |
| `PDFImporterTests.testRasterizeAtOutputTimesTwoProducesExpectedPixelTarget` | 16:9 page at 3840×2160 raster lands exactly 3840×2160. |
| `PDFImporterTests.testRasterizeCreatesDestinationDirectoryIfMissing` | Two-deep target directory created on demand. |
| `PDFImporterTests.testRasterizeThrowsOnUnreadablePDF` | Bogus URL → `.unreadable` error. |
| `MediaImporterPDFTests.testRoutesPDFThroughContextAndProducesImageSlides` | 4-page PDF → 4 `.image` MediaSlides whose URLs resolve to written PNGs; titles include page numbers. |
| `MediaImporterPDFTests.testReturnsEmptyForPDFWhenContextIsAbsent` | No-context overload silently drops PDFs (back-compat for legacy callers). |
| `MediaImporterPDFTests.testNonPDFInputsAreUnaffectedByContextSignature` | Stills work the same with or without a context. |
| `MediaImporterPDFTests.testIsPDFRecognizesByExtensionAndUTType` | `.pdf` / `.PDF` recognized, `.png` / `.mov` rejected. |

Total: 243 tests, all green (was 233 at session start).

---

## Manual verification needed (session 7 deltas)

1. Save a fresh project to disk (so it has a `fileURL`). Drag a multi-page PDF into the asset library palette. The asset library should show one image slide per page, titled `<filename> — page N`. Browse into `<project.spb>/Cache/Renders/<UUID>/` in Finder; the PNGs should be there.
2. Drop a PDF into an untitled (unsaved) document. Slides appear; PNGs land in `~/Library/Application Support/Simple Playback/Renders/<sessionUUID>/<batchUUID>/`. Save the project, restart the app, reopen — slides resolve via absolute path. (Future "Bundle for Travel" task would copy them into the bundle.)
3. Use **Add Media…** (toolbar) to pick a PDF. Same result as drop.
4. Drop a Letter portrait PDF and a 16:9 landscape PDF. Each renders at the largest size that fits within Stage × 2 with aspect preserved. The compositor's `ScaleMode.fit` (default) presents them centered with bars when the Stage aspect differs from the PDF page aspect.
5. Drop a corrupt or zero-page PDF. Nothing imports; the app does not crash. (Operator feedback for failed-import is deferred to a future "import status banner" task — see C2 transcode toast pattern.)
6. Drop a PDF whose pages mix orientations (some portrait, some landscape). Each page is independently fit-into the raster; mixed-orientation decks browse correctly.

---

## What shipped in session 6 (C1)

### C1a — Pure-logic flag model + evaluator

- **`Models/MediaFlags.swift`** — `MediaFlags` (Codable / Hashable) with four booleans matching spec §3.10's transcoding-posture warnings: `longGOP`, `variableFrameRate`, `tenBitYUV420`, `untaggedColor`. `MediaFlags.none` for "no flags / not inspected", `hasAnyFlag` accessor for inspector short-circuit, `activeWarnings` returns the warning kinds in stable order (long-GOP first, untagged color last — most-to-least actionable).
- **`CodecFamily`** enum — maps a CoreMedia FourCC (`avc1`, `hvc1`, `apch`, `AVdn`, …) into an explicit family. `isLongGOPCapable` is a property of the family (true only for H.264 / HEVC). Conservative — unknown codecs default to `.other` / `false`, so we miss flags rather than false-positive on intra codecs we haven't characterized.
- **`MediaFlagsEvaluator.evaluate(...)`** — pure-logic combiner that takes the structured properties (codec family, bits per component, chroma 4:2:0 hint, color-primaries-tag presence, frame-rate-inconsistent boolean) and produces a `MediaFlags`. AVFoundation is intentionally not imported here — the adapter calls in. That split makes every rule unit-testable without committing fixture media.
- **`MediaFlagsEvaluator.warning(for:)`** — operator-facing copy. Spec §3.10 wording is preserved verbatim where the spec was prescriptive ("Long-GOP — may not scrub frame-accurately." / "Variable frame rate — will not loop seamlessly." / "10-bit 4:2:0 HEVC — limited hardware decode." / "Untagged color — treating as sRGB.").
- 25 tests cover the evaluator matrix (long-GOP true/false, VFR true/false, 10-bit 4:2:0 only on HEVC at 4:2:0 + ≥10-bit, untagged true/false, missing-bits-treated-as-8-bit), CodecFamily mapping for the common FourCCs, warning-copy contracts, `hasAnyFlag`, `activeWarnings` ordering, JSON round-trip, legacy-`{}`-decodes-to-none, and partial-JSON-defaults-to-false.

### C1b — AVFoundation adapter populates flags at import

- **`Services/MediaFlagsInspector.swift`** — `inspect(url: URL) -> MediaFlags`. Synchronous on the import thread; never throws (any inspection failure returns `.none`).
  - Codec from `CMFormatDescriptionGetMediaSubType` (FourCC → `CodecFamily`).
  - Color tagging from `kCMFormatDescriptionExtension_ColorPrimaries` presence.
  - Bit depth from `kCMFormatDescriptionExtension_BitsPerComponent` first; falls back to substring search ("Main 10" / "10-bit") on `kCMFormatDescriptionExtension_FormatName`. Documented limitation: HEVC sources that expose neither extension are not flagged 10-bit. Better than false-positive.
  - 4:2:0 chroma — for HEVC, default to true (overwhelming convention for SDR HEVC) and downgrade if `FormatName` explicitly says 4:2:2 / 4:4:4. For non-HEVC, irrelevant — the evaluator only consults chroma for HEVC.
  - VFR — `nominalFrameRate <= 0` OR derived rate from `minFrameDuration` differs from declared by >0.1%. False negatives on cleanly-muxed VFR are a known v1 limitation (a real timestamp scan is out of scope for the import path).
- **`MediaSlide.flags: MediaFlags`** — new field, populated at import in `MediaImporter.importSlides(from:)`. Round-tripped via `decodeIfPresent` so legacy projects (every project saved before this commit) decode with `flags == .none`.
- 6 adapter tests using a freshly synthesized AVAssetWriter movie at test time (H.264 → flags long-GOP, ProRes → suppresses long-GOP) plus missing-file / non-video-file safe-return tests.

### C1c — Inspector chips

- **`MediaFlagWarningChip`** in `Views/RootView.swift` — single-line yellow info chip per active flag. Yellow palette (FYI — informational metadata caveat) is deliberately distinct from the orange FPS-mismatch banner above (action recommended — transcode for a Stage-rate copy). Operators reading the inspector at a glance can tell shape problems from metadata caveats by color alone.
- Chips render below the existing FPS conformance warning in `CueInspectorView`, in `MediaFlags.activeWarnings` order. Hover help text directs the operator to the eventual right-click → Transcode-to-ProRes-422 action (C2, not yet shipped).

---

## Tests added (session 6)

| Test | What it covers |
|---|---|
| `MediaFlagsTests.testCodecFamilyIdentifiesH264FourCCs` | `avc1` / `avc3` → `.h264`. |
| `MediaFlagsTests.testCodecFamilyIdentifiesHEVCFourCCs` | `hvc1` / `hev1` / `dvh1` → `.hevc`. |
| `MediaFlagsTests.testCodecFamilyIdentifiesProResVariants` | All six ProRes FourCCs (`apco`/`apcs`/`apcn`/`apch`/`ap4h`/`ap4x`) → `.proRes`. |
| `MediaFlagsTests.testCodecFamilyHandlesIntraOnlyCodecs` | DNx / Animation / MJPEG / uncompressed FourCCs. |
| `MediaFlagsTests.testCodecFamilyDefaultsToOtherForUnknown` | Unrecognized codes default to `.other` (not `.unknown` — `.unknown` is reserved for "I haven't inspected"). |
| `MediaFlagsTests.testLongGOPCapability` | Family-level long-GOP capability per spec §3.10. |
| `MediaFlagsTests.testEvaluatorFlagsH264AsLongGOP` / `…ProResAsLongGOP` | H.264 flagged; ProRes never. |
| `MediaFlagsTests.testEvaluatorFlagsVFRWhenFrameRateInconsistent` / `…WhenFrameRateConsistent` | VFR boolean threading. |
| `MediaFlagsTests.testEvaluatorFlagsHEVCMain10AsTenBit420` | HEVC + 10-bit + 4:2:0 → flagged. |
| `MediaFlagsTests.testEvaluatorDoesNotFlag8BitHEVCAsTenBit420` | 8-bit HEVC → not flagged. |
| `MediaFlagsTests.testEvaluatorDoesNotFlag10BitHEVCInOtherChromaSamplings` | 10-bit 4:2:2 HEVC → not flagged (Apple Silicon decodes those fine). |
| `MediaFlagsTests.testEvaluatorDoesNotFlag10BitProResAsTenBit420` | 10-bit ProRes → not flagged (intra, hardware-irrelevant). |
| `MediaFlagsTests.testEvaluatorTreatsMissingBitDepthAs8Bit` | `nil` bits-per-component → never trips the 10-bit flag. |
| `MediaFlagsTests.testEvaluatorFlagsUntaggedColor` / `…DoesNotFlagTaggedColor` | Untagged-color boolean threading. |
| `MediaFlagsTests.testTenBit420PixelFormatCodesIncludesBothRanges` | `x420` (video range) and `xf20` (full range) both in the constant set. |
| `MediaFlagsTests.testHasAnyFlagFalseForCleanMedia` / `…TrueWhenAnySingleFlagSet` | `hasAnyFlag` short-circuit. |
| `MediaFlagsTests.testActiveWarningsOrderIsStable` | Inspector chip order is locked. |
| `MediaFlagsTests.testWarningStringsMatchSpec` | Spec §3.10 wording is exact (treated as a contract). |
| `MediaFlagsTests.testMediaFlagsRoundTripsThroughJSON` / `…LegacyJSONDecodesToAllFalse` / `…PartialJSONDecodesMissingFieldsAsFalse` | Codable shape + legacy decode. |
| `MediaFlagsTests.testMediaSlideLegacyJSONWithoutFlagsDecodesToNoneFlags` | Pre-C1 slides decode with `flags == .none`. |
| `MediaFlagsTests.testMediaSlideRoundTripsFlags` | New slides round-trip through encode/decode. |
| `MediaFlagsTests.testInspectorFlagsLongGOPForSynthesizedH264Movie` | AVFoundation adapter, end-to-end, flags long-GOP for an H.264 movie generated by AVAssetWriter at test time. |
| `MediaFlagsTests.testInspectorDoesNotFlagLongGOPForSynthesizedProResMovie` | Adapter does not flag long-GOP / 10-bit-4:2:0 for ProRes 422. |
| `MediaFlagsTests.testInspectorReturnsNoneForMissingFile` / `…ForNonVideoFile` | Missing files / still images return `.none` rather than throwing. |

Total: 233 tests, all green (was 202 at session start).

---

## Manual verification needed (session 6 deltas)

These need human eyeballs — autonomous tests don't drive SwiftUI inspectors.

1. Import a typical H.264 .mp4 from a phone or screen capture into a project. Open the cue inspector. The yellow `Long-GOP — may not scrub frame-accurately.` chip should appear below the existing orange FPS-mismatch warning (if the rate also disagrees with the Stage). Untagged-color chip may also appear depending on whether the source has color tags.
2. Import a ProRes 422 export from Final Cut / Compressor. The cue inspector should show **no** flag chips (ProRes is intra, color-tagged, CFR).
3. Import an HEVC Main 10 source (e.g. an iPhone HDR clip or a 10-bit graded export). The inspector should show `Long-GOP` and `10-bit 4:2:0 HEVC — limited hardware decode.`. The 10-bit flag depends on the source's format-name / bits-per-component extension; some encoders don't tag it (documented limitation — chip won't appear).
4. Import a clip you know is VFR (a screen recording, a Twitch VOD). The `Variable frame rate — will not loop seamlessly.` chip should appear. Note the v1 detection is metadata-only — cleanly-muxed VFR may still not flag.
5. Save the project, reopen it. Flags persist on disk via `MediaSlide.flags`.
6. Re-open a project saved before this session. Slides decode with `flags == .none` (no chips appear) — they re-flag only on next re-import. Documented limitation; a future "Refresh inspector flags" action could re-run the inspector across the asset library.

---

## Still deferred (session 7+)

**Phase B leftovers** (mostly hardware-bound):
- **B6 (remaining)** — REF format-mismatch detection vs Stage frame rate. Needs a Blackmagic SDK spike against newer interfaces; possible blocker.
- **B7** — DeckLink format negotiation. Has product-UX questions (mid-show re-arm flow — modal? non-modal banner?) that warrant a fresh session with options surfaced to the user.
- **B8** — 10-bit YUV 4:2:2 default — **now unblocked by C1**. Once C1's `tenBitYUV420` flag exists across all video assets, B8 can key the 10-bit conversion path on `project.slides.contains { $0.flags.tenBitYUV420 || $0.flags.bitsPerComponent >= 10 }` (the latter would need exposing in C1 too — or just driving off the flag).
- **B11** — NDI Full sender as a `TransportSink`. Independent of DeckLink. Needs the NDI SDK as a new dependency — confirm license + size in `decision_log.md` first.
- **B13** — Color pipeline (sits on top of B5+B12).
- **B9 / B15 / B10** — long tail.
- **B16** — final Phase B summary + DeckLink mock layer for tests.

**Phase C remaining** (autonomy-friendly):
- **C2** — Right-click "Transcode to ProRes 422" action. Uses `AVAssetExportSession` with `.proRes422` preset. Open product question: does transcode replace the original slide or add a sibling? (Default to sibling — non-destructive, lets the operator A/B.) Needs a non-modal progress surface. Sibling folder location now has precedent: `<bundle>/Transcoded/` matching `<bundle>/Cache/Renders/` pattern.
- **C4** — Animated GIF / APNG detect → offer convert-to-ProRes-4444. AVFoundation can't decode animated GIFs natively, so detection forces a conversion path. Decompose: "detect" first (an `animatedGIF` flag on MediaFlags? or a `MediaSlide.requiresConversion` enum?), then a separate "offer convert" UX.
- **C5** — Image-sequence detect (`name.0001.png`) → offer encode-to-ProRes-4444 via `AVAssetWriter`. Pure import-time logic + AVAssetWriter wrapper.
- **C6** — Keynote import via AppleScript → PDF → bitmaps. **Now unblocked by C3** — Keynote import is a thin shell around AppleScript that exports `.key` to PDF, then calls `PDFImporter.rasterize` with the same `MediaImportContext`. Needs the "Keynote not installed" diagnostic branch and AppleScript permission UX.
- **C7+** — Asset library, audio engine, subtitles, etc. Larger.

**Recommended next pick**: **C6 (Keynote import)** is the natural follow-up to C3 — the rasterize plumbing is in place and Keynote import collapses to AppleScript + reuse. Or **C2 (transcode action)** to close the C1 inspector-chip → action loop. C4/C5 also fit cleanly.

### Known gaps in the C3 import path

- **No operator feedback on failed imports.** A corrupt or zero-page PDF imports zero slides silently. A future "import status banner" (see C2's transcode toast pattern) should expose `PDFImportError` and per-batch counts.
- **Untitled-document portability.** Untitled docs render PDFs to `~/Library/Application Support/Simple Playback/Renders/<sessionUUID>/`. After Save As, the slides resolve via absolute path but live outside the bundle. A future "Bundle for Travel" command (spec §3.17) is what migrates them in.
- **No re-rasterize on Stage resize.** If the operator changes the Stage from 1080p to 2160p mid-project, previously-imported PDFs stay at the old 1080p × 2 raster. A future "Re-rasterize PDF imports" action (or automatic re-render on Stage change) would close the loop.
