import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import XCTest
@testable import Simple_Playback

/// C2a — TranscodeService pure logic + TranscodeJob (AVAssetExportSession wrapper).
/// The end-to-end transcode test synthesizes a tiny H.264 movie at runtime via
/// AVAssetWriter (mirroring the MediaFlagsTests pattern) so no fixture media is
/// required.
final class TranscodeServiceTests: XCTestCase {

    // MARK: - Pure-logic helpers

    func testProRes422PresetMapsToAVConstant() {
        XCTAssertEqual(TranscodePreset.proRes422.avPresetName, AVAssetExportPresetAppleProRes422LPCM)
        XCTAssertEqual(TranscodePreset.proRes422.fileExtension, "mov")
        XCTAssertEqual(TranscodePreset.proRes422.avFileType, .mov)
    }

    func testProRes4444PresetMapsToAVConstant() {
        XCTAssertEqual(TranscodePreset.proRes4444.avPresetName, AVAssetExportPresetAppleProRes4444LPCM)
        XCTAssertEqual(TranscodePreset.proRes4444.fileExtension, "mov")
        XCTAssertEqual(TranscodePreset.proRes4444.avFileType, .mov)
    }

    func testSiblingTitleAppendsPresetLabel() {
        XCTAssertEqual(
            TranscodeService.siblingTitle(originalTitle: "Keynote", preset: .proRes422),
            "Keynote (ProRes 422)"
        )
        XCTAssertEqual(
            TranscodeService.siblingTitle(originalTitle: "Drone shot", preset: .proRes4444),
            "Drone shot (ProRes 4444)"
        )
    }

    func testDestinationFilenameUsesUUIDAndPresetExtension() {
        let filename = TranscodeService.destinationFilename(preset: .proRes422)
        XCTAssertTrue(filename.hasSuffix(".mov"))
        // Strip the ".mov" — the remaining stem must be a valid UUID. UUIDs in Swift are
        // 36 chars (8-4-4-4-12 plus four dashes). The expectation pins both length and
        // that two consecutive calls don't collide.
        let stem = (filename as NSString).deletingPathExtension
        XCTAssertNotNil(UUID(uuidString: stem), "destination stem should be a UUID, got \(stem)")
        let other = TranscodeService.destinationFilename(preset: .proRes422)
        XCTAssertNotEqual(filename, other, "concurrent transcodes should never collide on filename")
    }

    func testCanTranscodeRequiresVideoSlideWithResolvableURL() throws {
        let movie = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanTranscode-\(UUID().uuidString).mov")
        try Data().write(to: movie)
        defer { try? FileManager.default.removeItem(at: movie) }

        let video = MediaSlide(url: movie, mediaKind: .video)
        XCTAssertTrue(TranscodeService.canTranscode(slide: video))

        // Stills are excluded — no point transcoding a PNG to ProRes.
        let still = MediaSlide(url: movie, mediaKind: .image)
        XCTAssertFalse(TranscodeService.canTranscode(slide: still))

        // A video slide whose underlying URL no longer resolves should not be offered the
        // action — the operator's feedback for missing media is the asset-relink workflow
        // (C9), not the transcode menu.
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).mov")
        let unresolvable = MediaSlide(url: missing, mediaKind: .video)
        XCTAssertFalse(TranscodeService.canTranscode(slide: unresolvable))
    }

    // C4 widening: animated GIF / APNG slides arrive as `.image` but with
    // `flags.animatedImage = true` set by `AnimatedImageInspector`. They should now
    // light up the right-click menu so the operator can convert to ProRes 4444.
    func testCanTranscodeAcceptsAnimatedImageSlide() throws {
        let gif = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanTranscode-\(UUID().uuidString).gif")
        try Data().write(to: gif)
        defer { try? FileManager.default.removeItem(at: gif) }

        var slide = MediaSlide(url: gif, mediaKind: .image)
        slide.flags = MediaFlags(animatedImage: true)
        XCTAssertTrue(TranscodeService.canTranscode(slide: slide))
    }

    func testPreferredPresetOrderLeads4444ForAnimatedImages() {
        let url = URL(fileURLWithPath: "/tmp/anim.gif")
        var animated = MediaSlide(url: url, mediaKind: .image)
        animated.flags = MediaFlags(animatedImage: true)
        // Alpha-aware sources lead with the alpha-preserving codec; ProRes 422 is still
        // available so an operator can override.
        XCTAssertEqual(
            TranscodeService.preferredPresetOrder(for: animated),
            [.proRes4444, .proRes422]
        )
    }

    func testPreferredPresetOrderLeads422ForVideoSlides() {
        let url = URL(fileURLWithPath: "/tmp/clip.mov")
        let video = MediaSlide(url: url, mediaKind: .video)
        XCTAssertEqual(
            TranscodeService.preferredPresetOrder(for: video),
            [.proRes422, .proRes4444]
        )
    }

    // MARK: - Job state machine

    @MainActor
    func testJobStartsInIdle() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("idle-\(UUID().uuidString).mov")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("idle-out-\(UUID().uuidString).mov")
        let job = TranscodeJob(sourceURL: source, destinationURL: dest, preset: .proRes422, displayLabel: "Idle")
        XCTAssertEqual(job.state, .idle)
        XCTAssertEqual(job.progress, 0)
        XCTAssertFalse(job.state.isTerminal)
        XCTAssertFalse(job.state.isRunning)
    }

    @MainActor
    func testJobFailsOnUnreadableSource() async throws {
        // Point the source at a non-existent path. AVAssetExportSession should reject and
        // we should land in the .failed state with a usable error message.
        let source = URL(fileURLWithPath: "/tmp/transcode-missing-\(UUID().uuidString).mov")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("fail-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: dest) }

        let job = TranscodeJob(sourceURL: source, destinationURL: dest, preset: .proRes422, displayLabel: "Missing")

        let exp = expectation(description: "job completed")
        job.start { result in
            switch result {
            case .success:
                XCTFail("expected failure on unreadable source")
            case .failure:
                exp.fulfill()
            }
        }
        await fulfillment(of: [exp], timeout: 30)
        guard case .failed = job.state else {
            XCTFail("expected .failed state, got \(job.state)")
            return
        }
    }

    /// End-to-end transcode of a synthesized H.264 movie → ProRes 422. Mirrors the
    /// MediaFlagsTests pattern of building a tiny movie with AVAssetWriter at test time
    /// so no fixture media is committed.
    @MainActor
    func testJobTranscodesH264ToProRes422() async throws {
        let source = try makeTinyH264Movie()
        defer { try? FileManager.default.removeItem(at: source) }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcode-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: dest) }

        let job = TranscodeJob(sourceURL: source, destinationURL: dest, preset: .proRes422, displayLabel: "Synth")

        let exp = expectation(description: "job completed")
        job.start { result in
            switch result {
            case .success(let url):
                XCTAssertEqual(url, dest)
                exp.fulfill()
            case .failure(let error):
                XCTFail("expected success, got \(error)")
            }
        }
        await fulfillment(of: [exp], timeout: 60)

        // Output file actually landed on disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))

        // Output is ProRes (the encoder we asked for).
        let asset = AVURLAsset(url: dest)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let track2 = try XCTUnwrap(track)
        let formats = try await track2.load(.formatDescriptions)
        let codec = try XCTUnwrap(formats.first.map { CMFormatDescriptionGetMediaSubType($0) })
        // ProRes 422: 'apcn'. ProRes 422 LT: 'apcs'. ProRes 422 Proxy: 'apco'. ProRes 422 HQ: 'apch'.
        let proResFourCCs: Set<FourCharCode> = [
            FourCharCode("apcn".fourCharCode),
            FourCharCode("apcs".fourCharCode),
            FourCharCode("apco".fourCharCode),
            FourCharCode("apch".fourCharCode)
        ]
        XCTAssertTrue(proResFourCCs.contains(codec), "expected ProRes 422 family, got \(codec)")

        // Job state should now be terminal and progress should be 1.0 at completion.
        guard case .completed(let url) = job.state else {
            XCTFail("expected .completed state, got \(job.state)")
            return
        }
        XCTAssertEqual(url, dest)
        XCTAssertTrue(job.state.isTerminal)
        XCTAssertEqual(job.progress, 1.0, accuracy: 0.0001)
    }

    // MARK: - H.264 movie synth

    private func makeTinyH264Movie() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcode-source-\(UUID().uuidString).mov")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 32,
                AVVideoHeightKey: 32
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 32,
                kCVPixelBufferHeightKey as String: 32
            ]
        )

        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            throw XCTSkip("pixel buffer pool unavailable on this host — H.264 encoder missing?")
        }

        for frameIndex in 0..<4 {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else { continue }
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

        let exp = expectation(description: "writer finished")
        writer.finishWriting { exp.fulfill() }
        wait(for: [exp], timeout: 10)
        return url
    }
}

private extension String {
    /// Treat the receiver as a 4-character ASCII string and return its FourCharCode.
    /// Used by the ProRes-family identification in `testJobTranscodesH264ToProRes422`.
    var fourCharCode: UInt32 {
        precondition(count == 4, "fourCharCode requires exactly 4 ASCII chars; got \(self)")
        var value: UInt32 = 0
        for char in unicodeScalars {
            value = (value << 8) | (UInt32(char.value) & 0xFF)
        }
        return value
    }
}
