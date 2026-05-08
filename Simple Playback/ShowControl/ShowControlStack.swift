import Foundation

/// Bundles the show-control services (OSC, HTTP+WS, OSCQuery, Bonjour, subscriptions,
/// auth, dispatcher, state) into a single startable object.
///
/// Lifecycle:
/// 1. Construct with a binding to a `CueRuntime` and a `Configuration`.
/// 2. Call `start()` from the app entry point.
/// 3. (Optional) call `bindRuntime(_:)` whenever the active project changes — the runtime
///    reference inside the dispatcher is rebound so external triggers fire against the
///    new project's show list.
/// 4. Call `stop()` on app termination.
///
/// Threading: services internally use `Network.framework` and Core Audio queues. The
/// public methods are safe to call from `@MainActor` contexts.
final class ShowControlStack {
    struct Configuration {
        var oscHost: String = "127.0.0.1"
        var oscPort: UInt16 = 53000
        var httpHost: String = "127.0.0.1"
        var httpPort: UInt16 = 53001
        var defaultCapabilities: Set<ShowControlCapability> = [.read, .fire]
        var enableBonjour: Bool = true
        var subscriptionPushHz: Double = 10
    }

    let state: ShowControlState
    let dispatcher: ShowControlDispatcher
    let subscriptions: SubscriptionRegistry
    let tokens: AuthTokenStore
    let oscServer: OSCServer
    let httpServer: HTTPServer
    let oscQueryServer: OSCQueryServer
    let subscriptionPump: SubscriptionPump
    let bonjour: BonjourPublisher

    private let configuration: Configuration
    private(set) var isRunning: Bool = false

    init(runtime: CueRuntime?, configuration: Configuration = Configuration()) {
        self.configuration = configuration
        let state = ShowControlState()
        let dispatcher = ShowControlDispatcher(runtime: runtime, state: state)
        let subscriptions = SubscriptionRegistry()
        let tokens = AuthTokenStore()
        // Seed a default token with read+fire so localhost clients (Companion, TouchOSC)
        // can connect without a setup step. Operators can rotate via Settings.
        let defaultToken = AuthTokenStore.generateToken()
        tokens.add(token: defaultToken, label: "default", capabilities: configuration.defaultCapabilities)

        self.state = state
        self.dispatcher = dispatcher
        self.subscriptions = subscriptions
        self.tokens = tokens

        var oscConfig = OSCServer.Configuration()
        oscConfig.host = configuration.oscHost
        oscConfig.udpPort = configuration.oscPort
        oscConfig.tcpPort = configuration.oscPort
        oscConfig.defaultCapabilities = configuration.defaultCapabilities
        let osc = OSCServer(configuration: oscConfig)
        osc.dispatcher = dispatcher
        osc.subscriptions = subscriptions
        self.oscServer = osc

        var httpConfig = HTTPServer.Configuration()
        httpConfig.host = configuration.httpHost
        httpConfig.port = configuration.httpPort
        httpConfig.defaultCapabilities = configuration.defaultCapabilities
        let http = HTTPServer(configuration: httpConfig)
        http.dispatcher = dispatcher
        http.subscriptions = subscriptions
        http.tokens = tokens
        self.httpServer = http

        let oscQuery = OSCQueryServer(state: state)
        self.oscQueryServer = oscQuery

        let pump = SubscriptionPump(state: state, subscriptions: subscriptions)
        self.subscriptionPump = pump

        var bonjourConfig = BonjourPublisher.Configuration()
        bonjourConfig.oscUDPPort = configuration.oscPort
        bonjourConfig.httpPort = configuration.httpPort
        self.bonjour = BonjourPublisher(configuration: bonjourConfig)

        // Wire the OSCQuery routes into the HTTP server so a single port handles both
        // the JSON twin and OSCQuery introspection.
        http.oscQueryHandler = { [weak oscQuery] path, query in
            oscQuery?.handle(path: path, query: query)
        }

        // Wire dispatcher subscribe/unsubscribe verbs to the registry. Default to UDP
        // for OSC subscribers — TCP subscribers go through the HTTPServer's WebSocket
        // path, so the OSC subscribe verb is UDP-only.
        dispatcher.subscribe = { [weak subscriptions] host, port in
            subscriptions?.subscribe(host: host, port: port, transport: .udp)
        }
        dispatcher.unsubscribe = { [weak subscriptions] host, port in
            subscriptions?.unsubscribe(host: host, port: port)
        }
    }

    /// Rebinds the dispatcher's runtime reference. Call when the user opens a new project
    /// so external GO triggers fire against the new show list.
    func bindRuntime(_ runtime: CueRuntime?) {
        dispatcher.runtime = runtime
    }

    func start() {
        guard !isRunning else { return }
        do {
            try oscServer.start()
            try httpServer.start()
            if configuration.enableBonjour {
                try? bonjour.start()
            }
            subscriptionPump.start()
            isRunning = true
        } catch {
            // Surface the failure but do not crash — the app remains usable without
            // remote control. Phase E's show log will record this.
            NSLog("[ShowControl] start failed: \(error.localizedDescription)")
            stop()
        }
    }

    func stop() {
        guard isRunning else { return }
        subscriptionPump.stop()
        bonjour.stop()
        httpServer.stop()
        oscServer.stop()
        isRunning = false
    }
}
