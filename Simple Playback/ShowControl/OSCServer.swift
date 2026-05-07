import Foundation
import Network

/// OSC server that listens on UDP and TCP.
///
/// UDP is connectionless — each datagram is decoded as one OSC packet. Replies
/// go back to the sender's `host:replyPort` (default 53011, configurable per
/// `/sp/udpReplyPort` in a future revision; for Phase D we reply to the
/// sender's actual ephemeral port to match common practice and ease testing).
///
/// TCP frames OSC packets per the SLIP-style "size-prefixed" convention used
/// by QLab and the wider OSC ecosystem: a 4-byte big-endian size prefix, then
/// the OSC packet bytes.
final class OSCServer {
    struct Configuration {
        var host: String = "127.0.0.1"
        var udpPort: UInt16 = 53000
        var tcpPort: UInt16 = 53000
        var udpReplyPort: UInt16 = 53011
        var defaultCapabilities: Set<ShowControlCapability> = [.read, .fire]
        init() {}
    }

    var configuration: Configuration
    weak var dispatcher: ShowControlDispatcher?
    var subscriptions: SubscriptionRegistry?

    private var udpListener: NWListener?
    private var tcpListener: NWListener?
    private var udpConnections: [ObjectIdentifier: NWConnection] = [:]
    private var tcpConnections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.josh.simpleplayback.osc.server")

    private(set) var isRunning: Bool = false

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func start() throws {
        guard !isRunning else { return }
        try startUDP()
        try startTCP()
        isRunning = true
    }

    func stop() {
        udpListener?.cancel()
        tcpListener?.cancel()
        udpListener = nil
        tcpListener = nil
        for c in udpConnections.values { c.cancel() }
        for c in tcpConnections.values { c.cancel() }
        udpConnections.removeAll()
        tcpConnections.removeAll()
        isRunning = false
    }

    deinit { stop() }

    // MARK: - UDP

    private func startUDP() throws {
        let params = NWParameters.udp
        let host = configuration.host
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: configuration.udpPort) ?? .any
        )
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.handleUDPConnection(connection)
        }
        listener.stateUpdateHandler = { [weak self] _ in _ = self }
        listener.start(queue: queue)
        udpListener = listener
    }

    private func handleUDPConnection(_ conn: NWConnection) {
        udpConnections[ObjectIdentifier(conn)] = conn
        receiveUDP(on: conn)
    }

    private func receiveUDP(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handleIncoming(
                    data: data,
                    transport: .udp,
                    sender: conn.endpoint,
                    sendReply: { reply in
                        let packet = framedSize(for: .udp, packet: reply)
                        conn.send(content: packet, completion: .contentProcessed { _ in })
                    }
                )
            }
            if error == nil {
                self.receiveUDP(on: conn)
            } else {
                conn.cancel()
                self.udpConnections.removeValue(forKey: ObjectIdentifier(conn))
            }
        }
    }

    // MARK: - TCP

    private func startTCP() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: NWEndpoint.Port(rawValue: configuration.tcpPort) ?? .any
        )
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.handleTCPConnection(connection)
        }
        listener.start(queue: queue)
        tcpListener = listener
    }

    private func handleTCPConnection(_ conn: NWConnection) {
        tcpConnections[ObjectIdentifier(conn)] = conn
        let buffer = TCPFrameBuffer()
        receiveTCP(on: conn, buffer: buffer)
    }

    private func receiveTCP(on conn: NWConnection, buffer: TCPFrameBuffer) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                buffer.append(data)
                while let packet = buffer.nextPacket() {
                    self.handleIncoming(
                        data: packet,
                        transport: .tcp,
                        sender: conn.endpoint,
                        sendReply: { reply in
                            let framed = framedSize(for: .tcp, packet: reply)
                            conn.send(content: framed, completion: .contentProcessed { _ in })
                        }
                    )
                }
            }
            if let error {
                _ = error
                conn.cancel()
                self.tcpConnections.removeValue(forKey: ObjectIdentifier(conn))
                return
            }
            if isComplete {
                conn.cancel()
                self.tcpConnections.removeValue(forKey: ObjectIdentifier(conn))
                return
            }
            self.receiveTCP(on: conn, buffer: buffer)
        }
    }

    // MARK: - Common

    private func handleIncoming(
        data: Data,
        transport: OSCTransportKind,
        sender: NWEndpoint,
        sendReply: @escaping (Data) -> Void
    ) {
        guard let dispatcher = dispatcher else { return }
        let messages: [OSCMessage]
        do {
            messages = try OSCMessage.decodePacket(data)
        } catch {
            let reply = OSCMessage(
                address: "/reply",
                arguments: [.string(#"{"apiVersion":1,"status":"error","error":"decode_failed"}"#)]
            )
            sendReply(reply.data())
            return
        }

        let (host, port) = endpointHostPort(sender)

        for message in messages {
            guard let action = OSCAddressMap.action(for: message) else {
                let reply = OSCMessage(
                    address: "/reply",
                    arguments: [.string(ShowControlReplyEnvelope.jsonString(
                        address: message.address,
                        result: .rejected(reason: "unknown_address")
                    ))]
                )
                sendReply(reply.data())
                continue
            }

            // Subscriptions: register the source endpoint when address asked.
            if case let .subscribe(h, p) = action {
                subscriptions?.subscribe(host: h, port: p, transport: transport)
            }
            if case let .unsubscribe(h, p) = action {
                subscriptions?.unsubscribe(host: h, port: p)
            }

            let result = dispatcher.dispatch(
                action,
                source: .osc(host: host, port: port, transport: transport),
                capabilities: configuration.defaultCapabilities
            )
            let reply = OSCMessage(
                address: "/reply",
                arguments: [.string(ShowControlReplyEnvelope.jsonString(
                    address: message.address,
                    result: result
                ))]
            )
            sendReply(reply.data())
        }
    }
}

private func endpointHostPort(_ endpoint: NWEndpoint) -> (String, UInt16) {
    switch endpoint {
    case let .hostPort(host, port):
        return (host.debugDescription, port.rawValue)
    default:
        return (endpoint.debugDescription, 0)
    }
}

/// Frames an OSC packet for the appropriate transport.
/// - UDP: packet as-is.
/// - TCP: 4-byte big-endian size prefix.
func framedSize(for transport: OSCTransportKind, packet: Data) -> Data {
    switch transport {
    case .udp:
        return packet
    case .tcp:
        var out = Data()
        var size = UInt32(packet.count).bigEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        out.append(packet)
        return out
    }
}

/// Reassembles size-prefixed OSC frames from a TCP byte stream.
final class TCPFrameBuffer {
    private var buffer = Data()

    func append(_ data: Data) { buffer.append(data) }

    func nextPacket() -> Data? {
        guard buffer.count >= 4 else { return nil }
        let size: UInt32 = buffer.withUnsafeBytes { ptr -> UInt32 in
            var be: UInt32 = 0
            withUnsafeMutableBytes(of: &be) { dest in
                _ = dest.copyBytes(from: ptr.bindMemory(to: UInt8.self).prefix(4))
            }
            return UInt32(bigEndian: be)
        }
        let total = 4 + Int(size)
        guard buffer.count >= total else { return nil }
        let packet = buffer.subdata(in: 4..<total)
        buffer.removeSubrange(0..<total)
        return packet
    }
}
