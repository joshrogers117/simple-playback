import Foundation
import XCTest
@testable import Simple_Playback

/// v2 Post-Show Summary — pin the CSV exporter's section ordering, RFC 4180
/// quoting, and per-section column shape. The CSV is the producer-facing
/// post-show artifact; downstream spreadsheet templates depend on column
/// names + ordering, so tests fix the contract.
@MainActor
final class PostShowCSVExporterTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func event(
        _ action: ShowLogEvent.Action,
        offset: TimeInterval = 0,
        source: ShowLogEvent.Source = .localHotkey,
        detail: String? = nil
    ) -> ShowLogEvent {
        ShowLogEvent(
            timestamp: t0.addingTimeInterval(offset),
            chaseTimecode: nil,
            action: action,
            source: source,
            detail: detail
        )
    }

    // MARK: - Section presence + ordering

    func testAllSectionsPresentInFixedOrder() {
        let csv = PostShowCSVExporter.export(.empty)
        let sections = [
            "# Section: Window",
            "# Section: Totals",
            "# Section: CueStats",
            "# Section: LatencyHistogram",
            "# Section: DropEvents",
            "# Section: LateTakes",
            "# Section: SystemEvents",
            "# Section: SourceMix"
        ]
        // Pin order by walking the offsets — each must appear after the prior.
        var lastIndex: String.Index = csv.startIndex
        for section in sections {
            guard let range = csv.range(of: section, range: lastIndex..<csv.endIndex) else {
                XCTFail("Section \(section) not found at or after lastIndex.")
                return
            }
            lastIndex = range.upperBound
        }
    }

    // MARK: - Window section

    func testWindowSectionIncludesStartedEndedElapsedAndTotalEvents() {
        let summary = PostShowSummary.from(events: [
            event(.go, offset: 0, detail: "1"),
            event(.cueEnded, offset: 60, source: .system, detail: "1")
        ])
        let csv = PostShowCSVExporter.export(summary)
        XCTAssertTrue(csv.contains("Started,"))
        XCTAssertTrue(csv.contains("Ended,"))
        XCTAssertTrue(csv.contains("ElapsedSeconds,60.000"))
        XCTAssertTrue(csv.contains("TotalEvents,2"))
    }

    // MARK: - Totals section

    func testTotalsSectionEmitsAllVerbs() {
        let summary = PostShowSummary.from(events: [
            event(.go, offset: 0, detail: "1"),
            event(.go, offset: 1, detail: "2"),
            event(.panic, offset: 2)
        ])
        let csv = PostShowCSVExporter.export(summary)
        XCTAssertTrue(csv.contains("GO,2"))
        XCTAssertTrue(csv.contains("PREVIOUS,0"))
        XCTAssertTrue(csv.contains("PANIC,1"))
        XCTAssertTrue(csv.contains("SHOW_MODE_TOGGLES,0"))
    }

    // MARK: - CueStats section

    func testCueStatsRowEmitsAllFiveColumnsWithFormattedNumbers() {
        let summary = PostShowSummary.from(events: [
            event(.go, offset: 0, detail: "Q.1"),
            event(.cueEnded, offset: 30.5, source: .system, detail: "Q.1")
        ])
        let csv = PostShowCSVExporter.export(summary)
        XCTAssertTrue(csv.contains("Cue,Fires,Paired,AvgRuntimeSeconds,TotalRuntimeSeconds"))
        XCTAssertTrue(csv.contains("Q.1,1,1,30.500,30.500"))
    }

    func testCueStatsAvgRuntimeIsEmptyWhenUnpaired() {
        let summary = PostShowSummary.from(events: [
            event(.go, offset: 0, detail: "running")
        ])
        let csv = PostShowCSVExporter.export(summary)
        XCTAssertTrue(csv.contains("running,1,0,,0.000"),
                      "Unpaired cue gets empty AvgRuntimeSeconds, zero TotalRuntimeSeconds.")
    }

    func testCueStatsDescriptorWithCommaIsQuoted() {
        let summary = PostShowSummary.from(events: [
            event(.go, offset: 0, detail: "Q,WithComma")
        ])
        let csv = PostShowCSVExporter.export(summary)
        XCTAssertTrue(csv.contains("\"Q,WithComma\","))
    }

    // MARK: - Histogram section

    func testHistogramRowsHaveStableOrderAndLabels() {
        let csv = PostShowCSVExporter.export(.empty)
        let bucketRows = ["Under50ms,0", "50to100ms,0", "100to200ms,0", "200to500ms,0", "Over500ms,0"]
        var lastIndex: String.Index = csv.startIndex
        for row in bucketRows {
            guard let r = csv.range(of: row, range: lastIndex..<csv.endIndex) else {
                XCTFail("Histogram row \(row) missing.")
                return
            }
            lastIndex = r.upperBound
        }
    }

    // MARK: - Drop / late-take / system-event sections

    func testDropEventsRowFormatTimestampDetail() {
        let summary = PostShowSummary.from(events: [
            event(.droppedFrame, offset: 1, source: .system, detail: "drops=2 cumulative=2")
        ])
        let csv = PostShowCSVExporter.export(summary)
        XCTAssertTrue(csv.contains("Timestamp,Detail"))
        XCTAssertTrue(csv.contains("drops=2 cumulative=2"))
    }

    func testLateTakesRowFormatTimestampCueLatencyMS() {
        let summary = PostShowSummary.from(events: [
            event(.lateTake, offset: 1, source: .system, detail: "latency=210ms cue=Q.5")
        ])
        let csv = PostShowCSVExporter.export(summary)
        XCTAssertTrue(csv.contains("Timestamp,Cue,LatencyMS"))
        XCTAssertTrue(csv.contains(",Q.5,210"))
    }

    func testSystemEventsRowFormatTimestampActionDetail() {
        let summary = PostShowSummary.from(events: [
            event(.missingMedia, offset: 1, source: .system, detail: "Q.bad")
        ])
        let csv = PostShowCSVExporter.export(summary)
        XCTAssertTrue(csv.contains("Timestamp,Action,Detail"))
        XCTAssertTrue(csv.contains(",MISSING_MEDIA,Q.bad"))
    }

    // MARK: - SourceMix section

    func testSourceMixSectionIncludesAllFiveBuckets() {
        let summary = PostShowSummary.from(events: [
            event(.go, offset: 0, source: .localHotkey, detail: "1"),
            event(.go, offset: 1, source: .osc(host: "h", port: 1), detail: "2")
        ])
        let csv = PostShowCSVExporter.export(summary)
        XCTAssertTrue(csv.contains("Local,1"))
        XCTAssertTrue(csv.contains("OSC,1"))
        XCTAssertTrue(csv.contains("HTTP,0"))
        XCTAssertTrue(csv.contains("Timecode,0"))
        XCTAssertTrue(csv.contains("System,0"))
    }

    // MARK: - RFC 4180 quoting

    func testCSVQuotesCommaInDetailField() {
        let summary = PostShowSummary.from(events: [
            event(.missingMedia, offset: 1, source: .system, detail: "weird, path")
        ])
        let csv = PostShowCSVExporter.export(summary)
        XCTAssertTrue(csv.contains("\"weird, path\""))
    }

    func testCSVDoublesEmbeddedQuotes() {
        let summary = PostShowSummary.from(events: [
            event(.missingMedia, offset: 1, source: .system, detail: "title with \"quotes\"")
        ])
        let csv = PostShowCSVExporter.export(summary)
        XCTAssertTrue(csv.contains("\"title with \"\"quotes\"\"\""))
    }

    func testCSVEndsWithTrailingNewline() {
        let csv = PostShowCSVExporter.export(.empty)
        XCTAssertTrue(csv.hasSuffix("\n"),
                      "Trailing newline so concat-into-bigger-doc stays well-formed.")
    }
}
