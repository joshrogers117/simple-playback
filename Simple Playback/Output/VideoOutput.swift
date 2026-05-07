import Foundation
import SwiftUI

final class OutputSettingsStore: ObservableObject {
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
}

final class PreviewVideoOutputDriver: VideoOutputDriver {
    private(set) var status = "Software preview output"

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
        status = "Software preview running"
    }

    func stop() {
        status = "Software preview output"
    }

    func submitVideoFrame(_ data: Data, width: Int, height: Int, rowBytes: Int) throws {}
    func submitAudioPCM16(_ data: Data, sampleFrameCount: Int) throws {}
}

final class DeckLinkVideoOutputDriver: VideoOutputDriver {
    private let bridge = SPDeckLinkBridge()
    private(set) var status = "DeckLink idle"

    func availableDevices() -> [VideoOutputDevice] {
        let devices = bridge.availableDevices()
        status = bridge.runtimeStatus

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
        do {
            try bridge.start(withDeviceIdentifier: deviceID, modeIdentifier: modeID)
            status = bridge.runtimeStatus
        } catch {
            status = bridge.runtimeStatus
            throw VideoOutputError.deckLink(error.localizedDescription)
        }
    }

    func stop() {
        bridge.stop()
        status = "DeckLink stopped"
    }

    func submitVideoFrame(_ data: Data, width: Int, height: Int, rowBytes: Int) throws {
        do {
            try bridge.displayFrame(withBGRAData: data, width: width, height: height, rowBytes: rowBytes)
        } catch {
            status = bridge.runtimeStatus
            throw VideoOutputError.deckLink(error.localizedDescription)
        }
    }

    func submitAudioPCM16(_ data: Data, sampleFrameCount: Int) throws {
        do {
            try bridge.writeAudioPCM16Data(data, sampleFrameCount: sampleFrameCount)
        } catch {
            status = bridge.runtimeStatus
            throw VideoOutputError.deckLink(error.localizedDescription)
        }
    }
}
