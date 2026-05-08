import Foundation
import XCTest
@testable import Simple_Playback

/// E3+ — pin that ShowController's dropped-frame log debounce emits a
/// single `.droppedFrame` event per quiet window, batches the deficit
/// across a window, and re-baselines on counter reset. Tests drive
/// `handleDropCumulative(_:now:)` directly so the debounce is pinned
/// without real-time waits.
@MainActor
final class ShowControllerDroppedFrameLogTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func makeController() -> (controller: ShowController, log: ShowLog, playback: PlaybackController) {
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
        return (controller, log, playback)
    }

    func testFirstBurstEmitsImmediately() {
        let (controller, log, _) = makeController()
        controller.handleDropCumulative(3, now: t0)
        let drops = log.events.filter { $0.action == .droppedFrame }
        XCTAssertEqual(drops.count, 1)
        XCTAssertEqual(drops.first?.source, .system)
        XCTAssertEqual(drops.first?.detail, "drops=3 cumulative=3")
    }

    func testDebounceSuppressesEmissionsInsideQuietWindow() {
        let (controller, log, _) = makeController()
        controller.handleDropCumulative(3, now: t0)
        controller.handleDropCumulative(5, now: t0.addingTimeInterval(0.3))
        controller.handleDropCumulative(8, now: t0.addingTimeInterval(0.9))
        let drops = log.events.filter { $0.action == .droppedFrame }
        XCTAssertEqual(drops.count, 1)
    }

    func testNextBurstAfterWindowBatchesAccumulatedDeficit() {
        let (controller, log, _) = makeController()
        controller.handleDropCumulative(3, now: t0)
        controller.handleDropCumulative(8, now: t0.addingTimeInterval(0.3))
        controller.handleDropCumulative(12, now: t0.addingTimeInterval(1.5))
        let drops = log.events.filter { $0.action == .droppedFrame }
        XCTAssertEqual(drops.count, 2)
        // First emission: 3 since baseline 0.
        XCTAssertEqual(drops.first?.detail, "drops=3 cumulative=3")
        // Second emission: deficit since the last logged value (3 → 12 = 9).
        XCTAssertEqual(drops.last?.detail, "drops=9 cumulative=12")
    }

    func testCounterResetReBaselinesWithoutEmission() {
        let (controller, log, _) = makeController()
        controller.handleDropCumulative(4, now: t0)
        let beforeReset = log.events.filter { $0.action == .droppedFrame }.count
        // Counter goes back to zero (PlaybackController.stopOutput).
        controller.handleDropCumulative(0, now: t0.addingTimeInterval(0.5))
        let afterReset = log.events.filter { $0.action == .droppedFrame }.count
        XCTAssertEqual(beforeReset, afterReset, "Reset must not emit a phantom drop event")
    }

    func testSubsequentBurstAfterResetEmitsFromZero() {
        let (controller, log, _) = makeController()
        controller.handleDropCumulative(2, now: t0)
        controller.handleDropCumulative(0, now: t0.addingTimeInterval(0.4)) // reset
        controller.handleDropCumulative(5, now: t0.addingTimeInterval(0.5))
        let drops = log.events.filter { $0.action == .droppedFrame }
        XCTAssertEqual(drops.count, 2)
        XCTAssertEqual(drops.last?.detail, "drops=5 cumulative=5")
    }

    func testZeroCumulativeWithoutPriorRecordsDoesNotEmit() {
        let (controller, log, _) = makeController()
        // The published initial value of 0 should not produce a log entry.
        controller.handleDropCumulative(0, now: t0)
        XCTAssertEqual(log.events.filter { $0.action == .droppedFrame }.count, 0)
    }

    func testEndToEndCounterUpdatePropagatesViaPublishedSubscription() {
        let (controller, log, playback) = makeController()
        // Retain `controller` for the lifetime of the test — without this the
        // tuple-destructured controller is deallocated immediately and its
        // Combine subscription dies before the counter publishes.
        _ = controller
        // The Combine subscription is wired in init. A synchronous publish
        // through `record` should reach the sink on the next main-loop
        // turn — ride the run loop briefly so the receive(on: .main) hop
        // delivers the value.
        playback.droppedFrameCounter.record(count: 3, at: Date())
        let exp = expectation(description: "drop log via subscription")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        XCTAssertGreaterThanOrEqual(
            log.events.filter { $0.action == .droppedFrame }.count, 1
        )
    }
}
