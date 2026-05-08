import Foundation

/// E3 — Show log. Append-only event journal of every show-runtime verb (GO,
/// PREVIOUS, PANIC, CLEAR, BLACKOUT, Show-Mode toggle, missing-media, etc.).
/// Spec §3.16 — persisted in `<bundle>/Logs/<showdate>.log` as plaintext CSV
/// with one row per event so the operator (and later auditors) can replay the
/// run minute-by-minute.
///
/// **Source attribution** is first-class: every event records *who* fired it
/// (local hotkey, operator click, OSC peer ip:port, HTTP token suffix, TC
/// trigger, or system). That's the difference between debugging a missed cue
/// and a duplicate fire from a remote operator.
///
/// The model + writer ship in E3a (this file). E3b/c integrate it into
/// `ShowController` and the OSC/HTTP handlers. E3d will add a viewer.
struct ShowLogEvent: Equatable {

    let timestamp: Date
    /// Chase timecode when LTC/MTC is engaged, in `HH:MM:SS:FF` form. Nil
    /// when no timecode source is locked. Operators trace events against
    /// the show's master TC, not the wall clock alone.
    let chaseTimecode: String?
    let action: Action
    let source: Source
    /// Free-form context — typically a cue id, error message, or OSC
    /// address. Operator-readable; CSV-quoted on serialization.
    let detail: String?

    enum Action: String, CaseIterable, Equatable {
        case go = "GO"
        case previous = "PREVIOUS"
        case panic = "PANIC"
        case clear = "CLEAR"
        case blackout = "BLACKOUT"
        case showModeOn = "SHOW_MODE_ON"
        case showModeOff = "SHOW_MODE_OFF"
        case droppedFrame = "DROPPED_FRAME"
        case lateTake = "LATE_TAKE"
        case missingMedia = "MISSING_MEDIA"
        case oscAction = "OSC_ACTION"
        case httpAction = "HTTP_ACTION"
        case timecodeTrigger = "TC_TRIGGER"
    }

    enum Source: Equatable {
        /// Operator pressed a registered keyboard shortcut.
        case localHotkey
        /// Operator clicked a button in the app's UI.
        case operatorButton
        /// OSC client at the given host/port.
        case osc(host: String?, port: Int?)
        /// HTTP client with the given token (last 4 chars only — never log
        /// the full token).
        case http(tokenSuffix: String?)
        /// LTC/MTC trigger fired the action.
        case timecode
        /// Internal system event (autosave, missing-media, etc.).
        case system

        /// Stable serialised form for CSV. Compact enough that the field
        /// fits in a single CSV cell without quoting in the common cases.
        var label: String {
            switch self {
            case .localHotkey: return "local"
            case .operatorButton: return "ui"
            case .osc(let host, let port):
                let h = host ?? "?"
                let p = port.map(String.init) ?? "?"
                return "osc \(h):\(p)"
            case .http(let tokenSuffix):
                let t = tokenSuffix ?? "?"
                return "http …\(t)"
            case .timecode: return "tc"
            case .system: return "system"
            }
        }
    }

    /// Render this event as a single CSV line per RFC 4180. Field order:
    /// timestamp (ISO 8601), chaseTimecode, action, source, detail.
    func csvLine() -> String {
        let ts = showLogISO8601Formatter.string(from: timestamp)
        let tc = chaseTimecode ?? ""
        return [
            csvField(ts),
            csvField(tc),
            csvField(action.rawValue),
            csvField(source.label),
            csvField(detail ?? "")
        ].joined(separator: ",")
    }
}

/// Module-scoped formatter so `ShowLogEvent.csvLine` (which is not actor-
/// isolated) can serialize timestamps without crossing into the main-actor
/// isolation of `ShowLog`. `ISO8601DateFormatter` is documented thread-safe.
let showLogISO8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Append-only event journal for a single document. The host owns one
/// `ShowLog` per open project; events flow in from `ShowController`, the OSC
/// hub, and the HTTP API. The writer side is split: an in-memory `events`
/// list backs the viewer, and an optional `fileURL` writer streams CSV lines
/// to `<bundle>/Logs/<showdate>.log`.
@MainActor
final class ShowLog: ObservableObject {

    @Published private(set) var events: [ShowLogEvent] = []

    /// Optional on-disk destination. When non-nil, every appended event
    /// writes a CSV line to this URL. Untitled documents don't have a
    /// bundle on disk yet, so the file writer is suppressed in that case
    /// and the in-memory log is the only record. Setting a non-nil URL
    /// also writes the CSV header if the file is empty / does not exist.
    private(set) var fileURL: URL?

    /// Test seam — the file writer dependency. Default writes to disk via
    /// `Data.write(to:options:)`; tests can substitute a no-op or a
    /// capturing closure to verify on-disk shape without touching the
    /// filesystem.
    var fileWriter: (URL, Data, _ append: Bool) throws -> Void = { url, data, append in
        if append, FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    }

    /// CSV header line written on first event when the file is empty.
    static let csvHeader = "timestamp,timecode,action,source,detail\n"

    /// Set or clear the on-disk destination. Idempotent — calling with the
    /// same URL twice does not duplicate the header.
    func setFileURL(_ url: URL?) {
        fileURL = url
        guard let url else { return }
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists {
            // Seed the file with the CSV header so external tools can parse
            // it without prior knowledge of the column order.
            do {
                try fileWriter(url, Data(Self.csvHeader.utf8), false)
            } catch {
                // If the writer fails (read-only volume, missing parent)
                // suppress the URL so we don't keep retrying. Events still
                // accumulate in memory.
                fileURL = nil
            }
        }
    }

    /// Append a fully-formed event. Used in tests and by callers that build
    /// the event timestamp / TC themselves.
    func append(_ event: ShowLogEvent) {
        events.append(event)
        guard let url = fileURL else { return }
        let line = event.csvLine() + "\n"
        do {
            try fileWriter(url, Data(line.utf8), true)
        } catch {
            // A failed write should not crash the show — drop the URL and
            // keep going in memory. The viewer flags this on next open.
            fileURL = nil
        }
    }

    /// Convenience entry point. Stamps the event with `Date()` and the
    /// caller-supplied chase TC.
    func appendNow(
        action: ShowLogEvent.Action,
        source: ShowLogEvent.Source,
        detail: String? = nil,
        chaseTimecode: String? = nil
    ) {
        append(ShowLogEvent(
            timestamp: Date(),
            chaseTimecode: chaseTimecode,
            action: action,
            source: source,
            detail: detail
        ))
    }

    /// Export the entire in-memory event list as a CSV string, header
    /// included. Used by the viewer's "Export…" affordance.
    func exportCSV() -> String {
        var s = Self.csvHeader
        for event in events {
            s += event.csvLine() + "\n"
        }
        return s
    }
}

// MARK: - E4 filtering

extension ShowLog {

    /// Filter axis over `ShowLogEvent.Source`. The dispatcher tags every
    /// event with one of six source variants; the operator-facing picker
    /// collapses related variants (local-hotkey + operator-click stay
    /// together as a single "Local" bucket) so the filter chrome stays
    /// readable.
    enum SourceFilter: String, Equatable, CaseIterable, Identifiable {
        case all
        case local
        case osc
        case http
        case timecode
        case system

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: "All sources"
            case .local: "Local"
            case .osc: "OSC"
            case .http: "HTTP"
            case .timecode: "Timecode"
            case .system: "System"
            }
        }

        func matches(_ source: ShowLogEvent.Source) -> Bool {
            switch (self, source) {
            case (.all, _): return true
            case (.local, .localHotkey), (.local, .operatorButton): return true
            case (.osc, .osc): return true
            case (.http, .http): return true
            case (.timecode, .timecode): return true
            case (.system, .system): return true
            default: return false
            }
        }
    }

    /// Filter axis over `ShowLogEvent.Action`. Mirrors the runtime/remote/
    /// system split so an operator looking for "what did the show do" vs
    /// "what did a remote do" vs "what did the OS do" can pick fast.
    enum ActionFilter: String, Equatable, CaseIterable, Identifiable {
        case all
        case runtimeVerbs
        case remoteActions
        case systemEvents

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: "All actions"
            case .runtimeVerbs: "Show verbs"
            case .remoteActions: "Remote API"
            case .systemEvents: "System"
            }
        }

        func matches(_ action: ShowLogEvent.Action) -> Bool {
            switch (self, action) {
            case (.all, _):
                return true
            case (.runtimeVerbs, .go),
                 (.runtimeVerbs, .previous),
                 (.runtimeVerbs, .panic),
                 (.runtimeVerbs, .clear),
                 (.runtimeVerbs, .blackout),
                 (.runtimeVerbs, .showModeOn),
                 (.runtimeVerbs, .showModeOff):
                return true
            case (.remoteActions, .oscAction),
                 (.remoteActions, .httpAction),
                 (.remoteActions, .timecodeTrigger):
                return true
            case (.systemEvents, .missingMedia),
                 (.systemEvents, .droppedFrame),
                 (.systemEvents, .lateTake):
                return true
            default:
                return false
            }
        }
    }

    /// Pure-logic filter applied to a snapshot of `events`. The view passes
    /// the result through `ForEach` for rendering so SwiftUI doesn't have
    /// to redo the predicate work on every redraw.
    func filteredEvents(
        source: SourceFilter,
        action: ActionFilter,
        since: Date? = nil
    ) -> [ShowLogEvent] {
        events.filter { event in
            guard source.matches(event.source) else { return false }
            guard action.matches(event.action) else { return false }
            if let since, event.timestamp < since { return false }
            return true
        }
    }
}

/// RFC 4180 field quoting — wrap in `"` if the field contains a comma, a
/// quote, or a newline; double any embedded `"`.
private func csvField(_ value: String) -> String {
    let needsQuote = value.contains(",") || value.contains("\"") || value.contains("\n")
    guard needsQuote else { return value }
    let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
    return "\"\(escaped)\""
}
