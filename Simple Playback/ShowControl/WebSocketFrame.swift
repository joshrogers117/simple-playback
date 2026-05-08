import Foundation

/// Minimal RFC 6455 WebSocket frame encode/decode. Server-side: we never mask
/// outbound; we expect clients to mask inbound (we tolerate both for tests).
struct WebSocketFrame {
    let fin: Bool
    let opcode: UInt8
    let payload: Data

    /// Encodes a single frame with FIN=1, no mask.
    static func encode(opcode: UInt8, payload: Data) -> Data {
        var out = Data()
        out.append(0x80 | (opcode & 0x0F)) // FIN + opcode
        let len = payload.count
        if len < 126 {
            out.append(UInt8(len))
        } else if len <= 0xFFFF {
            out.append(126)
            var be = UInt16(len).bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        } else {
            out.append(127)
            var be = UInt64(len).bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        }
        out.append(payload)
        return out
    }

    /// Decodes one or more frames from a buffer. Partial frames at the tail
    /// are ignored; for our uses (control frames and short text frames),
    /// this is sufficient.
    static func decode(_ data: Data) -> [WebSocketFrame] {
        let bytes = Data(data)
        var cursor = 0
        var frames: [WebSocketFrame] = []
        while cursor < bytes.count {
            guard cursor + 2 <= bytes.count else { break }
            let b0 = bytes[bytes.startIndex + cursor]
            let b1 = bytes[bytes.startIndex + cursor + 1]
            let fin = (b0 & 0x80) != 0
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            var len: Int = Int(b1 & 0x7F)
            cursor += 2
            if len == 126 {
                guard cursor + 2 <= bytes.count else { break }
                len = (Int(bytes[bytes.startIndex + cursor]) << 8) | Int(bytes[bytes.startIndex + cursor + 1])
                cursor += 2
            } else if len == 127 {
                guard cursor + 8 <= bytes.count else { break }
                var v: UInt64 = 0
                for i in 0..<8 {
                    v = (v << 8) | UInt64(bytes[bytes.startIndex + cursor + i])
                }
                cursor += 8
                if v > UInt64(Int.max) { break }
                len = Int(v)
            }
            var maskKey: [UInt8] = []
            if masked {
                guard cursor + 4 <= bytes.count else { break }
                maskKey = (0..<4).map { bytes[bytes.startIndex + cursor + $0] }
                cursor += 4
            }
            guard cursor + len <= bytes.count else { break }
            var payload = bytes.subdata(in: (bytes.startIndex + cursor)..<(bytes.startIndex + cursor + len))
            if masked {
                for i in 0..<payload.count {
                    payload[payload.startIndex + i] ^= maskKey[i % 4]
                }
            }
            cursor += len
            frames.append(WebSocketFrame(fin: fin, opcode: opcode, payload: payload))
        }
        return frames
    }
}
