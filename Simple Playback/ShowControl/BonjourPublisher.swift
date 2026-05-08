import Foundation
import Network

/// Publishes Bonjour/mDNS service records for the show-control transports.
///
/// Two service types are advertised:
/// - `_simpleplayback._udp` for OSC over UDP (port 53000 by default).
/// - `_simpleplayback._tcp` for OSC over TCP and HTTP/JSON twin
///   (port 53001 for HTTP, 53000 for OSC TCP — we publish HTTP since
///    OSCQuery clients expect HTTP next to OSC).
///
/// TXT records carry product version, OSCQuery URL, workspace name.
final class BonjourPublisher {
    struct Configuration {
        var serviceName: String = "Simple Playback"
        var oscUDPPort: UInt16 = 53000
        var httpPort: UInt16 = 53001
        var workspaceName: String = ""
        var version: String = "1.0"
        init() {}
    }

    var configuration: Configuration

    private var udpListener: NWListener?
    private var tcpListener: NWListener?
    private let queue = DispatchQueue(label: "com.josh.simpleplayback.bonjour")

    private(set) var isRunning: Bool = false

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Starts publishing both service types. Idempotent — calling start while
    /// already running is a no-op.
    func start() throws {
        guard !isRunning else { return }
        try publishUDP()
        try publishTCP()
        isRunning = true
    }

    func stop() {
        udpListener?.cancel()
        tcpListener?.cancel()
        udpListener = nil
        tcpListener = nil
        isRunning = false
    }

    deinit { stop() }

    private func txtRecord() -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt["version"] = configuration.version
        txt["product"] = "simpleplayback"
        txt["api"] = "v1"
        txt["oscquery"] = "http://localhost:\(configuration.httpPort)"
        if !configuration.workspaceName.isEmpty {
            txt["workspace"] = configuration.workspaceName
        }
        txt["transport"] = "osc-udp,osc-tcp,http,websocket,oscquery"
        return txt
    }

    private func publishUDP() throws {
        let params = NWParameters.udp
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: configuration.oscUDPPort) ?? .any)
        listener.service = NWListener.Service(
            name: configuration.serviceName,
            type: "_simpleplayback._udp",
            domain: nil,
            txtRecord: txtRecord()
        )
        listener.newConnectionHandler = { conn in
            // We don't accept inbound connections here — the OSCServer owns
            // the actual UDP socket. This listener is purely for the Bonjour
            // advertisement. Cancel any inbound to avoid resource accumulation.
            conn.cancel()
        }
        listener.start(queue: queue)
        udpListener = listener
    }

    private func publishTCP() throws {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: configuration.httpPort) ?? .any)
        listener.service = NWListener.Service(
            name: configuration.serviceName,
            type: "_simpleplayback._tcp",
            domain: nil,
            txtRecord: txtRecord()
        )
        listener.newConnectionHandler = { conn in conn.cancel() }
        listener.start(queue: queue)
        tcpListener = listener
    }
}

/// Discovers other Simple Playback instances on the LAN. Used (in v2) for
/// main+backup follow-mode and (in v1 tests) to verify our advertisement is
/// findable.
final class BonjourBrowser {
    struct DiscoveredService: Hashable {
        let name: String
        let type: String
        let txtRecord: [String: String]
    }

    private var udpBrowser: NWBrowser?
    private var tcpBrowser: NWBrowser?
    private let queue = DispatchQueue(label: "com.josh.simpleplayback.bonjour.browser")
    private var found: Set<DiscoveredService> = []
    private let foundQueue = DispatchQueue(label: "com.josh.simpleplayback.bonjour.found")

    var onChange: (([DiscoveredService]) -> Void)?

    init() {}

    func start() {
        startBrowser(type: "_simpleplayback._udp", store: &udpBrowser)
        startBrowser(type: "_simpleplayback._tcp", store: &tcpBrowser)
    }

    func stop() {
        udpBrowser?.cancel()
        tcpBrowser?.cancel()
        udpBrowser = nil
        tcpBrowser = nil
    }

    private func startBrowser(type: String, store: inout NWBrowser?) {
        let descriptor = NWBrowser.Descriptor.bonjour(type: type, domain: nil)
        let browser = NWBrowser(for: descriptor, using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var seen: Set<DiscoveredService> = []
            for result in results {
                if case let NWEndpoint.service(name, t, _, _) = result.endpoint {
                    var txt: [String: String] = [:]
                    if case let .bonjour(record) = result.metadata {
                        for key in record.dictionary.keys {
                            if let v = record[key] {
                                txt[key] = v
                            }
                        }
                    }
                    seen.insert(DiscoveredService(name: name, type: t, txtRecord: txt))
                }
            }
            self.foundQueue.async {
                self.found.formUnion(seen)
                self.onChange?(Array(self.found))
            }
        }
        browser.start(queue: queue)
        store = browser
    }
}
