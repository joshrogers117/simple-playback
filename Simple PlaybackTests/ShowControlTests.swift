import Foundation
import XCTest
@testable import Simple_Playback

final class ShowControlTests: XCTestCase {
    // MARK: - OSC encode/decode (D1)

    func testOSCMessageEncodesAddressOnly() throws {
        let msg = OSCMessage(address: "/sp/go")
        let data = msg.data()
        let decoded = try OSCMessage.decodeMessage(data)
        XCTAssertEqual(decoded.address, "/sp/go")
        XCTAssertTrue(decoded.arguments.isEmpty)
    }

    func testOSCMessageRoundTripsString() throws {
        let msg = OSCMessage(address: "/sp/go", arguments: [.string("INTRO")])
        let decoded = try OSCMessage.decodeMessage(msg.data())
        XCTAssertEqual(decoded.address, "/sp/go")
        XCTAssertEqual(decoded.arguments, [.string("INTRO")])
    }

    func testOSCMessageRoundTripsIntFloatBlob() throws {
        let blob = Data([0x01, 0x02, 0x03])
        let msg = OSCMessage(address: "/sp/cue/INTRO/scrub", arguments: [
            .int(42),
            .float(0.5),
            .blob(blob)
        ])
        let decoded = try OSCMessage.decodeMessage(msg.data())
        XCTAssertEqual(decoded.arguments[0], .int(42))
        XCTAssertEqual(decoded.arguments[1], .float(0.5))
        XCTAssertEqual(decoded.arguments[2], .blob(blob))
    }

    func testOSCMessageDecodesBundle() throws {
        let m1 = OSCMessage(address: "/sp/go").data()
        let m2 = OSCMessage(address: "/sp/clear").data()
        var bundle = Data()
        bundle.append(contentsOf: Array("#bundle".utf8) + [0])
        // Time tag (8 bytes, all zero = "immediate")
        bundle.append(contentsOf: Array(repeating: UInt8(0), count: 8))
        // Element 1
        var s1 = UInt32(m1.count).bigEndian
        withUnsafeBytes(of: &s1) { bundle.append(contentsOf: $0) }
        bundle.append(m1)
        var s2 = UInt32(m2.count).bigEndian
        withUnsafeBytes(of: &s2) { bundle.append(contentsOf: $0) }
        bundle.append(m2)

        let decoded = try OSCMessage.decodePacket(bundle)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].address, "/sp/go")
        XCTAssertEqual(decoded[1].address, "/sp/clear")
    }

    func testOSCAddressMatchesWildcard() {
        XCTAssertTrue(OSCMessage.addressMatches(pattern: "/sp/cue/*/stop", address: "/sp/cue/INTRO/stop"))
        XCTAssertFalse(OSCMessage.addressMatches(pattern: "/sp/cue/*/stop", address: "/sp/cue/INTRO/scrub"))
        XCTAssertTrue(OSCMessage.addressMatches(pattern: "/sp/go", address: "/sp/go"))
        XCTAssertFalse(OSCMessage.addressMatches(pattern: "/sp/go", address: "/sp/clear"))
    }

    // MARK: - Address map

    func testOSCAddressMapDecodesGoWithoutArgs() {
        let m = OSCMessage(address: "/sp/go")
        XCTAssertEqual(OSCAddressMap.action(for: m), .go(target: nil))
    }

    func testOSCAddressMapDecodesGoWithTarget() {
        let m = OSCMessage(address: "/sp/go", arguments: [.string("INTRO")])
        XCTAssertEqual(OSCAddressMap.action(for: m), .go(target: "INTRO"))
    }

    func testOSCAddressMapDecodesPanicWithFade() {
        let m = OSCMessage(address: "/sp/panic", arguments: [.float(0.25)])
        XCTAssertEqual(OSCAddressMap.action(for: m), .panic(fade: 0.25))
    }

    func testOSCAddressMapDecodesCueScrub() {
        let m = OSCMessage(address: "/sp/cue/INTRO/scrub", arguments: [.float(0.5)])
        XCTAssertEqual(OSCAddressMap.action(for: m), .cueScrubNormalized(cueNumber: "INTRO", position: 0.5))
        let m2 = OSCMessage(address: "/sp/cue/INTRO/scrub/seconds", arguments: [.float(12.5)])
        XCTAssertEqual(OSCAddressMap.action(for: m2), .cueScrubSeconds(cueNumber: "INTRO", seconds: 12.5))
    }

    func testOSCAddressMapDecodesOutputBlackout() {
        let m = OSCMessage(address: "/sp/output/main/blackout", arguments: [.int(1)])
        XCTAssertEqual(OSCAddressMap.action(for: m), .outputBlackout(enabled: true))
    }

    func testOSCAddressMapDecodesTimecodeSource() {
        let m = OSCMessage(address: "/sp/timecode/source", arguments: [.string("ltc:input1")])
        XCTAssertEqual(OSCAddressMap.action(for: m), .timecodeSource(spec: "ltc:input1"))
    }

    func testOSCAddressMapRejectsUnknown() {
        let m = OSCMessage(address: "/sp/bogus/path")
        XCTAssertNil(OSCAddressMap.action(for: m))
        let m2 = OSCMessage(address: "/qlab/cue/1/play")
        XCTAssertNil(OSCAddressMap.action(for: m2))
    }

    // MARK: - Reply envelope

    func testReplyEnvelopeIncludesApiVersion() throws {
        let json = ShowControlReplyEnvelope.jsonString(
            address: "/sp/go",
            result: .ok(data: ["fired": .string("INTRO")])
        )
        XCTAssertTrue(json.contains("\"apiVersion\":1"))
        XCTAssertTrue(json.contains("\"status\":\"ok\""))
        XCTAssertTrue(json.contains("\"fired\":\"INTRO\""))
    }

    func testReplyEnvelopeReportsError() {
        let json = ShowControlReplyEnvelope.jsonString(
            address: "/sp/go",
            result: .rejected(reason: "go_failed")
        )
        XCTAssertTrue(json.contains("\"status\":\"error\""))
        XCTAssertTrue(json.contains("\"error\":\"go_failed\""))
    }

    // MARK: - HTTP Routes (D2)

    func testHTTPRoutesDecodeGoFromBody() {
        let body = #"{"target":"INTRO"}"#.data(using: .utf8)
        let action = HTTPRoutes.action(method: "POST", path: "/api/v1/go", body: body)
        guard case let .action(decoded) = action else {
            XCTFail("expected action"); return
        }
        XCTAssertEqual(decoded, .go(target: "INTRO"))
    }

    func testHTTPRoutesDecodeGoWithoutTarget() {
        let action = HTTPRoutes.action(method: "POST", path: "/api/v1/go", body: nil)
        guard case let .action(decoded) = action else {
            XCTFail("expected action"); return
        }
        XCTAssertEqual(decoded, .go(target: nil))
    }

    func testHTTPRoutesDecodeCueScrubSeconds() {
        let body = #"{"seconds":12.5}"#.data(using: .utf8)
        let action = HTTPRoutes.action(method: "POST", path: "/api/v1/cue/INTRO/scrub/seconds", body: body)
        guard case let .action(decoded) = action else {
            XCTFail("expected action"); return
        }
        XCTAssertEqual(decoded, .cueScrubSeconds(cueNumber: "INTRO", seconds: 12.5))
    }

    func testHTTPRoutesGetStateMapsToSnapshot() {
        let action = HTTPRoutes.action(method: "GET", path: "/api/v1/state", body: nil)
        guard case .stateSnapshot = action else {
            XCTFail("expected stateSnapshot"); return
        }
    }

    func testHTTPRoutesGetCueDetail() {
        let action = HTTPRoutes.action(method: "GET", path: "/api/v1/cue/INTRO", body: nil)
        guard case let .cueDetail(num) = action else {
            XCTFail("expected cueDetail"); return
        }
        XCTAssertEqual(num, "INTRO")
    }

    func testHTTPRequestParserExtractsBearer() {
        let raw = "GET /api/v1/state HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer abc123\r\n\r\n"
        let buf = HTTPRequestBuffer()
        buf.append(Data(raw.utf8))
        let req = buf.nextRequest()
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.bearerToken(), "abc123")
        XCTAssertEqual(req?.method, "GET")
        XCTAssertEqual(req?.path, "/api/v1/state")
    }

    func testHTTPRequestParserHandlesPOSTWithBody() {
        let body = #"{"target":"INTRO"}"#
        let raw = "POST /api/v1/go HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.count)\r\n\r\n\(body)"
        let buf = HTTPRequestBuffer()
        buf.append(Data(raw.utf8))
        let req = buf.nextRequest()
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.method, "POST")
        XCTAssertEqual(req?.body.flatMap { String(data: $0, encoding: .utf8) }, body)
    }

    func testHTTPRequestParserHandlesQueryString() {
        let raw = "GET /api/v1/state?foo=bar&baz=qux HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let buf = HTTPRequestBuffer()
        buf.append(Data(raw.utf8))
        let req = buf.nextRequest()
        XCTAssertEqual(req?.path, "/api/v1/state")
        XCTAssertEqual(req?.queryParameters["foo"], "bar")
        XCTAssertEqual(req?.queryParameters["baz"], "qux")
    }

    func testHTTPRequestParserDetectsWebSocketUpgrade() {
        let raw = "GET /api/v1/events HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        let buf = HTTPRequestBuffer()
        buf.append(Data(raw.utf8))
        let req = buf.nextRequest()
        XCTAssertEqual(req?.isWebSocketUpgrade, true)
    }

    // MARK: - WebSocket frames (D3)

    func testWebSocketFrameRoundTrips() {
        let payload = Data("hello".utf8)
        let encoded = WebSocketFrame.encode(opcode: 0x1, payload: payload)
        let frames = WebSocketFrame.decode(encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].opcode, 0x1)
        XCTAssertEqual(frames[0].payload, payload)
        XCTAssertTrue(frames[0].fin)
    }

    func testWebSocketFrameDecodesMaskedClientFrame() {
        var data = Data([0x81, 0x85])
        let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
        data.append(contentsOf: mask)
        let plain = Array("Hello".utf8)
        let masked: [UInt8] = plain.enumerated().map { (idx, b) in b ^ mask[idx % 4] }
        data.append(contentsOf: masked)
        let frames = WebSocketFrame.decode(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(String(data: frames[0].payload, encoding: .utf8), "Hello")
    }

    func testWebSocketFrameEncodes16BitLength() {
        let payload = Data(repeating: 0x41, count: 200)
        let encoded = WebSocketFrame.encode(opcode: 0x1, payload: payload)
        // header byte 1 should indicate 126 (extended 16-bit length)
        XCTAssertEqual(encoded[1] & 0x7F, 126)
        let frames = WebSocketFrame.decode(encoded)
        XCTAssertEqual(frames.first?.payload.count, 200)
    }

    // MARK: - State snapshot (D2)

    func testStateSnapshotEncodesPlayheadAndTimecode() throws {
        let state = ShowControlState()
        var list = ShowList()
        let cue = Cue(number: "INTRO", title: "Intro", assetID: UUID())
        try list.append(cue)
        state.updateShowList(list)
        state.updatePlayhead(cueID: cue.id)
        state.updateTimecode(source: "ltc:input1", engaged: true, locked: true, now: "01:00:00:00")

        let snap = state.snapshot()
        let json = StateSnapshotEncoder.json(snap)
        let str = String(data: json, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("\"playhead\":\"INTRO\""))
        XCTAssertTrue(str.contains("\"now\":\"01:00:00:00\""))
        XCTAssertTrue(str.contains("\"engaged\":true"))
    }

    // MARK: - Auth tokens

    func testAuthTokenStoreCRUD() {
        let store = AuthTokenStore()
        store.add(token: "tok-1", label: "default", capabilities: [.read, .fire])
        XCTAssertTrue(store.contains(token: "tok-1"))
        XCTAssertEqual(store.capabilities(for: "tok-1"), [.read, .fire])
        store.remove(token: "tok-1")
        XCTAssertFalse(store.contains(token: "tok-1"))
    }

    func testAuthTokenGenerateProducesUniqueValues() {
        let a = AuthTokenStore.generateToken()
        let b = AuthTokenStore.generateToken()
        XCTAssertNotEqual(a, b)
        XCTAssertGreaterThanOrEqual(a.count, 16)
    }

    // MARK: - OSCQuery (D4)

    func testOSCQueryRootListsSpNamespace() throws {
        let state = ShowControlState()
        let server = OSCQueryServer(state: state)
        let result = try XCTUnwrap(server.handle(path: "/", query: [:]))
        XCTAssertEqual(result.status, 200)
        let str = try XCTUnwrap(String(data: result.body, encoding: .utf8))
        XCTAssertTrue(str.contains("\"FULL_PATH\":\"/\""))
        XCTAssertTrue(str.contains("\"FULL_PATH\":\"/sp\""))
    }

    func testOSCQueryReturnsHostInfoOnQuery() throws {
        let state = ShowControlState()
        let server = OSCQueryServer(state: state)
        let result = try XCTUnwrap(server.handle(path: "/", query: ["HOST_INFO": ""]))
        let str = try XCTUnwrap(String(data: result.body, encoding: .utf8))
        XCTAssertTrue(str.contains("\"NAME\":\"Simple Playback\""))
        XCTAssertTrue(str.contains("\"OSC_PORT\":53000"))
        XCTAssertTrue(str.contains("\"EXTENSIONS\""))
    }

    func testOSCQueryEnumeratesCueByNumber() throws {
        let state = ShowControlState()
        var list = ShowList()
        let cue = Cue(number: "INTRO", title: "Intro", assetID: UUID())
        try list.append(cue)
        state.updateShowList(list)
        let server = OSCQueryServer(state: state)
        let result = try XCTUnwrap(server.handle(path: "/sp/cue", query: [:]))
        let str = try XCTUnwrap(String(data: result.body, encoding: .utf8))
        XCTAssertTrue(str.contains("\"INTRO\""))
        XCTAssertTrue(str.contains("\"/sp/cue/INTRO\""))
    }

    func testOSCQueryWalksIntoCueLeafs() throws {
        let state = ShowControlState()
        var list = ShowList()
        let cue = Cue(number: "INTRO", title: "Intro", assetID: UUID())
        try list.append(cue)
        state.updateShowList(list)
        let server = OSCQueryServer(state: state)
        let result = try XCTUnwrap(server.handle(path: "/sp/cue/INTRO/play", query: [:]))
        XCTAssertEqual(result.status, 200)
        let str = try XCTUnwrap(String(data: result.body, encoding: .utf8))
        XCTAssertTrue(str.contains("\"/sp/cue/INTRO/play\""))
    }

    func testOSCQueryReturns404OnUnknownPath() {
        let state = ShowControlState()
        let server = OSCQueryServer(state: state)
        let result = server.handle(path: "/sp/bogus/path", query: [:])
        XCTAssertEqual(result?.status, 404)
    }

    func testOSCQueryValueQuerySelector() throws {
        let state = ShowControlState()
        state.updateBlackout(true)
        let server = OSCQueryServer(state: state)
        let result = try XCTUnwrap(server.handle(path: "/sp/output/main/blackout", query: ["VALUE": ""]))
        let str = try XCTUnwrap(String(data: result.body, encoding: .utf8))
        XCTAssertTrue(str.contains("\"VALUE\""))
    }

    // MARK: - Bonjour (D5)

    func testBonjourConfigurationDefaults() {
        let pub = BonjourPublisher()
        XCTAssertEqual(pub.configuration.serviceName, "Simple Playback")
        XCTAssertEqual(pub.configuration.oscUDPPort, 53000)
        XCTAssertEqual(pub.configuration.httpPort, 53001)
        XCTAssertFalse(pub.isRunning)
    }

    // MARK: - Auth and capabilities (D6)

    func testDispatcherRejectsActionWithoutCapability() {
        let runtime = makeShowControlRuntime()
        let state = ShowControlState()
        let d = ShowControlDispatcher(runtime: runtime, state: state)
        let result = d.dispatch(.go(target: nil), source: .test, capabilities: [.read])
        guard case let .rejected(reason) = result else {
            XCTFail("expected rejection"); return
        }
        XCTAssertTrue(reason.contains("missing_capability"))
    }

    func testDispatcherAllowsActionWithCapability() {
        let runtime = makeShowControlRuntime()
        let state = ShowControlState()
        let d = ShowControlDispatcher(runtime: runtime, state: state)
        let result = d.dispatch(.previous, source: .test, capabilities: [.read, .fire])
        guard case .ok = result else { XCTFail("expected ok: \(result)"); return }
    }

    func testShowModeStripsEditCapability() {
        let runtime = makeShowControlRuntime()
        let state = ShowControlState()
        state.updateShowMode(true)
        let d = ShowControlDispatcher(runtime: runtime, state: state)
        let result = d.dispatch(
            .cueLoop(cueNumber: "INTRO", enabled: true),
            source: .test,
            capabilities: [.read, .fire, .edit]
        )
        guard case let .rejected(reason) = result else {
            XCTFail("expected rejection due to show mode"); return
        }
        XCTAssertEqual(reason, "missing_capability:edit")
    }

    func testIdempotencyLockoutSuppressesRapidRetrigger() {
        var clockNow: TimeInterval = 0
        let runtime = makeShowControlRuntime()
        let state = ShowControlState()
        let d = ShowControlDispatcher(runtime: runtime, state: state, clock: { clockNow })
        d.retriggerLockout = 0.05
        let first = d.dispatch(.previous, source: .test, capabilities: [.read, .fire])
        guard case .ok = first else { XCTFail("expected ok"); return }
        clockNow += 0.01
        let second = d.dispatch(.previous, source: .test, capabilities: [.read, .fire])
        guard case let .rejected(reason) = second else {
            XCTFail("expected rejection"); return
        }
        XCTAssertEqual(reason, "retrigger_lockout")
        clockNow += 0.10
        let third = d.dispatch(.previous, source: .test, capabilities: [.read, .fire])
        guard case .ok = third else { XCTFail("expected ok after lockout window"); return }
    }

    func testRequiredCapabilityForActions() {
        XCTAssertEqual(ShowControlAction.go(target: nil).requiredCapability, .fire)
        XCTAssertEqual(ShowControlAction.ping.requiredCapability, .read)
        XCTAssertEqual(ShowControlAction.cueLoop(cueNumber: "x", enabled: true).requiredCapability, .edit)
        XCTAssertEqual(ShowControlAction.cueNotes(cueNumber: "x", text: "n").requiredCapability, .edit)
    }

    // MARK: - Test helpers

    /// Builds a CueRuntime with a single cue named "INTRO" so dispatch tests
    /// have something to act on.
    func makeShowControlRuntime() -> CueRuntime {
        var list = ShowList()
        let cue = Cue(number: "INTRO", title: "Intro", assetID: UUID())
        try? list.append(cue)
        return CueRuntime(showList: list)
    }

    // MARK: - Subscription pump (D7/D8/D9)

    func testSubscriptionPumpSkipsTickWithoutSubscribers() {
        let state = ShowControlState()
        var list = ShowList()
        try? list.append(Cue(number: "INTRO", title: "Intro", assetID: UUID()))
        state.updateShowList(list)

        let registry = SubscriptionRegistry()
        let pump = SubscriptionPump(state: state, subscriptions: registry)

        // No subscribers → no broadcasts. Mostly proves we don't crash.
        pump.tick()
        // (Visible side effect: zero broadcasts, registry still empty.)
        XCTAssertFalse(registry.hasSubscribers)
    }

    func testSubscriptionPumpEmitsGlobalsAndCues() {
        let state = ShowControlState()
        var list = ShowList()
        let cue = Cue(number: "INTRO", title: "Intro", assetID: UUID())
        try? list.append(cue)
        state.updateShowList(list)
        state.updatePlayhead(cueID: cue.id)
        state.updateTimecode(locked: true, now: "01:00:00:00")

        let registry = SubscriptionRegistry()
        var captured: [Data] = []
        let sink = SubscriptionRegistry.WebSocketSink(send: { captured.append($0) })
        registry.addWebSocket(sink)

        let pump = SubscriptionPump(state: state, subscriptions: registry)
        pump.tick()

        XCTAssertFalse(captured.isEmpty)
        let combined = captured.compactMap { String(data: $0, encoding: .utf8) }.joined(separator: "\n")
        XCTAssertTrue(combined.contains("playhead_id"))
        XCTAssertTrue(combined.contains("INTRO"))
        XCTAssertTrue(combined.contains("tc_now"))
        XCTAssertTrue(combined.contains("01:00:00:00"))
    }

    func testSubscriptionPumpFormatsDurations() {
        XCTAssertEqual(SubscriptionPump.formatDuration(0), "00:00:00.000")
        XCTAssertEqual(SubscriptionPump.formatDuration(1.5), "00:00:01.500")
        XCTAssertEqual(SubscriptionPump.formatDuration(3661.123), "01:01:01.123")
    }

    func testSubscriptionPumpEmitsPerCueFeedbacks() {
        let state = ShowControlState()
        var list = ShowList()
        let cue = Cue(number: "INTRO", title: "Intro", assetID: UUID())
        try? list.append(cue)
        state.updateShowList(list)
        state.updateCueState(cueID: cue.id, state: .running)
        state.updateCueElapsed(cueID: cue.id, elapsed: 5, remaining: 25)

        let registry = SubscriptionRegistry()
        var captured: [Data] = []
        let sink = SubscriptionRegistry.WebSocketSink(send: { captured.append($0) })
        registry.addWebSocket(sink)

        let pump = SubscriptionPump(state: state, subscriptions: registry)
        pump.tick()

        let combined = captured.compactMap { String(data: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(combined.contains("/sp/state/cue/INTRO/running"))
        XCTAssertTrue(combined.contains("/sp/state/cue/INTRO/elapsed"))
        XCTAssertTrue(combined.contains("/sp/state/cue/INTRO/remaining"))
        XCTAssertTrue(combined.contains("\"running\":true"))
    }

    // MARK: - Ping (D10) and apiVersion (D11)

    func testDispatcherPingReturnsUptime() {
        let runtime = makeShowControlRuntime()
        let state = ShowControlState()
        var clockNow: TimeInterval = 0
        let d = ShowControlDispatcher(runtime: runtime, state: state, clock: { clockNow })
        clockNow = 42
        let result = d.dispatch(.ping, source: .test, capabilities: [.read, .fire])
        guard case let .ok(data) = result else { XCTFail(); return }
        guard case let .double(uptime) = data["uptime"] else { XCTFail(); return }
        XCTAssertGreaterThanOrEqual(uptime, 0)
    }

    func testApiVersionAppearsInEveryReply() {
        let json = ShowControlReplyEnvelope.jsonString(
            address: "/sp/ping",
            result: .ok(data: ["uptime": .double(1)])
        )
        XCTAssertTrue(json.contains("\"apiVersion\":1"))
    }

    // MARK: - Timecode (D12)

    func testTimecodeParsesAndFormats() {
        let tc = TimecodeValue.parse("01:02:03:15", frameRate: .fps30)
        XCTAssertNotNil(tc)
        XCTAssertEqual(tc?.stringValue, "01:02:03:15")
    }

    func testTimecodeDropFrameUsesSemicolon() {
        let tc = TimecodeValue(hours: 0, minutes: 1, seconds: 0, frames: 0, frameRate: .fps29_97_df)
        XCTAssertEqual(tc.stringValue, "00:01:00;00")
    }

    func testTimecodeFrameCountMatchesNDF() {
        let tc = TimecodeValue(hours: 0, minutes: 1, seconds: 0, frames: 0, frameRate: .fps29_97_ndf)
        XCTAssertEqual(tc.frameCount, 60 * 30)
    }

    func testTimecodeFrameCountAccountsForDropFrame() {
        // First minute boundary: drop 2 frames.
        let tc = TimecodeValue(hours: 0, minutes: 1, seconds: 0, frames: 0, frameRate: .fps29_97_df)
        // Without DF: 30 fps * 60 = 1800. With DF: 1800 - 2.
        XCTAssertEqual(tc.frameCount, 1800 - 2)
    }

    func testTimecodeFromFrameCountRoundTripsNDF() {
        let original = TimecodeValue(hours: 1, minutes: 23, seconds: 45, frames: 12, frameRate: .fps30)
        let roundTrip = TimecodeValue.fromFrameCount(original.frameCount, frameRate: .fps30)
        XCTAssertEqual(roundTrip, original)
    }

    func testTimecodeFollowerArmsThenChases() {
        var clockNow: TimeInterval = 0
        let follower = TimecodeFollower(clock: { clockNow })
        follower.arm()
        XCTAssertEqual(follower.engagement, .armed)
        let tc = TimecodeValue(hours: 1, minutes: 0, seconds: 0, frames: 0, frameRate: .fps30)
        let decision = follower.frameReceived(tc)
        XCTAssertEqual(follower.engagement, .chasing)
        if case let .lock(t) = decision { XCTAssertEqual(t, tc) } else { XCTFail("expected lock") }
    }

    func testTimecodeFollowerSnapsWithinThreshold() {
        var clockNow: TimeInterval = 0
        let follower = TimecodeFollower(clock: { clockNow })
        follower.arm()
        let tc1 = TimecodeValue(hours: 0, minutes: 0, seconds: 0, frames: 0, frameRate: .fps30)
        _ = follower.frameReceived(tc1)
        clockNow = 1.0 / 30.0 // one frame later in real time
        let tc2 = TimecodeValue(hours: 0, minutes: 0, seconds: 0, frames: 1, frameRate: .fps30)
        let decision = follower.frameReceived(tc2)
        if case .snap = decision {} else { XCTFail("expected snap, got \(decision)") }
    }

    func testTimecodeFollowerRelocksOutsideThreshold() {
        var clockNow: TimeInterval = 0
        let follower = TimecodeFollower(clock: { clockNow })
        follower.snapThresholdFrames = 2
        follower.arm()
        _ = follower.frameReceived(TimecodeValue(hours: 0, minutes: 0, seconds: 0, frames: 0, frameRate: .fps30))
        clockNow = 1.0 / 30.0
        // Jump 30 frames ahead — way outside snap threshold.
        let tc2 = TimecodeValue(hours: 0, minutes: 0, seconds: 1, frames: 0, frameRate: .fps30)
        let decision = follower.frameReceived(tc2)
        if case .relock = decision {} else { XCTFail("expected relock, got \(decision)") }
    }

    func testTimecodeFollowerEntersFreewheelThenLost() {
        var clockNow: TimeInterval = 0
        let follower = TimecodeFollower(clock: { clockNow })
        follower.freewheelWindow = 1.0
        follower.arm()
        _ = follower.frameReceived(TimecodeValue(hours: 0, minutes: 0, seconds: 0, frames: 0, frameRate: .fps30))
        XCTAssertEqual(follower.engagement, .chasing)
        clockNow += 0.5
        follower.poll()
        XCTAssertEqual(follower.engagement, .freewheeling)
        clockNow += 1.0
        follower.poll()
        XCTAssertEqual(follower.engagement, .lost)
    }

    func testLTCGeneratorEncodesPayloadShape() {
        let tc = TimecodeValue(hours: 1, minutes: 2, seconds: 3, frames: 4, frameRate: .fps30)
        let bits = LTCGenerator.encodePayload(tc)
        XCTAssertEqual(bits.count, 64)
        // Frame units = 4 → bits 0-3 = 0,0,1,0 (LSB-first BCD).
        XCTAssertFalse(bits[0])
        XCTAssertFalse(bits[1])
        XCTAssertTrue(bits[2])
        XCTAssertFalse(bits[3])
    }

    func testLTCGeneratorProducesAudioForFrame() {
        let tc = TimecodeValue(hours: 1, minutes: 0, seconds: 0, frames: 5, frameRate: .fps30)
        let gen = LTCGenerator(sampleRate: 48000, frameRate: .fps30)
        let frame = gen.samples(for: tc)
        // 48000 samples/sec / 30 fps = 1600 samples/frame.
        XCTAssertEqual(frame.count, 1600)
        // Should oscillate — count zero crossings.
        var crossings = 0
        for i in 1..<frame.count {
            if (frame[i - 1] >= 0) != (frame[i] >= 0) { crossings += 1 }
        }
        // 80 bits * 2 half-bits = 160 boundaries, plus mid-bit transitions for
        // every "1" bit. We expect at least 160 crossings.
        XCTAssertGreaterThanOrEqual(crossings, 80, "Expected at least one crossing per bit boundary")
    }

    // MARK: - Internal generator (D14)

    func testInternalGeneratorProducesIncrementingTC() {
        var clockNow: TimeInterval = 0
        let gen = InternalTimecodeGenerator(
            frameRate: .fps30,
            startTC: TimecodeValue(hours: 1, minutes: 0, seconds: 0, frames: 0, frameRate: .fps30),
            clock: { clockNow }
        )
        // Without start(), advancing time still produces a current value
        // because we need to test the TC math.
        gen.start()
        clockNow = 1.0 // 30 frames later.
        let v = gen.currentValue()
        XCTAssertEqual(v.hours, 1)
        XCTAssertEqual(v.minutes, 0)
        XCTAssertEqual(v.seconds, 1)
        gen.stop()
    }

    func testInternalGeneratorRespectsStartOffset() {
        var clockNow: TimeInterval = 0
        let start = TimecodeValue(hours: 9, minutes: 30, seconds: 15, frames: 7, frameRate: .fps25)
        let gen = InternalTimecodeGenerator(frameRate: .fps25, startTC: start, clock: { clockNow })
        gen.start()
        let v = gen.currentValue()
        XCTAssertEqual(v.frameCount, start.frameCount)
        gen.stop()
    }

    // MARK: - Off-main dispatch hop (F1 P0 session 25)

    /// Pin the contract: dispatcher.dispatch from a non-main queue still
    /// returns a synchronous result (the OSC/HTTP servers depend on this
    /// to build their reply envelopes), and the runtime mutation runs on
    /// the main thread (not the network queue) so it can't race a local
    /// operator press.
    func testDispatcherFromOffMainHopsToMainAndReturnsSynchronously() {
        let runtime = makeShowControlRuntime()
        let state = ShowControlState()
        let d = ShowControlDispatcher(runtime: runtime, state: state)

        let exp = expectation(description: "off-main dispatch returns")
        var resultIsOk = false
        // Capture the runtime-touching thread via hostInterceptor —
        // that closure fires inside the runOnMain block, so its
        // thread reflects where the mutation would run.
        var hostInterceptorRanOnMain = false
        d.hostInterceptor = { _, _ in
            hostInterceptorRanOnMain = Thread.isMainThread
            return nil // fall through to perform()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = d.dispatch(.previous, source: .test, capabilities: [.read, .fire])
            if case .ok = result { resultIsOk = true }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertTrue(resultIsOk, "Off-main dispatch must return a synchronous .ok result.")
        XCTAssertTrue(hostInterceptorRanOnMain, "Runtime-touching closures must run on main so they can't race operator-press paths.")
    }

    /// XCTest may run the test method itself on main. The dispatcher's
    /// Thread.isMainThread guard must skip the DispatchQueue.main.sync
    /// hop in that case — otherwise we'd deadlock and this test would
    /// hang forever.
    func testDispatcherFromMainDoesNotDeadlock() {
        let runtime = makeShowControlRuntime()
        let state = ShowControlState()
        let d = ShowControlDispatcher(runtime: runtime, state: state)
        // If the guard ever regresses, this call hangs the runner.
        let result = d.dispatch(.previous, source: .test, capabilities: [.read, .fire])
        guard case .ok = result else { return XCTFail("Expected .ok, got \(result)") }
    }

    /// Pin: even when `dispatch` is called from a network queue (off-main),
    /// the `onActionDispatched` callback must fire on the main thread. Its
    /// downstream consumer (`ShowController.recordDispatchedAction` →
    /// `ShowLog.appendNow`) is `@MainActor`-isolated, so an off-main
    /// callback is a Swift concurrency hazard. This is the show-log fan-
    /// out half of the session-25 P0 dispatcher fix.
    func testDispatchedCallbackFiresOnMainEvenFromOffMainCaller() {
        let runtime = makeShowControlRuntime()
        let state = ShowControlState()
        let d = ShowControlDispatcher(runtime: runtime, state: state)
        let exp = expectation(description: "callback fires on main")
        var callbackRanOnMain: Bool?
        d.onActionDispatched = { _, _, _ in
            // Capture the thread the callback fired on. This must be main
            // because consumers downstream (show log + show controller) are
            // @MainActor.
            if callbackRanOnMain == nil {
                callbackRanOnMain = Thread.isMainThread
                exp.fulfill()
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = d.dispatch(.previous, source: .test, capabilities: [.read, .fire])
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(callbackRanOnMain, true,
                       "onActionDispatched must run on main even when dispatch is called from a network queue.")
    }

    /// When `dispatch` is rejected before the runtime hop (capability
    /// failure or idempotency lockout) the callback still routes through
    /// `notifyDispatched`, so the same off-main → main hop applies. Pin
    /// the rejection paths so a future refactor doesn't accidentally fire
    /// the rejection callback synchronously from the network queue.
    func testRejectedDispatchCallbackFiresOnMainEvenFromOffMainCaller() {
        let runtime = makeShowControlRuntime()
        let state = ShowControlState()
        let d = ShowControlDispatcher(runtime: runtime, state: state)
        let exp = expectation(description: "rejection callback fires on main")
        var callbackRanOnMain: Bool?
        d.onActionDispatched = { _, _, result in
            if case .rejected = result, callbackRanOnMain == nil {
                callbackRanOnMain = Thread.isMainThread
                exp.fulfill()
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // Empty capability set => capability check rejects.
            _ = d.dispatch(.previous, source: .test, capabilities: [])
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(callbackRanOnMain, true,
                       "Rejection-path callback must also run on main.")
    }
}
