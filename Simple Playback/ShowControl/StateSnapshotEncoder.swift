import Foundation

/// Serializes `ShowControlState.Snapshot` (and slices thereof) into JSON for
/// HTTP twin GET responses, OSCQuery values, and WebSocket state pushes.
enum StateSnapshotEncoder {
    static func json(_ snap: ShowControlState.Snapshot) -> Data {
        let envelope = stateEnvelope(snap)
        return (try? JSONEncoder.standard().encode(envelope)) ?? Data("{}".utf8)
    }

    static func cueListJSON(_ snap: ShowControlState.Snapshot) -> Data {
        let cues = snap.showList.cues.map { cueObject($0, in: snap) }
        let body: [String: ShowControlValue] = [
            "apiVersion": .int(SHOW_CONTROL_API_VERSION),
            "status": .string("ok"),
            "data": .object(["cues": .array(cues)])
        ]
        return (try? JSONEncoder.standard().encode(JSONValueDict(body))) ?? Data("{}".utf8)
    }

    static func cueDetailJSON(_ snap: ShowControlState.Snapshot, cueNumber: String) -> Data? {
        guard let cue = snap.showList.cue(number: cueNumber) else { return nil }
        let body: [String: ShowControlValue] = [
            "apiVersion": .int(SHOW_CONTROL_API_VERSION),
            "status": .string("ok"),
            "data": .object(["cue": cueObject(cue, in: snap)])
        ]
        return (try? JSONEncoder.standard().encode(JSONValueDict(body)))
    }

    /// Build a JSON-friendly dictionary from a snapshot, with the standard
    /// reply envelope around the state payload.
    static func stateEnvelope(_ snap: ShowControlState.Snapshot) -> JSONReply {
        let cues = snap.showList.cues.map { cueObject($0, in: snap) }
        let payload: [String: ShowControlValue] = [
            "playhead": snap.showList.playheadCue.map { .string($0.number) } ?? .null,
            "playheadName": snap.showList.playheadCue.map { .string($0.title) } ?? .null,
            "blackout": .bool(snap.blackout),
            "panic": .bool(snap.panicActive),
            "onAir": .bool(snap.onAir),
            "showMode": .bool(snap.showModeEnabled),
            "uptime": .double(snap.uptime),
            "timecode": .object([
                "source": .string(snap.timecodeSource),
                "engaged": .bool(snap.timecodeEngaged),
                "locked": .bool(snap.timecodeLocked),
                "now": .string(snap.timecodeNow),
                "offset": .double(snap.timecodeOffset),
            ]),
            "cues": .array(cues)
        ]
        return JSONReply(
            apiVersion: SHOW_CONTROL_API_VERSION,
            address: "/api/v1/state",
            status: "ok",
            data: payload,
            error: nil
        )
    }

    static func cueObject(_ cue: Cue, in snap: ShowControlState.Snapshot) -> ShowControlValue {
        let state = snap.cueStates[cue.id] ?? .idle
        let elapsed = snap.cueElapsed[cue.id] ?? 0
        let remaining = snap.cueRemaining[cue.id] ?? 0
        let isPlayhead = (snap.showList.playheadCue?.id == cue.id)
        return .object([
            "id": .string(cue.number),
            "name": .string(cue.title),
            "continuation": .string(cue.continuation.rawValue),
            "preWait": .double(cue.preWait),
            "postWait": .double(cue.postWait),
            "notes": .string(cue.notes),
            "state": .string(state.rawValue),
            "running": .bool(state == .running),
            "standby": .bool(state == .loaded),
            "isPlayhead": .bool(isPlayhead),
            "elapsed": .double(elapsed),
            "remaining": .double(remaining),
        ])
    }
}
