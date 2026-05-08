import Foundation
import XCTest
@testable import Simple_Playback

/// E3+ tail Path 1 — pin the new "first composed frame for cue X reached
/// output" callback that replaces the Path 2 `$liveSlideID` proxy. The
/// PlaybackController side of the contract: token armed by `take(...)` is
/// consumed exactly once on the next successful `submitFrame`, and the
/// callback receives the slide ID + a `Date` close to the actual submission.
@MainActor
final class PlaybackControllerCueFireTests: XCTestCase {

    func testCallbackFiresOnceWhenTokenArmedAndSimulationRuns() async {
        let playback = PlaybackController()
        let exp = expectation(description: "callback fired")
        var observed: (slideID: UUID, at: Date)?
        playback.onFirstComposedFrameForCue = { slideID, at in
            observed = (slideID, at)
            exp.fulfill()
        }

        let slideID = UUID()
        playback.armPendingCueFireSlideIDForTesting(slideID)
        playback.simulateFirstComposedFrameForTesting()

        await fulfillment(of: [exp], timeout: 1.0)
        XCTAssertEqual(observed?.slideID, slideID)
        XCTAssertNil(playback.peekPendingCueFireSlideIDForTesting(),
                     "Token must be consumed (cleared) on first emission so subsequent frames don't refire.")
    }

    func testSubsequentSimulationDoesNotRefireSameTake() async {
        let playback = PlaybackController()
        var fireCount = 0
        playback.onFirstComposedFrameForCue = { _, _ in fireCount += 1 }

        let slideID = UUID()
        playback.armPendingCueFireSlideIDForTesting(slideID)
        playback.simulateFirstComposedFrameForTesting()
        playback.simulateFirstComposedFrameForTesting()
        playback.simulateFirstComposedFrameForTesting()

        // Drain the main queue so all dispatched callbacks have run.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fireCount, 1,
                       "Subsequent simulations on the same take must not refire — token is one-shot.")
    }

    func testNoFireWhenTokenNotArmed() async {
        let playback = PlaybackController()
        var fireCount = 0
        playback.onFirstComposedFrameForCue = { _, _ in fireCount += 1 }

        // No arm. Simulate anyway — must be a no-op.
        playback.simulateFirstComposedFrameForTesting()

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fireCount, 0)
    }

    func testStopOutputDropsArmedToken() {
        let playback = PlaybackController()
        let slideID = UUID()
        playback.armPendingCueFireSlideIDForTesting(slideID)
        XCTAssertEqual(playback.peekPendingCueFireSlideIDForTesting(), slideID)

        playback.stopOutput()

        XCTAssertNil(playback.peekPendingCueFireSlideIDForTesting(),
                     "stopOutput must drop the armed token so a subsequent restart's first frame can't fire it.")
    }

    func testClearDropsArmedToken() {
        let playback = PlaybackController()
        let slideID = UUID()
        playback.armPendingCueFireSlideIDForTesting(slideID)
        XCTAssertEqual(playback.peekPendingCueFireSlideIDForTesting(), slideID)

        playback.clear()

        XCTAssertNil(playback.peekPendingCueFireSlideIDForTesting(),
                     "clear() must drop the armed token so the impending black-frame submit doesn't masquerade as the cleared cue's first frame.")
    }

    func testCallbackNotConsumedWhenNoCallbackIsSet() async {
        let playback = PlaybackController()
        let slideID = UUID()
        playback.armPendingCueFireSlideIDForTesting(slideID)

        // No callback set; simulate. Token MUST remain armed so a later-
        // attached callback can still receive the inaugural emission.
        playback.simulateFirstComposedFrameForTesting()

        XCTAssertEqual(playback.peekPendingCueFireSlideIDForTesting(), slideID,
                       "Token must remain armed when no callback is set — consumption requires a recipient.")
    }
}
