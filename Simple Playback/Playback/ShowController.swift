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

    private let playback: PlaybackController
    private let assetLookup: (UUID) -> MediaSlide?
    private let transitionSettingsLookup: () -> PlayoutTransitionSettings
    private let outputBindingLookup: () -> (deviceID: String?, modeID: String?)
    private var panicCompletionTask: DispatchWorkItem?
    private var droppedFrameCancellable: AnyCancellable?
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
        // Hand this document's runtime to the process-wide show-control hub so
        // OSC/HTTP/Companion route GO/PANIC/etc. to this show list. Also pipe
        // the dispatcher's `onActionDispatched` callback into our show log so
        // every remote-driven action lands with its source attribution (host,
        // port, transport, etc.).
        ShowControlHub.shared.bind(runtime: runtime)
        ShowControlHub.shared.stack.dispatcher.onActionDispatched = { [weak self] action, source, _ in
            self?.recordDispatchedAction(action, source: source)
        }
        wireDroppedFrameLog()
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
        guard let cue else { return nil }
        let id = cue.number.isEmpty ? cue.title : cue.number
        return id
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

        guard let asset = assetLookup(cue.assetID) else {
            // Missing asset is a runtime error: the cue references an asset that no longer
            // exists in the library. Phase C will treat this as a non-blocking warning and
            // surface it in the inspector. For now, end the cue immediately so the runtime
            // returns to idle and chains can advance.
            let detail = cue.number.isEmpty ? cue.title : cue.number
            showLog?.appendNow(action: .missingMedia, source: .system, detail: detail)
            runtime.cueDidEnd(cueID: cue.id)
            return
        }

        let (deviceID, modeID) = outputBindingLookup()
        let resolvedTransition = effectiveTransitionSettings(for: cue)
        playback.take(
            slide: asset,
            deviceID: deviceID,
            modeID: modeID,
            transitionSettings: resolvedTransition
        )
    }

    private func handleCueEnded(_ cue: Cue) {
        if liveCueID == cue.id {
            liveCueID = nil
        }
        revision &+= 1
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
