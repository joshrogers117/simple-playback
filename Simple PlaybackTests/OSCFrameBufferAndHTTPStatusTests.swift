import Foundation
import XCTest
@testable import Simple_Playback

/// Hardening pin tests added during the squeaky-clean review pass:
///
/// 1. `TCPFrameBuffer.nextPacket` now caps a single OSC frame at 1 MiB. A
///    misbehaving or malicious peer announcing a 4 GiB size used to buffer
///    silently; the cap prevents the unbounded buffer growth.
/// 2. `HTTPServer.httpStatus(for:)` replaces the dead `200 : 200` ternary
///    with a real status mapping. Capability rejections become 401 (so
///    curl / log scrapers can distinguish at a glance); other rejections
///    stay 200 with the structured envelope in the body.
@MainActor
final class OSCFrameBufferAndHTTPStatusTests: XCTestCase {

    // MARK: - TCPFrameBuffer DoS bound

    func testTCPFrameBufferAcceptsFrameAtMaxSize() {
        let buffer = TCPFrameBuffer()
        let payload = Data(repeating: 0xAB, count: TCPFrameBuffer.maxPacketSize)
        buffer.append(framedSize(for: .tcp, packet: payload))
        let decoded = buffer.nextPacket()
        XCTAssertEqual(decoded?.count, TCPFrameBuffer.maxPacketSize,
                       "Frames at exactly maxPacketSize must still decode.")
        XCTAssertFalse(buffer.didRejectOversizedFrame)
    }

    func testTCPFrameBufferRejectsFrameOverMaxSize() {
        let buffer = TCPFrameBuffer()
        // Hand-craft a header that announces (maxPacketSize + 1) bytes
        // without actually buffering that much — the rejection is supposed
        // to fire before the body arrives.
        let oversize = UInt32(TCPFrameBuffer.maxPacketSize + 1).bigEndian
        var header = Data()
        withUnsafeBytes(of: oversize) { header.append(contentsOf: $0) }
        buffer.append(header)
        XCTAssertNil(buffer.nextPacket(),
                     "Oversize header must short-circuit before a packet ships.")
        XCTAssertTrue(buffer.didRejectOversizedFrame,
                      "Rejection flag is the server's hook to drop the connection.")
    }

    func testTCPFrameBufferDropsAccumulatedBytesOnRejection() {
        let buffer = TCPFrameBuffer()
        // Append a half-formed oversize frame so internal buffer is non-empty.
        let oversize = UInt32(TCPFrameBuffer.maxPacketSize + 1).bigEndian
        var hdr = Data()
        withUnsafeBytes(of: oversize) { hdr.append(contentsOf: $0) }
        hdr.append(Data(repeating: 0, count: 64))
        buffer.append(hdr)
        _ = buffer.nextPacket()
        // Subsequent valid frame must not be poisoned by the leftover bytes.
        let validPayload = Data([0x2F, 0x73, 0x70])
        buffer.append(framedSize(for: .tcp, packet: validPayload))
        // After rejection the impl wipes the buffer, so the next decode
        // sees only the valid frame appended after.
        XCTAssertEqual(buffer.nextPacket(), validPayload)
    }

    func testTCPFrameBufferRoundTripsValidFrame() {
        let buffer = TCPFrameBuffer()
        let payload = Data([0x2F, 0x73, 0x70, 0x2F, 0x67, 0x6F]) // "/sp/go"
        buffer.append(framedSize(for: .tcp, packet: payload))
        XCTAssertEqual(buffer.nextPacket(), payload)
    }

    // MARK: - HTTPServer.httpStatus mapping

    func testHTTPStatusOKResultMapsTo200() {
        let result = ShowControlActionResult.ok(data: [:])
        XCTAssertEqual(HTTPServer.httpStatus(for: result), 200)
    }

    func testHTTPStatusOKResultWithDataMapsTo200() {
        let result = ShowControlActionResult.ok(data: ["foo": .string("bar")])
        XCTAssertEqual(HTTPServer.httpStatus(for: result), 200)
    }

    func testHTTPStatusCapabilityRejectionMapsTo401() {
        let result = ShowControlActionResult.rejected(reason: "missing_capability:fire")
        XCTAssertEqual(HTTPServer.httpStatus(for: result), 401,
                       "Capability misses surface at the HTTP layer so simple clients see 401.")
    }

    func testHTTPStatusGenericRejectionMapsTo200() {
        // Idempotency lockout, unknown_cue, not_running — all runtime no-ops
        // that the dispatcher rejects with reasons not prefixed by
        // "missing_capability". The HTTP layer reports 200 + structured
        // body so the caller can read the reason without parsing 4xx codes.
        let result = ShowControlActionResult.rejected(reason: "unknown_cue:Q.bogus")
        XCTAssertEqual(HTTPServer.httpStatus(for: result), 200)
    }

    func testHTTPStatusIdempotencyRejectionMapsTo200() {
        let result = ShowControlActionResult.rejected(reason: "idempotent_lockout")
        XCTAssertEqual(HTTPServer.httpStatus(for: result), 200)
    }
}
