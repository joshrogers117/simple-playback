import Foundation

/// Per-slide outcome of a relink pass. Recorded only for slides whose resolution
/// step is the *fallback* rungs (`.contentHash` / `.nameAndSize`) — slides whose
/// file resolved at the original path are already correct and not in the plan.
struct AssetRelinkUpdate: Equatable {
    var slideID: UUID
    var newURL: URL
    var step: MediaResolutionStep
}

/// Aggregate result of `AssetRelinkPlan.plan`: which slides got updates, plus
/// counts of unchanged-online and still-offline slides so the operator-facing
/// summary can read "relinked 3 via content hash, 1 via name+size, 2 still
/// offline".
struct AssetRelinkPlanReport: Equatable {
    var updates: [AssetRelinkUpdate]
    var stillOfflineSlideIDs: [UUID]
    var unchangedOnlineSlideIDs: [UUID]

    var contentHashCount: Int {
        updates.filter { $0.step == .contentHash }.count
    }

    var nameAndSizeCount: Int {
        updates.filter { $0.step == .nameAndSize }.count
    }
}

/// Pure-logic relink planner + applier. Given a slide list and one or more
/// candidate folders, decides which slides should be re-pointed at a different
/// on-disk URL and produces a new slide array reflecting those decisions. Every
/// I/O dependency is injected; tests drive entirely through stubs.
///
/// Compose with the C9 (deferred) Fix handler in `RootView`:
///   1. Operator picks a folder via NSOpenPanel.
///   2. `plan(slides:searchRoots:)` walks each slide through `MediaResolver`.
///   3. `apply(plan:to:)` mutates the slide list in place (returns a new array).
///   4. RootView writes the result back to `document.project.slides`.
enum AssetRelinkPlan {

    /// Live default — runs the full MediaResolver waterfall.
    static let liveResolve: (MediaReference, [URL]) -> MediaResolutionResult = { reference, roots in
        MediaResolver.resolve(reference: reference, searchRoots: roots)
    }

    /// C8 — factory for a live resolver closure that threads
    /// `folderBookmarks` + `bundleMediaDirectory` into every per-slide
    /// `MediaResolver.resolve` call. RootView builds one of these from
    /// `document.project.folderBookmarks` and passes it as the `resolve:`
    /// argument to `plan(...)` so the folder-bookmark rung fires for the
    /// pre-show `media.files` Locate Folder action.
    static func liveResolve(
        folderBookmarks: [UUID: FolderBookmark],
        bundleMediaDirectory: URL?
    ) -> (MediaReference, [URL]) -> MediaResolutionResult {
        { reference, roots in
            MediaResolver.resolve(
                reference: reference,
                searchRoots: roots,
                bundleMediaDirectory: bundleMediaDirectory,
                folderBookmarks: folderBookmarks
            )
        }
    }

    /// Live default — re-fingerprints the new URL after relink. Tests substitute
    /// a deterministic stub.
    static let liveFingerprint: (URL) -> MediaAssetFingerprint? = { url in
        try? AssetFingerprinter.fingerprint(url: url)
    }

    /// Walk every slide through the resolver. Slides that resolve at their
    /// original path are recorded as `unchangedOnlineSlideIDs` (no change
    /// needed). Slides that resolve via `.contentHash` or `.nameAndSize` get an
    /// `AssetRelinkUpdate`. Slides that resolve to `.offline` are recorded
    /// separately so the host can surface a "still offline" count.
    static func plan(
        slides: [MediaSlide],
        searchRoots: [URL],
        resolve: (MediaReference, [URL]) -> MediaResolutionResult = liveResolve
    ) -> AssetRelinkPlanReport {
        var updates: [AssetRelinkUpdate] = []
        var stillOffline: [UUID] = []
        var unchanged: [UUID] = []
        for slide in slides {
            let result = resolve(slide.media, searchRoots)
            switch result.step {
            case .bundleMedia, .original, .folderBookmark:
                // C8 — `.folderBookmark` reads as "still resolves through the
                // recorded folder bookmark, no relink update needed." The
                // operator's per-file pointer is stale but the project-level
                // FolderBookmark recovers it transparently, so this is treated
                // the same as the per-file bookmark resolving (`.original`).
                unchanged.append(slide.id)
            case .contentHash, .nameAndSize:
                if let url = result.url {
                    updates.append(AssetRelinkUpdate(
                        slideID: slide.id,
                        newURL: url,
                        step: result.step
                    ))
                } else {
                    // Defensive — resolver contract says non-offline implies a URL.
                    stillOffline.append(slide.id)
                }
            case .offline:
                stillOffline.append(slide.id)
            }
        }
        return AssetRelinkPlanReport(
            updates: updates,
            stillOfflineSlideIDs: stillOffline,
            unchangedOnlineSlideIDs: unchanged
        )
    }

    /// Applies a plan to a slide list. For each updated slide, replaces
    /// `slide.media` with a fresh `MediaReference(url:fingerprint:)` so the
    /// stored fingerprint reflects the *new* file (the relink target may be a
    /// different revision of the same asset, so re-hashing is the correct
    /// default). Slides not in the plan are returned unchanged.
    ///
    /// `bundleMediaDirectory` drives kind inference (see `inferKind`):
    /// - `nil` (caller doesn't know the bundle URL — typically untitled
    ///   documents) → existing kind preserved verbatim.
    /// - non-nil → kind flips to `.managed` if the relink target lives under
    ///   the bundle's `Media/` directory, `.linked` otherwise. Closes the
    ///   "managed asset relinked outside the bundle still says managed" gap
    ///   where rung 0 of `MediaResolver` silently failed and the kind lied.
    static func apply(
        plan: AssetRelinkPlanReport,
        to slides: [MediaSlide],
        bundleMediaDirectory: URL? = nil,
        fingerprint: (URL) -> MediaAssetFingerprint? = liveFingerprint
    ) -> [MediaSlide] {
        guard !plan.updates.isEmpty else { return slides }
        let updateMap = Dictionary(uniqueKeysWithValues: plan.updates.map { ($0.slideID, $0) })
        return slides.map { slide -> MediaSlide in
            guard let update = updateMap[slide.id] else { return slide }
            var copy = slide
            let kind = inferKind(
                existing: copy.media.kind,
                newURL: update.newURL,
                bundleMediaDirectory: bundleMediaDirectory
            )
            copy.media = MediaReference(
                url: update.newURL,
                fingerprint: fingerprint(update.newURL),
                kind: kind
            )
            return copy
        }
    }

    /// Pure-logic kind inference for a single relink. Exposed so the
    /// per-slide Locate context-menu path (which doesn't go through
    /// `apply(plan:to:)`) can use the same rule.
    ///
    /// - When `bundleMediaDirectory` is nil, returns `existing` unchanged —
    ///   callers that don't know the bundle URL must not silently
    ///   misclassify.
    /// - When non-nil:
    ///   - `newURL` is a descendant of `bundleMediaDirectory` → `.managed`.
    ///   - `newURL` lives anywhere else → `.linked`. The reverse case
    ///     (a `.linked` slide relinked into the bundle) also flips, which
    ///     is the right thing — the file is now bundle-managed and rung 0
    ///     of the resolver should pick it up.
    static func inferKind(
        existing: MediaReferenceKind,
        newURL: URL,
        bundleMediaDirectory: URL?
    ) -> MediaReferenceKind {
        guard let bundleMediaDirectory else { return existing }
        return urlIsDescendant(newURL, of: bundleMediaDirectory) ? .managed : .linked
    }

    /// True iff `child` lives anywhere under `parent`. Compares
    /// standardized path components so trailing slashes, `.`, `..`, and
    /// symlinks don't trip up the check.
    private static func urlIsDescendant(_ child: URL, of parent: URL) -> Bool {
        let childComponents = child.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parentComponents = parent.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard childComponents.count > parentComponents.count else { return false }
        return Array(childComponents.prefix(parentComponents.count)) == parentComponents
    }
}
