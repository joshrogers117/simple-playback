import Foundation

/// Operator-facing description of a single media-pipeline failure. Surfaces in the
/// non-modal `ImportStatusBanner` (C-banner) so the operator stops losing PDFs / Keynote
/// decks / transcodes to silent error swallowing.
///
/// The model intentionally keeps `summary` as a flat string rather than embedding the
/// underlying error: each pipeline (PDF / Keynote / transcode) has its own error type and
/// they are not always Equatable. The banner needs a stable, operator-readable line, and
/// tests need a value type they can compare.
struct MediaImportFailure: Identifiable, Equatable {
    let id: UUID
    let url: URL?
    let kind: Kind
    let summary: String

    enum Kind: String, Equatable {
        /// PDFKit refused the source, found no pages, or could not write a PNG sidecar.
        case pdfImport
        /// Keynote refused (deck encrypted, AppleScript blocked, install missing) or the
        /// resulting intermediate PDF failed to rasterize.
        case keynoteImport
        /// AVAssetExportSession reported a failure or the source URL no longer resolved.
        case transcode
        /// File extension / UTI did not resolve to image, video, PDF, or Keynote — the
        /// importer silently dropped this URL prior to C-banner.
        case unsupportedMedia
    }

    init(id: UUID = UUID(), url: URL?, kind: Kind, summary: String) {
        self.id = id
        self.url = url
        self.kind = kind
        self.summary = summary
    }
}

/// Aggregate result of a single import batch. Returned by
/// `MediaImporter.importSlidesAndReport(from:context:)`. Callers who don't need the
/// failures continue to use `MediaImporter.importSlides(from:context:)`, which delegates
/// to the same path and discards the failure list.
struct MediaImportReport: Equatable {
    var slides: [MediaSlide]
    var failures: [MediaImportFailure]

    static let empty = MediaImportReport(slides: [], failures: [])
}
