#!/usr/bin/env bash
#
# regenerate-fixtures.sh — F5 fixture-policy guard for Simple Playback's test
# suite.
#
# Policy: the test suite ships ZERO committed binary fixtures. Every test
# synthesizes its inputs at runtime — see docs/test_fixtures.md for the full
# catalogue of synthesis patterns (CGPDFContext PDFs, AVAssetWriter tiny .mov
# files, CGContext bitmap PNGs, single-byte stub Data blobs).
#
# This script's job is to defend that policy. Run it from the repo root; it
# walks Simple PlaybackTests/ and prints any non-source file. Exit status:
#   0 — policy intact (only .swift sources under tests)
#   1 — at least one non-source file found; see "What to do" below.
#
# What to do if this fails:
#   1. Determine whether the file is a true fixture (referenced by a test) or
#      just stray debris (.DS_Store, IDE leftovers). Stray files should be
#      removed and added to .gitignore.
#   2. If the file is a true fixture, prefer rewriting the test to synthesize
#      it at runtime. The synthesis patterns are:
#        - PDF: CGDataConsumer + CGContext(consumer:mediaBox:) +
#          beginPDFPage / endPDFPage / closePDF. Reference:
#          Simple PlaybackTests/PDFImporterTests.swift makeTestPDF
#        - H.264 .mov: AVAssetWriter + AVAssetWriterInputPixelBufferAdaptor +
#          CVPixelBufferPool. Reference:
#          Simple PlaybackTests/AVTrackLoaderTests.swift makeTinyH264Movie
#        - PNG: CGContext bitmap → NSBitmapImageRep(cgImage:) →
#          .representation(using: .png, properties: [:]). Reference:
#          Simple PlaybackTests/MediaImporterPDFTests.swift makeStillPNG
#        - Animated GIF: CGImageDestinationCreateWithURL kUTTypeGIF +
#          CGImageDestinationAddImage with delay. Reference: none yet —
#          AnimatedImageInspectorTests synthesizes via GIF89a header bytes.
#   3. If runtime synthesis is genuinely impossible (e.g. a real-world
#      operator deck the test asserts pixel-equivalence against), commit the
#      fixture AND a per-fixture regeneration script next to it under
#      Scripts/regenerate-fixtures/<fixture-name>.sh. Then update the
#      ALLOWED_FIXTURES list below so the guard stops failing.
#
# This script does NOT regenerate anything itself — there is currently nothing
# to regenerate. It is a guard. If a future fixture lands, replace this
# section with explicit regeneration calls for that fixture.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$REPO_ROOT/Simple PlaybackTests"

if [ ! -d "$TEST_ROOT" ]; then
    echo "regenerate-fixtures.sh: cannot find Simple PlaybackTests/ at $TEST_ROOT" >&2
    exit 2
fi

# Allowed exceptions — none today. Add one path per line if a real fixture
# ships in the future. Comments (lines starting with '#') and blank lines are
# ignored.
ALLOWED_FIXTURES=()

# Find every non-Swift file under the test target. Portable to bash 3.2
# (macOS default) — no mapfile, no process substitution into arrays.
violations=""
violation_count=0
while IFS= read -r path; do
    [ -z "$path" ] && continue
    rel="${path#$REPO_ROOT/}"
    allowed=0
    for pattern in "${ALLOWED_FIXTURES[@]:+${ALLOWED_FIXTURES[@]}}"; do
        if [ "$rel" = "$pattern" ]; then
            allowed=1
            break
        fi
    done
    if [ "$allowed" -eq 0 ]; then
        violations="$violations$rel"$'\n'
        violation_count=$((violation_count + 1))
    fi
done < <(find "$TEST_ROOT" -type f ! -name "*.swift" ! -name ".DS_Store")

if [ "$violation_count" -eq 0 ]; then
    echo "regenerate-fixtures.sh: policy intact — 0 non-Swift files under Simple PlaybackTests/."
    echo "regenerate-fixtures.sh: see docs/test_fixtures.md for the inline-synthesis catalogue."
    exit 0
fi

echo "regenerate-fixtures.sh: found $violation_count non-Swift file(s) under Simple PlaybackTests/:" >&2
printf '%s' "$violations" | while IFS= read -r path; do
    [ -z "$path" ] && continue
    echo "  - $path" >&2
done
echo >&2
echo "regenerate-fixtures.sh: this violates the synthesis-only fixture policy." >&2
echo "regenerate-fixtures.sh: see the header comment of this script for next steps." >&2
exit 1
