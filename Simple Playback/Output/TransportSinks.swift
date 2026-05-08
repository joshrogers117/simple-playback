import Foundation

/// `TransportSink` backed by `SPDeckLinkBridge`. Each instance owns its own bridge, so a
/// multi-port future (Fill+Key on a Duo 2, separate Program+Confidence DeckLinks) becomes
/// "register multiple sinks with the router" rather than another rewrite.
///
/// The bridge layer still gates v1 to a single DeckLink at a time today; that constraint is
/// a B6/B7 deliverable, not a sink-protocol limitation.
final class DeckLinkTransportSink: TransportSink {
    let sinkID: String
    let label: String
    let deviceID: String
    let modeID: String

    private(set) var status: String
    private(set) var isRunning: Bool = false
    private(set) var activeStage: TransportSinkStage?

    private let bridge: SPDeckLinkBridge

    init(deviceID: String, modeID: String, bridge: SPDeckLinkBridge = SPDeckLinkBridge()) {
        self.deviceID = deviceID
        self.modeID = modeID
        self.bridge = bridge
        self.sinkID = "decklink:\(deviceID):\(modeID)"
        self.label = "DeckLink \(deviceID) (\(modeID))"
        self.status = bridge.runtimeStatus
    }

    func start(stage: TransportSinkStage) throws {
        if isRunning, activeStage == stage { return }
        if isRunning { stop() }
        do {
            try bridge.start(withDeviceIdentifier: deviceID, modeIdentifier: modeID)
            status = bridge.runtimeStatus
            isRunning = true
            activeStage = stage
        } catch {
            status = bridge.runtimeStatus
            throw VideoOutputError.deckLink(error.localizedDescription)
        }
    }

    func stop() {
        guard isRunning else { return }
        bridge.stop()
        isRunning = false
        activeStage = nil
        status = "DeckLink stopped"
    }

    func submit(frame: RenderedFrame) throws {
        guard isRunning else { return }
        do {
            try bridge.displayFrame(
                withBGRAData: frame.data,
                width: frame.width,
                height: frame.height,
                rowBytes: frame.rowBytes
            )
        } catch {
            status = bridge.runtimeStatus
            throw VideoOutputError.deckLink(error.localizedDescription)
        }
    }

    func submit(audio: Data, sampleFrameCount: Int) throws {
        guard isRunning else { return }
        do {
            try bridge.writeAudioPCM16Data(audio, sampleFrameCount: sampleFrameCount)
        } catch {
            status = bridge.runtimeStatus
            throw VideoOutputError.deckLink(error.localizedDescription)
        }
    }
}

/// `TransportSink` for the in-app software preview. The compositor's frame is already
/// surfaced to the operator via SwiftUI; this sink exists so the preview path participates
/// in the router (status/lifecycle parity, single submit fan-out path).
final class PreviewTransportSink: TransportSink {
    let sinkID = "preview:software"
    let label = "Software Preview"

    private(set) var status: String = "Software preview output"
    private(set) var isRunning: Bool = false
    private(set) var activeStage: TransportSinkStage?

    func start(stage: TransportSinkStage) throws {
        isRunning = true
        activeStage = stage
        status = "Software preview running"
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        activeStage = nil
        status = "Software preview output"
    }

    func submit(frame: RenderedFrame) throws {}
    func submit(audio: Data, sampleFrameCount: Int) throws {}
}
