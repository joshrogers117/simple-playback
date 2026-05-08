import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import XCTest
@testable import Simple_Playback

/// C2b — TranscodeCoordinator job lifecycle + sibling-slide construction. The end-to-end
/// transcode test still uses an AVAssetWriter-synthesized H.264 source (mirrors C2a).
/// Sibling-slide construction is unit-testable via the `siblingImporter` test seam, so
/// the assertions about sibling shape don't need to round-trip through AVFoundation.
final class TranscodeCoordinatorTests: XCTestCase {

    private var savedSiblingImporter: (URL) -> MediaSlide? = { _ in nil }

    @MainActor
    override func setUp() {
        super.setUp()
        savedSiblingImporter = TranscodeCoordinator.siblingImporter
    }

    @MainActor
    override func tearDown() {
        TranscodeCoordinator.siblingImporter = savedSiblingImporter
        super.tearDown()
    }

    @MainActor
    func testCoordinatorStartsEmpty() {
        let coordinator = TranscodeCoordinator()
        XCTAssertTrue(coordinator.jobs.isEmpty)
    }

    @MainActor
    func testTranscodeFailsImmediatelyWhenSourceURLDoesNotResolve() {
        // A MediaSlide whose URL no longer resolves (file deleted, bookmark stale) must
        // not enqueue a job — the UI gates this through canTranscode, but the coordinator
        // should refuse defensively.
        let missing = URL(fileURLWithPath: "/tmp/transcode-nope-\(UUID().uuidString).mov")
        let slide = MediaSlide(url: missing, mediaKind: .video)
        let coordinator = TranscodeCoordinator()

        let exp = expectation(description: "completion")
        let job = coordinator.transcode(
            slide: slide,
            preset: .proRes422,
            destinationDirectory: FileManager.default.temporaryDirectory
        ) { result in
            if case .failure = result { exp.fulfill() }
        }
        XCTAssertNil(job)
        wait(for: [exp], timeout: 1)
        XCTAssertTrue(coordinator.jobs.isEmpty)
    }

    @MainActor
    func testTranscodeProducesSiblingSlideWithExpectedShape() async throws {
        // End-to-end: synthesized H.264 source → ProRes 422 transcode → sibling slide
        // returned via completion. Stub the sibling importer so the assertion isn't gated
        // on AVFoundation re-inspecting the transcoded file shape (covered by C2a).
        let source = try makeTinyH264Movie()
        defer { try? FileManager.default.removeItem(at: source) }

        var stubURL: URL?
        TranscodeCoordinator.siblingImporter = { url in
            stubURL = url
            var slide = MediaSlide(url: url, mediaKind: .video)
            slide.nativeFrameRate = 25.0
            return slide
        }

        let dest = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        let sourceSlide = MediaSlide(url: source, mediaKind: .video)
        let coordinator = TranscodeCoordinator()

        let exp = expectation(description: "outcome")
        var captured: TranscodeOutcome?
        coordinator.transcode(
            slide: sourceSlide,
            preset: .proRes422,
            destinationDirectory: dest
        ) { result in
            switch result {
            case .success(let outcome):
                captured = outcome
                exp.fulfill()
            case .failure(let error):
                XCTFail("expected success, got \(error)")
            }
        }

        // While running, the job should be visible in the published list.
        XCTAssertEqual(coordinator.jobs.count, 1)

        await fulfillment(of: [exp], timeout: 60)

        let outcome = try XCTUnwrap(captured)
        XCTAssertEqual(outcome.sourceSlideID, sourceSlide.id)
        XCTAssertEqual(outcome.preset, .proRes422)
        XCTAssertEqual(outcome.siblingSlide.mediaKind, .video)
        XCTAssertEqual(outcome.siblingSlide.title, "\(sourceSlide.title) (ProRes 422)")
        XCTAssertEqual(outcome.siblingSlide.nativeFrameRate, 25.0)
        // Sibling MediaSlide gets a fresh UUID — A/B comparison must work without ID
        // collision.
        XCTAssertNotEqual(outcome.siblingSlide.id, sourceSlide.id)
        // The transcoded file actually landed in the destination directory.
        let writtenURL = try XCTUnwrap(stubURL)
        XCTAssertEqual(writtenURL.deletingLastPathComponent(), dest)
        XCTAssertEqual(writtenURL.pathExtension, "mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: writtenURL.path))

        // Job is removed from the published list once it terminates.
        XCTAssertTrue(coordinator.jobs.isEmpty)
    }

    @MainActor
    func testCancelAllCancelsRunningJobs() async throws {
        // Start a transcode against a synthesized source so the underlying export is real,
        // then immediately cancel. The completion should fire with `.cancelled` and the
        // job list should drain.
        let source = try makeTinyH264Movie()
        defer { try? FileManager.default.removeItem(at: source) }

        TranscodeCoordinator.siblingImporter = { _ in
            XCTFail("sibling importer should not be invoked on cancel")
            return nil
        }

        let dest = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        let sourceSlide = MediaSlide(url: source, mediaKind: .video)
        let coordinator = TranscodeCoordinator()

        let exp = expectation(description: "cancelled")
        coordinator.transcode(
            slide: sourceSlide,
            preset: .proRes422,
            destinationDirectory: dest
        ) { result in
            switch result {
            case .success:
                // Race window: a tiny synthesized clip can finish before the cancel takes
                // effect. Either outcome is valid for this test — the contract under test
                // is that the jobs list drains and no leak/crash occurs.
                exp.fulfill()
            case .failure(.cancelled):
                exp.fulfill()
            case .failure(let error):
                XCTFail("expected cancelled or success, got \(error)")
            }
        }

        coordinator.cancelAll()
        await fulfillment(of: [exp], timeout: 30)
        XCTAssertTrue(coordinator.jobs.isEmpty)
    }

    // MARK: - Helpers

    private func tempSubdirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscodeCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTinyH264Movie() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coord-source-\(UUID().uuidString).mov")
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
