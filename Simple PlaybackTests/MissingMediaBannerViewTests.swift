import Foundation
import XCTest
@testable import Simple_Playback

/// Pure-logic coverage for the banner's text helpers. The banner itself is
/// presentation-only; the recomputation lives in RootView via
/// `AssetLibraryProbe.evaluate` and is covered by AssetLibraryProbeTests.
final class MissingMediaBannerViewTests: XCTestCase {

    func testHeadlineSingularPlural() {
        let one = MissingMediaBannerView(
            status: AssetLibraryStatus(offlineSlideCount: 1),
            onRelink: {},
            canRelink: true
        )
        let many = MissingMediaBannerView(
            status: AssetLibraryStatus(offlineSlideCount: 7),
            onRelink: {},
            canRelink: true
        )
        XCTAssertEqual(one.headline, "1 media item offline")
        XCTAssertEqual(many.headline, "7 media items offline")
    }

    func testSubheadShowsPreviewTitlesOnly() {
        let banner = MissingMediaBannerView(
            status: AssetLibraryStatus(
                offlineSlideCount: 2,
                offlineSlideTitles: ["intro", "outro"]
            ),
            onRelink: {},
            canRelink: true
        )
        XCTAssertEqual(banner.subhead, "intro, outro")
    }

    func testSubheadAppendsAndNMoreWhenPreviewBounded() {
        // AssetLibraryProbe caps offlineSlideTitles at `previewLimit` (3 by
        // default). For projects with more offline slides than the cap, the
        // banner should communicate the overflow.
        let banner = MissingMediaBannerView(
            status: AssetLibraryStatus(
                offlineSlideCount: 10,
                offlineSlideTitles: ["a", "b", "c"]
            ),
            onRelink: {},
            canRelink: true
        )
        XCTAssertEqual(banner.subhead, "a, b, c, and 7 more")
    }
}
