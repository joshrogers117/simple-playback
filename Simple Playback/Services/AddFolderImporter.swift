import Foundation

/// Top-level folder walker for the C5c "Add Folder…" UX. Walks one folder a single level
/// deep — recursing into subfolders would surprise operators who export sequences into
/// nested batches — partitions the contents into image sequences vs. standalone media,
/// and hands the result back to the host (RootView) for confirmation and enqueue.
///
/// **Pure logic**: hits the file system to enumerate the folder, but does not import
/// anything itself. The host is responsible for routing standalone URLs through
/// `MediaImporter` and detected sequences through `ImageSequenceEncodeCoordinator`.
enum AddFolderImporter {

    /// What a folder import looks like before the operator confirms. Sequences are queued
    /// for ProRes 4444 encoding (frame rate operator-supplied via the C5c-b sheet);
    /// `standaloneMediaURLs` are passed straight to `MediaImporter` as-is.
    struct Plan: Equatable {
        var sequences: [ImageSequenceDetector.Sequence]
        /// URLs that were not part of any detected sequence. May still be media (a single
        /// `.png` with no siblings, a `.mov`, etc.) or non-media (`.txt`, `.psd`); the
        /// downstream `MediaImporter` decides per-URL via UTI lookup, surfacing failures
        /// through the C-banner.
        var standaloneMediaURLs: [URL]

        static let empty = Plan(sequences: [], standaloneMediaURLs: [])
    }

    /// Read the folder's top-level contents, run `ImageSequenceDetector`, and split the
    /// result into the operator-facing plan. Hidden files (`.DS_Store`, AppleDouble
    /// resource forks) are skipped at enumeration time so they don't show up in the
    /// banner as "unsupported media".
    static func plan(folderURL: URL) throws -> Plan {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        // contentsOfDirectory's order is filesystem-dependent. Normalize by
        // last-path-component so the operator sees a predictable order in the sheet and so
        // tests are deterministic without relying on directory enumeration order.
        let sortedURLs = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let detection = ImageSequenceDetector.detect(in: sortedURLs)
        return Plan(sequences: detection.sequences, standaloneMediaURLs: detection.leftovers)
    }
}
