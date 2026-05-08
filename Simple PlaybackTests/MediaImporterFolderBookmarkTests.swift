import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import Simple_Playback

/// C8 — pins the importer-side folder-bookmark stamping. When the host opts
/// into folder-mode (Add Folder / folder-drop with a single common parent)
/// every direct image/video MediaReference picks up the FolderBookmark id
/// and a path relative to the folder root. Default-nil context is the legacy
/// path and slides come through with no folder-bookmark fields set.
final class MediaImporterFolderBookmarkTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        MediaImporter.thumbnailEncoder = { url, kind in
            try? ThumbnailGenerator.generateJPEG(for: url, mediaKind: kind)
        }
        MediaImporter.fingerprinter = { url in
            try? AssetFingerprinter.fingerprint(url: url)
        }
    }

    // MARK: - importer stamping

    func testImportStampsFolderBookmarkFieldsOnDirectImageImport() throws {
        let folder = try makeUniqueDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let still = try makeStillPNG(at: folder.appendingPathComponent("intro.png"))
        let folderBookmark = FolderBookmark(
            label: folder.lastPathComponent,
            originalPath: folder.path,
            bookmarkData: nil
        )

        MediaImporter.thumbnailEncoder = { _, _ in nil }

        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: FileManager.default.temporaryDirectory,
            folderBookmark: folderBookmark,
            folderRoot: folder
        )

        let slides = MediaImporter.importSlides(from: [still], context: context)
        XCTAssertEqual(slides.count, 1)
        XCTAssertEqual(slides.first?.media.folderBookmarkID, folderBookmark.id)
        XCTAssertEqual(slides.first?.media.folderRelativePath, "intro.png")
    }

    func testImportStampsRelativePathForNestedSubfolderURL() throws {
        let folder = try makeUniqueDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scene = folder.appendingPathComponent("scene-01", isDirectory: true)
        try FileManager.default.createDirectory(at: scene, withIntermediateDirectories: true)
        let still = try makeStillPNG(at: scene.appendingPathComponent("clip.png"))

        let folderBookmark = FolderBookmark(
            label: folder.lastPathComponent,
            originalPath: folder.path,
            bookmarkData: nil
        )
        MediaImporter.thumbnailEncoder = { _, _ in nil }

        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: FileManager.default.temporaryDirectory,
            folderBookmark: folderBookmark,
            folderRoot: folder
        )

        let slides = MediaImporter.importSlides(from: [still], context: context)
        XCTAssertEqual(slides.first?.media.folderBookmarkID, folderBookmark.id)
        XCTAssertEqual(slides.first?.media.folderRelativePath, "scene-01/clip.png")
    }

    func testImportSkipsStampingWhenContextOmitsFolderBookmark() throws {
        let folder = try makeUniqueDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let still = try makeStillPNG(at: folder.appendingPathComponent("intro.png"))
        MediaImporter.thumbnailEncoder = { _, _ in nil }

        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: FileManager.default.temporaryDirectory
        )

        let slides = MediaImporter.importSlides(from: [still], context: context)
        XCTAssertNil(slides.first?.media.folderBookmarkID,
                     "Default context (no folder mode) must not set folderBookmarkID.")
        XCTAssertNil(slides.first?.media.folderRelativePath)
    }

    func testImportSkipsStampingWhenSourceURLIsNotUnderFolderRoot() throws {
        // The host opted into folder-mode but somehow passed a URL outside
        // folderRoot. The importer should NOT stamp a relative path that
        // would silently include `..` — better to leave it unstamped and
        // fall back to the per-file bookmark.
        let folder = try makeUniqueDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let outsideFolder = try makeUniqueDirectory()
        defer { try? FileManager.default.removeItem(at: outsideFolder) }
        let still = try makeStillPNG(at: outsideFolder.appendingPathComponent("rogue.png"))
        let folderBookmark = FolderBookmark(
            label: folder.lastPathComponent,
            originalPath: folder.path,
            bookmarkData: nil
        )
        MediaImporter.thumbnailEncoder = { _, _ in nil }

        let context = MediaImportContext(
            rasterSize: CGSize(width: 1920, height: 1080),
            renderRootDirectory: FileManager.default.temporaryDirectory,
            folderBookmark: folderBookmark,
            folderRoot: folder
        )

        let slides = MediaImporter.importSlides(from: [still], context: context)
        XCTAssertNil(slides.first?.media.folderBookmarkID,
                     "URLs outside folderRoot must not inherit the folder bookmark.")
        XCTAssertNil(slides.first?.media.folderRelativePath)
    }

    // MARK: - folderRelativePath helper

    func testFolderRelativePathReturnsNilWhenRootIsNil() {
        let url = URL(fileURLWithPath: "/Volumes/Show/intro.mov")
        XCTAssertNil(MediaImporter.folderRelativePath(of: url, under: nil))
    }

    func testFolderRelativePathReturnsRelativeWhenFileIsDescendant() {
        let root = URL(fileURLWithPath: "/Volumes/Show")
        let file = URL(fileURLWithPath: "/Volumes/Show/scene/clip.mov")
        XCTAssertEqual(
            MediaImporter.folderRelativePath(of: file, under: root),
            "scene/clip.mov"
        )
    }

    func testFolderRelativePathReturnsNilWhenFileIsOutsideRoot() {
        let root = URL(fileURLWithPath: "/Volumes/Show")
        let file = URL(fileURLWithPath: "/Volumes/Other/clip.mov")
        XCTAssertNil(MediaImporter.folderRelativePath(of: file, under: root))
    }

    func testFolderRelativePathRejectsRootEqualToFile() {
        // The root URL cannot also be the file URL. We require a strict
        // descendant relationship; the caller treats nil as "do not stamp."
        let same = URL(fileURLWithPath: "/Volumes/Show/clip.mov")
        XCTAssertNil(MediaImporter.folderRelativePath(of: same, under: same))
    }

    func testFolderRelativePathRejectsSiblingDirectoryWithSharedPrefix() {
        // /Volumes/ShowFootage is NOT under /Volumes/Show, even though the
        // string prefix matches. Path-component comparison guards against
        // this collision (mirrors the AssetRelinkPlan kind-inference fix).
        let root = URL(fileURLWithPath: "/Volumes/Show")
        let file = URL(fileURLWithPath: "/Volumes/ShowFootage/clip.mov")
        XCTAssertNil(MediaImporter.folderRelativePath(of: file, under: root))
    }

    // MARK: - Fixtures

    private func makeUniqueDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaImporterFolderBookmarkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStillPNG(at url: URL) throws -> URL {
        let width = 32
        let height = 32
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(CGColor(srgbRed: 0.4, green: 0.7, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else {
            throw CocoaError(.fileWriteUnknown)
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
