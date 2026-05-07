import Foundation

/// Decodes an `OSCMessage` into a `ShowControlAction`. Returns `nil` for
/// addresses we don't recognize (the caller should reply with an error).
enum OSCAddressMap {
    static func action(for message: OSCMessage) -> ShowControlAction? {
        let segs = message.address.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segs.first?.lowercased() == "sp" else { return nil }
        let tail = Array(segs.dropFirst())
        return decode(tail: tail, args: message.arguments)
    }

    private static func decode(tail: [String], args: [OSCArgument]) -> ShowControlAction? {
        guard let head = tail.first?.lowercased() else { return nil }
        switch head {
        case "go":
            if let target = args.first?.stringValue {
                return .go(target: target)
            }
            return .go(target: nil)
        case "prev", "previous":
            return .previous
        case "panic":
            return .panic(fade: args.first.flatMap { $0.floatValue.map(TimeInterval.init) })
        case "clear":
            return .clear
        case "playhead":
            if let s = args.first?.stringValue {
                return .movePlayhead(cueNumber: s)
            }
            return nil
        case "load":
            if let s = args.first?.stringValue {
                return .load(cueNumber: s)
            }
            return nil
        case "ping":
            return .ping
        case "subscribe":
            return parseHostPort(args).map { .subscribe(host: $0.0, port: $0.1) }
        case "unsubscribe":
            return parseHostPort(args).map { .unsubscribe(host: $0.0, port: $0.1) }
        case "show_mode":
            return args.first?.intValue.map { .showMode(enabled: $0 != 0) }
        case "workspace":
            return decodeWorkspace(tail: Array(tail.dropFirst()))
        case "look":
            return decodeLook(tail: Array(tail.dropFirst()))
        case "output":
            return decodeOutput(tail: Array(tail.dropFirst()), args: args)
        case "timecode":
            return decodeTimecode(tail: Array(tail.dropFirst()), args: args)
        case "cue":
            return decodeCue(tail: Array(tail.dropFirst()), args: args)
        default:
            return nil
        }
    }

    private static func parseHostPort(_ args: [OSCArgument]) -> (String, UInt16)? {
        // Either "host:port" as a single string, or two args (string host, int port).
        if let s = args.first?.stringValue, let idx = s.lastIndex(of: ":") {
            let host = String(s[..<idx])
            let portStr = String(s[s.index(after: idx)...])
            if let p = UInt16(portStr) {
                return (host, p)
            }
        }
        if args.count >= 2,
           let host = args[0].stringValue,
           let port = args[1].intValue,
           port >= 0 {
            return (host, UInt16(min(port, Int32(UInt16.max))))
        }
        return nil
    }

    private static func decodeWorkspace(tail: [String]) -> ShowControlAction? {
        guard let head = tail.first?.lowercased() else { return nil }
        switch head {
        case "save": return .workspaceSave
        case "reload": return .workspaceReload
        default: return nil
        }
    }

    private static func decodeLook(tail: [String]) -> ShowControlAction? {
        // /sp/look/{name}/recall
        guard tail.count >= 2, tail.last?.lowercased() == "recall" else { return nil }
        let name = tail[0]
        return .lookRecall(name: name)
    }

    private static func decodeOutput(tail: [String], args: [OSCArgument]) -> ShowControlAction? {
        // /sp/output/main/freeze i 0|1 ; /sp/output/main/blackout i 0|1
        guard tail.count >= 2 else { return nil }
        let action = tail[1].lowercased()
        let enabled = (args.first?.intValue ?? 0) != 0
        switch action {
        case "freeze": return .outputFreeze(enabled: enabled)
        case "blackout": return .outputBlackout(enabled: enabled)
        default: return nil
        }
    }

    private static func decodeTimecode(tail: [String], args: [OSCArgument]) -> ShowControlAction? {
        guard let head = tail.first?.lowercased() else { return nil }
        switch head {
        case "source":
            return args.first?.stringValue.map { .timecodeSource(spec: $0) }
        case "engaged":
            return args.first?.intValue.map { .timecodeEngaged(enabled: $0 != 0) }
        case "offset":
            return args.first?.floatValue.map { .timecodeOffset(seconds: $0) }
        default:
            return nil
        }
    }

    private static func decodeCue(tail: [String], args: [OSCArgument]) -> ShowControlAction? {
        // /sp/cue/{id}/{action}[/sub]
        guard tail.count >= 2 else { return nil }
        let id = tail[0]
        let act = tail[1].lowercased()
        switch act {
        case "play":
            return .cuePlay(cueNumber: id)
        case "stop":
            return .cueStop(cueNumber: id, fade: args.first.flatMap { $0.floatValue.map(TimeInterval.init) })
        case "scrub":
            if tail.count >= 3, tail[2].lowercased() == "seconds" {
                return args.first?.floatValue.map { .cueScrubSeconds(cueNumber: id, seconds: $0) }
            }
            return args.first?.floatValue.map { .cueScrubNormalized(cueNumber: id, position: $0) }
        case "opacity":
            return args.first?.floatValue.map { .cueOpacity(cueNumber: id, value: $0) }
        case "audio":
            // /sp/cue/{id}/audio/level f
            if tail.count >= 3, tail[2].lowercased() == "level" {
                return args.first?.floatValue.map { .cueAudioLevel(cueNumber: id, dB: $0) }
            }
            return nil
        case "in_point":
            return args.first?.floatValue.map { .cueInPoint(cueNumber: id, seconds: $0) }
        case "out_point":
            return args.first?.floatValue.map { .cueOutPoint(cueNumber: id, seconds: $0) }
        case "loop":
            return args.first?.intValue.map { .cueLoop(cueNumber: id, enabled: $0 != 0) }
        case "goto":
            return args.first?.stringValue.map { .cueGoto(cueNumber: id, nextNumber: $0) }
        case "preload":
            return .cuePreload(cueNumber: id)
        case "notes":
            return args.first?.stringValue.map { .cueNotes(cueNumber: id, text: $0) }
        default:
            return nil
        }
    }
}

/// Encodes a `ShowControlActionResult` into an OSC `/reply` envelope, plus
/// reusable JSON encoding for HTTP twin replies.
enum ShowControlReplyEnvelope {
    /// Builds the JSON body. Includes `apiVersion`, `address`, `status`, `data`.
    static func json(
        address: String,
        result: ShowControlActionResult,
        encoder: JSONEncoder = .standard()
    ) -> Data {
        let payload = build(address: address, result: result)
        return (try? encoder.encode(payload)) ?? Data("{}".utf8)
    }

    static func jsonString(
        address: String,
        result: ShowControlActionResult
    ) -> String {
        let data = json(address: address, result: result)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func build(
        address: String,
        result: ShowControlActionResult
    ) -> JSONReply {
        switch result {
        case let .ok(data):
            return JSONReply(
                apiVersion: SHOW_CONTROL_API_VERSION,
                address: address,
                status: "ok",
                data: data,
                error: nil
            )
        case let .rejected(reason):
            return JSONReply(
                apiVersion: SHOW_CONTROL_API_VERSION,
                address: address,
                status: "error",
                data: nil,
                error: reason
            )
        }
    }
}

/// JSON-encodable reply envelope.
struct JSONReply: Encodable {
    let apiVersion: Int
    let address: String
    let status: String
    let data: [String: ShowControlValue]?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case apiVersion, address, status, data, error
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(apiVersion, forKey: .apiVersion)
        try c.encode(address, forKey: .address)
        try c.encode(status, forKey: .status)
        if let data = data {
            try c.encode(JSONValueDict(data), forKey: .data)
        }
        if let error = error {
            try c.encode(error, forKey: .error)
        }
    }
}

/// Wrapper that knows how to encode a `[String: ShowControlValue]` into JSON.
struct JSONValueDict: Encodable {
    let underlying: [String: ShowControlValue]
    init(_ d: [String: ShowControlValue]) { underlying = d }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        for (k, v) in underlying {
            try v.encode(to: c.superEncoder(forKey: AnyCodingKey(stringValue: k)!))
        }
    }
}

extension ShowControlValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case let .string(s): try single.encode(s)
        case let .int(i): try single.encode(i)
        case let .double(d): try single.encode(d)
        case let .bool(b): try single.encode(b)
        case .null: try single.encodeNil()
        case let .array(arr): try single.encode(arr)
        case let .object(o): try single.encode(JSONValueDict(o))
        }
    }
}

/// AnyCodingKey shim so we can encode arbitrary string-keyed maps.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = String(intValue) }
}

extension JSONEncoder {
    /// Standard encoder for show-control replies. Sorted keys for stable output.
    static func standard() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
