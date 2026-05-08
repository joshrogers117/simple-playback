import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import QuartzCore

final class PlaybackController: ObservableObject {
    @Published private(set) var devices: [VideoOutputDevice] = []
    /// Latest DeckLink REF lock state, refreshed by `refreshDevices()` and on output start/stop.
    /// Nil when the active output is not a DeckLink (preview, NDI, etc.).
    @Published private(set) var deckLinkReferenceState: DeckLinkTransportSink.ReferenceState?
    /// Flips true the first time `submitFrame` runs successfully — i.e. the render path
    /// has pushed at least one composed frame to its outputs. Pre-show check (E1) reads
    /// this as the "render path warmed" signal: spec §3.16 expects an operator to be able
    /// to verify the output pipeline isn't cold before a show. Cleared on `stop()`.
    @Published private(set) var hasRenderedAnyFrame: Bool = false
    /// E3+ — dropped-frame counter. Owned by `PlaybackController` so the lifecycle
    /// (reset on `stopOutput`, accumulate during a session) is naturally tied to
    /// output state. The video timer's render path detects cadence misses and
    /// records them; observers (status-bar chip, ShowController log) read the
    /// rolling and cumulative published values directly.
    let droppedFrameCounter = DroppedFrameCounter()
    @Published private(set) var liveSlideID: UUID?
    @Published private(set) var liveTitle: String = "Black"
    @Published private(set) var status: String = "Idle"
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewPlayer: AVPlayer?
    @Published private(set) var transitionPreviewImage: CGImage?
    @Published private(set) var videoCurrentTime: Double = 0
    @Published private(set) var videoDuration: Double = 0
    @Published private(set) var isRunning = false
    @Published private(set) var isPlaying: Bool = false

    private let outputDriver: VideoOutputDriver
    /// Additional `TransportSink`s receiving every composed frame alongside the primary
    /// `outputDriver`. Used by NDI (B11), Syphon, file-record, and the second DeckLink port
    /// once those land. The primary path still goes through `outputDriver` for backward
    /// compatibility with the (deviceID, modeID) UI; the router enables N>1 fan-out today.
    private let auxiliarySinks = TransportSinkRouter()
    /// Three-layer compositor (media + bug + message). Defaults to `.empty` so no allocations
    /// or behavior change for projects that haven't enabled overlays.
    private let compositor = CompositorPipeline()
    /// Persistent overlay state. Setting this is cheap when overlays are inert. Changes to the
    /// bug's media reference flush the pipeline's image cache.
    var compositorOverlays: CompositorOverlays = .empty {
        didSet {
            if oldValue.bug.media != compositorOverlays.bug.media {
                compositor.invalidateBugImageCache()
            }
            // Re-composite the cached base frame so live edits in the Overlays inspector
            // update the in-app preview without requiring a fresh take. The driver/router
            // hot path picks the new overlays up on the next regular submit.
            republishComposedPreview()
        }
    }
    private var activeSinkStage: TransportSinkStage?
    private let outputQueue = DispatchQueue(label: "SimplePlayback.OutputSubmissions")
    private let outputQueueKey = DispatchSpecificKey<Void>()
    private let audioOutputQueue = DispatchQueue(label: "SimplePlayback.AudioSubmissions")
    private let videoPreparationQueue = DispatchQueue(label: "SimplePlayback.VideoPreparation", qos: .userInitiated)
    private let renderer = FrameRenderer()
    private let audioPump = AudioPump()
    private var videoOutput: AVPlayerItemVideoOutput?
    private var activeRenderItem: AVPlayerItem?
    private var timer: DispatchSourceTimer?
    private var outgoingHandoffTimer: DispatchSourceTimer?
    private weak var outgoingHandoffSource: OutgoingVideoSource?
    private var pendingVideoPrepareTimer: DispatchSourceTimer?
    private var pendingPreparedVideo: PreparedVideoTake?
    private var pendingPreparedImage: PreparedImageTake?
    private var pendingVideoTakeID: UUID?
    private var pendingPostDissolveActivation: (() -> Void)?
    private var rateObservation: NSKeyValueObservation?
    private var videoEndObserver: NSObjectProtocol?
    private var playerTimeObserver: Any?
    private var activeSettings = SlideSettings()
    private var activeOutputSize = CGSize(width: 1920, height: 1080)
    private var activeFrameInterval = 1.0 / 30.0
    private var currentFrame: RenderedFrame?
    private var latestVideoFrame: RenderedFrame?
    private var activeTransition: ActiveTransition?
    private var outputStartedForDevice: String?
    private var outputStartedForMode: String?
    private var scopedURL: URL?
    private var scopedURLDidAccess = false
    /// Host time of the last timer-driven render tick. Reset on
    /// `startVideoTimer` and `stopOutput`/`stopMediaOnly`. The drop detector
    /// reads this to compare against the configured `activeFrameInterval`.
    private var lastTimerTickHostTime: CFTimeInterval?

    init(outputDriver: VideoOutputDriver = CompositeVideoOutputDriver()) {
        self.outputDriver = outputDriver
        outputQueue.setSpecific(key: outputQueueKey, value: ())
    }

    func refreshDevices() {
        let result = syncOutput {
            let devices = outputDriver.availableDevices()
            return (devices, outputDriver.status, outputDriver.deckLinkReferenceState)
        }
        devices = result.0
        status = result.1
        deckLinkReferenceState = result.2
    }

    func defaultDeviceID(current: String?) -> String? {
        if let current, devices.contains(where: { $0.id == current }) {
            return current
        }
        return devices.first?.id
    }

    func defaultModeID(deviceID: String?, current: String?) -> String? {
        guard let device = devices.first(where: { $0.id == deviceID }) ?? devices.first else {
            return nil
        }
        if let current, device.modes.contains(where: { $0.id == current }) {
            return current
        }
        return device.modes.first?.id
    }

    func modes(for deviceID: String?) -> [VideoOutputMode] {
        guard let deviceID, let device = devices.first(where: { $0.id == deviceID }) else {
            return devices.first?.modes ?? []
        }
        return device.modes
    }

    /// C7d — current project bundle's `<bundle>/Media/` URL, when one exists.
    /// Drives bundle-aware resolution for `.managed` references so a moved
    /// `.splayback` plays its bundled media even when the absolute path
    /// recorded at apply time is stale on the new host. RootView updates this
    /// on document open / file-URL change. `nil` for untitled documents.
    /// Mirrored to the compositor so overlay (bug-image) resolution follows
    /// the same bundle-aware path as the primary take.
    var bundleMediaDirectory: URL? {
        didSet {
            if oldValue != bundleMediaDirectory {
                compositor.bundleMediaDirectory = bundleMediaDirectory
            }
        }
    }

    func take(slide: MediaSlide, deviceID: String?, modeID: String?, transitionSettings: PlayoutTransitionSettings) {
        cancelPendingVideoPreparation()

        guard let url = slide.media.resolvedURL(bundleMediaDirectory: bundleMediaDirectory) else {
            status = "Missing media: \(slide.title)"
            return
        }

        guard let deviceID = defaultDeviceID(current: deviceID),
              let modeID = defaultModeID(deviceID: deviceID, current: modeID),
              let mode = modes(for: deviceID).first(where: { $0.id == modeID }) else {
            status = "No output device selected"
            return
        }

        let outputSize = CGSize(width: mode.width, height: mode.height)
        let outputIsAlreadyRunning = outputStartedForDevice == deviceID && outputStartedForMode == modeID
        let transition = outputIsAlreadyRunning
            ? pendingTransition(settings: transitionSettings, outputSize: outputSize)
            : nil

        if let transition {
            switch slide.mediaKind {
            case .video:
                prepareVideoTransition(
                    slide: slide,
                    url: url,
                    deviceID: deviceID,
                    modeID: modeID,
                    mode: mode,
                    outputSize: outputSize,
                    transitionDuration: transition.duration
                )
            case .image:
                prepareImageTransition(
                    slide: slide,
                    url: url,
                    deviceID: deviceID,
                    modeID: modeID,
                    mode: mode,
                    outputSize: outputSize,
                    transitionDuration: transition.duration
                )
            }
            return
        }

        let outgoingVideo = stopMediaOnly(preservingMediaForTransition: false)

        do {
            try startOutputIfNeeded(deviceID: deviceID, modeID: modeID)
        } catch {
            outgoingVideo?.stop()
            audioPump.stop()
            liveSlideID = nil
            liveTitle = "Black"
            previewImage = nil
            isRunning = false
            status = error.localizedDescription
            return
        }

        updateScopedAccess(url: url)
        activeOutputSize = outputSize
        activeFrameInterval = frameInterval(for: mode)
        activeSettings = slide.settings
        beginTransition(nil, outgoingVideo: outgoingVideo)
        liveSlideID = slide.id
        liveTitle = slide.title
        isRunning = true

        switch slide.mediaKind {
        case .image:
            latestVideoFrame = nil
            takeImage(url: url, settings: slide.settings, transitionDuration: nil)
        case .video:
            takeVideo(url: url, settings: slide.settings, mode: mode, transitionDuration: nil)
        }
    }

    func clear() {
        cancelPendingVideoPreparation()
        stopMediaOnly()
        drainAudioOutput()
        let frame = renderer.blackFrame(outputSize: activeOutputSize)
        do {
            try syncOutput {
            stopActiveTransition()
            try submitFrame(frame)
            latestVideoFrame = nil
        }
            status = "Output cleared"
        } catch {
            status = error.localizedDescription
        }
        liveSlideID = nil
        liveTitle = "Black"
        previewImage = nil
        isRunning = false
    }

    func stopOutput() {
        cancelPendingVideoPreparation()
        stopMediaOnly()
        drainAudioOutput()
        syncOutput {
            outputDriver.stop()
            auxiliarySinks.stopAll()
            currentFrame = nil
            latestVideoFrame = nil
            stopActiveTransition()
        }
        outputStartedForDevice = nil
        outputStartedForMode = nil
        activeSinkStage = nil
        deckLinkReferenceState = nil
        hasRenderedAnyFrame = false
        let counter = droppedFrameCounter
        Task { @MainActor in counter.reset() }
        lastTimerTickHostTime = nil
        isRunning = false
        status = "Output stopped"
    }

    func togglePlayback() {
        guard let player = previewPlayer else { return }
        if player.rate > 0 {
            player.pause()
            audioPump.pauseAudio()
        } else {
            player.play()
            audioPump.resumeAudio()
        }
    }

    func jumpVideo(by offset: Double) {
        guard previewPlayer != nil, videoDuration > 0 else { return }
        seekVideo(to: videoCurrentTime + offset)
    }

    func seekVideo(to seconds: Double, syncAudio: Bool = true) {
        guard let player = previewPlayer else { return }

        let upperBound = videoDuration > 0 ? videoDuration : seconds
        let clampedSeconds = max(0, min(seconds, upperBound))
        let targetTime = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        videoCurrentTime = clampedSeconds

        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            if syncAudio {
                self.audioPump.seek(to: targetTime)
            }
            self.outputQueue.async { [weak self] in
                self?.renderCurrentVideoFrame(forceCurrentTime: true)
            }
        }
    }

    private func startOutputIfNeeded(deviceID: String, modeID: String) throws {
        if outputStartedForDevice == deviceID, outputStartedForMode == modeID {
            return
        }

        outputStartedForDevice = nil
        outputStartedForMode = nil
        drainAudioOutput()
        let newStatus = try syncOutput {
            outputDriver.stop()
            try outputDriver.start(deviceID: deviceID, modeID: modeID)
            return outputDriver.status
        }
        outputStartedForDevice = deviceID
        outputStartedForMode = modeID
        deckLinkReferenceState = outputDriver.deckLinkReferenceState

        // Re-arm auxiliary sinks for the new (device, mode) pair so additional transports
        // (NDI, Syphon, secondary DeckLink) start in lockstep with the primary output.
        let modeForStage = modes(for: deviceID).first(where: { $0.id == modeID })
            ?? VideoOutputMode.preview1080p30
        let stage = TransportSinkStage(
            width: modeForStage.width,
            height: modeForStage.height,
            frameRateNumerator: Int(modeForStage.timeScale),
            frameRateDenominator: Int(modeForStage.frameDuration)
        )
        activeSinkStage = stage
        startAuxiliarySinks(for: stage)

        status = newStatus
    }

    private func startAuxiliarySinks(for stage: TransportSinkStage) {
        for sink in auxiliarySinks.allSinks {
            do {
                try sink.start(stage: stage)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.status = "\(sink.label): \(error.localizedDescription)"
                }
            }
        }
    }

    /// Register a `TransportSink` to receive every composed frame and audio submission. If
    /// output is already running, the sink is started immediately for the active stage.
    func register(sink: TransportSink) {
        auxiliarySinks.addSink(sink)
        if let activeSinkStage {
            do {
                try sink.start(stage: activeSinkStage)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.status = "\(sink.label): \(error.localizedDescription)"
                }
            }
        }
    }

    /// Unregister and stop a previously registered `TransportSink`.
    func unregister(sink: TransportSink) {
        auxiliarySinks.removeSink(sink)
    }

    @discardableResult
    private func stopMediaOnly(preservingMediaForTransition shouldPreserveMedia: Bool = false) -> OutgoingVideoSource? {
        let outgoingVideo = shouldPreserveMedia ? makeOutgoingVideoSource() : nil
        if let outgoingVideo {
            startOutgoingHandoffTimer(for: outgoingVideo)
        } else {
            cancelOutgoingHandoffTimer()
        }

        timer?.cancel()
        timer = nil

        if !shouldPreserveMedia {
            removePlayerTimeObserver()
            if let videoEndObserver {
                NotificationCenter.default.removeObserver(videoEndObserver)
                self.videoEndObserver = nil
            }
            audioPump.stop()
            drainAudioOutput()
        }
        syncOutput {}
        if outgoingVideo == nil {
            previewPlayer?.pause()
            previewPlayer = nil
            videoCurrentTime = 0
            videoDuration = 0
        }
        videoOutput = nil
        activeRenderItem = nil
        latestVideoFrame = nil
        if outgoingVideo == nil, scopedURLDidAccess {
            scopedURL?.stopAccessingSecurityScopedResource()
        }
        scopedURL = nil
        scopedURLDidAccess = false

        return outgoingVideo
    }

    private func makeOutgoingVideoSource() -> OutgoingVideoSource? {
        guard let player = previewPlayer,
              let videoOutput,
              let item = player.currentItem,
              let currentFrame,
              currentFrame.width == Int(activeOutputSize.width),
              currentFrame.height == Int(activeOutputSize.height) else {
            return nil
        }

        let source = OutgoingVideoSource(
            player: player,
            item: item,
            videoOutput: videoOutput,
            settings: activeSettings,
            outputSize: activeOutputSize,
            fallbackFrame: currentFrame,
            scopedURL: scopedURL,
            scopedURLDidAccess: scopedURLDidAccess
        )

        if activeSettings.loopVideo {
            source.endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak source, weak item] _ in
                guard let source, let item else { return }
                item.seek(to: .zero, completionHandler: { _ in
                    source.player.play()
                })
            }
        }

        return source
    }

    private func takeImage(url: URL, settings: SlideSettings, transitionDuration: Double?) {
        guard let image = NSImage(contentsOf: url),
              let frame = renderer.renderImage(image, settings: settings, outputSize: activeOutputSize) else {
            syncOutput {
                stopActiveTransition()
            }
            audioPump.stop()
            status = "Could not render image"
            return
        }

        previewImage = image

        if syncOutput({ activeTransition != nil }) {
            audioPump.fadeOut(duration: transitionDuration ?? 0.001)
            startStillTransition(to: frame)
            status = "Crossfading image"
            return
        }

        do {
            try syncOutput {
                try submitFrame(frame)
            }
            status = "Live image"
        } catch {
            status = error.localizedDescription
        }
    }

    private func takeVideo(url: URL, settings: SlideSettings, mode: VideoOutputMode, transitionDuration: Double?) {
        let item = AVPlayerItem(url: url)
        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: mode.width,
            kCVPixelBufferHeightKey as String: mode.height
        ]
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixelAttributes)
        item.add(videoOutput)

        installVideoEndObserver(for: item, settings: settings)

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = settings.loopVideo ? .none : .pause
        player.isMuted = true
        previewPlayer = player
        previewImage = nil
        self.videoOutput = videoOutput
        self.activeRenderItem = item
        latestVideoFrame = nil
        videoCurrentTime = 0
        updateDuration(from: item)
        installPlayerTimeObserver(for: player)

        let submitAudio = audioSubmitter()
        if let transitionDuration, syncOutput({ activeTransition != nil }) {
            audioPump.crossfade(
                to: url,
                loop: settings.loopVideo,
                volume: settings.volume,
                duration: transitionDuration,
                submit: submitAudio
            )
        } else {
            audioPump.start(url: url, loop: settings.loopVideo, volume: settings.volume, submit: submitAudio)
        }

        startVideoTimer(mode: mode)
        player.play()
        status = "Live video"
    }

    private func prepareVideoTransition(
        slide: MediaSlide,
        url: URL,
        deviceID: String,
        modeID: String,
        mode: VideoOutputMode,
        outputSize: CGSize,
        transitionDuration: Double
    ) {
        let takeID = UUID()
        pendingVideoTakeID = takeID

        let didAccess = url.startAccessingSecurityScopedResource()
        let item = AVPlayerItem(url: url)
        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: mode.width,
            kCVPixelBufferHeightKey as String: mode.height
        ]
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixelAttributes)
        item.add(videoOutput)

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = slide.settings.loopVideo ? .none : .pause
        player.isMuted = true

        let prepared = PreparedVideoTake(
            id: takeID,
            slide: slide,
            url: url,
            scopedURLDidAccess: didAccess,
            deviceID: deviceID,
            modeID: modeID,
            mode: mode,
            outputSize: outputSize,
            transitionDuration: transitionDuration,
            item: item,
            player: player,
            videoOutput: videoOutput
        )
        pendingPreparedVideo = prepared
        status = "Preparing video"

        renderFirstPreparedFrame(for: prepared)
        startPreparedVideoTimeout(for: prepared)
    }

    private func startPreparedVideoTimeout(for prepared: PreparedVideoTake) {
        pendingVideoPrepareTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: videoPreparationQueue)
        timer.schedule(deadline: .now() + .seconds(3), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self, weak prepared] in
            DispatchQueue.main.async { [weak self, weak prepared] in
                guard let self, let prepared else { return }
                guard self.pendingVideoTakeID == prepared.id, self.pendingPreparedVideo === prepared else { return }
                prepared.abandon()
                self.pendingVideoPrepareTimer?.cancel()
                self.pendingVideoPrepareTimer = nil
                self.pendingVideoTakeID = nil
                self.pendingPreparedVideo = nil
                self.status = "Could not prepare video"
            }
        }
        pendingVideoPrepareTimer = timer
        timer.resume()
    }

    private func renderFirstPreparedFrame(for prepared: PreparedVideoTake) {
        videoPreparationQueue.async { [weak self, weak prepared] in
            guard let self, let prepared else { return }

            let frame: RenderedFrame? = autoreleasepool {
                let generator = AVAssetImageGenerator(asset: prepared.item.asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = prepared.outputSize
                guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
                    return nil
                }

                return FrameRenderer().render(
                    cgImage: cgImage,
                    settings: prepared.slide.settings,
                    outputSize: prepared.outputSize
                )
            }

            DispatchQueue.main.async { [weak self, weak prepared] in
                guard let self, let prepared else { return }
                guard self.pendingVideoTakeID == prepared.id, self.pendingPreparedVideo === prepared else { return }
                guard let frame else {
                    prepared.abandon()
                    self.pendingPreparedVideo = nil
                    self.pendingVideoTakeID = nil
                    self.pendingVideoPrepareTimer?.cancel()
                    self.pendingVideoPrepareTimer = nil
                    self.status = "Could not decode video"
                    return
                }

                prepared.firstFrame = frame
                self.commitPreparedVideoTransitionIfReady(prepared)
            }
        }
    }

    private func commitPreparedVideoTransitionIfReady(_ prepared: PreparedVideoTake) {
        guard let firstFrame = prepared.firstFrame else { return }
        commitPreparedVideoTransition(prepared, firstFrame: firstFrame)
    }

    private func commitPreparedVideoTransition(_ prepared: PreparedVideoTake, firstFrame: RenderedFrame) {
        guard pendingVideoTakeID == prepared.id, pendingPreparedVideo === prepared else {
            prepared.abandon()
            return
        }

        pendingVideoPrepareTimer?.cancel()
        pendingVideoPrepareTimer = nil
        pendingVideoTakeID = nil

        let transition: PendingTransition? = syncOutput {
            guard let currentFrame,
                  currentFrame.width == Int(prepared.outputSize.width),
                  currentFrame.height == Int(prepared.outputSize.height) else {
                return nil
            }
            return PendingTransition(frame: currentFrame, duration: prepared.transitionDuration)
        }
        let outgoingVideo = stopMediaOnly(preservingMediaForTransition: transition != nil)

        do {
            try startOutputIfNeeded(deviceID: prepared.deviceID, modeID: prepared.modeID)
        } catch {
            outgoingVideo?.stop()
            prepared.abandon()
            audioPump.stop()
            liveSlideID = nil
            liveTitle = "Black"
            previewImage = nil
            isRunning = false
            pendingPreparedVideo = nil
            status = error.localizedDescription
            return
        }

        activeOutputSize = prepared.outputSize
        activeFrameInterval = frameInterval(for: prepared.mode)
        activeSettings = prepared.slide.settings
        adoptScopedAccess(from: prepared)

        previewImage = nil
        videoOutput = prepared.videoOutput
        activeRenderItem = prepared.item
        latestVideoFrame = firstFrame

        beginTransition(transition, outgoingVideo: outgoingVideo)
        liveSlideID = prepared.slide.id
        liveTitle = prepared.slide.title
        isRunning = true

        let submitAudio = audioSubmitter()
        if transition != nil {
            audioPump.crossfade(
                to: prepared.url,
                loop: prepared.slide.settings.loopVideo,
                volume: prepared.slide.settings.volume,
                duration: prepared.transitionDuration,
                submit: submitAudio
            )
            let preparedItem = prepared.item
            let preparedSettings = prepared.slide.settings
            let preparedPlayer = prepared.player
            pendingPostDissolveActivation = { [weak self] in
                guard let self else { return }
                self.removePlayerTimeObserver()
                if let videoEndObserver = self.videoEndObserver {
                    NotificationCenter.default.removeObserver(videoEndObserver)
                    self.videoEndObserver = nil
                }
                self.previewPlayer = preparedPlayer
                let currentSeconds = preparedItem.currentTime().seconds
                self.videoCurrentTime = currentSeconds.isFinite ? max(0, currentSeconds) : 0
                self.updateDuration(from: preparedItem)
                self.installPlayerTimeObserver(for: preparedPlayer)
                self.installVideoEndObserver(for: preparedItem, settings: preparedSettings)
            }
        } else {
            previewPlayer = prepared.player
            videoCurrentTime = max(0, prepared.item.currentTime().seconds.isFinite ? prepared.item.currentTime().seconds : 0)
            updateDuration(from: prepared.item)
            installPlayerTimeObserver(for: prepared.player)
            installVideoEndObserver(for: prepared.item, settings: prepared.slide.settings)
            audioPump.start(
                url: prepared.url,
                loop: prepared.slide.settings.loopVideo,
                volume: prepared.slide.settings.volume,
                submit: submitAudio
            )
        }

        do {
            try syncOutput {
                var frame = firstFrame
                cancelOutgoingHandoffTimer()
                applyTransition(to: &frame)
                try submitFrame(frame)
            }
        } catch {
            status = error.localizedDescription
        }

        startVideoTimer(mode: prepared.mode)
        prepared.player.play()
        pendingPreparedVideo = nil
        status = transition != nil ? "Crossfading video" : "Live video"
    }

    private func prepareImageTransition(
        slide: MediaSlide,
        url: URL,
        deviceID: String,
        modeID: String,
        mode: VideoOutputMode,
        outputSize: CGSize,
        transitionDuration: Double
    ) {
        let takeID = UUID()
        pendingVideoTakeID = takeID
        let prepared = PreparedImageTake(
            id: takeID,
            slide: slide,
            url: url,
            deviceID: deviceID,
            modeID: modeID,
            mode: mode,
            outputSize: outputSize,
            transitionDuration: transitionDuration
        )
        pendingPreparedImage = prepared
        status = "Preparing image"

        videoPreparationQueue.async { [weak self, weak prepared] in
            guard let prepared else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            let result: (image: NSImage, frame: RenderedFrame)? = autoreleasepool {
                guard let image = NSImage(contentsOf: url),
                      let frame = FrameRenderer().renderImage(image, settings: slide.settings, outputSize: outputSize) else {
                    return nil
                }
                return (image, frame)
            }
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }

            DispatchQueue.main.async { [weak self, weak prepared] in
                guard let self, let prepared else { return }
                guard self.pendingVideoTakeID == prepared.id, self.pendingPreparedImage === prepared else { return }
                guard let result else {
                    self.pendingPreparedImage = nil
                    self.pendingVideoTakeID = nil
                    self.status = "Could not render image"
                    return
                }
                self.commitPreparedImageTransition(prepared, image: result.image, frame: result.frame)
            }
        }
    }

    private func commitPreparedImageTransition(_ prepared: PreparedImageTake, image: NSImage, frame: RenderedFrame) {
        guard pendingVideoTakeID == prepared.id, pendingPreparedImage === prepared else {
            return
        }
        pendingPreparedImage = nil
        pendingVideoTakeID = nil

        let transition: PendingTransition? = syncOutput {
            guard let currentFrame,
                  currentFrame.width == Int(prepared.outputSize.width),
                  currentFrame.height == Int(prepared.outputSize.height) else {
                return nil
            }
            return PendingTransition(frame: currentFrame, duration: prepared.transitionDuration)
        }
        let outgoingVideo = stopMediaOnly(preservingMediaForTransition: transition != nil)

        do {
            try startOutputIfNeeded(deviceID: prepared.deviceID, modeID: prepared.modeID)
        } catch {
            outgoingVideo?.stop()
            audioPump.stop()
            liveSlideID = nil
            liveTitle = "Black"
            previewImage = nil
            isRunning = false
            status = error.localizedDescription
            return
        }

        updateScopedAccess(url: prepared.url)
        activeOutputSize = prepared.outputSize
        activeFrameInterval = frameInterval(for: prepared.mode)
        activeSettings = prepared.slide.settings
        latestVideoFrame = nil

        beginTransition(transition, outgoingVideo: outgoingVideo)
        liveSlideID = prepared.slide.id
        liveTitle = prepared.slide.title
        isRunning = true

        if transition != nil {
            audioPump.fadeOut(duration: prepared.transitionDuration)
            pendingPostDissolveActivation = { [weak self] in
                guard let self else { return }
                self.removePlayerTimeObserver()
                if let videoEndObserver = self.videoEndObserver {
                    NotificationCenter.default.removeObserver(videoEndObserver)
                    self.videoEndObserver = nil
                }
                self.previewPlayer = nil
                self.previewImage = image
                self.videoCurrentTime = 0
                self.videoDuration = 0
            }
            startStillTransition(to: frame)
            status = "Crossfading image"
        } else {
            previewImage = image
            do {
                try syncOutput {
                    try submitFrame(frame)
                }
                status = "Live image"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func cancelPendingVideoPreparation() {
        pendingVideoPrepareTimer?.cancel()
        pendingVideoPrepareTimer = nil
        pendingVideoTakeID = nil
        pendingPreparedVideo?.abandon()
        pendingPreparedVideo = nil
        pendingPreparedImage = nil
        pendingPostDissolveActivation = nil
        transitionPreviewImage = nil
    }

    private func audioSubmitter() -> (Data, Int) -> Void {
        { [weak self] data, sampleFrameCount in
            guard let self else { return }
            self.audioOutputQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.outputDriver.submitAudioPCM16(data, sampleFrameCount: sampleFrameCount)
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.status = error.localizedDescription
                    }
                }
                self.auxiliarySinks.submit(audio: data, sampleFrameCount: sampleFrameCount)
            }
        }
    }

    private func installVideoEndObserver(for item: AVPlayerItem, settings: SlideSettings) {
        videoEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let self, settings.loopVideo else { return }
            self.audioPump.seek(to: .zero)
            item?.seek(to: .zero, completionHandler: { _ in
                self.previewPlayer?.play()
            })
        }
    }

    private func updateDuration(from item: AVPlayerItem) {
        Task { [weak self, weak item] in
            guard let item else { return }
            let duration = try? await item.asset.load(.duration)
            let seconds = duration?.seconds ?? 0
            await MainActor.run { [weak self, weak item] in
                guard let self, self.previewPlayer?.currentItem === item else { return }
                self.videoDuration = seconds.isFinite ? max(0, seconds) : 0
            }
        }
    }

    private func installPlayerTimeObserver(for player: AVPlayer) {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        playerTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            self.videoCurrentTime = seconds.isFinite ? max(0, seconds) : 0
        }
        rateObservation?.invalidate()
        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] _, change in
            DispatchQueue.main.async { [weak self] in
                self?.isPlaying = (change.newValue ?? 0) > 0
            }
        }
    }

    private func removePlayerTimeObserver() {
        if let playerTimeObserver, let player = previewPlayer {
            player.removeTimeObserver(playerTimeObserver)
        }
        playerTimeObserver = nil
        rateObservation?.invalidate()
        rateObservation = nil
        isPlaying = false
    }

    private func startVideoTimer(mode: VideoOutputMode) {
        let interval = frameInterval(for: mode)
        timer?.cancel()
        // Restart the tick clock so the first tick of a new take never reads
        // as a "drop" against the previous take's last submission.
        lastTimerTickHostTime = nil
        let timer = DispatchSource.makeTimerSource(queue: outputQueue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(interval * 1_000_000_000)), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.renderCurrentVideoFrame()
        }
        self.timer = timer
        timer.resume()
    }

    private func renderCurrentVideoFrame(forceCurrentTime: Bool = false) {
        autoreleasepool {
            guard let videoOutput else { return }

            // E3+ drop detection: compare wall-clock between consecutive timer
            // ticks against the configured frame interval. If the queue stalled
            // and a tick is delayed, the deficit (in whole frames) lands as
            // dropped frames. `forceCurrentTime` tides — operator-driven seeks
            // re-pull a frame off-cadence and shouldn't count as drops.
            if !forceCurrentTime {
                detectAndRecordDroppedFrames(at: CACurrentMediaTime())
            }

            var decodedFrame: RenderedFrame? = nil
            let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
            let chosenTime: CMTime
            if forceCurrentTime, let item = activeRenderItem {
                chosenTime = item.currentTime()
            } else if itemTime.isValid {
                chosenTime = itemTime
            } else if let item = activeRenderItem {
                chosenTime = item.currentTime()
            } else {
                chosenTime = .invalid
            }

            if chosenTime.isValid,
               (forceCurrentTime || videoOutput.hasNewPixelBuffer(forItemTime: chosenTime)),
               let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: chosenTime, itemTimeForDisplay: nil) {
                decodedFrame = renderer.renderPixelBuffer(pixelBuffer, settings: activeSettings, outputSize: activeOutputSize)
            }

            let transitionIsActive = activeTransition != nil
            if let decodedFrame {
                latestVideoFrame = decodedFrame
            }

            guard var frame = decodedFrame ?? (transitionIsActive ? latestVideoFrame : nil) else {
                return
            }

            do {
                try syncOutput {
                    cancelOutgoingHandoffTimer()
                    applyTransition(to: &frame)
                    try submitFrame(frame)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.status = error.localizedDescription
                }
            }

            if transitionIsActive, activeTransition == nil {
                firePendingPostDissolveActivation()
            }
        }
    }

    private func startStillTransition(to targetFrame: RenderedFrame) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: outputQueue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(activeFrameInterval * 1_000_000_000)), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.renderStillTransitionFrame(targetFrame)
        }
        self.timer = timer
        timer.resume()
    }

    private func renderStillTransitionFrame(_ targetFrame: RenderedFrame) {
        do {
            let frame = stillTransitionFrame(to: targetFrame)
            let didComplete = activeTransition == nil
            cancelOutgoingHandoffTimer()
            try submitFrame(frame, cacheAsCurrent: didComplete)
            if didComplete {
                timer?.cancel()
                timer = nil
                DispatchQueue.main.async { [weak self] in
                    self?.status = "Live image"
                }
                firePendingPostDissolveActivation()
            }
        } catch {
            timer?.cancel()
            timer = nil
            DispatchQueue.main.async { [weak self] in
                self?.status = error.localizedDescription
            }
        }
    }

    private func firePendingPostDissolveActivation() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Keep `transitionPreviewImage` populated past dissolve completion so the in-app
            // preview tile keeps showing the composed frame (with overlays) instead of falling
            // back to the raw `previewImage` / AVPlayer surface (B12f).
            guard let activation = self.pendingPostDissolveActivation else { return }
            self.pendingPostDissolveActivation = nil
            activation()
        }
    }

    private func republishComposedPreview() {
        let snapshot: (frame: RenderedFrame, canvas: CGSize)? = syncOutput {
            guard let frame = currentFrame else { return nil }
            return (frame, activeOutputSize)
        }
        guard let snapshot else { return }
        let composed = compositor.compose(
            baseFrame: snapshot.frame,
            overlays: compositorOverlays,
            canvasSize: snapshot.canvas
        )
        publishTransitionPreview(composed)
    }

    private func makeTransitionPreviewImage(from frame: RenderedFrame) -> CGImage? {
        let cfData = frame.data as CFData
        guard let provider = CGDataProvider(data: cfData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.rowBytes,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func publishTransitionPreview(_ frame: RenderedFrame) {
        guard let image = makeTransitionPreviewImage(from: frame) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.transitionPreviewImage = image
        }
    }

    private func pendingTransition(settings: PlayoutTransitionSettings, outputSize: CGSize) -> PendingTransition? {
        guard settings.crossfadeEnabled else { return nil }
        let duration = PlayoutTransitionSettings.clampedDuration(settings.crossfadeDuration)

        return syncOutput {
            guard let currentFrame,
                  currentFrame.width == Int(outputSize.width),
                  currentFrame.height == Int(outputSize.height) else {
                return nil
            }
            return PendingTransition(frame: currentFrame, duration: duration)
        }
    }

    private func beginTransition(_ transition: PendingTransition?, outgoingVideo: OutgoingVideoSource?) {
        syncOutput {
            stopActiveTransition(preservingOutgoingVideo: outgoingVideo)
            if let transition {
                activeTransition = ActiveTransition(
                    startFrame: transition.frame,
                    duration: transition.duration,
                    startTime: nil,
                    outgoingVideo: outgoingVideo
                )
            } else {
                outgoingVideo?.stop()
                cancelOutgoingHandoffTimer()
            }
        }
    }

    private func applyTransition(to frame: inout RenderedFrame) {
        guard let progress = transitionProgress(),
              let transition = activeTransition else { return }
        if progress >= 1 {
            stopActiveTransition()
            return
        }

        let startFrame = transitionStartFrame(for: transition)
        _ = renderer.blendInPlace(from: startFrame, into: &frame, progress: progress)
    }

    private func stillTransitionFrame(to targetFrame: RenderedFrame) -> RenderedFrame {
        guard let progress = transitionProgress(),
              let transition = activeTransition else { return targetFrame }
        if progress >= 1 {
            stopActiveTransition()
            return targetFrame
        }

        if activeTransition!.scratchFrame == nil {
            activeTransition!.scratchFrame = renderer.blankFrame(matching: targetFrame)
        }

        let startFrame = transitionStartFrame(for: transition)
        if renderer.blend(from: startFrame, to: targetFrame, into: &activeTransition!.scratchFrame!, progress: progress),
           let scratchFrame = activeTransition!.scratchFrame {
            return scratchFrame
        }

        stopActiveTransition()
        return targetFrame
    }

    private func transitionStartFrame(for transition: ActiveTransition) -> RenderedFrame {
        guard let outgoingVideo = transition.outgoingVideo else {
            return transition.startFrame
        }

        return renderOutgoingVideoFrame(outgoingVideo) ?? outgoingVideo.latestFrame ?? transition.startFrame
    }

    private func transitionProgress() -> Double? {
        let now = CACurrentMediaTime()
        if activeTransition?.startTime == nil {
            activeTransition?.startTime = now
            return 0
        }

        guard let transition = activeTransition,
              let startTime = transition.startTime else {
            return nil
        }

        return (now - startTime) / transition.duration
    }

    private func renderOutgoingVideoFrame(_ source: OutgoingVideoSource) -> RenderedFrame? {
        guard let item = source.player.currentItem else {
            return nil
        }

        let itemTime = source.videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        let chosenTime = itemTime.isValid ? itemTime : item.currentTime()
        guard source.videoOutput.hasNewPixelBuffer(forItemTime: chosenTime),
              let pixelBuffer = source.videoOutput.copyPixelBuffer(forItemTime: chosenTime, itemTimeForDisplay: nil),
              let frame = renderer.renderPixelBuffer(pixelBuffer, settings: source.settings, outputSize: source.outputSize) else {
            return source.latestFrame
        }

        source.latestFrame = frame
        return frame
    }

    private func startOutgoingHandoffTimer(for source: OutgoingVideoSource) {
        if outgoingHandoffSource === source, outgoingHandoffTimer != nil {
            return
        }
        cancelOutgoingHandoffTimer()
        outgoingHandoffSource = source

        let timer = DispatchSource.makeTimerSource(queue: outputQueue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(activeFrameInterval * 1_000_000_000)), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.renderOutgoingHandoffFrame(source)
        }
        outgoingHandoffTimer = timer
        timer.resume()
    }

    private func renderOutgoingHandoffFrame(_ source: OutgoingVideoSource) {
        autoreleasepool {
            guard activeTransition?.outgoingVideo === source || outgoingHandoffSource === source else {
                cancelOutgoingHandoffTimer()
                return
            }

            guard let frame = renderOutgoingVideoFrame(source) ?? source.latestFrame else {
                return
            }

            do {
                try submitFrame(frame)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.status = error.localizedDescription
                }
            }
        }
    }

    private func cancelOutgoingHandoffTimer() {
        outgoingHandoffTimer?.cancel()
        outgoingHandoffTimer = nil
        outgoingHandoffSource = nil
    }

    private func stopActiveTransition(preservingOutgoingVideo preservedOutgoingVideo: OutgoingVideoSource? = nil) {
        if outgoingHandoffSource !== preservedOutgoingVideo {
            cancelOutgoingHandoffTimer()
        }
        let outgoingToStop: OutgoingVideoSource?
        if let source = activeTransition?.outgoingVideo, source !== preservedOutgoingVideo {
            outgoingToStop = source
        } else {
            outgoingToStop = nil
        }
        activeTransition = nil
        if let outgoingToStop {
            DispatchQueue.main.async {
                outgoingToStop.stop()
            }
        }
    }

    private func submitFrame(_ frame: RenderedFrame, cacheAsCurrent: Bool = true) throws {
        // Compose the three-layer output (media → bug → message) before handing off to any
        // transport. When overlays are inert the call returns `frame` itself — no allocation.
        let composed = compositor.compose(
            baseFrame: frame,
            overlays: compositorOverlays,
            canvasSize: activeOutputSize
        )
        try outputDriver.submitVideoFrame(composed.data, width: composed.width, height: composed.height, rowBytes: composed.rowBytes)
        auxiliarySinks.submit(frame: composed)
        if !hasRenderedAnyFrame { hasRenderedAnyFrame = true }
        if cacheAsCurrent {
            // Cache the BASE frame, not the composed one. Transitions blend cached frames
            // with new media; if we cached composed frames the bug+message would get blended
            // and re-composited, doubling the overlay during a crossfade.
            currentFrame = frame
        }
        publishTransitionPreview(composed)
    }

    private func updateScopedAccess(url: URL) {
        if scopedURL == url {
            return
        }
        if scopedURLDidAccess {
            scopedURL?.stopAccessingSecurityScopedResource()
        }
        scopedURL = url
        scopedURLDidAccess = url.startAccessingSecurityScopedResource()
    }

    private func adoptScopedAccess(from prepared: PreparedVideoTake) {
        if scopedURLDidAccess {
            scopedURL?.stopAccessingSecurityScopedResource()
        }
        scopedURL = prepared.url
        scopedURLDidAccess = prepared.scopedURLDidAccess
        prepared.didTransferScopedAccess = true
    }

    private func syncOutput<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: outputQueueKey) != nil {
            return try work()
        }
        return try outputQueue.sync(execute: work)
    }

    private func drainAudioOutput() {
        audioOutputQueue.sync {}
    }

    private func frameInterval(for mode: VideoOutputMode) -> Double {
        max(1.0 / max(mode.framesPerSecond, 1), 1.0 / 60.0)
    }

    /// E3+ — drop detection. Computes the gap between consecutive timer ticks
    /// and converts a deficit larger than 1.5× the configured frame interval
    /// into a count of dropped frames. The 1.5× threshold absorbs normal
    /// scheduler jitter (~5–20 ms on a healthy mac) without producing false
    /// positives. Multi-frame stalls report the full deficit so a brief 3-
    /// frame skip lands as a single batched record on the counter.
    private func detectAndRecordDroppedFrames(at hostTime: CFTimeInterval) {
        defer { lastTimerTickHostTime = hostTime }
        guard let last = lastTimerTickHostTime else { return }
        let interval = activeFrameInterval
        guard interval > 0 else { return }
        let delta = hostTime - last
        // Ignore non-positive deltas (clock adjustment, scheduling oddity) so
        // we never record a negative drop.
        guard delta > 0 else { return }
        let expectedFrames = delta / interval
        let dropped = Int(expectedFrames.rounded(.down)) - 1
        guard dropped > 0 else { return }
        let now = Date()
        Task { @MainActor [droppedFrameCounter] in
            droppedFrameCounter.record(count: dropped, at: now)
        }
    }

    private struct PendingTransition {
        var frame: RenderedFrame
        var duration: Double
    }

    private struct ActiveTransition {
        var startFrame: RenderedFrame
        var duration: Double
        var startTime: CFTimeInterval?
        var outgoingVideo: OutgoingVideoSource?
        var scratchFrame: RenderedFrame? = nil
    }

    private final class PreparedVideoTake {
        let id: UUID
        let slide: MediaSlide
        let url: URL
        let scopedURLDidAccess: Bool
        let deviceID: String
        let modeID: String
        let mode: VideoOutputMode
        let outputSize: CGSize
        let transitionDuration: Double
        let item: AVPlayerItem
        let player: AVPlayer
        let videoOutput: AVPlayerItemVideoOutput
        var firstFrame: RenderedFrame?
        var didPreroll = false
        var didTransferScopedAccess = false

        init(
            id: UUID,
            slide: MediaSlide,
            url: URL,
            scopedURLDidAccess: Bool,
            deviceID: String,
            modeID: String,
            mode: VideoOutputMode,
            outputSize: CGSize,
            transitionDuration: Double,
            item: AVPlayerItem,
            player: AVPlayer,
            videoOutput: AVPlayerItemVideoOutput
        ) {
            self.id = id
            self.slide = slide
            self.url = url
            self.scopedURLDidAccess = scopedURLDidAccess
            self.deviceID = deviceID
            self.modeID = modeID
            self.mode = mode
            self.outputSize = outputSize
            self.transitionDuration = transitionDuration
            self.item = item
            self.player = player
            self.videoOutput = videoOutput
        }

        func abandon() {
            player.pause()
            releaseScopedAccessIfNeeded()
        }

        private func releaseScopedAccessIfNeeded() {
            guard scopedURLDidAccess, !didTransferScopedAccess else { return }
            url.stopAccessingSecurityScopedResource()
            didTransferScopedAccess = true
        }

        deinit {
            releaseScopedAccessIfNeeded()
        }
    }

    private final class PreparedImageTake {
        let id: UUID
        let slide: MediaSlide
        let url: URL
        let deviceID: String
        let modeID: String
        let mode: VideoOutputMode
        let outputSize: CGSize
        let transitionDuration: Double

        init(
            id: UUID,
            slide: MediaSlide,
            url: URL,
            deviceID: String,
            modeID: String,
            mode: VideoOutputMode,
            outputSize: CGSize,
            transitionDuration: Double
        ) {
            self.id = id
            self.slide = slide
            self.url = url
            self.deviceID = deviceID
            self.modeID = modeID
            self.mode = mode
            self.outputSize = outputSize
            self.transitionDuration = transitionDuration
        }
    }

    private final class OutgoingVideoSource {
        let player: AVPlayer
        let item: AVPlayerItem
        let videoOutput: AVPlayerItemVideoOutput
        let settings: SlideSettings
        let outputSize: CGSize
        let fallbackFrame: RenderedFrame
        let scopedURL: URL?
        let scopedURLDidAccess: Bool
        var latestFrame: RenderedFrame?
        var endObserver: NSObjectProtocol?
        private var didStop = false

        init(
            player: AVPlayer,
            item: AVPlayerItem,
            videoOutput: AVPlayerItemVideoOutput,
            settings: SlideSettings,
            outputSize: CGSize,
            fallbackFrame: RenderedFrame,
            scopedURL: URL?,
            scopedURLDidAccess: Bool
        ) {
            self.player = player
            self.item = item
            self.videoOutput = videoOutput
            self.settings = settings
            self.outputSize = outputSize
            self.fallbackFrame = fallbackFrame
            self.scopedURL = scopedURL
            self.scopedURLDidAccess = scopedURLDidAccess
            latestFrame = fallbackFrame
        }

        func stop() {
            guard !didStop else { return }
            didStop = true
            player.pause()
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
            if scopedURLDidAccess {
                scopedURL?.stopAccessingSecurityScopedResource()
            }
        }

        deinit {
            stop()
        }
    }
}
