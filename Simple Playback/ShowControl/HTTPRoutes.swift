import Foundation

/// HTTP route mapping. Mirrors the `/sp/*` OSC address surface as
/// `POST /api/v1/...` and `GET /api/v1/...`. Decoding logic is shared with
/// the OSC adapter — both transports produce a `ShowControlAction`.
enum HTTPRoutes {
    /// Decodes an HTTP request into either a `ShowControlAction` (when the
    /// route maps to one) or a state-snapshot read intent. Returns `nil` for
    /// unknown routes.
    static func action(method: String, path: String, body: Data?) -> HTTPAction? {
        // Strip /api/v1 prefix.
        let lowered = method.uppercased()
        let prefix = "/api/v1"
        guard path.hasPrefix(prefix) else {
            // Allow OSCQuery-style root listing at /
            if path == "/" { return .stateSnapshot }
            return nil
        }
        let tail = String(path.dropFirst(prefix.count)).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let bodyJSON: [String: Any]
        if let body, !body.isEmpty,
           let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            bodyJSON = obj
        } else {
            bodyJSON = [:]
        }

        // GET /api/v1/state
        if lowered == "GET", tail == ["state"] {
            return .stateSnapshot
        }
        // GET /api/v1/cues — full cue list
        if lowered == "GET", tail == ["cues"] {
            return .cueList
        }
        // GET /api/v1/cue/{id}
        if lowered == "GET", tail.count == 2, tail[0].lowercased() == "cue" {
            return .cueDetail(cueNumber: tail[1])
        }
        // POST routes — translate to /sp/... and reuse OSCAddressMap.
        if lowered == "POST" {
            if let action = decodePOST(tail: tail, body: bodyJSON) {
                return .action(action)
            }
        }
        return nil
    }

    private static func decodePOST(tail: [String], body: [String: Any]) -> ShowControlAction? {
        guard let head = tail.first?.lowercased() else { return nil }
        switch head {
        case "go":
            return .go(target: body["target"] as? String)
        case "prev", "previous":
            return .previous
        case "panic":
            let fade = (body["fade"] as? NSNumber)?.doubleValue
            return .panic(fade: fade)
        case "clear":
            return .clear
        case "playhead":
            if let s = body["target"] as? String {
                return .movePlayhead(cueNumber: s)
            }
            return nil
        case "load":
            if let s = body["target"] as? String {
                return .load(cueNumber: s)
            }
            return nil
        case "ping":
            return .ping
        case "subscribe":
            if let host = body["host"] as? String,
               let port = (body["port"] as? NSNumber)?.uint16Value {
                return .subscribe(host: host, port: port)
            }
            return nil
        case "show_mode":
            if let v = body["enabled"] as? Bool {
                return .showMode(enabled: v)
            }
            return nil
        case "output":
            return decodeOutput(tail: Array(tail.dropFirst()), body: body)
        case "look":
            return decodeLook(tail: Array(tail.dropFirst()))
        case "timecode":
            return decodeTimecode(tail: Array(tail.dropFirst()), body: body)
        case "cue":
            return decodeCue(tail: Array(tail.dropFirst()), body: body)
        case "workspace":
            if tail.count >= 2 {
                if tail[1].lowercased() == "save" { return .workspaceSave }
                if tail[1].lowercased() == "reload" { return .workspaceReload }
            }
            return nil
        default:
            return nil
        }
    }

    private static func decodeOutput(tail: [String], body: [String: Any]) -> ShowControlAction? {
        guard tail.count >= 2 else { return nil }
        let action = tail[1].lowercased()
        let enabled = (body["enabled"] as? Bool) ?? false
        switch action {
        case "freeze": return .outputFreeze(enabled: enabled)
        case "blackout": return .outputBlackout(enabled: enabled)
        default: return nil
        }
    }

    private static func decodeLook(tail: [String]) -> ShowControlAction? {
        guard tail.count >= 2, tail.last?.lowercased() == "recall" else { return nil }
        return .lookRecall(name: tail[0])
    }

    private static func decodeTimecode(tail: [String], body: [String: Any]) -> ShowControlAction? {
        guard let head = tail.first?.lowercased() else { return nil }
        switch head {
        case "source":
            return (body["source"] as? String).map { .timecodeSource(spec: $0) }
        case "engaged":
            return (body["enabled"] as? Bool).map { .timecodeEngaged(enabled: $0) }
        case "offset":
            return (body["seconds"] as? NSNumber)
                .map { .timecodeOffset(seconds: $0.floatValue) }
        default:
            return nil
        }
    }

    private static func decodeCue(tail: [String], body: [String: Any]) -> ShowControlAction? {
        guard tail.count >= 2 else { return nil }
        let id = tail[0]
        let act = tail[1].lowercased()
        switch act {
        case "play":
            return .cuePlay(cueNumber: id)
        case "stop":
            let fade = (body["fade"] as? NSNumber)?.doubleValue
            return .cueStop(cueNumber: id, fade: fade)
        case "scrub":
            if tail.count >= 3, tail[2].lowercased() == "seconds" {
                return (body["seconds"] as? NSNumber).map {
                    .cueScrubSeconds(cueNumber: id, seconds: $0.floatValue)
                }
            }
            return (body["position"] as? NSNumber).map {
                .cueScrubNormalized(cueNumber: id, position: $0.floatValue)
            }
        case "opacity":
            return (body["value"] as? NSNumber).map {
                .cueOpacity(cueNumber: id, value: $0.floatValue)
            }
        case "audio":
            if tail.count >= 3, tail[2].lowercased() == "level" {
                return (body["dB"] as? NSNumber).map {
                    .cueAudioLevel(cueNumber: id, dB: $0.floatValue)
                }
            }
            return nil
        case "in_point":
            return (body["seconds"] as? NSNumber).map {
                .cueInPoint(cueNumber: id, seconds: $0.floatValue)
            }
        case "out_point":
            return (body["seconds"] as? NSNumber).map {
                .cueOutPoint(cueNumber: id, seconds: $0.floatValue)
            }
        case "loop":
            return (body["enabled"] as? Bool).map {
                .cueLoop(cueNumber: id, enabled: $0)
            }
        case "goto":
            return (body["next"] as? String).map {
                .cueGoto(cueNumber: id, nextNumber: $0)
            }
        case "preload":
            return .cuePreload(cueNumber: id)
        case "notes":
            return (body["text"] as? String).map {
                .cueNotes(cueNumber: id, text: $0)
            }
        default:
            return nil
        }
    }

    /// Equivalent OSC address, used when the HTTP route's reply envelope
    /// echoes the action source.
    static func oscAddress(for action: ShowControlAction) -> String {
        switch action {
        case .go: return "/sp/go"
        case .previous: return "/sp/prev"
        case .panic: return "/sp/panic"
        case .clear: return "/sp/clear"
        case .movePlayhead: return "/sp/playhead"
        case .load: return "/sp/load"
        case let .cuePlay(num): return "/sp/cue/\(num)/play"
        case let .cueStop(num, _): return "/sp/cue/\(num)/stop"
        case let .cueScrubNormalized(num, _): return "/sp/cue/\(num)/scrub"
        case let .cueScrubSeconds(num, _): return "/sp/cue/\(num)/scrub/seconds"
        case let .cueOpacity(num, _): return "/sp/cue/\(num)/opacity"
        case let .cueAudioLevel(num, _): return "/sp/cue/\(num)/audio/level"
        case let .cueInPoint(num, _): return "/sp/cue/\(num)/in_point"
        case let .cueOutPoint(num, _): return "/sp/cue/\(num)/out_point"
        case let .cueLoop(num, _): return "/sp/cue/\(num)/loop"
        case let .cueGoto(num, _): return "/sp/cue/\(num)/goto"
        case let .cuePreload(num): return "/sp/cue/\(num)/preload"
        case let .cueNotes(num, _): return "/sp/cue/\(num)/notes"
        case .outputFreeze: return "/sp/output/main/freeze"
        case .outputBlackout: return "/sp/output/main/blackout"
        case let .lookRecall(name): return "/sp/look/\(name)/recall"
        case .timecodeSource: return "/sp/timecode/source"
        case .timecodeEngaged: return "/sp/timecode/engaged"
        case .timecodeOffset: return "/sp/timecode/offset"
        case .showMode: return "/sp/show_mode"
        case .workspaceSave: return "/sp/workspace/save"
        case .workspaceReload: return "/sp/workspace/reload"
        case .ping: return "/sp/ping"
        case .subscribe: return "/sp/subscribe"
        case .unsubscribe: return "/sp/unsubscribe"
        }
    }
}

/// One decoded HTTP request — either an action to dispatch, or a read
/// of state.
enum HTTPAction {
    case action(ShowControlAction)
    case stateSnapshot
    case cueList
    case cueDetail(cueNumber: String)
}
