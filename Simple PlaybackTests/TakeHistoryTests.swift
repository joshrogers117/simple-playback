import Foundation
import XCTest
@testable import Simple_Playback

/// E5 — pin the take-history circular-buffer invariants.
@MainActor
final class TakeHistoryTests: XCTestCase {

    private func entry(_ number: String, at offset: TimeInterval = 0) -> TakeHistoryEntry {
        TakeHistoryEntry(
            timestamp: Date(timeIntervalSinceReferenceDate: offset),
            cueID: UUID(),
            cueNumber: number,
            cueTitle: "Cue \(number)",
            durationSecondsAtFire: nil
        )
    }

    func testAppendBelowCapacityKeepsAllEntries() {
        let history = TakeHistory(capacity: 5)
        for i in 0..<3 {
            history.append(entry("\(i)", at: TimeInterval(i)))
        }
        XCTAssertEqual(history.entries.count, 3)
    }

    func testAppendAtCapacityDropsOldestEntry() {
        let history = TakeHistory(capacity: 3)
        history.append(entry("A", at: 0))
        history.append(entry("B", at: 1))
        history.append(entry("C", at: 2))
        history.append(entry("D", at: 3))
        XCTAssertEqual(history.entries.count, 3)
        XCTAssertEqual(history.entries.map(\.cueNumber), ["B", "C", "D"])
    }

    func testCapacityEnforcedAcrossManyAppends() {
        let history = TakeHistory(capacity: 200)
        for i in 0..<400 {
            history.append(entry("\(i)", at: TimeInterval(i)))
        }
        XCTAssertEqual(history.entries.count, 200)
        // Latest 200: 200..399.
        XCTAssertEqual(history.entries.first?.cueNumber, "200")
        XCTAssertEqual(history.entries.last?.cueNumber, "399")
    }

    func testCapacityClampedToAtLeastOne() {
        let history = TakeHistory(capacity: 0)
        XCTAssertEqual(history.capacity, 1)
        history.append(entry("A", at: 0))
        history.append(entry("B", at: 1))
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.cueNumber, "B")
    }

    func testLatestEntriesReversesChronologicalOrder() {
        let history = TakeHistory(capacity: 5)
        history.append(entry("A", at: 0))
        history.append(entry("B", at: 1))
        history.append(entry("C", at: 2))
        XCTAssertEqual(history.latestEntries.map(\.cueNumber), ["C", "B", "A"])
    }

    func testResetClearsAllEntries() {
        let history = TakeHistory(capacity: 5)
        history.append(entry("A", at: 0))
        history.append(entry("B", at: 1))
        history.reset()
        XCTAssertEqual(history.entries.count, 0)
    }

    func testRecordFireCapturesCueDetails() {
        let history = TakeHistory(capacity: 5)
        let slideID = UUID()
        let cue = Cue(number: "Q1", title: "Opener", assetID: slideID)
        history.recordFire(cue: cue, durationSecondsAtFire: 12.5)
        XCTAssertEqual(history.entries.count, 1)
        let saved = history.entries[0]
        XCTAssertEqual(saved.cueID, cue.id)
        XCTAssertEqual(saved.cueNumber, "Q1")
        XCTAssertEqual(saved.cueTitle, "Opener")
        XCTAssertEqual(saved.durationSecondsAtFire, 12.5)
    }

    func testRecordFireMutatedCueNotReflectedInPriorHistory() {
        // Capturing the title at fire time means renaming the cue later
        // doesn't rewrite history — operators see what was on screen at
        // the time, not the current state.
        let history = TakeHistory(capacity: 5)
        var cue = Cue(number: "Q1", title: "Opener", assetID: UUID())
        history.recordFire(cue: cue)
        cue.title = "Renamed"
        history.recordFire(cue: cue)
        XCTAssertEqual(history.entries[0].cueTitle, "Opener")
        XCTAssertEqual(history.entries[1].cueTitle, "Renamed")
    }

    func testEntriesHaveUniqueIDsAcrossRepeatedFires() {
        let history = TakeHistory(capacity: 5)
        let cue = Cue(number: "Q1", title: "Same", assetID: UUID())
        history.recordFire(cue: cue)
        history.recordFire(cue: cue)
        let ids = history.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Each entry must have a unique id")
    }
}
