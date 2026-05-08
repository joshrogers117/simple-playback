import Foundation
import XCTest
@testable import Simple_Playback

final class KeynoteImporterTests: XCTestCase {

    // workspaceProvider is global state on the type; restore it between tests so any test
    // that swaps it doesn't leak into another suite.
    private var savedWorkspaceProvider: (String) -> URL? = { _ in nil }

    override func setUp() {
        super.setUp()
        savedWorkspaceProvider = KeynoteImporter.workspaceProvider
    }

    override func tearDown() {
        KeynoteImporter.workspaceProvider = savedWorkspaceProvider
        super.tearDown()
    }

    // MARK: - bundle ID

    func testKeynoteBundleIDMatchesApplesIdentifier() {
        XCTAssertEqual(KeynoteImporter.keynoteBundleIdentifier, "com.apple.iWork.Keynote",
                       "Apple ships Keynote under com.apple.iWork.Keynote — changing this " +
                       "would break detection without an explicit reason.")
    }

    // MARK: - isKeynoteInstalled

    func testIsKeynoteInstalledTrueWhenWorkspaceProviderReturnsURL() {
        KeynoteImporter.workspaceProvider = { _ in URL(fileURLWithPath: "/Applications/Keynote.app") }
        XCTAssertTrue(KeynoteImporter.isKeynoteInstalled())
    }

    func testIsKeynoteInstalledFalseWhenWorkspaceProviderReturnsNil() {
        KeynoteImporter.workspaceProvider = { _ in nil }
        XCTAssertFalse(KeynoteImporter.isKeynoteInstalled())
    }

    func testIsKeynoteInstalledQueriesTheKeynoteBundleID() {
        var queried: String?
        KeynoteImporter.workspaceProvider = { bundleID in
            queried = bundleID
            return nil
        }
        _ = KeynoteImporter.isKeynoteInstalled()
        XCTAssertEqual(queried, "com.apple.iWork.Keynote")
    }

    // MARK: - exportToPDF: error paths (Keynote-absent does not need real Keynote)

    func testExportToPDFThrowsKeynoteNotInstalledWhenAbsent() {
        KeynoteImporter.workspaceProvider = { _ in nil }
        let key = URL(fileURLWithPath: "/tmp/sample.key")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeynoteImporterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        XCTAssertThrowsError(
            try KeynoteImporter.exportToPDF(keynoteURL: key, destinationDirectory: dest)
        ) { error in
            guard case KeynoteImportError.keynoteNotInstalled = error else {
                return XCTFail("Expected .keynoteNotInstalled, got \(error)")
            }
        }
    }

    func testExportToPDFThrowsUnreadableWhenSourceMissing() {
        KeynoteImporter.workspaceProvider = { _ in URL(fileURLWithPath: "/Applications/Keynote.app") }
        let key = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).key")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeynoteImporterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        XCTAssertThrowsError(
            try KeynoteImporter.exportToPDF(keynoteURL: key, destinationDirectory: dest)
        ) { error in
            guard case KeynoteImportError.unreadable = error else {
                return XCTFail("Expected .unreadable, got \(error)")
            }
        }
    }

    // MARK: - AppleScript shape

    func testExportAppleScriptIsKeynoteTellBlock() {
        let key = URL(fileURLWithPath: "/tmp/deck.key")
        let pdf = URL(fileURLWithPath: "/tmp/out/deck.pdf")
        let source = KeynoteImporter.exportAppleScript(keynoteURL: key, pdfURL: pdf)
        XCTAssertTrue(source.contains("tell application \"Keynote\""),
                      "AppleScript should target Keynote by application name.")
        XCTAssertTrue(source.contains("end tell"))
    }

    func testExportAppleScriptOpensSourceAndExportsToPDF() {
        let key = URL(fileURLWithPath: "/tmp/deck.key")
        let pdf = URL(fileURLWithPath: "/tmp/out/deck.pdf")
        let source = KeynoteImporter.exportAppleScript(keynoteURL: key, pdfURL: pdf)
        XCTAssertTrue(source.contains("open POSIX file \"/tmp/deck.key\""),
                      "Should open the source via POSIX file path.")
        XCTAssertTrue(source.contains("export theDoc to POSIX file \"/tmp/out/deck.pdf\" as PDF"),
                      "Should export to the destination PDF via POSIX file path.")
        XCTAssertTrue(source.contains("close theDoc saving no"),
                      "Should close the document without saving — operator's deck remains untouched.")
    }

    func testExportAppleScriptEscapesQuotesAndBackslashes() {
        // POSIX paths can contain odd characters; the AppleScript string-literal escape
        // must turn `"` into `\"` and `\` into `\\` so Keynote parses the path correctly.
        let key = URL(fileURLWithPath: "/tmp/weird path/deck \"v2\".key")
        let pdf = URL(fileURLWithPath: "/tmp/out/x.pdf")
        let source = KeynoteImporter.exportAppleScript(keynoteURL: key, pdfURL: pdf)
        XCTAssertTrue(source.contains("deck \\\"v2\\\".key"),
                      "Quotes inside the source path should be escaped for AppleScript.")
    }
}
