import AVFoundation
import Foundation

final class AudioPump {
    private let queue = DispatchQueue(label: "SimplePlayback.AudioPump")
    private let queueKey = DispatchSpecificKey<Void>()
    private var timer: DispatchSourceTimer?
    private var primary: AudioTrack?
    private var outgoing: AudioTrack?
    private var transition: AudioTransition?
    private var submit: ((Data, Int) -> Void)?
    private var isPaused = false

    init() {
        queue.setSpecific(key: queueKey, value: ())
    }

    func start(url: URL, loop: Bool, volume: Double, fadeInDuration: Double = 0, submit: @escaping (Data, Int) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked(clearConfiguration: true)
            self.submit = submit

            guard let track = AudioTrack(url: url, loop: loop, volume: volume),
                  track.prepareReader() else {
                return
            }

            self.primary = track
            if fadeInDuration > 0 {
                self.transition = AudioTransition(
                    startTime: Self.now(),
                    duration: fadeInDuration,
                    incomingTargetVolume: track.volume,
                    outgoingStartVolume: 0
                )
            }
            self.startTimerIfNeeded()
        }
    }

    func crossfade(to url: URL, loop: Bool, volume: Double, duration: Double, submit: @escaping (Data, Int) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.submit = submit

            guard let incoming = AudioTrack(url: url, loop: loop, volume: volume),
                  incoming.prepareReader() else {
                self.startFadeOutLocked(duration: duration)
                return
            }

            self.outgoing?.stop()
            self.outgoing = self.primary
            self.primary = incoming
            self.transition = AudioTransition(
                startTime: Self.now(),
                duration: max(0.001, duration),
                incomingTargetVolume: incoming.volume,
                outgoingStartVolume: self.outgoing?.volume ?? 0
            )
            self.startTimerIfNeeded()
        }
    }

    func fadeOut(duration: Double) {
        queue.async { [weak self] in
            self?.startFadeOutLocked(duration: duration)
        }
    }

    func pauseAudio() {
        queue.async { [weak self] in
            self?.isPaused = true
        }
    }

    func resumeAudio() {
        queue.async { [weak self] in
            self?.isPaused = false
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopLocked(clearConfiguration: true)
            return
        }
        queue.sync {
            stopLocked(clearConfiguration: true)
        }
    }

    func seek(to time: CMTime) {
        let seconds = time.seconds.isFinite ? max(0, time.seconds) : 0
        let targetTime = CMTime(seconds: seconds, preferredTimescale: 600)

        queue.async { [weak self] in
            guard let self, let primary = self.primary else { return }
            primary.seek(to: targetTime)
            if primary.prepareReader(), self.timer == nil {
                self.startTimerIfNeeded()
            }
        }
    }

    private func startFadeOutLocked(duration: Double) {
        guard primary != nil || outgoing != nil else {
            stopLocked(clearConfiguration: true)
            return
        }

        if let primary {
            outgoing?.stop()
            outgoing = primary
            self.primary = nil
        }
        transition = AudioTransition(
            startTime: Self.now(),
            duration: max(0.001, duration),
            incomingTargetVolume: 0,
            outgoingStartVolume: outgoing?.volume ?? 0
        )
        startTimerIfNeeded()
    }

    private func stopLocked(clearConfiguration: Bool) {
        timer?.cancel()
        timer = nil
        primary?.stop()
        primary = nil
        outgoing?.stop()
        outgoing = nil
        transition = nil
        isPaused = false

        if clearConfiguration {
            submit = nil
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            self?.pumpSamples()
        }
        self.timer = timer
        timer.resume()
    }

    private func pumpSamples() {
        if isPaused { return }
        let gains = updateTransitionGains()
        guard primary != nil || outgoing != nil else { return }

        let primaryData = gains.incoming > 0 ? primary?.nextData() : nil
        if primary?.isActive == false {
            primary = nil
        }

        let outgoingData = gains.outgoing > 0 ? outgoing?.nextData() : nil
        if outgoing?.isActive == false {
            outgoing = nil
        }

        guard let data = mixPCM16Stereo(
            primaryData: primaryData,
            primaryGain: gains.incoming,
            outgoingData: outgoingData,
            outgoingGain: gains.outgoing
        ) else {
            if primary == nil && outgoing == nil {
                stopLocked(clearConfiguration: true)
            }
            return
        }

        submit?(data, max(0, data.count / 4))
    }

    private func updateTransitionGains() -> (incoming: Double, outgoing: Double) {
        guard let transition else {
            return (primary?.volume ?? 0, outgoing?.volume ?? 0)
        }

        let progress = (Self.now() - transition.startTime) / transition.duration
        if progress >= 1 {
            outgoing?.stop()
            outgoing = nil
            self.transition = nil

            if let primary {
                primary.volume = transition.incomingTargetVolume
                return (primary.volume, 0)
            }

            stopLocked(clearConfiguration: true)
            return (0, 0)
        }

        let clampedProgress = max(0, min(1, progress))
        return (
            transition.incomingTargetVolume * clampedProgress,
            transition.outgoingStartVolume * (1 - clampedProgress)
        )
    }

    private func mixPCM16Stereo(primaryData: Data?, primaryGain: Double, outgoingData: Data?, outgoingGain: Double) -> Data? {
        let byteCount = max(primaryData?.count ?? 0, outgoingData?.count ?? 0)
        let alignedByteCount = byteCount - (byteCount % 4)
        guard alignedByteCount > 0 else { return nil }

        var mixed = Data(count: alignedByteCount)
        mixed.withUnsafeMutableBytes { mixedBytes in
            primaryData?.withUnsafeBytes { primaryBytes in
                outgoingData?.withUnsafeBytes { outgoingBytes in
                    mixSamples(
                        primaryBytes: primaryBytes,
                        primaryGain: primaryGain,
                        outgoingBytes: outgoingBytes,
                        outgoingGain: outgoingGain,
                        into: mixedBytes
                    )
                }
            }

            if primaryData != nil, outgoingData == nil {
                primaryData?.withUnsafeBytes { primaryBytes in
                    mixSamples(
                        primaryBytes: primaryBytes,
                        primaryGain: primaryGain,
                        outgoingBytes: nil,
                        outgoingGain: 0,
                        into: mixedBytes
                    )
                }
            } else if primaryData == nil, outgoingData != nil {
                outgoingData?.withUnsafeBytes { outgoingBytes in
                    mixSamples(
                        primaryBytes: nil,
                        primaryGain: 0,
                        outgoingBytes: outgoingBytes,
                        outgoingGain: outgoingGain,
                        into: mixedBytes
                    )
                }
            }
        }
        return mixed
    }

    private func mixSamples(
        primaryBytes: UnsafeRawBufferPointer?,
        primaryGain: Double,
        outgoingBytes: UnsafeRawBufferPointer?,
        outgoingGain: Double,
        into mixedBytes: UnsafeMutableRawBufferPointer
    ) {
        guard let mixedBase = mixedBytes.baseAddress else { return }
        let mixedSamples = mixedBase.bindMemory(to: Int16.self, capacity: mixedBytes.count / MemoryLayout<Int16>.size)
        let primarySamples = primaryBytes?.baseAddress?.bindMemory(to: Int16.self, capacity: (primaryBytes?.count ?? 0) / MemoryLayout<Int16>.size)
        let outgoingSamples = outgoingBytes?.baseAddress?.bindMemory(to: Int16.self, capacity: (outgoingBytes?.count ?? 0) / MemoryLayout<Int16>.size)
        let primarySampleCount = (primaryBytes?.count ?? 0) / MemoryLayout<Int16>.size
        let outgoingSampleCount = (outgoingBytes?.count ?? 0) / MemoryLayout<Int16>.size
        let mixedSampleCount = mixedBytes.count / MemoryLayout<Int16>.size

        for index in 0..<mixedSampleCount {
            let primarySample = index < primarySampleCount ? Double(primarySamples?[index] ?? 0) * primaryGain : 0
            let outgoingSample = index < outgoingSampleCount ? Double(outgoingSamples?[index] ?? 0) * outgoingGain : 0
            let sample = primarySample + outgoingSample
            mixedSamples[index] = Int16(max(Double(Int16.min), min(Double(Int16.max), sample)))
        }
    }

    private static func now() -> TimeInterval {
        Date.timeIntervalSinceReferenceDate
    }

    private struct AudioTransition {
        var startTime: TimeInterval
        var duration: Double
        var incomingTargetVolume: Double
        var outgoingStartVolume: Double
    }

    private final class AudioTrack {
        let url: URL
        var loop: Bool
        var volume: Double
        var startTime = CMTime.zero
        var reader: AVAssetReader?
        var output: AVAssetReaderTrackOutput?
        var isActive = true

        init?(url: URL, loop: Bool, volume: Double) {
            self.url = url
            self.loop = loop
            self.volume = max(0, min(1, volume))
        }

        func seek(to time: CMTime) {
            stop()
            isActive = true
            startTime = time
        }

        func prepareReader() -> Bool {
            stopReader()
            let asset = AVAsset(url: url)
            guard let track = asset.tracks(withMediaType: .audio).first else {
                isActive = false
                return false
            }

            do {
                let reader = try AVAssetReader(asset: asset)
                if startTime.seconds > 0 {
                    reader.timeRange = CMTimeRange(start: startTime, duration: .positiveInfinity)
                }
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else {
                    isActive = false
                    return false
                }
                reader.add(output)
                guard reader.startReading() else {
                    isActive = false
                    return false
                }
                self.reader = reader
                self.output = output
                isActive = true
                return true
            } catch {
                isActive = false
                return false
            }
        }

        func nextData() -> Data? {
            guard let output else { return nil }

            if let sampleBuffer = output.copyNextSampleBuffer(),
               let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                let byteCount = CMBlockBufferGetDataLength(blockBuffer)
                var data = Data(count: byteCount)
                data.withUnsafeMutableBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else { return }
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteCount, destination: baseAddress)
                }
                return data
            }

            if loop {
                startTime = .zero
                return prepareReader() ? nextData() : nil
            }

            stop()
            return nil
        }

        func stop() {
            isActive = false
            stopReader()
        }

        private func stopReader() {
            reader?.cancelReading()
            reader = nil
            output = nil
        }
    }
}
