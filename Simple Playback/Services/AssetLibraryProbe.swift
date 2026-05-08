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

    static let empty = AssetLibraryStatus(
        totalSlideCount: 0,
        offlineSlideCount: 0,
        offlineSlideTitles: []
    )
}

enum AssetLibraryProbe {
    /// Default online-check used by the live probe. Honors the bookmark resolution
    /// path inside `MediaReference.resolvedURL()` and verifies the resolved URL
    /// actually points at a real file (the bookmark branch returns a URL even for
    /// missing files because the security-scoped bookmark resolution doesn't stat).
    static let liveIsOnline: (MediaSlide) -> Bool = { slide in
        guard let url = slide.media.resolvedURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Walk the slide list, count offline slides, and capture the first three
    /// offline titles for the operator-facing pre-show summary.
    ///
    /// Pure-logic over the injected `isOnline` predicate. Tests substitute a stub
    /// instead of standing up a temp filesystem of fixtures.
    static func evaluate(
        slides: [MediaSlide],
        previewLimit: Int = 3,
        isOnline: (MediaSlide) -> Bool = liveIsOnline
    ) -> AssetLibraryStatus {
        var offlineTitles: [String] = []
        var offlineCount = 0
        for slide in slides where !isOnline(slide) {
            offlineCount += 1
            if offlineTitles.count < previewLimit {
                offlineTitles.append(slide.title)
            }
        }
        return AssetLibraryStatus(
            totalSlideCount: slides.count,
            offlineSlideCount: offlineCount,
            offlineSlideTitles: offlineTitles
        )
    }
}
