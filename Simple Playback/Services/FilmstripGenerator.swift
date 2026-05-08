import AVFoundation
import AppKit
import CoreGraphics
import Foundation

/// C11 — pure-logic filmstrip sprite-sheet generator. Pre-renders N
/// thumbnails sampled across a video's duration, composes them into a
/// fixed-grid sprite-sheet PNG, and returns the encoded bytes. The
/// background queue (`FilmstripCoordinator`) writes the result to
/// `<bundle>/Cache/Filmstrips/<slide.id>.png` and a future scrub UI
/// loads the single sprite per video lazily on inspector open.
///
/// Why a sprite sheet rather than per-frame sidecars (the C10 choice):
/// for filmstrips the inspector wants ALL frames at once for a scrub
/// gesture, so a single PNG read is cheaper than N file opens. C10's
/// per-slide sidecar served a different access pattern — one tile at
/// a time as the operator scrolls the palette grid. See `decision_log.md`.
///
/// Sample distribution: `N` evenly-distributed timestamps across
/// `[0, duration)`, centered (the i-th of N is at `D × (i + 0.5)/N`)
/// so neither endpoint is sampled exactly — avoids decode-at-EOF
/// failure modes and makes the visual mid-points legible.
enum FilmstripGenerator {

    /// Default total frame count. 24 is enough for a recognizable scrub
    /// preview at typical operator zoom levels and keeps the sprite-sheet
    /// dimensions modest (160×90 × 6 cols × 4 rows = 960×360 PNG, ~50 KB
    /// at typical-content compression).
    static let defaultFrameCount = 24

    /// Default columns. 6 columns × 4 rows = 24 frames in a 6:4 aspect.
    static let defaultColumns = 6

    /// Default per-frame size. Slightly larger than C10's 320×180 so the
    /// scrub UI's frame is legible without scaling, but small enough to
    /// keep the sprite-sheet image under 100 KB.
    static let defaultFrameSize = CGSize(width: 160, height: 90)

    enum Failure: Error, Equatable {
        case sourceNotReadable
        case durationUnknown
        case frameCountInvalid
        case columnsInvalid
        case frameExtractionFailed(timestamp: Double)
        case encodingFailed
    }

    /// Pure-logic helper — the centered-sample timestamps for a video of
    /// `durationSeconds` carved into `frameCount` slots. Returns the
    /// per-frame timestamp in seconds. Empty array on invalid input
    /// (zero / negative duration or frame count).
    static func sampleTimestamps(durationSeconds: Double, frameCount: Int) -> [Double] {
        guard frameCount > 0, durationSeconds > 0 else { return [] }
        let n = Double(frameCount)
        return (0..<frameCount).map { i in
            durationSeconds * (Double(i) + 0.5) / n
        }
    }

    /// Pure-logic helper — total sprite-sheet dimensions for a grid of
    /// `frameCount` cells laid out `columns`-wide. Rows derived as
    /// `ceil(frameCount / columns)`. The returned size is in pixels (point
    /// scale 1; the sprite is drawn into a CGContext at 1× and encoded as
    /// PNG so DPI is irrelevant).
    static func gridPixelSize(frameCount: Int, columns: Int, frameSize: CGSize) -> CGSize {
        guard frameCount > 0, columns > 0 else { return .zero }
        let cols = max(1, columns)
        let rows = (frameCount + cols - 1) / cols
        return CGSize(
            width: CGFloat(cols) * frameSize.width,
            height: CGFloat(rows) * frameSize.height
        )
    }

    /// Generate a sprite-sheet PNG for the video at `url`. Returns the
    /// encoded `Data`. The caller is responsible for writing to disk
    /// (`FilmstripCoordinator` does this on a background actor so the main
    /// thread isn't blocked by a several-second extraction pass).
    ///
    /// Threading: `AVAssetImageGenerator.copyCGImage(at:actualTime:)` is
    /// synchronous; this method blocks the calling thread for `frameCount`
    /// extractions. Production callsites must run this off the main thread.
    static func generateSpriteSheet(
        for url: URL,
        frameCount: Int = defaultFrameCount,
        columns: Int = defaultColumns,
        frameSize: CGSize = defaultFrameSize
    ) throws -> Data {
        guard frameCount > 0 else { throw Failure.frameCountInvalid }
        guard columns > 0 else { throw Failure.columnsInvalid }

        let asset = AVURLAsset(url: url)
        // `tracks(withMediaType:)` is enough to detect "this isn't really a
        // video" without paying the full async-load cost. `duration` on a
        // post-iOS-13 asset can return invalid for unreadable URLs; we
        // surface those as `sourceNotReadable` rather than `durationUnknown`.
        guard !asset.tracks(withMediaType: .video).isEmpty else {
            throw Failure.sourceNotReadable
        }
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw Failure.durationUnknown
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = frameSize
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let timestamps = sampleTimestamps(durationSeconds: durationSeconds, frameCount: frameCount)
        var cgFrames: [CGImage?] = []
        for ts in timestamps {
            let cmTime = CMTime(seconds: ts, preferredTimescale: 600)
            do {
                let cg = try generator.copyCGImage(at: cmTime, actualTime: nil)
                cgFrames.append(cg)
            } catch {
                throw Failure.frameExtractionFailed(timestamp: ts)
            }
        }

        let canvasSize = gridPixelSize(frameCount: frameCount, columns: columns, frameSize: frameSize)
        return try encodePNG(
            frames: cgFrames,
            canvasSize: canvasSize,
            frameSize: frameSize,
            columns: columns
        )
    }

    private static func encodePNG(
        frames: [CGImage?],
        canvasSize: CGSize,
        frameSize: CGSize,
        columns: Int
    ) throws -> Data {
        let width = Int(canvasSize.width)
        let height = Int(canvasSize.height)
        guard width > 0, height > 0 else { throw Failure.encodingFailed }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw Failure.encodingFailed
        }

        // Black opaque background so non-extracted cells (if any) read as
        // empty rather than transparent garbage.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvasSize))

        for (index, cgImage) in frames.enumerated() {
            guard let cgImage else { continue }
            let row = index / columns
            let col = index % columns
            // Origin: top-left of the cell in CGContext default (y-up) coords.
            // Place row 0 at the top — flip y so visual order matches operator
            // expectation (frame 0 top-left, frame N bottom-right).
            let x = CGFloat(col) * frameSize.width
            let yFromTop = CGFloat(row) * frameSize.height
            let y = canvasSize.height - yFromTop - frameSize.height
            context.draw(cgImage, in: CGRect(x: x, y: y, width: frameSize.width, height: frameSize.height))
        }

        guard let outputCGImage = context.makeImage() else {
            throw Failure.encodingFailed
        }
        let bitmap = NSBitmapImageRep(cgImage: outputCGImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure.encodingFailed
        }
        return pngData
    }
}
