import Foundation

/// v2 Post-Show Summary — CSV exporter. Pure-function rendering of a
/// `PostShowSummary` value to a single multi-section CSV file the producer
/// can drop into a spreadsheet. Spec §4 item 18: "Post-show summary report
/// (CSV + human readable)."
///
/// Format: one logical CSV per section, separated by a blank line. Section
/// headings render as a `# Section: <name>` single-column row so spreadsheet
/// tools that don't honour `#` comments still parse the file (the heading
/// just lands as a literal first cell).
///
/// Field quoting follows RFC 4180 — values containing `,`, `"`, `\r`, or
/// `\n` get wrapped in `"..."` with embedded `"` doubled. Matches the
/// existing show-log CSV writer so producers reading both files use the same
/// parser.
enum PostShowCSVExporter {

    static func export(_ summary: PostShowSummary) -> String {
        var sections: [String] = []
        sections.append(renderHeader(summary))
        sections.append(renderTotals(summary))
        sections.append(renderCueStats(summary))
        sections.append(renderHistogram(summary))
        sections.append(renderDropEvents(summary))
        sections.append(renderLateTakes(summary))
        sections.append(renderSystemEvents(summary))
        sections.append(renderSourceMix(summary))
        // Blank line between sections; trailing newline at end of file.
        return sections.joined(separator: "\n") + "\n"
    }

    // MARK: - Sections

    private static func renderHeader(_ summary: PostShowSummary) -> String {
        var rows: [String] = ["# Section: Window"]
        rows.append("Field,Value")
        if let started = summary.showStartedAt {
            rows.append("Started," + csvField(timestampFormatter.string(from: started)))
        }
        if let ended = summary.showEndedAt {
            rows.append("Ended," + csvField(timestampFormatter.string(from: ended)))
        }
        if let elapsed = summary.elapsedSeconds {
            rows.append("ElapsedSeconds," + String(format: "%.3f", elapsed))
        }
        rows.append("TotalEvents,\(summary.totalEventCount)")
        return rows.joined(separator: "\n")
    }

    private static func renderTotals(_ summary: PostShowSummary) -> String {
        var rows: [String] = ["# Section: Totals", "Action,Count"]
        rows.append("GO,\(summary.totalGOs)")
        rows.append("PREVIOUS,\(summary.totalPreviouses)")
        rows.append("PANIC,\(summary.totalPanics)")
        rows.append("CLEAR,\(summary.totalClears)")
        rows.append("BLACKOUT,\(summary.totalBlackouts)")
        rows.append("SHOW_MODE_TOGGLES,\(summary.totalShowModeToggles)")
        return rows.joined(separator: "\n")
    }

    private static func renderCueStats(_ summary: PostShowSummary) -> String {
        var rows: [String] = [
            "# Section: CueStats",
            "Cue,Fires,Paired,AvgRuntimeSeconds,TotalRuntimeSeconds"
        ]
        for stats in summary.cueStats {
            let avg = stats.averageRuntimeSeconds.map { String(format: "%.3f", $0) } ?? ""
            let total = String(format: "%.3f", stats.totalRuntimeSeconds)
            rows.append([
                csvField(stats.descriptor),
                "\(stats.fires)",
                "\(stats.pairedCount)",
                avg,
                total
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private static func renderHistogram(_ summary: PostShowSummary) -> String {
        let h = summary.latencyHistogram
        var rows: [String] = ["# Section: LatencyHistogram", "Bucket,Count"]
        rows.append("Under50ms,\(h.under50ms)")
        rows.append("50to100ms,\(h.from50to100ms)")
        rows.append("100to200ms,\(h.from100to200ms)")
        rows.append("200to500ms,\(h.from200to500ms)")
        rows.append("Over500ms,\(h.over500ms)")
        return rows.joined(separator: "\n")
    }

    private static func renderDropEvents(_ summary: PostShowSummary) -> String {
        var rows: [String] = ["# Section: DropEvents", "Timestamp,Detail"]
        for evt in summary.dropEvents {
            rows.append([
                csvField(timestampFormatter.string(from: evt.timestamp)),
                csvField(evt.detail)
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private static func renderLateTakes(_ summary: PostShowSummary) -> String {
        var rows: [String] = ["# Section: LateTakes", "Timestamp,Cue,LatencyMS"]
        for evt in summary.lateTakeEvents {
            rows.append([
                csvField(timestampFormatter.string(from: evt.timestamp)),
                csvField(evt.cueDescriptor),
                "\(evt.latencyMS)"
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private static func renderSystemEvents(_ summary: PostShowSummary) -> String {
        var rows: [String] = ["# Section: SystemEvents", "Timestamp,Action,Detail"]
        for evt in summary.systemEvents {
            rows.append([
                csvField(timestampFormatter.string(from: evt.timestamp)),
                csvField(evt.action.rawValue),
                csvField(evt.detail ?? "")
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private static func renderSourceMix(_ summary: PostShowSummary) -> String {
        let mix = summary.sourceMix
        var rows: [String] = ["# Section: SourceMix", "Source,Count"]
        rows.append("Local,\(mix.local)")
        rows.append("OSC,\(mix.osc)")
        rows.append("HTTP,\(mix.http)")
        rows.append("Timecode,\(mix.timecode)")
        rows.append("System,\(mix.system)")
        return rows.joined(separator: "\n")
    }

    // MARK: - Internals

    /// Same ISO 8601 formatter the show-log uses, so timestamps in the
    /// post-show CSV match the raw log a producer might also be reading.
    private static let timestampFormatter: ISO8601DateFormatter = showLogISO8601Formatter

    /// RFC 4180 field quoting. Mirrors the show-log writer's helper (kept
    /// local so the exporter has no dependency on a private file-scope
    /// helper).
    private static func csvField(_ value: String) -> String {
        let needsQuote = value.contains(",")
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r")
        guard needsQuote else { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
