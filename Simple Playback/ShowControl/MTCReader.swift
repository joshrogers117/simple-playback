import Foundation
import CoreMIDI

/// MIDI Time Code (MTC) reader.
///
/// MTC carries timecode as quarter-frame messages: 0xF1 0x0n where the high
/// nibble of n is the field index (0..7) and the low nibble is 4 data bits.
/// Eight quarter-frame messages spell out one full HH:MM:SS:FF (over two
/// frames of TC, so timing is lagged by one frame).
///
/// MTC also defines an MMC "Full Frame" message
/// (`F0 7F 7F 01 01 hh mm ss ff F7`) for absolute jumps. We accept both.
final class MTCReader {
    private var client = MIDIClientRef()
    private var input = MIDIPortRef()
    private var connectedSource: MIDIEndpointRef?

    let follower: TimecodeFollower

    /// Bits accumulated from quarter-frame messages, indexed 0..7.
    private var qfNibbles: [Int] = Array(repeating: 0, count: 8)
    private var qfReceived: Set<Int> = []
    private var qfRateBits: Int = 0

    private(set) var isRunning: Bool = false

    var onFrame: ((TimecodeValue, TimecodeJamSyncDecision) -> Void)?
    var onStateChanged: ((TimecodeEngagement) -> Void)?

    init() {
        self.follower = TimecodeFollower()
    }

    /// Lists available MIDI source endpoints by display name.
    static func availableSources() -> [(MIDIEndpointRef, String)] {
        let count = MIDIGetNumberOfSources()
        var out: [(MIDIEndpointRef, String)] = []
        for i in 0..<count {
            let endpoint = MIDIGetSource(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
            let nameString = name?.takeRetainedValue() as String? ?? "Source \(i)"
            out.append((endpoint, nameString))
        }
        return out
    }

    /// Connects to a MIDI source endpoint and arms the follower.
    func start(source: MIDIEndpointRef) throws {
        guard !isRunning else { return }
        let clientName = "Simple Playback MTC" as CFString
        var status = MIDIClientCreate(clientName, nil, nil, &client)
        if status != noErr { throw MTCReaderError.clientFailed(status) }
        let portName = "MTC In" as CFString
        status = MIDIInputPortCreateWithProtocol(client, portName, ._1_0, &input) { [weak self] eventList, _ in
            self?.handle(eventList: eventList)
        }
        if status != noErr { throw MTCReaderError.portFailed(status) }
        status = MIDIPortConnectSource(input, source, nil)
        if status != noErr { throw MTCReaderError.connectFailed(status) }
        connectedSource = source
        follower.arm()
        isRunning = true
        onStateChanged?(follower.engagement)
    }

    func stop() {
        guard isRunning else { return }
        if let src = connectedSource {
            MIDIPortDisconnectSource(input, src)
        }
        connectedSource = nil
        if input != 0 { MIDIPortDispose(input) }
        if client != 0 { MIDIClientDispose(client) }
        input = 0
        client = 0
        follower.disengage()
        isRunning = false
        onStateChanged?(follower.engagement)
    }

    deinit { stop() }

    // MARK: - Parsing

    private func handle(eventList: UnsafePointer<MIDIEventList>) {
        let evList = eventList.pointee
        var packet = evList.packet
        for _ in 0..<evList.numPackets {
            let words = withUnsafePointer(to: packet.words) { ptr -> [UInt32] in
                let buffer = UnsafeBufferPointer(
                    start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt32.self),
                    count: Int(packet.wordCount)
                )
                return Array(buffer)
            }
            for word in words {
                handle(word: word)
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
    }

    private func handle(word: UInt32) {
        // Universal MIDI Packet — for our needs we only care about
        // Channel Voice / System Common messages. Quarter-frame is
        // 0xF1 in MIDI 1.0 protocol (3-byte messages encoded in CV
        // group when using ump ._1_0).
        let msgType = (word >> 28) & 0xF
        // 0x2 = MIDI 1.0 Channel Voice, 0x1 = System message in UMP.
        if msgType == 0x1 {
            // System Common: bits 23..16 are status byte, 15..8 data1, 7..0 data2.
            let status = UInt8((word >> 16) & 0xFF)
            let data1 = UInt8((word >> 8) & 0xFF)
            if status == 0xF1 {
                handleQuarterFrame(byte: data1)
            }
        }
    }

    private func handleQuarterFrame(byte: UInt8) {
        let field = Int((byte >> 4) & 0x07)
        let nibble = Int(byte & 0x0F)
        qfNibbles[field] = nibble
        qfReceived.insert(field)
        if field == 7 {
            // Top half of hours + rate.
            qfRateBits = (nibble >> 1) & 0x03
        }
        if qfReceived.count == 8 {
            // Assemble TC.
            let frames = qfNibbles[0] | (qfNibbles[1] << 4)
            let seconds = qfNibbles[2] | (qfNibbles[3] << 4)
            let minutes = qfNibbles[4] | (qfNibbles[5] << 4)
            let hours = qfNibbles[6] | ((qfNibbles[7] & 0x01) << 4)
            let rate = qfRateBits
            let frameRate: TimecodeFrameRate
            switch rate {
            case 0: frameRate = .fps24
            case 1: frameRate = .fps25
            case 2: frameRate = .fps29_97_ndf
            case 3: frameRate = .fps30
            default: frameRate = .fps30
            }
            qfReceived.removeAll()
            // Sanity check.
            guard hours < 24, minutes < 60, seconds < 60, frames < frameRate.integerFPS else {
                return
            }
            let tc = TimecodeValue(
                hours: hours, minutes: minutes, seconds: seconds,
                frames: frames, frameRate: frameRate
            )
            let prev = follower.engagement
            let decision = follower.frameReceived(tc)
            onFrame?(tc, decision)
            if prev != follower.engagement {
                onStateChanged?(follower.engagement)
            }
        }
    }
}

enum MTCReaderError: Error, Equatable {
    case clientFailed(OSStatus)
    case portFailed(OSStatus)
    case connectFailed(OSStatus)
}
