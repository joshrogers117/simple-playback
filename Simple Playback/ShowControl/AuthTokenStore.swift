import Foundation

/// Bearer-token store for the HTTP twin and (optionally) for OSC.
///
/// Tokens are arbitrary opaque strings; each carries a capability set
/// (`read` / `fire` / `edit`). The default token set on a fresh project is
/// one token with `read+fire`. Show Mode strips `edit` from every token
/// at the dispatcher level — the store just records what capabilities are
/// granted; the dispatcher applies the show-mode mask.
final class AuthTokenStore {
    struct Token: Codable, Hashable {
        let value: String
        let label: String
        let capabilities: Set<ShowControlCapability>
    }

    private let queue = DispatchQueue(label: "com.josh.simpleplayback.auth")
    private var tokens: [String: Token] = [:]

    init() {}

    func add(token: String, label: String, capabilities: Set<ShowControlCapability>) {
        queue.sync {
            tokens[token] = Token(value: token, label: label, capabilities: capabilities)
        }
    }

    func remove(token: String) {
        queue.sync { tokens.removeValue(forKey: token) }
    }

    func capabilities(for token: String) -> Set<ShowControlCapability>? {
        queue.sync { tokens[token]?.capabilities }
    }

    func contains(token: String) -> Bool {
        queue.sync { tokens[token] != nil }
    }

    func allTokens() -> [Token] {
        queue.sync { Array(tokens.values) }
    }

    /// Generates a fresh random bearer token.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if result == errSecSuccess {
            return Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        // Fallback: UUID concatenation.
        return UUID().uuidString + "-" + UUID().uuidString
    }
}
