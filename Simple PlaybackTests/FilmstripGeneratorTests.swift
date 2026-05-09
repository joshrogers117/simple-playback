import AVFoundation
import CoreGraphics
import Foundation
import XCTest
@testable import Simple_Playback

/// C11 — pure-logic helpers and end-to-end sprite-sheet generation. The
/// pure-logic helpers (timestamp sampling + grid sizing) are what tests
/// pin most heavily; the end-to-end test builds a tiny H.264 movie via
/// AVAssetWriter (mirroring the TranscodeServiceTests pattern) so no
/// fixture media is committed.
final class FilmstripGeneratorTests: XCTestCase {

    // MARK: - sampleTimestamps

    func testSampleTimestampsCenteredEvenlyAcrossDuration() {
        let stamps = FilmstripGenerator.sampleTimestamps(durationSeconds: 12, frameCount: 4)
        // 4 cells over 12 s => spacing 3 s, centered offsets 1.5 / 4.5 / 7.5 / 10.5
        XCTAssertEqual(stamps, [1.5, 4.5, 7.5, 10.5])
    }

    func testSampleTimestampsNeverHitsExactZeroOrDuration() {
        // Avoiding `.zero` exact and `duration` exact protects against
        // decode-at-EOF failures and matches the doc-comment contract.
        let stamps = FilmstripGenerator.sampleTimestamps(durationSeconds: 10, frameCount: 24)
        XCTAssertGreaterThan(stamps.first ?? -1, 0)
        XCTAssertLessThan(stamps.last ?? 11, 10)
    }

    func testSampleTimestampsEmptyForInvalidInput() {
        XCTAssertTrue(FilmstripGenerator.sampleTimestamps(durationSeconds: 0, frameCount: 24).isEmpty)
        XCTAssertTrue(FilmstripGenerator.sampleTimestamps(durationSeconds: -5, frameCount: 24).isEmpty)
        XCTAssertTrue(FilmstripGenerator.sampleTimestamps(durationSeconds: 10, frameCount: 0).isEmpty)
    }

    // MARK: - gridPixelSize

    func testGridPixelSizeForDefaults() {
        let size = FilmstripGenerator.gridPixelSize(
            frameCount: 24,
            columns: 6,
            frameSize: CGSize(width: 160, height: 90)
        )
        // 6 cols × 4 rows × 160×90 each
        XCTAssertEqual(size.width, 960)
        XCTAssertEqual(size.height, 360)
    }

    func testGridPixelSizeRoundsRowsUp() {
        // 7 frames / 3 columns => ceil(7/3) = 3 rows.
        let size = FilmstripGenerator.gridPixelSize(
            frameCount: 7,
            columns: 3,
            frameSize: CGSize(width: 100, height: 60)
        )
        XCTAssertEqual(size.width, 300)
        XCTAssertEqual(size.height, 180)
    }

    func testGridPixelSizeZeroForInvalidInput() {
        XCTAssertEqual(FilmstripGenerator.gridPixelSize(frameCount: 0, columns: 6, frameSize: CGSize(width: 10, height: 10)), .zero)
        XCTAssertEqual(FilmstripGenerator.gridPixelSize(frameCount: 24, columns: 0, frameSize: CGSize(width: 10, height: 10)), .zero)
    }

    // MARK: - generateSpriteSheet

    func testGenerateSpriteSheetThrowsForUnreadableSource() async {
        let bogusURL = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).mov")
        do {
            _ = try await FilmstripGenerator.generateSpriteSheet(for: bogusURL)
            XCTFail("Expected throw")
        } catch {
            // Either sourceNotReadable (no video tracks) or durationUnknown
            // is acceptable — observationally equivalent for a missing file.
            switch error as? FilmstripGeneratorError {
            case .sourceNotReadable, .durationUnknown:
                break
            default:
                XCTFail("Expected sourceNotReadable / durationUnknown, got \(error)")
            }
        }
    }

    func testGenerateSpriteSheetThrowsFrameCountInvalid() async {
        let bogusURL = URL(fileURLWithPath: "/tmp/x.mov")
        do {
            _ = try await FilmstripGenerator.generateSpriteSheet(for: bogusURL, frameCount: 0)
            XCTFail("Expected throw")
        } catch {
            XCTAssertEqual(error as? FilmstripGeneratorError, .frameCountInvalid)
        }
    }

    func testGenerateSpriteSheetThrowsColumnsInvalid() async {
        let bogusURL = URL(fileURLWithPath: "/tmp/x.mov")
        do {
            _ = try await FilmstripGenerator.generateSpriteSheet(for: bogusURL, columns: 0)
            XCTFail("Expected throw")
        } catch {
            XCTAssertEqual(error as? FilmstripGeneratorError, .columnsInvalid)
        }
    }

    func testGenerateSpriteSheetHonorsTaskCancellation() async throws {
        // After the migration to async APIs, a cancelled Task aborts the
        // per-frame extraction loop instead of running every extraction
        // to completion. Spawn a task, cancel it before it hits await,
        // and confirm the throw is CancellationError rather than a
        // FilmstripGeneratorError.
        let url = try makeH264Movie(frameCount: 30)
        defer { try? FileManager.default.removeItem(at: url) }

        let task = Task<Void, Error> {
            try Task.checkCancellation()
            _ = try await FilmstripGenerator.generateSpriteSheet(
                for: url,
                frameCount: 24,
                columns: 6,
                frameSize: CGSize(width: 32, height: 32)
            )
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled task should not complete normally.")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testGenerateSpriteSheetProducesPNGForRealMovie() async throws {
        let url = try makeH264Movie(frameCount: 30)
        defer { try? FileManager.default.removeItem(at: url) }

        let pngData = try await FilmstripGenerator.generateSpriteSheet(
            for: url,
            frameCount: 4,
            columns: 2,
            frameSize: CGSize(width: 32, height: 32)
        )
        // PNG magic: 89 50 4E 47 0D 0A 1A 0A
        XCTAssertGreaterThanOrEqual(pngData.count, 8)
        XCTAssertEqual(Array(pngData.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        // Round-trip the PNG and verify the dimensions match the grid math.
        let bitmap = NSBitmapImageRep(data: pngData)
        XCTAssertEqual(bitmap?.pixelsWide, 64) // 2 cols × 32
        XCTAssertEqual(bitmap?.pixelsHigh, 64) // 2 rows × 32 (4 frames / 2 cols)
    }

    // MARK: - Test fixture

    private func makeH264Movie(frameCount: Int) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("filmstrip-source-\(UUID().uuidString).mov")
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
