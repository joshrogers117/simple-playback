import Foundation
import XCTest
@testable import Simple_Playback

@MainActor
final class DebouncerTests: XCTestCase {

    func testRapidScheduleCollapsesIntoSingleInvocation() async {
        // Drive with a tiny real interval so the test stays fast but exercises
        // the actual Task.sleep path. Fire 10 schedules in quick succession;
        // only the last should win.
        let debouncer = Debouncer(interval: .milliseconds(20))
        let counter = Counter()

        for i in 0..<10 {
            debouncer.schedule {
                counter.record(i)
            }
        }

        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(counter.count, 1, "Bursting 10 schedules must collapse to a single invocation.")
        XCTAssertEqual(counter.last, 9, "The final scheduled action must be the one that runs.")
    }

    func testCancelDropsPendingAction() async {
        let debouncer = Debouncer(interval: .milliseconds(20))
        let counter = Counter()

        debouncer.schedule { counter.record(1) }
        debouncer.cancel()

        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(counter.count, 0, "cancel() before the timer fires must drop the pending action.")
    }

    func testActionFiresOnceAfterInterval() async {
        let debouncer = Debouncer(interval: .milliseconds(20))
        let counter = Counter()

        debouncer.schedule { counter.record(42) }

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(counter.last, 42)
    }

    func testInjectedSleepIsHonored() async {
        // With the sleep closure under test control, scheduling should fire
        // exactly when the closure returns. This pins the seam used by
        // future deterministic tests.
        let resumed = expectation(description: "sleep returned")
        let debouncer = Debouncer(interval: .milliseconds(1)) { _ in
            // Honor the requested wait but mark it observable.
            try await Task.sleep(for: .milliseconds(1))
            resumed.fulfill()
        }
        let counter = Counter()
        debouncer.schedule { counter.record(7) }

        await fulfillment(of: [resumed], timeout: 1.0)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(counter.last, 7)
    }

    @MainActor
    private final class Counter {
        private(set) var count = 0
        private(set) var last: Int?
        func record(_ value: Int) {
            count += 1
            last = value
        }
    }
}
