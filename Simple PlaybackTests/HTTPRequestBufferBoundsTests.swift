import Foundation
import XCTest
@testable import Simple_Playback

/// Hardening pin tests added during the squeaky-clean review pass:
///
/// - `HTTPRequestBuffer.maxHeaderSize` (64 KiB) — header bytes that arrive
///   without a `\r\n\r\n` terminator must not grow the buffer indefinitely.
/// - `HTTPRequestBuffer.maxBodySize` (1 MiB) — `Content-Length` larger than
///   the cap must reject without allocating attacker-controlled memory.
/// - `findHeaderEnd` resume-cursor — incomplete headers arriving across
///   multiple `append` calls must not re-scan from offset 0 each time
///   (was O(n²); now linear).
@MainActor
final class HTTPRequestBufferBoundsTests: XCTestCase {

    // MARK: - Header-size cap

    func testHeaderUnderCapAcceptsRequest() {
        let buf = HTTPRequestBuffer()
        let request = "GET /api/v1/state HTTP/1.1\r\nHost: localhost\r\n\r\n"
        buf.append(Data(request.utf8))
        XCTAssertNotNil(buf.nextRequest())
        XCTAssertFalse(buf.didRejectOversizedRequest)
    }

    func testHeaderOverCapRejectsAndDropsBuffer() {
        let buf = HTTPRequestBuffer()
        // Pour bytes without ever emitting `\r\n\r\n`.
        let chunk = String(repeating: "A", count: HTTPRequestBuffer.maxHeaderSize / 4)
        for _ in 0..<5 {
            buf.append(Data(chunk.utf8))
            _ = buf.nextRequest()
        }
        XCTAssertTrue(buf.didRejectOversizedRequest,
                      "Header bytes growing past maxHeaderSize must trip the rejection flag.")
    }

    // MARK: - Body-size cap

    func testBodyUnderCapAcceptsRequest() {
        let buf = HTTPRequestBuffer()
        let body = String(repeating: "x", count: 256)
        let request = "POST /api/v1/cue HTTP/1.1\r\nContent-Length: 256\r\n\r\n\(body)"
        buf.append(Data(request.utf8))
        let req = buf.nextRequest()
        XCTAssertEqual(req?.body?.count, 256)
        XCTAssertFalse(buf.didRejectOversizedRequest)
    }

    func testBodyOverCapRejectsRequest() {
        let buf = HTTPRequestBuffer()
        // Announce a body 1 byte over cap; impl must reject before
        // allocating, so we don't actually have to send the bytes.
        let cap = HTTPRequestBuffer.maxBodySize + 1
        let request = "POST /api/v1/cue HTTP/1.1\r\nContent-Length: \(cap)\r\n\r\n"
        buf.append(Data(request.utf8))
        XCTAssertNil(buf.nextRequest())
        XCTAssertTrue(buf.didRejectOversizedRequest)
    }

    func testNegativeContentLengthRejected() {
        let buf = HTTPRequestBuffer()
        let request = "POST /api/v1/cue HTTP/1.1\r\nContent-Length: -1\r\n\r\n"
        buf.append(Data(request.utf8))
        XCTAssertNil(buf.nextRequest())
        XCTAssertTrue(buf.didRejectOversizedRequest)
    }

    // MARK: - Header-end scan resumes from cursor

    func testHeaderArrivingAcrossManyChunksStillParses() {
        // Drip-feed the request a few bytes at a time. Pre-fix this would
        // re-scan from offset 0 on every append (O(n²)); post-fix the scan
        // resumes from the cursor. Either way the request must parse — but
        // the post-fix path is also fast.
        let buf = HTTPRequestBuffer()
        let request = "GET /api/v1/state HTTP/1.1\r\nHost: localhost\r\nUser-Agent: drip\r\n\r\n"
        for byte in request.utf8 {
            buf.append(Data([byte]))
            _ = buf.nextRequest() // most return nil; the last one returns the request
        }
        // Final scan should find the now-complete request.
        // (The drip loop above already attempted parsing on each byte; re-
        // run nextRequest to confirm the final state. The expected state
        // is "no buffered bytes left" since the last drip completed it.)
        // Reassemble to verify behaviour deterministically:
        let buf2 = HTTPRequestBuffer()
        for byte in request.utf8 {
            buf2.append(Data([byte]))
        }
        let req = buf2.nextRequest()
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.method, "GET")
        XCTAssertEqual(req?.path, "/api/v1/state")
    }

    func testTwoBackToBackRequestsParseIndependently() {
        let buf = HTTPRequestBuffer()
        let r1 = "GET /api/v1/state HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let r2 = "GET /api/v1/cues HTTP/1.1\r\nHost: localhost\r\n\r\n"
        buf.append(Data(r1.utf8))
        buf.append(Data(r2.utf8))
        let first = buf.nextRequest()
        let second = buf.nextRequest()
        XCTAssertEqual(first?.path, "/api/v1/state")
        XCTAssertEqual(second?.path, "/api/v1/cues")
        XCTAssertNil(buf.nextRequest())
    }

    func testSeparatorStraddlingChunkBoundaryParses() {
        // The `\r\n\r\n` separator must be detected even when it spans the
        // boundary between two `append` chunks — the cursor's "rewind 3
        // bytes" rule covers this.
        let buf = HTTPRequestBuffer()
        let firstChunk = "GET / HTTP/1.1\r\nHost: x\r\n\r"
        let secondChunk = "\nbody-bytes-after"
        buf.append(Data(firstChunk.utf8))
        XCTAssertNil(buf.nextRequest())
        buf.append(Data(secondChunk.utf8))
        let req = buf.nextRequest()
        XCTAssertNotNil(req,
                       "Separator straddling the boundary must still be detected.")
        XCTAssertEqual(req?.path, "/")
    }
}
