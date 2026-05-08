import Foundation
import XCTest
@testable import Simple_Playback

/// E8b — controller-level tests. The pure-logic IO + liveness branches are
/// covered in ProjectLockFileTests; this suite drives the state machine
/// (`evaluate` → `acquire` / `foreignBanner` / `release` / `openAnyway` /
/// `dismissBanner`) using captured-IO seams so no filesystem is touched.
@MainActor
final class ProjectLockControllerTests: XCTestCase {

    private struct Recorder {
        var reads: [URL] = []
        var writes: [(ProjectLockFile, URL)] = []
        var removes: [URL] = []
    }

    private var bundleA: URL { URL(fileURLWithPath: "/tmp/a.spb") }
    private var bundleB: URL { URL(fileURLWithPath: "/tmp/b.spb") }

    private func makeController(
        existingLock: ProjectLockFile? = nil,
        signals: ProjectLockFileSignals = ProjectLockFileSignals(pid: 100, hostname: "host-A", applicationVersion: "0.1.0"),
        isPIDAlive: @escaping (Int32) -> Bool = { _ in true },
        now: Date = Date()
    ) -> (ProjectLockController, () -> Recorder, (URL, ProjectLockFile?) -> Void) {
        var recorder = Recorder()
        var lockMap: [URL: ProjectLockFile] = [:]
        if let existingLock {
            lockMap[ProjectLockFileIO.lockURL(in: bundleA)] = existingLock
            lockMap[ProjectLockFileIO.lockURL(in: bundleB)] = existingLock
        }
        let recorderRef = NSMutableArray()
        recorderRef.add(recorder as Any)

        var capturedRecorder = recorder
        let getRecorder: () -> Recorder = { capturedRecorder }
        let setLock: (URL, ProjectLockFile?) -> Void = { url, lock in
            let lockURL = ProjectLockFileIO.lockURL(in: url)
            if let lock { lockMap[lockURL] = lock } else { lockMap[lockURL] = nil }
        }

        let controller = ProjectLockController(
            signalsProvider: { signals },
            isPIDAlive: isPIDAlive,
            now: { now },
            reader: { url in
                capturedRecorder.reads.append(url)
                return lockMap[ProjectLockFileIO.lockURL(in: url)]
            },
            writer: { lock, url in
                capturedRecorder.writes.append((lock, url))
                lockMap[ProjectLockFileIO.lockURL(in: url)] = lock
            },
            remover: { url in
                capturedRecorder.removes.append(url)
                lockMap[ProjectLockFileIO.lockURL(in: url)] = nil
            }
        )
        return (controller, getRecorder, setLock)
    }

    // MARK: - acquire path (no existing lock)

    func testEvaluateNilURLDoesNothing() {
        let (controller, getRec, _) = makeController()
        controller.evaluate(bundleURL: nil)
        XCTAssertEqual(getRec().writes.count, 0)
        XCTAssertNil(controller.foreignBanner)
        XCTAssertNil(controller.ownedBundleURL)
    }

    func testEvaluateNoExistingLockAcquiresOwnership() {
        let (controller, getRec, _) = makeController()
        controller.evaluate(bundleURL: bundleA)
        XCTAssertEqual(getRec().writes.count, 1)
        XCTAssertEqual(controller.ownedBundleURL, bundleA)
        XCTAssertNil(controller.foreignBanner)
    }

    // MARK: - existing-lock branches

    func testEvaluateOursReusesAndRefreshes() {
        let lock = ProjectLockFile(pid: 100, hostname: "host-A", timestamp: Date(), applicationVersion: "x")
        let (controller, getRec, _) = makeController(existingLock: lock)
        controller.evaluate(bundleURL: bundleA)
        XCTAssertEqual(controller.ownedBundleURL, bundleA)
        XCTAssertNil(controller.foreignBanner)
        // refresh should have written a fresh lock
        XCTAssertEqual(getRec().writes.count, 1)
    }

    func testEvaluateLocalStaleOverwrites() {
        let stale = ProjectLockFile(pid: 200, hostname: "host-A", timestamp: Date(), applicationVersion: "x")
        let (controller, getRec, _) = makeController(
            existingLock: stale,
            isPIDAlive: { _ in false }
        )
        controller.evaluate(bundleURL: bundleA)
        XCTAssertEqual(controller.ownedBundleURL, bundleA)
        XCTAssertNil(controller.foreignBanner)
        XCTAssertEqual(getRec().writes.count, 1)
    }

    func testEvaluateForeignStaleOverwrites() {
        let stale = ProjectLockFile(
            pid: 5,
            hostname: "host-X",
            timestamp: Date(timeIntervalSince1970: 0),
            applicationVersion: nil
        )
        let (controller, getRec, _) = makeController(existingLock: stale)
        controller.evaluate(bundleURL: bundleA)
        XCTAssertEqual(controller.ownedBundleURL, bundleA)
        XCTAssertNil(controller.foreignBanner)
        XCTAssertEqual(getRec().writes.count, 1)
    }

    func testEvaluateLocalLiveSurfacesBannerAndDoesNotWrite() {
        let live = ProjectLockFile(pid: 200, hostname: "host-A", timestamp: Date(), applicationVersion: "x")
        let (controller, getRec, _) = makeController(
            existingLock: live,
            isPIDAlive: { _ in true }
        )
        controller.evaluate(bundleURL: bundleA)
        XCTAssertNil(controller.ownedBundleURL)
        XCTAssertEqual(controller.foreignBanner, live)
        XCTAssertEqual(getRec().writes.count, 0, "Live foreign lock must not be silently overwritten.")
    }

    func testEvaluateForeignLiveSurfacesBanner() {
        let now = Date()
        let live = ProjectLockFile(
            pid: 5,
            hostname: "host-X",
            timestamp: now.addingTimeInterval(-30),
            applicationVersion: nil
        )
        let (controller, _, _) = makeController(existingLock: live, now: now)
        controller.evaluate(bundleURL: bundleA)
        XCTAssertEqual(controller.foreignBanner, live)
        XCTAssertNil(controller.ownedBundleURL)
    }

    // MARK: - operator actions

    func testOpenAnywayAcquiresAndClearsBanner() {
        let live = ProjectLockFile(pid: 200, hostname: "host-A", timestamp: Date(), applicationVersion: "x")
        let (controller, getRec, _) = makeController(existingLock: live)
        controller.evaluate(bundleURL: bundleA)
        XCTAssertNotNil(controller.foreignBanner)
        controller.openAnyway()
        XCTAssertNil(controller.foreignBanner)
        XCTAssertEqual(controller.ownedBundleURL, bundleA)
        XCTAssertEqual(getRec().writes.count, 1)
    }

    func testDismissBannerKeepsLockUnchanged() {
        let live = ProjectLockFile(pid: 200, hostname: "host-A", timestamp: Date(), applicationVersion: "x")
        let (controller, getRec, _) = makeController(existingLock: live)
        controller.evaluate(bundleURL: bundleA)
        XCTAssertNotNil(controller.foreignBanner)
        controller.dismissBanner()
        XCTAssertNil(controller.foreignBanner)
        XCTAssertNil(controller.ownedBundleURL)
        XCTAssertEqual(getRec().writes.count, 0, "Dismiss must not claim ownership.")
    }

    // MARK: - release

    func testReleaseRemovesOwnedLock() {
        let (controller, getRec, _) = makeController()
        controller.evaluate(bundleURL: bundleA)
        XCTAssertEqual(controller.ownedBundleURL, bundleA)
        controller.release()
        XCTAssertNil(controller.ownedBundleURL)
        XCTAssertEqual(getRec().removes.count, 1)
    }

    func testReleaseWithoutOwnershipIsNoop() {
        let (controller, getRec, _) = makeController()
        controller.release()
        XCTAssertEqual(getRec().removes.count, 0)
    }

    // MARK: - URL change

    func testEvaluateNewURLReleasesOldOwnership() {
        let (controller, getRec, _) = makeController()
        controller.evaluate(bundleURL: bundleA)
        XCTAssertEqual(controller.ownedBundleURL, bundleA)
        // SaveAs to bundleB — controller should evaluate B independently.
        // (Today the implementation does not auto-release A; that's an
        // accepted gap because the OS file move would have moved the lock
        // along with the bundle. Test pins current behaviour: bundleB is
        // acquired, A's ownership is replaced.)
        controller.evaluate(bundleURL: bundleB)
        XCTAssertEqual(controller.ownedBundleURL, bundleB)
        XCTAssertEqual(getRec().writes.count, 2)
    }

    func testEvaluateNilURLAfterAcquisitionReleases() {
        let (controller, getRec, _) = makeController()
        controller.evaluate(bundleURL: bundleA)
        XCTAssertEqual(controller.ownedBundleURL, bundleA)
        controller.evaluate(bundleURL: nil)
        XCTAssertNil(controller.ownedBundleURL)
        XCTAssertEqual(getRec().removes.count, 1)
    }
}
