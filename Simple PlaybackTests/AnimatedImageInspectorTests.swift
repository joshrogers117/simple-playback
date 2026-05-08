import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Simple_Playback

/// Synthesized fixtures cover the spec §3.10 detection contract:
///   - multi-frame GIF       → animatedImage = true
///   - static  GIF (1 frame) → animatedImage = false
///   - multi-frame APNG      → animatedImage = true
///   - static  PNG           → animatedImage = false
///   - JPEG                  → animatedImage = false (never animatable)
///   - missing / unreadable  → animatedImage = false (defensive)
final class AnimatedImageInspectorTests: XCTestCase {

    // MARK: - GIF

    func testIsAnimatedTrueForMultiFrameGIF() throws {
        let url = try makeGIF(frameCount: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(AnimatedImageInspector.isAnimated(url: url))
    }

    func testIsAnimatedFalseForSingleFrameGIF() throws {
        let url = try makeGIF(frameCount: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(AnimatedImageInspector.isAnimated(url: url),
                       "A 1-frame GIF is just a static image; should not flag.")
    }

    // MARK: - PNG / APNG

    func testIsAnimatedTrueForMultiFrameAPNG() throws {
        let url = try makeAPNG(frameCount: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(AnimatedImageInspector.isAnimated(url: url))
    }

    func testIsAnimatedFalseForStaticPNG() throws {
        let url = try makeStaticPNG()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(AnimatedImageInspector.isAnimated(url: url))
    }

    // MARK: - Other formats

    func testIsAnimatedFalseForJPEG() throws {
        let url = try makeStaticJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(AnimatedImageInspector.isAnimated(url: url),
                       "JPEG is never multi-frame; pre-filter must skip the source check.")
    }

    // MARK: - Defensive

    func testIsAnimatedFalseForMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).gif")
        XCTAssertFalse(AnimatedImageInspector.isAnimated(url: url))
    }

    func testIsAnimatedFalseForCorruptGIF() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("corrupt-\(UUID().uuidString).gif")
        try Data([0x00, 0x01, 0x02]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(AnimatedImageInspector.isAnimated(url: url),
                       "Corrupt headers must return false rather than crash.")
    }

    // MARK: - inspect(url:) → MediaFlags

    func testInspectReturnsAnimatedFlagForMultiFrameGIF() throws {
        let url = try makeGIF(frameCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let flags = AnimatedImageInspector.inspect(url: url)
        XCTAssertEqual(flags, MediaFlags(animatedImage: true))
    }

    func testInspectReturnsNoneForStaticPNG() throws {
        let url = try makeStaticPNG()
        defer { try? FileManager.default.removeItem(at: url) }

        let flags = AnimatedImageInspector.inspect(url: url)
        XCTAssertEqual(flags, MediaFlags.none)
    }

    // MARK: - Importer integration

    func testMediaImporterFlagsAnimatedGIFAtImport() throws {
        let url = try makeGIF(frameCount: 5)
        defer { try? FileManager.default.removeItem(at: url) }

        let slides = MediaImporter.importSlides(from: [url])
        XCTAssertEqual(slides.count, 1)
        XCTAssertEqual(slides.first?.mediaKind, .image)
        XCTAssertTrue(slides.first?.flags.animatedImage ?? false,
                      "Animated GIF must come back from the importer with animatedImage = true.")
        XCTAssertFalse(slides.first?.flags.longGOP ?? true,
                       "Image-branch flags must not set the four video-only flags.")
    }

    func testMediaImporterDoesNotFlagStaticPNGAsAnimated() throws {
        let url = try makeStaticPNG()
        defer { try? FileManager.default.removeItem(at: url) }

        let slides = MediaImporter.importSlides(from: [url])
        XCTAssertEqual(slides.count, 1)
        XCTAssertEqual(slides.first?.flags, MediaFlags.none)
    }

    // MARK: - Synthesis helpers

    private func makeGIF(frameCount: Int) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anim-\(UUID().uuidString).gif")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw NSError(domain: "AnimatedImageInspectorTests", code: 1)
        }
        let containerProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(dest, containerProps as CFDictionary)
        for index in 0..<frameCount {
            let cg = makeFrame(width: 8, height: 8, fillIndex: index)
            let frameProps: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]
            ]
            CGImageDestinationAddImage(dest, cg, frameProps as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "AnimatedImageInspectorTests", code: 2)
        }
        return url
    }

    private func makeAPNG(frameCount: Int) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anim-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw NSError(domain: "AnimatedImageInspectorTests", code: 3)
        }
        let containerProps: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]
        ]
        CGImageDestinationSetProperties(dest, containerProps as CFDictionary)
        for index in 0..<frameCount {
            let cg = makeFrame(width: 8, height: 8, fillIndex: index)
            let frameProps: [CFString: Any] = [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.05]
            ]
            CGImageDestinationAddImage(dest, cg, frameProps as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "AnimatedImageInspectorTests", code: 4)
        }
        return url
    }

    private func makeStaticPNG() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("static-\(UUID().uuidString).png")
        let cg = makeFrame(width: 8, height: 8, fillIndex: 0)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "AnimatedImageInspectorTests", code: 5)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "AnimatedImageInspectorTests", code: 6)
        }
        return url
    }

    private func makeStaticJPEG() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("static-\(UUID().uuidString).jpg")
        let cg = makeFrame(width: 8, height: 8, fillIndex: 0)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "AnimatedImageInspectorTests", code: 7)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "AnimatedImageInspectorTests", code: 8)
        }
        return url
    }

    /// Solid-fill RGBA frame; `fillIndex` rotates the channel so every frame is distinct.
    private func makeFrame(width: Int, height: Int, fillIndex: Int) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: bitmapInfo
        )!
        let r = CGFloat((fillIndex * 60) % 255) / 255.0
        context.setFillColor(red: r, green: 0.5, blue: 0.5, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
