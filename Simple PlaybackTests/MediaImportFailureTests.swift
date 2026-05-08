import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Simple_Playback

/// C-banner-a — `MediaImporter.importSlidesAndReport(from:context:)` plus
/// `MediaImportFailure` value-type. Pins the contract: every failure that previously
/// dropped on the floor (PDF rasterize error, Keynote AppleScript / install-missing
/// error, unsupported file type) now lands in the report.
final class MediaImportFailureTests: XCTestCase {

    private var savedKeynoteWorkspace: ((String) -> URL?)!
    private var savedKeynoteExporter: ((URL, URL) throws -> URL)!

    override func setUp() {
        super.setUp()
        savedKeynoteWorkspace = KeynoteImporter.workspaceProvider
        savedKeynoteExporter = MediaImporter.keynoteExporter
    }

    override func tearDown() {
        KeynoteImporter.workspaceProvider = savedKeynoteWorkspace
        MediaImporter.keynoteExporter = savedKeynoteExporter
        super.tearDown()
    }

    // MARK: - Empty / happy path

    func testEmptyURLListYieldsEmptyReport() {
        let report = MediaImporter.importSlidesAndReport(from: [], context: nil)
        XCTAssertEqual(report, .empty)
    }

    func testHappyImagePathProducesNoFailures() throws {
        let still = try makeStillPNG(size: CGSize(width: 32, height: 32))
        defer { try? FileManager.default.removeItem(at: still) }

        let report = MediaImporter.importSlidesAndReport(from: [still], context: nil)
        XCTAssertEqual(report.slides.count, 1)
        XCTAssertEqual(report.failures, [])
    }

    // MARK: - Unsupported media

    func testUnsupportedMediaIsReportedAsFailure() {
        // .txt has no image / video / PDF / Keynote UTI conformance — the importer
        // previously dropped silently.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(UUID().uuidString).txt")
        try? "hi".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let report = MediaImporter.importSlidesAndReport(from: [url], context: nil)
        XCTAssertEqual(report.slides, [])
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.kind, .unsupportedMedia)
        XCTAssertEqual(report.failures.first?.url, url)
        XCTAssertTrue(report.failures.first?.summary.contains(url.lastPathComponent) ?? false)
    }

    // MARK: - PDF failure

    func testCorruptPDFIsReportedAsPDFImportFailure() throws {
        let pdf = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).pdf")
        try Data([0x00, 0x01, 0x02]).write(to: pdf)
        defer { try? FileManager.default.removeItem(at: pdf) }

        let dest = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: dest
        )
        let report = MediaImporter.importSlidesAndReport(from: [pdf], context: context)
        XCTAssertEqual(report.slides, [])
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.kind, .pdfImport)
        XCTAssertEqual(report.failures.first?.url, pdf)
    }

    // MARK: - Keynote failure

    func testKeynoteNotInstalledIsReportedAsKeynoteImportFailure() throws {
        // Force "Keynote not installed" via the workspace provider seam.
        KeynoteImporter.workspaceProvider = { _ in nil }

        let key = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-\(UUID().uuidString).key")
        try Data().write(to: key)
        defer { try? FileManager.default.removeItem(at: key) }

        let dest = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: dest
        )
        let report = MediaImporter.importSlidesAndReport(from: [key], context: context)
        XCTAssertEqual(report.slides, [])
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.kind, .keynoteImport)
        XCTAssertEqual(report.failures.first?.url, key)
    }

    func testKeynoteExporterThrowingIsReportedAsKeynoteImportFailure() throws {
        struct FakeError: LocalizedError {
            var errorDescription: String? { "fake AppleScript error" }
        }
        MediaImporter.keynoteExporter = { _, _ in throw FakeError() }

        let key = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-\(UUID().uuidString).key")
        try Data().write(to: key)
        defer { try? FileManager.default.removeItem(at: key) }

        let dest = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: dest
        )
        let report = MediaImporter.importSlidesAndReport(from: [key], context: context)
        XCTAssertEqual(report.slides, [])
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.kind, .keynoteImport)
        XCTAssertTrue(report.failures.first?.summary.contains("fake AppleScript error") ?? false,
                      "Failure summary should propagate the underlying error description.")
    }

    // MARK: - Mixed batch

    func testMixedBatchSeparatesSlidesAndFailures() throws {
        let still = try makeStillPNG(size: CGSize(width: 32, height: 32))
        defer { try? FileManager.default.removeItem(at: still) }

        let bogusPDF = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).pdf")
        try Data([0x00]).write(to: bogusPDF)
        defer { try? FileManager.default.removeItem(at: bogusPDF) }

        let unsupported = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(UUID().uuidString).txt")
        try? "x".write(to: unsupported, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: unsupported) }

        let dest = tempSubdirectory()
        defer { try? FileManager.default.removeItem(at: dest) }

        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: dest
        )

        let report = MediaImporter.importSlidesAndReport(
            from: [still, bogusPDF, unsupported],
            context: context
        )

        // Healthy item still imports.
        XCTAssertEqual(report.slides.count, 1)

        // Failures collected, keyed by URL — operator can identify which file failed.
        XCTAssertEqual(report.failures.count, 2)
        let kindsByURL = Dictionary(uniqueKeysWithValues: report.failures.map { ($0.url, $0.kind) })
        XCTAssertEqual(kindsByURL[bogusPDF], .pdfImport)
        XCTAssertEqual(kindsByURL[unsupported], .unsupportedMedia)
    }

    // MARK: - Back-compat: importSlides delegates to importSlidesAndReport

    func testImportSlidesReturnsSlidesOnlyAndDiscardsFailures() throws {
        let still = try makeStillPNG(size: CGSize(width: 32, height: 32))
        defer { try? FileManager.default.removeItem(at: still) }

        let unsupported = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(UUID().uuidString).txt")
        try? "x".write(to: unsupported, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: unsupported) }

        let slides = MediaImporter.importSlides(from: [still, unsupported])
        XCTAssertEqual(slides.count, 1, "importSlides keeps only the slides; failures discarded for back-compat callers.")
    }

    // MARK: - Helpers

    private func tempSubdirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaImportFailureTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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
            .appendingPathComponent("MediaImportFailureTests-\(UUID().uuidString).png")
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
