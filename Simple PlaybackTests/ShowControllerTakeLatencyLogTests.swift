import Foundation
import XCTest
@testable import Simple_Playback

/// v2 Post-Show Summary precondition (Q3-C) — pin that ShowController emits a
/// `.takeLatency` show-log entry on every late-take detector verdict (both
/// on-time and late), and that the existing `.lateTake` event continues to
/// fire only for late verdicts. The post-show reducer bins `.takeLatency`
/// rows into a histogram; `.lateTake` remains the operator-readable highlight.
@MainActor
final class ShowControllerTakeLatencyLogTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func makeController() -> (controller: ShowController, log: ShowLog) {
        let playback = PlaybackController()
        let controller = ShowController(
            showList: ShowList(name: "Test"),
            playback: playback,
            assetLookup: { _ in nil },
            transitionSettings: { PlayoutTransitionSettings() },
            outputBinding: { (nil, nil) }
        )
        let log = ShowLog()
        controller.showLog = log
        return (controller, log)
    }

    func testOnTimeVerdictEmitsTakeLatencyButNotLateTake() {
        let (controller, log) = makeController()
        let cueID = UUID()
        let slideID = UUID()
        controller.lateTakeDetector.recordGoFired(cueID: cueID, slideID: slideID, at: t0)
        controller.setPendingLateTakeCueDescriptor("CUE-1")

        let onTimeAt = t0.addingTimeInterval(0.05) // 50 ms < 150 ms threshold
        controller.handleLiveSlideTransition(slideID: slideID, now: onTimeAt)

        let latency = log.events.filter { $0.action == .takeLatency }
        let late = log.events.filter { $0.action == .lateTake }
        XCTAssertEqual(latency.count, 1, "On-time verdict still emits .takeLatency.")
        XCTAssertEqual(latency.first?.detail, "latency=50ms cue=CUE-1")
        XCTAssertEqual(latency.first?.source, .system)
        XCTAssertTrue(late.isEmpty, "On-time verdict must not emit .lateTake.")
    }

    func testLateVerdictEmitsBothTakeLatencyAndLateTake() {
        let (controller, log) = makeController()
        let cueID = UUID()
        let slideID = UUID()
        controller.lateTakeDetector.recordGoFired(cueID: cueID, slideID: slideID, at: t0)
        controller.setPendingLateTakeCueDescriptor("CUE-2")

        let lateAt = t0.addingTimeInterval(0.3) // 300 ms > 150 ms threshold
        controller.handleLiveSlideTransition(slideID: slideID, now: lateAt)

        let latency = log.events.filter { $0.action == .takeLatency }
        let late = log.events.filter { $0.action == .lateTake }
        XCTAssertEqual(latency.count, 1, "Late verdict emits .takeLatency.")
        XCTAssertEqual(late.count, 1, "Late verdict also emits .lateTake.")
        XCTAssertEqual(latency.first?.detail, "latency=300ms cue=CUE-2")
        XCTAssertEqual(late.first?.detail, "latency=300ms cue=CUE-2")
    }

    func testFrameWithoutPendingTakeEmitsNeitherEvent() {
        let (controller, log) = makeController()
        // No recordGoFired call — the detector returns nil for the frame.
        controller.handleLiveSlideTransition(slideID: UUID(), now: t0)
        XCTAssertTrue(log.events.filter { $0.action == .takeLatency }.isEmpty)
        XCTAssertTrue(log.events.filter { $0.action == .lateTake }.isEmpty)
    }

    func testTakeLatencyActionFiltersAsSystemEvent() {
        // Reducer + viewer filter: .takeLatency belongs alongside .droppedFrame
        // and .lateTake under the System bucket so operators looking at "show
        // verbs only" don't see histogram noise.
        XCTAssertTrue(ShowLog.ActionFilter.systemEvents.matches(.takeLatency))
        XCTAssertFalse(ShowLog.ActionFilter.runtimeVerbs.matches(.takeLatency))
        XCTAssertTrue(ShowLog.ActionFilter.all.matches(.takeLatency))
    }

    func testTakeLatencyRawValueStable() {
        XCTAssertEqual(ShowLogEvent.Action.takeLatency.rawValue, "TAKE_LATENCY")
    }
}
