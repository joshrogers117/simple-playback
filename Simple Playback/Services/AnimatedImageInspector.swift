import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Detects multi-frame still containers (animated GIF, APNG) at import time so the codec
/// inspector can surface the C4 yellow chip prompting "transcode to ProRes 4444 for full
/// motion." Today these import as `.image` MediaSlides and only the first frame plays —
/// without this detection step, the operator never sees a hint that the deck contains
/// motion at all.
///
/// Inspection is metadata-only: `CGImageSourceGetCount > 1` is treated as "animated."
/// `CGImageSource` parses the container header without decoding pixel data, so this is
/// cheap to call at import. Errors (unreadable file, unrecognized container) return `false`
/// — better to miss the chip than false-positive on a malformed file.
///
/// Spec ref: feature_spec.md §3.10 ("Animated GIF / APNG — detect → offer
/// convert-to-ProRes-4444"). The "offer" half is the existing C2c right-click; this
/// service supplies the detection half.
enum AnimatedImageInspector {

    /// True for files whose container header advertises more than one frame. Limited to
    /// `.gif` and `.png`/`.apng` extensions because those are the only image containers
    /// that v1 needs to handle as multi-frame. (TIFFs can technically be multi-frame too,
    /// but operators don't ship motion content in TIFFs and we don't want a false-positive
    /// on a multi-resolution JPEG.)
    static func isAnimated(url: URL) -> Bool {
        guard isAnimatableContainer(url) else { return false }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// Convenience that returns a `MediaFlags` for the image branch of `MediaImporter`.
    /// Only the `animatedImage` flag can ever be set (the four codec-inspector flags are
    /// video-only). Returns `.none` for static or unrecognized images.
    static func inspect(url: URL) -> MediaFlags {
        MediaFlags(animatedImage: isAnimated(url: url))
    }

    /// Cheap pre-filter: only `.gif` / `.png` / `.apng` paths can be animated. Skipping
    /// the rest avoids a `CGImageSourceCreateWithURL` call per image-only import.
    private static func isAnimatableContainer(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "gif" || ext == "png" || ext == "apng" { return true }
        // Fall back to UTType when the extension was stripped (some Finder workflows).
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .gif) || type.conforms(to: .png)
        }
        return false
    }
}
