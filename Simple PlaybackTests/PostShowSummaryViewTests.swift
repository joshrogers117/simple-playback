import Foundation
import XCTest
@testable import Simple_Playback

/// v2 Post-Show Summary — pin the view's per-export-format file metadata so
/// the Save sheet doesn't silently drop the wrong UTI / extension. The view
/// itself is mostly SwiftUI chrome; the test seam is the (contents, format)
/// pair the saveAction closure receives + the format value's user-visible
/// strings.
@MainActor
final class PostShowSummaryViewTests: XCTestCase {

    func testMarkdownFormatExtensionIsMD() {
        XCTAssertEqual(PostShowSummaryView.ExportFormat.markdown.fileExtension, "md")
    }

    func testCSVFormatExtensionIsCSV() {
        XCTAssertEqual(PostShowSummaryView.ExportFormat.csv.fileExtension, "csv")
    }

    func testMarkdownFormatDisplayName() {
        XCTAssertEqual(PostShowSummaryView.ExportFormat.markdown.displayName, "Markdown")
    }

    func testCSVFormatDisplayName() {
        XCTAssertEqual(PostShowSummaryView.ExportFormat.csv.displayName, "CSV")
    }

    func testMarkdownFormatContentTypeIsPlainText() {
        // Markdown isn't a registered macOS UTI; plainText is the safe parent.
        XCTAssertEqual(PostShowSummaryView.ExportFormat.markdown.contentType, .plainText)
    }

    func testCSVFormatContentTypeIsCommaSeparatedText() {
        XCTAssertEqual(PostShowSummaryView.ExportFormat.csv.contentType, .commaSeparatedText)
    }
}
