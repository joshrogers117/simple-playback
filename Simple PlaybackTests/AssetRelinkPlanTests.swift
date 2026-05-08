import Foundation
import XCTest
@testable import Simple_Playback

final class AssetRelinkPlanTests: XCTestCase {

    // MARK: - plan

    func testPlanRecordsHashAndNameAndSizeUpdates() {
        let hashSlide = makeSlide(title: "hash-source")
        let nameSizeSlide = makeSlide(title: "name-source")
        let onlineSlide = makeSlide(title: "online")
        let offlineSlide = makeSlide(title: "offline")

        let resolved: [URL] = [
            URL(fileURLWithPath: "/relink/hash-target.mov"),
            URL(fileURLWithPath: "/relink/name-target.mov")
        ]

        let resolve: (MediaReference, [URL]) -> MediaResolutionResult = { reference, _ in
            switch reference.originalPath {
            case "/tmp/hash-source.mov":
                return MediaResolutionResult(url: resolved[0], step: .contentHash)
            case "/tmp/name-source.mov":
                return MediaResolutionResult(url: resolved[1], step: .nameAndSize)
            case "/tmp/online.mov":
                return MediaResolutionResult(
                    url: URL(fileURLWithPath: "/tmp/online.mov"),
                    step: .original
                )
            default:
                return .offline
            }
        }

        let report = AssetRelinkPlan.plan(
            slides: [hashSlide, nameSizeSlide, onlineSlide, offlineSlide],
            searchRoots: [URL(fileURLWithPath: "/relink")],
            resolve: resolve
        )

        XCTAssertEqual(report.updates.count, 2)
        XCTAssertEqual(report.contentHashCount, 1)
        XCTAssertEqual(report.nameAndSizeCount, 1)
        XCTAssertEqual(report.unchangedOnlineSlideIDs, [onlineSlide.id])
        XCTAssertEqual(report.stillOfflineSlideIDs, [offlineSlide.id])
        XCTAssertEqual(report.updates.first?.newURL.path, "/relink/hash-target.mov")
    }

    func testPlanWithEmptySlidesProducesEmptyReport() {
        let report = AssetRelinkPlan.plan(
            slides: [],
            searchRoots: [URL(fileURLWithPath: "/relink")],
            resolve: { _, _ in .offline }
        )
        XCTAssertEqual(report.updates, [])
        XCTAssertEqual(report.stillOfflineSlideIDs, [])
        XCTAssertEqual(report.unchangedOnlineSlideIDs, [])
    }

    func testPlanIsResilientToResolverReturningNilURLForNonOfflineStep() {
        // Defensive: if the resolver violates its contract and returns
        // .contentHash with a nil URL, the plan treats that slide as still
        // offline rather than crashing or skipping silently.
        let slide = makeSlide(title: "broken-resolver")
        let report = AssetRelinkPlan.plan(
            slides: [slide],
            searchRoots: [URL(fileURLWithPath: "/x")],
            resolve: { _, _ in MediaResolutionResult(url: nil, step: .contentHash) }
        )

        XCTAssertEqual(report.updates, [])
        XCTAssertEqual(report.stillOfflineSlideIDs, [slide.id])
    }

    // MARK: - apply

    func testApplyRewritesMediaReferenceAndRefreshesFingerprint() {
        var slide = makeSlide(title: "to-relink")
        slide.media.fingerprint = MediaAssetFingerprint(
            contentHash: "stale-hash",
            size: 100,
            mtime: Date(timeIntervalSince1970: 1)
        )

        let newURL = URL(fileURLWithPath: "/relink/found.mov")
        let plan = AssetRelinkPlanReport(
            updates: [AssetRelinkUpdate(slideID: slide.id, newURL: newURL, step: .contentHash)],
            stillOfflineSlideIDs: [],
            unchangedOnlineSlideIDs: []
        )

        let updated = AssetRelinkPlan.apply(
            plan: plan,
            to: [slide],
            fingerprint: { url in
                MediaAssetFingerprint(
                    contentHash: "fresh-\(url.lastPathComponent)",
                    size: 200,
                    mtime: Date(timeIntervalSince1970: 999)
                )
            }
        )

        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].media.originalPath, newURL.path)
        XCTAssertEqual(updated[0].media.fingerprint?.contentHash, "fresh-found.mov")
        XCTAssertEqual(updated[0].media.fingerprint?.size, 200)
    }

    func testApplyPreservesUnchangedSlides() {
        let unchanged = makeSlide(title: "unchanged")
        let originalRef = unchanged.media

        let plan = AssetRelinkPlanReport(
            updates: [],
            stillOfflineSlideIDs: [],
            unchangedOnlineSlideIDs: [unchanged.id]
        )

        let result = AssetRelinkPlan.apply(plan: plan, to: [unchanged], fingerprint: { _ in nil })

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].media, originalRef,
                       "Slides not in the plan must round-trip unchanged.")
    }

    func testApplyShortcircuitsForEmptyPlan() {
        let slides = [makeSlide(title: "a"), makeSlide(title: "b")]
        let plan = AssetRelinkPlanReport(
            updates: [],
            stillOfflineSlideIDs: [slides[0].id],
            unchangedOnlineSlideIDs: [slides[1].id]
        )

        let result = AssetRelinkPlan.apply(plan: plan, to: slides, fingerprint: { _ in
            XCTFail("Empty plan should not call fingerprint().")
            return nil
        })

        XCTAssertEqual(result, slides)
    }

    // MARK: - kind inference (bundle-aware)

    func testInferKindReturnsExistingWhenBundleDirectoryNil() {
        // Untitled documents pass nil — preserving the existing kind is the
        // only safe behavior when the bundle URL is unknown.
        XCTAssertEqual(
            AssetRelinkPlan.inferKind(
                existing: .managed,
                newURL: URL(fileURLWithPath: "/anywhere/clip.mov"),
                bundleMediaDirectory: nil
            ),
            .managed
        )
        XCTAssertEqual(
            AssetRelinkPlan.inferKind(
                existing: .linked,
                newURL: URL(fileURLWithPath: "/Bundle/Media/clip.mov"),
                bundleMediaDirectory: nil
            ),
            .linked
        )
    }

    func testInferKindFlipsToManagedWhenURLIsInsideBundleMedia() {
        let bundleMedia = URL(fileURLWithPath: "/Show.spb/Media")
        let newURL = URL(fileURLWithPath: "/Show.spb/Media/intro.mov")
        XCTAssertEqual(
            AssetRelinkPlan.inferKind(
                existing: .linked,
                newURL: newURL,
                bundleMediaDirectory: bundleMedia
            ),
            .managed
        )
    }

    func testInferKindFlipsToLinkedWhenURLIsOutsideBundleMedia() {
        // A `.managed` slide relinked to a file outside the bundle must flip
        // to `.linked`. Pre-fix, the kind stayed `.managed` and rung 0 of
        // MediaResolver silently failed to find the file.
        let bundleMedia = URL(fileURLWithPath: "/Show.spb/Media")
        let newURL = URL(fileURLWithPath: "/Footage/intro.mov")
        XCTAssertEqual(
            AssetRelinkPlan.inferKind(
                existing: .managed,
                newURL: newURL,
                bundleMediaDirectory: bundleMedia
            ),
            .linked
        )
    }

    func testInferKindHandlesSiblingDirectoryWithSharedPrefix() {
        // /Show.spb/MediaCache vs /Show.spb/Media — string-prefix logic
        // would falsely accept the first as inside the second. Path-component
        // comparison must reject it.
        let bundleMedia = URL(fileURLWithPath: "/Show.spb/Media")
        let newURL = URL(fileURLWithPath: "/Show.spb/MediaCache/intro.mov")
        XCTAssertEqual(
            AssetRelinkPlan.inferKind(
                existing: .managed,
                newURL: newURL,
                bundleMediaDirectory: bundleMedia
            ),
            .linked
        )
    }

    func testInferKindRejectsURLEqualToBundleDirectoryItself() {
        // Edge case: newURL exactly equals the bundle Media directory. Not a
        // descendant — must classify as linked rather than managed.
        let bundleMedia = URL(fileURLWithPath: "/Show.spb/Media")
        XCTAssertEqual(
            AssetRelinkPlan.inferKind(
                existing: .managed,
                newURL: bundleMedia,
                bundleMediaDirectory: bundleMedia
            ),
            .linked
        )
    }

    func testApplyFlipsKindToManagedWhenRelinkLandsInsideBundle() {
        var slide = makeSlide(title: "linked-asset")
        slide.media = MediaReference(
            url: URL(fileURLWithPath: "/tmp/old.mov"),
            fingerprint: nil,
            kind: .linked
        )

        let bundleMedia = URL(fileURLWithPath: "/Show.spb/Media")
        let newURL = bundleMedia.appendingPathComponent("relinked.mov")

        let plan = AssetRelinkPlanReport(
            updates: [AssetRelinkUpdate(slideID: slide.id, newURL: newURL, step: .nameAndSize)],
            stillOfflineSlideIDs: [],
            unchangedOnlineSlideIDs: []
        )

        let updated = AssetRelinkPlan.apply(
            plan: plan,
            to: [slide],
            bundleMediaDirectory: bundleMedia,
            fingerprint: { _ in nil }
        )
        XCTAssertEqual(updated[0].media.kind, .managed,
                       "Relinking inside the bundle Media directory should flip to .managed.")
    }

    func testApplyFlipsKindToLinkedWhenManagedRelinkLandsOutsideBundle() {
        var slide = makeSlide(title: "managed-asset")
        slide.media = MediaReference(
            url: URL(fileURLWithPath: "/Show.spb/Media/managed.mov"),
            fingerprint: nil,
            kind: .managed
        )

        let bundleMedia = URL(fileURLWithPath: "/Show.spb/Media")
        let newURL = URL(fileURLWithPath: "/Footage/managed.mov")

        let plan = AssetRelinkPlanReport(
            updates: [AssetRelinkUpdate(slideID: slide.id, newURL: newURL, step: .contentHash)],
            stillOfflineSlideIDs: [],
            unchangedOnlineSlideIDs: []
        )

        let updated = AssetRelinkPlan.apply(
            plan: plan,
            to: [slide],
            bundleMediaDirectory: bundleMedia,
            fingerprint: { _ in nil }
        )
        XCTAssertEqual(updated[0].media.kind, .linked,
                       "A managed slide relinked outside the bundle must flip to .linked.")
    }

    func testApplyPreservesMediaReferenceKind() {
        var slide = makeSlide(title: "managed-asset")
        slide.media = MediaReference(
            url: URL(fileURLWithPath: "/tmp/managed.mov"),
            fingerprint: nil,
            kind: .managed
        )

        let plan = AssetRelinkPlanReport(
            updates: [AssetRelinkUpdate(
                slideID: slide.id,
                newURL: URL(fileURLWithPath: "/relink/managed.mov"),
                step: .contentHash
            )],
            stillOfflineSlideIDs: [],
            unchangedOnlineSlideIDs: []
        )

        let updated = AssetRelinkPlan.apply(plan: plan, to: [slide], fingerprint: { _ in nil })
        XCTAssertEqual(updated[0].media.kind, .managed,
                       "Relink should preserve managed-vs-linked status.")
    }

    // MARK: - helpers

    private func makeSlide(title: String) -> MediaSlide {
        var slide = MediaSlide(
            url: URL(fileURLWithPath: "/tmp/\(title).mov"),
            mediaKind: .video
        )
        slide.title = title
        return slide
    }
}
