import CryptoKit
import Foundation

/// Read-side fingerprint of a media file at a moment in time. Pinned at import (and
/// recomputed on relink) so the asset library can detect when a linked file has been
/// replaced, moved, or modified, and so the relink waterfall (C9) can find moved files
/// by content hash.
///
/// `contentHash` is hex-encoded SHA-256 over the full file body. `size` and `mtime` are
/// the filesystem-reported values at fingerprint time. All three are needed: hashing is
/// authoritative but expensive, so the size/mtime pair is the cheap pre-check that
/// short-circuits the hash on a hot path ("did this file change since import?").
struct MediaAssetFingerprint: Codable, Hashable {
    /// Hex-encoded SHA-256 of the file's bytes at fingerprint time. Lowercase, no spaces.
    var contentHash: String
    /// File size in bytes at fingerprint time.
    var size: Int64
    /// File modification date at fingerprint time.
    var mtime: Date
}

enum AssetFingerprintError: LocalizedError, Equatable {
    case unreadable(URL)
    case missingAttributes(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            "Could not read \(url.lastPathComponent) for fingerprinting."
        case .missingAttributes(let url):
            "Could not read filesystem attributes for \(url.lastPathComponent)."
        }
    }
}

enum AssetFingerprinter {
    /// 1 MiB streaming window. Sized so multi-GB ProRes files don't load into RAM.
    static let defaultChunkSize = 1 << 20

    /// Computes SHA-256 + size + mtime for the file at `url`. Streams in `chunkSize`
    /// chunks; never holds more than one chunk at a time. Throws on read or attribute
    /// failure — callers in C7b (importer) downgrade those to a non-blocking nil
    /// fingerprint rather than failing the whole import.
    static func fingerprint(url: URL, chunkSize: Int = defaultChunkSize) throws -> MediaAssetFingerprint {
        let bufferLength = max(1, chunkSize)
        guard let stream = InputStream(url: url) else {
            throw AssetFingerprintError.unreadable(url)
        }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: bufferLength)
        while stream.hasBytesAvailable {
            let read = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return stream.read(base, maxLength: ptr.count)
            }
            if read < 0 {
                throw AssetFingerprintError.unreadable(url)
            }
            if read == 0 { break }
            buffer.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress {
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(start: base, count: read))
                }
            }
        }

        let hex = hexString(hasher.finalize())

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw AssetFingerprintError.missingAttributes(url)
        }
        guard let sizeNumber = attributes[.size] as? NSNumber else {
            throw AssetFingerprintError.missingAttributes(url)
        }
        let mtime = (attributes[.modificationDate] as? Date) ?? Date()

        return MediaAssetFingerprint(
            contentHash: hex,
            size: sizeNumber.int64Value,
            mtime: mtime
        )
    }

    /// Hex-SHA-256 of arbitrary bytes. Exposed for unit tests so they don't have to
    /// stand up a temp file to verify the hash function.
    static func sha256Hex(_ data: Data) -> String {
        hexString(SHA256.hash(data: data))
    }

    private static func hexString<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { byte in String(format: "%02x", byte) }.joined()
    }
}
