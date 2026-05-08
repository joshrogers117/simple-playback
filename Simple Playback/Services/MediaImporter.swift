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
    /// Backwards-compatible entry point: no context means PDF (and other conversion-required
    /// formats) cannot be rendered, so PDFs are silently dropped. Callers that need PDF
    /// support pass the context-aware overload.
    static func importSlides(from urls: [URL]) -> [MediaSlide] {
        importSlides(from: urls, context: nil)
    }

    static func importSlides(from urls: [URL], context: MediaImportContext?) -> [MediaSlide] {
        urls.flatMap { url -> [MediaSlide] in
            if isPDF(url) {
                guard let context else { return [] }
                return importPDF(at: url, context: context)
            }
            guard let kind = mediaKind(for: url) else { return [] }
            let fps = kind == .video ? nativeFrameRate(for: url) : nil
            let flags = kind == .video ? MediaFlagsInspector.inspect(url: url) : .none
            return [MediaSlide(url: url, mediaKind: kind, nativeFrameRate: fps, flags: flags)]
        }
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

    /// One PDF in → N image MediaSlides out (one per page). Each PNG lands inside a fresh
    /// per-batch subdirectory of `context.renderRootDirectory`. On render failure (corrupt
    /// PDF, write error) returns an empty array — callers see "nothing imported" rather
    /// than a half-imported deck.
    private static func importPDF(at url: URL, context: MediaImportContext) -> [MediaSlide] {
        let batchDirectory = context.renderRootDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pageURLs: [URL]
        do {
            pageURLs = try PDFImporter.rasterize(
                pdfURL: url,
                rasterSize: context.rasterSize,
                destinationDirectory: batchDirectory
            )
        } catch {
            return []
        }
        let baseTitle = url.deletingPathExtension().lastPathComponent
        return pageURLs.enumerated().map { index, pageURL in
            var slide = MediaSlide(url: pageURL, mediaKind: .image)
            slide.title = "\(baseTitle) — page \(index + 1)"
            return slide
        }
    }
}
