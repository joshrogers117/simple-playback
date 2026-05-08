import Foundation
import XCTest
@testable import Simple_Playback

/// E3+ — pure-logic dropped-frame counter. Tests pin rolling-window edge
/// cases (entry rotation, window slide, cumulative monotonicity) by injecting
/// explicit `Date` values; no sleeps, no real-time assumptions.
@MainActor
final class DroppedFrameCounterTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func testInitialStateIsZero() {
        let counter = DroppedFrameCounter()
        XCTAssertEqual(counter.cumulative, 0)
        XCTAssertEqual(counter.rollingCount, 0)
    }

    func testRecordSingleDropUpdatesBothCounters() {
        let counter = DroppedFrameCounter()
        counter.record(count: 1, at: t0)
        XCTAssertEqual(counter.cumulative, 1)
        XCTAssertEqual(counter.rollingCount, 1)
    }

    func testRecordZeroOrNegativeIsNoOp() {
        let counter = DroppedFrameCounter()
        counter.record(count: 0, at: t0)
        counter.record(count: -3, at: t0)
        XCTAssertEqual(counter.cumulative, 0)
        XCTAssertEqual(counter.rollingCount, 0)
    }

    func testCumulativeSumsAllRecords() {
        let counter = DroppedFrameCounter()
        counter.record(count: 1, at: t0)
        counter.record(count: 2, at: t0.addingTimeInterval(1))
        counter.record(count: 5, at: t0.addingTimeInterval(2))
        XCTAssertEqual(counter.cumulative, 8)
        XCTAssertEqual(counter.rollingCount, 8)
    }

    func testSamplesOlderThanRollingWindowAreEvictedFromRolling() {
        let counter = DroppedFrameCounter(rollingWindow: 10.0)
        counter.record(count: 3, at: t0)
        counter.record(count: 1, at: t0.addingTimeInterval(11))
        // The 3-drop sample is now 11 s old → outside the 10 s window.
        XCTAssertEqual(counter.rollingCount, 1)
        // Cumulative is the lifetime sum and never decreases.
        XCTAssertEqual(counter.cumulative, 4)
    }

    func testSampleAtExactlyWindowEdgeIsKept() {
        let counter = DroppedFrameCounter(rollingWindow: 10.0)
        counter.record(count: 2, at: t0)
        counter.record(count: 1, at: t0.addingTimeInterval(10))
        // 10s exactly is the cutoff — inclusive. Both samples count.
        XCTAssertEqual(counter.rollingCount, 3)
    }

    func testObservePrunesWithoutNewRecord() {
        let counter = DroppedFrameCounter(rollingWindow: 10.0)
        counter.record(count: 4, at: t0)
        XCTAssertEqual(counter.rollingCount, 4)
        counter.observe(now: t0.addingTimeInterval(15))
        XCTAssertEqual(counter.rollingCount, 0)
        // Cumulative is unchanged by observe — only by record.
        XCTAssertEqual(counter.cumulative, 4)
    }

    func testRollingCountIsZeroWhenAllSamplesAged() {
        let counter = DroppedFrameCounter(rollingWindow: 10.0)
        counter.record(count: 1, at: t0)
        counter.record(count: 2, at: t0.addingTimeInterval(1))
        counter.observe(now: t0.addingTimeInterval(60))
        XCTAssertEqual(counter.rollingCount, 0)
        XCTAssertEqual(counter.cumulative, 3)
    }

    func testResetClearsBothCounters() {
        let counter = DroppedFrameCounter()
        counter.record(count: 5, at: t0)
        counter.reset()
        XCTAssertEqual(counter.cumulative, 0)
        XCTAssertEqual(counter.rollingCount, 0)
        // After reset, new records start from zero.
        counter.record(count: 1, at: t0.addingTimeInterval(1))
        XCTAssertEqual(counter.cumulative, 1)
        XCTAssertEqual(counter.rollingCount, 1)
    }

    func testRollingWindowSlidesAcrossManySamples() {
        let counter = DroppedFrameCounter(rollingWindow: 10.0)
        for i in 0..<20 {
            counter.record(count: 1, at: t0.addingTimeInterval(Double(i)))
        }
        // After 20 samples 1 second apart at t=19, the rolling window
        // ending at t=19 (start cutoff = t=9) covers samples at 9..19 → 11 samples.
        XCTAssertEqual(counter.rollingCount, 11)
        XCTAssertEqual(counter.cumulative, 20)
    }

    func testRollingCountReadsRecordTimestampNotWallClock() {
        // Recording a "future" sample (timestamp ahead of others) should still
        // place that sample inside its own observation window.
        let counter = DroppedFrameCounter(rollingWindow: 10.0)
        counter.record(count: 1, at: t0.addingTimeInterval(100))
        XCTAssertEqual(counter.rollingCount, 1)
        // Earlier-timestamp record after the future one is ~100 s in the past
        // relative to the most recent observation, so it's already outside the
        // window once we re-observe at the latest sample's time.
        counter.record(count: 1, at: t0)
        counter.observe(now: t0.addingTimeInterval(100))
        XCTAssertEqual(counter.rollingCount, 1)
        XCTAssertEqual(counter.cumulative, 2)
    }

    func testBatchedDropsRecordedAsSingleSample() {
        // The wiring layer will report bursts (e.g., "we missed 3 frames in
        // one render-tick deficit"). One record call with count=3 must show
        // up in the rolling sum verbatim.
        let counter = DroppedFrameCounter(rollingWindow: 10.0)
        counter.record(count: 3, at: t0)
        XCTAssertEqual(counter.rollingCount, 3)
        XCTAssertEqual(counter.cumulative, 3)
    }
}
