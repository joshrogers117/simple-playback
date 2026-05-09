import Foundation

/// v2 Post-Show Summary — pure-logic reducer over an `[ShowLogEvent]` snapshot
/// producing a `PostShowSummary` value the operator can render to Markdown /
/// CSV / HTML for the post-show ritual. Spec §4 item 18: "Post-show summary
/// report (CSV + human readable)."
///
/// The reducer is intentionally I/O-free: callers pass a slice of events
/// (loaded from `<bundle>/Logs/<date>.log` or sampled from the live in-memory
/// `ShowLog.events`), and the reducer returns the value type. Exporters (CSV
/// / Markdown) live in `PostShowExporters.swift`; the SwiftUI sheet lives in
/// `PostShowSummaryView.swift` (deferred).
///
/// **Pairing semantics**: cue runtime is the duration between a `.go` and the
/// matching `.cueEnded` event. They pair by `detail` field (the cue descriptor
/// — number when present, else title) using FIFO ordering: the oldest pending
/// `.go` for a descriptor pops when a `.cueEnded` for that descriptor arrives.
/// Cue-ID case-insensitivity (per A2) is honoured by lower-casing the
/// descriptor key before pairing.
///
/// **Histogram buckets** match the v2 pre-scope doc's recommendation (5
/// buckets covering the latency range operators care about post-show). Bucket
/// boundaries are inclusive on the lower edge, exclusive on the upper edge:
/// `<50ms`, `50–100ms`, `100–200ms`, `200–500ms`, `>=500ms`.
struct PostShowSummary: Equatable {

    // MARK: - Top-line counters

    /// Number of `.go` events in the window.
    let totalGOs: Int
    /// Number of `.previous` events.
    let totalPreviouses: Int
    /// Number of `.panic` events.
    let totalPanics: Int
    /// Number of `.clear` events.
    let totalClears: Int
    /// Number of `.blackout` events.
    let totalBlackouts: Int
    /// Number of show-mode toggles (on + off combined).
    let totalShowModeToggles: Int

    /// Total events in the window — includes runtime verbs, system events,
    /// remote actions, every category. Useful as a sanity check for the
    /// reducer.
    let totalEventCount: Int

    // MARK: - Per-cue stats

    /// Per-cue aggregation, keyed by lower-cased cue descriptor (so
    /// case-insensitive cue IDs collapse to a single row). Order is the order
    /// of first appearance in the event list — chronological by first GO.
    let cueStats: [CueStats]

    struct CueStats: Equatable {
        /// Display descriptor (verbatim from the `.go` event detail) — used
        /// for rendering. Pairing uses the lowercased form.
        let descriptor: String
        /// Number of `.go` events with this descriptor.
        let fires: Int
        /// Sum of (cueEnded - go) durations in seconds, over all paired
        /// fire/end events. `.go` events without a matching `.cueEnded` (cue
        /// still running at end of window) contribute zero.
        let totalRuntimeSeconds: Double
        /// `totalRuntimeSeconds / pairedCount` — nil when no pair completed.
        let averageRuntimeSeconds: Double?
        /// Number of (`.go`, `.cueEnded`) pairs that completed inside the
        /// window. Always `<= fires`.
        let pairedCount: Int
    }

    // MARK: - Drop / late-take detail rows

    let dropEvents: [DropEvent]
    let lateTakeEvents: [LateTakeEvent]

    struct DropEvent: Equatable {
        let timestamp: Date
        /// Free-form detail copied verbatim from `.droppedFrame`.
        let detail: String
    }

    struct LateTakeEvent: Equatable {
        let timestamp: Date
        let cueDescriptor: String
        let latencyMS: Int
    }

    // MARK: - Latency histogram

    let latencyHistogram: LatencyHistogram

    struct LatencyHistogram: Equatable {
        /// `[0, 50)` ms.
        let under50ms: Int
        /// `[50, 100)` ms.
        let from50to100ms: Int
        /// `[100, 200)` ms.
        let from100to200ms: Int
        /// `[200, 500)` ms.
        let from200to500ms: Int
        /// `[500, +∞)` ms.
        let over500ms: Int

        var totalSamples: Int {
            under50ms + from50to100ms + from100to200ms + from200to500ms + over500ms
        }

        static let empty = LatencyHistogram(
            under50ms: 0, from50to100ms: 0, from100to200ms: 0,
            from200to500ms: 0, over500ms: 0
        )
    }

    // MARK: - System events

    /// Anything that's neither a runtime verb nor a remote action — currently
    /// `.missingMedia` (other system buckets like `.droppedFrame` /
    /// `.lateTake` / `.takeLatency` get their own broken-out sections).
    let systemEvents: [SystemEvent]

    struct SystemEvent: Equatable {
        let timestamp: Date
        let action: ShowLogEvent.Action
        /// Verbatim detail.
        let detail: String?
    }

    // MARK: - Source mix

    let sourceMix: SourceMix

    struct SourceMix: Equatable {
        let local: Int
        let osc: Int
        let http: Int
        let timecode: Int
        let system: Int

        var total: Int { local + osc + http + timecode + system }

        static let empty = SourceMix(local: 0, osc: 0, http: 0, timecode: 0, system: 0)
    }

    // MARK: - Time window

    let showStartedAt: Date?
    let showEndedAt: Date?

    /// `showEndedAt - showStartedAt` in seconds; nil for empty windows.
    var elapsedSeconds: Double? {
        guard let s = showStartedAt, let e = showEndedAt, e >= s else { return nil }
        return e.timeIntervalSince(s)
    }

    // MARK: - Reducer

    /// Reduce a chronological event list to a summary. Events do not need to
    /// be sorted — the reducer sorts internally — but a pre-sorted list lets
    /// the caller skip a copy.
    static func from(events: [ShowLogEvent]) -> PostShowSummary {
        guard !events.isEmpty else { return .empty }

        let sorted = events.sorted { $0.timestamp < $1.timestamp }

        var totalGOs = 0
        var totalPreviouses = 0
        var totalPanics = 0
        var totalClears = 0
        var totalBlackouts = 0
        var totalShowModeToggles = 0

        var cueOrder: [String] = []          // lowercased descriptors in first-appearance order
        var cueByKey: [String: CueAccumulator] = [:]
        // FIFO queue of pending GOs per descriptor key (for runtime pairing).
        var pendingGOsByKey: [String: [Date]] = [:]

        var dropEvents: [DropEvent] = []
        var lateTakeEvents: [LateTakeEvent] = []
        var histogramBuckets = HistogramBuckets()
        var systemEvents: [SystemEvent] = []
        var sourceMix = SourceCounters()

        for event in sorted {
            sourceMix.bump(event.source)

            switch event.action {
            case .go:
                totalGOs += 1
                let descriptor = event.detail ?? ""
                let key = descriptor.lowercased()
                if cueByKey[key] == nil {
                    cueByKey[key] = CueAccumulator(descriptor: descriptor)
                    cueOrder.append(key)
                }
                cueByKey[key]?.fires += 1
                pendingGOsByKey[key, default: []].append(event.timestamp)

            case .cueEnded:
                let key = (event.detail ?? "").lowercased()
                guard var pending = pendingGOsByKey[key], !pending.isEmpty else {
                    // Orphan .cueEnded (no preceding .go in window). Skip
                    // silently — common when the window starts mid-show.
                    continue
                }
                let goAt = pending.removeFirst()
                pendingGOsByKey[key] = pending
                let runtime = event.timestamp.timeIntervalSince(goAt)
                if runtime >= 0, var accum = cueByKey[key] {
                    accum.totalRuntime += runtime
                    accum.pairedCount += 1
                    cueByKey[key] = accum
                }

            case .previous:
                totalPreviouses += 1

            case .panic:
                totalPanics += 1

            case .clear:
                totalClears += 1

            case .blackout:
                totalBlackouts += 1

            case .showModeOn, .showModeOff:
                totalShowModeToggles += 1

            case .droppedFrame:
                dropEvents.append(DropEvent(
                    timestamp: event.timestamp,
                    detail: event.detail ?? ""
                ))

            case .lateTake:
                if let parsed = parseLatencyDetail(event.detail) {
                    lateTakeEvents.append(LateTakeEvent(
                        timestamp: event.timestamp,
                        cueDescriptor: parsed.cueDescriptor,
                        latencyMS: parsed.latencyMS
                    ))
                }

            case .takeLatency:
                if let parsed = parseLatencyDetail(event.detail) {
                    histogramBuckets.bump(latencyMS: parsed.latencyMS)
                }

            case .missingMedia, .lockFileForeign:
                systemEvents.append(SystemEvent(
                    timestamp: event.timestamp,
                    action: event.action,
                    detail: event.detail
                ))

            case .oscAction, .httpAction, .timecodeTrigger:
                // Remote actions are counted via sourceMix; not folded into
                // systemEvents (which is operator-visible "what did the OS do"
                // territory). Future: optionally surface a "remote actions"
                // section.
                break
            }
        }

        let cueStatsList = cueOrder.compactMap { key -> CueStats? in
            guard let accum = cueByKey[key] else { return nil }
            let avg: Double? = accum.pairedCount > 0
                ? accum.totalRuntime / Double(accum.pairedCount)
                : nil
            return CueStats(
                descriptor: accum.descriptor,
                fires: accum.fires,
                totalRuntimeSeconds: accum.totalRuntime,
                averageRuntimeSeconds: avg,
                pairedCount: accum.pairedCount
            )
        }

        return PostShowSummary(
            totalGOs: totalGOs,
            totalPreviouses: totalPreviouses,
            totalPanics: totalPanics,
            totalClears: totalClears,
            totalBlackouts: totalBlackouts,
            totalShowModeToggles: totalShowModeToggles,
            totalEventCount: sorted.count,
            cueStats: cueStatsList,
            dropEvents: dropEvents,
            lateTakeEvents: lateTakeEvents,
            latencyHistogram: histogramBuckets.snapshot(),
            systemEvents: systemEvents,
            sourceMix: sourceMix.snapshot(),
            showStartedAt: sorted.first?.timestamp,
            showEndedAt: sorted.last?.timestamp
        )
    }

    /// Empty-window sentinel. Lets callers render "no events" without nil
    /// branches everywhere.
    static let empty = PostShowSummary(
        totalGOs: 0, totalPreviouses: 0, totalPanics: 0,
        totalClears: 0, totalBlackouts: 0, totalShowModeToggles: 0,
        totalEventCount: 0,
        cueStats: [],
        dropEvents: [], lateTakeEvents: [],
        latencyHistogram: .empty,
        systemEvents: [],
        sourceMix: .empty,
        showStartedAt: nil, showEndedAt: nil
    )
}

// MARK: - Reducer scratch types (file-private)

private struct CueAccumulator {
    let descriptor: String
    var fires: Int = 0
    var totalRuntime: TimeInterval = 0
    var pairedCount: Int = 0
}

private struct HistogramBuckets {
    var under50: Int = 0
    var from50to100: Int = 0
    var from100to200: Int = 0
    var from200to500: Int = 0
    var over500: Int = 0

    mutating func bump(latencyMS: Int) {
        switch latencyMS {
        case ..<50: under50 += 1
        case 50..<100: from50to100 += 1
        case 100..<200: from100to200 += 1
        case 200..<500: from200to500 += 1
        default: over500 += 1
        }
    }

    func snapshot() -> PostShowSummary.LatencyHistogram {
        .init(
            under50ms: under50,
            from50to100ms: from50to100,
            from100to200ms: from100to200,
            from200to500ms: from200to500,
            over500ms: over500
        )
    }
}

private struct SourceCounters {
    var local: Int = 0
    var osc: Int = 0
    var http: Int = 0
    var timecode: Int = 0
    var system: Int = 0

    mutating func bump(_ source: ShowLogEvent.Source) {
        switch source {
        case .localHotkey, .operatorButton: local += 1
        case .osc: osc += 1
        case .http: http += 1
        case .timecode: timecode += 1
        case .system: system += 1
        }
    }

    func snapshot() -> PostShowSummary.SourceMix {
        .init(local: local, osc: osc, http: http, timecode: timecode, system: system)
    }
}

/// Parse a `latency=Nms cue=DESCRIPTOR` detail string. Format is fixed by
/// `ShowController.handleLiveSlideTransition` (and pinned by tests there);
/// returns nil if the string doesn't match so a malformed log row is skipped
/// rather than crashing the reducer.
///
/// Uses prefix matching rather than a regex so the parser stays predictable
/// when the descriptor itself contains spaces or colons.
private func parseLatencyDetail(_ detail: String?) -> (latencyMS: Int, cueDescriptor: String)? {
    guard let detail else { return nil }
    let prefix = "latency="
    let cueMarker = "ms cue="
    guard detail.hasPrefix(prefix) else { return nil }
    let afterLatency = detail.dropFirst(prefix.count)
    guard let msRange = afterLatency.range(of: cueMarker) else { return nil }
    let latencyString = afterLatency[afterLatency.startIndex..<msRange.lowerBound]
    guard let latencyMS = Int(latencyString) else { return nil }
    let descriptor = String(afterLatency[msRange.upperBound...])
    return (latencyMS, descriptor)
}
