import Foundation

/// Drives the 10 Hz state push when at least one OSC or WebSocket subscriber
/// exists. Idle (zero-rate) when no one is listening — operators sometimes
/// run a show with no remote-control rig at all and we shouldn't waste CPU.
///
/// Pushes carry per-cue and per-show variables defined in spec §3.14:
/// - `cue_id`, `cue_name`, `cue_remaining_string`, `cue_elapsed_string`
/// - globals: `playhead_id`, `playhead_name`, `next_id`, `tc_locked`,
///   `tc_now`, `onair`, `panic`, `blackout`, `show_mode`, `uptime`.
///
/// Per-cue feedbacks (running, standby, is-playhead, elapsed > X,
/// remaining < X) are computed from these fields by the receiving Companion
/// module — we just publish the raw state.
final class SubscriptionPump {
    weak var state: ShowControlState?
    var subscriptions: SubscriptionRegistry?

    /// Override for tests: the closure called instead of `Timer.scheduledTimer`.
    var schedule: ((TimeInterval, @escaping () -> Void) -> SubscriptionPumpToken)?

    private var token: SubscriptionPumpToken?
    private var lastSentSnapshot: SnapshotDigest?

    /// Push interval in seconds (default 10 Hz).
    var pushInterval: TimeInterval = 0.1

    init(state: ShowControlState, subscriptions: SubscriptionRegistry?) {
        self.state = state
        self.subscriptions = subscriptions
    }

    func start() {
        guard token == nil else { return }
        let scheduler = schedule ?? { interval, work in
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(10))
            timer.setEventHandler(handler: work)
            timer.resume()
            return SubscriptionPumpToken { timer.cancel() }
        }
        token = scheduler(pushInterval) { [weak self] in
            self?.tick()
        }
    }

    func stop() {
        token?.cancel()
        token = nil
    }

    /// Performs one push iteration. Public for tests.
    func tick() {
        guard let subs = subscriptions, subs.hasSubscribers else { return }
        guard let snap = state?.snapshot() else { return }
        let digest = SnapshotDigest(snap)
        let force = digest.requiresImmediatePush || lastSentSnapshot == nil
        // Always push at the 10 Hz rate — but skip if nothing changed and the
        // value-only fields (uptime, elapsed) have moved less than 100 ms.
        if !force, digest == lastSentSnapshot { return }
        lastSentSnapshot = digest

        // Globals first.
        push(globals: snap)

        // Per-cue.
        push(perCue: snap)
    }

    private func push(globals snap: ShowControlState.Snapshot) {
        let playhead = snap.showList.playheadCue
        let next = snap.showList.nextCueAfterPlayhead
        let payload: [String: ShowControlValue] = [
            "playhead_id": playhead.map { .string($0.number) } ?? .null,
            "playhead_name": playhead.map { .string($0.title) } ?? .null,
            "next_id": next.map { .string($0.number) } ?? .null,
            "tc_locked": .bool(snap.timecodeLocked),
            "tc_now": .string(snap.timecodeNow),
            "onair": .bool(snap.onAir),
            "panic": .bool(snap.panicActive),
            "blackout": .bool(snap.blackout),
            "show_mode": .bool(snap.showModeEnabled),
            "uptime": .double(snap.uptime),
        ]
        emit(address: "/sp/state/globals", payload: payload)
    }

    private func push(perCue snap: ShowControlState.Snapshot) {
        for cue in snap.showList.cues {
            let state = snap.cueStates[cue.id] ?? .idle
            let elapsed = snap.cueElapsed[cue.id] ?? 0
            let remaining = snap.cueRemaining[cue.id] ?? 0
            let isPlayhead = (snap.showList.playheadCue?.id == cue.id)
            let payload: [String: ShowControlValue] = [
                "cue_id": .string(cue.number),
                "cue_name": .string(cue.title),
                "cue_state": .string(state.rawValue),
                "running": .bool(state == .running),
                "standby": .bool(state == .loaded),
                "is_playhead": .bool(isPlayhead),
                "elapsed": .double(elapsed),
                "remaining": .double(remaining),
                "cue_elapsed_string": .string(SubscriptionPump.formatDuration(elapsed)),
                "cue_remaining_string": .string(SubscriptionPump.formatDuration(remaining)),
            ]
            emit(address: "/sp/state/cue/\(cue.number)", payload: payload)
            // Discrete feedback addresses for Companion to subscribe to.
            emit(address: "/sp/state/cue/\(cue.number)/running",
                 payload: ["value": .int(state == .running ? 1 : 0)])
            emit(address: "/sp/state/cue/\(cue.number)/standby",
                 payload: ["value": .int(state == .loaded ? 1 : 0)])
            emit(address: "/sp/state/cue/\(cue.number)/is_playhead",
                 payload: ["value": .int(isPlayhead ? 1 : 0)])
            emit(address: "/sp/state/cue/\(cue.number)/elapsed",
                 payload: ["value": .double(elapsed)])
            emit(address: "/sp/state/cue/\(cue.number)/remaining",
                 payload: ["value": .double(remaining)])
        }
    }

    private func emit(address: String, payload: [String: ShowControlValue]) {
        // OSC: send a JSON-blob argument, mirroring the reply envelope shape so
        // subscribers parse one format.
        let json = ShowControlReplyEnvelope.jsonString(
            address: address,
            result: .ok(data: payload)
        )
        let osc = OSCMessage(address: address, arguments: [.string(json)])
        subscriptions?.broadcastOSC(osc)

        // WebSocket: same JSON plus the address as a separate field at the top
        // level so clients don't need to parse twice.
        if let body = try? JSONEncoder.standard().encode(JSONValueDict([
            "apiVersion": .int(SHOW_CONTROL_API_VERSION),
            "address": .string(address),
            "data": .object(payload)
        ])) {
            subscriptions?.broadcastWebSocket(body)
        }
    }

    /// Formats `seconds` as `HH:MM:SS.mmm` per QLab/Mitti convention.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00:00.000" }
        let totalMs = Int(seconds * 1000)
        let h = totalMs / 3_600_000
        let m = (totalMs % 3_600_000) / 60_000
        let s = (totalMs % 60_000) / 1000
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}

/// Cancellable handle for the pump's scheduled timer.
final class SubscriptionPumpToken {
    private let cancelClosure: () -> Void
    init(cancel: @escaping () -> Void) { self.cancelClosure = cancel }
    func cancel() { cancelClosure() }
}

/// Compares two state snapshots by the fields the pump cares about. Used to
/// suppress redundant pushes when literally nothing has changed (rare, but
/// avoids waking subscribers that don't need the kick).
private struct SnapshotDigest: Equatable {
    let playhead: UUID?
    let blackout: Bool
    let panic: Bool
    let onAir: Bool
    let showMode: Bool
    let tcLocked: Bool
    let tcNow: String
    let cueStates: [UUID: CueStandbyState]

    init(_ s: ShowControlState.Snapshot) {
        playhead = s.showList.playheadCueID
        blackout = s.blackout
        panic = s.panicActive
        onAir = s.onAir
        showMode = s.showModeEnabled
        tcLocked = s.timecodeLocked
        tcNow = s.timecodeNow
        cueStates = s.cueStates
    }

    /// Some changes always force an immediate push — panic, blackout, and
    /// playhead changes are too important to skip.
    var requiresImmediatePush: Bool { false }
}
