import AVFoundation
import CoreVideo
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

    func testActiveWarningsOrderIncludesAnimatedImageLast() {
        // animatedImage is orthogonal to the four codec-inspector flags (it only sets on
        // `.image` slides; the other four only on `.video`). When co-occurring (theoretical;
        // the importer never produces both today), animatedImage trails the four video flags.
        let allOn = MediaFlags(
            longGOP: true,
            variableFrameRate: true,
            tenBitYUV420: true,
            untaggedColor: true,
            animatedImage: true
        )
        XCTAssertEqual(allOn.activeWarnings,
                       [.longGOP, .variableFrameRate, .tenBitYUV420, .untaggedColor, .animatedImage])
    }

    func testActiveWarningsForAnimatedImageOnlyContainsAnimatedImage() {
        let flags = MediaFlags(animatedImage: true)
        XCTAssertEqual(flags.activeWarnings, [.animatedImage])
    }

    func testHasAnyFlagTrueWhenAnimatedImageSet() {
        XCTAssertTrue(MediaFlags(animatedImage: true).hasAnyFlag)
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
        XCTAssertEqual(MediaFlagsEvaluator.warning(for: .animatedImage),
                       "Animated GIF / APNG — first frame only; transcode to ProRes 4444 for full motion.")
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
        XCTAssertFalse(decoded.animatedImage)
    }

    func testMediaFlagsRoundTripsAnimatedImageFlag() throws {
        let original = MediaFlags(animatedImage: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MediaFlags.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.animatedImage)
    }

    func testMediaFlagsLegacyJSONWithFourFlagsDecodesAnimatedImageAsFalse() throws {
        // A pre-C4 project (post-C1, pre-C4) wrote the four codec-inspector flags but no
        // `animatedImage`. The decoder must default the new field to false.
        let json = #"{"longGOP": true, "variableFrameRate": false, "tenBitYUV420": false, "untaggedColor": true}"#
            .data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MediaFlags.self, from: json)
        XCTAssertTrue(decoded.longGOP)
        XCTAssertTrue(decoded.untaggedColor)
        XCTAssertFalse(decoded.animatedImage)
    }

    // MARK: - MediaSlide persistence

    func testMediaSlideLegacyJSONWithoutFlagsDecodesToNoneFlags() throws {
        // A v1/v2 project saved before C1 had no `flags` field. Slides on disk must keep
        // opening cleanly — the decoder defaults to `.none`.
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "title": "old clip",
          "mediaKind": "video",
          "media": { "originalPath": "/tmp/missing.mov" }
        }
        """.data(using: .utf8)!
        let slide = try JSONDecoder().decode(MediaSlide.self, from: json)
        XCTAssertEqual(slide.flags, .none,
                       "Pre-C1 slide must decode with flags == .none, never a synthesized default.")
    }

    func testMediaSlideRoundTripsFlags() throws {
        let url = URL(fileURLWithPath: "/tmp/clip.mov")
        var slide = MediaSlide(
            url: url,
            mediaKind: .video,
            nativeFrameRate: 29.97,
            flags: MediaFlags(longGOP: true, variableFrameRate: false, tenBitYUV420: true, untaggedColor: false)
        )
        slide.title = "round trip"

        let data = try JSONEncoder().encode(slide)
        let decoded = try JSONDecoder().decode(MediaSlide.self, from: data)
        XCTAssertEqual(decoded.flags.longGOP, true)
        XCTAssertEqual(decoded.flags.tenBitYUV420, true)
        XCTAssertFalse(decoded.flags.variableFrameRate)
        XCTAssertFalse(decoded.flags.untaggedColor)
    }

    // MARK: - AVFoundation adapter (synthesized assets)

    /// The adapter is a thin glue layer; we exercise it against a freshly synthesized H.264
    /// movie to confirm long-GOP detection and the codable plumbing. Detailed branch
    /// coverage of the evaluator stays in the pure-logic tests above — those don't depend
    /// on AVFoundation behavior.
    func testInspectorFlagsLongGOPForSynthesizedH264Movie() throws {
        let url = try makeTinyMovie(codec: .h264)
        defer { try? FileManager.default.removeItem(at: url) }

        let flags = MediaFlagsInspector.inspect(url: url)
        XCTAssertTrue(flags.longGOP, "An H.264 .mov should flag long-GOP scrubbing.")
    }

    func testInspectorDoesNotFlagLongGOPForSynthesizedProResMovie() throws {
        let url = try makeTinyMovie(codec: .proRes422)
        defer { try? FileManager.default.removeItem(at: url) }

        let flags = MediaFlagsInspector.inspect(url: url)
        XCTAssertFalse(flags.longGOP, "ProRes is intra-only; never flagged long-GOP.")
        XCTAssertFalse(flags.tenBitYUV420, "ProRes 422 is not the spec's 10-bit 4:2:0 HEVC shape.")
    }

    func testInspectorReturnsNoneForMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).mov")
        XCTAssertEqual(MediaFlagsInspector.inspect(url: url), .none)
    }

    func testInspectorReturnsNoneForNonVideoFile() throws {
        // A still image has no video track; the inspector should bail with .none rather
        // than crash. We synthesize a tiny PNG via NSImage to avoid committing a fixture.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flagless-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.black.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 4, height: 4))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            XCTFail("Could not synthesize PNG.")
            return
        }
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(MediaFlagsInspector.inspect(url: url), .none)
    }

    // MARK: - Movie synthesis helper

    private enum SynthesizedCodec {
        case h264
        case proRes422

        var avCodecType: AVVideoCodecType {
            switch self {
            case .h264: return .h264
            case .proRes422: return .proRes422
            }
        }
    }

    private func makeTinyMovie(codec: SynthesizedCodec) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flags-\(UUID().uuidString).mov")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: codec.avCodecType,
                AVVideoWidthKey: 16,
                AVVideoHeightKey: 16
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16
            ]
        )

        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            XCTFail("Pixel buffer pool unavailable for codec \(codec).")
            return url
        }

        // Write 2 frames so the movie has a usable nominalFrameRate / minFrameDuration.
        for frameIndex in 0..<2 {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else {
                XCTFail("Pixel buffer alloc failed.")
                continue
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, 0, CVPixelBufferGetDataSize(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            while !input.isReadyForMoreMediaData {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: 30)
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: pts))
        }
        input.markAsFinished()

        let finished = expectation(description: "Writer finished")
        writer.finishWriting { finished.fulfill() }
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(writer.status, .completed, "Writer failed: \(writer.error?.localizedDescription ?? "nil")")
        if let error = writer.error { throw error }
        return url
    }
}
