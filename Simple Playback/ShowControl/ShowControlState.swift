import Foundation

/// Snapshot of show-control-relevant state. Updated by `CueRuntime` callbacks
/// and timecode reader callbacks; read by transports building OSC/HTTP replies
/// and by the subscription pump building state-change notifications.
///
/// All access through `ShowControlState` goes through its serial queue so
/// readers and writers don't race. The state itself is a value type returned by
/// `snapshot()`.
public final class ShowControlState {
    private let queue = DispatchQueue(label: "com.josh.simpleplayback.showcontrol.state")

    private var _showList: ShowList = ShowList()
    private var _cueStates: [UUID: CueStandbyState] = [:]
    private var _blackout: Bool = false
    private var _panicActive: Bool = false
    private var _onAir: Bool = true

    private var _timecodeSource: String = "off"
    private var _timecodeEngaged: Bool = false
    private var _timecodeLocked: Bool = false
    private var _timecodeNow: String = "00:00:00:00"
    private var _timecodeOffset: TimeInterval = 0

    private var _showModeEnabled: Bool = false

    private var _cueElapsed: [UUID: TimeInterval] = [:]
    private var _cueRemaining: [UUID: TimeInterval] = [:]

    /// Wall-clock seconds when the runtime started (for `/sp/ping` uptime).
    public let startedAt: TimeInterval = Date().timeIntervalSinceReferenceDate

    public init() {}

    // MARK: - Snapshot

    public struct Snapshot: Equatable {
        public var showList: ShowList
        public var cueStates: [UUID: CueStandbyState]
        public var blackout: Bool
        public var panicActive: Bool
        public var onAir: Bool
        public var timecodeSource: String
        public var timecodeEngaged: Bool
        public var timecodeLocked: Bool
        public var timecodeNow: String
        public var timecodeOffset: TimeInterval
        public var showModeEnabled: Bool
        public var cueElapsed: [UUID: TimeInterval]
        public var cueRemaining: [UUID: TimeInterval]
        public var uptime: TimeInterval
    }

    public func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(
                showList: _showList,
                cueStates: _cueStates,
                blackout: _blackout,
                panicActive: _panicActive,
                onAir: _onAir,
                timecodeSource: _timecodeSource,
                timecodeEngaged: _timecodeEngaged,
                timecodeLocked: _timecodeLocked,
                timecodeNow: _timecodeNow,
                timecodeOffset: _timecodeOffset,
                showModeEnabled: _showModeEnabled,
                cueElapsed: _cueElapsed,
                cueRemaining: _cueRemaining,
                uptime: Date().timeIntervalSinceReferenceDate - startedAt
            )
        }
    }

    // MARK: - Updates from CueRuntime

    public func updateShowList(_ list: ShowList) {
        queue.sync {
            _showList = list
            // Reseed cue states for any new cues; drop stale.
            let live = Set(list.cues.map(\.id))
            for cueID in _cueStates.keys where !live.contains(cueID) {
                _cueStates.removeValue(forKey: cueID)
                _cueElapsed.removeValue(forKey: cueID)
                _cueRemaining.removeValue(forKey: cueID)
            }
            for cue in list.cues where _cueStates[cue.id] == nil {
                _cueStates[cue.id] = .idle
            }
        }
    }

    public func updateCueState(cueID: UUID, state: CueStandbyState) {
        queue.sync {
            _cueStates[cueID] = state
            if state == .idle {
                _cueElapsed[cueID] = 0
                _cueRemaining[cueID] = 0
            }
        }
    }

    public func updatePlayhead(cueID: UUID?) {
        queue.sync {
            _showList.playheadCueID = cueID
        }
    }

    public func updatePanic(_ active: Bool) {
        queue.sync { _panicActive = active }
    }

    public func updateBlackout(_ active: Bool) {
        queue.sync { _blackout = active }
    }

    public func updateOnAir(_ onAir: Bool) {
        queue.sync { _onAir = onAir }
    }

    public func updateTimecode(
        source: String? = nil,
        engaged: Bool? = nil,
        locked: Bool? = nil,
        now: String? = nil,
        offset: TimeInterval? = nil
    ) {
        queue.sync {
            if let source { _timecodeSource = source }
            if let engaged { _timecodeEngaged = engaged }
            if let locked { _timecodeLocked = locked }
            if let now { _timecodeNow = now }
            if let offset { _timecodeOffset = offset }
        }
    }

    public func updateShowMode(_ enabled: Bool) {
        queue.sync { _showModeEnabled = enabled }
    }

    public func updateCueElapsed(cueID: UUID, elapsed: TimeInterval, remaining: TimeInterval) {
        queue.sync {
            _cueElapsed[cueID] = elapsed
            _cueRemaining[cueID] = remaining
        }
    }
}
