import Foundation

/// Pure-logic detector for late-take events: GO was pressed but the cue's
/// first rendered frame didn't reach the output within an operator-set
/// threshold. Spec §3.16 ("show log writer must record late takes" alongside
/// dropped frames). The detector is independent of `PlaybackController` and
/// `ShowController` so it unit-tests deterministically; live integration is
/// host-side wiring (deferred — `PlaybackController` doesn't yet expose a
/// "first frame for cue X" callback).
///
/// Latency model: the host calls `recordGoFired(...)` when the cue-runtime
/// state transitions (operator GO accepted; cue is loading). Frames stream
/// in via `recordFrameSubmitted(slideID:at:)` — the *first* frame whose
/// `slideID` matches the pending take's expected slide closes the
/// measurement. Subsequent frames for the same slide are no-ops; a new GO
/// resets the pending state.
///
/// The detector does not measure inter-frame jitter (that's the
/// `DroppedFrameCounter`'s job). It measures the round-trip from "operator
/// pressed GO" to "operator-visible content changed."
struct LateTakePending: Equatable {
    var cueID: UUID
    var slideID: UUID
    var firedAt: Date
}

enum LateTakeVerdict: Equatable {
    /// The take's first frame arrived inside the threshold. Latency in ms is
    /// recorded for telemetry; the host typically does NOT log this case.
    case onTime(latencyMS: Int)
    /// The take's first frame was late. The host should log a `.lateTake`
    /// event with this latency. Threshold-relative; the threshold itself
    /// lives on the detector.
    case late(latencyMS: Int)

    var latencyMS: Int {
        switch self {
        case .onTime(let ms), .late(let ms): return ms
        }
    }

    var isLate: Bool {
        if case .late = self { return true }
        return false
    }
}

@MainActor
final class LateTakeDetector {

    /// Default threshold above which a take counts as "late." 150 ms is a
    /// rule-of-thumb for live-show feel: below ~150 ms the operator perceives
    /// GO as instant; above it, the gap reads as a delay. Spec §3.16 doesn't
    /// fix a number; this is a reasonable starting point that we'll tune from
    /// real rehearsal data.
    nonisolated static let defaultLateThresholdMS: Int = 150

    /// Threshold in milliseconds. Initial value comes from
    /// `defaultLateThresholdMS`; settable so tests can drive both branches
    /// without contorted timing.
    var lateThresholdMS: Int

    private(set) var pending: LateTakePending?

    init(lateThresholdMS: Int = LateTakeDetector.defaultLateThresholdMS) {
        self.lateThresholdMS = lateThresholdMS
    }

    /// Operator pressed GO; the cue is on its way. The detector remembers
    /// `cueID` + `slideID` + the firing timestamp so a subsequent frame can
    /// match it. Calling `recordGoFired` while a previous take is still
    /// pending replaces the pending state — the second GO supersedes the
    /// first (matching cue-runtime semantics where a stacked GO pre-empts
    /// the queued cue).
    func recordGoFired(cueID: UUID, slideID: UUID, at firedAt: Date) {
        pending = LateTakePending(cueID: cueID, slideID: slideID, firedAt: firedAt)
    }

    /// A frame for `slideID` reached the output at `at`. If this is the
    /// first frame for the pending take's expected slide, returns a verdict
    /// (`.onTime` or `.late`) and clears the pending state. Returns nil if
    /// the slide doesn't match the pending take, or no take is pending, or
    /// the frame's timestamp pre-dates the GO (clock skew defense — never
    /// happens on the same host but cheap to guard).
    func recordFrameSubmitted(slideID: UUID, at frameAt: Date) -> LateTakeVerdict? {
        guard let pending else { return nil }
        guard pending.slideID == slideID else { return nil }
        guard frameAt >= pending.firedAt else { return nil }
        let latencyMS = Int((frameAt.timeIntervalSince(pending.firedAt) * 1000.0).rounded())
        self.pending = nil
        if latencyMS > lateThresholdMS {
            return .late(latencyMS: latencyMS)
        }
        return .onTime(latencyMS: latencyMS)
    }

    /// Reset the pending state without recording a verdict. Use this when
    /// the cue-runtime aborted before any frame rendered (e.g. PANIC during
    /// load) so a stale pending entry doesn't fire a verdict against the
    /// next unrelated take.
    func clearPending() {
        pending = nil
    }
}
