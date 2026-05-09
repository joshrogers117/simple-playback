import Foundation
import XCTest
@testable import Simple_Playback

/// v2 Post-Show Summary — pin the reducer's per-section behaviour. The reducer
/// is the load-bearing piece of the post-show feature; renames or shape
/// changes downstream rely on these tests catching regressions.
@MainActor
final class PostShowSummaryTests: XCTestCase {

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

    // MARK: - Empty / minimal

    func testEmptyEventsProducesEmptySummary() {
        let summary = PostShowSummary.from(events: [])
        XCTAssertEqual(summary, .empty)
        XCTAssertEqual(summary.totalGOs, 0)
        XCTAssertNil(summary.showStartedAt)
        XCTAssertNil(summary.elapsedSeconds)
    }

    func testSingleGOProducesOneFireAndOneCueStatRow() {
        let summary = PostShowSummary.from(events: [
            event(.go, detail: "Q.1")
        ])
        XCTAssertEqual(summary.totalGOs, 1)
        XCTAssertEqual(summary.cueStats.count, 1)
        XCTAssertEqual(summary.cueStats.first?.descriptor, "Q.1")
        XCTAssertEqual(summary.cueStats.first?.fires, 1)
        XCTAssertEqual(summary.cueStats.first?.pairedCount, 0)
        XCTAssertNil(summary.cueStats.first?.averageRuntimeSeconds)
    }

    // MARK: - Top-line counters

    func testTopLineCountersCountOneOfEachVerb() {
        let summary = PostShowSummary.from(events: [
            event(.go, detail: "1"),
            event(.previous, offset: 1),
            event(.panic, offset: 2),
            event(.clear, offset: 3),
            event(.blackout, offset: 4),
            event(.showModeOn, offset: 5),
            event(.showModeOff, offset: 6)
        ])
        XCTAssertEqual(summary.totalGOs, 1)
        XCTAssertEqual(summary.totalPreviouses, 1)
        XCTAssertEqual(summary.totalPanics, 1)
        XCTAssertEqual(summary.totalClears, 1)
        XCTAssertEqual(summary.totalBlackouts, 1)
        XCTAssertEqual(summary.totalShowModeToggles, 2, "On + Off both bump.")
        XCTAssertEqual(summary.totalEventCount, 7)
    }

    // MARK: - Per-cue runtime pairing

    func testCueStatsPairsGoAndCueEndedToProduceRuntime() {
        let summary = PostShowSummary.from(events: [
            event(.go, offset: 0, detail: "Q.1"),
            event(.cueEnded, offset: 5.0, source: .system, detail: "Q.1")
        ])
        let stats = summary.cueStats.first
        XCTAssertEqual(stats?.fires, 1)
        XCTAssertEqual(stats?.pairedCount, 1)
        XCTAssertEqual(stats?.totalRuntimeSeconds ?? 0, 5.0, accuracy: 0.001)
        XCTAssertEqual(stats?.averageRuntimeSeconds ?? 0, 5.0, accuracy: 0.001)
    }

    func testCueStatsPairingIsCaseInsensitive() {
        // .go uses "Q.1" but .cueEnded uses "q.1" — A2 cue IDs are
        // case-insensitive; the reducer must match them.
        let summary = PostShowSummary.from(events: [
            event(.go, offset: 0, detail: "Q.1"),
            event(.cueEnded, offset: 3.0, source: .system, detail: "q.1")
        ])
        XCTAssertEqual(summary.cueStats.count, 1)
        XCTAssertEqual(summary.cueStats.first?.pairedCount, 1)
    }

    func testCueStatsPairsTwoFiresOfSameCueFIFO() {
        // Cue Q.1 fires twice; .cueEnded events arrive in fire order.
        // First pair: 0 → 2 (2s). Second pair: 5 → 8 (3s). Avg 2.5s.
        let summary = PostShowSummary.from(events: [
            event(.go, offset: 0, detail: "Q.1"),
            event(.cueEnded, offset: 2.0, source: .system, detail: "Q.1"),
            event(.go, offset: 5.0, detail: "Q.1"),
            event(.cueEnded, offset: 8.0, source: .system, detail: "Q.1")
        ])
        let stats = summary.cueStats.first
        XCTAssertEqual(stats?.fires, 2)
        XCTAssertEqual(stats?.pairedCount, 2)
        XCTAssertEqual(stats?.totalRuntimeSeconds ?? 0, 5.0, accuracy: 0.001)
        XCTAssertEqual(stats?.averageRuntimeSeconds ?? 0, 2.5, accuracy: 0.001)
    }

    func testGoWithNoCueEndedContributesZeroRuntimeButCountsAsFire() {
        let summary = PostShowSummary.from(events: [
            event(.go, offset: 0, detail: "Q.1") // never ends in window
        ])
        let stats = summary.cueStats.first
        XCTAssertEqual(stats?.fires, 1)
        XCTAssertEqual(stats?.pairedCount, 0)
        XCTAssertEqual(stats?.totalRuntimeSeconds, 0.0)
        XCTAssertNil(stats?.averageRuntimeSeconds)
    }

    func testOrphanCueEndedIsIgnored() {
        // .cueEnded with no preceding .go — common when window starts
        // mid-show. Reducer must drop silently.
        let summary = PostShowSummary.from(events: [
            event(.cueEnded, offset: 0, source: .system, detail: "Q.1")
        ])
        XCTAssertEqual(summary.cueStats.count, 0)
    }

    func testDifferentCuesGetDifferentRows() {
        let summary = PostShowSummary.from(events: [
            event(.go, offset: 0, detail: "Q.1"),
            event(.go, offset: 1, detail: "Q.2"),
            event(.cueEnded, offset: 2, source: .system, detail: "Q.1"),
            event(.cueEnded, offset: 3, source: .system, detail: "Q.2")
        ])
        XCTAssertEqual(summary.cueStats.count, 2)
        XCTAssertEqual(summary.cueStats[0].descriptor, "Q.1")
        XCTAssertEqual(summary.cueStats[1].descriptor, "Q.2")
    }

    // MARK: - Drop / late-take detail

    func testDropEventsAreCollectedVerbatim() {
        let summary = PostShowSummary.from(events: [
            event(.droppedFrame, offset: 1, source: .system, detail: "drops=3 cumulative=3"),
            event(.droppedFrame, offset: 5, source: .system, detail: "drops=1 cumulative=4")
        ])
        XCTAssertEqual(summary.dropEvents.count, 2)
        XCTAssertEqual(summary.dropEvents.first?.detail, "drops=3 cumulative=3")
    }

    func testLateTakeEventsParseLatencyAndDescriptor() {
        let summary = PostShowSummary.from(events: [
            event(.lateTake, offset: 1, source: .system, detail: "latency=300ms cue=Q.1"),
            event(.lateTake, offset: 5, source: .system, detail: "latency=420ms cue=Bumper")
        ])
        XCTAssertEqual(summary.lateTakeEvents.count, 2)
        XCTAssertEqual(summary.lateTakeEvents.first?.latencyMS, 300)
        XCTAssertEqual(summary.lateTakeEvents.first?.cueDescriptor, "Q.1")
        XCTAssertEqual(summary.lateTakeEvents.last?.cueDescriptor, "Bumper")
    }

    func testLateTakeMalformedDetailIsSkipped() {
        // Don't crash on a malformed row — drop it and continue.
        let summary = PostShowSummary.from(events: [
            event(.lateTake, offset: 1, source: .system, detail: "garbage")
        ])
        XCTAssertEqual(summary.lateTakeEvents.count, 0)
    }

    // MARK: - Latency histogram

    func testLatencyHistogramBucketsTakeLatencyEvents() {
        let summary = PostShowSummary.from(events: [
            event(.takeLatency, offset: 1, source: .system, detail: "latency=20ms cue=A"),
            event(.takeLatency, offset: 2, source: .system, detail: "latency=49ms cue=A"),
            event(.takeLatency, offset: 3, source: .system, detail: "latency=50ms cue=A"),
            event(.takeLatency, offset: 4, source: .system, detail: "latency=99ms cue=A"),
            event(.takeLatency, offset: 5, source: .system, detail: "latency=100ms cue=A"),
            event(.takeLatency, offset: 6, source: .system, detail: "latency=199ms cue=A"),
            event(.takeLatency, offset: 7, source: .system, detail: "latency=200ms cue=A"),
            event(.takeLatency, offset: 8, source: .system, detail: "latency=499ms cue=A"),
            event(.takeLatency, offset: 9, source: .system, detail: "latency=500ms cue=A"),
            event(.takeLatency, offset: 10, source: .system, detail: "latency=10000ms cue=A")
        ])
        let h = summary.latencyHistogram
        XCTAssertEqual(h.under50ms, 2)
        XCTAssertEqual(h.from50to100ms, 2)
        XCTAssertEqual(h.from100to200ms, 2)
        XCTAssertEqual(h.from200to500ms, 2)
        XCTAssertEqual(h.over500ms, 2)
        XCTAssertEqual(h.totalSamples, 10)
    }

    func testLatencyHistogramIgnoresMalformedDetail() {
        let summary = PostShowSummary.from(events: [
            event(.takeLatency, offset: 1, source: .system, detail: "garbage"),
            event(.takeLatency, offset: 2, source: .system, detail: nil)
        ])
        XCTAssertEqual(summary.latencyHistogram.totalSamples, 0)
    }

    // MARK: - System events

    func testMissingMediaLandsInSystemEvents() {
        let summary = PostShowSummary.from(events: [
            event(.missingMedia, offset: 1, source: .system, detail: "Q.bad")
        ])
        XCTAssertEqual(summary.systemEvents.count, 1)
        XCTAssertEqual(summary.systemEvents.first?.action, .missingMedia)
        XCTAssertEqual(summary.systemEvents.first?.detail, "Q.bad")
    }

    func testDroppedFrameAndLateTakeDoNotDuplicateInSystemEvents() {
        // .droppedFrame and .lateTake have their own broken-out sections;
        // they must NOT also land in systemEvents.
        let summary = PostShowSummary.from(events: [
            event(.droppedFrame, offset: 1, source: .system, detail: "drops=1 cumulative=1"),
            event(.lateTake, offset: 2, source: .system, detail: "latency=200ms cue=A")
        ])
        XCTAssertEqual(summary.systemEvents.count, 0)
    }

    // MARK: - Source mix

    func testSourceMixCountsBySource() {
        let summary = PostShowSummary.from(events: [
            event(.go, offset: 0, source: .localHotkey, detail: "1"),
            event(.go, offset: 1, source: .operatorButton, detail: "2"),
            event(.go, offset: 2, source: .osc(host: "x", port: 1), detail: "3"),
            event(.go, offset: 3, source: .http(tokenSuffix: "ab"), detail: "4"),
            event(.go, offset: 4, source: .timecode, detail: "5"),
            event(.cueEnded, offset: 5, source: .system, detail: "1")
        ])
        let mix = summary.sourceMix
        XCTAssertEqual(mix.local, 2, ".localHotkey + .operatorButton both fold to local.")
        XCTAssertEqual(mix.osc, 1)
        XCTAssertEqual(mix.http, 1)
        XCTAssertEqual(mix.timecode, 1)
        XCTAssertEqual(mix.system, 1)
        XCTAssertEqual(mix.total, 6)
    }

    // MARK: - Time window

    func testShowStartedAndEndedReflectFirstAndLastEventTimestamps() {
        let summary = PostShowSummary.from(events: [
            event(.go, offset: 0, detail: "1"),
            event(.cueEnded, offset: 60, source: .system, detail: "1"),
            event(.go, offset: 30, detail: "2") // out-of-order, reducer sorts
        ])
        XCTAssertEqual(summary.showStartedAt, t0)
        XCTAssertEqual(summary.showEndedAt, t0.addingTimeInterval(60))
        XCTAssertEqual(summary.elapsedSeconds ?? 0, 60.0, accuracy: 0.001)
    }

    func testReducerSortsOutOfOrderEvents() {
        // Even when caller passes events out of order, pairing must work.
        let summary = PostShowSummary.from(events: [
            event(.cueEnded, offset: 5, source: .system, detail: "Q.1"),
            event(.go, offset: 0, detail: "Q.1")
        ])
        XCTAssertEqual(summary.cueStats.first?.pairedCount, 1)
    }
}
