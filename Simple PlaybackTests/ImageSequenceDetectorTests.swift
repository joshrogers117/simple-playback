import Foundation
import XCTest
@testable import Simple_Playback

/// C5a — `ImageSequenceDetector` pure-logic. The detector groups inputs into
/// sequences vs. leftovers without touching the filesystem (URLs only). Tests pin the
/// regex/parser semantics, ordering invariants, and the leftover behavior so the C5b
/// encode side has a stable contract to build against.
final class ImageSequenceDetectorTests: XCTestCase {

    // MARK: - parse

    func testParseAcceptsThreeDigitCounter() {
        let parsed = ImageSequenceDetector.parse(url: URL(fileURLWithPath: "/tmp/shot.001.png"))
        XCTAssertEqual(parsed?.baseName, "shot")
        XCTAssertEqual(parsed?.counter, 1)
        XCTAssertEqual(parsed?.padWidth, 3)
        XCTAssertEqual(parsed?.ext, "png")
    }

    func testParseAcceptsFourDigitCounter() {
        let parsed = ImageSequenceDetector.parse(url: URL(fileURLWithPath: "/tmp/shot.0042.exr"))
        XCTAssertEqual(parsed?.baseName, "shot")
        XCTAssertEqual(parsed?.counter, 42)
        XCTAssertEqual(parsed?.padWidth, 4)
        XCTAssertEqual(parsed?.ext, "exr")
    }

    func testParseRejectsTwoDigitCounter() {
        // Avoid false-positives like "v1.2.png" — operators don't ship 2-digit counters.
        XCTAssertNil(ImageSequenceDetector.parse(url: URL(fileURLWithPath: "/tmp/shot.42.png")))
    }

    func testParseRejectsFiveDigitCounter() {
        XCTAssertNil(ImageSequenceDetector.parse(url: URL(fileURLWithPath: "/tmp/shot.12345.png")))
    }

    func testParseRejectsUnrecognizedExtension() {
        XCTAssertNil(ImageSequenceDetector.parse(url: URL(fileURLWithPath: "/tmp/shot.001.mov")))
        XCTAssertNil(ImageSequenceDetector.parse(url: URL(fileURLWithPath: "/tmp/shot.001.heic")))
    }

    func testParseAcceptsRecognizedExtensions() {
        for ext in ["png", "jpg", "jpeg", "tiff", "tif", "exr"] {
            XCTAssertNotNil(
                ImageSequenceDetector.parse(url: URL(fileURLWithPath: "/tmp/shot.001.\(ext)")),
                "Expected `\(ext)` to be a recognized image-sequence extension."
            )
        }
    }

    func testParseIsCaseInsensitiveOnExtension() {
        XCTAssertNotNil(ImageSequenceDetector.parse(url: URL(fileURLWithPath: "/tmp/shot.001.PNG")))
        XCTAssertEqual(ImageSequenceDetector.parse(url: URL(fileURLWithPath: "/tmp/shot.001.PNG"))?.ext, "png")
    }

    func testParseRejectsMissingCounter() {
        XCTAssertNil(ImageSequenceDetector.parse(url: URL(fileURLWithPath: "/tmp/shot.png")))
    }

    func testParseRejectsNonNumericCounter() {
        XCTAssertNil(ImageSequenceDetector.parse(url: URL(fileURLWithPath: "/tmp/shot.abc.png")))
    }

    func testParseSupportsMultiDotBaseNames() {
        // Operators name files with multiple dots ("vfx.shot.0001.png"). The counter is
        // the rightmost segment — the rest is the baseName.
        let parsed = ImageSequenceDetector.parse(url: URL(fileURLWithPath: "/tmp/vfx.shot.0001.png"))
        XCTAssertEqual(parsed?.baseName, "vfx.shot")
        XCTAssertEqual(parsed?.counter, 1)
    }

    // MARK: - detect: empty / zero-sequence

    func testDetectEmptyInputYieldsEmptyResult() {
        XCTAssertEqual(ImageSequenceDetector.detect(in: []), .empty)
    }

    func testSingleFrameWithCounterIsLeftoverNotSequence() {
        // One name.0001.png with no siblings is just a still — not a sequence.
        let url = URL(fileURLWithPath: "/tmp/shot.0001.png")
        let result = ImageSequenceDetector.detect(in: [url])
        XCTAssertEqual(result.sequences, [])
        XCTAssertEqual(result.leftovers, [url])
    }

    // MARK: - detect: happy path

    func testDetectsSimpleSequence() {
        let urls = [
            URL(fileURLWithPath: "/tmp/shot.0001.png"),
            URL(fileURLWithPath: "/tmp/shot.0002.png"),
            URL(fileURLWithPath: "/tmp/shot.0003.png")
        ]
        let result = ImageSequenceDetector.detect(in: urls)
        XCTAssertEqual(result.sequences.count, 1)
        XCTAssertEqual(result.sequences.first?.baseName, "shot")
        XCTAssertEqual(result.sequences.first?.fileExtension, "png")
        XCTAssertEqual(result.sequences.first?.frameURLs, urls)
        XCTAssertEqual(result.sequences.first?.counterPadWidth, 4)
        XCTAssertEqual(result.leftovers, [])
    }

    func testDetectSortsFramesByCounter() {
        let urls = [
            URL(fileURLWithPath: "/tmp/shot.0003.png"),
            URL(fileURLWithPath: "/tmp/shot.0001.png"),
            URL(fileURLWithPath: "/tmp/shot.0002.png")
        ]
        let result = ImageSequenceDetector.detect(in: urls)
        XCTAssertEqual(
            result.sequences.first?.frameURLs.map { $0.lastPathComponent },
            ["shot.0001.png", "shot.0002.png", "shot.0003.png"]
        )
    }

    func testDetectAllowsGapsInCounter() {
        // Operators may export a non-contiguous selection (1, 2, 5, 10). Still a sequence.
        let urls = [
            URL(fileURLWithPath: "/tmp/shot.0001.png"),
            URL(fileURLWithPath: "/tmp/shot.0002.png"),
            URL(fileURLWithPath: "/tmp/shot.0005.png"),
            URL(fileURLWithPath: "/tmp/shot.0010.png")
        ]
        let result = ImageSequenceDetector.detect(in: urls)
        XCTAssertEqual(result.sequences.count, 1)
        XCTAssertEqual(result.sequences.first?.frameURLs.count, 4)
    }

    // MARK: - detect: separation

    func testDetectSeparatesSequencesFromSingletons() {
        let urls = [
            URL(fileURLWithPath: "/tmp/shot.0001.png"),
            URL(fileURLWithPath: "/tmp/shot.0002.png"),
            URL(fileURLWithPath: "/tmp/logo.png"),
            URL(fileURLWithPath: "/tmp/intro.mov")
        ]
        let result = ImageSequenceDetector.detect(in: urls)
        XCTAssertEqual(result.sequences.count, 1)
        XCTAssertEqual(result.leftovers.map(\.lastPathComponent), ["logo.png", "intro.mov"],
                       "Leftovers preserve original drop order.")
    }

    func testDetectSeparatesMultipleSequencesByName() {
        let urls = [
            URL(fileURLWithPath: "/tmp/intro.0001.png"),
            URL(fileURLWithPath: "/tmp/intro.0002.png"),
            URL(fileURLWithPath: "/tmp/outro.0001.png"),
            URL(fileURLWithPath: "/tmp/outro.0002.png")
        ]
        let result = ImageSequenceDetector.detect(in: urls)
        XCTAssertEqual(result.sequences.count, 2)
        // Sorted alphabetically for deterministic test output.
        XCTAssertEqual(result.sequences.map(\.baseName), ["intro", "outro"])
    }

    func testDetectSeparatesSequencesByExtension() {
        // Same baseName but different extension is two distinct sequences.
        let urls = [
            URL(fileURLWithPath: "/tmp/shot.0001.png"),
            URL(fileURLWithPath: "/tmp/shot.0002.png"),
            URL(fileURLWithPath: "/tmp/shot.0001.exr"),
            URL(fileURLWithPath: "/tmp/shot.0002.exr")
        ]
        let result = ImageSequenceDetector.detect(in: urls)
        XCTAssertEqual(result.sequences.count, 2)
        XCTAssertEqual(Set(result.sequences.map(\.fileExtension)), ["png", "exr"])
    }

    func testDetectSeparatesSequencesByPadWidth() {
        // Mixing 3-digit and 4-digit counters is unusual but possible — a sequence with
        // <1000 frames vs. one with ≥1000. Treated as separate sequences so output
        // numbering stays consistent for each.
        let urls = [
            URL(fileURLWithPath: "/tmp/shot.001.png"),
            URL(fileURLWithPath: "/tmp/shot.002.png"),
            URL(fileURLWithPath: "/tmp/shot.0001.png"),
            URL(fileURLWithPath: "/tmp/shot.0002.png")
        ]
        let result = ImageSequenceDetector.detect(in: urls)
        XCTAssertEqual(result.sequences.count, 2)
        XCTAssertEqual(Set(result.sequences.map(\.counterPadWidth)), [3, 4])
    }

    // MARK: - detect: edge cases

    func testDetectIgnoresUnrecognizedExtensions() {
        let urls = [
            URL(fileURLWithPath: "/tmp/take.0001.heic"),
            URL(fileURLWithPath: "/tmp/take.0002.heic")
        ]
        let result = ImageSequenceDetector.detect(in: urls)
        XCTAssertEqual(result.sequences, [])
        XCTAssertEqual(result.leftovers, urls,
                       "Unrecognized extensions never become sequences — operators get them as leftovers.")
    }
}
