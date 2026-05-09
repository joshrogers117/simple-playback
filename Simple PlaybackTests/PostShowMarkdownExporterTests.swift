import Foundation
import XCTest
@testable import Simple_Playback

/// v2 Post-Show Summary — pin the Markdown exporter's section ordering, table
/// shape, and edge-case rendering. The output is the operator-facing post-show
/// artifact (paste into email, share with producer); shape changes are
/// breaking from a downstream-tool perspective, so tests pin the format.
@MainActor
final class PostShowMarkdownExporterTests: XCTestCase {

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

    // MARK: - Sections present

    func testEmptySummaryRendersAllSectionHeadings() {
        let md = PostShowMarkdownExporter.export(.empty)
        XCTAssertTrue(md.contains("# Post-Show Summary"))
        XCTAssertTrue(md.contains("## Totals"))
        XCTAssertTrue(md.contains("## Cue Stats"))
        XCTAssertTrue(md.contains("## Take Latency Histogram"))
        XCTAssertTrue(md.contains("## Drop Events"))
        XCTAssertTrue(md.contains("## Late Takes"))
        XCTAssertTrue(md.contains("## System Events"))
        XCTAssertTrue(md.contains("## Source Mix"))
    }

    func testEmptySectionsRenderNoneSentinel() {
        let md = PostShowMarkdownExporter.export(.empty)
        // Each empty data-bearing section uses _(none)_.
        XCTAssertTrue(md.contains("_(none)_"))
    }

    // MARK: - Cue stats table

    func testCueStatsTableRendersDescriptorFiresAndDuration() {
        let summary = PostShowSummary.from(events: [
            event(.go, offset: 0, detail: "Q.1"),
            event(.cueEnded, offset: 5.0, source: .system, detail: "Q.1")
        ])
        let md = PostShowMarkdownExporter.export(summary)
        XCTAssertTrue(md.contains("| Cue | Fires | Paired | Avg runtime | Total runtime |"))
        XCTAssertTrue(md.contains("| Q.1 | 1 | 1 | 5.0s | 5.0s |"))
    }

    func testCueStatsRendersDashForUnpairedAvgAndTotal() {
        let summary = PostShowSummary.from(events: [
            event(.go, offset: 0, detail: "Q.runaway")
        ])
        let md = PostShowMarkdownExporter.export(summary)
        XCTAssertTrue(md.contains("Q.runaway"))
        XCTAssertTrue(md.contains("| Q.runaway | 1 | 0 | — | — |"))
    }

    // MARK: - Histogram

    func testHistogramRendersAllFiveBucketsWhenNonEmpty() {
        let summary = PostShowSummary.from(events: [
            event(.takeLatency, offset: 1, source: .system, detail: "latency=20ms cue=A"),
            event(.takeLatency, offset: 2, source: .system, detail: "latency=300ms cue=A")
        ])
        let md = PostShowMarkdownExporter.export(summary)
        XCTAssertTrue(md.contains("| <50ms | 1 |"))
        XCTAssertTrue(md.contains("| 50-100ms | 0 |"))
        XCTAssertTrue(md.contains("| 100-200ms | 0 |"))
        XCTAssertTrue(md.contains("| 200-500ms | 1 |"))
        XCTAssertTrue(md.contains("| ≥500ms | 0 |"))
        XCTAssertTrue(md.contains("**Total samples:** 2"))
    }

    // MARK: - Drop events / late takes

    func testDropEventsTableRendersDetailVerbatim() {
        let summary = PostShowSummary.from(events: [
            event(.droppedFrame, offset: 1, source: .system, detail: "drops=3 cumulative=5")
        ])
        let md = PostShowMarkdownExporter.export(summary)
        XCTAssertTrue(md.contains("## Drop Events (1)"))
        XCTAssertTrue(md.contains("| Time | Detail |"))
        XCTAssertTrue(md.contains("drops=3 cumulative=5"))
    }

    func testLateTakesTableRendersCueAndLatency() {
        let summary = PostShowSummary.from(events: [
            event(.lateTake, offset: 1, source: .system, detail: "latency=420ms cue=Bumper")
        ])
        let md = PostShowMarkdownExporter.export(summary)
        XCTAssertTrue(md.contains("## Late Takes (1)"))
        XCTAssertTrue(md.contains("| Bumper | 420ms |"))
    }

    // MARK: - System events

    func testSystemEventsTableRendersActionAndDetail() {
        let summary = PostShowSummary.from(events: [
            event(.missingMedia, offset: 1, source: .system, detail: "Q.bad")
        ])
        let md = PostShowMarkdownExporter.export(summary)
        XCTAssertTrue(md.contains("## System Events (1)"))
        XCTAssertTrue(md.contains("MISSING_MEDIA"))
        XCTAssertTrue(md.contains("Q.bad"))
    }

    // MARK: - Source mix bullets

    func testSourceMixIncludesAllBucketsAndTotal() {
        let summary = PostShowSummary.from(events: [
            event(.go, offset: 0, source: .localHotkey, detail: "1"),
            event(.go, offset: 1, source: .osc(host: "x", port: 1), detail: "2")
        ])
        let md = PostShowMarkdownExporter.export(summary)
        XCTAssertTrue(md.contains("- Local: 1"))
        XCTAssertTrue(md.contains("- OSC: 1"))
        XCTAssertTrue(md.contains("- HTTP: 0"))
        XCTAssertTrue(md.contains("- Timecode: 0"))
        XCTAssertTrue(md.contains("- System: 0"))
        XCTAssertTrue(md.contains("- **Total:** 2"))
    }

    // MARK: - Formatters

    func testDurationUnder60SecondsRendersAsSeconds() {
        XCTAssertEqual(PostShowMarkdownExporter.formatDuration(5.0), "5.0s")
        XCTAssertEqual(PostShowMarkdownExporter.formatDuration(59.9), "59.9s")
    }

    func testDurationOver60SecondsRendersWithMinutes() {
        XCTAssertEqual(PostShowMarkdownExporter.formatDuration(60.0), "1m0.0s")
        XCTAssertEqual(PostShowMarkdownExporter.formatDuration(125.5), "2m5.5s")
    }

    func testDurationOver1HourRendersWithHours() {
        XCTAssertEqual(PostShowMarkdownExporter.formatDuration(3600.0), "1h0m0.0s")
        XCTAssertEqual(PostShowMarkdownExporter.formatDuration(3725.5), "1h2m5.5s")
    }

    func testDurationNegativeOrNaNRendersZero() {
        XCTAssertEqual(PostShowMarkdownExporter.formatDuration(-1.0), "0.0s")
        XCTAssertEqual(PostShowMarkdownExporter.formatDuration(.nan), "0.0s")
    }

    // MARK: - Cell escaping

    func testCellEscapesPipesAndNewlinesInDetail() {
        let summary = PostShowSummary.from(events: [
            event(.missingMedia, offset: 1, source: .system, detail: "weird | path\nsplit")
        ])
        let md = PostShowMarkdownExporter.export(summary)
        XCTAssertTrue(md.contains("weird \\| path split"),
                      "Pipe must be escaped; newline must collapse to space.")
    }

    // MARK: - Window header

    func testWindowHeaderIncludesElapsedDuration() {
        let summary = PostShowSummary.from(events: [
            event(.go, offset: 0, detail: "1"),
            event(.cueEnded, offset: 90.0, source: .system, detail: "1")
        ])
        let md = PostShowMarkdownExporter.export(summary)
        XCTAssertTrue(md.contains("**Elapsed:** 1m30.0s"),
                      "Elapsed must render via the duration formatter.")
    }
}
