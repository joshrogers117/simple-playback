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
    private var buffer = Data()

    func append(_ data: Data) { buffer.append(data) }

    /// Returns one complete request, or `nil` if the buffer doesn't yet hold
    /// a full set of headers + body. Accepted body kinds: `Content-Length:`
    /// only. Chunked transfer encoding is rejected.
    func nextRequest() -> HTTPRequest? {
        // Find header/body separator.
        guard let headerEnd = findHeaderEnd() else { return nil }
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
        let bodyStart = headerEnd + 4 // skip "\r\n\r\n"
        guard buffer.count >= bodyStart + contentLength else { return nil }
        let body: Data?
        if contentLength > 0 {
            body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        } else {
            body = nil
        }

        // Drop the consumed bytes.
        buffer.removeSubrange(0..<(bodyStart + contentLength))

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
        // Find the first occurrence of "\r\n\r\n".
        let needle: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard buffer.count >= needle.count else { return nil }
        let bytes = [UInt8](buffer)
        for i in 0...(bytes.count - needle.count) {
            if Array(bytes[i..<(i + needle.count)]) == needle {
                return i
            }
        }
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
