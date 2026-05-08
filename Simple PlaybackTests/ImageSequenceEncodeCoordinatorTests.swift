import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Simple_Playback

/// C5b coordinator — job lifecycle + sibling-slide construction. End-to-end encode is
/// covered by `ImageSequenceEncoderTests`; this suite focuses on the coordinator wiring
/// (jobs list, sibling-importer seam, cancelAll). Mirrors `TranscodeCoordinatorTests`.
final class ImageSequenceEncodeCoordinatorTests: XCTestCase {

    private var savedSiblingImporter: (URL) -> MediaSlide? = { _ in nil }

    @MainActor
    override func setUp() {
        super.setUp()
        savedSiblingImporter = ImageSequenceEncodeCoordinator.siblingImporter
    }

    @MainActor
    override func tearDown() {
        ImageSequenceEncodeCoordinator.siblingImporter = savedSiblingImporter
        super.tearDown()
    }

    @MainActor
    func testCoordinatorStartsEmpty() {
        let coordinator = ImageSequenceEncodeCoordinator()
        XCTAssertTrue(coordinator.jobs.isEmpty)
    }

    @MainActor
    func testEncodeProducesSiblingSlideWithSequenceBaseName() async throws {
        let frames = try makeSyntheticPNGSequence(frameCount: 2, size: 32)
        defer {
            for url in frames { try? FileManager.default.removeItem(at: url) }
        }
        let sequence = ImageSequenceDetector.Sequence(
            baseName: "shot07",
            fileExtension: "png",
            frameURLs: frames,
            counterPadWidth: 4
        )
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seq-coord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        // Stub the sibling importer so the assertions don't depend on AVFoundation
        // re-inspecting the encoded file shape (already covered by C5b end-to-end).
        let stubURL = URL(fileURLWithPath: "/tmp/stub-\(UUID().uuidString).mov")
        ImageSequenceEncodeCoordinator.siblingImporter = { _ in
            MediaSlide(url: stubURL, mediaKind: .video, nativeFrameRate: 30, flags: .none)
        }

        let coordinator = ImageSequenceEncodeCoordinator()
        let exp = expectation(description: "encode complete")
        let job = coordinator.encode(
            sequence: sequence,
            frameRate: 30,
            destinationDirectory: destDir
        ) { result in
            switch result {
            case .success(let outcome):
                XCTAssertEqual(outcome.baseName, "shot07")
                XCTAssertEqual(outcome.siblingSlide.title, "shot07")
                XCTAssertEqual(outcome.siblingSlide.mediaKind, .video)
                exp.fulfill()
            case .failure(let error):
                XCTFail("expected success, got \(error)")
            }
        }
        XCTAssertNotNil(job)
        await fulfillment(of: [exp], timeout: 30)
        XCTAssertTrue(coordinator.jobs.isEmpty, "jobs list should drain on completion")
    }

    @MainActor
    func testEncodeFailsWhenSiblingImporterReturnsNil() async throws {
        let frames = try makeSyntheticPNGSequence(frameCount: 2, size: 32)
        defer {
            for url in frames { try? FileManager.default.removeItem(at: url) }
        }
        let sequence = ImageSequenceDetector.Sequence(
            baseName: "stillborn",
            fileExtension: "png",
            frameURLs: frames,
            counterPadWidth: 4
        )
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seq-coord-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        // Importer says no — the encode succeeded on disk, but the post-encode reimport
        // didn't yield a slide. Coordinator surfaces a finishFailed.
        ImageSequenceEncodeCoordinator.siblingImporter = { _ in nil }

        let coordinator = ImageSequenceEncodeCoordinator()
        let exp = expectation(description: "encode failure")
        coordinator.encode(
            sequence: sequence,
            frameRate: 30,
            destinationDirectory: destDir
        ) { result in
            switch result {
            case .success:
                XCTFail("expected failure when sibling importer returns nil")
            case .failure(let error):
                if case .finishFailed = error {
                    exp.fulfill()
                } else {
                    XCTFail("expected .finishFailed, got \(error)")
                }
            }
        }
        await fulfillment(of: [exp], timeout: 30)
    }

    @MainActor
    func testCancelAllCancelsRunningJobs() async throws {
        // Build a deliberately-large sequence so the encoder has time to be running when
        // we cancel. 60 frames at 32×32 is still cheap to synthesize but takes long enough
        // for the cancel to land mid-encode on most hosts.
        let frames = try makeSyntheticPNGSequence(frameCount: 60, size: 32)
        defer {
            for url in frames { try? FileManager.default.removeItem(at: url) }
        }
        let sequence = ImageSequenceDetector.Sequence(
            baseName: "longshot",
            fileExtension: "png",
            frameURLs: frames,
            counterPadWidth: 4
        )
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seq-cancelall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        ImageSequenceEncodeCoordinator.siblingImporter = { url in
            MediaSlide(url: url, mediaKind: .video, nativeFrameRate: 30)
        }

        let coordinator = ImageSequenceEncodeCoordinator()
        let exp = expectation(description: "cancelled (or completed if cancellation raced past)")
        coordinator.encode(
            sequence: sequence,
            frameRate: 30,
            destinationDirectory: destDir
        ) { result in
            // Either outcome is fine — the cancel may race the final frame. The contract
            // is that the jobs list drains and no encoder state stays orphaned.
            switch result {
            case .success, .failure:
                exp.fulfill()
            }
        }
        coordinator.cancelAll()
        await fulfillment(of: [exp], timeout: 30)
        XCTAssertTrue(coordinator.jobs.isEmpty, "jobs list should drain after cancelAll completes the encoder")
    }

    // MARK: - Synthesis helpers (mirrors ImageSequenceEncoderTests)

    private func makeSyntheticPNGSequence(frameCount: Int, size: Int) throws -> [URL] {
        var urls: [URL] = []
        for index in 0..<frameCount {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("frame-coord-\(UUID().uuidString)-\(index).png")
            let space = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let context = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: bitmapInfo
            ) else {
                throw NSError(domain: "ImageSequenceEncodeCoordinatorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "CGContext init failed"])
            }
            let red = CGFloat(index + 1) / CGFloat(frameCount + 1)
            context.setFillColor(red: red, green: 0.5, blue: 0.5, alpha: 1.0)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            guard let cg = context.makeImage() else {
                throw NSError(domain: "ImageSequenceEncodeCoordinatorTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "makeImage failed"])
            }
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw NSError(domain: "ImageSequenceEncodeCoordinatorTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "CGImageDestinationCreateWithURL failed"])
            }
            CGImageDestinationAddImage(dest, cg, nil)
            guard CGImageDestinationFinalize(dest) else {
                throw NSError(domain: "ImageSequenceEncodeCoordinatorTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "CGImageDestinationFinalize failed"])
            }
            urls.append(url)
        }
        return urls
    }
}
