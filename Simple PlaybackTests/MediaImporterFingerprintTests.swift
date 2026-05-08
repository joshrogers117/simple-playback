import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import Simple_Playback

/// MediaImporter wiring for the C7b fingerprint pass. Pins that direct image/video
/// imports and PDF/Keynote rasterized pages all carry a `media.fingerprint` populated
/// at import time. The hash function itself is covered in `AssetFingerprinterTests`;
/// these tests pin only the routing.
final class MediaImporterFingerprintTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        // Reset the test seam so other suites don't see a stub from this file.
        MediaImporter.fingerprinter = { url in
            try? AssetFingerprinter.fingerprint(url: url)
        }
    }

    // MARK: - direct image/video paths

    func testImportPopulatesFingerprintForDirectImage() throws {
        let still = try makeStillPNG(size: CGSize(width: 32, height: 32))
        defer { try? FileManager.default.removeItem(at: still) }

        let slides = MediaImporter.importSlides(from: [still])

        XCTAssertEqual(slides.count, 1)
        let fingerprint = try XCTUnwrap(slides.first?.media.fingerprint,
                                        "Direct image import should carry a non-nil fingerprint.")
        XCTAssertEqual(fingerprint.contentHash.count, 64,
                       "Hex SHA-256 is 64 characters.")
        XCTAssertGreaterThan(fingerprint.size, 0,
                             "Real PNG file should report non-zero size.")

        let direct = try AssetFingerprinter.fingerprint(url: still)
        XCTAssertEqual(fingerprint.contentHash, direct.contentHash,
                       "Importer-side fingerprint should match a direct stream of the same bytes.")
        XCTAssertEqual(fingerprint.size, direct.size)
    }

    func testImportSurvivesNilFingerprinter() throws {
        // A failed fingerprint must NOT block the import — slide is still produced
        // with `fingerprint = nil`. A future relink will recompute.
        let still = try makeStillPNG(size: CGSize(width: 16, height: 16))
        defer { try? FileManager.default.removeItem(at: still) }

        MediaImporter.fingerprinter = { _ in nil }

        let slides = MediaImporter.importSlides(from: [still])

        XCTAssertEqual(slides.count, 1)
        XCTAssertNil(slides.first?.media.fingerprint)
    }

    func testFingerprinterIsCalledWithSourceURL() throws {
        let still = try makeStillPNG(size: CGSize(width: 8, height: 8))
        defer { try? FileManager.default.removeItem(at: still) }

        var observedURLs: [URL] = []
        MediaImporter.fingerprinter = { url in
            observedURLs.append(url)
            return MediaAssetFingerprint(contentHash: "stub", size: 1, mtime: Date())
        }

        _ = MediaImporter.importSlides(from: [still])

        XCTAssertEqual(observedURLs, [still])
    }

    // MARK: - PDF rasterized pages

    func testFingerprinterIsCalledForEachPDFPage() throws {
        let pdf = try makeTestPDF(pages: 3, pageSize: CGSize(width: 200, height: 200))
        defer { try? FileManager.default.removeItem(at: pdf) }

        let dest = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        var observedURLs: [URL] = []
        MediaImporter.fingerprinter = { url in
            observedURLs.append(url)
            return MediaAssetFingerprint(contentHash: "stub", size: 1, mtime: Date())
        }

        let slides = MediaImporter.importSlides(
            from: [pdf],
            context: MediaImportContext(
                rasterSize: CGSize(width: 400, height: 400),
                renderRootDirectory: dest
            )
        )

        XCTAssertEqual(slides.count, 3)
        XCTAssertEqual(observedURLs.count, 3,
                       "Every rasterized page should be fingerprinted.")
        for (slide, url) in zip(slides, observedURLs) {
            XCTAssertEqual(slide.media.fingerprint?.contentHash, "stub")
            XCTAssertEqual(slide.media.originalPath, url.path)
        }
    }

    // MARK: - helpers

    private func tempSubdirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaImporterFingerprintTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStillPNG(size: CGSize) throws -> URL {
        let width = Int(size.width)
        let height = Int(size.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
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
            .appendingPathComponent("MediaImporterFingerprintTests-\(UUID().uuidString).png")
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private func makeTestPDF(pages: Int, pageSize: CGSize) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaImporterFingerprintTests-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for i in 0..<pages {
            context.beginPDFPage(nil)
            let red = CGFloat((i * 37) % 256) / 255.0
            context.setFillColor(CGColor(srgbRed: red, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}
