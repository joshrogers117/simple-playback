import AppKit
import Foundation

enum KeynoteImportError: LocalizedError {
    case keynoteNotInstalled
    case unreadable(URL)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .keynoteNotInstalled:
            "Keynote not installed — install Keynote to import .key files"
        case .unreadable(let url):
            "Keynote file could not be opened: \(url.lastPathComponent)"
        case .exportFailed(let reason):
            "Keynote could not export the file: \(reason)"
        }
    }
}

/// Drives Keynote to export a `.key` deck to PDF, reusing the C3 rasterize plumbing
/// downstream. Spec §3.10: "Keynote `.key` — AppleScript-driven Keynote → PDF → bitmaps.
/// Surface a clear 'Keynote not installed' diagnostic if absent."
///
/// AppleScript-driving-Keynote is fundamentally untestable in isolation (no real Keynote in
/// CI). The unit tests pin the AppleScript shape, the install-detection branch, and the
/// error mapping. Live-Keynote verification belongs to manual rehearsal.
enum KeynoteImporter {

    static let keynoteBundleIdentifier = "com.apple.iWork.Keynote"

    /// Indirection so tests can simulate Keynote installed/absent without depending on the
    /// host machine. Default goes straight to NSWorkspace.
    static var workspaceProvider: (String) -> URL? = { bundleID in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func isKeynoteInstalled() -> Bool {
        workspaceProvider(keynoteBundleIdentifier) != nil
    }

    /// Exports `keynoteURL` to a single PDF inside `destinationDirectory`. Returns the URL
    /// of the written PDF. Synchronous; runs on the import thread. The directory is created
    /// on demand. The output filename is `<deck-name>.pdf`.
    @discardableResult
    static func exportToPDF(keynoteURL: URL, destinationDirectory: URL) throws -> URL {
        guard isKeynoteInstalled() else {
            throw KeynoteImportError.keynoteNotInstalled
        }
        guard FileManager.default.fileExists(atPath: keynoteURL.path) else {
            throw KeynoteImportError.unreadable(keynoteURL)
        }
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let pdfURL = destinationDirectory
            .appendingPathComponent("\(keynoteURL.deletingPathExtension().lastPathComponent).pdf")

        let source = exportAppleScript(keynoteURL: keynoteURL, pdfURL: pdfURL)
        try runAppleScript(source: source)

        guard FileManager.default.fileExists(atPath: pdfURL.path) else {
            throw KeynoteImportError.exportFailed("Keynote did not produce a PDF at \(pdfURL.path)")
        }
        return pdfURL
    }

    /// AppleScript text that Keynote interprets. Pure-string output so tests can pin the
    /// shape without invoking the scripting bridge. Paths are escaped for AppleScript
    /// string literals (backslashes and double quotes).
    static func exportAppleScript(keynoteURL: URL, pdfURL: URL) -> String {
        let keyPath = appleScriptEscape(keynoteURL.path)
        let outPath = appleScriptEscape(pdfURL.path)
        return """
        tell application "Keynote"
            activate
            set theDoc to open POSIX file "\(keyPath)"
            export theDoc to POSIX file "\(outPath)" as PDF
            close theDoc saving no
        end tell
        """
    }

    private static func appleScriptEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(source: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw KeynoteImportError.exportFailed("could not parse AppleScript")
        }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? errorInfo[NSAppleScript.errorBriefMessage] as? String
                ?? "unknown error"
            throw KeynoteImportError.exportFailed(message)
        }
    }
}
