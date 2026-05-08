import Foundation
import XCTest
@testable import Simple_Playback

/// E1+ — energy / no-idle-sleep IOPM assertion. Tests pin the state machine
/// (acquire idempotent, release idempotent, isHeld toggles) without engaging
/// IOKit by injecting a captured assertor + releaser.
@MainActor
final class EnergyAssertionTests: XCTestCase {

    private final class Capture {
        var assertedNames: [String] = []
        var releasedIDs: [UInt32] = []
    }

    private func makeAssertion(
        assertResult: UInt32? = 42
    ) -> (EnergyAssertion, () -> Capture) {
        let capture = Capture()
        let assertion = EnergyAssertion(
            assertor: { name in
                capture.assertedNames.append(name)
                return assertResult
            },
            releaser: { id in
                capture.releasedIDs.append(id)
            }
        )
        return (assertion, { capture })
    }

    func testAcquireFlipsIsHeldAndCallsAssertor() {
        let (a, getCapture) = makeAssertion()
        XCTAssertFalse(a.isHeld)
        a.acquire()
        XCTAssertTrue(a.isHeld)
        XCTAssertEqual(getCapture().assertedNames.count, 1)
    }

    func testAcquireIsIdempotent() {
        let (a, getCapture) = makeAssertion()
        a.acquire()
        a.acquire()
        a.acquire()
        XCTAssertTrue(a.isHeld)
        XCTAssertEqual(getCapture().assertedNames.count, 1, "Idempotent acquire calls only the kernel once.")
    }

    func testReleaseDropsIsHeld() {
        let (a, getCapture) = makeAssertion()
        a.acquire()
        a.release()
        XCTAssertFalse(a.isHeld)
        XCTAssertEqual(getCapture().releasedIDs.count, 1)
    }

    func testReleaseWithoutAcquireIsNoop() {
        let (a, getCapture) = makeAssertion()
        a.release()
        XCTAssertFalse(a.isHeld)
        XCTAssertEqual(getCapture().releasedIDs.count, 0)
    }

    func testFailedAssertionLeavesHeldFalse() {
        let (a, getCapture) = makeAssertion(assertResult: nil)
        a.acquire()
        XCTAssertFalse(a.isHeld, "Failed kernel call must not flip isHeld true.")
        XCTAssertEqual(getCapture().assertedNames.count, 1, "Assertor was invoked.")
    }

    func testReacquireAfterReleaseSucceeds() {
        let (a, getCapture) = makeAssertion()
        a.acquire()
        a.release()
        a.acquire()
        XCTAssertTrue(a.isHeld)
        XCTAssertEqual(getCapture().assertedNames.count, 2)
        XCTAssertEqual(getCapture().releasedIDs.count, 1)
    }

    func testAssertionNameIsHumanReadable() {
        // Pinned so a future rename doesn't accidentally flip the label
        // operators see in `pmset -g assertions`.
        XCTAssertEqual(EnergyAssertion.assertionName, "Simple Playback — Show Mode")
    }
}
