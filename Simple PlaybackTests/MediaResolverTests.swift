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

    func testSkipsSearchRootWalkWhenReferenceHasNoFingerprint() {
        // Legacy (pre-C7) slides have no fingerprint, so both rung 2 (content hash)
        // and rung 3 (name + size) can never match — both require stored values.
        // Walking every file in every search root would be O(roots × files) wasted
        // syscalls per legacy slide; short-circuit straight to offline. Pin via
        // an XCTFail in the listFiles closure so a regression that re-introduces
        // the walk fails loudly.
        let reference = MediaReference(url: URL(fileURLWithPath: "/Movies/legacy.mov"))
        XCTAssertNil(reference.fingerprint)

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [URL(fileURLWithPath: "/A"), URL(fileURLWithPath: "/B")],
            fileExists: { _ in false },
            listFiles: { _ in
                XCTFail("Search roots must not be enumerated when reference has no fingerprint.")
                return []
            },
            fileSize: { _ in nil },
            fingerprintAt: { _ in nil }
        )

        XCTAssertEqual(result, .offline)
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

    // MARK: - MediaReference.resolvedURL(bundleMediaDirectory:)

    func testManagedReferenceResolvedURLPrefersBundleMediaWhenFileExists() throws {
        // Real filesystem so we exercise the FileManager.fileExists check.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleAware-\(UUID().uuidString)", isDirectory: true)
        let mediaDir = tmp.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        let fileURL = mediaDir.appendingPathComponent("intro.mov")
        try Data("x".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var ref = MediaReference(url: URL(fileURLWithPath: "/Old/Bundle/Media/intro.mov"))
        ref.kind = .managed
        ref.bookmarkData = nil

        XCTAssertEqual(
            ref.resolvedURL(bundleMediaDirectory: mediaDir)?.standardizedFileURL,
            fileURL.standardizedFileURL
        )
    }

    func testLinkedReferenceResolvedURLIgnoresBundleMediaDirectory() throws {
        // Put a file at <mediaDir>/intro.mov, but the linked reference's
        // original path is "/nowhere/intro.mov" with no bookmark. If the
        // bundle-Media short-circuit erroneously fired for linked references
        // it would return the bundle file; correct behavior is nil because
        // the linked file genuinely doesn't exist.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleAware-\(UUID().uuidString)", isDirectory: true)
        let mediaDir = tmp.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        let bundleFile = mediaDir.appendingPathComponent("intro.mov")
        try Data("inside-bundle".utf8).write(to: bundleFile)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var ref = MediaReference(url: URL(fileURLWithPath: "/nowhere/intro.mov"))
        ref.kind = .linked
        ref.bookmarkData = nil

        XCTAssertNil(
            ref.resolvedURL(bundleMediaDirectory: mediaDir),
            "Linked reference must not silently substitute a same-name file from the bundle Media/ directory."
        )
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

    // MARK: - C8 folder bookmark rung

    func testResolvesViaFolderBookmarkWhenOriginalIsGoneAndFolderHit() {
        // Original path is gone but the folder bookmark resolves to a directory
        // that contains the file at the recorded relative path. Should land on
        // `.folderBookmark` without walking any search root.
        let folderID = UUID()
        let folderBookmark = FolderBookmark(
            label: "Show Footage",
            originalPath: "/Volumes/Show/Footage",
            bookmarkData: nil
        )
        let reference = MediaReference(
            url: URL(fileURLWithPath: "/OriginalGone/intro.mov"),
            folderBookmarkID: folderID,
            folderRelativePath: "scene-01/intro.mov"
        )

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [],
            folderBookmarks: [folderID: folderBookmark],
            fileExists: { url in
                url.path == "/Volumes/Show/Footage" ||
                url.path == "/Volumes/Show/Footage/scene-01/intro.mov"
            },
            listFiles: { _ in
                XCTFail("Folder-bookmark rung must not walk any search root.")
                return []
            },
            fileSize: { _ in nil },
            fingerprintAt: { _ in nil }
        )

        XCTAssertEqual(result.step, .folderBookmark)
        XCTAssertEqual(result.url?.path, "/Volumes/Show/Footage/scene-01/intro.mov")
    }

    func testFolderBookmarkRungSkippedWhenIDMissingFromLookup() {
        // Reference carries folderBookmarkID + folderRelativePath but the host
        // didn't supply that bookmark in the lookup (e.g. a project that hasn't
        // run the folderBookmarks migration). Resolver must fall through, not
        // error, and must not consult the rung.
        let folderID = UUID()
        let reference = MediaReference(
            url: URL(fileURLWithPath: "/OriginalGone/intro.mov"),
            folderBookmarkID: folderID,
            folderRelativePath: "intro.mov"
        )

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [],
            folderBookmarks: [:],
            fileExists: { _ in false },
            listFiles: { _ in [] },
            fileSize: { _ in nil },
            fingerprintAt: { _ in nil }
        )

        XCTAssertEqual(result, .offline)
    }

    func testFolderBookmarkRungSkippedWhenRelativePathIsEmpty() {
        // Empty relative path means the importer never recorded an in-folder
        // location — the rung is a no-op. Don't return the directory itself.
        let folderID = UUID()
        let folderBookmark = FolderBookmark(
            label: "Show",
            originalPath: "/Volumes/Show/Footage",
            bookmarkData: nil
        )
        let reference = MediaReference(
            url: URL(fileURLWithPath: "/OriginalGone/intro.mov"),
            folderBookmarkID: folderID,
            folderRelativePath: ""
        )

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [],
            folderBookmarks: [folderID: folderBookmark],
            fileExists: { url in url.path == "/Volumes/Show/Footage" },
            listFiles: { _ in [] },
            fileSize: { _ in nil },
            fingerprintAt: { _ in nil }
        )

        XCTAssertEqual(result, .offline)
    }

    func testFolderBookmarkRungSkippedWhenFolderResolutionFails() {
        // Folder bookmark resolves to nil (directory doesn't exist anymore).
        // Resolver must continue to the search-root walk rather than treating
        // the rung as a hit.
        let folderID = UUID()
        let folderBookmark = FolderBookmark(
            label: "Gone",
            originalPath: "/Volumes/MissingFolder",
            bookmarkData: nil
        )
        let reference = MediaReference(
            url: URL(fileURLWithPath: "/OriginalGone/intro.mov"),
            folderBookmarkID: folderID,
            folderRelativePath: "intro.mov"
        )

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [],
            folderBookmarks: [folderID: folderBookmark],
            fileExists: { _ in false },
            listFiles: { _ in [] },
            fileSize: { _ in nil },
            fingerprintAt: { _ in nil }
        )

        XCTAssertEqual(result, .offline)
    }

    func testOriginalRungWinsWhenBothOriginalAndFolderBookmarkResolve() {
        // When the per-file path still exists, the rung-1 hit must win over
        // rung-2 — original location is the cheapest authoritative answer and
        // we don't want a folder-bookmark mismatch to silently shadow it.
        let folderID = UUID()
        let folderBookmark = FolderBookmark(
            label: "Show",
            originalPath: "/Volumes/Show/Footage",
            bookmarkData: nil
        )
        let reference = MediaReference(
            url: URL(fileURLWithPath: "/Movies/intro.mov"),
            folderBookmarkID: folderID,
            folderRelativePath: "intro.mov"
        )

        let result = MediaResolver.resolve(
            reference: reference,
            searchRoots: [],
            folderBookmarks: [folderID: folderBookmark],
            fileExists: { url in
                url.path == "/Movies/intro.mov" ||
                url.path == "/Volumes/Show/Footage" ||
                url.path == "/Volumes/Show/Footage/intro.mov"
            },
            listFiles: { _ in [] },
            fileSize: { _ in nil },
            fingerprintAt: { _ in nil }
        )

        XCTAssertEqual(result.step, .original)
        XCTAssertEqual(result.url?.path, "/Movies/intro.mov")
    }

    func testResolvedURLReturnsNilWhenBookmarkResolvesToDeletedFile() throws {
        // A security-scoped bookmark created over a real file resolves to a URL
        // even after that file is deleted (with `stale = true`). Pre-fix, the
        // bookmark branch returned that URL unconditionally — and downstream
        // consumers (TranscodeService.canTranscode, AssetLibraryProbe) treated
        // a non-nil resolvedURL as "online." Gate on fileExists so a deleted
        // file is reported as offline at this layer.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaResolverTests-\(UUID().uuidString).bin")
        try Data("hello".utf8).write(to: url)
        let reference = MediaReference(url: url)
        XCTAssertNotNil(reference.bookmarkData,
                        "Bookmark must be set up so the test exercises the bookmark branch.")
        try FileManager.default.removeItem(at: url)

        XCTAssertNil(reference.resolvedURL(),
                     "Bookmark resolving to a now-deleted file must return nil, not a URL pointing nowhere.")
    }
}
