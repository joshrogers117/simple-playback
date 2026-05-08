import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import Simple_Playback

/// C10 — pins the importer-side thumbnail cache write. The encoder is stubbed
/// so the test doesn't depend on AVAsset for video URLs and can drive the
/// failure path deterministically.
final class MediaImporterThumbnailTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        MediaImporter.thumbnailEncoder = { url, kind in
            try? ThumbnailGenerator.generateJPEG(for: url, mediaKind: kind)
        }
        MediaImporter.fingerprinter = { url in
            try? AssetFingerprinter.fingerprint(url: url)
        }
    }

    func testImportWritesThumbnailWhenContextProvidesDirectory() throws {
        let still = try makeStillPNG(size: CGSize(width: 32, height: 32))
        defer { try? FileManager.default.removeItem(at: still) }
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaImporterThumbTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let stubData = Data([0xFF, 0xD8, 0xFF, 0xDB, 0xCA, 0xFE])
        MediaImporter.thumbnailEncoder = { _, _ in stubData }

        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: FileManager.default.temporaryDirectory,
            thumbnailRootDirectory: cacheDir
        )
        let slides = MediaImporter.importSlides(from: [still], context: context)
        XCTAssertEqual(slides.count, 1)

        let slideID = try XCTUnwrap(slides.first?.id)
        let cached = cacheDir.appendingPathComponent("\(slideID.uuidString).jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path),
                      "Thumbnail should land at <thumbDir>/<slide.id>.jpg.")
        XCTAssertEqual(try Data(contentsOf: cached), stubData,
                       "The exact bytes returned by the encoder seam should reach disk.")
    }

    func testImportSkipsThumbnailWhenContextDirectoryIsNil() throws {
        let still = try makeStillPNG(size: CGSize(width: 16, height: 16))
        defer { try? FileManager.default.removeItem(at: still) }

        var encoderCallCount = 0
        MediaImporter.thumbnailEncoder = { _, _ in
            encoderCallCount += 1
            return Data([0xFF, 0xD8, 0xFF])
        }

        // No context at all — the legacy import path. Encoder should not be
        // touched (no cache directory means nowhere to write).
        let slides = MediaImporter.importSlides(from: [still])
        XCTAssertEqual(slides.count, 1)
        XCTAssertEqual(encoderCallCount, 0,
                       "Without a thumbnail directory, the encoder seam should not be invoked.")
    }

    func testImportSurvivesNilEncoder() throws {
        let still = try makeStillPNG(size: CGSize(width: 8, height: 8))
        defer { try? FileManager.default.removeItem(at: still) }
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaImporterThumbTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        // Encoder returns nil — simulating a codec-rejected source. The
        // import must still produce the slide; the cache file must not
        // exist.
        MediaImporter.thumbnailEncoder = { _, _ in nil }

        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: FileManager.default.temporaryDirectory,
            thumbnailRootDirectory: cacheDir
        )
        let slides = MediaImporter.importSlides(from: [still], context: context)
        XCTAssertEqual(slides.count, 1)

        let slideID = try XCTUnwrap(slides.first?.id)
        let cached = cacheDir.appendingPathComponent("\(slideID.uuidString).jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path),
                       "Encoder returning nil must not produce an empty file.")
    }

    func testImportPassesCorrectMediaKindToEncoder() throws {
        let still = try makeStillPNG(size: CGSize(width: 12, height: 12))
        defer { try? FileManager.default.removeItem(at: still) }
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaImporterThumbTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        var capturedKinds: [MediaKind] = []
        MediaImporter.thumbnailEncoder = { _, kind in
            capturedKinds.append(kind)
            return Data([0xFF, 0xD8, 0xFF])
        }

        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: FileManager.default.temporaryDirectory,
            thumbnailRootDirectory: cacheDir
        )
        _ = MediaImporter.importSlides(from: [still], context: context)
        XCTAssertEqual(capturedKinds, [.image])
    }

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
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.setFillColor(CGColor(srgbRed: 0.4, green: 0.7, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaImporterThumbTests-\(UUID().uuidString).png")
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
