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

    // C7d punch list: a managed slide whose absolute path is stale on this host
    // should still register as transcode-eligible when the bundle's Media/ directory
    // is supplied — the bundle-aware overload of `MediaReference.resolvedURL` lets
    // re-transcode actions survive a moved bundle.
    func testCanTranscodeUsesBundleMediaDirectoryForManagedSlides() throws {
        let bundleMedia = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanTranscode-Bundle-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleMedia, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleMedia.deletingLastPathComponent()) }

        let bundledClip = bundleMedia.appendingPathComponent("clip.mov")
        try Data().write(to: bundledClip)

        // Build a managed slide whose recorded absolute path is wrong on this host —
        // the only way to resolve it is via the bundleMediaDirectory.
        let stalePath = "/tmp/host-A-only-\(UUID().uuidString)/clip.mov"
        var slide = MediaSlide(url: URL(fileURLWithPath: stalePath), mediaKind: .video)
        slide.media.kind = .managed
        slide.media.bookmarkData = nil

        XCTAssertFalse(
            TranscodeService.canTranscode(slide: slide),
            "Without a bundle hint, a stale-path managed slide cannot be transcoded."
        )
        XCTAssertTrue(
            TranscodeService.canTranscode(slide: slide, bundleMediaDirectory: bundleMedia),
            "With the bundle hint, the same managed slide resolves through Media/ and is transcode-eligible."
        )
    }

    // C8 v1.1 — folder-bookmark fallback rung lights up the eligibility check
    // when the per-file bookmark + absolute path are dead but the folder
    // bookmark + relative path resolves. Mirrors the bundle-aware test above
    // for the rung-2 route.
    func testCanTranscodeUsesFolderBookmarkFallback() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanTranscode-Folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let realClip = folder.appendingPathComponent("clip.mov")
        try Data().write(to: realClip)

        let bookmark = FolderBookmark(folderURL: folder)

        // Slide with a stale per-file path but valid folder-bookmark + relative path.
        let stalePath = "/tmp/host-A-only-\(UUID().uuidString)/clip.mov"
        var slide = MediaSlide(url: URL(fileURLWithPath: stalePath), mediaKind: .video)
        slide.media.bookmarkData = nil
        slide.media.folderBookmarkID = bookmark.id
        slide.media.folderRelativePath = "clip.mov"

        XCTAssertFalse(
            TranscodeService.canTranscode(slide: slide, bundleMediaDirectory: nil, folderBookmarks: [:]),
            "Without the folder-bookmark lookup, the stale per-file path is the only route and it's dead."
        )
        XCTAssertTrue(
            TranscodeService.canTranscode(
                slide: slide,
                bundleMediaDirectory: nil,
                folderBookmarks: [bookmark.id: bookmark]
            ),
            "With the folder-bookmark lookup, the rung-2 fallback resolves so the slide is transcode-eligible."
        )
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

    /// Cancellation must remove the partial `.mov` from disk so `<bundle>/Transcoded/`
    /// does not accumulate orphans across cancellations. Uses a longer source (~120
    /// frames @ 30 fps ≈ 4 s) to give the cancel time to land mid-export. If the
    /// cancel races past the export's natural finish (small chance on a fast host),
    /// the test still passes — we only assert cleanup in the actual cancel branch.
    @MainActor
    func testCancelledTranscodeRemovesPartialFile() async throws {
        let source = try makeH264Movie(frameCount: 120)
        defer { try? FileManager.default.removeItem(at: source) }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcode-cancel-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: dest) }

        let job = TranscodeJob(sourceURL: source, destinationURL: dest, preset: .proRes422, displayLabel: "Cancel synth")

        let exp = expectation(description: "job terminal")
        job.start { _ in exp.fulfill() }

        // Give the export a moment to actually start writing before we cancel. Without
        // this delay, the cancel sometimes lands while AVAssetExportSession is still
        // setting up and the partial file is never created — making the cleanup
        // assertion vacuous.
        try await Task.sleep(nanoseconds: 100_000_000)
        job.cancel()

        await fulfillment(of: [exp], timeout: 60)

        if case .cancelled = job.state {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: dest.path),
                "Cancelled transcodes must clean up their partial .mov so <bundle>/Transcoded/ does not accumulate orphans."
            )
        }
        // If state.isTerminal but not .cancelled (the cancel raced past completion),
        // the test exits without asserting — the cleanup invariant only applies to
        // the cancel branch.
    }

    func testRemovePartialFileIfNeededDeletesExistingFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("partial-\(UUID().uuidString).mov")
        try Data([0x00, 0x01, 0x02]).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        TranscodeJob.removePartialFileIfNeeded(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRemovePartialFileIfNeededIsSafeWhenAbsent() {
        // Helper must be called repeatedly without crashing — the cancel path runs
        // unconditionally, even on cancel-before-write-started where no file exists yet.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).mov")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        TranscodeJob.removePartialFileIfNeeded(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - H.264 movie synth

    private func makeTinyH264Movie() throws -> URL {
        try makeH264Movie(frameCount: 4)
    }

    private func makeH264Movie(frameCount: Int) throws -> URL {
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

        for frameIndex in 0..<frameCount {
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
