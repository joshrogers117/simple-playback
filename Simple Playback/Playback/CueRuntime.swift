import Foundation

/// Per-cue lifecycle state during a show.
///
/// - `idle`: cue is in the list but not pre-rolled or running.
/// - `loaded`: cue has been pre-rolled (decoder warmed, GPU upload primed) and is ready to fire instantly.
/// - `running`: cue is currently producing video/audio frames on outputs.
/// - `tail`: cue has been requested to stop and is in its post-fire fade-out window.
// Demoted from `public` during the review pass — Simple Playback ships as a
// single-target app so no other module imports this; `public` was a no-op
// here and inconsistent with the rest of the codebase (everything else is
// internal). Easy to re-promote if the runtime ever splits into a library.
enum CueStandbyState: String, Codable, Equatable, Hashable, CaseIterable {
    case idle
    case loaded
    case running
    case tail
}

/// Reasons a `go()` request can be rejected without firing a cue.
enum CueRuntimeRejection: Equatable {
    /// A previous `go()` arrived within the debounce window. The caller may retry after the debounce expires.
    case debounced
    /// The playhead is past the end of the list, or the list is empty. Nothing to fire.
    case noCueAtPlayhead
    /// The named cue (`go(targetNumber:)`) does not exist in the list.
    case unknownCueNumber(String)
    /// A panic is in progress. The runtime ignores GO until panic resolves.
    case panicInProgress
}

/// Cancellable handle returned by a `CueScheduler` schedule.
final class CueScheduledTask {
    private let cancelClosure: () -> Void
    private(set) var isCancelled = false

    init(cancel: @escaping () -> Void) {
        self.cancelClosure = cancel
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelClosure()
    }
}

/// Schedules a closure to run after a delay. Injected into `CueRuntime` so production uses
/// real timers and tests use deterministic virtual time.
protocol CueScheduler: AnyObject {
    @discardableResult
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> CueScheduledTask
}

/// Production scheduler backed by `DispatchSourceTimer`. Default scheduler used when callers
/// do not inject one.
final class DispatchCueScheduler: CueScheduler {
    private let queue: DispatchQueue

    init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    @discardableResult
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> CueScheduledTask {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let clamped = max(0, delay)
        timer.schedule(deadline: .now() + clamped, leeway: .milliseconds(1))
        let cancelled = ManagedAtomicFlag()
        timer.setEventHandler {
            guard !cancelled.value else { return }
            work()
            timer.cancel()
        }
        timer.resume()
        return CueScheduledTask {
            cancelled.value = true
            timer.cancel()
        }
    }
}

/// Tiny lock-free flag used by `DispatchCueScheduler` to suppress already-cancelled fires.
/// Not exposed outside this file.
private final class ManagedAtomicFlag {
    private let queue = DispatchQueue(label: "CueRuntime.atomicFlag", attributes: [])
    private var _value: Bool = false
    var value: Bool {
        get { queue.sync { _value } }
        set { queue.sync { _value = newValue } }
    }
}

/// Pure show-runtime state machine.
///
/// `CueRuntime` owns a `ShowList` and exposes the GO / PREV / PANIC / CLEAR / BLACKOUT verbs that
/// drive the show. It does not render or decode anything: it tells observers (via callbacks) what
/// happened and lets the playback layer react.
///
/// Time enters the runtime via the injectable `clock`, so tests can drive debounce and continuation
/// timing deterministically without `Thread.sleep`. Continuation timing flows through the injected
/// `scheduler` for the same reason.
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
    private let scheduler: CueScheduler

    /// Pending auto-follow continuation tasks, keyed by the cue whose end will fire the chain.
    private var pendingContinuationTasks: [UUID: CueScheduledTask] = [:]

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
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        scheduler: CueScheduler? = nil
    ) {
        self.showList = showList
        self.clock = clock
        self.scheduler = scheduler ?? DispatchCueScheduler()
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
    /// `auto-continue` chains expand inside `fire(cue:)`, so the returned cue is just the
    /// first one fired by this GO.
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
        guard let target = showList.cue(number: targetNumber) else {
            onGoRejected?(.unknownCueNumber(targetNumber))
            return nil
        }
        let now = clock()
        if now - lastGoAt < minimumGoInterval {
            onGoRejected?(.debounced)
            return nil
        }
        showList.movePlayhead(to: target.id)
        onPlayheadChanged?(showList.playheadCue)
        lastGoAt = now
        fire(cue: target, dueToContinuation: false)
        return target
    }

    /// Steps the playhead one cue back without firing.
    func previous() {
        showList.retreatPlayhead()
        onPlayheadChanged?(showList.playheadCue)
    }

    // MARK: - PANIC / CLEAR / BLACKOUT

    /// Soft panic. Fades all running cues out over `fade` seconds (default `defaultPanicFade`),
    /// flips them through `tail` to `idle`, leaves the playhead untouched, cancels every pending
    /// continuation, and locks GO until `panicCompleted()` is called by the playback layer.
    func panic(fade: TimeInterval? = nil) {
        let fadeDuration = max(0, fade ?? defaultPanicFade)
        panicActive = true
        cancelAllPendingContinuations()
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

    /// Hard kill. Instantly stops every running cue, cancels every pending continuation. Audio
    /// mute is the playback layer's job; the runtime contract is "tell observers everything is
    /// now idle". Does NOT engage panic lock — CLEAR is non-blocking.
    func clear() {
        cancelAllPendingContinuations()
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
    ///
    /// If the cue's `continuation` is `autoFollow`, schedules the next cue to fire after
    /// `cue.postWait` seconds. The schedule is cancelled by panic, clear, or list mutation
    /// that removes the next cue.
    func cueDidEnd(cueID: UUID) {
        guard let cue = showList.cue(id: cueID) else { return }
        transition(cue: cue, to: .idle)
        onCueEnded?(cue)
        scheduleAutoFollowIfNeeded(after: cue)
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
        // Drop state and pending tasks for cues that have been removed.
        let livingIDs = Set(showList.cues.map(\.id))
        cueStates = cueStates.filter { livingIDs.contains($0.key) }
        for (cueID, task) in pendingContinuationTasks where !livingIDs.contains(cueID) {
            task.cancel()
            pendingContinuationTasks.removeValue(forKey: cueID)
        }
    }

    // MARK: - Private

    /// Fires the given cue and, if it is auto-continue, recursively fires the next cue in the
    /// list (which may itself chain further). Auto-follow does NOT chain here — it waits for
    /// `cueDidEnd` to schedule its follow-up via the injected scheduler.
    ///
    /// Each fire advances the playhead past the just-fired cue, so a chain of auto-continues
    /// leaves the playhead on the first cue that did NOT chain.
    private func fire(cue: Cue, dueToContinuation: Bool) {
        // Cancel any pending follow that this cue had scheduled — we're firing fresh.
        cancelPendingContinuation(for: cue.id)

        transition(cue: cue, to: .running)
        onCueFired?(cue, dueToContinuation)

        // Always advance playhead past this cue, regardless of how it was triggered.
        if showList.playheadCue?.id == cue.id {
            showList.advancePlayhead()
            onPlayheadChanged?(showList.playheadCue)
        }

        // Auto-continue: chain immediately into the next cue.
        if cue.continuation == .autoContinue, let next = nextCueAfter(cue) {
            fire(cue: next, dueToContinuation: true)
        }
    }

    /// Schedules an auto-follow chain to fire the next cue after `cue.postWait`, if `cue`
    /// has `autoFollow` continuation and a next cue exists. Idempotent if called twice for
    /// the same cue: cancels any prior schedule first.
    private func scheduleAutoFollowIfNeeded(after cue: Cue) {
        guard cue.continuation == .autoFollow,
              let next = nextCueAfter(cue),
              !panicActive else {
            return
        }

        cancelPendingContinuation(for: cue.id)
        let delay = max(0, cue.postWait)
        let nextID = next.id
        let task = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.pendingContinuationTasks.removeValue(forKey: cue.id)
            // Re-resolve `next` from the current show list — it may have been removed since.
            guard let resolvedNext = self.showList.cue(id: nextID) else { return }
            // Don't fire if a panic engaged while we were waiting.
            guard !self.panicActive else { return }
            self.showList.movePlayhead(to: resolvedNext.id)
            self.onPlayheadChanged?(self.showList.playheadCue)
            self.fire(cue: resolvedNext, dueToContinuation: true)
        }
        pendingContinuationTasks[cue.id] = task
    }

    private func nextCueAfter(_ cue: Cue) -> Cue? {
        guard let idx = showList.cueIndex(id: cue.id) else { return nil }
        let nextIdx = idx + 1
        return showList.cues.indices.contains(nextIdx) ? showList.cues[nextIdx] : nil
    }

    private func cancelPendingContinuation(for cueID: UUID) {
        if let task = pendingContinuationTasks.removeValue(forKey: cueID) {
            task.cancel()
        }
    }

    private func cancelAllPendingContinuations() {
        for (_, task) in pendingContinuationTasks {
            task.cancel()
        }
        pendingContinuationTasks.removeAll()
    }

    private func transition(cue: Cue, to newState: CueStandbyState) {
        let previous = state(of: cue.id)
        guard previous != newState else { return }
        cueStates[cue.id] = newState
        onCueStateChanged?(cue, newState)
    }
}
