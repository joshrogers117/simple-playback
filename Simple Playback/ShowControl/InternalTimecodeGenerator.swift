import Foundation

/// Internal timecode generator for rehearsal and headless tests.
///
/// Drives a `TimecodeFollower` with frames at the configured frame rate,
/// starting at a chosen offset. The host can also feed the generated TC
/// strings into the OSC/HTTP state push so the operator UI shows the
/// running TC even with no external generator attached.
final class InternalTimecodeGenerator {
    let frameRate: TimecodeFrameRate
    var startTC: TimecodeValue
    private var startedAt: TimeInterval = 0
    private var token: SubscriptionPumpToken?
    private var clock: () -> TimeInterval

    /// Called once per rendered frame on the timer thread.
    var onFrame: ((TimecodeValue) -> Void)?

    init(
        frameRate: TimecodeFrameRate = .fps30,
        startTC: TimecodeValue? = nil,
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.frameRate = frameRate
        self.startTC = startTC ?? TimecodeValue(hours: 1, minutes: 0, seconds: 0, frames: 0, frameRate: frameRate)
        self.clock = clock
    }

    var isRunning: Bool { token != nil }

    func start() {
        guard token == nil else { return }
        startedAt = clock()
        let interval = 1.0 / frameRate.nominalFPS
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let tc = self.currentValue()
            self.onFrame?(tc)
        }
        timer.resume()
        token = SubscriptionPumpToken { timer.cancel() }
    }

    func stop() {
        token?.cancel()
        token = nil
    }

    deinit { stop() }

    /// Computes the TC value at the current clock time, given `startTC`.
    func currentValue() -> TimecodeValue {
        let elapsed = clock() - startedAt
        let elapsedFrames = Int64((elapsed * frameRate.nominalFPS).rounded())
        return TimecodeValue.fromFrameCount(
            startTC.frameCount + elapsedFrames,
            frameRate: frameRate
        )
    }
}
