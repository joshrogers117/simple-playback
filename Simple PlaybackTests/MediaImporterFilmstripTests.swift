import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import Simple_Playback

/// C11 — pins the importer-side filmstrip enqueue hook. Mirrors the
/// `MediaImporterThumbnailTests` shape: stub the enqueue closure on the
/// per-call `MediaImportContext` and assert it fires exactly once per video
/// import, never for images, and survives a nil hook.
final class MediaImporterFilmstripTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        // The importer's static seams are reset back to defaults so cross-
        // test state doesn't leak. We don't override fingerprinter here, but
        // restore it defensively to match the thumbnail-test pattern.
        MediaImporter.thumbnailEncoder = { url, kind in
            try? ThumbnailGenerator.generateJPEG(for: url, mediaKind: kind)
        }
        MediaImporter.fingerprinter = { url in
            try? AssetFingerprinter.fingerprint(url: url)
        }
    }

    func testImportInvokesEnqueueFilmstripForVideoImport() throws {
        let movie = try makeH264Movie(frameCount: 2)
        defer { try? FileManager.default.removeItem(at: movie) }

        // Avoid the real ThumbnailGenerator+AVFoundation overhead — the
        // filmstrip hook is what's under test.
        MediaImporter.thumbnailEncoder = { _, _ in nil }

        var calls: [(UUID, URL)] = []
        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: FileManager.default.temporaryDirectory,
            enqueueFilmstrip: { slideID, sourceURL in
                calls.append((slideID, sourceURL))
            }
        )

        let slides = MediaImporter.importSlides(from: [movie], context: context)
        XCTAssertEqual(slides.count, 1)

        let slideID = try XCTUnwrap(slides.first?.id)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, slideID)
        XCTAssertEqual(calls.first?.1.standardizedFileURL, movie.standardizedFileURL)
    }

    func testImportDoesNotEnqueueFilmstripForImageImport() throws {
        let still = try makeStillPNG(size: CGSize(width: 32, height: 32))
        defer { try? FileManager.default.removeItem(at: still) }

        var callCount = 0
        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: FileManager.default.temporaryDirectory,
            enqueueFilmstrip: { _, _ in callCount += 1 }
        )
        let slides = MediaImporter.importSlides(from: [still], context: context)
        XCTAssertEqual(slides.count, 1)
        XCTAssertEqual(callCount, 0,
                       "Image imports must not enqueue a filmstrip.")
    }

    func testImportSurvivesNilFilmstripHook() throws {
        // Default-nil hook (the legacy import contract). Importing a video
        // must still produce a slide and not crash on the missing closure.
        let movie = try makeH264Movie(frameCount: 2)
        defer { try? FileManager.default.removeItem(at: movie) }
        MediaImporter.thumbnailEncoder = { _, _ in nil }

        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: FileManager.default.temporaryDirectory
        )
        let slides = MediaImporter.importSlides(from: [movie], context: context)
        XCTAssertEqual(slides.count, 1)
    }

    // MARK: - Fixtures

    private func makeStillPNG(size: CGSize) throws -> URL {
        let width = Int(size.width)
        let height = Int(size.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(CGColor(srgbRed: 0.4, green: 0.7, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaImporterFilmstripTests-\(UUID().uuidString).png")
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private func makeH264Movie(frameCount: Int) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MediaImporterFilmstripTests-\(UUID().uuidString).mov")
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
