import Foundation
import XCTest
@testable import Simple_Playback

/// E6 — autosave checkpointer. Tests pin the filename round-trip, the
/// pure-logic prune (always keeps the newest N regardless of write order),
/// and the writer's "create dir → write file → prune" sequence.
final class AutosaveCheckpointerTests: XCTestCase {

    // MARK: - Filename round-trip

    func testFilenameIncludesTimestampAndReason() {
        let cp = AutosaveCheckpoint(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            reason: .showModeOn
        )
        XCTAssertTrue(cp.filename.hasSuffix("__show_mode_on.json"))
        XCTAssertTrue(cp.filename.contains("2023"))
    }

    func testFilenameRoundTrips() {
        let original = AutosaveCheckpoint(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            reason: .showModeOff
        )
        let parsed = AutosaveCheckpoint.parse(filename: original.filename)
        XCTAssertEqual(parsed?.reason, .showModeOff)
        XCTAssertEqual(parsed?.timestamp.timeIntervalSince1970, original.timestamp.timeIntervalSince1970)
    }

    func testFilenameParseRejectsMissingExtension() {
        XCTAssertNil(AutosaveCheckpoint.parse(filename: "2023-01-01T000000Z__show_mode_on"))
    }

    func testFilenameParseRejectsUnknownReason() {
        XCTAssertNil(AutosaveCheckpoint.parse(filename: "2023-01-01T000000Z__bogus.json"))
    }

    func testFilenameParseRejectsMalformedTimestamp() {
        XCTAssertNil(AutosaveCheckpoint.parse(filename: "garbage__show_mode_on.json"))
    }

    func testFilenameAvoidsColons() {
        // Colons break Windows / SMB / exFAT — guard against accidental
        // reintroduction.
        let cp = AutosaveCheckpoint(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            reason: .manual
        )
        XCTAssertFalse(cp.filename.contains(":"))
    }

    // MARK: - Prune

    func testPruneReturnsEmptyWhenUnderLimit() {
        let names = (0..<5).map { offset in
            AutosaveCheckpoint(
                timestamp: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + offset * 60)),
                reason: .manual
            ).filename
        }
        let toPrune = AutosaveCheckpointer.filenamesToPrune(existing: names, retentionLimit: 20)
        XCTAssertTrue(toPrune.isEmpty)
    }

    func testPruneDropsOldestPastLimit() {
        let names = (0..<25).map { offset in
            AutosaveCheckpoint(
                timestamp: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + offset * 60)),
                reason: .manual
            ).filename
        }
        let toPrune = AutosaveCheckpointer.filenamesToPrune(existing: names, retentionLimit: 20)
        XCTAssertEqual(toPrune.count, 5, "25 items, retention 20 → 5 pruned.")
        // Must be the *oldest* five.
        for old in toPrune {
            let cp = AutosaveCheckpoint.parse(filename: old)
            XCTAssertNotNil(cp)
            XCTAssertLessThan(
                cp!.timestamp.timeIntervalSince1970,
                1_700_000_000 + 5 * 60,
                "Pruned set must contain the oldest five."
            )
        }
    }

    func testPruneIgnoresMalformedFilenames() {
        var names = (0..<22).map { offset in
            AutosaveCheckpoint(
                timestamp: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + offset * 60)),
                reason: .manual
            ).filename
        }
        names.append("not a checkpoint.txt")
        names.append(".DS_Store")
        let toPrune = AutosaveCheckpointer.filenamesToPrune(existing: names, retentionLimit: 20)
        XCTAssertEqual(toPrune.count, 2)
        XCTAssertFalse(toPrune.contains("not a checkpoint.txt"))
        XCTAssertFalse(toPrune.contains(".DS_Store"))
    }

    func testPruneLimitOneKeepsLatest() {
        let names = (0..<3).map { offset in
            AutosaveCheckpoint(
                timestamp: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + offset * 60)),
                reason: .manual
            ).filename
        }
        let toPrune = AutosaveCheckpointer.filenamesToPrune(existing: names, retentionLimit: 1)
        XCTAssertEqual(toPrune.count, 2)
        // Latest must NOT be pruned.
        XCTAssertFalse(toPrune.contains(names.last!))
    }

    // MARK: - Writer plumbing

    func testWriteCheckpointCreatesDirectoryAndWritesFile() throws {
        let bundle = URL(fileURLWithPath: "/tmp/show.spb")
        var createdDirs: [URL] = []
        var writes: [(URL, Data)] = []

        let result = try AutosaveCheckpointer.writeCheckpoint(
            projectData: Data("project".utf8),
            bundleURL: bundle,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            reason: .showModeOn,
            directoryCreator: { dir in createdDirs.append(dir) },
            directoryLister: { _ in [] },
            fileWriter: { u, d in writes.append((u, d)) },
            fileRemover: { _ in }
        )

        XCTAssertEqual(createdDirs.first?.lastPathComponent, "Autosave")
        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(writes[0].0.lastPathComponent.contains("show_mode_on.json"))
        XCTAssertEqual(writes[0].1, Data("project".utf8))
        XCTAssertEqual(result.url.deletingLastPathComponent().lastPathComponent, "Autosave")
        XCTAssertTrue(result.pruneFailures.isEmpty)
    }

    func testWriteCheckpointPrunesAfterListing() throws {
        let bundle = URL(fileURLWithPath: "/tmp/show.spb")
        // Pretend the directory already has 22 checkpoints (the writer just
        // added a 23rd).
        let stale = (0..<23).map { offset in
            AutosaveCheckpoint(
                timestamp: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + offset * 60)),
                reason: .manual
            ).filename
        }
        var removed: [URL] = []

        _ = try AutosaveCheckpointer.writeCheckpoint(
            projectData: Data(),
            bundleURL: bundle,
            timestamp: Date(timeIntervalSince1970: 1_700_001_500),
            reason: .manual,
            retentionLimit: 20,
            directoryCreator: { _ in },
            directoryLister: { _ in stale },
            fileWriter: { _, _ in },
            fileRemover: { url in removed.append(url) }
        )

        XCTAssertEqual(removed.count, 3, "23 → keep 20 → prune 3")
    }

    func testWriteCheckpointSwallowsRemoveErrors() throws {
        // A flaky filesystem returning ENOENT on remove should not abort the
        // checkpoint write — checkpoints are best-effort by design.
        let stale = (0..<25).map { offset in
            AutosaveCheckpoint(
                timestamp: Date(timeIntervalSince1970: TimeInterval(offset * 60)),
                reason: .manual
            ).filename
        }
        let bundle = URL(fileURLWithPath: "/tmp/show.spb")
        struct Boom: Error {}
        XCTAssertNoThrow(
            try AutosaveCheckpointer.writeCheckpoint(
                projectData: Data(),
                bundleURL: bundle,
                timestamp: Date(),
                reason: .manual,
                directoryCreator: { _ in },
                directoryLister: { _ in stale },
                fileWriter: { _, _ in },
                fileRemover: { _ in throw Boom() }
            )
        )
    }

    func testWriteCheckpointSurfacesPruneFailures() throws {
        // Pre-review the prune step swallowed errors via `try?`, leaving the
        // operator unable to see why `<bundle>/Autosave/` kept growing.
        // The WriteResult now reports each failed remove so the host can
        // log + surface.
        let stale = (0..<25).map { offset in
            AutosaveCheckpoint(
                timestamp: Date(timeIntervalSince1970: TimeInterval(offset * 60)),
                reason: .manual
            ).filename
        }
        let bundle = URL(fileURLWithPath: "/tmp/show.spb")
        struct Boom: Error {}
        let result = try AutosaveCheckpointer.writeCheckpoint(
            projectData: Data(),
            bundleURL: bundle,
            timestamp: Date(),
            reason: .manual,
            directoryCreator: { _ in },
            directoryLister: { _ in stale },
            fileWriter: { _, _ in },
            fileRemover: { _ in throw Boom() }
        )
        // 25 → keep 20 → 5 prune attempts, all failing.
        XCTAssertEqual(result.pruneFailures.count, 5)
        XCTAssertTrue(result.pruneFailures.first?.error is Boom)
    }

    func testWriteCheckpointReportsEmptyFailureListOnSuccess() throws {
        // When prune succeeds, the result's pruneFailures must be empty —
        // hosts read this list and surface non-empty cases; a stray entry
        // would produce false alarms.
        let stale = (0..<22).map { offset in
            AutosaveCheckpoint(
                timestamp: Date(timeIntervalSince1970: TimeInterval(offset * 60)),
                reason: .manual
            ).filename
        }
        let bundle = URL(fileURLWithPath: "/tmp/show.spb")
        let result = try AutosaveCheckpointer.writeCheckpoint(
            projectData: Data(),
            bundleURL: bundle,
            timestamp: Date(),
            reason: .manual,
            directoryCreator: { _ in },
            directoryLister: { _ in stale },
            fileWriter: { _, _ in },
            fileRemover: { _ in }
        )
        XCTAssertTrue(result.pruneFailures.isEmpty)
    }
}
