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

    private let playback: PlaybackController
    private let assetLookup: (UUID) -> MediaSlide?
    private let transitionSettingsLookup: () -> PlayoutTransitionSettings
    private let outputBindingLookup: () -> (deviceID: String?, modeID: String?)
    private var panicCompletionTask: DispatchWorkItem?

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
        // OSC/HTTP/Companion route GO/PANIC/etc. to this show list.
        ShowControlHub.shared.bind(runtime: runtime)
    }

    // MARK: - Verb facade

    /// Fires the playhead cue. UI hotkey: Space.
    func go() {
        runtime.go()
    }

    /// Jumps to and fires a cue by its operator-visible number.
    func go(targetNumber: String) {
        runtime.go(targetNumber: targetNumber)
    }

    /// Steps the playhead one cue back without firing.
    func previous() {
        runtime.previous()
    }

    /// Soft panic — fade everything out, lock GO, then resolve after the fade completes.
    /// UI hotkey: Esc.
    func panic(fade: TimeInterval? = nil) {
        let fadeDuration = max(0, fade ?? runtime.defaultPanicFade)
        runtime.panic(fade: fadeDuration)
        playback.clear()

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
    func clear() {
        panicCompletionTask?.cancel()
        panicCompletionTask = nil
        runtime.clear()
        playback.clear()
    }

    /// Toggles the latching blackout flag. UI hotkey: B.
    func toggleBlackout() {
        runtime.toggleBlackout()
    }

    /// Toggles Show Mode. UI hotkey: Cmd-Shift-L. Confirm dialog handled by the calling view.
    func toggleShowMode() {
        showMode.toggle()
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
