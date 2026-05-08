import Foundation
import AVFoundation

/// Reads LTC audio from a Core Audio input device (any channel) and feeds
/// the decoder. Reports decoded TC frames via `onFrame` and engagement state
/// changes via `onStateChanged`.
///
/// The host (ShowController/PlaybackController) wires `onFrame` into a
/// `TimecodeFollower.frameReceived` and applies the resulting jam-sync
/// decision to the timeline.
final class LTCReader {
    let engine: AVAudioEngine
    let decoder: LTCDecoder
    let follower: TimecodeFollower

    /// Channel index to extract from the multi-channel input buffer (0-based).
    var channelIndex: Int = 0

    private(set) var isRunning: Bool = false

    /// Called after every decoded frame, on the audio queue.
    var onFrame: ((TimecodeValue, TimecodeJamSyncDecision) -> Void)?
    /// Called on every engagement-state change.
    var onStateChanged: ((TimecodeEngagement) -> Void)?

    init(sampleRate: Double = 48000) {
        self.engine = AVAudioEngine()
        self.decoder = LTCDecoder(sampleRate: sampleRate)
        self.follower = TimecodeFollower()
        decoder.onFrame = { [weak self] tc in
            guard let self else { return }
            let prev = self.follower.engagement
            let decision = self.follower.frameReceived(tc)
            self.onFrame?(tc, decision)
            if prev != self.follower.engagement {
                self.onStateChanged?(self.follower.engagement)
            }
        }
    }

    /// Arms the follower and installs an audio tap. Throws if the input bus
    /// can't be configured (no input device, sample rate mismatch).
    func start() throws {
        guard !isRunning else { return }
        follower.arm()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        try engine.start()
        isRunning = true
        onStateChanged?(follower.engagement)
    }

    /// Cancels the audio tap and disarms the follower.
    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        follower.disengage()
        isRunning = false
        onStateChanged?(follower.engagement)
    }

    deinit { stop() }

    private func handle(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        let channel = min(channelIndex, Int(buffer.format.channelCount) - 1)
        var samples: [Float] = []
        samples.reserveCapacity(count)
        for i in 0..<count {
            samples.append(channelData[channel][i])
        }
        decoder.process(samples: samples)
        follower.poll()
    }
}
