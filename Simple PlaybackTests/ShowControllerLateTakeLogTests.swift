import Combine
import Foundation
import XCTest
@testable import Simple_Playback

/// E3+ tail — pin that ShowController's late-take live integration emits a
/// `.lateTake` show-log entry only when the load-latency proxy crosses the
/// detector's threshold, names the right cue, and survives PANIC reset.
///
/// Tests drive `lateTakeDetector` + `handleLiveSlideTransition(slideID:now:)`
/// directly so the bridge is pinned without synthesizing a real
/// `liveSlideID` publish from `PlaybackController`.
@MainActor
final class ShowControllerLateTakeLogTests: XCTestCase {

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

    func testLateFrameAfterRecordedGoLogsLateTakeWithLatencyAndCueDescriptor() {
        let (controller, log) = makeController()
        let cueID = UUID()
        let slideID = UUID()
        controller.lateTakeDetector.recordGoFired(cueID: cueID, slideID: slideID, at: t0)
        // Stash the descriptor the way handleCueFired would.
        // Tests touch the private cache via the detector path: sending a
        // matching frame sources the descriptor from the lateTakeDetector
        // pending state. We simulate the descriptor by manipulating the
        // controller directly through a public-test-seam method.
        controller.setPendingLateTakeCueDescriptor("CUE-12")

        let lateAt = t0.addingTimeInterval(0.3) // 300 ms > 150 ms default
        controller.handleLiveSlideTransition(slideID: slideID, now: lateAt)

        let entries = log.events.filter { $0.action == .lateTake }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.detail, "latency=300ms cue=CUE-12")
        XCTAssertEqual(entries.first?.source, .system)
    }

    func testOnTimeFrameDoesNotLogLateTake() {
        let (controller, log) = makeController()
        let cueID = UUID()
        let slideID = UUID()
        controller.lateTakeDetector.recordGoFired(cueID: cueID, slideID: slideID, at: t0)
        controller.setPendingLateTakeCueDescriptor("CUE-1")

        let onTimeAt = t0.addingTimeInterval(0.05) // 50 ms < threshold
        controller.handleLiveSlideTransition(slideID: slideID, now: onTimeAt)

        XCTAssertTrue(log.events.filter { $0.action == .lateTake }.isEmpty)
    }

    func testFrameWithoutPendingTakeIsIgnored() {
        let (controller, log) = makeController()
        controller.handleLiveSlideTransition(slideID: UUID(), now: t0)
        XCTAssertTrue(log.events.filter { $0.action == .lateTake }.isEmpty)
    }

    func testFrameForDifferentSlideKeepsPendingAlive() {
        let (controller, log) = makeController()
        let pendingSlideID = UUID()
        let unrelatedSlideID = UUID()
        controller.lateTakeDetector.recordGoFired(
            cueID: UUID(),
            slideID: pendingSlideID,
            at: t0
        )
        controller.setPendingLateTakeCueDescriptor("CUE-A")

        // A frame for an unrelated slide arrives first (e.g., the previous
        // take's tail frame). It must not close the verdict — pending state
        // is preserved for the right slide.
        controller.handleLiveSlideTransition(slideID: unrelatedSlideID, now: t0.addingTimeInterval(0.05))
        XCTAssertNotNil(controller.lateTakeDetector.pending)
        XCTAssertTrue(log.events.filter { $0.action == .lateTake }.isEmpty)

        // The right slide arrives later — and it's late.
        controller.handleLiveSlideTransition(slideID: pendingSlideID, now: t0.addingTimeInterval(0.5))
        let entries = log.events.filter { $0.action == .lateTake }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.detail, "latency=500ms cue=CUE-A")
    }

    func testPanicClearsPendingTakeSoNextFrameIsIgnored() {
        let (controller, log) = makeController()
        let slideID = UUID()
        controller.lateTakeDetector.recordGoFired(cueID: UUID(), slideID: slideID, at: t0)
        controller.setPendingLateTakeCueDescriptor("CUE-BAD")

        // Operator hits PANIC mid-load. ShowController must clear pending so
        // a stale measurement doesn't fire when the panic-recovered frame
        // eventually lands.
        controller.lateTakeDetector.clearPending()
        controller.clearPendingLateTakeCueDescriptorForTesting()

        controller.handleLiveSlideTransition(slideID: slideID, now: t0.addingTimeInterval(2.0))
        XCTAssertTrue(log.events.filter { $0.action == .lateTake }.isEmpty)
    }

    func testSecondGoSupersedesFirstAndOnlyLatestVerdictLogs() {
        let (controller, log) = makeController()
        let firstSlide = UUID()
        let secondSlide = UUID()

        controller.lateTakeDetector.recordGoFired(cueID: UUID(), slideID: firstSlide, at: t0)
        controller.setPendingLateTakeCueDescriptor("CUE-First")

        // Operator stacks a second GO 80 ms later — same controller, different
        // cue and slide. The detector replaces pending; the bridge replaces
        // the descriptor cache (mirroring handleCueFired).
        controller.lateTakeDetector.recordGoFired(
            cueID: UUID(),
            slideID: secondSlide,
            at: t0.addingTimeInterval(0.08)
        )
        controller.setPendingLateTakeCueDescriptor("CUE-Second")

        // The first slide's frame eventually arrives — but it's stale.
        controller.handleLiveSlideTransition(slideID: firstSlide, now: t0.addingTimeInterval(1.0))
        XCTAssertTrue(log.events.filter { $0.action == .lateTake }.isEmpty,
                      "Stale frame for the superseded take must not log.")

        // The second slide arrives 250 ms after its GO — that's late.
        controller.handleLiveSlideTransition(
            slideID: secondSlide,
            now: t0.addingTimeInterval(0.08).addingTimeInterval(0.25)
        )
        let entries = log.events.filter { $0.action == .lateTake }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.detail, "latency=250ms cue=CUE-Second")
    }
}
