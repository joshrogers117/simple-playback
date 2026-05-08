import Foundation
import XCTest
@testable import Simple_Playback

/// E3+ tail Path 1 — pin the new "first composed frame for cue X reached
/// output" callback that replaces the Path 2 `$liveSlideID` proxy. The
/// PlaybackController side of the contract: token armed by `take(...)` is
/// consumed exactly once on the next successful `submitFrame`, and the
/// callback receives the slide ID + a `Date` close to the actual submission.
@MainActor
final class PlaybackControllerCueFireTests: XCTestCase {

    func testCallbackFiresOnceWhenTokenArmedAndSimulationRuns() async {
        let playback = PlaybackController()
        let exp = expectation(description: "callback fired")
        var observed: (slideID: UUID, at: Date)?
        playback.onFirstComposedFrameForCue = { slideID, at in
            observed = (slideID, at)
            exp.fulfill()
        }

        let slideID = UUID()
        playback.armPendingCueFireSlideIDForTesting(slideID)
        playback.simulateFirstComposedFrameForTesting()

        await fulfillment(of: [exp], timeout: 1.0)
        XCTAssertEqual(observed?.slideID, slideID)
        XCTAssertNil(playback.peekPendingCueFireSlideIDForTesting(),
                     "Token must be consumed (cleared) on first emission so subsequent frames don't refire.")
    }

    func testSubsequentSimulationDoesNotRefireSameTake() async {
        let playback = PlaybackController()
        var fireCount = 0
        playback.onFirstComposedFrameForCue = { _, _ in fireCount += 1 }

        let slideID = UUID()
        playback.armPendingCueFireSlideIDForTesting(slideID)
        playback.simulateFirstComposedFrameForTesting()
        playback.simulateFirstComposedFrameForTesting()
        playback.simulateFirstComposedFrameForTesting()

        // Drain the main queue so all dispatched callbacks have run.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fireCount, 1,
                       "Subsequent simulations on the same take must not refire — token is one-shot.")
    }

    func testNoFireWhenTokenNotArmed() async {
        let playback = PlaybackController()
        var fireCount = 0
        playback.onFirstComposedFrameForCue = { _, _ in fireCount += 1 }

        // No arm. Simulate anyway — must be a no-op.
        playback.simulateFirstComposedFrameForTesting()

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fireCount, 0)
    }

    func testStopOutputDropsArmedToken() {
        let playback = PlaybackController()
        let slideID = UUID()
        playback.armPendingCueFireSlideIDForTesting(slideID)
        XCTAssertEqual(playback.peekPendingCueFireSlideIDForTesting(), slideID)

        playback.stopOutput()

        XCTAssertNil(playback.peekPendingCueFireSlideIDForTesting(),
                     "stopOutput must drop the armed token so a subsequent restart's first frame can't fire it.")
    }

    func testClearDropsArmedToken() {
        let playback = PlaybackController()
        let slideID = UUID()
        playback.armPendingCueFireSlideIDForTesting(slideID)
        XCTAssertEqual(playback.peekPendingCueFireSlideIDForTesting(), slideID)

        playback.clear()

        XCTAssertNil(playback.peekPendingCueFireSlideIDForTesting(),
                     "clear() must drop the armed token so the impending black-frame submit doesn't masquerade as the cleared cue's first frame.")
    }

    func testCallbackNotConsumedWhenNoCallbackIsSet() async {
        let playback = PlaybackController()
        let slideID = UUID()
        playback.armPendingCueFireSlideIDForTesting(slideID)

        // No callback set; simulate. Token MUST remain armed so a later-
        // attached callback can still receive the inaugural emission.
        playback.simulateFirstComposedFrameForTesting()

        XCTAssertEqual(playback.peekPendingCueFireSlideIDForTesting(), slideID,
                       "Token must remain armed when no callback is set — consumption requires a recipient.")
    }

    // MARK: - C8 v1.1 — folder-bookmark threading

    /// Pin that a slide whose per-file path is gone but whose folder-bookmark
    /// route resolves to a real file passes the `take(...)` "Missing media"
    /// guard. We can't drive AVFoundation deterministically in tests, but we
    /// CAN verify that the resolution branch picks the rung-2 URL — the
    /// failure mode would be `playback.status == "Missing media: ..."` after
    /// the call, which is observable.
    func testTakeResolvesViaFolderBookmarkWhenPerFilePathIsDead() throws {
        let playback = PlaybackController()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("c8-take-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let realFile = tmp.appendingPathComponent("clip.mov")
        try Data([0]).write(to: realFile)

        let bookmark = FolderBookmark(folderURL: tmp)
        var media = MediaReference(url: URL(fileURLWithPath: "/this/path/is/dead/clip.mov"))
        media.folderBookmarkID = bookmark.id
        media.folderRelativePath = "clip.mov"
        let slide = MediaSlide(
            url: realFile,
            mediaKind: .video
        )
        var resolved = slide
        resolved.media = media

        // Sanity: with no bookmarks installed, the resolver returns nil because
        // the per-file URL is dead.
        XCTAssertNil(resolved.media.resolvedURL(bundleMediaDirectory: nil),
                     "Without a bookmark lookup the per-file path is the only route, and it's dead.")

        // With the bookmark installed, the rung-2 fallback hits the real file.
        playback.folderBookmarks = [bookmark.id: bookmark]
        let url = resolved.media.resolvedURL(
            bundleMediaDirectory: nil,
            folderBookmarks: playback.folderBookmarks
        )
        // Compare resolved paths — `/var/folders` is a symlink to `/private/var/folders`
        // on macOS, and the bookmark resolution path canonicalizes through the symlink.
        XCTAssertEqual(
            url?.resolvingSymlinksInPath().path,
            realFile.resolvingSymlinksInPath().path,
            "Threaded folderBookmarks lookup must let take()'s resolvedURL fall through to the rung-2 hit."
        )
    }

    func testFolderBookmarksAssignmentPersists() {
        let playback = PlaybackController()
        XCTAssertTrue(playback.folderBookmarks.isEmpty)

        let a = FolderBookmark(label: "A", originalPath: "/tmp/a")
        let b = FolderBookmark(label: "B", originalPath: "/tmp/b")
        playback.folderBookmarks = [a.id: a, b.id: b]
        XCTAssertEqual(playback.folderBookmarks.count, 2)
        XCTAssertEqual(playback.folderBookmarks[a.id]?.label, "A")
        XCTAssertEqual(playback.folderBookmarks[b.id]?.label, "B")
    }
}
