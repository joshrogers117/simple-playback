import Foundation

/// Pure-logic comparison of a clip's native frame rate to a Stage's frame rate.
///
/// Spec ref: feature_spec.md §3.7 ("Frame-rate conformance warnings — flag any clip whose
/// native rate ≠ Screen rate at clip-into-show time and again in pre-show check; never
/// silently re-time."). Reused by Phase E pre-show check (E1).
struct FrameRateConformance: Hashable {
    enum Severity: Hashable {
        /// Native FPS within tolerance — render path runs cleanly at the Stage rate.
        case match
        /// Native FPS unknown (legacy slide, still image, audio-only) — informational only.
        case unknown
        /// Native FPS does not match Stage; AVFoundation will re-time, which is acceptable
        /// for occasional cues (sting clips at 24p on a 60p stage) but warrants a visible
        /// flag so the operator chooses transcode-or-accept rather than getting blindsided.
        case mismatch
    }

    let clipFPS: Double?
    let stageFPS: Double
    let severity: Severity

    /// Comparison tolerance in FPS. 0.1 catches the four canonical fractional/integer pairs
    /// — 23.976↔24 (Δ≈0.024), 29.97↔30 (Δ≈0.03), 47.952↔48 (Δ≈0.048), 59.94↔60 (Δ≈0.06)
    /// — as matches, but still flags 24 vs 25, 30 vs 60, 23.976 vs 59.94, etc. We treat the
    /// fractional/integer pairs as a match because operators routinely interchange them and
    /// AVFoundation re-times cleanly across that gap.
    static let toleranceFPS: Double = 0.1

    /// Build a conformance verdict for a clip's native FPS against a Stage rate.
    init(clipFPS: Double?, stageFPS: Double) {
        self.clipFPS = clipFPS
        self.stageFPS = stageFPS
        guard let clipFPS, clipFPS > 0 else {
            severity = .unknown
            return
        }
        if abs(clipFPS - stageFPS) <= Self.toleranceFPS {
            severity = .match
        } else {
            severity = .mismatch
        }
    }

    /// Convenience initializer that pulls Stage rate from a `Stage` value.
    init(clipFPS: Double?, stage: Stage) {
        self.init(clipFPS: clipFPS, stageFPS: stage.framesPerSecond)
    }

    /// Operator-facing one-line summary. Stable strings — OK to use as accessibility labels
    /// or to exact-match in tests.
    var summary: String {
        switch severity {
        case .match:
            return "Frame rate matches Stage."
        case .unknown:
            return "Native frame rate unknown — verify on the timeline."
        case .mismatch:
            let clipString = Self.format(clipFPS ?? 0)
            let stageString = Self.format(stageFPS)
            return "Clip \(clipString) ≠ Stage \(stageString) — AVFoundation will re-time."
        }
    }

    /// Short chip label for UI: "23.976 → 59.94" or "matches" or "unknown".
    var chipLabel: String {
        switch severity {
        case .match: return "FPS: matches"
        case .unknown: return "FPS: unknown"
        case .mismatch:
            let clipString = Self.format(clipFPS ?? 0)
            let stageString = Self.format(stageFPS)
            return "FPS: \(clipString) → \(stageString)"
        }
    }

    /// Formats an FPS value for operator display. Integer values render as "30" / "60";
    /// fractional rates keep their canonical precision: "29.97", "23.976", "59.94".
    static func format(_ fps: Double) -> String {
        let rounded = (fps * 1000).rounded() / 1000
        if abs(rounded - rounded.rounded()) < 0.005 {
            return String(format: "%.0f", rounded)
        }
        // Use %.3f then trim trailing zeros so 23.976 → "23.976", 29.97 → "29.97".
        var s = String(format: "%.3f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
