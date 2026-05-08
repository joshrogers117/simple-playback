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

    // MARK: - helpers

    private func makeSlide(title: String) -> MediaSlide {
        let url = URL(fileURLWithPath: "/tmp/\(title).mov")
        var slide = MediaSlide(url: url, mediaKind: .video)
        slide.title = title
        return slide
    }
}
