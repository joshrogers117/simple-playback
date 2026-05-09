import Foundation
import XCTest
@testable import Simple_Playback

/// Direct coverage of `HTTPServer.computeResponse(to:)` — the pure-logic
/// request-routing decision extracted during the squeaky-clean review pass.
/// Pre-refactor `HTTPServer.respond` required a real `NWConnection` to test;
/// only `HTTPRequestBuffer` parsing was covered by direct tests. The control
/// plane is operator-facing (Companion / curl scripts / web UIs all hit
/// it), so end-to-end coverage of the routing + auth surface is load-bearing.
@MainActor
final class HTTPServerRespondTests: XCTestCase {

    // MARK: - Fixture helpers

    private func makeRequest(
        method: String = "GET",
        path: String = "/api/v1/state",
        headers: [String: String] = [:],
        body: Data? = nil
    ) -> HTTPRequest {
        var lowered: [String: String] = [:]
        for (k, v) in headers {
            lowered[k.lowercased()] = v
        }
        // RootView's `Connection: keep-alive` default is encoded by the
        // `HTTPRequest.keepAlive` computed property. Tests don't usually
        // care about keep-alive shape; default it to an HTTP/1.1 keep-alive.
        if lowered["connection"] == nil {
            lowered["connection"] = "keep-alive"
        }
        return HTTPRequest(
            method: method,
            path: path,
            queryParameters: [:],
            httpVersion: "HTTP/1.1",
            headers: lowered,
            body: body,
            host: "localhost"
        )
    }

    private func makeServer(
        defaultCapabilities: Set<ShowControlCapability> = [.read, .fire],
        attachDispatcher: Bool = true,
        attachTokens: Bool = false
    ) -> HTTPServer {
        var config = HTTPServer.Configuration()
        config.defaultCapabilities = defaultCapabilities
        let server = HTTPServer(configuration: config)
        if attachDispatcher {
            var list = ShowList()
            try? list.append(Cue(number: "INTRO", title: "Intro", assetID: UUID()))
            let runtime = CueRuntime(showList: list)
            runtime.minimumGoInterval = 0
            let state = ShowControlState()
            state.updateShowList(list)
            server.dispatcher = ShowControlDispatcher(runtime: runtime, state: state, clock: { 0 })
        }
        if attachTokens {
            server.tokens = AuthTokenStore()
        }
        return server
    }

    // MARK: - Sec-WebSocket-Accept canonical RFC 6455 example

    func testWebSocketAcceptKeyMatchesRFC6455CanonicalExample() {
        // RFC 6455 §1.3 worked example: client sends key
        // `dGhlIHNhbXBsZSBub25jZQ==`; server must respond with
        // `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`.
        let accept = HTTPServer.webSocketAcceptKey(for: "dGhlIHNhbXBsZSBub25jZQ==")
        XCTAssertEqual(accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
                       "Accept-key derivation must match RFC 6455 §1.3 worked example.")
    }

    // MARK: - Unknown route

    func testUnknownPathReturnsRoute404() {
        let server = makeServer()
        let outcome = server.computeResponse(to: makeRequest(path: "/api/v1/nonexistent"))
        guard case let .writeError(status, jsonError, _) = outcome else {
            XCTFail("Expected writeError(404, unknown_route); got \(outcome)")
            return
        }
        XCTAssertEqual(status, 404)
        XCTAssertEqual(jsonError, "unknown_route")
    }

    // MARK: - state / cues / cueDetail capability gate

    func testStateSnapshotRequiresReadCapability() {
        let server = makeServer(defaultCapabilities: [.fire])
        let outcome = server.computeResponse(to: makeRequest(path: "/api/v1/state"))
        guard case let .writeError(status, jsonError, _) = outcome else {
            XCTFail("Expected writeError(401, missing_capability:read); got \(outcome)")
            return
        }
        XCTAssertEqual(status, 401)
        XCTAssertEqual(jsonError, "missing_capability:read")
    }

    func testStateSnapshotWithReadCapabilityReturnsJSON() {
        let server = makeServer(defaultCapabilities: [.read])
        let outcome = server.computeResponse(to: makeRequest(path: "/api/v1/state"))
        guard case let .write(status, body, contentType, _) = outcome else {
            XCTFail("Expected write(200, json, ...); got \(outcome)")
            return
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(contentType, "application/json")
        XCTAssertFalse(body.isEmpty)
    }

    func testCueListRequiresReadCapability() {
        let server = makeServer(defaultCapabilities: [.fire])
        let outcome = server.computeResponse(to: makeRequest(path: "/api/v1/cues"))
        guard case let .writeError(status, _, _) = outcome else {
            XCTFail("Expected 401 for /cues without read; got \(outcome)")
            return
        }
        XCTAssertEqual(status, 401)
    }

    func testCueDetailReturns404ForUnknownCue() {
        let server = makeServer(defaultCapabilities: [.read])
        let outcome = server.computeResponse(to: makeRequest(path: "/api/v1/cue/UNKNOWN"))
        guard case let .writeError(status, jsonError, _) = outcome else {
            XCTFail("Expected 404 unknown_cue; got \(outcome)")
            return
        }
        XCTAssertEqual(status, 404)
        XCTAssertEqual(jsonError, "unknown_cue")
    }

    // MARK: - Action dispatch path

    func testActionRouteWithoutDispatcherReturns503NoRuntime() {
        let server = makeServer(attachDispatcher: false)
        let outcome = server.computeResponse(to: makeRequest(method: "POST", path: "/api/v1/go"))
        guard case let .writeError(status, jsonError, _) = outcome else {
            XCTFail("Expected 503 no_runtime; got \(outcome)")
            return
        }
        XCTAssertEqual(status, 503)
        XCTAssertEqual(jsonError, "no_runtime")
    }

    func testActionRouteWithDispatcherReturnsJSONReply() {
        let server = makeServer()
        let outcome = server.computeResponse(to: makeRequest(method: "POST", path: "/api/v1/go"))
        guard case let .write(status, body, contentType, _) = outcome else {
            XCTFail("Expected 200 + JSON envelope; got \(outcome)")
            return
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(contentType, "application/json")
        XCTAssertFalse(body.isEmpty)
    }

    // MARK: - WebSocket upgrade path

    func testWebSocketUpgradeMissingKeyReturnsRejection() {
        let server = makeServer()
        let req = makeRequest(
            path: "/api/v1/events",
            headers: [
                "Upgrade": "websocket",
                "Connection": "Upgrade"
                // Note: no Sec-WebSocket-Key
            ]
        )
        let outcome = server.computeResponse(to: req)
        XCTAssertEqual(outcome, .rejectWebSocketMissingKey)
    }

    func testWebSocketUpgradeWithKeyEmitsAcceptKey() {
        let server = makeServer()
        let req = makeRequest(
            path: "/api/v1/events",
            headers: [
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ=="
            ]
        )
        let outcome = server.computeResponse(to: req)
        guard case let .upgradeWebSocket(acceptKey) = outcome else {
            XCTFail("Expected .upgradeWebSocket; got \(outcome)")
            return
        }
        XCTAssertEqual(acceptKey, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testWebSocketUpgradeOnlyAppliesToEventsPath() {
        // /api/v1/state with WebSocket headers must NOT upgrade — only
        // the events path is the WS endpoint.
        let server = makeServer()
        let req = makeRequest(
            path: "/api/v1/state",
            headers: [
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ=="
            ]
        )
        let outcome = server.computeResponse(to: req)
        // Should fall through to the normal /state handler — read cap
        // present (default is [.read, .fire]) → 200 JSON.
        guard case .write(_, _, _, _) = outcome else {
            XCTFail("Non-events path with WS headers must NOT upgrade; got \(outcome)")
            return
        }
    }

    // MARK: - Bearer token auth

    func testTokenStoreAuthOverridesDefaultCapabilities() {
        // When a token store is attached, an unknown bearer token
        // collapses to empty caps (no default-cap fallback). Verify
        // /state returns 401 even though the default-cap config would
        // allow it.
        let server = makeServer(defaultCapabilities: [.read, .fire], attachTokens: true)
        let req = makeRequest(
            path: "/api/v1/state",
            headers: ["Authorization": "Bearer not-a-real-token"]
        )
        let outcome = server.computeResponse(to: req)
        guard case let .writeError(status, _, _) = outcome else {
            XCTFail("Expected 401 for unknown bearer token; got \(outcome)")
            return
        }
        XCTAssertEqual(status, 401)
    }

    func testNoTokenStoreUsesDefaultCapabilities() {
        // Without a token store, the default-cap config gates access.
        let server = makeServer(defaultCapabilities: [.read])
        let outcome = server.computeResponse(to: makeRequest(path: "/api/v1/state"))
        guard case .write = outcome else {
            XCTFail("Expected 200 OK from default-cap; got \(outcome)")
            return
        }
    }

    // MARK: - OSCQuery handler first-chance

    func testOSCQueryHandlerHandlesNonAPIPathsFirst() {
        let server = makeServer()
        var called = false
        server.oscQueryHandler = { path, _ in
            called = true
            XCTAssertEqual(path, "/")
            return (status: 200, body: Data("{}".utf8), contentType: "application/json")
        }
        let outcome = server.computeResponse(to: makeRequest(path: "/"))
        XCTAssertTrue(called, "OSCQuery handler should get first chance at non-/api/v1 paths.")
        guard case let .write(status, _, contentType, _) = outcome else {
            XCTFail("Expected write outcome; got \(outcome)")
            return
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(contentType, "application/json")
    }

    func testOSCQueryHandlerSkippedForAPIv1Paths() {
        // `/api/v1/...` paths must NOT consult the OSCQuery handler.
        let server = makeServer()
        var called = false
        server.oscQueryHandler = { _, _ in
            called = true
            return (status: 200, body: Data(), contentType: "application/json")
        }
        _ = server.computeResponse(to: makeRequest(path: "/api/v1/state"))
        XCTAssertFalse(called, "OSCQuery handler must not see /api/v1 paths.")
    }
}
