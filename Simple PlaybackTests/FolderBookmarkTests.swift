import Foundation
import XCTest
@testable import Simple_Playback

/// C8 — pure-logic tests for the FolderBookmark value type. Resolution against
/// real security-scoped bookmarks needs an entitled host process and is exercised
/// indirectly through the resolver tests; here we just pin the value-type
/// construction, encoding round-trip, and `resolvedDirectory` fallback rules.
final class FolderBookmarkTests: XCTestCase {

    func testInitFromFolderURLDefaultsLabelToLastPathComponent() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Footage_\(UUID().uuidString)", isDirectory: true)
        let bookmark = FolderBookmark(folderURL: folder)

        XCTAssertTrue(bookmark.label.hasPrefix("Footage_"))
        XCTAssertEqual(bookmark.originalPath, folder.path)
    }

    func testInitFromFolderURLAcceptsExplicitLabel() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)", isDirectory: true)
        let bookmark = FolderBookmark(folderURL: folder, label: "Show Footage")

        XCTAssertEqual(bookmark.label, "Show Footage")
    }

    func testIdentifiableIDsAreUniquePerInstance() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)", isDirectory: true)
        let one = FolderBookmark(folderURL: folder)
        let two = FolderBookmark(folderURL: folder)
        XCTAssertNotEqual(one.id, two.id, "Each captured bookmark should have its own id even when the source folder is the same.")
    }

    func testEncodingRoundTripPreservesAllFields() throws {
        let bookmark = FolderBookmark(
            id: UUID(),
            label: "Show Footage",
            originalPath: "/Volumes/Show/Footage",
            bookmarkData: Data([0xCA, 0xFE, 0xBA, 0xBE])
        )

        let encoded = try JSONEncoder.simplePlayback.encode(bookmark)
        let decoded = try JSONDecoder.simplePlayback.decode(FolderBookmark.self, from: encoded)

        XCTAssertEqual(decoded.id, bookmark.id)
        XCTAssertEqual(decoded.label, "Show Footage")
        XCTAssertEqual(decoded.originalPath, "/Volumes/Show/Footage")
        XCTAssertEqual(decoded.bookmarkData, Data([0xCA, 0xFE, 0xBA, 0xBE]))
    }

    func testResolvedDirectoryReturnsOriginalPathWhenBookmarkIsNilAndFolderExists() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderBookmarkResolveTest_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let bookmark = FolderBookmark(
            label: folder.lastPathComponent,
            originalPath: folder.path,
            bookmarkData: nil
        )

        let resolved = bookmark.resolvedDirectory()
        XCTAssertEqual(resolved?.path, folder.path)
    }

    func testResolvedDirectoryReturnsNilWhenOriginalPathDoesNotExist() {
        let bookmark = FolderBookmark(
            label: "Gone",
            originalPath: "/Volumes/NonExistent_\(UUID().uuidString)",
            bookmarkData: nil
        )

        XCTAssertNil(bookmark.resolvedDirectory())
    }

    func testResolvedDirectoryRespectsInjectedFileExistsClosure() {
        // Drive the predicate without touching the filesystem so the test is
        // hermetic. The bookmarkData is nil so resolution falls through to the
        // originalPath + injected fileExists.
        let bookmark = FolderBookmark(
            label: "Mocked",
            originalPath: "/Volumes/Show/Mocked",
            bookmarkData: nil
        )

        let resolved = bookmark.resolvedDirectory(fileExists: { url in
            url.path == "/Volumes/Show/Mocked"
        })
        XCTAssertEqual(resolved?.path, "/Volumes/Show/Mocked")
    }
}
