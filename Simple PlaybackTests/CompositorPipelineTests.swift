import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import Simple_Playback

final class CompositorPipelineTests: XCTestCase {

    // MARK: - Inert short-circuit

    func testInertOverlaysReturnBaseFrameUnchanged() {
        let pipeline = CompositorPipeline()
        let base = greenFrame(width: 64, height: 36)
        let composed = pipeline.compose(
            baseFrame: base,
            overlays: .empty,
            canvasSize: CGSize(width: 64, height: 36)
        )
        XCTAssertEqual(composed.width, base.width)
        XCTAssertEqual(composed.height, base.height)
        XCTAssertEqual(composed.rowBytes, base.rowBytes)
        XCTAssertEqual(composed.data, base.data,
                       "Inert overlays must return the base frame unchanged — no allocations.")
    }

    func testCompositorReturnsBaseFrameOnDegenerateDimensions() {
        let pipeline = CompositorPipeline()
        let zero = RenderedFrame(data: Data(), width: 0, height: 0, rowBytes: 0)
        var overlays = CompositorOverlays.empty
        overlays.message = MessageOverlay(enabled: true, text: "x")
        let composed = pipeline.compose(
            baseFrame: zero,
            overlays: overlays,
            canvasSize: .zero
        )
        XCTAssertEqual(composed.width, 0)
        XCTAssertEqual(composed.height, 0)
    }

    // MARK: - Bug placement (pixel probe)

    func testBugDrawsInChosenCornerAndLeavesRestUnchanged() {
        let pipeline = CompositorPipeline(imageResolver: { _ in solidImage(width: 8, height: 8, red: 1, green: 0, blue: 0) })

        let canvasW = 100
        let canvasH = 100
        let base = greenFrame(width: canvasW, height: canvasH)

        var overlays = CompositorOverlays.empty
        overlays.bug = BugOverlay(
            enabled: true,
            media: MediaReference(url: URL(fileURLWithPath: "/tmp/test-logo.png")),
            corner: .topLeft,
            marginPercent: 0.05,
            sizePercent: 0.10,
            opacity: 1.0
        )

        let composed = pipeline.compose(
            baseFrame: base,
            overlays: overlays,
            canvasSize: CGSize(width: canvasW, height: canvasH)
        )

        // Margin is 5% of 100 = 5. Bug height is 10% of 100 = 10. Square logo so width = 10.
        // Top-left corner: pixels (5..14, 5..14) should be red-ish; (50,50) should still be green.
        let topLeftPixel = pixel(in: composed, x: 8, y: 8)
        XCTAssertGreaterThan(topLeftPixel.red, 0.7,
                             "Top-left bug pixel should have substantial red.")
        XCTAssertLessThan(topLeftPixel.green, 0.3,
                          "Top-left bug pixel should not be all green.")

        let centerPixel = pixel(in: composed, x: 50, y: 50)
        XCTAssertGreaterThan(centerPixel.green, 0.7,
                             "Canvas center should still be green base media.")
        XCTAssertLessThan(centerPixel.red, 0.3)
    }

    func testBugBottomRightCornerPlacementHitsBottomRightPixels() {
        let pipeline = CompositorPipeline(imageResolver: { _ in solidImage(width: 8, height: 8, red: 1, green: 0, blue: 0) })
        let canvasSize = CGSize(width: 100, height: 100)
        let base = greenFrame(width: 100, height: 100)

        var overlays = CompositorOverlays.empty
        overlays.bug = BugOverlay(
            enabled: true,
            media: MediaReference(url: URL(fileURLWithPath: "/tmp/test-logo.png")),
            corner: .bottomRight,
            marginPercent: 0.05,
            sizePercent: 0.10
        )

        let composed = pipeline.compose(baseFrame: base, overlays: overlays, canvasSize: canvasSize)

        // bottom-right rect lives between (85..94, 85..94) (margin 5, size 10).
        let bottomRight = pixel(in: composed, x: 90, y: 90)
        XCTAssertGreaterThan(bottomRight.red, 0.7)

        let topLeft = pixel(in: composed, x: 8, y: 8)
        XCTAssertGreaterThan(topLeft.green, 0.7,
                             "Top-left should be untouched when corner = bottomRight.")
    }

    func testBugInvisibleWhenMediaResolverReturnsNil() {
        let pipeline = CompositorPipeline(imageResolver: { _ in nil })
        let base = greenFrame(width: 64, height: 36)

        var overlays = CompositorOverlays.empty
        overlays.bug = BugOverlay(
            enabled: true,
            media: MediaReference(url: URL(fileURLWithPath: "/tmp/missing.png")),
            corner: .topLeft
        )

        let composed = pipeline.compose(
            baseFrame: base,
            overlays: overlays,
            canvasSize: CGSize(width: 64, height: 36)
        )

        // Bug couldn't load → only base media drawn → entire canvas should still be green.
        XCTAssertGreaterThan(pixel(in: composed, x: 4, y: 4).green, 0.7)
        XCTAssertGreaterThan(pixel(in: composed, x: 32, y: 18).green, 0.7)
    }

    func testBundleMediaDirectoryChangeInvalidatesBugImageCache() {
        var resolveCount = 0
        let pipeline = CompositorPipeline(imageResolver: { _ in
            resolveCount += 1
            return solidImage(width: 4, height: 4, red: 1, green: 0, blue: 0)
        })
        let base = greenFrame(width: 32, height: 32)
        var overlays = CompositorOverlays.empty
        overlays.bug = BugOverlay(
            enabled: true,
            media: MediaReference(url: URL(fileURLWithPath: "/tmp/bundle-aware-test.png")),
            corner: .topLeft,
            sizePercent: 0.25
        )

        _ = pipeline.compose(baseFrame: base, overlays: overlays, canvasSize: CGSize(width: 32, height: 32))
        XCTAssertEqual(resolveCount, 1)

        pipeline.bundleMediaDirectory = URL(fileURLWithPath: "/tmp/bundle-A/Media", isDirectory: true)
        _ = pipeline.compose(baseFrame: base, overlays: overlays, canvasSize: CGSize(width: 32, height: 32))
        XCTAssertEqual(resolveCount, 2,
                       "Mutating bundleMediaDirectory invalidates the bug-image cache so a moved bundle re-resolves.")

        pipeline.bundleMediaDirectory = URL(fileURLWithPath: "/tmp/bundle-A/Media", isDirectory: true)
        _ = pipeline.compose(baseFrame: base, overlays: overlays, canvasSize: CGSize(width: 32, height: 32))
        XCTAssertEqual(resolveCount, 2,
                       "Setting the same directory is a no-op — the cache is preserved.")
    }

    func testInvalidateBugImageCacheForcesResolverReinvocation() {
        var resolveCount = 0
        let pipeline = CompositorPipeline(imageResolver: { _ in
            resolveCount += 1
            return solidImage(width: 4, height: 4, red: 1, green: 0, blue: 0)
        })
        let base = greenFrame(width: 32, height: 32)
        var overlays = CompositorOverlays.empty
        overlays.bug = BugOverlay(
            enabled: true,
            media: MediaReference(url: URL(fileURLWithPath: "/tmp/cache-test.png")),
            corner: .topLeft,
            sizePercent: 0.25
        )

        _ = pipeline.compose(baseFrame: base, overlays: overlays, canvasSize: CGSize(width: 32, height: 32))
        _ = pipeline.compose(baseFrame: base, overlays: overlays, canvasSize: CGSize(width: 32, height: 32))
        XCTAssertEqual(resolveCount, 1, "Bug image is cached across compose calls.")

        pipeline.invalidateBugImageCache()
        _ = pipeline.compose(baseFrame: base, overlays: overlays, canvasSize: CGSize(width: 32, height: 32))
        XCTAssertEqual(resolveCount, 2, "Cache invalidation forces a re-resolve.")
    }

    // MARK: - Message text + countdown formatting

    func testFormatCountdownUnderOneHourUsesMSS() {
        XCTAssertEqual(CompositorPipeline.formatCountdown(0), "0:00")
        XCTAssertEqual(CompositorPipeline.formatCountdown(5), "0:05")
        XCTAssertEqual(CompositorPipeline.formatCountdown(65), "1:05")
        XCTAssertEqual(CompositorPipeline.formatCountdown(599), "9:59")
    }

    func testFormatCountdownOverOneHourUsesHMMSS() {
        XCTAssertEqual(CompositorPipeline.formatCountdown(3600), "1:00:00")
        XCTAssertEqual(CompositorPipeline.formatCountdown(3725), "1:02:05")
    }

    func testFormatCountdownClampsNegativeToZero() {
        XCTAssertEqual(CompositorPipeline.formatCountdown(-30), "0:00",
                       "Past-target countdowns clamp at zero so the overlay never reads `-1:23`.")
    }

    func testRenderedMessageTextSubstitutesTimeLeftToken() {
        let target = Date(timeIntervalSince1970: 1_000_000_000)
        let now = target.addingTimeInterval(-90)
        let overlay = MessageOverlay(
            enabled: true,
            text: "Doors in {time_left}",
            countdownTo: target
        )
        XCTAssertEqual(
            CompositorPipeline.renderedMessageText(overlay: overlay, nowDate: now),
            "Doors in 1:30"
        )
    }

    func testRenderedMessageTextWithEmptyTextRendersJustCountdown() {
        let target = Date(timeIntervalSince1970: 1_000_000_000)
        let now = target.addingTimeInterval(-30)
        let overlay = MessageOverlay(enabled: true, text: "", countdownTo: target)
        XCTAssertEqual(
            CompositorPipeline.renderedMessageText(overlay: overlay, nowDate: now),
            "0:30"
        )
    }

    func testRenderedMessageTextWithoutCountdownPassesTextThrough() {
        let overlay = MessageOverlay(enabled: true, text: "Welcome", countdownTo: nil)
        XCTAssertEqual(
            CompositorPipeline.renderedMessageText(overlay: overlay, nowDate: Date()),
            "Welcome"
        )
    }

    // MARK: - Composed-frame format invariants

    func testComposedFrameMatchesBaseFrameDimensionsAndStride() {
        let pipeline = CompositorPipeline(imageResolver: { _ in solidImage(width: 8, height: 8, red: 1, green: 0, blue: 0) })
        let base = greenFrame(width: 80, height: 45)
        var overlays = CompositorOverlays.empty
        overlays.bug = BugOverlay(
            enabled: true,
            media: MediaReference(url: URL(fileURLWithPath: "/tmp/test.png")),
            sizePercent: 0.2
        )
        let composed = pipeline.compose(
            baseFrame: base,
            overlays: overlays,
            canvasSize: CGSize(width: 80, height: 45)
        )
        XCTAssertEqual(composed.width, 80)
        XCTAssertEqual(composed.height, 45)
        XCTAssertEqual(composed.rowBytes, base.rowBytes,
                       "Composed frame must keep the base frame's row stride so DeckLink/Preview submit unchanged.")
        XCTAssertEqual(composed.data.count, base.data.count)
    }
}

// MARK: - Test helpers

/// Build a solid-green BGRA frame matching FrameRenderer's row 0-at-top layout.
private func greenFrame(width: Int, height: Int) -> RenderedFrame {
    let rowBytes = width * 4
    var data = Data(count: rowBytes * height)
    data.withUnsafeMutableBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        let buffer = base.assumingMemoryBound(to: UInt8.self)
        for i in stride(from: 0, to: rowBytes * height, by: 4) {
            // BGRA premultipliedFirst, byteOrder32Little: bytes are B, G, R, A.
            buffer[i + 0] = 0x00 // B
            buffer[i + 1] = 0xFF // G
            buffer[i + 2] = 0x00 // R
            buffer[i + 3] = 0xFF // A
        }
    }
    return RenderedFrame(data: data, width: width, height: height, rowBytes: rowBytes)
}

/// Sample a single pixel as 0…1 RGBA. Coordinates use top-left origin (matches the convention
/// FrameRenderer's flipped context produces).
private func pixel(in frame: RenderedFrame, x: Int, y: Int) -> (red: Double, green: Double, blue: Double, alpha: Double) {
    precondition(x >= 0 && x < frame.width && y >= 0 && y < frame.height)
    let offset = y * frame.rowBytes + x * 4
    return frame.data.withUnsafeBytes { bytes in
        let buffer = bytes.bindMemory(to: UInt8.self)
        // BGRA premultipliedFirst, byteOrder32Little: bytes are B, G, R, A.
        return (
            red: Double(buffer[offset + 2]) / 255,
            green: Double(buffer[offset + 1]) / 255,
            blue: Double(buffer[offset + 0]) / 255,
            alpha: Double(buffer[offset + 3]) / 255
        )
    }
}

/// Build an `NSImage` that's a solid color of given dimensions. Used by tests to inject
/// predictable bug graphics into the compositor.
private func solidImage(width: Int, height: Int, red: Double, green: Double, blue: Double) -> NSImage {
    let size = NSSize(width: width, height: height)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    return image
}
