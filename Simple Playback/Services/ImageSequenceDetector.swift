import Foundation

/// Pure-logic grouping of input URLs into image sequences. Spec §3.10:
/// "Image sequence folder (`name.0001.png`) — detect → offer encode-to-ProRes-4444 via
/// `AVAssetWriter`. Do not play sequences directly."
///
/// The detector takes a flat list of URLs (a dropped folder's contents, or a multi-file
/// Add Media… selection) and partitions them into sequences vs. singletons. The actual
/// encode is the deferred C5b — once that lands, the importer would route detected
/// sequences through it the same way C3/C6 route PDFs/Keynote decks through PDFImporter.
///
/// A sequence is a set of ≥2 files where the basename ends in `.NNN[N]` (a 3 or 4 digit
/// counter, optionally with leading zeros) and the rest of the filename is identical
/// (root + extension). The counter does not need to be contiguous (gaps are allowed —
/// some operators export selective frames) but must be strictly increasing in the
/// returned array.
///
/// Recognized extensions: `png`, `jpg`, `jpeg`, `tiff`, `tif`, `exr`. Other extensions
/// are not considered sequence material — they fall through to singletons.
enum ImageSequenceDetector {

    /// One detected sequence. Operators see this as a single MediaSlide once C5b lands;
    /// today the type only feeds the unit-test contract.
    struct Sequence: Equatable {
        /// The shared part of the filename, before the counter — e.g. `"shot01"` for
        /// `["shot01.0001.png", "shot01.0002.png"]`. Used as the slide title and as the
        /// stem of the encoded output filename.
        let baseName: String

        /// Lowercased extension (without dot). All frames share this extension.
        let fileExtension: String

        /// The frame URLs in monotonic counter order. Always ≥2 entries.
        let frameURLs: [URL]

        /// Pad width of the counter (3 or 4 — matches the input filenames). Output
        /// encoders may want this to recreate the original naming scheme for bundle
        /// references.
        let counterPadWidth: Int
    }

    /// Result of detection: the sequences found, plus every URL that didn't belong to a
    /// sequence (returned in the order they appeared in `urls`).
    struct Result: Equatable {
        var sequences: [Sequence]
        var leftovers: [URL]

        static let empty = Result(sequences: [], leftovers: [])
    }

    static let recognizedExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "exr"]

    /// Identify image sequences in `urls`. URLs not belonging to a sequence are returned in
    /// `leftovers`, preserving their original order.
    static func detect(in urls: [URL]) -> Result {
        // 1. Bucket recognized URLs by (baseName, ext, padWidth). Anything we can't parse
        //    falls straight to leftovers.
        struct Key: Hashable { let baseName: String; let ext: String; let padWidth: Int }
        var buckets: [Key: [(counter: Int, url: URL)]] = [:]
        var unbucketed: [URL] = []

        for url in urls {
            guard let parsed = parse(url: url) else {
                unbucketed.append(url)
                continue
            }
            let key = Key(baseName: parsed.baseName, ext: parsed.ext, padWidth: parsed.padWidth)
            buckets[key, default: []].append((parsed.counter, url))
        }

        // 2. A bucket of size ≥ 2 becomes a sequence. Bucket of size 1 falls back to a
        //    leftover — a single `name.0001.png` with no siblings is just a still image.
        var sequences: [Sequence] = []
        var leftovers = unbucketed

        for (key, entries) in buckets {
            if entries.count < 2 {
                leftovers.append(contentsOf: entries.map(\.url))
                continue
            }
            let sorted = entries.sorted(by: { $0.counter < $1.counter })
            sequences.append(Sequence(
                baseName: key.baseName,
                fileExtension: key.ext,
                frameURLs: sorted.map(\.url),
                counterPadWidth: key.padWidth
            ))
        }

        // 3. Restore original ordering on leftovers so the operator's drop ordering is
        //    preserved. Sequences are returned in baseName-then-extension order so output
        //    is deterministic across detection runs (testability).
        leftovers = orderPreserving(leftovers, originalOrder: urls)
        sequences.sort { lhs, rhs in
            if lhs.baseName != rhs.baseName { return lhs.baseName < rhs.baseName }
            return lhs.fileExtension < rhs.fileExtension
        }

        return Result(sequences: sequences, leftovers: leftovers)
    }

    /// Parse a URL into `(baseName, counter, padWidth, ext)` if its filename matches
    /// `<base>.<NNN[N]>.<ext>` with a recognized extension. Returns nil otherwise.
    static func parse(url: URL) -> (baseName: String, counter: Int, padWidth: Int, ext: String)? {
        let ext = url.pathExtension.lowercased()
        guard recognizedExtensions.contains(ext) else { return nil }

        let stem = url.deletingPathExtension().lastPathComponent
        guard let dotIndex = stem.lastIndex(of: ".") else { return nil }
        let counterString = String(stem[stem.index(after: dotIndex)...])
        let baseName = String(stem[..<dotIndex])
        guard !baseName.isEmpty, !counterString.isEmpty else { return nil }
        guard counterString.count == 3 || counterString.count == 4 else { return nil }
        guard counterString.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard let counter = Int(counterString) else { return nil }
        return (baseName, counter, counterString.count, ext)
    }

    /// Stable ordering helper — given a subset, return it in the same order it appeared
    /// in `originalOrder`.
    private static func orderPreserving(_ subset: [URL], originalOrder: [URL]) -> [URL] {
        let setOfPaths = Set(subset.map(\.absoluteString))
        return originalOrder.filter { setOfPaths.contains($0.absoluteString) }
    }
}
