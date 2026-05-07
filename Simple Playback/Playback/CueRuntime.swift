import Foundation

/// Per-cue lifecycle state during a show.
///
/// - `idle`: cue is in the list but not pre-rolled or running.
/// - `loaded`: cue has been pre-rolled (decoder warmed, GPU upload primed) and is ready to fire instantly.
/// - `running`: cue is currently producing video/audio frames on outputs.
/// - `tail`: cue has been requested to stop and is in its post-fire fade-out window.
public enum CueStandbyState: String, Codable, Equatable, Hashable, CaseIterable {
    case idle
    case loaded
    case running
    case tail
}

/// Reasons a `go()` request can be rejected without firing a cue.
public enum CueRuntimeRejection: Equatable {
    /// A previous `go()` arrived within the debounce window. The caller may retry after the debounce expires.
    case debounced
    /// The playhead is past the end of the list, or the list is empty. Nothing to fire.
    case noCueAtPlayhead
    /// The named cue (`go(targetNumber:)`) does not exist in the list.
    case unknownCueNumber(String)
    /// A panic is in progress. The runtime ignores GO until panic resolves.
    case panicInProgress
}

/// Pure show-runtime state machine.
///
/// `CueRuntime` owns a `ShowList` and exposes the GO / PREV / PANIC / CLEAR / BLACKOUT verbs that
/// drive the show. It does not render or decode anything: it tells observers (via callbacks) what
/// happened and lets the playback layer react.
///
/// Time enters the runtime via the injectable `clock`, so tests can drive debounce and continuation
/// timing deterministically without `Thread.sleep`.
final class CueRuntime {
    /// The show list this runtime is driving. Mutations to the list go through the runtime's
    /// methods so the playhead and per-cue state stay coherent; direct edits are allowed but
    /// callers should call `syncState()` afterward.
    private(set) var showList: ShowList
    private(set) var cueStates: [UUID: CueStandbyState] = [:]
    private(set) var blackout: Bool = false
    private(set) var panicActive: Bool = false

    /// Minimum interval between GOs, in seconds. Default 250 ms (matches the spec).
    var minimumGoInterval: TimeInterval = 0.25

    /// Default soft-panic fade duration when caller does not specify one.
    var defaultPanicFade: TimeInterval = 0.5

    private var lastGoAt: TimeInterval = -.infinity
    private let clock: () -> TimeInterval

    // MARK: - Callbacks

    /// Fires when a cue actually transitions to `running`. Provides the cue and a `dueByCue` flag
    /// indicating whether the call originated from a continuation chain (auto-continue/auto-follow,
    /// once those land in A4c) or from an operator-driven GO.
    var onCueFired: ((Cue, _ dueToContinuation: Bool) -> Void)?

    /// Fires when a cue moves out of `running` (either reached natural end or was stopped).
    var onCueEnded: ((Cue) -> Void)?

    /// Fires whenever a cue's standby state changes (idle ↔ loaded ↔ running ↔ tail).
    var onCueStateChanged: ((Cue, CueStandbyState) -> Void)?

    /// Fires when the playhead moves to a different cue (or off the end / back from past-end).
    var onPlayheadChanged: ((Cue?) -> Void)?

    /// Fires when panic is engaged (`true`) or fully cleared (`false`).
    var onPanicChanged: ((Bool, _ fade: TimeInterval) -> Void)?

    /// Fires whenever blackout toggles.
    var onBlackoutChanged: ((Bool) -> Void)?

    /// Fires when a GO request is rejected before any cue fires.
    var onGoRejected: ((CueRuntimeRejection) -> Void)?

    /// Fires when CLEAR is invoked (after every running cue is forced to idle).
    var onCleared: (() -> Void)?

    // MARK: - Init

    init(
        showList: ShowList = ShowList(),
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.showList = showList
        self.clock = clock
        for cue in showList.cues {
            cueStates[cue.id] = .idle
        }
    }

    // MARK: - State queries

    func state(of cueID: UUID) -> CueStandbyState {
        cueStates[cueID] ?? .idle
    }

    /// Cues whose state is `.running`.
    var activeCues: [Cue] {
        showList.cues.filter { state(of: $0.id) == .running }
    }

    // MARK: - GO / PREV

    /// Fires the cue at the playhead and advances. Returns the fired cue, or nil if rejected.
    @discardableResult
    func go() -> Cue? {
        guard !panicActive else {
            onGoRejected?(.panicInProgress)
            return nil
        }
        let now = clock()
        if now - lastGoAt < minimumGoInterval {
            onGoRejected?(.debounced)
            return nil
        }
        guard let cue = showList.playheadCue else {
            onGoRejected?(.noCueAtPlayhead)
            return nil
        }
        lastGoAt = now
        fire(cue: cue, dueToContinuation: false)
        showList.advancePlayhead()
        onPlayheadChanged?(showList.playheadCue)
        return cue
    }

    /// Jumps the playhead to the cue with the given operator-visible number (case-insensitive),
    /// then fires.
    @discardableResult
    func go(targetNumber: String) -> Cue? {
        guard !panicActive else {
            onGoRejected?(.panicInProgress)
            return nil
        }
        guard showList.cue(number: targetNumber) != nil else {
            onGoRejected?(.unknownCueNumber(targetNumber))
            return nil
        }
        let now = clock()
        if now - lastGoAt < minimumGoInterval {
            onGoRejected?(.debounced)
            return nil
        }
        guard let target = showList.cue(number: targetNumber) else {
            onGoRejected?(.unknownCueNumber(targetNumber))
            return nil
        }
        showList.movePlayhead(to: target.id)
        lastGoAt = now
        fire(cue: target, dueToContinuation: false)
        showList.advancePlayhead()
        onPlayheadChanged?(showList.playheadCue)
        return target
    }

    /// Steps the playhead one cue back without firing.
    func previous() {
        showList.retreatPlayhead()
        onPlayheadChanged?(showList.playheadCue)
    }

    // MARK: - PANIC / CLEAR / BLACKOUT

    /// Soft panic. Fades all running cues out over `fade` seconds (default `defaultPanicFade`),
    /// flips them through `tail` to `idle`, leaves the playhead untouched, and locks GO until
    /// `panicCompleted()` is called by the playback layer (or the caller resolves with the
    /// completion handler form).
    func panic(fade: TimeInterval? = nil) {
        let fadeDuration = max(0, fade ?? defaultPanicFade)
        panicActive = true
        for cue in activeCues {
            transition(cue: cue, to: .tail)
        }
        onPanicChanged?(true, fadeDuration)
    }

    /// Marks panic as resolved. Called by the playback layer once the fade-out has finished
    /// rendering. Forces every still-tail cue to idle and re-enables GO.
    func panicCompleted() {
        for cue in showList.cues where state(of: cue.id) == .tail {
            transition(cue: cue, to: .idle)
            onCueEnded?(cue)
        }
        panicActive = false
        onPanicChanged?(false, 0)
    }

    /// Hard kill. Instantly stops every running cue. Audio mute is the playback layer's job;
    /// the runtime contract is "tell observers everything is now idle". Does NOT engage panic
    /// lock — CLEAR is non-blocking.
    func clear() {
        for cue in activeCues {
            transition(cue: cue, to: .idle)
            onCueEnded?(cue)
        }
        for cue in showList.cues where state(of: cue.id) == .tail {
            transition(cue: cue, to: .idle)
            onCueEnded?(cue)
        }
        onCleared?()
    }

    /// Toggles the latching blackout flag. Audio is independent of blackout.
    func toggleBlackout() {
        blackout.toggle()
        onBlackoutChanged?(blackout)
    }

    /// Sets blackout to a specific value.
    func setBlackout(_ active: Bool) {
        guard blackout != active else { return }
        blackout = active
        onBlackoutChanged?(blackout)
    }

    // MARK: - External signals from the playback layer

    /// Called by the playback layer when a cue reaches its natural end-of-media (or stops for
    /// any non-CLEAR reason). Drives `running → tail → idle`. The actual `tail` window is
    /// the playback layer's fade-out duration; the runtime treats `cueDidEnd` as the moment
    /// the audience can no longer see the cue, transitioning straight to idle.
    func cueDidEnd(cueID: UUID) {
        guard let cue = showList.cue(id: cueID) else { return }
        transition(cue: cue, to: .idle)
        onCueEnded?(cue)
    }

    /// Called by the playback layer to mark a cue as pre-rolled and ready for instant fire.
    /// Idempotent: marking an already-loaded cue is a no-op.
    func markLoaded(cueID: UUID) {
        guard let cue = showList.cue(id: cueID), state(of: cueID) == .idle else { return }
        transition(cue: cue, to: .loaded)
    }

    /// Called by the playback layer to release a previously-loaded cue back to idle without
    /// firing it (e.g. user re-armed a different cue).
    func unloadCue(cueID: UUID) {
        guard let cue = showList.cue(id: cueID), state(of: cueID) == .loaded else { return }
        transition(cue: cue, to: .idle)
    }

    // MARK: - List mutations

    /// Replaces the show list. Resets per-cue state for any new cue IDs.
    func replaceShowList(_ list: ShowList) {
        showList = list
        var newStates: [UUID: CueStandbyState] = [:]
        for cue in showList.cues {
            newStates[cue.id] = cueStates[cue.id] ?? .idle
        }
        cueStates = newStates
        onPlayheadChanged?(showList.playheadCue)
    }

    /// Mutates the show list via a closure, then re-syncs state. Use this for in-place edits
    /// that need to preserve runtime state across mutations.
    func mutateShowList(_ body: (inout ShowList) -> Void) {
        body(&showList)
        for cue in showList.cues where cueStates[cue.id] == nil {
            cueStates[cue.id] = .idle
        }
        // Drop state for cues that have been removed.
        let livingIDs = Set(showList.cues.map(\.id))
        cueStates = cueStates.filter { livingIDs.contains($0.key) }
    }

    // MARK: - Private

    private func fire(cue: Cue, dueToContinuation: Bool) {
        transition(cue: cue, to: .running)
        onCueFired?(cue, dueToContinuation)
    }

    private func transition(cue: Cue, to newState: CueStandbyState) {
        let previous = state(of: cue.id)
        guard previous != newState else { return }
        cueStates[cue.id] = newState
        onCueStateChanged?(cue, newState)
    }
}
