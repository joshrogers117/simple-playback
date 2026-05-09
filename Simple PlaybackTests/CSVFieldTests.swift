import Foundation
import XCTest
@testable import Simple_Playback

/// Pin RFC 4180 field-quoting in the shared `Support/CSVField.swift` helper.
/// Both `ShowLog.csvLine` and `PostShowCSVExporter.csvField` now delegate
/// here, so any new CSV-emitting service inherits the same contract.
@MainActor
final class CSVFieldTests: XCTestCase {

    func testFieldsWithNoSpecialCharsPassThroughUnchanged() {
        XCTAssertEqual(CSVField.quoted("plain"), "plain")
        XCTAssertEqual(CSVField.quoted(""), "")
        XCTAssertEqual(CSVField.quoted("Q.1"), "Q.1")
    }

    func testFieldsWithCommaAreWrappedInQuotes() {
        XCTAssertEqual(CSVField.quoted("a,b"), "\"a,b\"")
    }

    func testFieldsWithEmbeddedQuotesAreDoubledAndWrapped() {
        XCTAssertEqual(CSVField.quoted("a\"b"), "\"a\"\"b\"")
    }

    func testFieldsWithLFAreWrappedInQuotes() {
        XCTAssertEqual(CSVField.quoted("line1\nline2"), "\"line1\nline2\"")
    }

    func testFieldsWithCRAreWrappedInQuotes() {
        // Windows-pasted notes can carry `\r\n`. The pre-consolidation
        // ShowLog helper missed `\r` and would have produced an unquoted
        // multi-line cell that downstream parsers split across rows.
        XCTAssertEqual(CSVField.quoted("line1\rline2"), "\"line1\rline2\"")
    }

    func testFieldsWithCRLFAreWrappedInQuotes() {
        XCTAssertEqual(CSVField.quoted("line1\r\nline2"), "\"line1\r\nline2\"")
    }

    func testCombinedSpecialCharsAreEscapedTogether() {
        // a comma + an embedded quote in one cell.
        let input = "Cue 1, \"reload\""
        XCTAssertEqual(CSVField.quoted(input), "\"Cue 1, \"\"reload\"\"\"")
    }
}
