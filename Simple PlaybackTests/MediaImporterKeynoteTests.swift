import CoreGraphics
import Foundation
import XCTest
@testable import Simple_Playback

/// MediaImporter wiring for `.key` inputs (C6b). Real-Keynote AppleScript is fundamentally
/// untestable in CI; the success path is covered by injecting a stub exporter that produces
/// a synthetic PDF, then verifying PDFImporter rasterizes it through the same plumbing as
/// real `.key` imports would.
final class MediaImporterKeynoteTests: XCTestCase {

    private var savedExporter: (URL, URL) throws -> URL = { _, _ in URL(fileURLWithPath: "/") }
    private var savedWorkspaceProvider: (String) -> URL? = { _ in nil }

    override func setUp() {
        super.setUp()
        savedExporter = MediaImporter.keynoteExporter
        savedWorkspaceProvider = KeynoteImporter.workspaceProvider
    }

    override func tearDown() {
        MediaImporter.keynoteExporter = savedExporter
        KeynoteImporter.workspaceProvider = savedWorkspaceProvider
        super.tearDown()
    }

    // MARK: - isKeynote

    func testIsKeynoteRecognizesByExtension() {
        XCTAssertTrue(MediaImporter.isKeynote(URL(fileURLWithPath: "/tmp/deck.key")))
        XCTAssertTrue(MediaImporter.isKeynote(URL(fileURLWithPath: "/tmp/deck.KEY")))
        XCTAssertFalse(MediaImporter.isKeynote(URL(fileURLWithPath: "/tmp/still.png")))
        XCTAssertFalse(MediaImporter.isKeynote(URL(fileURLWithPath: "/tmp/deck.pdf")))
        XCTAssertFalse(MediaImporter.isKeynote(URL(fileURLWithPath: "/tmp/clip.mov")))
    }

    // MARK: - .key without context

    func testReturnsEmptyForKeynoteWhenContextIsAbsent() {
        // No context means no render destination; the no-context overload silently drops
        // .key files just like it drops PDFs.
        let key = URL(fileURLWithPath: "/tmp/deck.key")
        XCTAssertTrue(MediaImporter.importSlides(from: [key]).isEmpty)
    }

    // MARK: - Keynote not installed

    func testReturnsEmptyForKeynoteWhenKeynoteNotInstalled() throws {
        // Default exporter delegates to KeynoteImporter, which throws .keynoteNotInstalled
        // when the workspace provider returns nil. The importer must swallow that and return
        // an empty array — the UI surfaces the diagnostic banner separately.
        KeynoteImporter.workspaceProvider = { _ in nil }

        let key = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaImporterKeynoteTests-\(UUID().uuidString).key")
        try Data().write(to: key)
        defer { try? FileManager.default.removeItem(at: key) }

        let dest = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: dest
        )
        XCTAssertTrue(MediaImporter.importSlides(from: [key], context: context).isEmpty)
    }

    // MARK: - Success path via injected exporter

    func testRoutesKeynoteThroughExporterAndProducesImageSlides() throws {
        // Stub exporter: synthesize a 5-page PDF in the batch directory, return its URL.
        // The importer should hand that to PDFImporter.rasterize, producing 5 image slides.
        MediaImporter.keynoteExporter = { source, dest in
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let pdf = dest.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent).pdf")
            try Self.writeMultipagePDF(at: pdf, pages: 5, pageSize: CGSize(width: 800, height: 600))
            return pdf
        }

        let key = FileManager.default.temporaryDirectory
            .appendingPathComponent("Talk-\(UUID().uuidString).key")
        try Data().write(to: key)
        defer { try? FileManager.default.removeItem(at: key) }

        let dest = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: dest
        )
        let slides = MediaImporter.importSlides(from: [key], context: context)

        XCTAssertEqual(slides.count, 5)
        XCTAssertTrue(slides.allSatisfy { $0.mediaKind == .image })
        XCTAssertEqual(slides.first?.title, "\(key.deletingPathExtension().lastPathComponent) — page 1")
        XCTAssertEqual(slides.last?.title, "\(key.deletingPathExtension().lastPathComponent) — page 5")
        for slide in slides {
            let resolved = try XCTUnwrap(slide.media.resolvedURL())
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
        }
    }

    func testReturnsEmptyWhenExporterThrows() throws {
        MediaImporter.keynoteExporter = { _, _ in
            throw KeynoteImportError.exportFailed("boom")
        }

        let key = FileManager.default.temporaryDirectory
            .appendingPathComponent("Talk-\(UUID().uuidString).key")
        try Data().write(to: key)
        defer { try? FileManager.default.removeItem(at: key) }

        let dest = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: dest
        )
        XCTAssertTrue(MediaImporter.importSlides(from: [key], context: context).isEmpty)
    }

    // MARK: - Helpers

    private func tempSubdirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaImporterKeynoteTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writeMultipagePDF(at url: URL, pages: Int, pageSize: CGSize) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for i in 0..<pages {
            context.beginPDFPage(nil)
            let red = CGFloat((i * 53) % 256) / 255.0
            context.setFillColor(CGColor(srgbRed: red, green: 0.5, blue: 0.5, alpha: 1))
            context.fill(mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
