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
}
