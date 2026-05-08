import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import Simple_Playback

/// C10 — pin that ThumbnailLoader.cachedThumbnail finds the poster JPEG the
/// importer wrote at `<dir>/<slide.id>.jpg`. The async loader (which prefers
/// the live source) is exercised in production; this test pins the offline
/// fallback path that's the whole point of the cache.
final class SlideGridViewThumbnailFallbackTests: XCTestCase {

    func testCachedThumbnailReturnsImageWhenSidecarExists() throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbFallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        // Use a slide whose source URL is missing — the live path will return
        // nil and the cache must take over.
        let slide = MediaSlide(
            url: URL(fileURLWithPath: "/tmp/never-exists-\(UUID().uuidString).png"),
            mediaKind: .image
        )
        let cacheURL = cacheDir.appendingPathComponent("\(slide.id.uuidString).jpg")

        let nsImage = solidImage(size: CGSize(width: 64, height: 36), red: 1, green: 0.5, blue: 0)
        let jpegData = try ThumbnailGenerator.encodeJPEG(
            image: nsImage,
            size: CGSize(width: 320, height: 180),
            quality: 0.85
        )
        try jpegData.write(to: cacheURL)

        let loaded = ThumbnailLoader.cachedThumbnail(for: slide, in: cacheDir)
        XCTAssertNotNil(loaded, "Cached JPEG at <dir>/<slide.id>.jpg must load.")
    }

    func testCachedThumbnailReturnsNilWhenSidecarMissing() {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbFallback-\(UUID().uuidString)", isDirectory: true)
        let slide = MediaSlide(url: URL(fileURLWithPath: "/tmp/x.png"), mediaKind: .image)
        XCTAssertNil(ThumbnailLoader.cachedThumbnail(for: slide, in: cacheDir),
                     "Missing cache dir + missing sidecar → nil, no crash.")
    }

    func testCachedThumbnailReturnsNilWhenDirectoryArgumentIsNil() {
        let slide = MediaSlide(url: URL(fileURLWithPath: "/tmp/x.png"), mediaKind: .image)
        XCTAssertNil(ThumbnailLoader.cachedThumbnail(for: slide, in: nil),
                     "No cache directory means no fallback — caller decides whether that's acceptable.")
    }

    func testAsyncLoaderFallsBackToCacheWhenSourceMissing() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbFallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let slide = MediaSlide(
            url: URL(fileURLWithPath: "/tmp/missing-\(UUID().uuidString).png"),
            mediaKind: .image
        )
        let cacheURL = cacheDir.appendingPathComponent("\(slide.id.uuidString).jpg")
        let jpegData = try ThumbnailGenerator.encodeJPEG(
            image: solidImage(size: CGSize(width: 32, height: 24), red: 0, green: 1, blue: 0),
            size: CGSize(width: 320, height: 180),
            quality: 0.85
        )
        try jpegData.write(to: cacheURL)

        let result = await ThumbnailLoader.thumbnail(
            for: slide,
            bundleMediaDirectory: nil,
            thumbnailCacheDirectory: cacheDir
        )
        XCTAssertNotNil(result,
                        "Live source missing + cache hit → loader returns the cached image.")
    }

    private func solidImage(size: CGSize, red: CGFloat, green: CGFloat, blue: CGFloat) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(red: red, green: green, blue: blue, alpha: 1).set()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }
}
