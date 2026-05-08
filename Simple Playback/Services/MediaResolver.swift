import Foundation

/// How a `MediaReference` was found at resolution time. The C9 missing-media banner
/// (deferred) will surface this to the operator so a successful auto-relink reads
/// "found via content hash in <folder>" rather than silently swapping the path.
enum MediaResolutionStep: Equatable {
    /// Found at `reference.originalPath` (or via the security-scoped bookmark — both
    /// resolve to the same location from the operator's POV).
    case original
    /// Found a file in one of the search roots whose SHA-256 + size matches the
    /// reference's stored fingerprint. Authoritative — the bytes are identical.
    case contentHash
    /// Found a file with matching basename + extension + size in one of the search
    /// roots. Heuristic — the bytes might differ. Used as a last resort before
    /// declaring offline; the C9 UX flags this case so the operator can verify.
    case nameAndSize
    /// No file resolved through any rung. The reference is offline.
    case offline
}

struct MediaResolutionResult: Equatable {
    /// The resolved file URL, or `nil` iff `step == .offline`.
    var url: URL?
    var step: MediaResolutionStep

    static let offline = MediaResolutionResult(url: nil, step: .offline)
}

/// Pure-logic resolution waterfall. The `MediaReference.resolvedURL()` shortcut covers
/// bookmark + absolute-path resolution; the resolver below handles the *missing-file*
/// fallback ladder per spec §3.10:
///
/// 1. **Original location** — bookmark or absolute path. Cheap and authoritative.
/// 2. **Content-hash search** — walk each `searchRoots` URL and fingerprint files
///    whose size matches the reference's stored size. The first content-hash match
///    wins. Authoritative because identical bytes ⇒ identical asset.
/// 3. **Name + size search** — same walk, but match by basename + extension + size.
///    Heuristic; the C9 banner exposes this so the operator can verify before going
///    live with a guessed file.
/// 4. **Offline** — no rung resolved. The asset is offline; downstream surfaces
///    (palette, cue inspector, pre-show check) treat it as missing media.
///
/// Every I/O dependency is injected so this whole pipeline unit-tests without a real
/// filesystem. The default implementations live in `MediaResolver.live`.
enum MediaResolver {
    /// Default file-existence check used by the live resolver.
    static let liveFileExists: (URL) -> Bool = { url in
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Default recursive directory walk. Returns every regular file under the root,
    /// excluding directories themselves. Skips hidden files (anything whose
    /// last-path-component starts with `.`).
    static let liveListFiles: (URL) -> [URL] = { root in
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    /// Default fingerprint hook used by the live resolver — streams the file via
    /// SHA-256. nil on read failure.
    static let liveFingerprint: (URL) -> MediaAssetFingerprint? = { url in
        try? AssetFingerprinter.fingerprint(url: url)
    }

    /// Default file-size lookup used by the live resolver. Returns `nil` if the file
    /// is unreadable. Cheaper than a full fingerprint — the resolver uses size as the
    /// pre-filter that gates the (expensive) hash step.
    static let liveFileSize: (URL) -> Int64? = { url in
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else {
            return nil
        }
        return Int64(size)
    }

    /// Walks the waterfall described in this enum's doc-comment.
    ///
    /// - Parameters:
    ///   - reference: the asset reference to resolve.
    ///   - searchRoots: directories to walk for hash / name+size matches. Order
    ///     matters: the first matching root wins. Callers typically pass `[bundle
    ///     Media/, project-relink folder]`.
    ///   - fileExists: returns `true` iff the file exists at the URL.
    ///   - listFiles: enumerates every regular file under a directory.
    ///   - fileSize: cheap size lookup used to pre-filter hash candidates.
    ///   - fingerprintAt: SHA-256 + size + mtime for a candidate file.
    static func resolve(
        reference: MediaReference,
        searchRoots: [URL],
        fileExists: (URL) -> Bool = liveFileExists,
        listFiles: (URL) -> [URL] = liveListFiles,
        fileSize: (URL) -> Int64? = liveFileSize,
        fingerprintAt: (URL) -> MediaAssetFingerprint? = liveFingerprint
    ) -> MediaResolutionResult {
        // Rung 1 — original location. Try the security-scoped bookmark first (it
        // survives renames at the source); fall back to `originalPath`. We use the
        // injected `fileExists` so unit tests can drive without a real filesystem.
        if let bookmarkData = reference.bookmarkData {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), fileExists(url) {
                return MediaResolutionResult(url: url, step: .original)
            }
        }
        let originalURLForRung1 = URL(fileURLWithPath: reference.originalPath)
        if fileExists(originalURLForRung1) {
            return MediaResolutionResult(url: originalURLForRung1, step: .original)
        }

        // Rungs 2 & 3 require search roots and a non-nil fingerprint (rung 2) or at
        // least a stored size (rung 3). If neither is available we go straight to
        // offline.
        guard !searchRoots.isEmpty else {
            return .offline
        }

        let originalURL = URL(fileURLWithPath: reference.originalPath)
        let originalBaseName = originalURL.lastPathComponent

        let storedHash = reference.fingerprint?.contentHash
        let storedSize = reference.fingerprint?.size

        var nameAndSizeHit: URL? = nil

        for root in searchRoots {
            let candidates = listFiles(root)
            for candidate in candidates {
                // Skip the original location — already exhausted in rung 1.
                if candidate.standardizedFileURL == originalURL.standardizedFileURL {
                    continue
                }

                let candidateSize = fileSize(candidate)

                // Rung 2 — content hash. Requires both stored size and stored hash.
                if let storedHash, let storedSize {
                    if candidateSize == storedSize,
                       let candidateFingerprint = fingerprintAt(candidate),
                       candidateFingerprint.contentHash == storedHash {
                        return MediaResolutionResult(url: candidate, step: .contentHash)
                    }
                }

                // Rung 3 — name + size. We only record the first hit; the loop
                // continues looking for a content-hash match (which would supersede).
                if nameAndSizeHit == nil,
                   candidate.lastPathComponent == originalBaseName,
                   let storedSize,
                   candidateSize == storedSize {
                    nameAndSizeHit = candidate
                }
            }
        }

        if let nameAndSizeHit {
            return MediaResolutionResult(url: nameAndSizeHit, step: .nameAndSize)
        }

        return .offline
    }
}
