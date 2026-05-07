import Foundation

/// Minimal OSC 1.0 message implementation.
///
/// We support the four type tags that the Simple Playback action surface needs:
/// - `s` — OSC-string (4-byte-aligned, NUL-terminated)
/// - `i` — int32 big-endian
/// - `f` — float32 big-endian
/// - `b` — blob (4-byte size prefix, padded payload)
///
/// Bundles (`#bundle`) are decoded as a flat list of contained messages.
/// We do not generate bundles — outbound traffic is one-message-per-datagram.
///
/// Address-pattern matching supports literal segments plus `*` (any segment) and
/// the reserved selectors `playhead`, `selected`, `active` documented in the
/// show-control spec. We do NOT implement OSC's `[abc]`, `{a,b}`, or `?` glob
/// forms — the spec curates a small enough action surface that pattern wildcards
/// only need `*` for whole-segment matching.
enum OSCArgument: Equatable {
    case string(String)
    case int(Int32)
    case float(Float)
    case blob(Data)

    /// Type-tag character for the type-tag string.
    var tag: Character {
        switch self {
        case .string: return "s"
        case .int: return "i"
        case .float: return "f"
        case .blob: return "b"
        }
    }

    var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    var intValue: Int32? {
        if case let .int(i) = self { return i }
        return nil
    }

    var floatValue: Float? {
        switch self {
        case let .float(f): return f
        case let .int(i): return Float(i)
        default: return nil
        }
    }

    var blobValue: Data? {
        if case let .blob(d) = self { return d }
        return nil
    }
}

/// One OSC message: an address (e.g. `/sp/go`) and zero or more arguments.
struct OSCMessage: Equatable {
    let address: String
    let arguments: [OSCArgument]

    init(address: String, arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }
}

/// Errors raised by the OSC encoder / decoder.
enum OSCDecodingError: Error, Equatable {
    case truncated
    case notNULTerminated
    case invalidTypeTag(Character)
    case unalignedSize
    case unsupportedBundleElement
}

// MARK: - Encoding

extension OSCMessage {
    /// Big-endian binary representation per OSC 1.0.
    func data() -> Data {
        var out = Data()
        out.appendOSCString(address)

        // Type-tag string starts with ','.
        var tagString = ","
        for arg in arguments {
            tagString.append(arg.tag)
        }
        out.appendOSCString(tagString)

        for arg in arguments {
            switch arg {
            case let .string(s):
                out.appendOSCString(s)
            case let .int(i):
                var be = i.bigEndian
                withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
            case let .float(f):
                var be = f.bitPattern.bigEndian
                withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
            case let .blob(d):
                var size = UInt32(d.count).bigEndian
                withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
                out.append(d)
                let padding = (4 - (d.count % 4)) % 4
                if padding > 0 {
                    out.append(contentsOf: Array(repeating: UInt8(0), count: padding))
                }
            }
        }
        return out
    }
}

// MARK: - Decoding

extension OSCMessage {
    /// Decodes a single OSC packet (which may be a bundle containing multiple
    /// messages). Returns the flattened list of messages.
    static func decodePacket(_ data: Data) throws -> [OSCMessage] {
        let d = Data(data)
        if d.starts(with: Array("#bundle".utf8) + [0]) {
            return try decodeBundle(d)
        }
        return [try decodeMessage(d)]
    }

    static func decodeMessage(_ data: Data) throws -> OSCMessage {
        let normalized = Data(data)
        var cursor = 0
        let address = try normalized.readOSCString(at: &cursor)
        let tagString = try normalized.readOSCString(at: &cursor)
        guard tagString.hasPrefix(",") else {
            return OSCMessage(address: address, arguments: [])
        }
        var args: [OSCArgument] = []
        for tag in tagString.dropFirst() {
            switch tag {
            case "s":
                args.append(.string(try normalized.readOSCString(at: &cursor)))
            case "i":
                args.append(.int(try normalized.readInt32BE(at: &cursor)))
            case "f":
                args.append(.float(try normalized.readFloat32BE(at: &cursor)))
            case "b":
                args.append(.blob(try normalized.readOSCBlob(at: &cursor)))
            case "T":
                args.append(.int(1))
            case "F":
                args.append(.int(0))
            case "N":
                args.append(.int(0))
            case "I":
                args.append(.int(1))
            default:
                throw OSCDecodingError.invalidTypeTag(tag)
            }
        }
        return OSCMessage(address: address, arguments: args)
    }

    static func decodeBundle(_ data: Data) throws -> [OSCMessage] {
        // Normalize so subscript indexing is always 0-based.
        let normalized = Data(data)
        var cursor = 8 // skip "#bundle\0"
        // Skip the 8-byte time tag.
        cursor += 8
        var messages: [OSCMessage] = []
        while cursor < normalized.count {
            let size = Int(try normalized.readInt32BE(at: &cursor))
            guard cursor + size <= normalized.count else {
                throw OSCDecodingError.truncated
            }
            let elem = normalized.subdata(in: cursor..<(cursor + size))
            cursor += size
            if elem.starts(with: Array("#bundle".utf8) + [0]) {
                messages.append(contentsOf: try decodeBundle(elem))
            } else {
                messages.append(try decodeMessage(elem))
            }
        }
        return messages
    }
}

// MARK: - Address-pattern matching

extension OSCMessage {
    /// Returns true if `pattern` matches `address`. The pattern uses literal
    /// segments separated by `/`; a segment of `*` matches any single
    /// non-empty segment. No other glob syntax is supported.
    ///
    /// Example: `/sp/cue/*/stop` matches `/sp/cue/INTRO/stop` but not
    /// `/sp/cue/INTRO/scrub`.
    static func addressMatches(pattern: String, address: String) -> Bool {
        let pSegs = pattern.split(separator: "/", omittingEmptySubsequences: true)
        let aSegs = address.split(separator: "/", omittingEmptySubsequences: true)
        guard pSegs.count == aSegs.count else { return false }
        for (p, a) in zip(pSegs, aSegs) {
            if p == "*" { continue }
            if p.lowercased() != a.lowercased() { return false }
        }
        return true
    }
}

// MARK: - Data helpers

extension Data {
    /// Appends a NUL-terminated, 4-byte-aligned OSC string.
    mutating func appendOSCString(_ s: String) {
        append(contentsOf: s.utf8)
        append(0)
        let padding = (4 - (count % 4)) % 4
        if padding > 0 {
            append(contentsOf: Array(repeating: UInt8(0), count: padding))
        }
    }

    func readOSCString(at cursor: inout Int) throws -> String {
        guard cursor < count else { throw OSCDecodingError.truncated }
        let base = startIndex
        var end = cursor
        while end < count, self[base + end] != 0 {
            end += 1
        }
        guard end < count else { throw OSCDecodingError.notNULTerminated }
        let bytes = self.subdata(in: (base + cursor)..<(base + end))
        let s = String(data: bytes, encoding: .utf8) ?? ""
        // Move cursor past the NUL and align to 4-byte boundary.
        let consumed = end - cursor + 1
        let padded = ((consumed + 3) / 4) * 4
        cursor += padded
        return s
    }

    func readInt32BE(at cursor: inout Int) throws -> Int32 {
        guard cursor + 4 <= count else { throw OSCDecodingError.truncated }
        let s = startIndex
        let b0 = UInt32(self[s + cursor])
        let b1 = UInt32(self[s + cursor + 1])
        let b2 = UInt32(self[s + cursor + 2])
        let b3 = UInt32(self[s + cursor + 3])
        let raw: UInt32 = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        cursor += 4
        return Int32(bitPattern: raw)
    }

    func readFloat32BE(at cursor: inout Int) throws -> Float {
        guard cursor + 4 <= count else { throw OSCDecodingError.truncated }
        let s = startIndex
        let b0 = UInt32(self[s + cursor])
        let b1 = UInt32(self[s + cursor + 1])
        let b2 = UInt32(self[s + cursor + 2])
        let b3 = UInt32(self[s + cursor + 3])
        let raw: UInt32 = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        cursor += 4
        return Float(bitPattern: raw)
    }

    func readOSCBlob(at cursor: inout Int) throws -> Data {
        let size = Int(try readInt32BE(at: &cursor))
        guard size >= 0, cursor + size <= count else { throw OSCDecodingError.truncated }
        let base = startIndex
        let blob = self.subdata(in: (base + cursor)..<(base + cursor + size))
        let padding = (4 - (size % 4)) % 4
        cursor += size + padding
        return blob
    }
}
