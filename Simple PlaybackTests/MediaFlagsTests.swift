import Foundation
import XCTest
@testable import Simple_Playback

final class MediaFlagsTests: XCTestCase {

    // MARK: - CodecFamily mapping

    func testCodecFamilyIdentifiesH264FourCCs() {
        XCTAssertEqual(CodecFamily.from(fourCC: "avc1"), .h264)
        XCTAssertEqual(CodecFamily.from(fourCC: "avc3"), .h264)
    }

    func testCodecFamilyIdentifiesHEVCFourCCs() {
        XCTAssertEqual(CodecFamily.from(fourCC: "hvc1"), .hevc)
        XCTAssertEqual(CodecFamily.from(fourCC: "hev1"), .hevc)
        XCTAssertEqual(CodecFamily.from(fourCC: "dvh1"), .hevc, "Dolby Vision HEVC variant")
    }

    func testCodecFamilyIdentifiesProResVariants() {
        // Proxy / LT / 422 / HQ / 4444 / 4444 XQ
        for code in ["apco", "apcs", "apcn", "apch", "ap4h", "ap4x"] {
            XCTAssertEqual(CodecFamily.from(fourCC: code), .proRes, "Expected \(code) → ProRes")
        }
    }

    func testCodecFamilyHandlesIntraOnlyCodecs() {
        XCTAssertEqual(CodecFamily.from(fourCC: "AVdn"), .dnx)
        XCTAssertEqual(CodecFamily.from(fourCC: "rle "), .animation)
        XCTAssertEqual(CodecFamily.from(fourCC: "jpeg"), .mjpeg)
        XCTAssertEqual(CodecFamily.from(fourCC: "v210"), .uncompressed)
    }

    func testCodecFamilyDefaultsToOtherForUnknown() {
        XCTAssertEqual(CodecFamily.from(fourCC: "wxyz"), .other)
    }

    func testLongGOPCapability() {
        XCTAssertTrue(CodecFamily.h264.isLongGOPCapable)
        XCTAssertTrue(CodecFamily.hevc.isLongGOPCapable)
        XCTAssertFalse(CodecFamily.proRes.isLongGOPCapable,
                       "ProRes is intra-only — never flagged long-GOP.")
        XCTAssertFalse(CodecFamily.dnx.isLongGOPCapable)
        XCTAssertFalse(CodecFamily.animation.isLongGOPCapable)
        XCTAssertFalse(CodecFamily.mjpeg.isLongGOPCapable)
        XCTAssertFalse(CodecFamily.uncompressed.isLongGOPCapable)
        XCTAssertFalse(CodecFamily.other.isLongGOPCapable)
        XCTAssertFalse(CodecFamily.unknown.isLongGOPCapable,
                       "Unknown is conservative — better to miss a flag than false-positive.")
    }

    // MARK: - Evaluator: long-GOP

    func testEvaluatorFlagsH264AsLongGOP() {
        let flags = MediaFlagsEvaluator.evaluate(
            codec: .h264,
            bitsPerComponent: 8,
            chromaSubsampling420: true,
            hasColorPrimariesTag: true,
            frameRateInconsistent: false
        )
        XCTAssertTrue(flags.longGOP)
    }

    func testEvaluatorDoesNotFlagProResAsLongGOP() {
        let flags = MediaFlagsEvaluator.evaluate(
            codec: .proRes,
            bitsPerComponent: 10,
            chromaSubsampling420: false,
            hasColorPrimariesTag: true,
            frameRateInconsistent: false
        )
        XCTAssertFalse(flags.longGOP, "ProRes is intra-only, even at 10-bit.")
    }

    // MARK: - Evaluator: VFR

    func testEvaluatorFlagsVFRWhenFrameRateInconsistent() {
        let flags = MediaFlagsEvaluator.evaluate(
            codec: .h264,
            bitsPerComponent: 8,
            chromaSubsampling420: true,
            hasColorPrimariesTag: true,
            frameRateInconsistent: true
        )
        XCTAssertTrue(flags.variableFrameRate)
    }

    func testEvaluatorDoesNotFlagVFRWhenFrameRateConsistent() {
        let flags = MediaFlagsEvaluator.evaluate(
            codec: .h264,
            bitsPerComponent: 8,
            chromaSubsampling420: true,
            hasColorPrimariesTag: true,
            frameRateInconsistent: false
        )
        XCTAssertFalse(flags.variableFrameRate)
    }

    // MARK: - Evaluator: 10-bit 4:2:0

    func testEvaluatorFlagsHEVCMain10AsTenBit420() {
        let flags = MediaFlagsEvaluator.evaluate(
            codec: .hevc,
            bitsPerComponent: 10,
            chromaSubsampling420: true,
            hasColorPrimariesTag: true,
            frameRateInconsistent: false
        )
        XCTAssertTrue(flags.tenBitYUV420)
    }

    func testEvaluatorDoesNotFlag8BitHEVCAsTenBit420() {
        let flags = MediaFlagsEvaluator.evaluate(
            codec: .hevc,
            bitsPerComponent: 8,
            chromaSubsampling420: true,
            hasColorPrimariesTag: true,
            frameRateInconsistent: false
        )
        XCTAssertFalse(flags.tenBitYUV420)
    }

    func testEvaluatorDoesNotFlag10BitHEVCInOtherChromaSamplings() {
        // 10-bit 4:2:2 HEVC is not the troublesome shape — Apple Silicon hardware decodes it.
        // Only the 4:2:0 + 10-bit intersection is the spec's "limited hardware decode" case.
        let flags = MediaFlagsEvaluator.evaluate(
            codec: .hevc,
            bitsPerComponent: 10,
            chromaSubsampling420: false,
            hasColorPrimariesTag: true,
            frameRateInconsistent: false
        )
        XCTAssertFalse(flags.tenBitYUV420)
    }

    func testEvaluatorDoesNotFlag10BitProResAsTenBit420() {
        let flags = MediaFlagsEvaluator.evaluate(
            codec: .proRes,
            bitsPerComponent: 10,
            chromaSubsampling420: true,
            hasColorPrimariesTag: true,
            frameRateInconsistent: false
        )
        XCTAssertFalse(flags.tenBitYUV420,
                       "10-bit 4:2:0 is an HEVC-specific decode-cost shape; ProRes 10-bit is fine.")
    }

    func testEvaluatorTreatsMissingBitDepthAs8Bit() {
        // ProRes / uncompressed don't always expose `bitsPerComponent` in their format
        // description extensions. Default to 8-bit so the absence of metadata never trips
        // the 10-bit flag.
        let flags = MediaFlagsEvaluator.evaluate(
            codec: .hevc,
            bitsPerComponent: nil,
            chromaSubsampling420: true,
            hasColorPrimariesTag: true,
            frameRateInconsistent: false
        )
        XCTAssertFalse(flags.tenBitYUV420)
    }

    // MARK: - Evaluator: untagged color

    func testEvaluatorFlagsUntaggedColor() {
        let flags = MediaFlagsEvaluator.evaluate(
            codec: .h264,
            bitsPerComponent: 8,
            chromaSubsampling420: true,
            hasColorPrimariesTag: false,
            frameRateInconsistent: false
        )
        XCTAssertTrue(flags.untaggedColor)
    }

    func testEvaluatorDoesNotFlagTaggedColor() {
        let flags = MediaFlagsEvaluator.evaluate(
            codec: .h264,
            bitsPerComponent: 8,
            chromaSubsampling420: true,
            hasColorPrimariesTag: true,
            frameRateInconsistent: false
        )
        XCTAssertFalse(flags.untaggedColor)
    }

    // MARK: - Pixel-format constants

    func testTenBit420PixelFormatCodesIncludesBothRanges() {
        // x420 / xf20 are the two 10-bit 4:2:0 biplanar pixel formats AVFoundation produces
        // for HEVC Main 10. Locking the constants prevents a future bug where someone
        // narrows this set to "video range only" and silently misses the full-range variant.
        XCTAssertTrue(MediaFlagsEvaluator.tenBit420PixelFormatCodes.contains("x420"))
        XCTAssertTrue(MediaFlagsEvaluator.tenBit420PixelFormatCodes.contains("xf20"))
    }

    // MARK: - hasAnyFlag / activeWarnings

    func testHasAnyFlagFalseForCleanMedia() {
        XCTAssertFalse(MediaFlags.none.hasAnyFlag)
        XCTAssertEqual(MediaFlags.none.activeWarnings, [])
    }

    func testHasAnyFlagTrueWhenAnySingleFlagSet() {
        XCTAssertTrue(MediaFlags(longGOP: true).hasAnyFlag)
        XCTAssertTrue(MediaFlags(variableFrameRate: true).hasAnyFlag)
        XCTAssertTrue(MediaFlags(tenBitYUV420: true).hasAnyFlag)
        XCTAssertTrue(MediaFlags(untaggedColor: true).hasAnyFlag)
    }

    func testActiveWarningsOrderIsStable() {
        let allOn = MediaFlags(
            longGOP: true,
            variableFrameRate: true,
            tenBitYUV420: true,
            untaggedColor: true
        )
        XCTAssertEqual(allOn.activeWarnings,
                       [.longGOP, .variableFrameRate, .tenBitYUV420, .untaggedColor],
                       "Inspector renders warnings in this fixed order.")
    }

    // MARK: - Warning copy

    func testWarningStringsMatchSpec() {
        // Spec §3.10 wording is exact; treat it as a contract.
        XCTAssertEqual(MediaFlagsEvaluator.warning(for: .longGOP),
                       "Long-GOP — may not scrub frame-accurately.")
        XCTAssertEqual(MediaFlagsEvaluator.warning(for: .variableFrameRate),
                       "Variable frame rate — will not loop seamlessly.")
        XCTAssertEqual(MediaFlagsEvaluator.warning(for: .tenBitYUV420),
                       "10-bit 4:2:0 HEVC — limited hardware decode.")
        XCTAssertEqual(MediaFlagsEvaluator.warning(for: .untaggedColor),
                       "Untagged color — treating as sRGB.")
    }

    // MARK: - Codable

    func testMediaFlagsRoundTripsThroughJSON() throws {
        let original = MediaFlags(
            longGOP: true,
            variableFrameRate: false,
            tenBitYUV420: true,
            untaggedColor: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MediaFlags.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMediaFlagsLegacyJSONDecodesToAllFalse() throws {
        // A pre-C1 project saved before MediaFlags existed didn't write any of these fields.
        // The decoder must tolerate their absence — projects on disk must keep opening cleanly.
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MediaFlags.self, from: json)
        XCTAssertEqual(decoded, .none)
    }

    func testMediaFlagsPartialJSONDecodesMissingFieldsAsFalse() throws {
        let json = #"{"longGOP": true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MediaFlags.self, from: json)
        XCTAssertTrue(decoded.longGOP)
        XCTAssertFalse(decoded.variableFrameRate)
        XCTAssertFalse(decoded.tenBitYUV420)
        XCTAssertFalse(decoded.untaggedColor)
    }
}
