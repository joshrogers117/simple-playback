import Foundation
import XCTest
@testable import Simple_Playback

@MainActor
final class LateTakeDetectorTests: XCTestCase {

    func testFrameWithinThresholdReturnsOnTimeVerdict() {
        let detector = LateTakeDetector(lateThresholdMS: 150)
        let cueID = UUID()
        let slideID = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000)

        detector.recordGoFired(cueID: cueID, slideID: slideID, at: t0)
        let verdict = detector.recordFrameSubmitted(slideID: slideID, at: t0.addingTimeInterval(0.05))

        XCTAssertEqual(verdict, .onTime(latencyMS: 50))
        XCTAssertNil(detector.pending,
                     "First-frame match should clear the pending state.")
    }

    func testFrameAboveThresholdReturnsLateVerdict() {
        let detector = LateTakeDetector(lateThresholdMS: 150)
        let cueID = UUID()
        let slideID = UUID()
        let t0 = Date(timeIntervalSince1970: 2_000)

        detector.recordGoFired(cueID: cueID, slideID: slideID, at: t0)
        let verdict = detector.recordFrameSubmitted(slideID: slideID, at: t0.addingTimeInterval(0.420))

        XCTAssertEqual(verdict, .late(latencyMS: 420))
        XCTAssertTrue(verdict?.isLate ?? false)
    }

    func testFrameForDifferentSlideIsIgnored() {
        let detector = LateTakeDetector()
        let cueID = UUID()
        let pendingSlide = UUID()
        let otherSlide = UUID()
        detector.recordGoFired(cueID: cueID, slideID: pendingSlide, at: Date())

        let verdict = detector.recordFrameSubmitted(slideID: otherSlide, at: Date().addingTimeInterval(1))

        XCTAssertNil(verdict)
        XCTAssertNotNil(detector.pending,
                        "A frame for the wrong slide should not consume the pending take.")
    }

    func testFrameWithoutPendingReturnsNil() {
        let detector = LateTakeDetector()
        let verdict = detector.recordFrameSubmitted(slideID: UUID(), at: Date())
        XCTAssertNil(verdict)
    }

    func testSecondGoSupersedesFirst() {
        // A stacked GO replaces the pending take — matching cue-runtime
        // semantics where the second GO pre-empts the queued cue.
        let detector = LateTakeDetector()
        let firstCue = UUID()
        let firstSlide = UUID()
        let secondCue = UUID()
        let secondSlide = UUID()
        let t0 = Date(timeIntervalSince1970: 3_000)

        detector.recordGoFired(cueID: firstCue, slideID: firstSlide, at: t0)
        detector.recordGoFired(cueID: secondCue, slideID: secondSlide, at: t0.addingTimeInterval(0.1))

        // A frame for the original slide should NOT close the second
        // pending take.
        let stale = detector.recordFrameSubmitted(slideID: firstSlide, at: t0.addingTimeInterval(0.2))
        XCTAssertNil(stale)
        XCTAssertEqual(detector.pending?.cueID, secondCue)

        // The second slide closes it. Latency from second-GO (t0+100ms) to
        // frame (t0+500ms) is 400 ms — above the default 150 ms threshold,
        // so this counts as a late take. The point of this test is the
        // *supersede* behavior, not the verdict — but we pin the actual
        // result so a future threshold tweak doesn't silently change it.
        let verdict = detector.recordFrameSubmitted(slideID: secondSlide, at: t0.addingTimeInterval(0.5))
        XCTAssertEqual(verdict, .late(latencyMS: 400))
    }

    func testFrameTimestampPriorToGoIsIgnored() {
        // Defense against same-process clock skew or out-of-order callbacks:
        // a frame timestamped before its GO doesn't fire a verdict.
        let detector = LateTakeDetector()
        let cueID = UUID()
        let slideID = UUID()
        let t0 = Date(timeIntervalSince1970: 4_000)
        detector.recordGoFired(cueID: cueID, slideID: slideID, at: t0)

        let verdict = detector.recordFrameSubmitted(slideID: slideID, at: t0.addingTimeInterval(-0.01))
        XCTAssertNil(verdict)
    }

    func testLatencyExactlyAtThresholdIsOnTime() {
        // Boundary: latency *strictly greater than* threshold counts as
        // late; equal-to is on time. Pinned because the threshold is the
        // operator-facing knob.
        let detector = LateTakeDetector(lateThresholdMS: 150)
        let cueID = UUID()
        let slideID = UUID()
        let t0 = Date(timeIntervalSince1970: 5_000)
        detector.recordGoFired(cueID: cueID, slideID: slideID, at: t0)

        let verdict = detector.recordFrameSubmitted(slideID: slideID, at: t0.addingTimeInterval(0.150))
        XCTAssertEqual(verdict, .onTime(latencyMS: 150))
    }

    func testClearPendingDropsTheTakeWithoutFiringVerdict() {
        let detector = LateTakeDetector()
        detector.recordGoFired(cueID: UUID(), slideID: UUID(), at: Date())
        XCTAssertNotNil(detector.pending)

        detector.clearPending()

        XCTAssertNil(detector.pending)
    }

    func testFrameForSamePendingArrivesOnce() {
        // Subsequent frames for the same slide after the verdict are
        // no-ops because the pending state was cleared.
        let detector = LateTakeDetector()
        let cueID = UUID()
        let slideID = UUID()
        let t0 = Date(timeIntervalSince1970: 6_000)
        detector.recordGoFired(cueID: cueID, slideID: slideID, at: t0)

        let firstVerdict = detector.recordFrameSubmitted(slideID: slideID, at: t0.addingTimeInterval(0.05))
        let secondVerdict = detector.recordFrameSubmitted(slideID: slideID, at: t0.addingTimeInterval(0.10))

        XCTAssertNotNil(firstVerdict)
        XCTAssertNil(secondVerdict)
    }

    // MARK: - Boundary cases (added during the squeaky-clean review pass)
    //
    // The "exactly at threshold = on-time" pin lives at line 96 above.
    // These add the matching "one-ms-over → late" discriminator and a
    // few clock-skew / zero-latency edge cases the suite was missing.

    func testLatencyOneMSOverThresholdIsLate() {
        // 151 ms must trip late — this is the discriminator vs the
        // exactly-at-threshold case above. Without it, an off-by-one
        // in the comparison would silently let 151 ms reads pass.
        let detector = LateTakeDetector(lateThresholdMS: 150)
        let slideID = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000)
        detector.recordGoFired(cueID: UUID(), slideID: slideID, at: t0)
        let verdict = detector.recordFrameSubmitted(slideID: slideID, at: t0.addingTimeInterval(0.151))
        XCTAssertEqual(verdict, .late(latencyMS: 151))
    }

    func testNegativeLatencyFromClockSkewReturnsNilAndKeepsPending() {
        // If a host accidentally mixes wall-clock with monotonic-clock
        // timestamps (or NTP slews backwards mid-show), the frame's `at`
        // can pre-date the GO. The detector must drop the verdict (nil)
        // and KEEP pending so a subsequent valid same-slide frame can
        // still close the verdict — not silently lock the pending state.
        let detector = LateTakeDetector(lateThresholdMS: 150)
        let slideID = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000)
        detector.recordGoFired(cueID: UUID(), slideID: slideID, at: t0)
        let skewed = detector.recordFrameSubmitted(slideID: slideID, at: t0.addingTimeInterval(-0.050))
        XCTAssertNil(skewed)
        XCTAssertNotNil(detector.pending,
                        "Negative-latency frames don't consume pending.")
        // A subsequent valid frame still closes the verdict.
        let valid = detector.recordFrameSubmitted(slideID: slideID, at: t0.addingTimeInterval(0.080))
        XCTAssertEqual(valid, .onTime(latencyMS: 80))
    }

    func testZeroLatencyReturnsOnTime() {
        // Frame arriving on the same instant as the GO. Operationally
        // unlikely but the detector shouldn't crash or treat as negative.
        let detector = LateTakeDetector(lateThresholdMS: 150)
        let slideID = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000)
        detector.recordGoFired(cueID: UUID(), slideID: slideID, at: t0)
        let verdict = detector.recordFrameSubmitted(slideID: slideID, at: t0)
        XCTAssertEqual(verdict, .onTime(latencyMS: 0))
    }

    func testCustomLowThresholdProducesLateAt100ms() {
        // Tighter threshold, e.g. for a high-stakes show where 100 ms is
        // the operator's bar. Pin that the threshold parameter is honoured
        // and not hard-coded to 150 anywhere.
        let detector = LateTakeDetector(lateThresholdMS: 100)
        let slideID = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000)
        detector.recordGoFired(cueID: UUID(), slideID: slideID, at: t0)
        let verdict = detector.recordFrameSubmitted(slideID: slideID, at: t0.addingTimeInterval(0.120))
        XCTAssertEqual(verdict, .late(latencyMS: 120))
    }
}
