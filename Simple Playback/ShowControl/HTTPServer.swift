import Foundation
import Network
import CryptoKit

/// Minimal HTTP/1.1 server with WebSocket upgrade support.
///
/// We support exactly the routes the show-control surface needs:
/// - `POST /api/v1/...` — dispatch a `ShowControlAction`.
/// - `GET /api/v1/state` — full state snapshot.
/// - `GET /api/v1/cues` — cue list.
/// - `GET /api/v1/cue/{id}` — single cue detail.
/// - `GET /api/v1/events` with `Upgrade: websocket` — push-state stream.
/// - `GET /` — OSCQuery namespace (handled by `OSCQueryServer`).
///
/// Localhost-only by default. Bearer-token auth optional; when no token store
/// is configured, the server uses the configured default capability set.
final class HTTPServer {
    struct Configuration {
        var host: String = "127.0.0.1"
        var port: UInt16 = 53001
        var defaultCapabilities: Set<ShowControlCapability> = [.read, .fire]
        init() {}
    }

    var configuration: Configuration
    var dispatcher: ShowControlDispatcher?
    var subscriptions: SubscriptionRegistry?
    var tokens: AuthTokenStore?

    /// Optional handler for OSCQuery requests. Set by the OSCQueryServer.
    var oscQueryHandler: ((String, [String: String]) -> (status: Int, body: Data, contentType: String)?)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.josh.simpleplayback.http.server")

    private(set) var isRunning: Bool = false

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func start() throws {
        guard !isRunning else { return }
        let params = NWParameters.tcp
        let listener = try NWListener(
            using: params,
            on: NWEndpoint.Port(rawValue: configuration.port) ?? .any
        )
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.handleConnection(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        isRunning = true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        // `connections` is mutated on `queue` by handleConnection + receive
        // callbacks. Drain on the same queue so we don't race with an
        // in-flight callback adding or removing entries.
        queue.sync {
            for c in connections.values { c.cancel() }
            connections.removeAll()
        }
        isRunning = false
    }

    deinit { stop() }

    private func handleConnection(_ conn: NWConnection) {
        connections[ObjectIdentifier(conn)] = conn
        let buffer = HTTPRequestBuffer()
        receive(on: conn, buffer: buffer)
    }

    private func receive(on conn: NWConnection, buffer: HTTPRequestBuffer) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                buffer.append(data)
                while let req = buffer.nextRequest() {
                    self.respond(to: req, on: conn)
                    if req.isWebSocketUpgrade {
                        return // connection has switched protocols; receive loop now WS-driven
                    }
                }
            }
            if let error {
                _ = error
                conn.cancel()
                self.connections.removeValue(forKey: ObjectIdentifier(conn))
                return
            }
            if isComplete {
                conn.cancel()
                self.connections.removeValue(forKey: ObjectIdentifier(conn))
                return
            }
            self.receive(on: conn, buffer: buffer)
        }
    }

    /// Outcome of `respond(to:)` — what the connection layer should write.
    /// Extracting the decision here makes the request-routing logic
    /// testable without a real `NWConnection`. The IO-side `respond(to:on:)`
    /// is a thin switch over this outcome.
    enum RespondOutcome: Equatable {
        /// Write a normal HTTP response with the given status + body.
        case write(status: Int, body: Data, contentType: String, keepAlive: Bool)
        /// Write a structured JSON error envelope (404 unknown_route,
        /// 401 missing_capability, 503 no_runtime, etc.).
        case writeError(status: Int, jsonError: String, keepAlive: Bool)
        /// Begin a WebSocket upgrade — the connection layer writes the
        /// 101 Switching Protocols response with the precomputed
        /// accept key, then transitions to the WS receive loop.
        case upgradeWebSocket(acceptKey: String)
        /// WebSocket upgrade requested but `Sec-WebSocket-Key` was missing
        /// — emit 400 missing_ws_key.
        case rejectWebSocketMissingKey
    }

    /// Pure-logic decision: given a parsed request + the dispatcher / tokens
    /// / subscriptions context, what should the connection layer write?
    /// No `NWConnection`, no IO, no side effects beyond the dispatcher's
    /// `dispatch(...)` call (which is itself idempotent / lockable).
    ///
    /// Operator-facing routes that need an `.read` capability return 401
    /// here; routes that need a runtime but the dispatcher is nil return
    /// 503; routes that don't match any HTTPRoutes prefix return 404
    /// (`unknown_route`). The OSCQuery handler gets first chance at any
    /// path NOT under `/api/v1`.
    func computeResponse(to req: HTTPRequest) -> RespondOutcome {
        // WebSocket upgrade for /api/v1/events
        if req.isWebSocketUpgrade, req.path == "/api/v1/events" {
            guard let key = req.headers["sec-websocket-key"] else {
                return .rejectWebSocketMissingKey
            }
            return .upgradeWebSocket(acceptKey: Self.webSocketAcceptKey(for: key))
        }

        // Auth: extract bearer token if any.
        let token = req.bearerToken()
        let caps: Set<ShowControlCapability>
        if let tokens = tokens, let token = token {
            caps = tokens.capabilities(for: token) ?? []
        } else {
            caps = configuration.defaultCapabilities
        }

        // OSCQuery handler — first chance at anything not under /api/v1.
        if !req.path.hasPrefix("/api/v1") {
            if let handler = oscQueryHandler,
               let result = handler(req.path, req.queryParameters) {
                return .write(
                    status: result.status,
                    body: result.body,
                    contentType: result.contentType,
                    keepAlive: req.keepAlive
                )
            }
        }

        guard let httpAction = HTTPRoutes.action(method: req.method, path: req.path, body: req.body) else {
            return .writeError(status: 404, jsonError: "unknown_route", keepAlive: req.keepAlive)
        }

        switch httpAction {
        case let .action(action):
            guard let dispatcher = dispatcher else {
                return .writeError(status: 503, jsonError: "no_runtime", keepAlive: req.keepAlive)
            }
            let source: ShowControlSource = .http(token: token ?? "", host: req.host)
            let result = dispatcher.dispatch(action, source: source, capabilities: caps)
            let address = HTTPRoutes.oscAddress(for: action)
            let body = ShowControlReplyEnvelope.json(address: address, result: result)
            return .write(
                status: httpStatus(for: result),
                body: body,
                contentType: "application/json",
                keepAlive: req.keepAlive
            )
        case .stateSnapshot:
            guard caps.contains(.read) else {
                return .writeError(status: 401, jsonError: "missing_capability:read", keepAlive: req.keepAlive)
            }
            let snapshot = dispatcher?.state.snapshot() ?? ShowControlState().snapshot()
            return .write(
                status: 200,
                body: StateSnapshotEncoder.json(snapshot),
                contentType: "application/json",
                keepAlive: req.keepAlive
            )
        case .cueList:
            guard caps.contains(.read) else {
                return .writeError(status: 401, jsonError: "missing_capability:read", keepAlive: req.keepAlive)
            }
            let snap = dispatcher?.state.snapshot() ?? ShowControlState().snapshot()
            return .write(
                status: 200,
                body: StateSnapshotEncoder.cueListJSON(snap),
                contentType: "application/json",
                keepAlive: req.keepAlive
            )
        case let .cueDetail(num):
            guard caps.contains(.read) else {
                return .writeError(status: 401, jsonError: "missing_capability:read", keepAlive: req.keepAlive)
            }
            let snap = dispatcher?.state.snapshot() ?? ShowControlState().snapshot()
            if let body = StateSnapshotEncoder.cueDetailJSON(snap, cueNumber: num) {
                return .write(
                    status: 200,
                    body: body,
                    contentType: "application/json",
                    keepAlive: req.keepAlive
                )
            }
            return .writeError(status: 404, jsonError: "unknown_cue", keepAlive: req.keepAlive)
        }
    }

    /// RFC 6455 Sec-WebSocket-Accept derivation. SHA-1(`key + magic`) →
    /// base64. Exposed `static` for testing; a malformed implementation
    /// would silently fail every WS handshake against any compliant
    /// client and only the canonical example (`dGhlIHNhbXBsZSBub25jZQ==`
    /// → `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`) catches it cheaply.
    static func webSocketAcceptKey(for clientKey: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let hash = Insecure.SHA1.hash(data: Data((clientKey + magic).utf8))
        return Data(hash).base64EncodedString()
    }

    private func respond(to req: HTTPRequest, on conn: NWConnection) {
        let outcome = computeResponse(to: req)
        switch outcome {
        case let .write(status, body, contentType, keepAlive):
            send(on: conn, status: status, body: body, contentType: contentType, keepAlive: keepAlive)
        case let .writeError(status, jsonError, keepAlive):
            send(on: conn, status: status, jsonError: jsonError, keepAlive: keepAlive)
        case let .upgradeWebSocket(acceptKey):
            handleWebSocketUpgrade(acceptKey: acceptKey, on: conn)
        case .rejectWebSocketMissingKey:
            send(on: conn, status: 400, jsonError: "missing_ws_key", keepAlive: false)
        }
    }

    // MARK: - WebSocket

    private func handleWebSocketUpgrade(acceptKey: String, on conn: NWConnection) {
        var response = "HTTP/1.1 101 Switching Protocols\r\n"
        response += "Upgrade: websocket\r\n"
        response += "Connection: Upgrade\r\n"
        response += "Sec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in })

        // Register a WebSocket sink for state push.
        let sink = SubscriptionRegistry.WebSocketSink(send: { [weak conn] data in
            guard let conn else { return }
            let frame = WebSocketFrame.encode(opcode: 0x1, payload: data) // text
            conn.send(content: frame, completion: .contentProcessed { _ in })
        })
        subscriptions?.addWebSocket(sink)

        receiveWebSocket(on: conn, sink: sink)
    }

    private func receiveWebSocket(on conn: NWConnection, sink: SubscriptionRegistry.WebSocketSink) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let frames = WebSocketFrame.decode(data)
                for frame in frames {
                    if frame.opcode == 0x8 {
                        // Close
                        let response = WebSocketFrame.encode(opcode: 0x8, payload: Data())
                        conn.send(content: response, completion: .contentProcessed { _ in })
                        self.subscriptions?.removeWebSocket(sink)
                        conn.cancel()
                        self.connections.removeValue(forKey: ObjectIdentifier(conn))
                        return
                    }
                    if frame.opcode == 0x9 {
                        // Ping → Pong
                        let pong = WebSocketFrame.encode(opcode: 0xA, payload: frame.payload)
                        conn.send(content: pong, completion: .contentProcessed { _ in })
                    }
                    // Text frames are ignored — clients receive but don't speak.
                }
            }
            if isComplete || error != nil {
                self.subscriptions?.removeWebSocket(sink)
                conn.cancel()
                self.connections.removeValue(forKey: ObjectIdentifier(conn))
                return
            }
            self.receiveWebSocket(on: conn, sink: sink)
        }
    }

    // MARK: - Send

    private func send(on conn: NWConnection, status: Int, body: Data, contentType: String, keepAlive: Bool) {
        var head = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += keepAlive ? "Connection: keep-alive\r\n" : "Connection: close\r\n"
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        conn.send(content: data, completion: .contentProcessed { _ in
            if !keepAlive { conn.cancel() }
        })
    }

    private func send(on conn: NWConnection, status: Int, jsonError: String, keepAlive: Bool) {
        let body = """
        {"apiVersion":\(SHOW_CONTROL_API_VERSION),"status":"error","error":"\(jsonError)"}
        """
        send(on: conn, status: status, body: Data(body.utf8), contentType: "application/json", keepAlive: keepAlive)
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }

    /// Map a `ShowControlActionResult` to its HTTP status code. The reply
    /// envelope (returned in the body) carries the structured outcome for
    /// JSON-aware clients; the status code is the wire-level summary so
    /// curl / log scrapers can distinguish at a glance. Capability misses
    /// stay 401 (the dispatcher uses the `missing_capability:` reason
    /// prefix); validation rejections are 400; runtime no-ops (idempotency
    /// lockout, unknown cue, etc.) are 200 with the rejection reason in
    /// the body — they're not protocol failures.
    static func httpStatus(for result: ShowControlActionResult) -> Int {
        switch result {
        case .ok:
            return 200
        case let .rejected(reason):
            if reason.hasPrefix("missing_capability") { return 401 }
            return 200
        }
    }

    private func httpStatus(for result: ShowControlActionResult) -> Int {
        Self.httpStatus(for: result)
    }
}
