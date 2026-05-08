import XCTest
@testable import Simple_Playback

/// Unit coverage for `OutputStatusBar.evaluateFreeRunBanner`, the pure helper that decides
/// whether the project-level "REF expected" toggle should escalate the chip into a red
/// status-bar banner. SwiftUI bodies aren't reachable from XCTest without a UI host, so
/// the assertions exercise the decision function directly across all reference states.
final class OutputStatusBarTests: XCTestCase {

    func testFreeRunBannerHiddenWhenReferenceNotExpected() {
        for state in allReferenceStates {
            XCTAssertFalse(
                OutputStatusBar.evaluateFreeRunBanner(referenceExpected: false, referenceState: state),
                "Banner should never appear when expectation is off (state: \(String(describing: state)))"
            )
        }
    }

    func testFreeRunBannerVisibleOnlyForUnlockedWhenReferenceExpected() {
        XCTAssertTrue(
            OutputStatusBar.evaluateFreeRunBanner(referenceExpected: true, referenceState: .unlocked),
            "Free-run with REF expected must escalate."
        )

        XCTAssertFalse(
            OutputStatusBar.evaluateFreeRunBanner(referenceExpected: true, referenceState: .locked)
        )
        XCTAssertFalse(
            OutputStatusBar.evaluateFreeRunBanner(referenceExpected: true, referenceState: .idle)
        )
        XCTAssertFalse(
            OutputStatusBar.evaluateFreeRunBanner(referenceExpected: true, referenceState: .notSupported)
        )
        XCTAssertFalse(
            OutputStatusBar.evaluateFreeRunBanner(referenceExpected: true, referenceState: nil),
            "No DeckLink running ⇒ no banner; idle output is not a contradiction."
        )
    }

    private var allReferenceStates: [DeckLinkTransportSink.ReferenceState?] {
        [nil, .idle, .notSupported, .unlocked, .locked]
    }
}
