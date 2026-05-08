import AVFoundation
import AppKit
import CoreGraphics
import Foundation

/// C10 — pure-logic thumbnail generator. Produces a JPEG `Data` representation
/// of a poster frame for any image / video URL the rest of the app already
/// imports. The point is "palette loads with media offline" (spec §3.10): on
/// every import the host caches one JPEG per slide so a moved or missing
/// source still has *something* to render in the palette grid.
///
/// Sized at 320×180 so a typical project's cache is tiny (~10 KB per slide
/// at quality 0.75). The grid uses `aspectRatio(16/9, contentMode: .fit)`,
/// so this matches the visible cell aspect — operators don't see a stretched
/// thumbnail when the asset's native aspect differs.
enum ThumbnailGenerator {

    /// Default cached-thumbnail size. Operators' preview tiles are 16:9 +
    /// `.fit`-clipped; the cache size matches the cell aspect to avoid
    /// re-encoding on display.
    static let defaultPixelSize = CGSize(width: 320, height: 180)

    /// JPEG quality. 0.75 strikes a balance between size (~10 KB) and the
    /// palette legibility of low-contrast posters.
    static let defaultJPEGQuality: CGFloat = 0.75

    enum Failure: Error, Equatable {
        case sourceNotReadable
        case generatorFailed
        case encodingFailed
    }

    /// Generate JPEG `Data` for `url`. `mediaKind` selects the producer:
    /// image URLs go through `NSImage(contentsOf:)`; video URLs through
    /// `AVAssetImageGenerator` at `.zero` (or its closest deliverable time).
    static func generateJPEG(
        for url: URL,
        mediaKind: MediaKind,
        size: CGSize = defaultPixelSize,
        quality: CGFloat = defaultJPEGQuality
    ) throws -> Data {
        switch mediaKind {
        case .image:
            return try generateJPEGFromImage(url: url, size: size, quality: quality)
        case .video:
            return try generateJPEGFromVideoFirstFrame(url: url, size: size, quality: quality)
        }
    }

    /// Encode an `NSImage` into JPEG `Data` at the given size. Exposed for
    /// non-import callers (operator-driven re-cache, future overlays-from-
    /// composition snapshot) that already hold the bitmap in memory.
    static func encodeJPEG(image: NSImage, size: CGSize, quality: CGFloat) throws -> Data {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure.generatorFailed
        }
        return try encodeJPEG(cgImage: cg, size: size, quality: quality)
    }

    private static func generateJPEGFromImage(url: URL, size: CGSize, quality: CGFloat) throws -> Data {
        guard let image = NSImage(contentsOf: url) else {
            throw Failure.sourceNotReadable
        }
        return try encodeJPEG(image: image, size: size, quality: quality)
    }

    private static func generateJPEGFromVideoFirstFrame(url: URL, size: CGSize, quality: CGFloat) throws -> Data {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        // Synchronous frame extraction is acceptable for v1 — import is already
        // a foreground operation and a failed `.zero` extract will throw, at
        // which point we fall back to the asset's first-frame attempt via
        // `requestedTimeToleranceBefore/After`.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        do {
            let cg = try generator.copyCGImage(at: .zero, actualTime: nil)
            return try encodeJPEG(cgImage: cg, size: size, quality: quality)
        } catch {
            throw Failure.generatorFailed
        }
    }

    private static func encodeJPEG(cgImage: CGImage, size: CGSize, quality: CGFloat) throws -> Data {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let representation = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: quality]
        )
        guard let representation else { throw Failure.encodingFailed }
        return representation
    }
}
