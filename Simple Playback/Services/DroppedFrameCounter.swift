import Combine
import Foundation

/// E3+ — dropped-frame counter. Tracks two numbers operators care about
/// during a show: the **cumulative** drop count since the counter was reset
/// (typically when output starts) and the **rolling 10 s** count, which is
/// what the status-bar chip surfaces. Spec §3.15.
///
/// The counter is pure-logic — `record(count:at:)` is the only mutation, and
/// `observe(now:)` re-prunes the rolling window so a status-bar timer can
/// keep the displayed value fresh even when no new drops are arriving. Tests
/// inject explicit `Date` values to avoid sleeps; the production caller uses
/// `Date()` defaults.
@MainActor
final class DroppedFrameCounter: ObservableObject {

    /// Cumulative drop count since the last `reset()`. Reset on
    /// `PlaybackController.stopOutput()` so each output session starts at
    /// zero.
    @Published private(set) var cumulative: Int = 0

    /// Drops within the rolling window ending at the most recent `record`
    /// or `observe` call. Operators read this as "are we dropping right
    /// now?" — a non-zero rolling count alongside a zero cumulative is
    /// impossible by construction.
    @Published private(set) var rollingCount: Int = 0

    /// Window over which `rollingCount` is summed. 10 seconds matches the
    /// spec's "rolling drop counter (rolling 10 s)" line — long enough to
    /// catch a brief glitch, short enough that the chip clears once the
    /// system is healthy.
    let rollingWindow: TimeInterval

    private var samples: [Sample] = []

    struct Sample: Equatable {
        let timestamp: Date
        let count: Int
    }

    init(rollingWindow: TimeInterval = 10.0) {
        self.rollingWindow = rollingWindow
    }

    /// Record one or more dropped frames at `at`. `count` ≤ 0 is a no-op so
    /// callers can pass arithmetic results without guarding.
    func record(count: Int = 1, at: Date = Date()) {
        guard count > 0 else { return }
        cumulative += count
        samples.append(Sample(timestamp: at, count: count))
        recomputeRolling(now: at)
    }

    /// Re-prune the rolling window against `now` and refresh
    /// `rollingCount`. Call this from a periodic UI timer so the chip
    /// returns to zero after the window passes even when no new drops are
    /// being recorded.
    func observe(now: Date = Date()) {
        recomputeRolling(now: now)
    }

    /// Drop everything. Called when output stops so the next session
    /// starts at zero on both axes.
    func reset() {
        samples.removeAll(keepingCapacity: true)
        cumulative = 0
        rollingCount = 0
    }

    /// Prune samples older than `rollingWindow` seconds before `now`, and
    /// update the published `rollingCount`. Iterates the full sample list
    /// because production samples can briefly be non-monotonic (host clock
    /// adjustments, batch flushes after a stall).
    private func recomputeRolling(now: Date) {
        let cutoff = now.addingTimeInterval(-rollingWindow)
        samples.removeAll(where: { $0.timestamp < cutoff })
        rollingCount = samples.reduce(0) { $0 + $1.count }
    }
}
