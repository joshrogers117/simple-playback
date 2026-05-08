import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum MediaImportError: LocalizedError {
    case unsupported(URL)

    var errorDescription: String? {
        switch self {
        case .unsupported(let url):
            "Unsupported media file: \(url.lastPathComponent)"
        }
    }
}

/// Caller-supplied context for source formats that need conversion at import time. Today
/// this is PDF (rasterize-on-import per spec §3.10); future C4/C5 paths (animated GIF,
/// image sequences) will reuse the same shape.
struct MediaImportContext {
    /// Pixel target for rasterization. Spec §3.10 says PDF rasterizes at "output × 2"; the
    /// caller computes that from the active Stage.
    var rasterSize: CGSize

    /// Directory under which rasterized assets land. The importer creates a per-batch
    /// subdirectory inside this root. Caller decides project-bundle (`Cache/Renders/`) vs.
    /// app-support fallback (untitled documents).
    var renderRootDirectory: URL

    /// C10 — directory under which a per-slide poster-frame JPEG is written
    /// at import time so the palette can render even when the source is
    /// offline. Filename is `<slide.id>.jpg`. `nil` skips thumbnail caching
    /// (untitled docs without an app-support fallback path; tests).
    var thumbnailRootDirectory: URL? = nil

    /// C11 — invoked once per imported video slide so the host can kick
    /// off background filmstrip-sprite-sheet generation. Receives the new
    /// slide's id + the still-resolvable source URL; the host computes
    /// the destination filename (`<slide.id>.png`) under whichever
    /// filmstrip cache root applies. The hook is intentionally fire-and-
    /// forget — filmstrip generation is asynchronous and the import path
    /// must not block on it. `nil` skips filmstrip caching (image
    /// imports, untitled docs, tests).
    var enqueueFilmstrip: ((UUID, URL) -> Void)? = nil
}

struct MediaImporter {
    /// Test seam — `.key` files route through this hook before PDFImporter. Default
    /// implementation drives Keynote via AppleScript. Tests substitute a stub that produces
    /// a synthetic PDF without invoking the real Keynote.
    static var keynoteExporter: (URL, URL) throws -> URL = { source, dest in
        try KeynoteImporter.exportToPDF(keynoteURL: source, destinationDirectory: dest)
    }

    /// Test seam — every imported MediaSlide carries the result of this closure as its
    /// `media.fingerprint`. Default streams the file via SHA-256 (C7a). Returns `nil`
    /// on any read or attribute failure; an unfingerprinted slide is still importable
    /// and the relink waterfall recomputes the fingerprint on first successful resolve.
    /// Tests substitute a deterministic stub so they don't need fixtures of known
    /// content.
    static var fingerprinter: (URL) -> MediaAssetFingerprint? = { url in
        try? AssetFingerprinter.fingerprint(url: url)
    }

    /// Test seam — given the slide id and the still-resolvable source URL,
    /// produce JPEG `Data` to cache under `MediaImportContext.thumbnailRootDirectory`.
    /// Default uses `ThumbnailGenerator.generateJPEG`. Returning nil skips the
    /// cache write (e.g., source unreadable, codec rejected at `.zero`); the
    /// importer never blocks an import on thumbnail failure.
    static var thumbnailEncoder: (URL, MediaKind) -> Data? = { url, kind in
        try? ThumbnailGenerator.generateJPEG(for: url, mediaKind: kind)
    }

    /// Backwards-compatible entry point: no context means PDF (and other conversion-required
    /// formats) cannot be rendered, so PDFs are silently dropped. Callers that need PDF
    /// support pass the context-aware overload.
    static func importSlides(from urls: [URL]) -> [MediaSlide] {
        importSlides(from: urls, context: nil)
    }

    static func importSlides(from urls: [URL], context: MediaImportContext?) -> [MediaSlide] {
        importSlidesAndReport(from: urls, context: context).slides
    }

    /// Result-bearing variant. Returns the imported slides AND a per-URL list of failures
    /// (PDF render error, Keynote AppleScript error, unsupported file type). The
    /// non-modal `ImportStatusBanner` (C-banner) presents the failure list to the
    /// operator; per-spec §3.10 silent failures are no longer acceptable.
    static func importSlidesAndReport(
        from urls: [URL],
        context: MediaImportContext?
    ) -> MediaImportReport {
        var slides: [MediaSlide] = []
        var failures: [MediaImportFailure] = []

        for url in urls {
            if isPDF(url) {
                guard let context else { continue }
                do {
                    slides.append(contentsOf: try importPDFThrowing(at: url, context: context))
                } catch {
                    failures.append(makeFailure(url: url, kind: .pdfImport, error: error))
                }
                continue
            }
            if isKeynote(url) {
                guard let context else { continue }
                do {
                    slides.append(contentsOf: try importKeynoteThrowing(at: url, context: context))
                } catch {
                    failures.append(makeFailure(url: url, kind: .keynoteImport, error: error))
                }
                continue
            }
            guard let kind = mediaKind(for: url) else {
                failures.append(MediaImportFailure(
                    url: url,
                    kind: .unsupportedMedia,
                    summary: "Unsupported media: \(url.lastPathComponent)"
                ))
                continue
            }
            let fps = kind == .video ? nativeFrameRate(for: url) : nil
            let flags: MediaFlags
            switch kind {
            case .video: flags = MediaFlagsInspector.inspect(url: url)
            case .image: flags = AnimatedImageInspector.inspect(url: url)
            }
            var slide = MediaSlide(url: url, mediaKind: kind, nativeFrameRate: fps, flags: flags)
            slide.media.fingerprint = fingerprinter(url)
            cacheThumbnailIfPossible(slide: slide, sourceURL: url, kind: kind, context: context)
            if kind == .video {
                context?.enqueueFilmstrip?(slide.id, url)
            }
            slides.append(slide)
        }

        return MediaImportReport(slides: slides, failures: failures)
    }

    /// C10 — best-effort poster-frame cache write. Never throws into the
    /// import path; a thumbnail failure should not block the slide from being
    /// imported. The directory is created lazily on first write.
    private static func cacheThumbnailIfPossible(
        slide: MediaSlide,
        sourceURL: URL,
        kind: MediaKind,
        context: MediaImportContext?
    ) {
        guard let directory = context?.thumbnailRootDirectory else { return }
        guard let data = thumbnailEncoder(sourceURL, kind) else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let dest = directory.appendingPathComponent("\(slide.id.uuidString).jpg")
            try data.write(to: dest, options: .atomic)
        } catch {
            // Silent — best-effort cache.
        }
    }

    /// Operator-facing summary string. `LocalizedError.errorDescription` is the canonical
    /// source; we pass through `error.localizedDescription` as a fallback for anything that
    /// doesn't conform.
    private static func makeFailure(url: URL, kind: MediaImportFailure.Kind, error: Error) -> MediaImportFailure {
        let summary: String
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            summary = description
        } else {
            summary = error.localizedDescription
        }
        return MediaImportFailure(url: url, kind: kind, summary: summary)
    }

    /// Reads the video track's nominal frame rate. Returns `nil` if the asset has no video
    /// track or the rate could not be determined. Synchronous to match the existing import
    /// flow; used at import time, not on the render hot path.
    static func nativeFrameRate(for url: URL) -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let nominal = Double(track.nominalFrameRate)
        if nominal > 0 { return nominal }
        // Fallback: derive from minFrameDuration when nominalFrameRate reports 0 (some HEVC).
        let duration = track.minFrameDuration
        if duration.isValid, duration.seconds > 0 {
            return 1.0 / duration.seconds
        }
        return nil
    }

    static func mediaKind(for url: URL) -> MediaKind? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if type.conforms(to: .image) {
                return .image
            }
            if type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .audiovisualContent) {
                return hasVideoTrack(url) ? .video : nil
            }
        }

        if let type = UTType(filenameExtension: url.pathExtension) {
            if type.conforms(to: .image) {
                return .image
            }
            if type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .audiovisualContent) {
                return hasVideoTrack(url) ? .video : nil
            }
            return nil
        }

        if NSImage(contentsOf: url) != nil {
            return .image
        }

        return hasVideoTrack(url) ? .video : nil
    }

    private static func hasVideoTrack(_ url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        return !asset.tracks(withMediaType: .video).isEmpty
    }

    static func isPDF(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .pdf) {
            return true
        }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .pdf) {
            return true
        }
        return url.pathExtension.lowercased() == "pdf"
    }

    /// Apple ships Keynote files under the UTI `com.apple.iwork.keynote.key`. We accept any
    /// of: a resolved content type that conforms to that UTI, an extension lookup that
    /// resolves to it, or a literal `.key` extension match (the last covers files dropped
    /// from a context where the system hasn't registered the UTI yet).
    static func isKeynote(_ url: URL) -> Bool {
        guard let keynoteUTI = UTType("com.apple.iwork.keynote.key") else {
            return url.pathExtension.lowercased() == "key"
        }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: keynoteUTI) {
            return true
        }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: keynoteUTI) {
            return true
        }
        return url.pathExtension.lowercased() == "key"
    }

    /// One PDF in → N image MediaSlides out (one per page). Each PNG lands inside a fresh
    /// per-batch subdirectory of `context.renderRootDirectory`. Throws on PDFKit failure;
    /// `importSlidesAndReport` catches and converts to a `MediaImportFailure` for the
    /// non-modal banner.
    private static func importPDFThrowing(at url: URL, context: MediaImportContext) throws -> [MediaSlide] {
        let batchDirectory = context.renderRootDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pageURLs = try PDFImporter.rasterize(
            pdfURL: url,
            rasterSize: context.rasterSize,
            destinationDirectory: batchDirectory
        )
        return imageSlidesWithThumbnailCache(
            forPagesAt: pageURLs,
            baseTitle: url.deletingPathExtension().lastPathComponent,
            context: context
        )
    }

    /// One Keynote deck in → N image MediaSlides out, via Keynote → PDF → PNG. The
    /// intermediate PDF lands in the per-batch directory next to its rasterized pages so a
    /// future "Re-rasterize" command (deferred from C3) can re-render from the same source.
    /// Throws on Keynote install / AppleScript / PDFKit failure;
    /// `importSlidesAndReport` catches and converts to a `MediaImportFailure`.
    private static func importKeynoteThrowing(at url: URL, context: MediaImportContext) throws -> [MediaSlide] {
        let batchDirectory = context.renderRootDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pdfURL = try keynoteExporter(url, batchDirectory)
        let pageURLs = try PDFImporter.rasterize(
            pdfURL: pdfURL,
            rasterSize: context.rasterSize,
            destinationDirectory: batchDirectory
        )
        return imageSlidesWithThumbnailCache(
            forPagesAt: pageURLs,
            baseTitle: url.deletingPathExtension().lastPathComponent,
            context: context
        )
    }

    private static func imageSlides(forPagesAt pageURLs: [URL], baseTitle: String) -> [MediaSlide] {
        pageURLs.enumerated().map { index, pageURL in
            var slide = MediaSlide(url: pageURL, mediaKind: .image)
            slide.title = "\(baseTitle) — page \(index + 1)"
            slide.media.fingerprint = fingerprinter(pageURL)
            return slide
        }
    }

    /// C10 — variant of `imageSlides` that also caches a poster-frame
    /// thumbnail per page. The PDF / Keynote import paths use this so the
    /// palette renders the rasterized page even when the bundle has been
    /// moved and the absolute Cache/Renders/ path is stale.
    private static func imageSlidesWithThumbnailCache(
        forPagesAt pageURLs: [URL],
        baseTitle: String,
        context: MediaImportContext
    ) -> [MediaSlide] {
        pageURLs.enumerated().map { index, pageURL in
            var slide = MediaSlide(url: pageURL, mediaKind: .image)
            slide.title = "\(baseTitle) — page \(index + 1)"
            slide.media.fingerprint = fingerprinter(pageURL)
            cacheThumbnailIfPossible(slide: slide, sourceURL: pageURL, kind: .image, context: context)
            return slide
        }
    }
}
