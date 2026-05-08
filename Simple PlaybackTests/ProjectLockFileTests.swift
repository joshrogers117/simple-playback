import Foundation
import XCTest
@testable import Simple_Playback

/// E8 — project lock file. Tests pin the pure-logic liveness evaluator (every
/// branch — ours / localLive / localStale / foreignLive / foreignStale), the
/// IO seams (read returns nil for missing/garbage; write/remove round-trip),
/// and the banner-copy contract.
final class ProjectLockFileTests: XCTestCase {

    private func makeLock(
        pid: Int32 = 12_345,
        hostname: String = "host-A.local",
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        applicationVersion: String? = "0.1.2"
    ) -> ProjectLockFile {
        ProjectLockFile(
            pid: pid,
            hostname: hostname,
            timestamp: timestamp,
            applicationVersion: applicationVersion
        )
    }

    // MARK: - liveness

    func testLivenessOursWhenSamePIDAndHostname() {
        let lock = makeLock(pid: 100, hostname: "h")
        let liveness = lock.liveness(
            now: Date(),
            currentPID: 100,
            currentHostname: "h",
            isPIDAlive: { _ in true }
        )
        XCTAssertEqual(liveness, .ours)
    }

    func testLivenessLocalLiveWhenSameHostDifferentPIDStillRunning() {
        let lock = makeLock(pid: 100, hostname: "h")
        let liveness = lock.liveness(
            now: Date(),
            currentPID: 200,
            currentHostname: "h",
            isPIDAlive: { _ in true }
        )
        XCTAssertEqual(liveness, .localLive)
    }

    func testLivenessLocalStaleWhenSameHostDifferentPIDDead() {
        let lock = makeLock(pid: 100, hostname: "h")
        let liveness = lock.liveness(
            now: Date(),
            currentPID: 200,
            currentHostname: "h",
            isPIDAlive: { _ in false }
        )
        XCTAssertEqual(liveness, .localStale)
    }

    func testLivenessForeignLiveWithinStalenessWindow() {
        let now = Date()
        let lock = makeLock(hostname: "host-X", timestamp: now.addingTimeInterval(-60))
        let liveness = lock.liveness(
            now: now,
            currentPID: 1,
            currentHostname: "host-Y",
            isPIDAlive: { _ in false }
        )
        XCTAssertEqual(liveness, .foreignLive)
    }

    func testLivenessForeignStalePastWindow() {
        let now = Date()
        let lock = makeLock(hostname: "host-X", timestamp: now.addingTimeInterval(-(60 * 60 * 2)))
        let liveness = lock.liveness(
            now: now,
            currentPID: 1,
            currentHostname: "host-Y",
            isPIDAlive: { _ in false }
        )
        XCTAssertEqual(liveness, .foreignStale)
    }

    func testLivenessForeignStalenessWindowOverridable() {
        // 30s old, custom 10s window → stale.
        let now = Date()
        let lock = makeLock(hostname: "host-X", timestamp: now.addingTimeInterval(-30))
        let liveness = lock.liveness(
            now: now,
            currentPID: 1,
            currentHostname: "host-Y",
            isPIDAlive: { _ in true },
            foreignStaleAfter: 10
        )
        XCTAssertEqual(liveness, .foreignStale)
    }

    // MARK: - IO seams

    func testIOReadReturnsNilOnMissingFile() {
        let bundle = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)")
        let lock = ProjectLockFileIO.read(bundleURL: bundle, fileReader: { url in
            throw CocoaError(.fileNoSuchFile)
        })
        XCTAssertNil(lock)
    }

    func testIOReadReturnsNilOnMalformedJSON() {
        let bundle = URL(fileURLWithPath: "/tmp/bundle")
        let lock = ProjectLockFileIO.read(bundleURL: bundle, fileReader: { _ in
            Data("not json".utf8)
        })
        XCTAssertNil(lock)
    }

    func testIORoundTripsLock() {
        let original = makeLock()
        var captured: (URL, Data)?
        let bundle = URL(fileURLWithPath: "/tmp/bundle")
        try? ProjectLockFileIO.write(original, bundleURL: bundle, fileWriter: { url, data in
            captured = (url, data)
        })
        guard let (url, data) = captured else {
            XCTFail("Expected fileWriter to be called")
            return
        }
        XCTAssertEqual(url.lastPathComponent, ".lock")
        let decoded = try? JSONDecoder().decode(ProjectLockFile.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testIORemoveSilentlySwallowsMissingFile() {
        let bundle = URL(fileURLWithPath: "/tmp/bundle")
        // No throw expected even when the remover throws — remove is best-effort.
        ProjectLockFileIO.remove(bundleURL: bundle, fileRemover: { _ in
            throw CocoaError(.fileNoSuchFile)
        })
    }

    func testIORemoveCallsRemoverWithLockURL() {
        var captured: URL?
        let bundle = URL(fileURLWithPath: "/tmp/bundle")
        ProjectLockFileIO.remove(bundleURL: bundle, fileRemover: { url in
            captured = url
        })
        XCTAssertEqual(captured?.lastPathComponent, ".lock")
    }

    func testLockURLIsBundleRelative() {
        let bundle = URL(fileURLWithPath: "/Users/op/Shows/MyShow.spb")
        let url = ProjectLockFileIO.lockURL(in: bundle)
        XCTAssertEqual(url.lastPathComponent, ".lock")
        XCTAssertEqual(url.deletingLastPathComponent().path, bundle.path)
    }

    // MARK: - Banner copy

    func testBannerSummaryMentionsHostnameAndPID() {
        let lock = makeLock(pid: 4242, hostname: "booth-mac.local")
        let summary = lock.bannerSummary
        XCTAssertTrue(summary.contains("booth-mac.local"))
        XCTAssertTrue(summary.contains("4242"))
    }

    // MARK: - Signals (real-host smoke)

    func testSignalsCurrentReadsLiveProcess() {
        let signals = ProjectLockFileSignals.current()
        XCTAssertGreaterThan(signals.pid, 0)
        XCTAssertFalse(signals.hostname.isEmpty)
    }

    func testIsPIDAliveDefaultRecognizesOurOwnPID() {
        let mine = ProjectLockFileSignals.currentPID()
        XCTAssertTrue(ProjectLockFileSignals.isPIDAliveDefault(mine))
    }

    func testIsPIDAliveDefaultRejectsClearlyBogusPID() {
        // PID_MAX is 99999 on Darwin; anything > that is guaranteed dead.
        XCTAssertFalse(ProjectLockFileSignals.isPIDAliveDefault(2_000_000))
    }

    func testMakeLockStampsTimestamp() {
        let signals = ProjectLockFileSignals(
            pid: 7, hostname: "h", applicationVersion: "1.0"
        )
        let now = Date(timeIntervalSince1970: 100)
        let lock = signals.makeLock(now: now)
        XCTAssertEqual(lock.pid, 7)
        XCTAssertEqual(lock.hostname, "h")
        XCTAssertEqual(lock.timestamp, now)
        XCTAssertEqual(lock.applicationVersion, "1.0")
    }
}
