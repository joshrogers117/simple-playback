import Foundation
import XCTest
@testable import Simple_Playback

/// v2 Post-Show Summary Q4-B — pin that `ProjectLockController` fires its
/// `onForeignLockDetected` callback once per first detection of a live
/// foreign lock, with the lock's hostname + pid available to the host so
/// the show log can attribute the event. Re-evaluating with the same lock
/// must NOT re-fire (the post-show summary's systemEvents would otherwise
/// duplicate one row per UI re-render).
@MainActor
final class ProjectLockForeignLogTests: XCTestCase {

    private var bundleA: URL { URL(fileURLWithPath: "/tmp/lockfork.spb") }

    private func makeController(
        existingLock: ProjectLockFile? = nil,
        signals: ProjectLockFileSignals = ProjectLockFileSignals(pid: 100, hostname: "host-A", applicationVersion: "0.1.0")
    ) -> ProjectLockController {
        var lockMap: [URL: ProjectLockFile] = [:]
        if let existingLock {
            lockMap[ProjectLockFileIO.lockURL(in: bundleA)] = existingLock
        }
        return ProjectLockController(
            signalsProvider: { signals },
            isPIDAlive: { _ in true },
            now: { Date() },
            reader: { url in lockMap[ProjectLockFileIO.lockURL(in: url)] },
            writer: { lock, url in lockMap[ProjectLockFileIO.lockURL(in: url)] = lock },
            remover: { url in lockMap[ProjectLockFileIO.lockURL(in: url)] = nil }
        )
    }

    func testForeignLockDetectionFiresCallbackWithLockDetails() {
        let foreign = ProjectLockFile(
            pid: 4242,
            hostname: "host-XX",
            timestamp: Date(),
            applicationVersion: "1.0.0"
        )
        let controller = makeController(existingLock: foreign)
        var captured: [ProjectLockFile] = []
        controller.onForeignLockDetected = { captured.append($0) }
        controller.evaluate(bundleURL: bundleA)
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.hostname, "host-XX")
        XCTAssertEqual(captured.first?.pid, 4242)
    }

    func testReevaluatingSameLockDoesNotRefireCallback() {
        let foreign = ProjectLockFile(
            pid: 4242,
            hostname: "host-XX",
            timestamp: Date(),
            applicationVersion: nil
        )
        let controller = makeController(existingLock: foreign)
        var fireCount = 0
        controller.onForeignLockDetected = { _ in fireCount += 1 }
        controller.evaluate(bundleURL: bundleA)
        controller.evaluate(bundleURL: bundleA)
        controller.evaluate(bundleURL: bundleA)
        XCTAssertEqual(fireCount, 1, "Repeat evaluations against the same foreign lock must not duplicate log rows.")
    }

    func testCallbackNotFiredWhenNoForeignLockDetected() {
        // No existing lock — controller acquires; no callback.
        let controller = makeController()
        var fireCount = 0
        controller.onForeignLockDetected = { _ in fireCount += 1 }
        controller.evaluate(bundleURL: bundleA)
        XCTAssertEqual(fireCount, 0)
    }

    func testLockFileForeignActionFiltersAsSystemEvent() {
        XCTAssertTrue(ShowLog.ActionFilter.systemEvents.matches(.lockFileForeign))
        XCTAssertFalse(ShowLog.ActionFilter.runtimeVerbs.matches(.lockFileForeign))
        XCTAssertEqual(ShowLogEvent.Action.lockFileForeign.rawValue, "LOCK_FOREIGN")
    }

    func testPostShowSummaryCollectsLockFileForeignAsSystemEvent() {
        // Round-trip — emission shape ends up in the right reducer bucket.
        let event = ShowLogEvent(
            timestamp: Date(),
            chaseTimecode: nil,
            action: .lockFileForeign,
            source: .system,
            detail: "host=host-XX pid=4242"
        )
        let summary = PostShowSummary.from(events: [event])
        XCTAssertEqual(summary.systemEvents.count, 1)
        XCTAssertEqual(summary.systemEvents.first?.action, .lockFileForeign)
        XCTAssertEqual(summary.systemEvents.first?.detail, "host=host-XX pid=4242")
    }
}
