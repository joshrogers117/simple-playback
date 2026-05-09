import Foundation

/// v2 Post-Show Summary — Markdown exporter. Pure-function rendering of a
/// `PostShowSummary` value to a Markdown document the operator can paste into
/// a post-show email or share with the producer. Spec §4 item 18: "Post-show
/// summary report (CSV + human readable)."
///
/// **Format choices** (pinned by tests so downstream tools that consume this
/// don't break silently on a refactor):
///
/// - Section headings use `##` so they can nest under a parent doc heading.
/// - Tables use pipe syntax (`|`) so the file is valid GitHub-flavoured
///   Markdown. SwiftUI's built-in `Text(.init(markdown))` doesn't render
///   tables — the in-app sheet renders the source verbatim; the export path
///   produces real Markdown for downstream tools that handle tables.
/// - Empty sections render as `_(none)_` rather than being elided so an
///   operator scanning for problems sees the explicit zero.
/// - Durations use a `XmYs` / `Xh Ym Zs` form so the operator can read total
///   runtime at a glance without converting from raw seconds.
/// - Timestamps render as ISO 8601 (matching the show-log CSV format) so
///   times match between the post-show summary and the raw log a producer
///   might also be looking at.
enum PostShowMarkdownExporter {

    static func export(_ summary: PostShowSummary) -> String {
        var lines: [String] = []
        lines.append("# Post-Show Summary")
        lines.append("")
        appendWindow(into: &lines, summary: summary)
        lines.append("")
        appendTotals(into: &lines, summary: summary)
        lines.append("")
        appendCueStats(into: &lines, summary: summary)
        lines.append("")
        appendLatencyHistogram(into: &lines, summary: summary)
        lines.append("")
        appendDropEvents(into: &lines, summary: summary)
        lines.append("")
        appendLateTakes(into: &lines, summary: summary)
        lines.append("")
        appendSystemEvents(into: &lines, summary: summary)
        lines.append("")
        appendSourceMix(into: &lines, summary: summary)
        return lines.joined(separator: "\n")
    }

    // MARK: - Sections

    private static func appendWindow(into lines: inout [String], summary: PostShowSummary) {
        if let started = summary.showStartedAt {
            lines.append("**Started:** \(formatTimestamp(started))")
        } else {
            lines.append("**Started:** _(no events)_")
        }
        if let ended = summary.showEndedAt {
            lines.append("**Ended:** \(formatTimestamp(ended))")
        }
        if let elapsed = summary.elapsedSeconds {
            lines.append("**Elapsed:** \(formatDuration(elapsed))")
        }
        lines.append("**Total events:** \(summary.totalEventCount)")
    }

    private static func appendTotals(into lines: inout [String], summary: PostShowSummary) {
        lines.append("## Totals")
        lines.append("")
        lines.append("- GO: \(summary.totalGOs)")
        lines.append("- PREVIOUS: \(summary.totalPreviouses)")
        lines.append("- PANIC: \(summary.totalPanics)")
        lines.append("- CLEAR: \(summary.totalClears)")
        lines.append("- BLACKOUT: \(summary.totalBlackouts)")
        lines.append("- Show-mode toggles: \(summary.totalShowModeToggles)")
    }

    private static func appendCueStats(into lines: inout [String], summary: PostShowSummary) {
        lines.append("## Cue Stats")
        lines.append("")
        if summary.cueStats.isEmpty {
            lines.append("_(none)_")
            return
        }
        lines.append("| Cue | Fires | Paired | Avg runtime | Total runtime |")
        lines.append("|---|---:|---:|---:|---:|")
        for stats in summary.cueStats {
            let avg = stats.averageRuntimeSeconds.map(formatDuration) ?? "—"
            let total = stats.pairedCount > 0
                ? formatDuration(stats.totalRuntimeSeconds)
                : "—"
            lines.append(
                "| \(escapeCell(stats.descriptor)) | \(stats.fires) | "
                + "\(stats.pairedCount) | \(avg) | \(total) |"
            )
        }
    }

    private static func appendLatencyHistogram(into lines: inout [String], summary: PostShowSummary) {
        lines.append("## Take Latency Histogram")
        lines.append("")
        let h = summary.latencyHistogram
        if h.totalSamples == 0 {
            lines.append("_(none)_")
            return
        }
        lines.append("| Bucket | Count |")
        lines.append("|---|---:|")
        lines.append("| <50ms | \(h.under50ms) |")
        lines.append("| 50-100ms | \(h.from50to100ms) |")
        lines.append("| 100-200ms | \(h.from100to200ms) |")
        lines.append("| 200-500ms | \(h.from200to500ms) |")
        lines.append("| ≥500ms | \(h.over500ms) |")
        lines.append("")
        lines.append("**Total samples:** \(h.totalSamples)")
    }

    private static func appendDropEvents(into lines: inout [String], summary: PostShowSummary) {
        lines.append("## Drop Events (\(summary.dropEvents.count))")
        lines.append("")
        if summary.dropEvents.isEmpty {
            lines.append("_(none)_")
            return
        }
        lines.append("| Time | Detail |")
        lines.append("|---|---|")
        for evt in summary.dropEvents {
            lines.append("| \(formatTimestamp(evt.timestamp)) | \(escapeCell(evt.detail)) |")
        }
    }

    private static func appendLateTakes(into lines: inout [String], summary: PostShowSummary) {
        lines.append("## Late Takes (\(summary.lateTakeEvents.count))")
        lines.append("")
        if summary.lateTakeEvents.isEmpty {
            lines.append("_(none)_")
            return
        }
        lines.append("| Time | Cue | Latency |")
        lines.append("|---|---|---:|")
        for evt in summary.lateTakeEvents {
            lines.append(
                "| \(formatTimestamp(evt.timestamp)) | "
                + "\(escapeCell(evt.cueDescriptor)) | \(evt.latencyMS)ms |"
            )
        }
    }

    private static func appendSystemEvents(into lines: inout [String], summary: PostShowSummary) {
        lines.append("## System Events (\(summary.systemEvents.count))")
        lines.append("")
        if summary.systemEvents.isEmpty {
            lines.append("_(none)_")
            return
        }
        lines.append("| Time | Action | Detail |")
        lines.append("|---|---|---|")
        for evt in summary.systemEvents {
            lines.append(
                "| \(formatTimestamp(evt.timestamp)) | "
                + "\(evt.action.rawValue) | \(escapeCell(evt.detail ?? "")) |"
            )
        }
    }

    private static func appendSourceMix(into lines: inout [String], summary: PostShowSummary) {
        lines.append("## Source Mix")
        lines.append("")
        let mix = summary.sourceMix
        lines.append("- Local: \(mix.local)")
        lines.append("- OSC: \(mix.osc)")
        lines.append("- HTTP: \(mix.http)")
        lines.append("- Timecode: \(mix.timecode)")
        lines.append("- System: \(mix.system)")
        lines.append("- **Total:** \(mix.total)")
    }

    // MARK: - Formatters

    /// Match the show-log CSV timestamp format so the post-show report and
    /// the raw log stay readable side-by-side.
    static func formatTimestamp(_ date: Date) -> String {
        showLogISO8601Formatter.string(from: date)
    }

    /// Compact human-readable duration. Under 1 minute as `X.Xs`; under 1
    /// hour as `XmY.Ys`; else `XhYmZ.Zs`. Tested at the bucket boundaries.
    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0.0s" }
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        if seconds < 3600 {
            let minutes = Int(seconds) / 60
            let remainder = seconds - Double(minutes * 60)
            return "\(minutes)m" + String(format: "%.1fs", remainder)
        }
        let hours = Int(seconds) / 3600
        let afterHours = seconds - Double(hours * 3600)
        let minutes = Int(afterHours) / 60
        let remainder = afterHours - Double(minutes * 60)
        return "\(hours)h\(minutes)m" + String(format: "%.1fs", remainder)
    }

    /// Escape pipe / newline characters so the cell doesn't break the table.
    /// `|` becomes `\|`; embedded newlines collapse to a space.
    private static func escapeCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
