import Foundation
import XCTest
@testable import Simple_Playback

final class MediaReferenceTests: XCTestCase {

    // MARK: - default values

    func testInitDefaultsKindToLinked() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        let ref = MediaReference(url: url)
        XCTAssertEqual(ref.kind, .linked)
        XCTAssertNil(ref.fingerprint)
    }

    func testInitAcceptsManagedKindAndFingerprint() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        let fingerprint = MediaAssetFingerprint(
            contentHash: "abc123",
            size: 4096,
            mtime: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let ref = MediaReference(url: url, fingerprint: fingerprint, kind: .managed)
        XCTAssertEqual(ref.kind, .managed)
        XCTAssertEqual(ref.fingerprint?.contentHash, "abc123")
        XCTAssertEqual(ref.fingerprint?.size, 4096)
    }

    // MARK: - round-trip

    func testRoundTripPreservesKindAndFingerprint() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        let fingerprint = MediaAssetFingerprint(
            contentHash: "deadbeef",
            size: 12_345,
            mtime: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let ref = MediaReference(url: url, fingerprint: fingerprint, kind: .managed)

        let data = try JSONEncoder.simplePlayback.encode(ref)
        let decoded = try JSONDecoder.simplePlayback.decode(MediaReference.self, from: data)

        XCTAssertEqual(decoded.kind, .managed)
        XCTAssertEqual(decoded.fingerprint?.contentHash, "deadbeef")
        XCTAssertEqual(decoded.fingerprint?.size, 12_345)
        XCTAssertEqual(decoded.fingerprint?.mtime.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.001)
        XCTAssertEqual(decoded.originalPath, url.path)
    }

    // MARK: - legacy decode

    func testLegacyDecodeWithoutKindOrFingerprintDefaultsToLinked() throws {
        // Pre-C7 projects encoded MediaReference with only originalPath + bookmarkData.
        // Loading those projects must continue to work; the new fields default in.
        let legacyJSON = """
        {
          "originalPath": "/Users/op/Movies/intro.mov"
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder.simplePlayback.decode(MediaReference.self, from: data)

        XCTAssertEqual(decoded.originalPath, "/Users/op/Movies/intro.mov")
        XCTAssertEqual(decoded.kind, .linked, "Legacy projects should default to linked.")
        XCTAssertNil(decoded.fingerprint, "Legacy projects should have no fingerprint until relinked.")
        XCTAssertNil(decoded.bookmarkData)
    }

    func testLegacyDecodeWithBookmarkDataPreservesIt() throws {
        let bookmarkBytes = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let legacyJSON = """
        {
          "originalPath": "/tmp/clip.mov",
          "bookmarkData": "\(bookmarkBytes.base64EncodedString())"
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder.simplePlayback.decode(MediaReference.self, from: data)

        XCTAssertEqual(decoded.bookmarkData, bookmarkBytes)
        XCTAssertEqual(decoded.kind, .linked)
        XCTAssertNil(decoded.fingerprint)
    }

    // MARK: - kind enum coverage

    func testMediaReferenceKindAllCasesCoversLinkedAndManaged() {
        XCTAssertEqual(Set(MediaReferenceKind.allCases), [.linked, .managed])
    }

    // MARK: - C8 folderBookmarkID + folderRelativePath

    func testInitDefaultsFolderBookmarkFieldsToNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        let ref = MediaReference(url: url)
        XCTAssertNil(ref.folderBookmarkID)
        XCTAssertNil(ref.folderRelativePath)
    }

    func testInitAcceptsFolderBookmarkFields() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        let folderID = UUID()
        let ref = MediaReference(
            url: url,
            folderBookmarkID: folderID,
            folderRelativePath: "subfolder/clip.mov"
        )
        XCTAssertEqual(ref.folderBookmarkID, folderID)
        XCTAssertEqual(ref.folderRelativePath, "subfolder/clip.mov")
    }

    func testRoundTripPreservesFolderBookmarkFields() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        let folderID = UUID()
        let ref = MediaReference(
            url: url,
            folderBookmarkID: folderID,
            folderRelativePath: "scene/clip-01.mov"
        )

        let data = try JSONEncoder.simplePlayback.encode(ref)
        let decoded = try JSONDecoder.simplePlayback.decode(MediaReference.self, from: data)

        XCTAssertEqual(decoded.folderBookmarkID, folderID)
        XCTAssertEqual(decoded.folderRelativePath, "scene/clip-01.mov")
    }

    func testResolvedURLConsultsFolderBookmarkRungWhenOriginalIsGone() throws {
        // Build a real folder + file, capture a FolderBookmark on the folder,
        // record a MediaReference whose originalPath points at the folder but
        // whose folderBookmarkID/folderRelativePath address a real file inside.
        // Move the real file out of folder + delete it to ensure original-path
        // resolution fails, then re-create the file at the same in-folder
        // location and confirm rung 2 (folder bookmark) recovers it.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResolvedURLFolderRung-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let actual = folder.appendingPathComponent("clip.mov")
        try Data([0x00, 0x01]).write(to: actual)

        let bookmark = FolderBookmark(folderURL: folder)
        var reference = MediaReference(url: URL(fileURLWithPath: "/Volumes/Gone/clip.mov"))
        reference.folderBookmarkID = bookmark.id
        reference.folderRelativePath = "clip.mov"

        let resolved = reference.resolvedURL(
            bundleMediaDirectory: nil,
            folderBookmarks: [bookmark.id: bookmark]
        )
        XCTAssertEqual(resolved?.standardizedFileURL, actual.standardizedFileURL)
    }

    func testResolvedURLReturnsNilWhenFolderBookmarkLookupIsEmpty() {
        // The reference carries folder fields but the host didn't supply the
        // bookmarks lookup (pre-C8 callsite, or the project lost its bookmark
        // list). Resolution falls through and returns nil.
        var reference = MediaReference(url: URL(fileURLWithPath: "/Volumes/Gone/clip.mov"))
        reference.folderBookmarkID = UUID()
        reference.folderRelativePath = "clip.mov"

        XCTAssertNil(reference.resolvedURL(bundleMediaDirectory: nil, folderBookmarks: [:]))
    }

    func testLegacyDecodeDefaultsFolderBookmarkFieldsToNil() throws {
        // Pre-C8 projects encoded MediaReference without folderBookmarkID +
        // folderRelativePath. Loading those projects must continue to work;
        // the new fields default to nil.
        let legacyJSON = """
        {
          "originalPath": "/Users/op/Movies/intro.mov",
          "kind": "linked"
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder.simplePlayback.decode(MediaReference.self, from: data)

        XCTAssertNil(decoded.folderBookmarkID)
        XCTAssertNil(decoded.folderRelativePath)
    }
}
