import AVFoundation
import CoreMedia
import XCTest
@testable import Simple_Playback

/// Pin tests for the shared `AVTrackLoader` async-bridge helper. The
/// behavior is exercised indirectly through `MediaImporter` and
/// `MediaFlagsInspector`, but a focused contract test makes the bundle
/// shape (`AVTrackInspection`) and the asset/track audio pair explicit
/// for future readers.
final class AVTrackLoaderTests: XCTestCase {

    func testVideoInspectionReturnsNilForMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/avtrackloader-missing-\(UUID().uuidString).mov")
        XCTAssertNil(AVTrackLoader.loadFirstVideoTrackInspection(url: url))
    }

    func testVideoInspectionReturnsNilForNonVideoFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("avtrackloader-\(UUID().uuidString).png")
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

        XCTAssertNil(AVTrackLoader.loadFirstVideoTrackInspection(url: url))
    }

    func testVideoInspectionPopulatesPropertiesForSynthesizedMovie() throws {
        let url = try makeTinyH264Movie()
        defer { try? FileManager.default.removeItem(at: url) }

        guard let inspection = AVTrackLoader.loadFirstVideoTrackInspection(url: url) else {
            XCTFail("Expected an inspection bundle for a valid H.264 movie.")
            return
        }
        XCTAssertGreaterThan(inspection.nominalFrameRate, 0,
                             "AVF should report a positive nominal frame rate for a CFR mov.")
        XCTAssertGreaterThan(inspection.formatDescriptions.count, 0,
                             "Every video track has at least one CMFormatDescription.")
        XCTAssertTrue(inspection.minFrameDuration.isValid,
                      "minFrameDuration is the AVF-derived inter-frame gap and must be valid.")
    }

    func testAudioLoaderReturnsNilForMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/avtrackloader-noaudio-\(UUID().uuidString).mov")
        XCTAssertNil(AVTrackLoader.loadFirstAudioTrack(url: url))
    }

    func testAudioLoaderReturnsNilForVideoOnlyMovie() throws {
        let url = try makeTinyH264Movie()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(AVTrackLoader.loadFirstAudioTrack(url: url),
                     "A video-only mov has no audio track; loader returns nil rather than throwing.")
    }

    // MARK: - Movie synthesis helper

    /// Same shape as `MediaFlagsTests.makeTinyMovie` — synthesized 16x16
    /// 30 fps H.264 .mov with two frames so the track has a defined
    /// nominalFrameRate / minFrameDuration / formatDescriptions.
    private func makeTinyH264Movie() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("avtrackloader-\(UUID().uuidString).mov")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
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
            XCTFail("Pixel buffer pool unavailable.")
            return url
        }
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
