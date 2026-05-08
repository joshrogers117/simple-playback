import Foundation

/// Snapshot of asset-library health used by the pre-show check (E1) — and, in a future
/// iteration, the C9 missing-media banner. "Online" means `slide.media.resolvedURL()`
/// returned a URL whose file exists on disk; "offline" covers every other reason a
/// slide can't be played (volume unmounted, file deleted, path renamed without bookmark
/// survival). Counting at the slide level rather than the cue level reflects the
/// asset-library shape: one missing video could be referenced by many cues, but it's
/// still one operator-facing problem.
struct AssetLibraryStatus: Equatable {
    var totalSlideCount: Int
    var offlineSlideCount: Int
    /// First few offline slide titles for the operator-facing summary. Bounded so
    /// projects with hundreds of missing slides don't render an unbounded summary
    /// string.
    var offlineSlideTitles: [String]
    /// Slides whose linked file is on disk but whose size or mtime differs from
    /// what was captured at import (fingerprint mismatch). Separate from offline:
    /// a stale slide is still playable, just possibly not the file the operator
    /// rehearsed with. Operator-facing as a warning, not an error.
    var staleSlideCount: Int
    var staleSlideTitles: [String]

    init(
        totalSlideCount: Int = 0,
        offlineSlideCount: Int = 0,
        offlineSlideTitles: [String] = [],
        staleSlideCount: Int = 0,
        staleSlideTitles: [String] = []
    ) {
        self.totalSlideCount = totalSlideCount
        self.offlineSlideCount = offlineSlideCount
        self.offlineSlideTitles = offlineSlideTitles
        self.staleSlideCount = staleSlideCount
        self.staleSlideTitles = staleSlideTitles
    }

    static let empty = AssetLibraryStatus()
}

enum AssetLibraryProbe {
    /// Cheap pre-flight metadata pair used to decide if a linked file's bytes
    /// have changed since import. Reading these via `FileManager.attributesOfItem`
    /// is fast (one stat); we only fall back to a real SHA-256 re-fingerprint
    /// when an operator explicitly requests it (deferred — out of scope for this
    /// pre-show row).
    struct CurrentFileMetadata: Equatable {
        var size: Int64
        var mtime: Date
    }

    /// Default online-check used by the live probe. Honors the bookmark resolution
    /// path inside `MediaReference.resolvedURL()` and verifies the resolved URL
    /// actually points at a real file (the bookmark branch returns a URL even for
    /// missing files because the security-scoped bookmark resolution doesn't stat).
    /// Bundle-unaware — for managed-asset bundle portability the host injects a
    /// closure that calls `resolvedURL(bundleMediaDirectory:)`.
    static let liveIsOnline: (MediaSlide) -> Bool = { slide in
        guard let url = slide.media.resolvedURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Returns a bundle-aware online-check closure for the given media-directory
    /// URL. Used by RootView to make the pre-show check correctly classify
    /// managed assets as online when the project bundle has been moved between
    /// machines (the absolute path is stale but the bundle Media/ has the file).
    static func makeIsOnline(bundleMediaDirectory: URL?) -> (MediaSlide) -> Bool {
        makeIsOnline(bundleMediaDirectory: bundleMediaDirectory, folderBookmarks: [:])
    }

    /// C8-aware online-check. Same as the bundle-only overload but threads the
    /// project's folder-bookmark lookup so a slide whose per-file bookmark +
    /// absolute path are dead still reads as online when the imported folder's
    /// bookmark + relative path resolves.
    static func makeIsOnline(
        bundleMediaDirectory: URL?,
        folderBookmarks: [UUID: FolderBookmark]
    ) -> (MediaSlide) -> Bool {
        { slide in
            guard let url = slide.media.resolvedURL(
                bundleMediaDirectory: bundleMediaDirectory,
                folderBookmarks: folderBookmarks
            ) else {
                return false
            }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// Default URL resolver used by the live probe — just `media.resolvedURL()`.
    /// Tests override this so the stale-check branch can be exercised without
    /// standing up real files at the slide's path.
    static let liveResolveURL: (MediaSlide) -> URL? = { slide in
        slide.media.resolvedURL()
    }

    /// Bundle-aware companion to `makeIsOnline`. The pre-show stale-check needs
    /// the same URL the online-check used, so RootView passes both closures
    /// keyed off the same bundle media directory.
    static func makeResolveURL(bundleMediaDirectory: URL?) -> (MediaSlide) -> URL? {
        makeResolveURL(bundleMediaDirectory: bundleMediaDirectory, folderBookmarks: [:])
    }

    /// C8-aware companion to `makeResolveURL`. Threads the same
    /// `folderBookmarks` lookup that `makeIsOnline` uses so the
    /// stale-fingerprint check sees the resolved-via-folder URL too.
    static func makeResolveURL(
        bundleMediaDirectory: URL?,
        folderBookmarks: [UUID: FolderBookmark]
    ) -> (MediaSlide) -> URL? {
        { slide in
            slide.media.resolvedURL(
                bundleMediaDirectory: bundleMediaDirectory,
                folderBookmarks: folderBookmarks
            )
        }
    }

    /// Default current-metadata reader. Returns nil on stat failure; callers
    /// treat that as "can't tell — skip the staleness check for this slide."
    static let liveCurrentMetadata: (URL) -> CurrentFileMetadata? = { url in
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return nil
        }
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        return CurrentFileMetadata(size: size, mtime: mtime)
    }

    /// Tolerance window for mtime comparison. Filesystem precision varies (HFS+
    /// is 1 s; APFS is nanosecond; SMB drops to 2 s on some volumes); 1 s is the
    /// conservative floor that doesn't trigger stale on a venue-portable bundle
    /// reopened on a different volume.
    static let defaultMtimeToleranceSeconds: TimeInterval = 1.0

    /// True iff the on-disk file has changed in size, or mtime moved by more than
    /// the tolerance window, since the fingerprint was captured. Pure helper —
    /// callers compose with `liveCurrentMetadata` (or a stub) to drive the check.
    static func isStale(
        stored: MediaAssetFingerprint,
        current: CurrentFileMetadata,
        mtimeToleranceSeconds: TimeInterval = defaultMtimeToleranceSeconds
    ) -> Bool {
        if stored.size != current.size { return true }
        let delta = abs(stored.mtime.timeIntervalSince(current.mtime))
        return delta > mtimeToleranceSeconds
    }

    /// Walk the slide list, count offline + stale slides, and capture the first
    /// few titles in each bucket for the operator-facing pre-show summary.
    ///
    /// Pure-logic over the injected predicates. Tests substitute stubs instead
    /// of standing up a temp filesystem of fixtures.
    static func evaluate(
        slides: [MediaSlide],
        previewLimit: Int = 3,
        isOnline: (MediaSlide) -> Bool = liveIsOnline,
        resolveURL: (MediaSlide) -> URL? = liveResolveURL,
        currentMetadata: (URL) -> CurrentFileMetadata? = liveCurrentMetadata
    ) -> AssetLibraryStatus {
        var offlineTitles: [String] = []
        var offlineCount = 0
        var staleTitles: [String] = []
        var staleCount = 0
        for slide in slides {
            if !isOnline(slide) {
                offlineCount += 1
                if offlineTitles.count < previewLimit {
                    offlineTitles.append(slide.title)
                }
                continue
            }
            // Stale check — only fires when the slide was fingerprinted at import
            // (pre-C7 slides skip silently) and the live file metadata is readable.
            guard let stored = slide.media.fingerprint,
                  let url = resolveURL(slide),
                  let current = currentMetadata(url) else {
                continue
            }
            if isStale(stored: stored, current: current) {
                staleCount += 1
                if staleTitles.count < previewLimit {
                    staleTitles.append(slide.title)
                }
            }
        }
        return AssetLibraryStatus(
            totalSlideCount: slides.count,
            offlineSlideCount: offlineCount,
            offlineSlideTitles: offlineTitles,
            staleSlideCount: staleCount,
            staleSlideTitles: staleTitles
        )
    }
}
