# Phase C — Media pipeline — Summary

**Status (session 6 — 2026-05-08)**: C1 shipped end-to-end (codec inspector flags). 233 tests, all green (was 202 at session start). 3 commits on `development`.

Phase C is just starting. The codec inspector (C1) is the first piece because it has zero hardware dependency and unblocks B8 (10-bit YUV default once any clip is >8-bit) — the `MediaSlide.flags.tenBitYUV420` boolean is now the project-wide signal B8 will key off of.

The remaining Phase C items (C2 transcode action, C3 PDF import, C4 GIF/APNG detect-and-convert, C5 image-sequence detect-and-encode, C6 Keynote import, C7+ asset library / audio / subtitles) are all autonomy-friendly with no hardware exposure — Phase C should be the workhorse phase for autonomous-build cycles.

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
- **C2** — Right-click "Transcode to ProRes 422" action. Uses `AVAssetExportSession` with `.proRes422` preset. Open product question: does transcode replace the original slide or add a sibling? (Default to sibling — non-destructive, lets the operator A/B.) Needs a non-modal progress surface.
- **C3** — PDF import via PDFKit → bitmap-per-page at output × 2. Needs a decision on where the rendered PNGs live (project bundle vs sidecar vs temp). Recommend project-bundle (`Bundle/Imports/<assetID>/page_*.png`) for venue portability.
- **C4** — Animated GIF / APNG detect → offer convert-to-ProRes-4444. AVFoundation can't decode animated GIFs natively, so detection forces a conversion path. Decompose: "detect" first (an `animatedGIF` flag on MediaFlags? or a `MediaSlide.requiresConversion` enum?), then a separate "offer convert" UX.
- **C5** — Image-sequence detect (`name.0001.png`) → offer encode-to-ProRes-4444 via `AVAssetWriter`. Pure import-time logic + AVAssetWriter wrapper.
- **C6** — Keynote import via AppleScript → PDF → bitmaps. Needs the C3 PDF-rasterize path first.
- **C7+** — Asset library, audio engine, subtitles, etc. Larger.

**Recommended next pick**: **C2 (transcode action)** is the natural follow-up to C1 — the inspector chips today direct operators to a right-click action that doesn't exist yet. Or **C3 (PDF import)** if you want a wholly contained slice of work that doesn't have the "where do transcoded files live?" decision.
