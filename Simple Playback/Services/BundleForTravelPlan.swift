import Foundation

/// Per-slide outcome of a Bundle for Travel plan: one slide that should be
/// copied into the project bundle's `Media/` directory. The destination is
/// declared as a *filename only* (no directory) so the host wires it up to
/// the actual `<bundleURL>/Media/` URL at copy time.
struct BundleForTravelOperation: Equatable {
    var slideID: UUID
    var sourceURL: URL
    var destinationFilename: String

    /// Convenience: the absolute destination URL inside the operator-supplied
    /// bundle Media/ directory.
    func destinationURL(inMediaDirectory mediaDirectoryURL: URL) -> URL {
        mediaDirectoryURL.appendingPathComponent(destinationFilename)
    }
}

/// Aggregate result of `BundleForTravelPlan.plan`. Surfaces exactly which
/// slides will be copied, which are already managed (so we skip them), and
/// which are offline (so we can't copy them). The host renders this summary
/// in the confirmation sheet so the operator knows what's about to happen.
struct BundleForTravelPlanReport: Equatable {
    var operations: [BundleForTravelOperation]
    var alreadyManagedSlideIDs: [UUID]
    var offlineSlideIDs: [UUID]

    /// Total bytes that will be read+written. Computed from the per-operation
    /// `sourceSize`s captured at plan time so the progress UI doesn't need to
    /// re-stat the source files.
    var totalBytes: Int64

    var copyCount: Int { operations.count }
    var skippedCount: Int { alreadyManagedSlideIDs.count + offlineSlideIDs.count }

    static let empty = BundleForTravelPlanReport(
        operations: [],
        alreadyManagedSlideIDs: [],
        offlineSlideIDs: [],
        totalBytes: 0
    )
}

/// Pure-logic plan + apply for the C7d "Bundle for Travel" command (spec §3.10).
/// Mirrors `AssetRelinkPlan` in shape: pure-logic plan against injected I/O
/// dependencies, then a coordinator outside this module performs the copies
/// and calls `apply` on completion.
///
/// Resolution order at plan time:
///   - Slides whose `kind == .managed` are skipped (already in Media/).
///   - Slides whose `kind == .linked` resolve via the injected `resolve` hook
///     (live default: `MediaResolver.resolve`). Online slides become
///     operations; offline slides go into `offlineSlideIDs`.
///
/// Filename collision policy: if two source files share a basename (e.g. two
/// folders with `intro.mov`), we deduplicate by appending `-1`, `-2`, … to the
/// stem before the extension. The first slide to claim a name keeps it. This
/// is deterministic in slide order so a re-run on the same project produces
/// the same destination filenames.
enum BundleForTravelPlan {

    /// Live default — runs the C7c MediaResolver waterfall to find each slide's
    /// current on-disk location. Search roots default to empty because at plan
    /// time we typically only need rung 1 (bookmark/originalPath); the operator
    /// runs missing-media relink separately.
    static let liveResolve: (MediaReference) -> MediaResolutionResult = { reference in
        MediaResolver.resolve(reference: reference, searchRoots: [])
    }

    /// Live default — cheap file-size lookup used to compute `totalBytes` at
    /// plan time so the progress UI has a denominator without re-statting.
    static let liveFileSize: (URL) -> Int64? = { url in
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else {
            return nil
        }
        return Int64(size)
    }

    /// Live default — re-fingerprints the destination URL after copy. Tests
    /// substitute a deterministic stub.
    static let liveFingerprint: (URL) -> MediaAssetFingerprint? = { url in
        try? AssetFingerprinter.fingerprint(url: url)
    }

    /// Plans a Bundle for Travel pass over the supplied slides. The plan
    /// itself does no I/O beyond the injected hooks — actual copies happen
    /// in the coordinator.
    static func plan(
        slides: [MediaSlide],
        resolve: (MediaReference) -> MediaResolutionResult = liveResolve,
        fileSize: (URL) -> Int64? = liveFileSize
    ) -> BundleForTravelPlanReport {
        var operations: [BundleForTravelOperation] = []
        var alreadyManaged: [UUID] = []
        var offline: [UUID] = []
        var claimedFilenames = Set<String>()
        var totalBytes: Int64 = 0

        for slide in slides {
            if slide.media.kind == .managed {
                alreadyManaged.append(slide.id)
                continue
            }

            let resolution = resolve(slide.media)
            guard resolution.step != .offline, let sourceURL = resolution.url else {
                offline.append(slide.id)
                continue
            }

            let filename = uniqueFilename(
                for: sourceURL.lastPathComponent,
                claimed: claimedFilenames
            )
            claimedFilenames.insert(filename)
            operations.append(BundleForTravelOperation(
                slideID: slide.id,
                sourceURL: sourceURL,
                destinationFilename: filename
            ))
            if let size = fileSize(sourceURL) {
                totalBytes += size
            }
        }

        return BundleForTravelPlanReport(
            operations: operations,
            alreadyManagedSlideIDs: alreadyManaged,
            offlineSlideIDs: offline,
            totalBytes: totalBytes
        )
    }

    /// Applies a completed plan to the slide list. For each operation, the
    /// matching slide's `MediaReference` is rebuilt at the *destination* URL
    /// (inside `<bundle>/Media/`), `kind` flips to `.managed`, and the
    /// fingerprint is refreshed against the freshly-copied file.
    ///
    /// Slides not in the plan (already managed, offline, or absent) round-trip
    /// unchanged.
    static func apply(
        plan: BundleForTravelPlanReport,
        to slides: [MediaSlide],
        mediaDirectoryURL: URL,
        fingerprint: (URL) -> MediaAssetFingerprint? = liveFingerprint
    ) -> [MediaSlide] {
        guard !plan.operations.isEmpty else { return slides }
        let opMap = Dictionary(
            uniqueKeysWithValues: plan.operations.map { ($0.slideID, $0) }
        )
        return slides.map { slide -> MediaSlide in
            guard let op = opMap[slide.id] else { return slide }
            var copy = slide
            let destinationURL = op.destinationURL(inMediaDirectory: mediaDirectoryURL)
            copy.media = MediaReference(
                url: destinationURL,
                fingerprint: fingerprint(destinationURL),
                kind: .managed
            )
            return copy
        }
    }

    /// Returns a filename derived from `original` that does not collide with
    /// `claimed`. The first claimant keeps the unsuffixed name; subsequent
    /// collisions get `-1`, `-2`, … inserted before the extension. Pure logic.
    static func uniqueFilename(for original: String, claimed: Set<String>) -> String {
        if !claimed.contains(original) { return original }

        let url = URL(fileURLWithPath: original)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let extSuffix = ext.isEmpty ? "" : ".\(ext)"

        var counter = 1
        while true {
            let candidate = "\(stem)-\(counter)\(extSuffix)"
            if !claimed.contains(candidate) { return candidate }
            counter += 1
        }
    }
}
