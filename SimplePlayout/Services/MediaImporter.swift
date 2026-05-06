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
            return MediaSlide(url: url, mediaKind: kind)
        }
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
