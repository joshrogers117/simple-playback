import Foundation
import XCTest
@testable import Simple_Playback

/// Pure-logic coverage for the C7c→E1 asset-library probe. Drives entirely through
/// the injected `isOnline` predicate so the tests never touch the filesystem.
final class AssetLibraryProbeTests: XCTestCase {

    // MARK: - empty / all-online cases

    func testEmptyLibraryReportsZeroes() {
        let status = AssetLibraryProbe.evaluate(slides: [])
        XCTAssertEqual(status, AssetLibraryStatus.empty)
    }

    func testAllOnlineLibraryReportsZeroOffline() {
        let slides = [makeSlide(title: "A"), makeSlide(title: "B"), makeSlide(title: "C")]

        let status = AssetLibraryProbe.evaluate(
            slides: slides,
            isOnline: { _ in true }
        )

        XCTAssertEqual(status.totalSlideCount, 3)
        XCTAssertEqual(status.offlineSlideCount, 0)
        XCTAssertEqual(status.offlineSlideTitles, [])
    }

    // MARK: - mixed / preview-limit

    func testOfflineCountAndTitlesPopulated() {
        let slides = [
            makeSlide(title: "Online 1"),
            makeSlide(title: "Offline 1"),
            makeSlide(title: "Offline 2")
        ]

        let status = AssetLibraryProbe.evaluate(
            slides: slides,
            isOnline: { slide in slide.title.starts(with: "Online") }
        )

        XCTAssertEqual(status.totalSlideCount, 3)
        XCTAssertEqual(status.offlineSlideCount, 2)
        XCTAssertEqual(status.offlineSlideTitles, ["Offline 1", "Offline 2"])
    }

    func testPreviewLimitTrimsOfflineTitles() {
        let titles = (1...10).map { "Slide \($0)" }
        let slides = titles.map { makeSlide(title: $0) }

        let status = AssetLibraryProbe.evaluate(
            slides: slides,
            previewLimit: 3,
            isOnline: { _ in false }
        )

        XCTAssertEqual(status.offlineSlideCount, 10)
        XCTAssertEqual(status.offlineSlideTitles, ["Slide 1", "Slide 2", "Slide 3"])
    }

    func testPreviewLimitZeroReturnsEmptyTitleList() {
        let slides = (1...3).map { makeSlide(title: "Slide \($0)") }

        let status = AssetLibraryProbe.evaluate(
            slides: slides,
            previewLimit: 0,
            isOnline: { _ in false }
        )

        XCTAssertEqual(status.offlineSlideCount, 3)
        XCTAssertEqual(status.offlineSlideTitles, [])
    }

    // MARK: - stale fingerprint detection

    func testIsStaleReturnsFalseWhenSizeAndMtimeUnchanged() {
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = MediaAssetFingerprint(contentHash: "h", size: 1024, mtime: mtime)
        let current = AssetLibraryProbe.CurrentFileMetadata(size: 1024, mtime: mtime)
        XCTAssertFalse(AssetLibraryProbe.isStale(stored: stored, current: current))
    }

    func testIsStaleReturnsTrueOnSizeChange() {
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = MediaAssetFingerprint(contentHash: "h", size: 1024, mtime: mtime)
        let current = AssetLibraryProbe.CurrentFileMetadata(size: 2048, mtime: mtime)
        XCTAssertTrue(AssetLibraryProbe.isStale(stored: stored, current: current))
    }

    func testIsStaleToleratesSubSecondMtimeDrift() {
        let storedMtime = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = MediaAssetFingerprint(contentHash: "h", size: 100, mtime: storedMtime)
        // 0.5 s drift should not trip stale (HFS+/SMB precision).
        let current = AssetLibraryProbe.CurrentFileMetadata(
            size: 100,
            mtime: storedMtime.addingTimeInterval(0.5)
        )
        XCTAssertFalse(AssetLibraryProbe.isStale(stored: stored, current: current))
    }

    func testIsStaleReturnsTrueWhenMtimePastTolerance() {
        let storedMtime = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = MediaAssetFingerprint(contentHash: "h", size: 100, mtime: storedMtime)
        let current = AssetLibraryProbe.CurrentFileMetadata(
            size: 100,
            mtime: storedMtime.addingTimeInterval(60)
        )
        XCTAssertTrue(AssetLibraryProbe.isStale(stored: stored, current: current))
    }

    func testEvaluateCountsStaleAndOfflineSeparately() {
        let onlineSlide = makeFingerprintedSlide(title: "Online", size: 100)
        let offlineSlide = makeFingerprintedSlide(title: "Offline", size: 200)
        let staleSlide = makeFingerprintedSlide(title: "Stale", size: 300)

        // Stub: offline slide reports false for online; everyone else reports true.
        let isOnline: (MediaSlide) -> Bool = { slide in slide.title != "Offline" }

        // Stub: stale slide returns metadata with a different size; online slide
        // returns matching metadata.
        let metadata: (URL) -> AssetLibraryProbe.CurrentFileMetadata? = { url in
            if url.lastPathComponent.contains("Stale") {
                return AssetLibraryProbe.CurrentFileMetadata(size: 999, mtime: Date(timeIntervalSince1970: 1))
            }
            return AssetLibraryProbe.CurrentFileMetadata(
                size: 100,
                mtime: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        // Stub the URL resolver so the test doesn't depend on real /tmp files.
        let resolveURL: (MediaSlide) -> URL? = { slide in
            URL(fileURLWithPath: "/tmp/\(slide.title).mov")
        }

        let status = AssetLibraryProbe.evaluate(
            slides: [onlineSlide, offlineSlide, staleSlide],
            isOnline: isOnline,
            resolveURL: resolveURL,
            currentMetadata: metadata
        )

        XCTAssertEqual(status.totalSlideCount, 3)
        XCTAssertEqual(status.offlineSlideCount, 1)
        XCTAssertEqual(status.offlineSlideTitles, ["Offline"])
        XCTAssertEqual(status.staleSlideCount, 1)
        XCTAssertEqual(status.staleSlideTitles, ["Stale"])
    }

    func testEvaluateSkipsStaleCheckForUnfingerprintedSlides() {
        // A pre-C7 slide (no fingerprint) should not get a stale flag even if the
        // currentMetadata closure would return non-matching values — there's no
        // baseline to compare against.
        var slide = MediaSlide(url: URL(fileURLWithPath: "/tmp/legacy.mov"), mediaKind: .video)
        slide.title = "Legacy"
        XCTAssertNil(slide.media.fingerprint)

        let status = AssetLibraryProbe.evaluate(
            slides: [slide],
            isOnline: { _ in true },
            resolveURL: { URL(fileURLWithPath: "/tmp/\($0.title).mov") },
            currentMetadata: { _ in
                AssetLibraryProbe.CurrentFileMetadata(size: 999, mtime: Date())
            }
        )

        XCTAssertEqual(status.staleSlideCount, 0,
                       "Slides without a stored fingerprint cannot be checked for staleness.")
    }

    // MARK: - PreShowCheck.evaluateAssetLibrary integration

    func testPreShowEvaluatesAssetLibraryOK() {
        var ctx = PreShowCheck.Context()
        ctx.assetLibraryStatus = AssetLibraryStatus(
            totalSlideCount: 5,
            offlineSlideCount: 0,
            offlineSlideTitles: []
        )
        let row = PreShowCheck.evaluateAssetLibrary(context: ctx)

        XCTAssertEqual(row?.id, "media.files")
        XCTAssertEqual(row?.severity, .ok)
        XCTAssertTrue(row?.summary.contains("All 5") ?? false,
                      "Summary should lead with the total count.")
    }

    func testPreShowEvaluatesAssetLibraryError() {
        var ctx = PreShowCheck.Context()
        ctx.assetLibraryStatus = AssetLibraryStatus(
            totalSlideCount: 5,
            offlineSlideCount: 2,
            offlineSlideTitles: ["intro.mov", "outro.mov"]
        )
        let row = PreShowCheck.evaluateAssetLibrary(context: ctx)

        XCTAssertEqual(row?.severity, .error)
        XCTAssertTrue(row?.summary.contains("2 of 5") ?? false)
        XCTAssertTrue(row?.summary.contains("intro.mov") ?? false)
        XCTAssertTrue(row?.summary.contains("outro.mov") ?? false)
    }

    func testPreShowEvaluatesAssetLibraryErrorWithExtraSummary() {
        var ctx = PreShowCheck.Context()
        ctx.assetLibraryStatus = AssetLibraryStatus(
            totalSlideCount: 10,
            offlineSlideCount: 6,
            offlineSlideTitles: ["a", "b", "c"]
        )
        let row = PreShowCheck.evaluateAssetLibrary(context: ctx)

        XCTAssertEqual(row?.severity, .error)
        XCTAssertTrue(row?.summary.contains("(+3 more)") ?? false,
                      "Summary should call out the trimmed remainder when offline > preview.")
    }

    func testPreShowEvaluatesAssetLibraryEmpty() {
        var ctx = PreShowCheck.Context()
        ctx.assetLibraryStatus = AssetLibraryStatus(
            totalSlideCount: 0,
            offlineSlideCount: 0,
            offlineSlideTitles: []
        )
        let row = PreShowCheck.evaluateAssetLibrary(context: ctx)

        XCTAssertEqual(row?.severity, .info,
                       "Empty libraries are info — useful signal for fresh projects.")
    }

    func testPreShowEvaluatesAssetLibrarySkipsWhenContextNil() {
        let ctx = PreShowCheck.Context() // no status sampled
        XCTAssertNil(PreShowCheck.evaluateAssetLibrary(context: ctx))
    }

    func testPreShowEvaluatesAssetLibraryStaleAsWarning() {
        var ctx = PreShowCheck.Context()
        ctx.assetLibraryStatus = AssetLibraryStatus(
            totalSlideCount: 4,
            offlineSlideCount: 0,
            offlineSlideTitles: [],
            staleSlideCount: 2,
            staleSlideTitles: ["intro.mov", "logo.png"]
        )
        let row = PreShowCheck.evaluateAssetLibrary(context: ctx)

        XCTAssertEqual(row?.severity, .warning)
        XCTAssertTrue(row?.summary.contains("2 of 4") ?? false)
        XCTAssertTrue(row?.summary.contains("modified since import") ?? false)
        XCTAssertTrue(row?.summary.contains("intro.mov") ?? false)
    }

    func testPreShowEvaluatesAssetLibraryOfflineEclipsesStale() {
        // When both offline and stale exist, the offline error wins — operators
        // need to address missing files first; staleness is a follow-up signal.
        var ctx = PreShowCheck.Context()
        ctx.assetLibraryStatus = AssetLibraryStatus(
            totalSlideCount: 5,
            offlineSlideCount: 1,
            offlineSlideTitles: ["missing.mov"],
            staleSlideCount: 2,
            staleSlideTitles: ["intro.mov", "logo.png"]
        )
        let row = PreShowCheck.evaluateAssetLibrary(context: ctx)

        XCTAssertEqual(row?.severity, .error)
        XCTAssertTrue(row?.summary.contains("offline") ?? false,
                      "Offline summary should be the surfaced one when both buckets are populated.")
    }

    // MARK: - helpers

    private func makeSlide(title: String) -> MediaSlide {
        let url = URL(fileURLWithPath: "/tmp/\(title).mov")
        var slide = MediaSlide(url: url, mediaKind: .video)
        slide.title = title
        return slide
    }

    private func makeFingerprintedSlide(title: String, size: Int64) -> MediaSlide {
        var slide = makeSlide(title: title)
        slide.media.fingerprint = MediaAssetFingerprint(
            contentHash: "h-\(title)",
            size: size,
            mtime: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return slide
    }
}
