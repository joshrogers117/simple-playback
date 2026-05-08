import Foundation
import Network

/// Registry of subscribers for state push.
///
/// Keeps an OSC-pushable list of `(host, port)` endpoints and a separate
/// list of WebSocket sinks. The state-push pump (`SubscriptionPump`) iterates
/// these at 10 Hz when at least one subscriber exists.
final class SubscriptionRegistry {
    struct OSCSubscriber: Hashable {
        let host: String
        let port: UInt16
        let transport: OSCTransportKind
    }

    /// Closure-driven WebSocket sink. The HTTP server installs the closure when
    /// a `/api/v1/events` connection upgrades.
    final class WebSocketSink: Hashable {
        let id = UUID()
        let send: (Data) -> Void
        init(send: @escaping (Data) -> Void) {
            self.send = send
        }
        static func == (lhs: WebSocketSink, rhs: WebSocketSink) -> Bool {
            lhs.id == rhs.id
        }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private let queue = DispatchQueue(label: "com.josh.simpleplayback.showcontrol.subs")
    private var oscSubs: Set<OSCSubscriber> = []
    private var wsSinks: Set<WebSocketSink> = []
    private var oscConnections: [OSCSubscriber: NWConnection] = [:]

    init() {}

    var hasSubscribers: Bool {
        queue.sync { !oscSubs.isEmpty || !wsSinks.isEmpty }
    }

    func subscribe(host: String, port: UInt16, transport: OSCTransportKind) {
        let sub = OSCSubscriber(host: host, port: port, transport: transport)
        queue.sync {
            oscSubs.insert(sub)
            // Open the outbound connection lazily.
            if oscConnections[sub] == nil {
                let endpoint = NWEndpoint.hostPort(
                    host: NWEndpoint.Host(host),
                    port: NWEndpoint.Port(rawValue: port) ?? .any
                )
                let params: NWParameters = transport == .udp ? .udp : .tcp
                let conn = NWConnection(to: endpoint, using: params)
                conn.start(queue: queue)
                oscConnections[sub] = conn
            }
        }
    }

    func unsubscribe(host: String, port: UInt16) {
        queue.sync {
            let toRemove = oscSubs.filter { $0.host == host && $0.port == port }
            for s in toRemove {
                oscSubs.remove(s)
                if let c = oscConnections.removeValue(forKey: s) {
                    c.cancel()
                }
            }
        }
    }

    func addWebSocket(_ sink: WebSocketSink) {
        queue.sync { _ = wsSinks.insert(sink) }
    }

    func removeWebSocket(_ sink: WebSocketSink) {
        queue.sync { _ = wsSinks.remove(sink) }
    }

    /// Sends the same OSC packet to every OSC subscriber.
    func broadcastOSC(_ message: OSCMessage) {
        queue.sync {
            for sub in oscSubs {
                guard let conn = oscConnections[sub] else { continue }
                let packet: Data
                switch sub.transport {
                case .udp:
                    packet = message.data()
                case .tcp:
                    packet = framedSize(for: .tcp, packet: message.data())
                }
                conn.send(content: packet, completion: .contentProcessed { _ in })
            }
        }
    }

    /// Sends a JSON payload to every WebSocket subscriber.
    func broadcastWebSocket(_ data: Data) {
        let sinks: [WebSocketSink] = queue.sync { Array(wsSinks) }
        for sink in sinks {
            sink.send(data)
        }
    }

    func cancelAll() {
        queue.sync {
            for conn in oscConnections.values { conn.cancel() }
            oscConnections.removeAll()
            oscSubs.removeAll()
            wsSinks.removeAll()
        }
    }
}
