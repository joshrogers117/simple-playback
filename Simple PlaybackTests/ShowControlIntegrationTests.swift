import Foundation
import Network
import XCTest
@testable import Simple_Playback

/// End-to-end integration tests: real OSC sockets, real dispatcher, real
/// CueRuntime. The "client" half uses Network.framework loopback connections
/// to send and receive OSC packets. Each test picks a unique high port to
/// avoid collisions if multiple test runs are interleaved.
final class ShowControlIntegrationTests: XCTestCase {
    private static var nextSharedPort: UInt16 = 53100
    private static let portLock = NSLock()

    private func allocatePort() -> UInt16 {
        Self.portLock.lock()
        defer { Self.portLock.unlock() }
        let p = Self.nextSharedPort
        Self.nextSharedPort &+= 1
        return p
    }

    private func makeServerHarness(udpPort: UInt16, tcpPort: UInt16) throws -> (CueRuntime, ShowControlState, ShowControlDispatcher, OSCServer) {
        var list = ShowList()
        try list.append(Cue(number: "INTRO", title: "Intro", assetID: UUID()))
        try list.append(Cue(number: "BUMPER", title: "Bumper", assetID: UUID()))
        let runtime = CueRuntime(showList: list)
        let state = ShowControlState()
        state.updateShowList(list)
        let dispatcher = ShowControlDispatcher(runtime: runtime, state: state)

        // Wire runtime callbacks → state.
        runtime.onCueFired = { cue, _ in
            state.updateCueState(cueID: cue.id, state: .running)
        }
        runtime.onCueEnded = { cue in
            state.updateCueState(cueID: cue.id, state: .idle)
        }
        runtime.onCueStateChanged = { cue, st in
            state.updateCueState(cueID: cue.id, state: st)
        }
        runtime.onPlayheadChanged = { cue in
            state.updatePlayhead(cueID: cue?.id)
        }
        runtime.onBlackoutChanged = { state.updateBlackout($0) }
        runtime.onPanicChanged = { active, _ in state.updatePanic(active) }

        var config = OSCServer.Configuration()
        config.host = "127.0.0.1"
        config.udpPort = udpPort
        config.tcpPort = tcpPort
        let server = OSCServer(configuration: config)
        server.dispatcher = dispatcher
        try server.start()
        return (runtime, state, dispatcher, server)
    }

    /// Sends `message` over UDP to `127.0.0.1:port`, waits for the reply, and
    /// returns the reply string. Times out after `timeout` seconds.
    private func roundTripUDP(_ message: OSCMessage, port: UInt16, timeout: TimeInterval = 2.0) throws -> String {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let conn = NWConnection(to: endpoint, using: .udp)
        let queue = DispatchQueue(label: "test-udp-client")

        let readyExp = expectation(description: "client ready")
        conn.stateUpdateHandler = { state in
            if case .ready = state { readyExp.fulfill() }
        }
        conn.start(queue: queue)
        wait(for: [readyExp], timeout: 2.0)

        defer { conn.cancel() }

        let exp = expectation(description: "round trip")
        var received: String?
        conn.send(content: message.data(), completion: .contentProcessed { _ in
            conn.receiveMessage { data, _, _, _ in
                if let data, let msgs = try? OSCMessage.decodePacket(data),
                   let reply = msgs.first, let arg = reply.arguments.first?.stringValue {
                    received = arg
                }
                exp.fulfill()
            }
        })
        wait(for: [exp], timeout: timeout)
        return received ?? ""
    }

    // MARK: - Test cases

    func testOSCGoFiresPlayheadCue() throws {
        let udp = allocatePort()
        let tcp = allocatePort()
        let (runtime, state, dispatcher, server) = try makeServerHarness(udpPort: udp, tcpPort: tcp)
        _ = dispatcher
        defer { server.stop() }

        let reply = try roundTripUDP(OSCMessage(address: "/sp/go"), port: udp)
        XCTAssertTrue(reply.contains("\"status\":\"ok\""), "reply: \(reply)")
        XCTAssertTrue(reply.contains("\"fired\":\"INTRO\""))
        // Server-side: cue should be running.
        let waitDeadline = Date().addingTimeInterval(0.5)
        while Date() < waitDeadline, runtime.state(of: runtime.showList.cue(number: "INTRO")!.id) != .running {
            usleep(10_000)
        }
        XCTAssertEqual(runtime.state(of: runtime.showList.cue(number: "INTRO")!.id), .running)
        XCTAssertEqual(state.snapshot().showList.playheadCue?.number, "BUMPER")
    }

    func testOSCGoWithCueId() throws {
        let udp = allocatePort()
        let tcp = allocatePort()
        let (runtime, _, _, server) = try makeServerHarness(udpPort: udp, tcpPort: tcp)
        defer { server.stop() }

        let reply = try roundTripUDP(
            OSCMessage(address: "/sp/go", arguments: [.string("BUMPER")]),
            port: udp
        )
        XCTAssertTrue(reply.contains("\"fired\":\"BUMPER\""), "reply: \(reply)")
        let bumper = runtime.showList.cue(number: "BUMPER")!
        let waitDeadline = Date().addingTimeInterval(0.5)
        while Date() < waitDeadline, runtime.state(of: bumper.id) != .running { usleep(10_000) }
        XCTAssertEqual(runtime.state(of: bumper.id), .running)
    }

    func testOSCBlackoutToggles() throws {
        let udp = allocatePort()
        let tcp = allocatePort()
        let (runtime, _, _, server) = try makeServerHarness(udpPort: udp, tcpPort: tcp)
        defer { server.stop() }

        XCTAssertFalse(runtime.blackout)
        _ = try roundTripUDP(
            OSCMessage(address: "/sp/output/main/blackout", arguments: [.int(1)]),
            port: udp
        )
        let waitDeadline = Date().addingTimeInterval(0.5)
        while Date() < waitDeadline, !runtime.blackout { usleep(10_000) }
        XCTAssertTrue(runtime.blackout)
    }

    func testOSCPingReturnsUptime() throws {
        let udp = allocatePort()
        let tcp = allocatePort()
        let (_, _, _, server) = try makeServerHarness(udpPort: udp, tcpPort: tcp)
        defer { server.stop() }

        let reply = try roundTripUDP(OSCMessage(address: "/sp/ping"), port: udp)
        XCTAssertTrue(reply.contains("\"status\":\"ok\""), "reply=\(reply)")
        XCTAssertTrue(reply.contains("uptime"), "reply=\(reply)")
        XCTAssertTrue(reply.contains("\"apiVersion\":1"), "reply=\(reply)")
    }

    func testOSCRetriggerLockoutSuppressesDoubleFire() throws {
        let udp = allocatePort()
        let tcp = allocatePort()
        let (runtime, _, dispatcher, server) = try makeServerHarness(udpPort: udp, tcpPort: tcp)
        defer { server.stop() }
        dispatcher.retriggerLockout = 0.5

        let firstReply = try roundTripUDP(OSCMessage(address: "/sp/go"), port: udp)
        XCTAssertTrue(firstReply.contains("\"fired\":\"INTRO\""))
        let secondReply = try roundTripUDP(OSCMessage(address: "/sp/go"), port: udp)
        XCTAssertTrue(secondReply.contains("retrigger_lockout"), "reply: \(secondReply)")
        XCTAssertEqual(runtime.state(of: runtime.showList.cue(number: "INTRO")!.id), .running)
    }

    func testOSCUnknownAddressReplies() throws {
        let udp = allocatePort()
        let tcp = allocatePort()
        let (_, _, _, server) = try makeServerHarness(udpPort: udp, tcpPort: tcp)
        defer { server.stop() }

        let reply = try roundTripUDP(OSCMessage(address: "/sp/totally/bogus"), port: udp)
        XCTAssertTrue(reply.contains("\"status\":\"error\""))
        XCTAssertTrue(reply.contains("unknown_address"))
    }

    func testOSCPanicAndClearReply() throws {
        let udp = allocatePort()
        let tcp = allocatePort()
        let (runtime, _, _, server) = try makeServerHarness(udpPort: udp, tcpPort: tcp)
        defer { server.stop() }

        let panicReply = try roundTripUDP(
            OSCMessage(address: "/sp/panic", arguments: [.float(0.25)]),
            port: udp
        )
        XCTAssertTrue(panicReply.contains("\"status\":\"ok\""))
        let waitDeadline = Date().addingTimeInterval(0.5)
        while Date() < waitDeadline, !runtime.panicActive { usleep(10_000) }
        XCTAssertTrue(runtime.panicActive)
    }

    func testOSCCuePlayDirect() throws {
        let udp = allocatePort()
        let tcp = allocatePort()
        let (runtime, _, _, server) = try makeServerHarness(udpPort: udp, tcpPort: tcp)
        defer { server.stop() }

        let reply = try roundTripUDP(
            OSCMessage(address: "/sp/cue/BUMPER/play"),
            port: udp
        )
        XCTAssertTrue(reply.contains("\"fired\":\"BUMPER\""))
        let bumper = runtime.showList.cue(number: "BUMPER")!
        let waitDeadline = Date().addingTimeInterval(0.5)
        while Date() < waitDeadline, runtime.state(of: bumper.id) != .running { usleep(10_000) }
        XCTAssertEqual(runtime.state(of: bumper.id), .running)
    }

    func testOSCSubscribeRegistersClient() throws {
        let udp = allocatePort()
        let tcp = allocatePort()
        let (_, _, _, server) = try makeServerHarness(udpPort: udp, tcpPort: tcp)
        defer { server.stop() }
        let registry = SubscriptionRegistry()
        server.subscriptions = registry
        defer { registry.cancelAll() }

        let reply = try roundTripUDP(
            OSCMessage(address: "/sp/subscribe", arguments: [.string("127.0.0.1:9999")]),
            port: udp
        )
        XCTAssertTrue(reply.contains("\"status\":\"ok\""))
        let waitDeadline = Date().addingTimeInterval(0.5)
        while Date() < waitDeadline, !registry.hasSubscribers { usleep(10_000) }
        XCTAssertTrue(registry.hasSubscribers)
    }
}
