import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Composes the three layers from spec §3.6 onto a base BGRA frame:
///
///   1. media (the input `baseFrame`)
///   2. bug / logo overlay
///   3. message / timer overlay
///
/// When `overlays.isInert`, returns `baseFrame` unmodified (zero allocations, zero copies)
/// — the rendering hot path is unchanged for projects that haven't enabled overlays.
///
/// Buffer convention matches `FrameRenderer`: BGRA premultiplied-first, byteOrder32Little, row 0
/// at the visual top of the image. The pipeline rebuilds a CGContext with the same y-flip used
/// by `FrameRenderer`, so a composed frame can be substituted for a base frame anywhere
/// (DeckLink, preview, transition cache).
final class CompositorPipeline {
    /// Resolves a `BugOverlay.media` reference into an `NSImage`. The default uses
    /// `MediaReference.resolvedURL(bundleMediaDirectory:)` + `NSImage(contentsOf:)`.
    /// Tests inject their own.
    typealias BugImageResolver = (MediaReference) -> NSImage?

    private let injectedResolver: BugImageResolver?
    private var bugImageCache: [String: NSImage] = [:]
    private let cacheLock = NSLock()

    /// C7d — current project bundle's `<bundle>/Media/` URL when one exists.
    /// Threaded into the default bug-image resolver and the cache key so a
    /// moved bundle's managed overlay assets resolve to their bundled copy
    /// instead of the stale absolute path. PlaybackController syncs this from
    /// its own `bundleMediaDirectory` so a single source of truth drives both
    /// playback and overlay resolution.
    var bundleMediaDirectory: URL? {
        didSet {
            if oldValue != bundleMediaDirectory {
                invalidateBugImageCache()
            }
        }
    }

    init(imageResolver: BugImageResolver? = nil) {
        self.injectedResolver = imageResolver
    }

    /// Drop the cached bug image. Call when `BugOverlay.media` changes or after stop.
    func invalidateBugImageCache() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        bugImageCache.removeAll()
    }

    /// Compose the base frame plus overlays. Returns `baseFrame` itself when overlays are
    /// inert (no allocation). Otherwise returns a freshly allocated `RenderedFrame` of the
    /// same dimensions.
    func compose(
        baseFrame: RenderedFrame,
        overlays: CompositorOverlays,
        canvasSize: CGSize,
        nowDate: Date = Date()
    ) -> RenderedFrame {
        if overlays.isInert {
            return baseFrame
        }

        let width = baseFrame.width
        let height = baseFrame.height
        let rowBytes = baseFrame.rowBytes
        guard width > 0, height > 0, rowBytes >= width * 4 else {
            return baseFrame
        }

        guard let baseImage = makeCGImage(from: baseFrame) else {
            return baseFrame
        }

        var data = Data(count: rowBytes * height)
        let canvas = CGSize(width: CGFloat(width), height: CGFloat(height))
        let didDraw = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddr = bytes.baseAddress else { return false }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let context = CGContext(
                data: baseAddr,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }

            // Match FrameRenderer's flip: produce a buffer with row 0 at the visual top.
            context.translateBy(x: 0, y: canvas.height)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high

            // Draw base media at full canvas. CGRect uses top-left coords in this flipped frame.
            context.draw(baseImage, in: CGRect(origin: .zero, size: canvas))

            if overlays.bug.isVisible {
                drawBug(overlay: overlays.bug, in: context, canvas: canvas)
            }
            if overlays.message.isVisible {
                drawMessage(overlay: overlays.message, in: context, canvas: canvas, nowDate: nowDate)
            }
            return true
        }

        guard didDraw else { return baseFrame }
        return RenderedFrame(data: data, width: width, height: height, rowBytes: rowBytes)
    }

    /// Format a remaining countdown as `M:SS` (or `H:MM:SS` once over an hour). Public so the
    /// inspector UI can preview the same string the compositor renders.
    static func formatCountdown(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Resolve a `MessageOverlay`'s text string at a moment in time. Substitutes
    /// `{time_left}` with the live countdown when `countdownTo` is set.
    static func renderedMessageText(overlay: MessageOverlay, nowDate: Date) -> String {
        guard let target = overlay.countdownTo else { return overlay.text }
        let remaining = max(0, target.timeIntervalSince(nowDate))
        let formatted = formatCountdown(remaining)
        if overlay.text.isEmpty { return formatted }
        return overlay.text.replacingOccurrences(of: "{time_left}", with: formatted)
    }

    // MARK: - Drawing

    private func makeCGImage(from frame: RenderedFrame) -> CGImage? {
        let cfData = frame.data as CFData
        guard let provider = CGDataProvider(data: cfData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.rowBytes,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func drawBug(overlay: BugOverlay, in context: CGContext, canvas: CGSize) {
        guard let media = overlay.media,
              let image = bugImage(for: media),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        let imageAspect = CGFloat(cgImage.width) / max(CGFloat(cgImage.height), 1)
        let height = canvas.height * CGFloat(max(0, min(overlay.sizePercent, 1)))
        let width = height * imageAspect
        let marginX = canvas.width * CGFloat(max(0, min(overlay.marginPercent, 0.5)))
        let marginY = canvas.height * CGFloat(max(0, min(overlay.marginPercent, 0.5)))

        // In this flipped context (translateBy(0,h) + scaleBy(1,-1)), the visible top of the
        // canvas is at y=0 and y grows downward.
        let origin: CGPoint
        switch overlay.corner {
        case .topLeft:
            origin = CGPoint(x: marginX, y: marginY)
        case .topRight:
            origin = CGPoint(x: canvas.width - marginX - width, y: marginY)
        case .bottomLeft:
            origin = CGPoint(x: marginX, y: canvas.height - marginY - height)
        case .bottomRight:
            origin = CGPoint(x: canvas.width - marginX - width, y: canvas.height - marginY - height)
        }

        context.saveGState()
        context.setAlpha(CGFloat(max(0, min(overlay.opacity, 1))))
        context.draw(cgImage, in: CGRect(origin: origin, size: CGSize(width: width, height: height)))
        context.restoreGState()
    }

    private func bugImage(for media: MediaReference) -> NSImage? {
        let key = media.resolvedURL(bundleMediaDirectory: bundleMediaDirectory)?.absoluteString ?? media.originalPath
        cacheLock.lock()
        if let cached = bugImageCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let image = resolveImage(media) else { return nil }
        cacheLock.lock()
        bugImageCache[key] = image
        cacheLock.unlock()
        return image
    }

    private func resolveImage(_ ref: MediaReference) -> NSImage? {
        if let injectedResolver { return injectedResolver(ref) }
        guard let url = ref.resolvedURL(bundleMediaDirectory: bundleMediaDirectory) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func drawMessage(overlay: MessageOverlay, in context: CGContext, canvas: CGSize, nowDate: Date) {
        let resolved = Self.renderedMessageText(overlay: overlay, nowDate: nowDate)
        if resolved.isEmpty { return }

        let fontSize = canvas.height * CGFloat(max(0.005, min(overlay.fontSizePercent, 0.5)))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)

        let textColor = overlay.textColor.cgColor
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: textColor
        ]
        guard let attributedString = CFAttributedStringCreate(
            kCFAllocatorDefault,
            resolved as CFString,
            attributes as CFDictionary
        ) else { return }
        let line = CTLineCreateWithAttributedString(attributedString)
        let lineBounds = CTLineGetImageBounds(line, context)
        let textWidth = lineBounds.width
        let textHeight = lineBounds.height
        if textWidth <= 0 || textHeight <= 0 { return }

        let padX = canvas.width * 0.012
        let padY = canvas.height * 0.012
        let bgWidth = textWidth + padX * 2
        let bgHeight = textHeight + padY * 2

        let bgX = (canvas.width - bgWidth) / 2
        // y is measured from the visual top (flipped context, +y down).
        let bgY: CGFloat
        switch overlay.position {
        case .top:
            bgY = canvas.height * 0.05
        case .center:
            bgY = (canvas.height - bgHeight) / 2
        case .lowerThird:
            bgY = canvas.height * 0.78
        }

        context.saveGState()
        context.setAlpha(CGFloat(max(0, min(overlay.opacity, 1))))

        if let bg = overlay.backgroundColor {
            context.setFillColor(bg.cgColor)
            context.fill(CGRect(x: bgX, y: bgY, width: bgWidth, height: bgHeight))
        }

        // Render upright text in a y-flipped context: invert the text matrix so the glyph
        // path orientation cancels out with the context flip.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        // Baseline sits below the visual bottom of the text rect (lineBounds.origin.y is
        // typically negative). After flipping, position the baseline so the glyphs land
        // inside the background pad.
        let textX = bgX + padX - lineBounds.origin.x
        let textY = bgY + padY + textHeight + lineBounds.origin.y
        context.textPosition = CGPoint(x: textX, y: textY)
        CTLineDraw(line, context)

        context.restoreGState()
    }
}
