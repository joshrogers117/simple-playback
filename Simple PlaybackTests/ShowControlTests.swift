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
}
