import Foundation
import XCTest
@testable import Simple_Playback

/// Pure-logic coverage for the C7c resolution waterfall. Every I/O dependency is
/// injected so these tests drive without touching the filesystem (where appropriate);
/// where realism matters we use temp files.
final class MediaResolverTests: XCTestCase {

    // MARK: - Rung 1 — original

    func testResolvesAtOriginalLocationWhenFileExists() {
        let url = URL(fileURLWithPath: "/Movies/intro.mov")
        let reference = MediaReference(url: url)

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [],
            fileExists: { $0.path == "/Movies/intro.mov" },
            listFiles: { _ in [] },
            fileSize: { _ in nil },
            fingerprintAt: { _ in nil }
        )

        XCTAssertEqual(result.step, .original)
        XCTAssertEqual(result.url?.path, "/Movies/intro.mov")
    }

    func testReturnsOfflineWhenOriginalMissingAndNoSearchRoots() {
        let reference = MediaReference(url: URL(fileURLWithPath: "/Movies/missing.mov"))

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [],
            fileExists: { _ in false },
            listFiles: { _ in [] },
            fileSize: { _ in nil },
            fingerprintAt: { _ in nil }
        )

        XCTAssertEqual(result, .offline)
    }

    // MARK: - Rung 2 — content hash

    func testResolvesViaContentHashWhenSizeAndHashMatch() {
        let original = URL(fileURLWithPath: "/Movies/missing.mov")
        let candidate = URL(fileURLWithPath: "/Backup/intro.mov")
        let reference = MediaReference(
            url: original,
            fingerprint: MediaAssetFingerprint(
                contentHash: "abc123",
                size: 4096,
                mtime: Date(timeIntervalSince1970: 1)
            )
        )
        let root = URL(fileURLWithPath: "/Backup")

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [root],
            fileExists: { _ in false },
            listFiles: { r in r == root ? [candidate] : [] },
            fileSize: { _ in 4096 },
            fingerprintAt: { _ in
                MediaAssetFingerprint(contentHash: "abc123", size: 4096, mtime: Date())
            }
        )

        XCTAssertEqual(result.step, .contentHash)
        XCTAssertEqual(result.url, candidate)
    }

    func testContentHashWinsOverNameAndSizeWhenBothPresent() {
        // The hash candidate has a different filename; the name+size candidate has the
        // matching name. Hash should win regardless of iteration order.
        let original = URL(fileURLWithPath: "/Movies/intro.mov")
        let hashCandidate = URL(fileURLWithPath: "/Backup/renamed-clip.mov")
        let nameSizeCandidate = URL(fileURLWithPath: "/Backup/intro.mov")
        let reference = MediaReference(
            url: original,
            fingerprint: MediaAssetFingerprint(
                contentHash: "match",
                size: 1000,
                mtime: Date(timeIntervalSince1970: 1)
            )
        )

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [URL(fileURLWithPath: "/Backup")],
            fileExists: { _ in false },
            listFiles: { _ in [nameSizeCandidate, hashCandidate] },
            fileSize: { _ in 1000 },
            fingerprintAt: { url in
                if url == hashCandidate {
                    return MediaAssetFingerprint(contentHash: "match", size: 1000, mtime: Date())
                }
                return MediaAssetFingerprint(contentHash: "different", size: 1000, mtime: Date())
            }
        )

        XCTAssertEqual(result.step, .contentHash)
        XCTAssertEqual(result.url, hashCandidate)
    }

    func testContentHashSkippedWhenNoFingerprintStored() {
        // Pre-C7 references (no fingerprint) cannot be hash-matched; should fall
        // through to name+size or offline.
        let reference = MediaReference(url: URL(fileURLWithPath: "/Movies/legacy.mov"))
        XCTAssertNil(reference.fingerprint)

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [URL(fileURLWithPath: "/Backup")],
            fileExists: { _ in false },
            listFiles: { _ in [URL(fileURLWithPath: "/Backup/legacy.mov")] },
            fileSize: { _ in 1234 },
            fingerprintAt: { _ in
                XCTFail("Hash step must be skipped when no fingerprint stored.")
                return nil
            }
        )

        XCTAssertEqual(result.step, .offline,
                       "Without a stored fingerprint, name+size also fails (no stored size).")
    }

    func testContentHashFiltersBySizeBeforeHashing() {
        // A candidate with the wrong size should never reach the fingerprintAt
        // closure — that's the cost-control invariant. We assert it via XCTFail in
        // the closure if it's invoked for the wrong-size candidate.
        let reference = MediaReference(
            url: URL(fileURLWithPath: "/Movies/clip.mov"),
            fingerprint: MediaAssetFingerprint(contentHash: "xx", size: 100, mtime: Date())
        )

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [URL(fileURLWithPath: "/Search")],
            fileExists: { _ in false },
            listFiles: { _ in [URL(fileURLWithPath: "/Search/wrongsize.mov")] },
            fileSize: { _ in 999 },
            fingerprintAt: { _ in
                XCTFail("Should not fingerprint wrong-size candidates.")
                return nil
            }
        )

        XCTAssertEqual(result.step, .offline)
    }

    // MARK: - Rung 3 — name + size

    func testResolvesViaNameAndSizeWhenHashMisses() {
        let original = URL(fileURLWithPath: "/Movies/intro.mov")
        let candidate = URL(fileURLWithPath: "/Backup/intro.mov")
        let reference = MediaReference(
            url: original,
            fingerprint: MediaAssetFingerprint(contentHash: "abc", size: 100, mtime: Date())
        )

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [URL(fileURLWithPath: "/Backup")],
            fileExists: { _ in false },
            listFiles: { _ in [candidate] },
            fileSize: { _ in 100 },
            fingerprintAt: { _ in
                MediaAssetFingerprint(contentHash: "different", size: 100, mtime: Date())
            }
        )

        XCTAssertEqual(result.step, .nameAndSize)
        XCTAssertEqual(result.url, candidate)
    }

    func testNameAndSizeRejectsDifferentSize() {
        let original = URL(fileURLWithPath: "/Movies/intro.mov")
        let reference = MediaReference(
            url: original,
            fingerprint: MediaAssetFingerprint(contentHash: "abc", size: 100, mtime: Date())
        )

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [URL(fileURLWithPath: "/Backup")],
            fileExists: { _ in false },
            listFiles: { _ in [URL(fileURLWithPath: "/Backup/intro.mov")] },
            fileSize: { _ in 50 },
            fingerprintAt: { _ in
                MediaAssetFingerprint(contentHash: "different", size: 50, mtime: Date())
            }
        )

        XCTAssertEqual(result.step, .offline,
                       "Same name but different size is not a name+size match.")
    }

    func testNameAndSizeRequiresStoredSize() {
        // Reference has no fingerprint → no stored size → name+size cannot match.
        let reference = MediaReference(url: URL(fileURLWithPath: "/Movies/legacy.mov"))

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [URL(fileURLWithPath: "/Backup")],
            fileExists: { _ in false },
            listFiles: { _ in [URL(fileURLWithPath: "/Backup/legacy.mov")] },
            fileSize: { _ in 1234 },
            fingerprintAt: { _ in nil }
        )

        XCTAssertEqual(result.step, .offline)
    }

    // MARK: - Search-root iteration

    func testFirstSearchRootWithHashHitWins() {
        let reference = MediaReference(
            url: URL(fileURLWithPath: "/Movies/clip.mov"),
            fingerprint: MediaAssetFingerprint(contentHash: "h", size: 1, mtime: Date())
        )
        let firstRoot = URL(fileURLWithPath: "/A")
        let secondRoot = URL(fileURLWithPath: "/B")
        let firstHit = URL(fileURLWithPath: "/A/clip.mov")
        let secondHit = URL(fileURLWithPath: "/B/clip.mov")

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [firstRoot, secondRoot],
            fileExists: { _ in false },
            listFiles: { root in root == firstRoot ? [firstHit] : [secondHit] },
            fileSize: { _ in 1 },
            fingerprintAt: { _ in MediaAssetFingerprint(contentHash: "h", size: 1, mtime: Date()) }
        )

        XCTAssertEqual(result.url, firstHit, "First search root with a hash match wins.")
    }

    func testSkipsOriginalLocationDuringSearch() {
        // If the operator's relink folder coincidentally contains the *original*
        // location (e.g. a wrapping folder), the resolver must not re-evaluate the
        // already-known-missing file as a candidate. Rung 1 handled it; rung 2/3
        // skip.
        let original = URL(fileURLWithPath: "/Movies/clip.mov")
        let reference = MediaReference(
            url: original,
            fingerprint: MediaAssetFingerprint(contentHash: "h", size: 1, mtime: Date())
        )

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [URL(fileURLWithPath: "/Movies")],
            fileExists: { _ in false },
            listFiles: { _ in [original] },
            fileSize: { _ in 1 },
            fingerprintAt: { _ in
                XCTFail("Original-location candidate should not be hashed in fallback rungs.")
                return nil
            }
        )

        XCTAssertEqual(result, .offline)
    }

    // MARK: - Rung 0 — bundle Media (managed assets)

    func testManagedReferenceResolvesViaBundleMediaDirectory() {
        // C7d managed asset that traveled to a new machine: absolute path is
        // wrong, but the file is at <bundle>/Media/<basename>. The resolver
        // must short-circuit to that location before the original-path check.
        let bundleMedia = URL(fileURLWithPath: "/NewMachine/MyShow.spb/Media")
        let originalPath = "/OldMachine/MyShow.spb/Media/intro.mov"
        let reference = MediaReference(
            url: URL(fileURLWithPath: originalPath),
            fingerprint: nil,
            kind: .managed
        )

        var seenURLs: [String] = []
        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [],
            bundleMediaDirectory: bundleMedia,
            fileExists: { url in
                seenURLs.append(url.path)
                return url.path == "/NewMachine/MyShow.spb/Media/intro.mov"
            },
            listFiles: { _ in [] },
            fileSize: { _ in nil },
            fingerprintAt: { _ in nil }
        )

        XCTAssertEqual(result.step, .bundleMedia)
        XCTAssertEqual(result.url?.path, "/NewMachine/MyShow.spb/Media/intro.mov")
    }

    func testManagedReferenceFallsThroughWhenBundleMediaMisses() {
        // If the bundle Media/ candidate doesn't exist, the resolver continues
        // to the original-path waterfall. Ensures we don't shortcut to offline
        // when the bundle is unexpectedly empty.
        let originalPath = "/Local/intro.mov"
        let reference = MediaReference(
            url: URL(fileURLWithPath: originalPath),
            fingerprint: nil,
            kind: .managed
        )

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [],
            bundleMediaDirectory: URL(fileURLWithPath: "/EmptyBundle/Media"),
            fileExists: { url in url.path == originalPath },
            listFiles: { _ in [] },
            fileSize: { _ in nil },
            fingerprintAt: { _ in nil }
        )

        XCTAssertEqual(result.step, .original)
        XCTAssertEqual(result.url?.path, originalPath)
    }

    func testLinkedReferenceIgnoresBundleMediaDirectory() {
        // Linked references should never short-circuit to the bundle Media/
        // location even if a file with the same basename lives there. Rung 0
        // is gated on `kind == .managed`.
        let reference = MediaReference(url: URL(fileURLWithPath: "/Footage/intro.mov"))

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [],
            bundleMediaDirectory: URL(fileURLWithPath: "/Bundle/Media"),
            fileExists: { url in url.path == "/Footage/intro.mov" },
            listFiles: { _ in [] },
            fileSize: { _ in nil },
            fingerprintAt: { _ in nil }
        )

        XCTAssertEqual(result.step, .original,
                       "Linked references must never use rung 0.")
    }

    func testManagedReferenceWithoutBundleMediaDirectoryUsesOriginalPath() {
        // Calling code that doesn't know the bundle URL (e.g. an untitled
        // document) passes `bundleMediaDirectory: nil`. Managed references
        // should still resolve via the standard waterfall in that case.
        let reference = MediaReference(
            url: URL(fileURLWithPath: "/Local/intro.mov"),
            fingerprint: nil,
            kind: .managed
        )

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [],
            bundleMediaDirectory: nil,
            fileExists: { url in url.path == "/Local/intro.mov" },
            listFiles: { _ in [] },
            fileSize: { _ in nil },
            fingerprintAt: { _ in nil }
        )

        XCTAssertEqual(result.step, .original)
    }

    // MARK: - Live integration (real file)

    func testResolvesAtOriginalLocationOnRealFilesystem() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaResolverTests-\(UUID().uuidString).bin")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reference = MediaReference(url: url)
        let result = MediaResolver.resolve(reference: reference, searchRoots: [])

        XCTAssertEqual(result.step, .original)
        XCTAssertEqual(result.url?.standardizedFileURL, url.standardizedFileURL)
    }
}
