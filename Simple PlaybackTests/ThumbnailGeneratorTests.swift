import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import Simple_Playback

final class ThumbnailGeneratorTests: XCTestCase {

    func testEncodeJPEGFromCGImageProducesNonEmptyJPEGMagicBytes() throws {
        let nsImage = solidImage(size: CGSize(width: 64, height: 36), red: 1, green: 0, blue: 0)
        let data = try ThumbnailGenerator.encodeJPEG(
            image: nsImage,
            size: CGSize(width: 320, height: 180),
            quality: 0.75
        )
        XCTAssertGreaterThan(data.count, 100, "Encoded JPEG should be non-trivial.")
        // JPEG magic prefix.
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1], 0xD8)
        XCTAssertEqual(data[2], 0xFF)
    }

    func testGenerateJPEGFromImageURLProducesData() throws {
        // Write a small PNG, then read it back through the generator.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-source-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let nsImage = solidImage(size: CGSize(width: 100, height: 80), red: 0, green: 1, blue: 0)
        let bitmap = NSBitmapImageRep(cgImage: nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let pngData = bitmap.representation(using: .png, properties: [:])!
        try pngData.write(to: url)

        let data = try ThumbnailGenerator.generateJPEG(for: url, mediaKind: .image)
        XCTAssertGreaterThan(data.count, 100)
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1], 0xD8)
    }

    func testGenerateJPEGForUnreadableSourceThrowsSourceNotReadable() {
        let missing = URL(fileURLWithPath: "/tmp/nope-\(UUID().uuidString).png")
        XCTAssertThrowsError(try ThumbnailGenerator.generateJPEG(for: missing, mediaKind: .image)) { error in
            XCTAssertEqual(error as? ThumbnailGeneratorError, .sourceNotReadable)
        }
    }

    func testEncodeJPEGRespectsQualityArgumentByProducingDifferentSizedOutputs() throws {
        // High-quality and low-quality encodes of the same image should differ
        // in byte size. Acts as a smoke test that the `compressionFactor`
        // property reaches the encoder.
        let image = solidImage(size: CGSize(width: 320, height: 180), red: 0.4, green: 0.6, blue: 0.8)
        let highQuality = try ThumbnailGenerator.encodeJPEG(
            image: image,
            size: CGSize(width: 320, height: 180),
            quality: 0.95
        )
        let lowQuality = try ThumbnailGenerator.encodeJPEG(
            image: image,
            size: CGSize(width: 320, height: 180),
            quality: 0.2
        )
        XCTAssertGreaterThan(highQuality.count, lowQuality.count,
                             "Higher quality must produce a larger JPEG (sanity-check that `quality` propagates).")
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
