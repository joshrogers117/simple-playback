import Foundation

/// Parsed HTTP/1.1 request.
struct HTTPRequest {
    let method: String
    let path: String
    let queryParameters: [String: String]
    let httpVersion: String
    let headers: [String: String]      // header names lowercased
    let body: Data?
    let host: String

    var keepAlive: Bool {
        let connection = headers["connection"]?.lowercased() ?? "keep-alive"
        return !connection.contains("close")
    }

    var isWebSocketUpgrade: Bool {
        let upgrade = headers["upgrade"]?.lowercased() ?? ""
        let connection = headers["connection"]?.lowercased() ?? ""
        return upgrade.contains("websocket") && connection.contains("upgrade")
    }

    func bearerToken() -> String? {
        guard let auth = headers["authorization"] else { return nil }
        let parts = auth.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1])
    }
}

/// Reassembles complete HTTP/1.1 requests from a TCP byte stream.
final class HTTPRequestBuffer {

    /// Hard ceiling on a single request's combined header size (excluding
    /// body). 64 KiB is well above any plausible legitimate request header
    /// set; without a cap, a peer that sends header bytes without ever
    /// emitting `\r\n\r\n` would force the server to scan an unbounded
    /// buffer on every receive callback.
    static let maxHeaderSize: Int = 64 * 1024

    /// Hard ceiling on a request body's `Content-Length`. The OSC/HTTP
    /// surface accepts small JSON payloads (cue numbers, scrub values);
    /// 1 MiB is far above any plausible operator-supplied body. Without
    /// the cap, a peer claiming Content-Length: 4 GiB would force the
    /// server to buffer attacker-controlled bytes indefinitely.
    static let maxBodySize: Int = 1 << 20

    /// Set when `nextRequest()` rejects a request that exceeds either
    /// `maxHeaderSize` or `maxBodySize`. The server should drop the
    /// connection on the next callback rather than try to recover.
    private(set) var didRejectOversizedRequest: Bool = false

    private var buffer = Data()
    /// Where to resume the `\r\n\r\n` scan on the next `nextRequest()` call.
    /// Without this, an incomplete request growing across N receive
    /// callbacks would re-scan the whole buffer N times — O(n²) in the
    /// total bytes received before the headers complete.
    private var headerScanCursor: Int = 0

    func append(_ data: Data) { buffer.append(data) }

    /// Returns one complete request, or `nil` if the buffer doesn't yet hold
    /// a full set of headers + body. Accepted body kinds: `Content-Length:`
    /// only. Chunked transfer encoding is rejected.
    func nextRequest() -> HTTPRequest? {
        // Find header/body separator.
        guard let headerEnd = findHeaderEnd() else {
            // Headers still incomplete. If we've buffered more than the
            // cap allows, surface an oversized-request signal and drop
            // the buffer so we don't keep growing.
            if buffer.count > Self.maxHeaderSize {
                didRejectOversizedRequest = true
                buffer.removeAll(keepingCapacity: false)
                headerScanCursor = 0
            }
            return nil
        }
        let headerData = buffer.subdata(in: 0..<headerEnd)
        let headerString = String(data: headerData, encoding: .ascii) ?? String(data: headerData, encoding: .utf8) ?? ""
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        let httpVersion = String(parts[2])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).lowercased().trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        if contentLength < 0 || contentLength > Self.maxBodySize {
            // Reject and drop — refusing to allocate attacker-controlled
            // memory is preferable to graceful degradation here.
            didRejectOversizedRequest = true
            buffer.removeAll(keepingCapacity: false)
            headerScanCursor = 0
            return nil
        }
        let bodyStart = headerEnd + 4 // skip "\r\n\r\n"
        guard buffer.count >= bodyStart + contentLength else { return nil }
        let body: Data?
        if contentLength > 0 {
            body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        } else {
            body = nil
        }

        // Drop the consumed bytes; reset the scan cursor since the next
        // request starts at offset 0 of the (now smaller) buffer.
        buffer.removeSubrange(0..<(bodyStart + contentLength))
        headerScanCursor = 0

        // Split path and query.
        let (path, query) = splitPathQuery(target)
        let host = headers["host"] ?? ""

        return HTTPRequest(
            method: method,
            path: path,
            queryParameters: query,
            httpVersion: httpVersion,
            headers: headers,
            body: body,
            host: host
        )
    }

    private func findHeaderEnd() -> Int? {
        // Resume the `\r\n\r\n` scan from where we left off on the prior
        // call so a header-set arriving across multiple receive callbacks
        // reduces from O(n*m) to O(n) total. The cursor is reset to 0
        // when a request is consumed (the next request starts at offset 0).
        let needle: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard buffer.count >= needle.count else { return nil }
        // Start three bytes earlier than the cursor to handle a separator
        // straddling the boundary between two appended chunks.
        let start = max(0, headerScanCursor - (needle.count - 1))
        let end = buffer.count - needle.count
        guard end >= start else { return nil }
        for i in start...end {
            if buffer[i] == needle[0]
                && buffer[i + 1] == needle[1]
                && buffer[i + 2] == needle[2]
                && buffer[i + 3] == needle[3] {
                return i
            }
        }
        // No match this pass — bookmark the (last viable starting offset)
        // so the next call doesn't redo work.
        headerScanCursor = max(0, buffer.count - (needle.count - 1))
        return nil
    }

    private func splitPathQuery(_ target: String) -> (String, [String: String]) {
        guard let q = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<q])
        let queryString = String(target[target.index(after: q)...])
        var params: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                params[k] = v
            } else if kv.count == 1 {
                let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                params[k] = ""
            }
        }
        return (path, params)
    }
}
