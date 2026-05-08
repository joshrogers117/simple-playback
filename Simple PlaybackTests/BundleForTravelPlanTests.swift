import Foundation
import XCTest
@testable import Simple_Playback

/// Pure-logic coverage for the C7d Bundle for Travel planner + applier. Every
/// I/O dependency is injected; the live-filesystem path is exercised by the
/// host integration in RootView, not here.
final class BundleForTravelPlanTests: XCTestCase {

    // MARK: - plan

    func testPlanCollectsLinkedSlidesAndSkipsManaged() {
        let linked = makeSlide(title: "linked-clip", kind: .linked)
        var managed = makeSlide(title: "already-managed", kind: .linked)
        managed.media = MediaReference(
            url: URL(fileURLWithPath: "/bundle/Media/already-managed.mov"),
            fingerprint: nil,
            kind: .managed
        )

        let report = BundleForTravelPlan.plan(
            slides: [linked, managed],
            resolve: { ref in
                MediaResolutionResult(
                    url: URL(fileURLWithPath: ref.originalPath),
                    step: .original
                )
            },
            fileSize: { _ in 1_000 }
        )

        XCTAssertEqual(report.operations.count, 1)
        XCTAssertEqual(report.operations.first?.slideID, linked.id)
        XCTAssertEqual(report.alreadyManagedSlideIDs, [managed.id])
        XCTAssertEqual(report.offlineSlideIDs, [])
        XCTAssertEqual(report.totalBytes, 1_000)
    }

    func testPlanRecordsOfflineSlidesSeparately() {
        let onlineSlide = makeSlide(title: "online", kind: .linked)
        let offlineSlide = makeSlide(title: "offline", kind: .linked)

        let report = BundleForTravelPlan.plan(
            slides: [onlineSlide, offlineSlide],
            resolve: { ref in
                if ref.originalPath.contains("online") {
                    return MediaResolutionResult(
                        url: URL(fileURLWithPath: ref.originalPath),
                        step: .original
                    )
                }
                return .offline
            },
            fileSize: { _ in 200 }
        )

        XCTAssertEqual(report.operations.count, 1)
        XCTAssertEqual(report.operations.first?.slideID, onlineSlide.id)
        XCTAssertEqual(report.offlineSlideIDs, [offlineSlide.id])
    }

    func testPlanDeduplicatesCollidingFilenames() {
        // Two distinct slides whose source files share a basename ("intro.mov"
        // in different folders). The second must get a `-1` suffix.
        let firstURL = URL(fileURLWithPath: "/Footage/A/intro.mov")
        let secondURL = URL(fileURLWithPath: "/Footage/B/intro.mov")
        var firstSlide = makeSlide(title: "first")
        firstSlide.media = MediaReference(url: firstURL)
        var secondSlide = makeSlide(title: "second")
        secondSlide.media = MediaReference(url: secondURL)

        let report = BundleForTravelPlan.plan(
            slides: [firstSlide, secondSlide],
            resolve: { ref in
                MediaResolutionResult(
                    url: URL(fileURLWithPath: ref.originalPath),
                    step: .original
                )
            },
            fileSize: { _ in 100 }
        )

        XCTAssertEqual(report.operations.count, 2)
        XCTAssertEqual(report.operations[0].destinationFilename, "intro.mov")
        XCTAssertEqual(report.operations[1].destinationFilename, "intro-1.mov")
    }

    func testPlanCarriesResolverChosenURLNotOriginalPath() {
        // If the resolver returned a content-hash relink URL (i.e. the file
        // was found in a sister folder), the plan must copy from *that* URL,
        // not from the now-stale originalPath.
        let slide = makeSlide(title: "relinked", kind: .linked)
        let foundURL = URL(fileURLWithPath: "/Backup/relinked.mov")

        let report = BundleForTravelPlan.plan(
            slides: [slide],
            resolve: { _ in
                MediaResolutionResult(url: foundURL, step: .contentHash)
            },
            fileSize: { _ in 50 }
        )

        XCTAssertEqual(report.operations.first?.sourceURL, foundURL)
    }

    func testPlanTotalBytesSumsAcrossOperations() {
        let a = makeSlide(title: "a")
        let b = makeSlide(title: "b")
        let c = makeSlide(title: "c")

        let report = BundleForTravelPlan.plan(
            slides: [a, b, c],
            resolve: { ref in
                MediaResolutionResult(
                    url: URL(fileURLWithPath: ref.originalPath),
                    step: .original
                )
            },
            fileSize: { url in
                switch url.lastPathComponent {
                case "a.mov": return 100
                case "b.mov": return 200
                case "c.mov": return 400
                default: return nil
                }
            }
        )

        XCTAssertEqual(report.totalBytes, 700)
    }

    func testPlanWithEmptySlidesProducesEmptyReport() {
        let report = BundleForTravelPlan.plan(
            slides: [],
            resolve: { _ in .offline },
            fileSize: { _ in nil }
        )
        XCTAssertEqual(report, .empty)
    }

    // MARK: - apply

    func testApplyFlipsKindToManagedAndRewritesURL() {
        let slide = makeSlide(title: "to-bundle", kind: .linked)
        let mediaDir = URL(fileURLWithPath: "/bundle/Media")
        let plan = BundleForTravelPlanReport(
            operations: [BundleForTravelOperation(
                slideID: slide.id,
                sourceURL: URL(fileURLWithPath: "/Footage/to-bundle.mov"),
                destinationFilename: "to-bundle.mov"
            )],
            alreadyManagedSlideIDs: [],
            offlineSlideIDs: [],
            totalBytes: 100
        )

        let updated = BundleForTravelPlan.apply(
            plan: plan,
            to: [slide],
            mediaDirectoryURL: mediaDir,
            fingerprint: { url in
                MediaAssetFingerprint(
                    contentHash: "managed-\(url.lastPathComponent)",
                    size: 100,
                    mtime: Date(timeIntervalSince1970: 1)
                )
            }
        )

        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].media.kind, .managed)
        XCTAssertEqual(updated[0].media.originalPath, "/bundle/Media/to-bundle.mov")
        XCTAssertEqual(updated[0].media.fingerprint?.contentHash, "managed-to-bundle.mov")
    }

    func testApplyPreservesSlidesNotInPlan() {
        let bundled = makeSlide(title: "bundled")
        let untouched = makeSlide(title: "untouched")
        let mediaDir = URL(fileURLWithPath: "/bundle/Media")

        let plan = BundleForTravelPlanReport(
            operations: [BundleForTravelOperation(
                slideID: bundled.id,
                sourceURL: URL(fileURLWithPath: "/x/bundled.mov"),
                destinationFilename: "bundled.mov"
            )],
            alreadyManagedSlideIDs: [],
            offlineSlideIDs: [untouched.id],
            totalBytes: 0
        )

        let updated = BundleForTravelPlan.apply(
            plan: plan,
            to: [bundled, untouched],
            mediaDirectoryURL: mediaDir,
            fingerprint: { _ in nil }
        )

        XCTAssertEqual(updated[0].media.kind, .managed)
        XCTAssertEqual(updated[1].media.kind, .linked,
                       "Slides not in the plan must round-trip unchanged.")
        XCTAssertEqual(updated[1].media.originalPath, untouched.media.originalPath)
    }

    func testApplyShortcircuitsForEmptyPlan() {
        let slides = [makeSlide(title: "a"), makeSlide(title: "b")]
        let mediaDir = URL(fileURLWithPath: "/bundle/Media")
        let result = BundleForTravelPlan.apply(
            plan: .empty,
            to: slides,
            mediaDirectoryURL: mediaDir,
            fingerprint: { _ in
                XCTFail("Empty plan should not call fingerprint().")
                return nil
            }
        )
        XCTAssertEqual(result, slides)
    }

    func testApplyUsesDeduplicatedDestinationFilename() {
        // The planner deduplicates filenames; apply must honor whatever the
        // plan recorded, not re-derive from sourceURL.
        let slide = makeSlide(title: "dup")
        let mediaDir = URL(fileURLWithPath: "/bundle/Media")
        let plan = BundleForTravelPlanReport(
            operations: [BundleForTravelOperation(
                slideID: slide.id,
                sourceURL: URL(fileURLWithPath: "/Footage/intro.mov"),
                destinationFilename: "intro-3.mov"
            )],
            alreadyManagedSlideIDs: [],
            offlineSlideIDs: [],
            totalBytes: 0
        )

        let updated = BundleForTravelPlan.apply(
            plan: plan,
            to: [slide],
            mediaDirectoryURL: mediaDir,
            fingerprint: { _ in nil }
        )

        XCTAssertEqual(updated[0].media.originalPath, "/bundle/Media/intro-3.mov")
    }

    // MARK: - uniqueFilename

    func testUniqueFilenameKeepsFirstClaimantUnsuffixed() {
        XCTAssertEqual(
            BundleForTravelPlan.uniqueFilename(for: "intro.mov", claimed: []),
            "intro.mov"
        )
    }

    func testUniqueFilenameInsertsCounterBeforeExtension() {
        let claimed: Set<String> = ["intro.mov"]
        XCTAssertEqual(
            BundleForTravelPlan.uniqueFilename(for: "intro.mov", claimed: claimed),
            "intro-1.mov"
        )
    }

    func testUniqueFilenameKeepsCountingPastCollisions() {
        let claimed: Set<String> = ["intro.mov", "intro-1.mov", "intro-2.mov"]
        XCTAssertEqual(
            BundleForTravelPlan.uniqueFilename(for: "intro.mov", claimed: claimed),
            "intro-3.mov"
        )
    }

    func testUniqueFilenameHandlesNoExtension() {
        let claimed: Set<String> = ["README"]
        XCTAssertEqual(
            BundleForTravelPlan.uniqueFilename(for: "README", claimed: claimed),
            "README-1"
        )
    }

    // MARK: - helpers

    private func makeSlide(title: String, kind: MediaReferenceKind = .linked) -> MediaSlide {
        var slide = MediaSlide(
            url: URL(fileURLWithPath: "/tmp/\(title).mov"),
            mediaKind: .video
        )
        slide.title = title
        if kind != .linked {
            slide.media = MediaReference(
                url: URL(fileURLWithPath: "/tmp/\(title).mov"),
                fingerprint: slide.media.fingerprint,
                kind: kind
            )
        }
        return slide
    }
}
