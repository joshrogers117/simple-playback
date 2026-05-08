import Foundation
import XCTest
@testable import Simple_Playback

final class AssetFingerprinterTests: XCTestCase {

    // MARK: - sha256Hex

    func testSHA256HexOfEmptyData() {
        // Spec'd value (RFC 6234 / NIST FIPS 180-4) — pinning so we know the hex
        // encoding is correct end-to-end (lowercase, no spaces).
        XCTAssertEqual(
            AssetFingerprinter.sha256Hex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testSHA256HexOfKnownStringMatchesSpec() {
        // SHA-256("abc") — pinned canonical value from FIPS 180-4 §5.
        let data = Data("abc".utf8)
        XCTAssertEqual(
            AssetFingerprinter.sha256Hex(data),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testSHA256HexIsLowercaseHex() {
        let hex = AssetFingerprinter.sha256Hex(Data([0xFF, 0x00, 0xAB]))
        XCTAssertEqual(hex.count, 64, "SHA-256 hex string should be 64 characters.")
        XCTAssertEqual(hex, hex.lowercased(), "Hex should be lowercase to match canonical formatting.")
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit }, "All characters should be hex digits.")
    }

    // MARK: - fingerprint(url:)

    func testFingerprintMatchesDirectHashForSmallFile() throws {
        let payload = Data("the quick brown fox jumps over the lazy dog".utf8)
        let url = try writeTempFile(contents: payload)
        defer { try? FileManager.default.removeItem(at: url) }

        let fingerprint = try AssetFingerprinter.fingerprint(url: url)

        XCTAssertEqual(fingerprint.contentHash, AssetFingerprinter.sha256Hex(payload))
        XCTAssertEqual(fingerprint.size, Int64(payload.count))
        XCTAssertGreaterThan(fingerprint.mtime.timeIntervalSince1970, 0)
    }

    func testFingerprintMatchesDirectHashForEmptyFile() throws {
        let url = try writeTempFile(contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }

        let fingerprint = try AssetFingerprinter.fingerprint(url: url)

        XCTAssertEqual(
            fingerprint.contentHash,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(fingerprint.size, 0)
    }

    func testFingerprintIsDeterministicAcrossCalls() throws {
        let payload = randomBytes(count: 8192)
        let url = try writeTempFile(contents: payload)
        defer { try? FileManager.default.removeItem(at: url) }

        let a = try AssetFingerprinter.fingerprint(url: url)
        let b = try AssetFingerprinter.fingerprint(url: url)

        XCTAssertEqual(a.contentHash, b.contentHash)
        XCTAssertEqual(a.size, b.size)
        XCTAssertEqual(a.mtime, b.mtime)
    }

    func testFingerprintStreamsMultipleChunks() throws {
        // Force a multi-chunk read to exercise the streaming path. 5 KiB of payload at
        // a 1 KiB chunk means ≥5 read iterations; the resulting hash must still match
        // the direct-data hash.
        let payload = randomBytes(count: 5 * 1024)
        let url = try writeTempFile(contents: payload)
        defer { try? FileManager.default.removeItem(at: url) }

        let fingerprint = try AssetFingerprinter.fingerprint(url: url, chunkSize: 1024)

        XCTAssertEqual(fingerprint.contentHash, AssetFingerprinter.sha256Hex(payload))
        XCTAssertEqual(fingerprint.size, Int64(payload.count))
    }

    func testFingerprintHashChangesWhenContentChanges() throws {
        let url = try writeTempFile(contents: Data("v1".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        let firstHash = try AssetFingerprinter.fingerprint(url: url).contentHash

        try Data("v2 — different bytes".utf8).write(to: url)

        let secondHash = try AssetFingerprinter.fingerprint(url: url).contentHash

        XCTAssertNotEqual(firstHash, secondHash, "Different bytes should hash differently.")
    }

    func testFingerprintThrowsOnMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).bin")

        XCTAssertThrowsError(try AssetFingerprinter.fingerprint(url: missing)) { error in
            guard let fingerprintError = error as? AssetFingerprintError else {
                XCTFail("Expected AssetFingerprintError, got \(error)")
                return
            }
            // Either branch is acceptable — InputStream(url:) returns nil for a missing
            // file on most platforms; some report it as an attribute lookup failure.
            switch fingerprintError {
            case .unreadable, .missingAttributes:
                break
            }
        }
    }

    // MARK: - helpers

    private func writeTempFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fp-\(UUID().uuidString).bin")
        try contents.write(to: url)
        return url
    }

    private func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return Data(bytes)
    }
}
