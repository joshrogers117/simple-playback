import AVFoundation
import AppKit
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

struct MediaImporter {
    static func importSlides(from urls: [URL]) -> [MediaSlide] {
        urls.compactMap { url in
            guard let kind = mediaKind(for: url) else { return nil }
            let fps = kind == .video ? nativeFrameRate(for: url) : nil
            return MediaSlide(url: url, mediaKind: kind, nativeFrameRate: fps)
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
}
