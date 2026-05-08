import Foundation

/// API version emitted in every reply envelope. Bumped when the address shape
/// changes in a backward-incompatible way.
let SHOW_CONTROL_API_VERSION = 1

/// Default per-action retrigger lockout window — duplicate actions arriving
/// within this window collapse to a single dispatch (per spec §3.14 / research §6).
let SHOW_CONTROL_RETRIGGER_LOCKOUT: TimeInterval = 0.05

/// Source attribution attached to every dispatched action. Phase E will use
/// this to write to the show log; Phase D records it in subscription pushes
/// and reply envelopes.
enum ShowControlSource: Equatable {
    case local
    case osc(host: String, port: UInt16, transport: OSCTransportKind)
    case http(token: String, host: String)
    case timecode
    case test

    var label: String {
        switch self {
        case .local: return "local"
        case let .osc(host, port, transport):
            return "osc/\(transport.rawValue) \(host):\(port)"
        case let .http(_, host): return "http \(host)"
        case .timecode: return "timecode"
        case .test: return "test"
        }
    }
}

enum OSCTransportKind: String, Equatable {
    case udp
    case tcp
}

/// Dispatcher: turns `ShowControlAction` values into calls on `CueRuntime` and
/// other show-mode-aware sinks, and produces a structured reply.
///
/// All transports talk to the same dispatcher. Idempotency, capability checks,
/// show-mode capability stripping, and source attribution all happen here.
final class ShowControlDispatcher {
    var runtime: CueRuntime?
    let state: ShowControlState
    var clock: () -> TimeInterval

    /// Hook so the host can intercept actions that don't map directly onto
    /// `CueRuntime` (output freeze, look recall, workspace save…). Returns
    /// `nil` if the dispatcher should handle the action with default semantics.
    var hostInterceptor: ((ShowControlAction, ShowControlSource) -> ShowControlActionResult?)?

    /// Notified after every successful dispatch (post-idempotency, post-cap-check).
    /// Used by the show log writer in Phase E.
    var onActionDispatched: ((ShowControlAction, ShowControlSource, ShowControlActionResult) -> Void)?

    /// When set, controls TC source. Phase D wires the timecode reader through this.
    var timecodeSourceSetter: ((String) -> Bool)?
    var timecodeEngagementSetter: ((Bool) -> Bool)?
    var timecodeOffsetSetter: ((TimeInterval) -> Void)?

    /// Show-mode toggle (defers to host so the SwiftUI side can confirm).
    var showModeToggle: ((Bool) -> Void)?

    /// Subscription manager invoked by `subscribe`/`unsubscribe`.
    var subscribe: ((String, UInt16) -> Void)?
    var unsubscribe: ((String, UInt16) -> Void)?

    private let lockoutQueue = DispatchQueue(label: "com.josh.simpleplayback.showcontrol.dispatch")
    private var lastFireByKey: [String: TimeInterval] = [:]

    var retriggerLockout: TimeInterval = SHOW_CONTROL_RETRIGGER_LOCKOUT

    init(
        runtime: CueRuntime?,
        state: ShowControlState,
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.runtime = runtime
        self.state = state
        self.clock = clock
    }

    /// Dispatches an action against the runtime. Honors capability flags,
    /// show-mode lockouts, and per-action retrigger debounce.
    @discardableResult
    func dispatch(
        _ action: ShowControlAction,
        source: ShowControlSource,
        capabilities: Set<ShowControlCapability>
    ) -> ShowControlActionResult {
        // Capability check.
        let required = action.requiredCapability
        let effectiveCaps = effectiveCapabilities(capabilities)
        guard effectiveCaps.contains(required) else {
            let reason = "missing_capability:\(required.rawValue)"
            let result = ShowControlActionResult.rejected(reason: reason)
            onActionDispatched?(action, source, result)
            return result
        }

        // Idempotency lockout.
        let now = clock()
        let key = action.idempotencyKey
        let suppressed: Bool = lockoutQueue.sync {
            if let last = lastFireByKey[key], (now - last) < retriggerLockout {
                return true
            }
            lastFireByKey[key] = now
            return false
        }
        if suppressed {
            let result = ShowControlActionResult.rejected(reason: "retrigger_lockout")
            onActionDispatched?(action, source, result)
            return result
        }

        // Host interceptor first chance.
        if let hosted = hostInterceptor?(action, source) {
            onActionDispatched?(action, source, hosted)
            return hosted
        }

        let result = perform(action, source: source)
        onActionDispatched?(action, source, result)
        return result
    }

    /// Computes the *effective* capability set for a token in the current
    /// show mode. Show Mode strips `edit` from every non-admin token.
    func effectiveCapabilities(_ caps: Set<ShowControlCapability>) -> Set<ShowControlCapability> {
        if state.snapshot().showModeEnabled {
            return caps.subtracting([.edit])
        }
        return caps
    }

    // MARK: - Default action handlers

    private func perform(_ action: ShowControlAction, source: ShowControlSource) -> ShowControlActionResult {
        guard let runtime = runtime else {
            return .rejected(reason: "no_runtime")
        }
        switch action {
        case let .go(target):
            if let target {
                if let cue = runtime.go(targetNumber: target) {
                    return .ok(data: ["fired": .string(cue.number)])
                }
                return .rejected(reason: "go_failed")
            }
            if let cue = runtime.go() {
                return .ok(data: ["fired": .string(cue.number)])
            }
            return .rejected(reason: "go_failed")

        case .previous:
            runtime.previous()
            let head = runtime.showList.playheadCue?.number ?? ""
            return .ok(data: ["playhead": .string(head)])

        case let .panic(fade):
            runtime.panic(fade: fade)
            return .ok(data: ["fade": .double(fade ?? runtime.defaultPanicFade)])

        case .clear:
            runtime.clear()
            return .ok(data: [:])

        case let .movePlayhead(cueNumber):
            guard let cue = runtime.showList.cue(number: cueNumber) else {
                return .rejected(reason: "unknown_cue")
            }
            runtime.mutateShowList { list in
                list.movePlayhead(to: cue.id)
            }
            return .ok(data: ["playhead": .string(cue.number)])

        case let .load(cueNumber):
            guard let cue = runtime.showList.cue(number: cueNumber) else {
                return .rejected(reason: "unknown_cue")
            }
            runtime.markLoaded(cueID: cue.id)
            return .ok(data: ["loaded": .string(cue.number)])

        case let .cuePlay(cueNumber):
            if let cue = runtime.go(targetNumber: cueNumber) {
                return .ok(data: ["fired": .string(cue.number)])
            }
            return .rejected(reason: "play_failed")

        case let .cueStop(cueNumber, _):
            // The runtime exposes only blanket clear. Per-cue stop requires
            // playback-controller cooperation; for now, when the cue is
            // running we end it via cueDidEnd (which idles + fires onCueEnded).
            guard let cue = runtime.showList.cue(number: cueNumber) else {
                return .rejected(reason: "unknown_cue")
            }
            if runtime.state(of: cue.id) == .running {
                runtime.cueDidEnd(cueID: cue.id)
                return .ok(data: ["stopped": .string(cue.number)])
            }
            return .rejected(reason: "not_running")

        case let .cueScrubNormalized(cueNumber, _),
             let .cueScrubSeconds(cueNumber, _),
             let .cueOpacity(cueNumber, _),
             let .cueAudioLevel(cueNumber, _):
            // These require the playback layer (decoder/audio pump) to honour
            // them. Without a host interceptor we ack the address but record
            // that the runtime did not act.
            guard let cue = runtime.showList.cue(number: cueNumber) else {
                return .rejected(reason: "unknown_cue")
            }
            return .ok(data: ["cue": .string(cue.number), "applied": .bool(false)])

        case let .cueInPoint(cueNumber, seconds),
             let .cueOutPoint(cueNumber, seconds):
            guard let cue = runtime.showList.cue(number: cueNumber) else {
                return .rejected(reason: "unknown_cue")
            }
            runtime.mutateShowList { list in
                if let idx = list.cueIndex(id: cue.id) {
                    if case let .cueInPoint(_, s) = action { list.cues[idx].overrides.inPoint = TimeInterval(s) }
                    if case let .cueOutPoint(_, s) = action { list.cues[idx].overrides.outPoint = TimeInterval(s) }
                    _ = seconds
                }
            }
            return .ok(data: ["cue": .string(cue.number)])

        case let .cueLoop(cueNumber, enabled):
            guard let cue = runtime.showList.cue(number: cueNumber) else {
                return .rejected(reason: "unknown_cue")
            }
            runtime.mutateShowList { list in
                if let idx = list.cueIndex(id: cue.id) {
                    list.cues[idx].overrides.loop = enabled
                }
            }
            return .ok(data: ["cue": .string(cue.number), "loop": .bool(enabled)])

        case let .cueGoto(cueNumber, _):
            guard runtime.showList.cue(number: cueNumber) != nil else {
                return .rejected(reason: "unknown_cue")
            }
            // GoTo is a chain-rewrite future feature; ack but store nothing yet.
            return .ok(data: ["cue": .string(cueNumber), "applied": .bool(false)])

        case let .cuePreload(cueNumber):
            guard let cue = runtime.showList.cue(number: cueNumber) else {
                return .rejected(reason: "unknown_cue")
            }
            runtime.markLoaded(cueID: cue.id)
            return .ok(data: ["preloaded": .string(cue.number)])

        case let .cueNotes(cueNumber, text):
            guard let cue = runtime.showList.cue(number: cueNumber) else {
                return .rejected(reason: "unknown_cue")
            }
            runtime.mutateShowList { list in
                if let idx = list.cueIndex(id: cue.id) {
                    list.cues[idx].notes = text
                }
            }
            return .ok(data: ["cue": .string(cue.number)])

        case let .outputBlackout(enabled):
            runtime.setBlackout(enabled)
            return .ok(data: ["blackout": .bool(enabled)])

        case let .outputFreeze(enabled):
            // Host interceptor is the right place; default no-op ack.
            return .ok(data: ["freeze": .bool(enabled), "applied": .bool(false)])

        case let .lookRecall(name):
            return .ok(data: ["look": .string(name), "applied": .bool(false)])

        case let .timecodeSource(spec):
            let ok = timecodeSourceSetter?(spec) ?? false
            state.updateTimecode(source: spec)
            return .ok(data: ["source": .string(spec), "applied": .bool(ok)])

        case let .timecodeEngaged(enabled):
            let ok = timecodeEngagementSetter?(enabled) ?? false
            state.updateTimecode(engaged: enabled)
            return .ok(data: ["engaged": .bool(enabled), "applied": .bool(ok)])

        case let .timecodeOffset(seconds):
            timecodeOffsetSetter?(TimeInterval(seconds))
            state.updateTimecode(offset: TimeInterval(seconds))
            return .ok(data: ["offset": .double(Double(seconds))])

        case let .showMode(enabled):
            state.updateShowMode(enabled)
            showModeToggle?(enabled)
            return .ok(data: ["showMode": .bool(enabled)])

        case .workspaceSave:
            return .ok(data: ["applied": .bool(false)])

        case .workspaceReload:
            return .ok(data: ["applied": .bool(false)])

        case .ping:
            let snap = state.snapshot()
            return .ok(data: ["uptime": .double(snap.uptime)])

        case let .subscribe(host, port):
            subscribe?(host, port)
            return .ok(data: ["host": .string(host), "port": .int(Int(port))])

        case let .unsubscribe(host, port):
            unsubscribe?(host, port)
            return .ok(data: ["host": .string(host), "port": .int(Int(port))])
        }
    }
}
