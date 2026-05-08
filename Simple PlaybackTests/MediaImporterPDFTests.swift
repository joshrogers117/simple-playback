import CoreGraphics
import Foundation
import XCTest
@testable import Simple_Playback

/// MediaImporter wiring for PDF inputs (C3b). PDFImporter rasterize-level coverage lives
/// in `PDFImporterTests`; this file pins the contract that the importer routes PDFs
/// through the context-aware path and produces resolvable image MediaSlides.
final class MediaImporterPDFTests: XCTestCase {

    func testRoutesPDFThroughContextAndProducesImageSlides() throws {
        let pdf = try makeTestPDF(pages: 4, pageSize: CGSize(width: 800, height: 600))
        defer { try? FileManager.default.removeItem(at: pdf) }

        let dest = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: dest
        )
        let slides = MediaImporter.importSlides(from: [pdf], context: context)

        XCTAssertEqual(slides.count, 4)
        XCTAssertTrue(slides.allSatisfy { $0.mediaKind == .image })
        XCTAssertEqual(slides.first?.title, "\(pdf.deletingPathExtension().lastPathComponent) — page 1")
        XCTAssertEqual(slides.last?.title, "\(pdf.deletingPathExtension().lastPathComponent) — page 4")
        for slide in slides {
            let resolved = try XCTUnwrap(slide.media.resolvedURL())
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
        }
    }

    func testReturnsEmptyForPDFWhenContextIsAbsent() throws {
        // Backwards-compatible no-context call has no way to render PDF pages — silently
        // drop instead of producing an unplayable .image slide pointing at the PDF itself.
        let pdf = try makeTestPDF(pages: 2, pageSize: CGSize(width: 200, height: 200))
        defer { try? FileManager.default.removeItem(at: pdf) }

        XCTAssertTrue(MediaImporter.importSlides(from: [pdf]).isEmpty)
    }

    func testNonPDFInputsAreUnaffectedByContextSignature() throws {
        // Non-PDF URLs route through the legacy mediaKind path. Stills should be detected
        // as `.image` whether or not the caller passed a context.
        let still = try makeStillPNG(size: CGSize(width: 64, height: 64))
        defer { try? FileManager.default.removeItem(at: still) }

        let dest = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: dest
        )
        let withContext = MediaImporter.importSlides(from: [still], context: context)
        let withoutContext = MediaImporter.importSlides(from: [still])

        XCTAssertEqual(withContext.count, 1)
        XCTAssertEqual(withoutContext.count, 1)
        XCTAssertEqual(withContext.first?.mediaKind, .image)
        XCTAssertEqual(withoutContext.first?.mediaKind, .image)
    }

    func testIsPDFRecognizesByExtensionAndUTType() {
        XCTAssertTrue(MediaImporter.isPDF(URL(fileURLWithPath: "/tmp/deck.pdf")))
        XCTAssertTrue(MediaImporter.isPDF(URL(fileURLWithPath: "/tmp/deck.PDF")))
        XCTAssertFalse(MediaImporter.isPDF(URL(fileURLWithPath: "/tmp/still.png")))
        XCTAssertFalse(MediaImporter.isPDF(URL(fileURLWithPath: "/tmp/clip.mov")))
    }

    // MARK: - Helpers

    private func tempSubdirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaImporterPDFTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTestPDF(pages: Int, pageSize: CGSize) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaImporterPDFTests-\(UUID().uuidString).pdf")
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

    private func makeStillPNG(size: CGSize) throws -> URL {
        let width = Int(size.width)
        let height = Int(size.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
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
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaImporterPDFTests-\(UUID().uuidString).png")
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}

#if canImport(AppKit)
import AppKit
#endif
