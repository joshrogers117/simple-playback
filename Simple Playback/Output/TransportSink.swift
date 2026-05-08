import CoreGraphics
import Foundation

/// Stage parameters as a sink needs them at runtime — raster size and integer-ratio frame
/// rate. Derived from a project `Stage` value but kept narrow so tests can build one
/// without a full `PlayoutProject`.
struct TransportSinkStage: Hashable {
    var width: Int
    var height: Int
    var frameRateNumerator: Int
    var frameRateDenominator: Int

    init(width: Int, height: Int, frameRateNumerator: Int, frameRateDenominator: Int) {
        self.width = width
        self.height = height
        self.frameRateNumerator = frameRateNumerator
        self.frameRateDenominator = frameRateDenominator
    }

    init(stage: Stage) {
        self.init(
            width: stage.width,
            height: stage.height,
            frameRateNumerator: stage.frameRateNumerator,
            frameRateDenominator: stage.frameRateDenominator
        )
    }

    var size: CGSize { CGSize(width: width, height: height) }

    var framesPerSecond: Double {
        guard frameRateDenominator > 0 else { return 60 }
        return Double(frameRateNumerator) / Double(frameRateDenominator)
    }

    var frameInterval: Double {
        max(1.0 / max(framesPerSecond, 1), 1.0 / 60.0)
    }
}

/// A single frame consumer: one Screen→Transport binding actively pushing pixels at hardware.
/// The compositor pushes a single composed frame to a `TransportSinkRouter`, which fans the
/// frame out to all running sinks. Each sink is responsible for any per-transport conversion
/// (DeckLink format, NDI sender, OS display) — the compositor stays format-agnostic.
///
/// Spec ref: feature_spec.md §3.6 ("Transport bindings per Screen") + §2.2 ("Stage vs Screen").
protocol TransportSink: AnyObject {
    /// Stable identifier (e.g. `"decklink:DeckLinkUltraStudio:1080p59.94"`). Used as a key
    /// in router error maps and logs.
    var sinkID: String { get }

    /// Human-readable label for status bar / logs. Should describe the binding rather than
    /// the live state (the latter belongs in `status`).
    var label: String { get }

    /// Live status string, mirroring the underlying driver. Updated on start/stop/submit.
    var status: String { get }

    /// `true` between successful `start(stage:)` and `stop()`.
    var isRunning: Bool { get }

    /// The Stage the sink was last started for, or `nil` when idle.
    var activeStage: TransportSinkStage? { get }

    /// Start the sink for a given Stage.
    ///
    /// - Idempotent for the same `stage` — calling start while already running with the same
    ///   Stage parameters is a no-op.
    /// - Re-arming with a different `stage` stops first, then restarts. Mid-show format
    ///   change is intentionally heavy (matches §3.7's "explicit at start, mid-show change
    ///   is a stop+restart").
    func start(stage: TransportSinkStage) throws

    /// Tear down. Idempotent — calling `stop()` on an already-stopped sink is a no-op.
    func stop()

    /// Submit a composed frame. Errors thrown bubble up through the router but are
    /// captured per-sink so a single bad transport does not kill the rendering loop.
    func submit(frame: RenderedFrame) throws

    /// Submit interleaved 16-bit PCM audio. Sinks that do not carry audio (e.g. NDI-video-only)
    /// are free to ignore.
    func submit(audio: Data, sampleFrameCount: Int) throws
}

/// Holds the active set of `TransportSink`s and fans a single frame out to all running
/// sinks. Captures per-sink errors so one failing transport does not stall the rest of
/// the show.
///
/// Concurrency: the router itself is thread-safe (NSLock), but each sink's submit path
/// is expected to be safe to call from the compositor's output queue.
final class TransportSinkRouter {
    private var sinks: [TransportSink] = []
    private let lock = NSLock()
    private var lastErrorsStorage: [String: Error] = [:]

    /// Snapshot of all registered sinks (running or not).
    var allSinks: [TransportSink] {
        lock.lock(); defer { lock.unlock() }
        return sinks
    }

    /// Most recent per-sink errors from a `submit(frame:)` cycle. Cleared on every submit
    /// — operators see only the latest state.
    var lastErrors: [String: Error] {
        lock.lock(); defer { lock.unlock() }
        return lastErrorsStorage
    }

    /// Replace the active sink set. Stops sinks that are no longer present; does not
    /// auto-start newly added ones (the caller decides when to start each sink).
    func setSinks(_ newSinks: [TransportSink]) {
        let toStop: [TransportSink] = {
            lock.lock(); defer { lock.unlock() }
            let newIDs = Set(newSinks.map { ObjectIdentifier($0) })
            let removed = sinks.filter { !newIDs.contains(ObjectIdentifier($0)) }
            sinks = newSinks
            return removed
        }()
        for sink in toStop { sink.stop() }
    }

    /// Add a sink. No-op if the same sink instance is already registered.
    func addSink(_ sink: TransportSink) {
        lock.lock(); defer { lock.unlock() }
        guard !sinks.contains(where: { ObjectIdentifier($0) == ObjectIdentifier(sink) }) else { return }
        sinks.append(sink)
    }

    /// Remove and stop a specific sink. No-op if not registered.
    func removeSink(_ sink: TransportSink) {
        let removed: TransportSink? = {
            lock.lock(); defer { lock.unlock() }
            guard let idx = sinks.firstIndex(where: { ObjectIdentifier($0) == ObjectIdentifier(sink) }) else {
                return nil
            }
            return sinks.remove(at: idx)
        }()
        removed?.stop()
    }

    /// Stop every registered sink. Does not remove them from the router (so a subsequent
    /// `start(stage:)` can re-arm).
    func stopAll() {
        let snapshot: [TransportSink] = {
            lock.lock(); defer { lock.unlock() }
            return sinks
        }()
        for sink in snapshot { sink.stop() }
    }

    /// Submit a frame to every running sink. Returns the per-sink error map for the
    /// just-completed cycle (also stored on `lastErrors`). One sink's failure does not
    /// affect the others.
    @discardableResult
    func submit(frame: RenderedFrame) -> [String: Error] {
        let snapshot: [TransportSink] = {
            lock.lock(); defer { lock.unlock() }
            return sinks
        }()
        var errors: [String: Error] = [:]
        for sink in snapshot where sink.isRunning {
            do {
                try sink.submit(frame: frame)
            } catch {
                errors[sink.sinkID] = error
            }
        }
        lock.lock()
        lastErrorsStorage = errors
        lock.unlock()
        return errors
    }

    /// Submit audio to every running sink. Errors are captured per-sink and returned.
    @discardableResult
    func submit(audio: Data, sampleFrameCount: Int) -> [String: Error] {
        let snapshot: [TransportSink] = {
            lock.lock(); defer { lock.unlock() }
            return sinks
        }()
        var errors: [String: Error] = [:]
        for sink in snapshot where sink.isRunning {
            do {
                try sink.submit(audio: audio, sampleFrameCount: sampleFrameCount)
            } catch {
                errors[sink.sinkID] = error
            }
        }
        return errors
    }
}
