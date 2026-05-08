import Foundation

/// How a `MediaReference` was found at resolution time. The C9 missing-media banner
/// (deferred) will surface this to the operator so a successful auto-relink reads
/// "found via content hash in <folder>" rather than silently swapping the path.
enum MediaResolutionStep: Equatable {
    /// `kind == .managed` reference resolved inside `<bundle>/Media/`. Authoritative —
    /// the file is bundled with the project. C7d Bundle for Travel produces references
    /// in this state. Tried first for managed assets so a bundle moved to a new
    /// machine still resolves even when the bookmark + absolute path are stale.
    case bundleMedia
    /// Found at `reference.originalPath` (or via the security-scoped bookmark — both
    /// resolve to the same location from the operator's POV).
    case original
    /// C8 — resolved via the project-level `FolderBookmark` whose `id` matches the
    /// reference's `folderBookmarkID`, joined with `folderRelativePath`. Recovers a
    /// clip moved within its imported parent directory (a folder-level rename leaves
    /// every per-file bookmark dead, but the folder bookmark plus the relative path
    /// reaches the new location without a relink walk).
    case folderBookmark
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
/// 0. **Bundle Media (managed only)** — for `.managed` references when the caller
///    supplies a `bundleMediaDirectory`, try `<bundleMediaDirectory>/<basename>` first.
///    A bundle moved to a new machine still resolves even when the absolute-path /
///    security-scoped-bookmark recorded at C7d apply time are stale.
/// 1. **Original location** — bookmark or absolute path. Cheap and authoritative.
/// 2. **C8 folder bookmark** — when the reference was imported via Add Folder /
///    folder-drop and carries `folderBookmarkID + folderRelativePath`, look up the
///    matching `FolderBookmark` in the project, resolve it to a directory URL, and
///    join with the relative path. Cheap (no walk) and recovers a clip moved within
///    its imported parent directory.
/// 3. **Content-hash search** — walk each `searchRoots` URL and fingerprint files
///    whose size matches the reference's stored size. The first content-hash match
///    wins. Authoritative because identical bytes ⇒ identical asset.
/// 4. **Name + size search** — same walk, but match by basename + extension + size.
///    Heuristic; the C9 banner exposes this so the operator can verify before going
///    live with a guessed file.
/// 5. **Offline** — no rung resolved. The asset is offline; downstream surfaces
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
    ///   - bundleMediaDirectory: the active project's `<bundle>/Media/` URL, if known.
    ///     Drives rung 0 for `.managed` references so a bundle moved across machines
    ///     still resolves. Pass `nil` for untitled documents or when the caller
    ///     intentionally wants only the original-path waterfall.
    ///   - folderBookmarks: id → `FolderBookmark` lookup for the active project.
    ///     Drives rung 2 (C8) when the reference carries `folderBookmarkID` +
    ///     `folderRelativePath`. Pass an empty dict to skip the rung; pre-C8
    ///     callsites that don't yet know about folder bookmarks can omit it.
    ///   - fileExists: returns `true` iff the file exists at the URL.
    ///   - listFiles: enumerates every regular file under a directory.
    ///   - fileSize: cheap size lookup used to pre-filter hash candidates.
    ///   - fingerprintAt: SHA-256 + size + mtime for a candidate file.
    static func resolve(
        reference: MediaReference,
        searchRoots: [URL],
        bundleMediaDirectory: URL? = nil,
        folderBookmarks: [UUID: FolderBookmark] = [:],
        fileExists: (URL) -> Bool = liveFileExists,
        listFiles: (URL) -> [URL] = liveListFiles,
        fileSize: (URL) -> Int64? = liveFileSize,
        fingerprintAt: (URL) -> MediaAssetFingerprint? = liveFingerprint
    ) -> MediaResolutionResult {
        // Rung 0 — bundle Media. Only consulted for `.managed` references when the
        // caller has supplied the bundle's Media/ directory. The destination filename
        // is the basename of `originalPath` because C7d apply writes
        // `<bundle>/Media/<basename>` as the new originalPath (so on the same machine
        // this short-circuits to the same URL as rung 1; on a moved bundle it
        // recovers when the absolute path no longer matches).
        if reference.kind == .managed, let bundleMediaDirectory {
            let candidate = bundleMediaDirectory
                .appendingPathComponent(URL(fileURLWithPath: reference.originalPath).lastPathComponent)
            if fileExists(candidate) {
                return MediaResolutionResult(url: candidate, step: .bundleMedia)
            }
        }

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

        // Rung 2 — folder bookmark + relative path (C8). Cheap: a single bookmark
        // resolution + path-append + fileExists. No walk. Only fires when the
        // reference was imported with folder-mode (Add Folder / folder-drop) and
        // the project's folderBookmarks lookup contains the matching entry.
        if let folderID = reference.folderBookmarkID,
           let relative = reference.folderRelativePath,
           !relative.isEmpty,
           let bookmark = folderBookmarks[folderID],
           let directory = bookmark.resolvedDirectory(fileExists: fileExists) {
            let candidate = directory.appendingPathComponent(relative)
            if fileExists(candidate) {
                return MediaResolutionResult(url: candidate, step: .folderBookmark)
            }
        }

        // Rungs 3 & 4 require search roots and a non-nil fingerprint (rung 3) or at
        // least a stored size (rung 4). If neither is available we go straight to
        // offline.
        guard !searchRoots.isEmpty else {
            return .offline
        }

        let originalURL = URL(fileURLWithPath: reference.originalPath)
        let originalBaseName = originalURL.lastPathComponent

        let storedHash = reference.fingerprint?.contentHash
        let storedSize = reference.fingerprint?.size

        // Pre-C7 (legacy) references have no fingerprint, so both `storedHash` and
        // `storedSize` are nil. Rung 3 needs a stored hash; rung 4 needs a stored
        // size — neither can match. Short-circuit before walking every file in
        // every search root for nothing. On a 500-slide deck this is the
        // difference between O(slides × roots × files) syscalls and zero.
        if storedHash == nil && storedSize == nil {
            return .offline
        }

        var nameAndSizeHit: URL? = nil

        for root in searchRoots {
            let candidates = listFiles(root)
            for candidate in candidates {
                // Skip the original location — already exhausted in rung 1.
                if candidate.standardizedFileURL == originalURL.standardizedFileURL {
                    continue
                }

                let candidateSize = fileSize(candidate)

                // Rung 3 — content hash. Requires both stored size and stored hash.
                if let storedHash, let storedSize {
                    if candidateSize == storedSize,
                       let candidateFingerprint = fingerprintAt(candidate),
                       candidateFingerprint.contentHash == storedHash {
                        return MediaResolutionResult(url: candidate, step: .contentHash)
                    }
                }

                // Rung 4 — name + size. We only record the first hit; the loop
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
