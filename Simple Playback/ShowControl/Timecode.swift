import Foundation

/// Frame rate options exposed in the timecode UI. 23.976 has no drop-frame
/// representation (per research §5.3 — the operator UI must reflect that).
enum TimecodeFrameRate: String, CaseIterable, Codable, Hashable {
    case fps23_976 = "23.976"
    case fps24 = "24"
    case fps25 = "25"
    case fps29_97_df = "29.97 DF"
    case fps29_97_ndf = "29.97 NDF"
    case fps30 = "30"

    /// Frames per second used for absolute-frame counting.
    var nominalFPS: Double {
        switch self {
        case .fps23_976: return 24000.0 / 1001.0
        case .fps24: return 24
        case .fps25: return 25
        case .fps29_97_df, .fps29_97_ndf: return 30000.0 / 1001.0
        case .fps30: return 30
        }
    }

    /// Integer FPS used for HH:MM:SS:FF parsing — for 29.97 it's 30, for 23.976 it's 24.
    var integerFPS: Int {
        switch self {
        case .fps23_976: return 24
        case .fps24: return 24
        case .fps25: return 25
        case .fps29_97_df, .fps29_97_ndf: return 30
        case .fps30: return 30
        }
    }

    var isDropFrame: Bool {
        if case .fps29_97_df = self { return true }
        return false
    }
}

/// One timecode value: HH:MM:SS:FF plus an absolute frame count for canonical
/// equality. `string` is the operator-visible form. `frameCount` is what the
/// engine compares against when deciding "did the frame advance?"
struct TimecodeValue: Equatable, Hashable {
    let hours: Int
    let minutes: Int
    let seconds: Int
    let frames: Int
    let frameRate: TimecodeFrameRate

    init(hours: Int, minutes: Int, seconds: Int, frames: Int, frameRate: TimecodeFrameRate) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
        self.frameRate = frameRate
    }

    /// Absolute frame count from "00:00:00:00", honoring drop-frame.
    var frameCount: Int64 {
        let fps = frameRate.integerFPS
        let totalMinutes = Int64(hours * 60 + minutes)
        if frameRate.isDropFrame {
            // 29.97 DF: drop 2 frames every minute except every tenth minute.
            let dropFrames: Int64 = 2 * (totalMinutes - totalMinutes / 10)
            let raw: Int64 =
                Int64(hours) * 3600 * Int64(fps)
                + Int64(minutes) * 60 * Int64(fps)
                + Int64(seconds) * Int64(fps)
                + Int64(frames)
            return raw - dropFrames
        } else {
            return Int64(hours) * 3600 * Int64(fps)
                 + Int64(minutes) * 60 * Int64(fps)
                 + Int64(seconds) * Int64(fps)
                 + Int64(frames)
        }
    }

    var stringValue: String {
        let separator = frameRate.isDropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, separator, frames)
    }

    /// Parses HH:MM:SS:FF (or HH:MM:SS;FF for drop-frame). Whitespace tolerated.
    static func parse(_ s: String, frameRate: TimecodeFrameRate) -> TimecodeValue? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = trimmed.replacingOccurrences(of: ";", with: ":")
        let parts = chars.split(separator: ":")
        guard parts.count == 4,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              let sec = Int(parts[2]),
              let f = Int(parts[3]),
              h >= 0, h < 24,
              m >= 0, m < 60,
              sec >= 0, sec < 60,
              f >= 0, f < frameRate.integerFPS
        else { return nil }
        return TimecodeValue(hours: h, minutes: m, seconds: sec, frames: f, frameRate: frameRate)
    }

    /// Builds a value from absolute frame count.
    static func fromFrameCount(_ count: Int64, frameRate: TimecodeFrameRate) -> TimecodeValue {
        let fps = Int64(frameRate.integerFPS)
        var c = max(0, count)
        if frameRate.isDropFrame {
            // Reverse the drop-frame math: a "drop-frame minute" is 60 fps - 2.
            // Pattern: every 10 minutes drops 18 frames (2 frames * 9 minutes).
            let framesPer10Min: Int64 = fps * 60 * 10 - 18
            let framesPerMin: Int64 = fps * 60 - 2
            var totalMinutes: Int64 = 0
            // First, peel off chunks of 10 minutes.
            let tenMinChunks = c / framesPer10Min
            c -= tenMinChunks * framesPer10Min
            totalMinutes += tenMinChunks * 10
            // Then peel off the first minute of the chunk (60*fps frames).
            let firstMinFrames: Int64 = fps * 60
            if c >= firstMinFrames {
                c -= firstMinFrames
                totalMinutes += 1
                // Then up to 9 more "drop minutes" of 60*fps - 2 frames.
                while c >= framesPerMin, totalMinutes % 10 != 0 {
                    c -= framesPerMin
                    totalMinutes += 1
                }
            }
            let hours = Int(totalMinutes / 60)
            let minutes = Int(totalMinutes % 60)
            let seconds = Int(c / fps)
            let frames = Int(c % fps)
            return TimecodeValue(
                hours: hours,
                minutes: minutes,
                seconds: seconds,
                frames: frames,
                frameRate: frameRate
            )
        } else {
            let totalSeconds = c / fps
            let frames = Int(c % fps)
            let seconds = Int(totalSeconds % 60)
            let minutes = Int((totalSeconds / 60) % 60)
            let hours = Int(totalSeconds / 3600)
            return TimecodeValue(
                hours: hours,
                minutes: minutes,
                seconds: seconds,
                frames: frames,
                frameRate: frameRate
            )
        }
    }
}

/// Engagement state. Operator-visible and pushed over OSC/WebSocket.
enum TimecodeEngagement: String, Equatable, Codable {
    case off
    case armed
    case chasing
    case freewheeling
    case lost
}

/// Decision the engagement state machine makes on each TC tick.
enum TimecodeJamSyncDecision: Equatable {
    case lock(to: TimecodeValue)
    case freewheel(from: TimecodeValue)
    case snap(to: TimecodeValue)
    case relock(jumpTo: TimecodeValue)
    case lose
}

/// Pure state machine for the engagement transitions and jam-sync threshold.
/// The audio decoder feeds it `frameReceived(value:at:)`; the timeline reads
/// `value()` for the current best-known position.
final class TimecodeFollower {
    var engagement: TimecodeEngagement = .off
    var freewheelWindow: TimeInterval = 2.0
    /// Per-frames threshold for jam-sync re-lock vs snap. ±2 frames per spec.
    var snapThresholdFrames: Int = 2

    private(set) var lastValue: TimecodeValue?
    private(set) var lastReceivedAt: TimeInterval = 0
    var clock: () -> TimeInterval

    init(clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.clock = clock
    }

    func arm() {
        if engagement == .off { engagement = .armed }
    }

    func disengage() {
        engagement = .off
        lastValue = nil
    }

    /// Called on every decoded TC frame. Returns the jam-sync decision, which
    /// the host applies (drives the playback timeline / cue triggers).
    @discardableResult
    func frameReceived(_ value: TimecodeValue) -> TimecodeJamSyncDecision {
        let now = clock()
        defer { lastReceivedAt = now }
        switch engagement {
        case .off:
            return .lose
        case .armed:
            engagement = .chasing
            lastValue = value
            return .lock(to: value)
        case .chasing, .freewheeling, .lost:
            engagement = .chasing
            // Compare against expected internal value.
            if let last = lastValue, let expected = expected(after: last, at: now) {
                let delta = abs(value.frameCount - expected.frameCount)
                if delta <= Int64(snapThresholdFrames) {
                    lastValue = value
                    return .snap(to: value)
                } else {
                    lastValue = value
                    return .relock(jumpTo: value)
                }
            }
            lastValue = value
            return .lock(to: value)
        }
    }

    /// Called by the host on a poll (e.g. once per render frame). Manages the
    /// freewheel timer and `lost` transition.
    func poll() {
        let now = clock()
        guard engagement == .chasing || engagement == .freewheeling else { return }
        let elapsed = now - lastReceivedAt
        if elapsed < 0.05 {
            // Just received — stay chasing.
            engagement = .chasing
            return
        }
        if elapsed <= freewheelWindow {
            engagement = .freewheeling
            return
        }
        engagement = .lost
    }

    /// Expected absolute TC at `now`, given last lock at `last`.
    /// Pure helper; tests use this to verify the jam-sync threshold math.
    func expected(after last: TimecodeValue, at now: TimeInterval) -> TimecodeValue? {
        let elapsed = now - lastReceivedAt
        guard elapsed >= 0 else { return last }
        let extraFrames = Int64((elapsed * last.frameRate.nominalFPS).rounded())
        return TimecodeValue.fromFrameCount(
            last.frameCount + extraFrames,
            frameRate: last.frameRate
        )
    }
}
