import Foundation

/// Canonical action vocabulary. Every operator action — local hotkey, OSC, HTTP,
/// Companion button — maps to one `ShowControlAction` value. A single dispatcher
/// (`ShowControlDispatcher`) interprets these against `CueRuntime` so the
/// transport surface and the local UI never diverge.
///
/// Mirrors the `/sp/...` OSC namespace defined in `feature_spec.md` §3.12.
enum ShowControlAction: Equatable {
    // Show-runtime verbs.
    case go(target: String?)
    case previous
    case panic(fade: TimeInterval?)
    case clear
    case movePlayhead(cueNumber: String)
    case load(cueNumber: String)

    // Per-cue verbs.
    case cuePlay(cueNumber: String)
    case cueStop(cueNumber: String, fade: TimeInterval?)
    case cueScrubNormalized(cueNumber: String, position: Float)
    case cueScrubSeconds(cueNumber: String, seconds: Float)
    case cueOpacity(cueNumber: String, value: Float)
    case cueAudioLevel(cueNumber: String, dB: Float)
    case cueInPoint(cueNumber: String, seconds: Float)
    case cueOutPoint(cueNumber: String, seconds: Float)
    case cueLoop(cueNumber: String, enabled: Bool)
    case cueGoto(cueNumber: String, nextNumber: String)
    case cuePreload(cueNumber: String)
    case cueNotes(cueNumber: String, text: String)

    // Output verbs.
    case outputFreeze(enabled: Bool)
    case outputBlackout(enabled: Bool)
    case lookRecall(name: String)

    // Timecode verbs.
    case timecodeSource(spec: String)
    case timecodeEngaged(enabled: Bool)
    case timecodeOffset(seconds: Float)

    // Workspace.
    case showMode(enabled: Bool)
    case workspaceSave
    case workspaceReload

    // Diagnostic.
    case ping
    case subscribe(host: String, port: UInt16)
    case unsubscribe(host: String, port: UInt16)
}

/// Capabilities required to perform an action. Tokens carry a set of caps;
/// dispatcher rejects an action whose required cap isn't in the token's set.
enum ShowControlCapability: String, Codable, CaseIterable, Hashable {
    case read
    case fire
    case edit
}

extension ShowControlAction {
    /// The capability a caller must hold to perform this action.
    var requiredCapability: ShowControlCapability {
        switch self {
        case .ping, .subscribe, .unsubscribe:
            return .read
        case .go, .previous, .panic, .clear, .movePlayhead, .load,
             .cuePlay, .cueStop, .cueScrubNormalized, .cueScrubSeconds,
             .cueOpacity, .cueAudioLevel, .cuePreload,
             .outputFreeze, .outputBlackout, .lookRecall,
             .timecodeSource, .timecodeEngaged, .timecodeOffset,
             .workspaceSave, .workspaceReload, .showMode:
            return .fire
        case .cueInPoint, .cueOutPoint, .cueLoop, .cueGoto, .cueNotes:
            return .edit
        }
    }
}

/// Unique idempotency key for retrigger lockout. Two actions with the same key
/// arriving within `retriggerLockoutSeconds` collapse to one. Per-cue verbs key
/// by cue number; global verbs key by their action name.
extension ShowControlAction {
    var idempotencyKey: String {
        switch self {
        case let .go(target):
            return "go:\(target ?? "<playhead>")"
        case .previous:
            return "previous"
        case .panic:
            return "panic"
        case .clear:
            return "clear"
        case let .movePlayhead(num):
            return "playhead:\(num.lowercased())"
        case let .load(num):
            return "load:\(num.lowercased())"
        case let .cuePlay(num):
            return "cue.play:\(num.lowercased())"
        case let .cueStop(num, _):
            return "cue.stop:\(num.lowercased())"
        case let .cueScrubNormalized(num, _):
            return "cue.scrub.norm:\(num.lowercased())"
        case let .cueScrubSeconds(num, _):
            return "cue.scrub.seconds:\(num.lowercased())"
        case let .cueOpacity(num, _):
            return "cue.opacity:\(num.lowercased())"
        case let .cueAudioLevel(num, _):
            return "cue.audio:\(num.lowercased())"
        case let .cueInPoint(num, _):
            return "cue.in:\(num.lowercased())"
        case let .cueOutPoint(num, _):
            return "cue.out:\(num.lowercased())"
        case let .cueLoop(num, _):
            return "cue.loop:\(num.lowercased())"
        case let .cueGoto(num, _):
            return "cue.goto:\(num.lowercased())"
        case let .cuePreload(num):
            return "cue.preload:\(num.lowercased())"
        case let .cueNotes(num, _):
            return "cue.notes:\(num.lowercased())"
        case let .outputFreeze(enabled):
            return "output.freeze:\(enabled)"
        case let .outputBlackout(enabled):
            return "output.blackout:\(enabled)"
        case let .lookRecall(name):
            return "look.recall:\(name)"
        case let .timecodeSource(spec):
            return "tc.source:\(spec)"
        case let .timecodeEngaged(enabled):
            return "tc.engaged:\(enabled)"
        case let .timecodeOffset(seconds):
            return "tc.offset:\(seconds)"
        case let .showMode(enabled):
            return "show_mode:\(enabled)"
        case .workspaceSave:
            return "workspace.save"
        case .workspaceReload:
            return "workspace.reload"
        case .ping:
            return "ping"
        case let .subscribe(host, port):
            return "subscribe:\(host):\(port)"
        case let .unsubscribe(host, port):
            return "unsubscribe:\(host):\(port)"
        }
    }
}

/// One outcome of dispatching an action — what to put in the reply envelope.
enum ShowControlActionResult: Equatable {
    case ok(data: [String: ShowControlValue])
    case rejected(reason: String)
}

/// JSON-friendly value type for action result data.
/// Avoids `Any` so encoding stays type-safe.
enum ShowControlValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([ShowControlValue])
    case object([String: ShowControlValue])
}
