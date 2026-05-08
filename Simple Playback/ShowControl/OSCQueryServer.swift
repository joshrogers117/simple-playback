import Foundation

/// OSCQuery namespace publisher.
///
/// Implements the subset of the OSCQuery proposal that Companion modules and
/// TouchOSC use:
/// - `GET /` returns the root container.
/// - `GET /<path>` returns the subtree at that path.
/// - Each node carries `FULL_PATH`, `DESCRIPTION`, `ACCESS`, `TYPE`,
///   `CONTENTS`, and (for value-bearing nodes) `RANGE` and `VALUE`.
/// - `?VALUE` query selector returns just the current value.
///
/// We curate the namespace; only the action surface in `feature_spec.md`
/// §3.12 is exposed. Per-cue endpoints are enumerated dynamically from
/// `ShowControlState`.
final class OSCQueryServer {
    weak var state: ShowControlState?

    /// Host info for the discovery handshake (`?HOST_INFO`).
    struct HostInfo {
        var name: String = "Simple Playback"
        var oscIP: String = "127.0.0.1"
        var oscPort: UInt16 = 53000
        var oscTransport: String = "UDP"
        var extensions: [String: Bool] = [
            "ACCESS": true,
            "VALUE": true,
            "RANGE": true,
            "DESCRIPTION": true,
            "TAGS": false,
            "EXTENDED_TYPE": false,
            "UNIT": false,
            "CRITICAL": false,
            "CLIPMODE": false,
            "LISTEN": true,
            "PATH_CHANGED": true,
        ]
    }

    var hostInfo: HostInfo = HostInfo()

    init(state: ShowControlState) {
        self.state = state
    }

    /// Top-level handler installed on the HTTP server. Returns `nil` for
    /// paths it doesn't own, allowing the HTTP server to fall through.
    func handle(path: String, query: [String: String]) -> (status: Int, body: Data, contentType: String)? {
        // HOST_INFO handshake.
        if query.keys.contains("HOST_INFO") {
            return (200, hostInfoJSON(), "application/json")
        }
        // Anything under /api/v1/ is the HTTP twin's job, not ours.
        if path.hasPrefix("/api/v1") { return nil }
        // Only respond to OSCQuery-style paths starting with `/` and
        // optionally including `/sp` or its subtree.
        if path == "/" || path.hasPrefix("/sp") {
            let valueOnly = query.keys.contains("VALUE")
            return buildNode(at: path, valueOnly: valueOnly)
        }
        return nil
    }

    // MARK: - Namespace tree

    private func buildNode(at path: String, valueOnly: Bool) -> (status: Int, body: Data, contentType: String) {
        let segs = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let snap = state?.snapshot()

        if segs.isEmpty {
            // Root.
            let root = container(
                fullPath: "/",
                description: "Simple Playback OSC namespace root",
                contents: [
                    "sp": .object(rootSP(snap))
                ]
            )
            return (200, encode(root), "application/json")
        }
        if segs == ["sp"] {
            return (200, encode(rootSP(snap)), "application/json")
        }

        // Walk into the namespace.
        if let node = walk(segs: segs, snap: snap) {
            if valueOnly, let v = node["VALUE"] {
                let body = (try? JSONEncoder.standard().encode(["VALUE": v])) ?? Data()
                return (200, body, "application/json")
            }
            return (200, encode(node), "application/json")
        }

        return (404, Data(#"{"ERROR":"NOT_FOUND"}"#.utf8), "application/json")
    }

    private func rootSP(_ snap: ShowControlState.Snapshot?) -> [String: ShowControlValue] {
        var contents: [String: ShowControlValue] = [
            "go": leaf(fullPath: "/sp/go", desc: "GO — fire playhead, advance", types: "s"),
            "prev": leaf(fullPath: "/sp/prev", desc: "Step playhead back", types: ""),
            "panic": leaf(fullPath: "/sp/panic", desc: "Soft fade-out everything", types: "f"),
            "clear": leaf(fullPath: "/sp/clear", desc: "Hard cut + audio mute", types: ""),
            "playhead": leaf(fullPath: "/sp/playhead", desc: "Move playhead, do not fire", types: "s"),
            "load": leaf(fullPath: "/sp/load", desc: "Async warm-up", types: "s"),
            "ping": leaf(fullPath: "/sp/ping", desc: "Heartbeat", types: ""),
            "subscribe": leaf(fullPath: "/sp/subscribe", desc: "Subscribe to state pushes", types: "s"),
            "show_mode": leaf(fullPath: "/sp/show_mode", desc: "Show mode lockout", types: "i"),
            "output": .object([
                "FULL_PATH": .string("/sp/output"),
                "DESCRIPTION": .string("Output controls"),
                "ACCESS": .int(0),
                "CONTENTS": .object([
                    "main": .object([
                        "FULL_PATH": .string("/sp/output/main"),
                        "ACCESS": .int(0),
                        "CONTENTS": .object([
                            "freeze": leaf(fullPath: "/sp/output/main/freeze", desc: "Freeze on program output", types: "i"),
                            "blackout": leaf(fullPath: "/sp/output/main/blackout", desc: "Blackout program output", types: "i", value: snap?.blackout == true ? .int(1) : .int(0)),
                        ])
                    ])
                ])
            ]),
            "timecode": .object([
                "FULL_PATH": .string("/sp/timecode"),
                "DESCRIPTION": .string("Timecode chase"),
                "ACCESS": .int(0),
                "CONTENTS": .object([
                    "source": leaf(fullPath: "/sp/timecode/source", desc: "TC source spec", types: "s",
                                   value: .string(snap?.timecodeSource ?? "off")),
                    "engaged": leaf(fullPath: "/sp/timecode/engaged", desc: "Arm/disarm chase", types: "i",
                                    value: .int(snap?.timecodeEngaged == true ? 1 : 0)),
                    "offset": leaf(fullPath: "/sp/timecode/offset", desc: "Per-show TC offset (s)", types: "f",
                                   value: .double(snap?.timecodeOffset ?? 0)),
                    "now": leaf(fullPath: "/sp/timecode/now", desc: "Current incoming TC", types: "s",
                                access: 1, // read-only
                                value: .string(snap?.timecodeNow ?? "00:00:00:00")),
                    "locked": leaf(fullPath: "/sp/timecode/locked", desc: "TC locked", types: "i",
                                   access: 1,
                                   value: .int(snap?.timecodeLocked == true ? 1 : 0)),
                ])
            ]),
            "cue": cueListContainer(snap),
            "state": stateContainer(snap),
        ]
        if snap?.showModeEnabled == true {
            contents["show_mode_state"] = leaf(
                fullPath: "/sp/show_mode_state",
                desc: "Show mode active",
                types: "i", access: 1,
                value: .int(1)
            )
        }
        return [
            "FULL_PATH": .string("/sp"),
            "DESCRIPTION": .string("Simple Playback show-control namespace"),
            "ACCESS": .int(0),
            "CONTENTS": .object(contents),
        ]
    }

    private func cueListContainer(_ snap: ShowControlState.Snapshot?) -> ShowControlValue {
        var byNumber: [String: ShowControlValue] = [:]
        if let snap {
            for cue in snap.showList.cues {
                let runId = cue.number
                let isPlayhead = (snap.showList.playheadCue?.id == cue.id)
                let state = snap.cueStates[cue.id] ?? .idle
                byNumber[runId] = .object([
                    "FULL_PATH": .string("/sp/cue/\(runId)"),
                    "DESCRIPTION": .string("Cue \(runId) — \(cue.title)"),
                    "ACCESS": .int(0),
                    "CONTENTS": .object([
                        "play": leaf(fullPath: "/sp/cue/\(runId)/play", desc: "Fire this cue", types: ""),
                        "stop": leaf(fullPath: "/sp/cue/\(runId)/stop", desc: "Stop this cue", types: "f"),
                        "preload": leaf(fullPath: "/sp/cue/\(runId)/preload", desc: "Async warm-up", types: ""),
                        "scrub": leaf(fullPath: "/sp/cue/\(runId)/scrub", desc: "Seek normalized 0..1", types: "f"),
                        "running": leaf(fullPath: "/sp/cue/\(runId)/running", desc: "1 if running", types: "i",
                                        access: 1, value: .int(state == .running ? 1 : 0)),
                        "standby": leaf(fullPath: "/sp/cue/\(runId)/standby", desc: "1 if pre-rolled", types: "i",
                                        access: 1, value: .int(state == .loaded ? 1 : 0)),
                        "is_playhead": leaf(fullPath: "/sp/cue/\(runId)/is_playhead", desc: "1 if armed", types: "i",
                                            access: 1, value: .int(isPlayhead ? 1 : 0)),
                        "elapsed": leaf(fullPath: "/sp/cue/\(runId)/elapsed", desc: "Elapsed seconds", types: "f",
                                        access: 1, value: .double(snap.cueElapsed[cue.id] ?? 0)),
                        "remaining": leaf(fullPath: "/sp/cue/\(runId)/remaining", desc: "Remaining seconds", types: "f",
                                          access: 1, value: .double(snap.cueRemaining[cue.id] ?? 0)),
                        "notes": leaf(fullPath: "/sp/cue/\(runId)/notes", desc: "Operator notes", types: "s",
                                      value: .string(cue.notes)),
                    ])
                ])
            }
            // Reserved selectors.
            byNumber["playhead"] = leaf(fullPath: "/sp/cue/playhead", desc: "Currently armed cue", types: "s",
                                        access: 1, value: snap.showList.playheadCue.map { .string($0.number) } ?? .string(""))
            byNumber["selected"] = leaf(fullPath: "/sp/cue/selected", desc: "Selected cue", types: "s",
                                        access: 1, value: snap.showList.playheadCue.map { .string($0.number) } ?? .string(""))
            byNumber["active"] = leaf(fullPath: "/sp/cue/active", desc: "All currently-running cue numbers (csv)", types: "s",
                                      access: 1,
                                      value: .string(snap.showList.cues.filter { snap.cueStates[$0.id] == .running }.map(\.number).joined(separator: ",")))
        }
        return .object([
            "FULL_PATH": .string("/sp/cue"),
            "DESCRIPTION": .string("Cue list"),
            "ACCESS": .int(0),
            "CONTENTS": .object(byNumber),
        ])
    }

    private func stateContainer(_ snap: ShowControlState.Snapshot?) -> ShowControlValue {
        return .object([
            "FULL_PATH": .string("/sp/state"),
            "DESCRIPTION": .string("Pushed state values"),
            "ACCESS": .int(1),
            "CONTENTS": .object([
                "playhead": leaf(fullPath: "/sp/state/playhead", desc: "Current playhead cue id", types: "s",
                                 access: 1,
                                 value: snap?.showList.playheadCue.map { .string($0.number) } ?? .string("")),
                "onair": leaf(fullPath: "/sp/state/output/onair", desc: "1 if program is on-air", types: "i",
                              access: 1,
                              value: .int(snap?.onAir == true ? 1 : 0)),
            ])
        ])
    }

    // MARK: - Leaf / container builders

    private func leaf(
        fullPath: String,
        desc: String,
        types: String,
        access: Int = 2, // 2 = read+write per OSCQuery proposal
        value: ShowControlValue? = nil,
        range: [String: ShowControlValue]? = nil
    ) -> ShowControlValue {
        var node: [String: ShowControlValue] = [
            "FULL_PATH": .string(fullPath),
            "DESCRIPTION": .string(desc),
            "ACCESS": .int(access),
        ]
        if !types.isEmpty {
            node["TYPE"] = .string(types)
        }
        if let value {
            node["VALUE"] = .array([value])
        }
        if let range {
            node["RANGE"] = .object(range)
        }
        return .object(node)
    }

    private func container(fullPath: String, description: String, contents: [String: ShowControlValue]) -> [String: ShowControlValue] {
        return [
            "FULL_PATH": .string(fullPath),
            "DESCRIPTION": .string(description),
            "ACCESS": .int(0),
            "CONTENTS": .object(contents),
        ]
    }

    // MARK: - Path walk

    private func walk(segs: [String], snap: ShowControlState.Snapshot?) -> [String: ShowControlValue]? {
        var current: ShowControlValue = .object(rootSP(snap))
        for (i, seg) in segs.enumerated() {
            // Skip the leading "sp" segment (already at /sp root).
            if i == 0, seg.lowercased() == "sp" {
                continue
            }
            guard case let .object(node) = current,
                  case let .object(contents) = node["CONTENTS"] ?? .null else {
                return nil
            }
            // Case-insensitive lookup at each level.
            let lower = seg.lowercased()
            var found: ShowControlValue? = nil
            for (k, v) in contents where k.lowercased() == lower {
                found = v
                break
            }
            guard let next = found else { return nil }
            current = next
        }
        if case let .object(node) = current { return node }
        return nil
    }

    // MARK: - Encoding

    private func encode(_ node: [String: ShowControlValue]) -> Data {
        (try? JSONEncoder.standard().encode(JSONValueDict(node))) ?? Data("{}".utf8)
    }

    private func hostInfoJSON() -> Data {
        let exts: [String: ShowControlValue] = hostInfo.extensions.mapValues { .bool($0) }
        let node: [String: ShowControlValue] = [
            "NAME": .string(hostInfo.name),
            "OSC_IP": .string(hostInfo.oscIP),
            "OSC_PORT": .int(Int(hostInfo.oscPort)),
            "OSC_TRANSPORT": .string(hostInfo.oscTransport),
            "EXTENSIONS": .object(exts),
        ]
        return encode(node)
    }
}
