import Combine
import Foundation
import SwiftUI

/// Bridges `CueRuntime` (pure show-runtime state machine) with `PlaybackController`
/// (audio/video output). Owns the runtime, observes its callbacks, and translates `cueFired`
/// into a `playback.take(...)` against the asset library.
///
/// Also holds operator-only UI state (Show Mode toggle) and surfaces enough `@Published`
/// signals that SwiftUI views can render the live state of the cue list.
@MainActor
final class ShowController: ObservableObject {
    let runtime: CueRuntime

    /// Bumped whenever the underlying runtime state changes — playhead moved, cue fired,
    /// state transitioned, etc. SwiftUI views watch this to redraw the cue list without
    /// the controller needing to reflect every field.
    @Published private(set) var revision: Int = 0

    @Published private(set) var liveCueID: UUID?
    @Published private(set) var blackout: Bool = false
    @Published private(set) var panicActive: Bool = false

    /// Whether the workspace is in Show Mode (lockouts engaged). Persists across the app
    /// session but not into the project file — it's an operator-state preference for the
    /// current open document.
    @Published var showMode: Bool = false

    /// Most recent rejection reason for a GO request — surfaced briefly in the UI so
    /// operators see why nothing happened.
    @Published private(set) var lastGoRejection: CueRuntimeRejection?

    /// E3 — append-only show log. Each verb method records a corresponding
    /// `ShowLogEvent`. Optional so headless tests + early app boot don't need a
    /// log instance; production sets it from `RootView` after the controller
    /// is wired up.
    weak var showLog: ShowLog?

    /// E5 — recent-take history (last 200 fires). Captured on
    /// `handleCueFired`. Optional so headless tests / early-boot wiring
    /// don't need an instance; production sets it from `RootView`.
    weak var takeHistory: TakeHistory?

    private let playback: PlaybackController
    private let assetLookup: (UUID) -> MediaSlide?
    private let transitionSettingsLookup: () -> PlayoutTransitionSettings
    private let outputBindingLookup: () -> (deviceID: String?, modeID: String?)
    private var panicCompletionTask: DispatchWorkItem?
    private var droppedFrameCancellable: AnyCancellable?
    /// E3+ tail — pure-logic late-take detector. ShowController bridges
    /// `handleCueFired` → `recordGoFired` and `playback.onFirstComposedFrameForCue`
    /// → `recordFrameSubmitted` (Path 1, upgraded from the prior Path 2
    /// `$liveSlideID` proxy). The Path 1 callback fires once per take when
    /// the first composed frame for that take reaches `submitFrame` — covers
    /// both image and video cues uniformly. The previous Path 2 proxy
    /// flipped `liveSlideID` synchronously inside `take(...)` for image
    /// cues (always reading as on-time) and only caught load latency for
    /// video cues; Path 1 closes both gaps. Detector exposed so tests can
    /// drive `handleLiveSlideTransition(slideID:now:)` directly without
    /// synthesizing a real callback emission.
    let lateTakeDetector = LateTakeDetector()
    /// Operator-readable descriptor (cue number or title) cached at
    /// `recordGoFired` time so the late-take log entry can name the cue. The
    /// detector itself only carries cueID; we cache the human form here.
    private var pendingLateTakeCueDescriptor: String?
    /// Most recent cumulative drop count we've already logged. Drives the
    /// debounce — only the delta since this value reaches the show log,
    /// gated by a 1 s throttle so a long stall lands as one event, not 30.
    private var lastReportedDropCumulative: Int = 0
    /// Wall clock of the last `.droppedFrame` log emission. The debounce
    /// gates emission until at least `dropFlushInterval` seconds since the
    /// previous emission, so a long stall lands as one log entry, not one
    /// per dropped frame.
    private var lastDropLogTime: Date?
    /// Window between consecutive `.droppedFrame` log entries (seconds).
    /// Spec §3.16 calls for debounced reporting; this is the floor.
    private let dropFlushInterval: TimeInterval = 1.0

    /// Hub bind token, returned by `ShowControlHub.shared.bind(...)` at init
    /// and handed back to `unbind(token:)` from `deinit` so the per-document
    /// bind stack pops cleanly when the document closes. See
    /// `ShowControlHub` doc-comment for the stack semantics. `var` (with a
    /// placeholder initial value) so all stored properties finish
    /// initialising before the bind closure captures `self` — Swift's
    /// definite-initialisation check rejects passing `self` into the
    /// closure while any stored property is still un-assigned.
    private var hubBindToken = ShowControlHub.BindToken.placeholder

    init(
        showList: ShowList,
        playback: PlaybackController,
        assetLookup: @escaping (UUID) -> MediaSlide?,
        transitionSettings: @escaping () -> PlayoutTransitionSettings,
        outputBinding: @escaping () -> (deviceID: String?, modeID: String?)
    ) {
        self.runtime = CueRuntime(showList: showList)
        self.playback = playback
        self.assetLookup = assetLookup
        self.transitionSettingsLookup = transitionSettings
        self.outputBindingLookup = outputBinding
        wireRuntime()
        // Hand this document's runtime + dispatched-action callback to the
        // process-wide show-control hub. The hub's per-document bind stack
        // routes remote-driven actions to whichever document was bound most
        // recently — opening doc B then closing it returns control to doc A
        // automatically. Every remote-driven action lands here with its
        // source attribution (host, port, transport, etc.) so the show log
        // captures it with the correct provenance.
        self.hubBindToken = ShowControlHub.shared.bind(runtime: runtime) { [weak self] action, source, _ in
            self?.recordDispatchedAction(action, source: source)
        }
        wireDroppedFrameLog()
        wireLateTakeDetector()
    }

    deinit {
        // Pop our entry off the hub's bind stack. `deinit` may run off the
        // main actor (Swift's @MainActor classes don't guarantee main-actor
        // deinit) — the hub's `unbind` is main-isolated, so hop. Capture
        // the token by value so the closure doesn't pin a (now-deinitting)
        // self.
        let token = hubBindToken
        Task { @MainActor in
            ShowControlHub.shared.unbind(token: token)
        }
    }

    /// E3+ tail — pipe `playback.onFirstComposedFrameForCue` into the
    /// late-take detector (Path 1). The callback fires once per take with
    /// (slideID, Date) when the first composed frame for that take reaches
    /// `submitFrame`. PlaybackController dispatches the callback on main, so
    /// the bridge can call `handleLiveSlideTransition` directly. Verdict.late
    /// lands as a `.lateTake` show-log entry with `latency=Nms cue=<descriptor>`
    /// detail.
    private func wireLateTakeDetector() {
        playback.onFirstComposedFrameForCue = { [weak self] slideID, firedAt in
            self?.handleLiveSlideTransition(slideID: slideID, now: firedAt)
        }
    }

    /// Test seam — set the human cue descriptor that will name the next
    /// `.lateTake` log entry. Production uses `handleCueFired` to set this
    /// alongside `recordGoFired`; tests bypass cue-runtime mechanics and
    /// drive the detector + bridge directly.
    func setPendingLateTakeCueDescriptor(_ descriptor: String) {
        pendingLateTakeCueDescriptor = descriptor
    }

    /// Test seam — clear the cached descriptor so a later frame doesn't
    /// reattach a stale cue name. Production clears it inside the panic
    /// handler / completion path.
    func clearPendingLateTakeCueDescriptorForTesting() {
        pendingLateTakeCueDescriptor = nil
    }

    /// Pure-logic decision so tests can drive the late-take bridge by injecting
    /// an explicit `now` rather than synthesizing a real `liveSlideID` publish.
    func handleLiveSlideTransition(slideID: UUID, now: Date) {
        guard let verdict = lateTakeDetector.recordFrameSubmitted(slideID: slideID, at: now) else {
            // No pending take, no clock-skew win, or slide doesn't match. Either
            // way the descriptor is stale — keep it for any subsequent matching
            // frame (the detector has already returned nil and didn't clear
            // its own pending state for the slide-mismatch / no-pending cases).
            if lateTakeDetector.pending == nil {
                pendingLateTakeCueDescriptor = nil
            }
            return
        }
        let descriptor = pendingLateTakeCueDescriptor ?? "?"
        pendingLateTakeCueDescriptor = nil
        // v2 Post-Show Summary precondition (Q3-C) — every verdict emits a
        // `.takeLatency` row so the reducer can bin all takes into a histogram.
        // The existing `.lateTake` row continues to fire only when the verdict
        // crossed the threshold (operator-readable highlight in the show log).
        showLog?.appendNow(
            action: .takeLatency,
            source: .system,
            detail: "latency=\(verdict.latencyMS)ms cue=\(descriptor)"
        )
        if verdict.isLate {
            showLog?.appendNow(
                action: .lateTake,
                source: .system,
                detail: "latency=\(verdict.latencyMS)ms cue=\(descriptor)"
            )
        }
    }

    /// E3+ — observe the playback controller's dropped-frame counter and
    /// emit one `.droppedFrame` log entry per 1 s window of accumulated
    /// drops. The debounce keeps long stalls from drowning the show log
    /// in one-per-frame entries; the detail records the burst size so
    /// operators can still see the magnitude post-show.
    ///
    /// Implementation: rather than Combine `throttle` (which emits on a
    /// trailing schedule and complicates testing), every cumulative
    /// publish is examined synchronously. We emit immediately on the
    /// first burst of a session, then suppress further emissions until
    /// `dropFlushInterval` seconds have passed. The next burst after the
    /// quiet window batches everything since the last emission into one
    /// log entry.
    private func wireDroppedFrameLog() {
        droppedFrameCancellable = playback.droppedFrameCounter.$cumulative
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cumulative in
                self?.handleDropCumulative(cumulative, now: Date())
            }
    }

    /// Pure-logic decision so tests can drive the debounce by injecting an
    /// explicit `now` rather than waiting on real time.
    func handleDropCumulative(_ cumulative: Int, now: Date) {
        let previous = lastReportedDropCumulative
        if cumulative < previous {
            // Counter was reset (output stopped). Re-baseline so the next
            // session starts from zero without emitting a phantom negative
            // drop event.
            lastReportedDropCumulative = cumulative
            lastDropLogTime = nil
            return
        }
        let delta = cumulative - previous
        guard delta > 0 else { return }
        if let last = lastDropLogTime,
           now.timeIntervalSince(last) < dropFlushInterval {
            // Still inside the quiet window — accumulate silently. The
            // next emission past the window will batch the deficit.
            return
        }
        lastReportedDropCumulative = cumulative
        lastDropLogTime = now
        showLog?.appendNow(
            action: .droppedFrame,
            source: .system,
            detail: "drops=\(delta) cumulative=\(cumulative)"
        )
    }

    /// Translate a dispatcher-level `ShowControlAction` + `ShowControlSource`
    /// into a `ShowLogEvent`. Verbs map directly; per-cue / output / TC /
    /// workspace actions collapse onto a generic `.oscAction` row with a
    /// short name for the action — operators get a single chronological log
    /// without it ballooning into one row per OSC address.
    private func recordDispatchedAction(_ action: ShowControlAction, source: ShowControlSource) {
        let logSource = source.toShowLogSource()
        switch action {
        case .go(let target):
            showLog?.appendNow(action: .go, source: logSource, detail: target)
        case .previous:
            showLog?.appendNow(action: .previous, source: logSource)
        case .panic(let fade):
            let detail = fade.map { "fade=\(String(format: "%.2f", $0))s" }
            showLog?.appendNow(action: .panic, source: logSource, detail: detail)
        case .clear:
            showLog?.appendNow(action: .clear, source: logSource)
        case .outputBlackout(let enabled):
            showLog?.appendNow(action: .blackout, source: logSource, detail: enabled ? "on" : "off")
        case .showMode(let enabled):
            showLog?.appendNow(
                action: enabled ? .showModeOn : .showModeOff,
                source: logSource
            )
        case .ping, .subscribe, .unsubscribe:
            // Diagnostic chatter — never logs. Subscriptions in particular fire
            // every time a control surface reconnects; logging them would drown
            // the operator-relevant verbs.
            return
        default:
            showLog?.appendNow(
                action: .oscAction,
                source: logSource,
                detail: shortActionName(action)
            )
        }
    }

    private func shortActionName(_ action: ShowControlAction) -> String {
        switch action {
        case .movePlayhead(let n): return "movePlayhead \(n)"
        case .load(let n): return "load \(n)"
        case .cuePlay(let n): return "cuePlay \(n)"
        case .cueStop(let n, _): return "cueStop \(n)"
        case .cueScrubNormalized(let n, _): return "cueScrub \(n)"
        case .cueScrubSeconds(let n, _): return "cueScrubSec \(n)"
        case .cueOpacity(let n, _): return "cueOpacity \(n)"
        case .cueAudioLevel(let n, _): return "cueAudio \(n)"
        case .cueInPoint(let n, _): return "cueIn \(n)"
        case .cueOutPoint(let n, _): return "cueOut \(n)"
        case .cueLoop(let n, _): return "cueLoop \(n)"
        case .cueGoto(let n, _): return "cueGoto \(n)"
        case .cuePreload(let n): return "cuePreload \(n)"
        case .cueNotes(let n, _): return "cueNotes \(n)"
        case .outputFreeze(let on): return "outputFreeze \(on)"
        case .lookRecall(let name): return "lookRecall \(name)"
        case .timecodeSource(let s): return "tcSource \(s)"
        case .timecodeEngaged(let on): return "tcEngaged \(on)"
        case .timecodeOffset(let s): return "tcOffset \(s)"
        case .workspaceSave: return "workspaceSave"
        case .workspaceReload: return "workspaceReload"
        default: return ""
        }
    }

    // MARK: - Verb facade

    /// Fires the playhead cue. UI hotkey: Space.
    func go(source: ShowLogEvent.Source = .operatorButton) {
        let fired = runtime.go()
        showLog?.appendNow(action: .go, source: source, detail: detailString(for: fired))
    }

    /// Jumps to and fires a cue by its operator-visible number.
    func go(targetNumber: String, source: ShowLogEvent.Source = .operatorButton) {
        let fired = runtime.go(targetNumber: targetNumber)
        showLog?.appendNow(action: .go, source: source, detail: detailString(for: fired) ?? "→\(targetNumber)")
    }

    /// Steps the playhead one cue back without firing.
    func previous(source: ShowLogEvent.Source = .operatorButton) {
        runtime.previous()
        showLog?.appendNow(action: .previous, source: source)
    }

    /// Soft panic — fade everything out, lock GO, then resolve after the fade completes.
    /// UI hotkey: Esc.
    func panic(fade: TimeInterval? = nil, source: ShowLogEvent.Source = .operatorButton) {
        let fadeDuration = max(0, fade ?? runtime.defaultPanicFade)
        runtime.panic(fade: fadeDuration)
        playback.clear()
        showLog?.appendNow(action: .panic, source: source, detail: "fade=\(String(format: "%.2f", fadeDuration))s")

        // Schedule auto-completion of the panic after the fade window. The scheduler-driven
        // panic state is the runtime's responsibility, but we drive completion here because
        // the runtime hands the fade to us — there's no async fade-out implemented in the
        // playback layer yet (Phase B work).
        panicCompletionTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.runtime.panicCompleted()
        }
        panicCompletionTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration, execute: task)
    }

    /// Hard kill — instant black + audio mute. UI hotkey: Cmd-Esc (planned).
    func clear(source: ShowLogEvent.Source = .operatorButton) {
        panicCompletionTask?.cancel()
        panicCompletionTask = nil
        runtime.clear()
        playback.clear()
        showLog?.appendNow(action: .clear, source: source)
    }

    /// Toggles the latching blackout flag. UI hotkey: B.
    func toggleBlackout(source: ShowLogEvent.Source = .operatorButton) {
        runtime.toggleBlackout()
        showLog?.appendNow(action: .blackout, source: source)
    }

    /// Toggles Show Mode. UI hotkey: Cmd-Shift-L. Confirm dialog handled by the calling view.
    func toggleShowMode(source: ShowLogEvent.Source = .operatorButton) {
        showMode.toggle()
        showLog?.appendNow(
            action: showMode ? .showModeOn : .showModeOff,
            source: source
        )
    }

    /// Build a CSV-friendly detail string from a fired cue. Empty for nil
    /// (GO rejected — the runtime separately publishes lastGoRejection).
    private func detailString(for cue: Cue?) -> String? {
        cue?.descriptor
    }

    // MARK: - Compositor overlays bridge (B12e)

    /// Forwards the active Stage's persisted overlay state into `PlaybackController` so the
    /// next composed frame picks up the new bug / message. The view layer calls this on every
    /// project mutation (single subscriber); `PlaybackController.compositorOverlays` is the
    /// source of truth for the rendering hot path. Inert overlays cost nothing per the
    /// pipeline's short-circuit.
    func applyCompositorOverlays(_ overlays: CompositorOverlays) {
        playback.compositorOverlays = overlays
    }

    // MARK: - List management

    /// Replaces the runtime's show list when the active list selection changes.
    func setActiveShowList(_ list: ShowList) {
        runtime.replaceShowList(list)
        revision &+= 1
    }

    /// Re-syncs the runtime's show list to a freshly mutated copy from the project model.
    func syncShowListFromProject(_ list: ShowList) {
        runtime.replaceShowList(list)
        revision &+= 1
    }

    /// Returns the currently active show list owned by the runtime.
    var activeShowList: ShowList {
        runtime.showList
    }

    /// Cue at the playhead (or nil if past end).
    var playheadCue: Cue? { runtime.showList.playheadCue }

    /// Cue currently fired/running, or nil if none.
    var runningCue: Cue? {
        guard let liveCueID else { return nil }
        return runtime.showList.cue(id: liveCueID)
    }

    func standbyState(of cueID: UUID) -> CueStandbyState {
        runtime.state(of: cueID)
    }

    // MARK: - Internal wiring

    private func wireRuntime() {
        runtime.onCueFired = { [weak self] cue, _ in
            DispatchQueue.main.async {
                self?.handleCueFired(cue)
            }
        }
        runtime.onCueEnded = { [weak self] cue in
            DispatchQueue.main.async {
                self?.handleCueEnded(cue)
            }
        }
        runtime.onCueStateChanged = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.revision &+= 1
            }
        }
        runtime.onPlayheadChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.revision &+= 1
            }
        }
        runtime.onBlackoutChanged = { [weak self] active in
            DispatchQueue.main.async {
                self?.blackout = active
                // Phase B will route blackout through the compositor; today we approximate
                // with playback.clear() on toggle-on. A latching blackout that survives
                // takes is a Phase B+ feature.
                if active {
                    self?.playback.clear()
                }
            }
        }
        runtime.onPanicChanged = { [weak self] active, _ in
            DispatchQueue.main.async {
                self?.panicActive = active
                if active {
                    // PANIC interrupts the in-flight take; abandon any pending
                    // late-take measurement so the next GO doesn't measure
                    // against a stale firedAt.
                    self?.lateTakeDetector.clearPending()
                    self?.pendingLateTakeCueDescriptor = nil
                }
            }
        }
        runtime.onGoRejected = { [weak self] reason in
            DispatchQueue.main.async {
                self?.lastGoRejection = reason
            }
        }
    }

    private func handleCueFired(_ cue: Cue) {
        liveCueID = cue.id
        revision &+= 1

        // E5 — record this fire in the take history. `videoDuration` is set
        // asynchronously after `playback.take(...)`, so capturing here yields
        // the *previous* take's duration on the first observation. We sample
        // it as a best-effort hint; nil on image cues (videoDuration == 0).
        let durationHint: TimeInterval? = playback.videoDuration > 0
            ? playback.videoDuration
            : nil
        takeHistory?.recordFire(cue: cue, durationSecondsAtFire: durationHint)

        guard let asset = assetLookup(cue.assetID) else {
            // Missing asset is a runtime error: the cue references an asset that no longer
            // exists in the library. Phase C will treat this as a non-blocking warning and
            // surface it in the inspector. For now, end the cue immediately so the runtime
            // returns to idle and chains can advance.
            showLog?.appendNow(action: .missingMedia, source: .system, detail: cue.descriptor)
            runtime.cueDidEnd(cueID: cue.id)
            return
        }

        let (deviceID, modeID) = outputBindingLookup()
        let resolvedTransition = effectiveTransitionSettings(for: cue)
        // E3+ tail — start the late-take measurement just before kicking off
        // the take so the GO timestamp is as close to the operator press as
        // we can capture inside the controller. The detector matches on
        // slideID; cache the cue's human descriptor for the log detail.
        let goFiredAt = Date()
        pendingLateTakeCueDescriptor = cue.descriptor
        lateTakeDetector.recordGoFired(cueID: cue.id, slideID: asset.id, at: goFiredAt)
        playback.take(
            slide: asset,
            deviceID: deviceID,
            modeID: modeID,
            transitionSettings: resolvedTransition
        )
    }

    /// Internal so tests can drive cue-end emission deterministically without
    /// staging a full cue lifecycle through the runtime + DispatchQueue.main
    /// hop. Mirrors `handleLiveSlideTransition`'s test seam shape.
    func handleCueEnded(_ cue: Cue) {
        if liveCueID == cue.id {
            liveCueID = nil
        }
        revision &+= 1
        // v2 Post-Show Summary precondition (Q2-A) — emit `.cueEnded` so the
        // reducer can compute per-cue runtime as (cueEnded - go). The detail
        // matches the `.go` event's descriptor (cue.number when present, else
        // cue.title) so the reducer pairs them by descriptor.
        showLog?.appendNow(action: .cueEnded, source: .system, detail: cue.descriptor)
    }

    /// Resolve transition settings for a cue: per-cue crossfade duration overrides the project
    /// default; everything else inherits.
    private func effectiveTransitionSettings(for cue: Cue) -> PlayoutTransitionSettings {
        var base = transitionSettingsLookup()
        if let override = cue.overrides.crossfadeDuration {
            base.crossfadeEnabled = override > 0
            base.crossfadeDuration = PlayoutTransitionSettings.clampedDuration(override)
        }
        return base
    }
}
