import Foundation
import SwiftUI

final class OutputSettingsStore: ObservableObject {
    static let shared = OutputSettingsStore()

    private static let selectedDeviceKey = "output.selectedDeviceID"
    private static let selectedModeKey = "output.selectedModeID"

    private let defaults: UserDefaults

    @Published var selectedDeviceID: String? {
        didSet { persist(selectedDeviceID, key: Self.selectedDeviceKey) }
    }

    @Published var selectedModeID: String? {
        didSet { persist(selectedModeID, key: Self.selectedModeKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedDeviceID = defaults.string(forKey: Self.selectedDeviceKey)
        selectedModeID = defaults.string(forKey: Self.selectedModeKey)
    }

    func selectDevice(_ deviceID: String?, using playback: PlaybackController) {
        selectedDeviceID = deviceID
        selectedModeID = playback.defaultModeID(deviceID: deviceID, current: selectedModeID)
    }

    func applyDefaults(using playback: PlaybackController) {
        let deviceID = playback.defaultDeviceID(current: selectedDeviceID)
        selectedDeviceID = deviceID
        selectedModeID = playback.defaultModeID(deviceID: deviceID, current: selectedModeID)
    }

    private func persist(_ value: String?, key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

struct VideoOutputMode: Identifiable, Hashable {
    var id: String
    var name: String
    var width: Int
    var height: Int
    var frameDuration: Int64
    var timeScale: Int64

    var framesPerSecond: Double {
        frameDuration > 0 ? Double(timeScale) / Double(frameDuration) : 30
    }

    static let preview1080p30 = VideoOutputMode(
        id: "preview-mode:1080p30",
        name: "1080p30",
        width: 1920,
        height: 1080,
        frameDuration: 1,
        timeScale: 30
    )
}

struct VideoOutputDevice: Identifiable, Hashable {
    enum Backend: String, Hashable {
        case deckLink
        case preview
    }

    var id: String
    var name: String
    var backend: Backend
    var modes: [VideoOutputMode]
}

protocol VideoOutputDriver: AnyObject {
    var status: String { get }
    func availableDevices() -> [VideoOutputDevice]
    func start(deviceID: String, modeID: String) throws
    func stop()
    func submitVideoFrame(_ data: Data, width: Int, height: Int, rowBytes: Int) throws
    func submitAudioPCM16(_ data: Data, sampleFrameCount: Int) throws

    /// Latest DeckLink REF / genlock lock state, when this driver wraps a DeckLink output.
    /// Returns `nil` for software-only drivers (preview, future Syphon, NDI). Re-queries the
    /// underlying transport on every read so callers can pull at status-tick cadence.
    var deckLinkReferenceState: DeckLinkTransportSink.ReferenceState? { get }
}

extension VideoOutputDriver {
    var deckLinkReferenceState: DeckLinkTransportSink.ReferenceState? { nil }
}

enum VideoOutputError: LocalizedError {
    case deviceNotFound
    case modeNotFound
    case deckLink(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            "Selected output device was not found."
        case .modeNotFound:
            "Selected output mode was not found."
        case .deckLink(let message):
            message
        }
    }
}

final class CompositeVideoOutputDriver: VideoOutputDriver {
    private let deckLinkDriver = DeckLinkVideoOutputDriver()
    private let previewDriver = PreviewVideoOutputDriver()
    private var activeDriver: VideoOutputDriver?

    var status: String {
        activeDriver?.status ?? deckLinkDriver.status
    }

    func availableDevices() -> [VideoOutputDevice] {
        let deckLinkDevices = deckLinkDriver.availableDevices()
        return deckLinkDevices + previewDriver.availableDevices()
    }

    func start(deviceID: String, modeID: String) throws {
        let devices = availableDevices()
        guard let device = devices.first(where: { $0.id == deviceID }) else {
            throw VideoOutputError.deviceNotFound
        }

        let driver: VideoOutputDriver = device.backend == .deckLink ? deckLinkDriver : previewDriver
        try driver.start(deviceID: deviceID, modeID: modeID)
        activeDriver = driver
    }

    func stop() {
        activeDriver?.stop()
        activeDriver = nil
    }

    func submitVideoFrame(_ data: Data, width: Int, height: Int, rowBytes: Int) throws {
        try activeDriver?.submitVideoFrame(data, width: width, height: height, rowBytes: rowBytes)
    }

    func submitAudioPCM16(_ data: Data, sampleFrameCount: Int) throws {
        try activeDriver?.submitAudioPCM16(data, sampleFrameCount: sampleFrameCount)
    }

    var deckLinkReferenceState: DeckLinkTransportSink.ReferenceState? {
        activeDriver?.deckLinkReferenceState
    }
}

/// Adapts a `VideoOutputMode` into the Stage shape a sink needs at start time. Used by the
/// driver shims while the project still drives output via (deviceID, modeID); once cues
/// resolve to Stage IDs (B5c+) this helper goes away.
private func transportStage(forMode mode: VideoOutputMode) -> TransportSinkStage {
    TransportSinkStage(
        width: mode.width,
        height: mode.height,
        frameRateNumerator: Int(mode.timeScale),
        frameRateDenominator: Int(mode.frameDuration)
    )
}

final class PreviewVideoOutputDriver: VideoOutputDriver {
    private let sink = PreviewTransportSink()
    var status: String { sink.status }

    func availableDevices() -> [VideoOutputDevice] {
        [
            VideoOutputDevice(
                id: "preview:software",
                name: "Software Preview",
                backend: .preview,
                modes: [.preview1080p30]
            )
        ]
    }

    func start(deviceID: String, modeID: String) throws {
        guard deviceID == "preview:software" else { throw VideoOutputError.deviceNotFound }
        guard modeID == VideoOutputMode.preview1080p30.id else { throw VideoOutputError.modeNotFound }
        try sink.start(stage: transportStage(forMode: .preview1080p30))
    }

    func stop() {
        sink.stop()
    }

    func submitVideoFrame(_ data: Data, width: Int, height: Int, rowBytes: Int) throws {
        try sink.submit(frame: RenderedFrame(data: data, width: width, height: height, rowBytes: rowBytes))
    }

    func submitAudioPCM16(_ data: Data, sampleFrameCount: Int) throws {
        try sink.submit(audio: data, sampleFrameCount: sampleFrameCount)
    }
}

final class DeckLinkVideoOutputDriver: VideoOutputDriver {
    private let discoveryBridge = SPDeckLinkBridge()
    private var activeSink: DeckLinkTransportSink?
    private var lastSinkStatus: String?

    var status: String {
        if let activeSink, activeSink.isRunning { return activeSink.status }
        if let lastSinkStatus { return lastSinkStatus }
        return discoveryBridge.runtimeStatus
    }

    func availableDevices() -> [VideoOutputDevice] {
        let devices = discoveryBridge.availableDevices()
        return devices.map { device in
            VideoOutputDevice(
                id: device.identifier,
                name: device.name,
                backend: .deckLink,
                modes: device.modes.map { mode in
                    VideoOutputMode(
                        id: mode.identifier,
                        name: mode.name,
                        width: mode.width,
                        height: mode.height,
                        frameDuration: mode.frameDuration,
                        timeScale: mode.timeScale
                    )
                }
            )
        }
    }

    func start(deviceID: String, modeID: String) throws {
        if let activeSink, activeSink.deviceID == deviceID, activeSink.modeID == modeID {
            // Existing sink can re-arm; new stage is derived from the same mode.
        } else {
            activeSink?.stop()
            activeSink = DeckLinkTransportSink(deviceID: deviceID, modeID: modeID)
        }

        guard let activeSink else { return }
        let mode = availableDevices()
            .first(where: { $0.id == deviceID })?.modes
            .first(where: { $0.id == modeID })
        let stage = mode.map(transportStage(forMode:))
            ?? TransportSinkStage(width: 1920, height: 1080, frameRateNumerator: 30, frameRateDenominator: 1)
        do {
            try activeSink.start(stage: stage)
            lastSinkStatus = activeSink.status
        } catch {
            lastSinkStatus = activeSink.status
            throw error
        }
    }

    func stop() {
        activeSink?.stop()
        lastSinkStatus = "DeckLink stopped"
    }

    func submitVideoFrame(_ data: Data, width: Int, height: Int, rowBytes: Int) throws {
        guard let activeSink else { return }
        do {
            try activeSink.submit(frame: RenderedFrame(data: data, width: width, height: height, rowBytes: rowBytes))
        } catch {
            lastSinkStatus = activeSink.status
            throw error
        }
    }

    func submitAudioPCM16(_ data: Data, sampleFrameCount: Int) throws {
        guard let activeSink else { return }
        do {
            try activeSink.submit(audio: data, sampleFrameCount: sampleFrameCount)
        } catch {
            lastSinkStatus = activeSink.status
            throw error
        }
    }

    var deckLinkReferenceState: DeckLinkTransportSink.ReferenceState? {
        guard let activeSink, activeSink.isRunning else { return nil }
        return activeSink.pollReferenceState()
    }
}
