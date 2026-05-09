# Test fixture audit (F5)

This is the F5 deliverable from the autonomous v1 build: a catalogue of every synthesized fixture in the Simple Playback test target, the synthesis pattern each one uses, and the policy that governs them.

If you are adding a test that needs binary input data, **read this file before committing a fixture**. The standing rule is below.

## Policy

The Simple Playback test target ships **zero committed binary fixtures**. Every test synthesizes its inputs at runtime — PDFs from `CGPDFContext`, tiny `.mov` files from `AVAssetWriter`, PNGs from `CGContext` bitmaps, animated GIFs / APNGs from `CGImageDestination`, malformed payloads from inline `Data([…])` literals, and so on. The synthesized files are written to `FileManager.default.temporaryDirectory`, asserted against, and removed in a `defer` block.

This policy is defended by `Scripts/regenerate-fixtures.sh`. The guard walks `Simple PlaybackTests/` and exits non-zero if any non-`.swift` file appears (with a `.DS_Store` exception). It is not wired into CI today (the runbook prohibits CI changes); run it manually before promoting a release.

The policy exists because:

- The repo can stay small and fast to clone — no binary churn in git history.
- Tests describe their inputs in code, so a reviewer reads the test and immediately sees what it depends on.
- A future maintainer who needs a different shape of fixture can copy the synthesis helper, change a parameter, and move on — no detective work to figure out where a `.mov` came from.
- Pixel-equivalence regressions against an operator-supplied source aren't on the v1 critical path; when v2 adds them, they should ship with their own per-fixture regeneration script (see "Adding a fixture if you must" below).

## Synthesis catalogue

Each row below names the synthesis pattern, its canonical implementation, and the tests that adopt it. New tests should reuse the canonical helper rather than re-implement it.

### PDF — `CGDataConsumer` + `CGPDFContext`

Pattern: build a `CGDataConsumer` over the destination URL, hand it to `CGContext(consumer:mediaBox:_:)`, then `beginPDFPage(nil)` / fill / `endPDFPage()` per page, then `closePDF()`.

| Canonical | `Simple PlaybackTests/PDFImporterTests.swift` `makeTestPDF(pages:pageSize:)` |
|---|---|
| Output  | Multi-page PDF with per-page solid-fill colours so pages aren't bitstream-identical |
| Used by | `PDFImporterTests`, `MediaImporterPDFTests` (own copy), `MediaImporterFingerprintTests` (own copy) |

### Tiny H.264 `.mov` — `AVAssetWriter` + pixel-buffer adaptor

Pattern: `AVAssetWriter` with `AVAssetWriterInput(mediaType: .video, outputSettings: [...h264, 16x16])` plus an `AVAssetWriterInputPixelBufferAdaptor`. Pull `CVPixelBuffer`s from the adaptor's `pixelBufferPool`, zero them, and append at the configured frame rate. Two frames is enough for `nominalFrameRate` / `minFrameDuration` / `formatDescriptions` to populate.

| Canonical | `Simple PlaybackTests/AVTrackLoaderTests.swift` `makeTinyH264Movie()` |
|---|---|
| Output  | 16×16 30 fps H.264 .mov, two frames, ~few KB |
| Used by | `AVTrackLoaderTests`, `MediaFlagsTests` (`makeTinyMovie` — extends with codec parameter), `MediaImporterFilmstripTests`, `FilmstripGeneratorTests`, `TranscodeServiceTests`, `TranscodeCoordinatorTests`, `ModelTests`, `ImageSequenceEncoderTests` (output-side write), `ImageSequenceEncodeCoordinatorTests` (output-side write) |

The `MediaFlagsTests.makeTinyMovie(codec:)` variant accepts an internal `SynthesizedCodec` enum so a single helper covers the H.264 / HEVC / ProRes branches the codec inspector flags. Other tests inline a copy and tweak the frame count or pixel format as needed.

### Still PNG — `CGContext` bitmap → `NSBitmapImageRep`

Pattern: `CGContext(data: nil, width:, height:, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: premultipliedLast)` to draw a fill, then `cgContext.makeImage()` → `NSBitmapImageRep(cgImage:)` → `.representation(using: .png, properties: [:])` → `.write(to: url)`.

| Canonical | `Simple PlaybackTests/MediaImporterPDFTests.swift` `makeStillPNG(size:)` |
|---|---|
| Output  | Single-frame solid-fill sRGB PNG |
| Used by | `MediaImporterPDFTests`, `MediaImporterFilmstripTests`, `MediaImporterFingerprintTests`, `MediaImporterThumbnailTests`, `MediaImporterFolderBookmarkTests`, `ThumbnailGeneratorTests` |

### Animated image (GIF / APNG) — `CGImageDestination`

Pattern: `CGImageDestinationCreateWithURL(url, UTType.gif.identifier or .png, frameCount, nil)` plus per-frame `CGImageDestinationAddImage(dest, frame, [kCGImagePropertyGIFDictionary: [delayTime: 0.1]])` then `CGImageDestinationFinalize(dest)`. Single-frame variants for the negative branch.

| Canonical | `Simple PlaybackTests/AnimatedImageInspectorTests.swift` `makeGIF(frameCount:)` / `makeAPNG(frameCount:)` |
|---|---|
| Output  | Multi-frame GIF / APNG (or single-frame for negatives) |
| Used by | `AnimatedImageInspectorTests` |

### Static JPEG / TIFF

Pattern: build an `NSImage` (often by drawing into an `NSBitmapImageRep`), pull its `tiffRepresentation`, optionally hand it to `NSBitmapImageRep(data:)` and re-emit as JPEG.

| Canonical | `Simple PlaybackTests/AnimatedImageInspectorTests.swift` `makeStaticJPEG()` |
|---|---|
| Used by | `AnimatedImageInspectorTests`, `MediaFlagsTests` (TIFF branch) |

### Empty / sentinel `Data` blobs

For tests that exercise format-detection or failure paths and don't need real-image content, the fixture is a literal `Data()`, `Data([0x00, 0x01, 0x02])`, or `Data("x".utf8)` written to a temp URL. These cover:

- `MediaImporterKeynoteTests` — empty `.key` files, exporter is faked
- `MediaImportFailureTests` — bogus PDFs, unsupported extensions, empty `.key`
- `MediaResolverTests` — fingerprintable byte streams that don't need decoder agreement
- `ProjectLockFileTests` — no fixture at all; pure-logic IO probe

### `.splayback` bundle round-trip

`Simple PlaybackTests/ModelTests.swift` round-trips a synthesized `PlayoutProject` value through the bundle codec into `temporaryDirectory.appendingPathComponent("…\(UUID()).splayback")`. The bundle layout (Show.json, Media/, Cache/, Logs/) is written by the SUT, not by a fixture. Same shape applies for autosave checkpoint round-trips.

## Adding a fixture if you must

If a future test genuinely requires a real-world fixture (an operator-supplied PowerPoint export, a malformed PDF the codec inspector should reject, a real-camera ProRes file with embedded metadata that AVAssetWriter can't reproduce), follow this checklist:

1. Place the fixture under `Simple PlaybackTests/Fixtures/<area>/<name>.<ext>` so the synthesis-only tests stay sorted from the binary-blob tests.
2. Write `Scripts/regenerate-fixtures/<name>.sh` that produces the fixture from source. The recipe must be reproducible on a stock macOS install with no manual intervention. If the source-of-truth fixture is licensed or operator-confidential, the recipe should describe the redaction step rather than commit the redacted output.
3. Update the `ALLOWED_FIXTURES` array in `Scripts/regenerate-fixtures.sh` so the guard accepts the new path.
4. Document the fixture (name, size, recipe pointer, what it asserts) here under a new "Committed fixtures" section.
5. Surface the addition in `docs/decision_log.md` with the rationale — why synthesis wouldn't work for this one.

A fixture that fails any of (1)–(4) is a regression against the policy. The reviewer should ask the test author to re-shape it as synthesis or move it under a documented exception.

## Verifying the policy

```bash
Scripts/regenerate-fixtures.sh
```

Exit 0 is green — policy intact. Exit 1 means a non-Swift file landed under the test target since the last guard run; the script lists offenders. Run before promoting a release; consider adding to a pre-commit hook in the operator's local checkout.
