import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Simple_Playback

/// C5b — Image-sequence encoder tests. Mirrors the C2 `TranscodeServiceTests` pattern of
/// synthesizing tiny media at test time so no fixture files are committed. Focus areas:
///
/// * State / lifecycle (idle → running → terminal).
/// * Empty-input / invalid-frame-rate fast-fail paths.
/// * End-to-end: PNG sequence → ProRes 4444 .mov pinned by FourCC `ap4h`.
/// * Frame-count / frame-rate threading: 3 input frames @ 30 fps → 0.1 s movie duration.
/// * Cancellation before start (no-op) and after completion (no-op).
final class ImageSequenceEncoderTests: XCTestCase {

    // MARK: - State + lifecycle

    @MainActor
    func testEncoderStartsInIdle() {
        let encoder = ImageSequenceEncoder(
            frameURLs: [URL(fileURLWithPath: "/tmp/none.png")],
            destinationURL: URL(fileURLWithPath: "/tmp/none.mov"),
            frameRate: 30,
            displayLabel: "stub"
        )
        XCTAssertEqual(encoder.state, .idle)
        XCTAssertEqual(encoder.progress, 0)
        XCTAssertFalse(encoder.state.isTerminal)
        XCTAssertFalse(encoder.state.isRunning)
    }

    @MainActor
    func testCancelBeforeStartIsNoOp() {
        let encoder = ImageSequenceEncoder(
            frameURLs: [URL(fileURLWithPath: "/tmp/none.png")],
            destinationURL: URL(fileURLWithPath: "/tmp/none.mov"),
            frameRate: 30,
            displayLabel: "stub"
        )
        encoder.cancel()
        // Cancel before start does NOT transition state — start() is the gating call.
        XCTAssertEqual(encoder.state, .idle)
    }

    // MARK: - Fast-fail paths

    @MainActor
    func testEncoderFailsWhenFrameListEmpty() {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).mov")
        let encoder = ImageSequenceEncoder(
            frameURLs: [],
            destinationURL: dest,
            frameRate: 30,
            displayLabel: "empty"
        )

        let exp = expectation(description: "completion")
        encoder.start { result in
            switch result {
            case .success:
                XCTFail("expected failure for empty frame list")
            case .failure(let error):
                XCTAssertEqual(error, .noFrames)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 5)
        guard case .failed = encoder.state else {
            XCTFail("expected .failed state, got \(encoder.state)")
            return
        }
    }

    @MainActor
    func testEncoderFailsWhenFrameRateLessThanOne() {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("badrate-\(UUID().uuidString).mov")
        let encoder = ImageSequenceEncoder(
            frameURLs: [URL(fileURLWithPath: "/tmp/none.png")],
            destinationURL: dest,
            frameRate: 0,
            displayLabel: "badrate"
        )

        let exp = expectation(description: "completion")
        encoder.start { result in
            switch result {
            case .success:
                XCTFail("expected failure for invalid frame rate")
            case .failure(let error):
                XCTAssertEqual(error, .invalidFrameRate(0))
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 5)
    }

    @MainActor
    func testEncoderFailsWhenFrameUnreadable() async {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("badframe-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: dest) }
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).png")
        let encoder = ImageSequenceEncoder(
            frameURLs: [bogus],
            destinationURL: dest,
            frameRate: 30,
            displayLabel: "badframe"
        )

        let exp = expectation(description: "completion")
        encoder.start { result in
            switch result {
            case .success:
                XCTFail("expected failure for unreadable frame")
            case .failure(let error):
                if case .unreadableFrame = error {
                    exp.fulfill()
                } else {
                    XCTFail("expected .unreadableFrame, got \(error)")
                }
            }
        }
        await fulfillment(of: [exp], timeout: 10)
    }

    // MARK: - End-to-end ProRes 4444

    /// End-to-end: synthesize three 32×32 PNG frames, encode them at 30 fps, assert the
    /// resulting .mov has FourCC `ap4h` (ProRes 4444).
    @MainActor
    func testEncodesPNGSequenceToProRes4444() async throws {
        let frames = try makeSyntheticPNGSequence(frameCount: 3, size: 32)
        defer {
            for url in frames { try? FileManager.default.removeItem(at: url) }
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("seq-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: dest) }

        let encoder = ImageSequenceEncoder(
            frameURLs: frames,
            destinationURL: dest,
            frameRate: 30,
            displayLabel: "synth"
        )

        let exp = expectation(description: "encode complete")
        encoder.start { result in
            switch result {
            case .success(let url):
                XCTAssertEqual(url, dest)
                exp.fulfill()
            case .failure(let error):
                XCTFail("expected success, got \(error)")
            }
        }
        await fulfillment(of: [exp], timeout: 30)

        // The output file actually landed on disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))

        // Codec is ProRes 4444 — FourCC `ap4h`. The sibling FourCC `ap4x` (ProRes 4444 XQ)
        // is also acceptable in case AVFoundation upgrades the asked-for codec on this
        // host, though `proRes4444` historically lands on `ap4h`.
        let asset = AVURLAsset(url: dest)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let videoTrack = try XCTUnwrap(track)
        let formats = try await videoTrack.load(.formatDescriptions)
        let codec = try XCTUnwrap(formats.first.map { CMFormatDescriptionGetMediaSubType($0) })
        let proRes4444Family: Set<FourCharCode> = [
            FourCharCode("ap4h".fourCharCode),
            FourCharCode("ap4x".fourCharCode)
        ]
        XCTAssertTrue(proRes4444Family.contains(codec), "expected ProRes 4444 family (ap4h/ap4x), got \(fourCCDescription(codec))")

        // Job state should be terminal and progress 1.0 at completion.
        guard case .completed(let url) = encoder.state else {
            XCTFail("expected .completed state, got \(encoder.state)")
            return
        }
        XCTAssertEqual(url, dest)
        XCTAssertTrue(encoder.state.isTerminal)
        XCTAssertEqual(encoder.progress, 1.0, accuracy: 0.0001)

        // Frame count + duration sanity. 3 frames at 30 fps → 3/30 = 0.1 s.
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        XCTAssertEqual(seconds, 0.1, accuracy: 0.05, "expected ~0.1 s, got \(seconds)")
    }

    /// Cancellation after completion is a no-op — the state stays `.completed`.
    @MainActor
    func testCancelAfterCompletionIsNoOp() async throws {
        let frames = try makeSyntheticPNGSequence(frameCount: 2, size: 32)
        defer {
            for url in frames { try? FileManager.default.removeItem(at: url) }
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("seq-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: dest) }

        let encoder = ImageSequenceEncoder(
            frameURLs: frames,
            destinationURL: dest,
            frameRate: 30,
            displayLabel: "synth"
        )

        let exp = expectation(description: "encode complete")
        encoder.start { _ in exp.fulfill() }
        await fulfillment(of: [exp], timeout: 30)

        guard case .completed = encoder.state else {
            XCTFail("expected .completed before cancel-after-complete check")
            return
        }
        encoder.cancel()
        // State remains .completed; cancel() short-circuits on terminal states.
        guard case .completed = encoder.state else {
            XCTFail("cancel after completion should leave state at .completed")
            return
        }
    }

    /// Calling start() twice — the second call is a no-op (the first call's task wins).
    @MainActor
    func testStartTwiceIsNoOpOnSecondCall() async throws {
        let frames = try makeSyntheticPNGSequence(frameCount: 2, size: 32)
        defer {
            for url in frames { try? FileManager.default.removeItem(at: url) }
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("seq-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: dest) }

        let encoder = ImageSequenceEncoder(
            frameURLs: frames,
            destinationURL: dest,
            frameRate: 30,
            displayLabel: "synth"
        )

        var firstFired = false
        var secondFired = false

        let firstExp = expectation(description: "first completion")
        encoder.start { _ in
            firstFired = true
            firstExp.fulfill()
        }
        // Immediately re-call: second invocation is a no-op (state is already `.running`)
        // and its completion never fires.
        encoder.start { _ in secondFired = true }

        await fulfillment(of: [firstExp], timeout: 30)
        XCTAssertTrue(firstFired)
        XCTAssertFalse(secondFired, "second start() must not fire its completion")
    }

    // MARK: - CGImage helper

    func testMakeCGImageReadsPNG() throws {
        let frames = try makeSyntheticPNGSequence(frameCount: 1, size: 16)
        defer {
            for url in frames { try? FileManager.default.removeItem(at: url) }
        }
        let image = ImageSequenceEncoder.makeCGImage(from: frames[0])
        let cg = try XCTUnwrap(image)
        XCTAssertEqual(cg.width, 16)
        XCTAssertEqual(cg.height, 16)
    }

    func testMakeCGImageReturnsNilForMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).png")
        XCTAssertNil(ImageSequenceEncoder.makeCGImage(from: url))
    }

    // MARK: - Synthesis helpers

    /// Builds `frameCount` solid-fill PNG files at `size × size`. Each frame's red channel
    /// varies by index so the encoder isn't compressing identical content (defensive — if
    /// an encoder ever short-circuited identical frames the test wouldn't catch real I/O).
    private func makeSyntheticPNGSequence(frameCount: Int, size: Int) throws -> [URL] {
        var urls: [URL] = []
        for index in 0..<frameCount {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("frame-\(UUID().uuidString)-\(index).png")
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
                throw NSError(domain: "ImageSequenceEncoderTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "CGContext init failed"])
            }
            let red = CGFloat(index + 1) / CGFloat(frameCount + 1)
            context.setFillColor(red: red, green: 0.5, blue: 0.5, alpha: 1.0)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            guard let cg = context.makeImage() else {
                throw NSError(domain: "ImageSequenceEncoderTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "makeImage failed"])
            }
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw NSError(domain: "ImageSequenceEncoderTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "CGImageDestinationCreateWithURL failed"])
            }
            CGImageDestinationAddImage(dest, cg, nil)
            guard CGImageDestinationFinalize(dest) else {
                throw NSError(domain: "ImageSequenceEncoderTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "CGImageDestinationFinalize failed"])
            }
            urls.append(url)
        }
        return urls
    }

    private func fourCCDescription(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }
}

private extension String {
    /// Treat the receiver as a 4-character ASCII string and return its FourCharCode.
    /// Mirrors the helper in `TranscodeServiceTests`.
    var fourCharCode: UInt32 {
        precondition(count == 4, "fourCharCode requires exactly 4 ASCII chars; got \(self)")
        var value: UInt32 = 0
        for char in unicodeScalars {
            value = (value << 8) | (UInt32(char.value) & 0xFF)
        }
        return value
    }
}
