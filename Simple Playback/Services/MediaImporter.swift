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
}

struct MediaImporter {
    /// Test seam — `.key` files route through this hook before PDFImporter. Default
    /// implementation drives Keynote via AppleScript. Tests substitute a stub that produces
    /// a synthetic PDF without invoking the real Keynote.
    static var keynoteExporter: (URL, URL) throws -> URL = { source, dest in
        try KeynoteImporter.exportToPDF(keynoteURL: source, destinationDirectory: dest)
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
            slides.append(MediaSlide(url: url, mediaKind: kind, nativeFrameRate: fps, flags: flags))
        }

        return MediaImportReport(slides: slides, failures: failures)
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
        return imageSlides(forPagesAt: pageURLs, baseTitle: url.deletingPathExtension().lastPathComponent)
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
        return imageSlides(forPagesAt: pageURLs, baseTitle: url.deletingPathExtension().lastPathComponent)
    }

    private static func imageSlides(forPagesAt pageURLs: [URL], baseTitle: String) -> [MediaSlide] {
        pageURLs.enumerated().map { index, pageURL in
            var slide = MediaSlide(url: pageURL, mediaKind: .image)
            slide.title = "\(baseTitle) — page \(index + 1)"
            return slide
        }
    }
}
