import Foundation

/// E5 — recent-take history. Spec §3.16: "operator can scroll back through
/// the last N takes." V1 ships an in-memory circular buffer of the last 200
/// fires, surfaced as a read-only sheet. **Replay scrub is deferred** — the
/// runtime would need a "fire cue X with original parameters at this offset"
/// entry point that doesn't yet exist; the data here is the foundation for
/// that future iteration.
///
/// The model is pure-logic. `ShowController.handleCueFired` pushes one entry
/// per take. The view reads `entries` (newest first by convention) and
/// renders timestamp + cue number + title + (optional) duration-at-fire.
struct TakeHistoryEntry: Identifiable, Equatable {
    /// Unique per record so SwiftUI can identify rows even when the same cue
    /// fires twice in a row.
    let id: UUID
    /// Wall-clock when the cue fired. The runtime's logical "fire" time, not
    /// when the take landed on the output.
    let timestamp: Date
    /// `Cue.id` — opaque to the operator but stable for cross-references.
    let cueID: UUID
    /// `Cue.number` — operator-visible (may be empty for un-numbered cues).
    let cueNumber: String
    /// `Cue.title` — captured at fire time. The cue's title may change
    /// later; the history pins what was on screen at the moment of fire.
    let cueTitle: String
    /// Asset duration in seconds, sampled from playback at fire time. Nil
    /// for image takes (which have no inherent duration) and for video
    /// takes where `videoDuration` hasn't been resolved yet (it loads
    /// asynchronously after `take(...)`).
    let durationSecondsAtFire: TimeInterval?

    init(
        id: UUID = UUID(),
        timestamp: Date,
        cueID: UUID,
        cueNumber: String,
        cueTitle: String,
        durationSecondsAtFire: TimeInterval?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.cueID = cueID
        self.cueNumber = cueNumber
        self.cueTitle = cueTitle
        self.durationSecondsAtFire = durationSecondsAtFire
    }
}

/// Bounded chronological list of recent fires. Pure-logic — caller owns the
/// instance and pushes entries on each cue fire. Append-only (`reset()` for
/// a session boundary).
///
/// Storage shape: an array kept in chronological order (oldest at index 0).
/// On overflow the oldest entry is removed. The view-facing accessor
/// `latestEntries` reverses the order so newest-first is the natural read.
@MainActor
final class TakeHistory: ObservableObject {

    /// Maximum number of entries retained. Spec §3.16: "recent 200." A flat
    /// circular buffer is fine — the view scrolls — but a hard cap keeps
    /// memory bounded across multi-hour shows.
    let capacity: Int

    @Published private(set) var entries: [TakeHistoryEntry] = []

    nonisolated init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    /// Append an entry. If the list is at capacity, the oldest entry is
    /// dropped to make room. The append/drop is O(n) once you hit the cap
    /// (Swift `Array.removeFirst()`), but at 200 entries this is negligible
    /// compared to the cost of taking the cue itself.
    func append(_ entry: TakeHistoryEntry) {
        entries.append(entry)
        while entries.count > capacity {
            entries.removeFirst()
        }
    }

    /// Convenience: build the entry from the operator-visible cue + a
    /// duration sampled at fire time. Stamps `Date()` for the timestamp.
    func recordFire(cue: Cue, durationSecondsAtFire: TimeInterval? = nil) {
        append(TakeHistoryEntry(
            timestamp: Date(),
            cueID: cue.id,
            cueNumber: cue.number,
            cueTitle: cue.title,
            durationSecondsAtFire: durationSecondsAtFire
        ))
    }

    /// View-facing accessor — newest first. Computed each call so the
    /// underlying chronological storage stays simple.
    var latestEntries: [TakeHistoryEntry] {
        entries.reversed()
    }

    /// Drop the entire history. Wired to `PlaybackController.stopOutput()`
    /// at session boundaries — operators don't usually want yesterday's
    /// fires lingering in today's history.
    func reset() {
        entries.removeAll(keepingCapacity: true)
    }
}
