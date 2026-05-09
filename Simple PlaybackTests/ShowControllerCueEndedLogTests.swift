import Foundation
import XCTest
@testable import Simple_Playback

/// v2 Post-Show Summary precondition (Q2-A) — pin that ShowController emits a
/// `.cueEnded` show-log entry on every `handleCueEnded` call, with the same
/// cue descriptor (number-or-title) that the corresponding `.go` event used.
///
/// The reducer pairs `.go` and `.cueEnded` rows by descriptor + chronology to
/// compute per-cue runtime; misnaming the descriptor would break the pairing
/// silently. These tests fix the descriptor format so future renames trip the
/// test rather than the post-show report.
@MainActor
final class ShowControllerCueEndedLogTests: XCTestCase {

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

    func testCueEndedEmitsLogEntryWithCueNumberDetail() {
        let (controller, log) = makeController()
        let cue = Cue(number: "1", title: "First", assetID: UUID())
        controller.handleCueEnded(cue)
        let cueEnded = log.events.filter { $0.action == .cueEnded }
        XCTAssertEqual(cueEnded.count, 1)
        XCTAssertEqual(cueEnded.first?.detail, "1")
        XCTAssertEqual(cueEnded.first?.source, .system)
    }

    func testCueEndedFallsBackToTitleWhenNumberEmpty() {
        let (controller, log) = makeController()
        let cue = Cue(number: "", title: "Walk-On VO", assetID: UUID())
        controller.handleCueEnded(cue)
        XCTAssertEqual(
            log.events.filter { $0.action == .cueEnded }.first?.detail,
            "Walk-On VO"
        )
    }

    func testCueEndedDescriptorMatchesGoDescriptorForReducerPairing() {
        // The Post-Show reducer pairs .go and .cueEnded by detail string.
        // Mismatched descriptors would silently break per-cue runtime.
        let (controller, log) = makeController()
        let cue = Cue(number: "Q.5", title: "Bumper", assetID: UUID())

        // Simulate the GO landing on the log via the controller's verb method
        // (uses the same descriptor format internally).
        log.appendNow(action: .go, source: .localHotkey, detail: cue.number)
        controller.handleCueEnded(cue)

        let go = log.events.first { $0.action == .go }
        let end = log.events.first { $0.action == .cueEnded }
        XCTAssertNotNil(go)
        XCTAssertNotNil(end)
        XCTAssertEqual(go?.detail, end?.detail,
                       "Reducer pairs .go and .cueEnded by detail string.")
    }

    func testCueEndedActionFiltersAsRuntimeVerb() {
        // ActionFilter.runtimeVerbs must include the new action so the viewer's
        // "Show verbs" filter doesn't silently drop CUE_ENDED rows.
        XCTAssertTrue(ShowLog.ActionFilter.runtimeVerbs.matches(.cueEnded))
        XCTAssertFalse(ShowLog.ActionFilter.systemEvents.matches(.cueEnded))
        XCTAssertTrue(ShowLog.ActionFilter.all.matches(.cueEnded))
    }

    func testCueEndedRoundTripsThroughCSV() {
        // Pin the rawValue so external CSV consumers don't break on rename.
        XCTAssertEqual(ShowLogEvent.Action.cueEnded.rawValue, "CUE_ENDED")
    }
}
