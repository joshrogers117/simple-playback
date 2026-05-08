import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import Simple_Playback

final class PDFImporterTests: XCTestCase {

    // MARK: - rasterize: happy path

    func testRasterizeWritesOnePNGPerPage() throws {
        let pdf = try makeTestPDF(pages: 3, pageSize: CGSize(width: 612, height: 792))
        defer { try? FileManager.default.removeItem(at: pdf) }

        let dest = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        let written = try PDFImporter.rasterize(
            pdfURL: pdf,
            rasterSize: CGSize(width: 1920, height: 1080),
            destinationDirectory: dest
        )

        XCTAssertEqual(written.count, 3)
        for url in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "Expected PNG at \(url.path)")
        }
    }

    func testRasterizeNamesPagesInOrderWithLeadingZeros() throws {
        let pdf = try makeTestPDF(pages: 12, pageSize: CGSize(width: 100, height: 100))
        defer { try? FileManager.default.removeItem(at: pdf) }

        let dest = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        let written = try PDFImporter.rasterize(
            pdfURL: pdf,
            rasterSize: CGSize(width: 200, height: 200),
            destinationDirectory: dest
        )

        XCTAssertEqual(written.count, 12)
        XCTAssertEqual(written.first?.lastPathComponent, "page_001.png",
                       "Pages are 1-indexed and zero-padded so lexicographic sort matches page order.")
        XCTAssertEqual(written.last?.lastPathComponent, "page_012.png")
    }

    func testRasterizeFitsWithinRasterSizePreservingAspect() throws {
        // Letter page: 612 × 792, aspect ≈ 0.773. At 1920×1080 raster, height-limited:
        // scale = 1080/792 ≈ 1.364 → output ≈ 834 × 1080.
        let pdf = try makeTestPDF(pages: 1, pageSize: CGSize(width: 612, height: 792))
        defer { try? FileManager.default.removeItem(at: pdf) }

        let dest = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        let written = try PDFImporter.rasterize(
            pdfURL: pdf,
            rasterSize: CGSize(width: 1920, height: 1080),
            destinationDirectory: dest
        )

        let png = try XCTUnwrap(written.first)
        let image = try XCTUnwrap(NSImage(contentsOf: png))
        let pixelSize = pixelDimensions(of: image)
        XCTAssertLessThanOrEqual(pixelSize.width, 1920)
        XCTAssertLessThanOrEqual(pixelSize.height, 1080)
        // Aspect ≈ 612/792 ≈ 0.773. Allow 1px tolerance from ceil rounding.
        let aspect = Double(pixelSize.width) / Double(pixelSize.height)
        XCTAssertEqual(aspect, 612.0 / 792.0, accuracy: 0.005,
                       "Page aspect should be preserved when fitting into rasterSize.")
        // Height-limited at 1080 for a portrait Letter page.
        XCTAssertEqual(pixelSize.height, 1080)
    }

    func testRasterizeAtOutputTimesTwoProducesExpectedPixelTarget() throws {
        // Spec §3.10: "rasterize-on-import at output × 2". For a 1920×1080 stage, callers
        // pass 3840×2160. A page matching stage aspect (16:9 — 1600 × 900) should land at
        // exactly 3840×2160.
        let pdf = try makeTestPDF(pages: 1, pageSize: CGSize(width: 1600, height: 900))
        defer { try? FileManager.default.removeItem(at: pdf) }

        let dest = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        let written = try PDFImporter.rasterize(
            pdfURL: pdf,
            rasterSize: CGSize(width: 3840, height: 2160),
            destinationDirectory: dest
        )

        let png = try XCTUnwrap(written.first)
        let image = try XCTUnwrap(NSImage(contentsOf: png))
        let size = pixelDimensions(of: image)
        XCTAssertEqual(size.width, 3840)
        XCTAssertEqual(size.height, 2160)
    }

    func testRasterizeCreatesDestinationDirectoryIfMissing() throws {
        let pdf = try makeTestPDF(pages: 1, pageSize: CGSize(width: 100, height: 100))
        defer { try? FileManager.default.removeItem(at: pdf) }

        let parent = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        // Two-deep target that does not exist yet.
        let dest = parent
            .appendingPathComponent("Renders", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))

        let written = try PDFImporter.rasterize(
            pdfURL: pdf,
            rasterSize: CGSize(width: 200, height: 200),
            destinationDirectory: dest
        )

        XCTAssertEqual(written.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }

    // MARK: - rasterize: error paths

    func testRasterizeThrowsOnUnreadablePDF() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).pdf")
        let dest = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        XCTAssertThrowsError(
            try PDFImporter.rasterize(
                pdfURL: bogus,
                rasterSize: CGSize(width: 200, height: 200),
                destinationDirectory: dest
            )
        ) { error in
            guard case PDFImportError.unreadable = error else {
                return XCTFail("Expected .unreadable, got \(error)")
            }
        }
    }

    // MARK: - Test helpers

    private func tempSubdirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFImporterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Synthesizes a CGContext-backed PDF with `pages` pages of size `pageSize`. Each page
    /// gets a different solid fill so a future pixel-diff test could distinguish them.
    private func makeTestPDF(pages: Int, pageSize: CGSize) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFImporterTests-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for i in 0..<pages {
            context.beginPDFPage(nil)
            // Vary fills slightly so pages aren't identical bitstreams.
            let red = CGFloat((i * 37) % 256) / 255.0
            let green = CGFloat((i * 73) % 256) / 255.0
            let blue = CGFloat((i * 109) % 256) / 255.0
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            context.fill(mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func pixelDimensions(of image: NSImage) -> (width: Int, height: Int) {
        if let rep = image.representations.first as? NSBitmapImageRep {
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return (Int(image.size.width), Int(image.size.height))
        }
        return (cgImage.width, cgImage.height)
    }
}
