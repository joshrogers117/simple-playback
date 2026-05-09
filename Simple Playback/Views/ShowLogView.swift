import AppKit
import SwiftUI

/// E3d / E4 — read-only show-log viewer. Renders one row per `ShowLogEvent`
/// in chronological order with optional severity-style colour for high-signal
/// actions (PANIC, MISSING_MEDIA). E4 adds a top toolbar that filters the
/// list by source bucket (Local / OSC / HTTP / TC / System), action bucket
/// (Show verbs / Remote API / System), and a "since" date pin so the
/// operator can scrub a multi-hour log down to "what fired in the last
/// 5 minutes" without exporting first.
///
/// Filtering is pure-logic on `ShowLog.filteredEvents` so SwiftUI redraws
/// re-run a single predicate, not a deep copy.
struct ShowLogView: View {

    @ObservedObject var log: ShowLog
    let onClose: () -> Void

    /// Test seam — production opens an `NSSavePanel`; tests can substitute a
    /// closure that invokes the writer with a synthetic URL.
    var saveAction: (String) -> Void = ShowLogView.defaultSaveAction

    @State private var sourceFilter: ShowLog.SourceFilter = .all
    @State private var actionFilter: ShowLog.ActionFilter = .all
    /// "Since" filter — when non-nil, only events at or after this time
    /// render. Operator picks from a small set of relative offsets ("Last
    /// minute", "Last 5 minutes", "Last hour", "All time"). Storing the
    /// absolute Date keeps the filter stable as the wall clock advances.
    @State private var sinceFilter: SinceFilter = .allTime

    private var visibleEvents: [ShowLogEvent] {
        log.filteredEvents(
            source: sourceFilter,
            action: actionFilter,
            since: sinceFilter.cutoffDate(now: Date())
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Show Log")
                    .font(.title3.bold())
                Text(eventCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Export CSV…") {
                    saveAction(log.exportCSV())
                }
                .disabled(log.events.isEmpty)
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            filterToolbar
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

            if case let .suspended(reason) = log.persistenceState {
                persistenceSuspendedBanner(reason: reason)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }

            Divider()

            if log.events.isEmpty {
                ContentUnavailableView(
                    "No events yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Fire a cue or trigger an action to populate the log.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleEvents.isEmpty {
                ContentUnavailableView(
                    "No events match the active filters",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Reset Source, Action, or Since to see more.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(visibleEvents.enumerated()), id: \.offset) { _, event in
                            ShowLogRowView(event: event)
                            Divider()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 880, minHeight: 420, idealHeight: 540)
    }

    /// Operator-facing summary — "8 of 142 events" when filters are
    /// active, plain "142 events" when they aren't. Plural-aware.
    private var eventCountLabel: String {
        let total = log.events.count
        let visible = visibleEvents.count
        let isFiltered = (sourceFilter != .all) || (actionFilter != .all) || (sinceFilter != .allTime)
        if isFiltered {
            return "\(visible) of \(total) event\(total == 1 ? "" : "s")"
        } else {
            return "\(total) event\(total == 1 ? "" : "s")"
        }
    }

    @ViewBuilder
    private var filterToolbar: some View {
        HStack(spacing: 12) {
            Picker("Source", selection: $sourceFilter) {
                ForEach(ShowLog.SourceFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 160)
            .help("Filter rows by where the action came from.")

            Picker("Action", selection: $actionFilter) {
                ForEach(ShowLog.ActionFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 160)
            .help("Filter rows by action category.")

            Picker("Since", selection: $sinceFilter) {
                ForEach(SinceFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 160)
            .help("Show only events from a recent window.")

            Spacer()

            if isAnyFilterActive {
                Button("Reset") {
                    sourceFilter = .all
                    actionFilter = .all
                    sinceFilter = .allTime
                }
                .controlSize(.small)
            }
        }
    }

    private var isAnyFilterActive: Bool {
        sourceFilter != .all || actionFilter != .all || sinceFilter != .allTime
    }

    /// Banner shown above the row list when the on-disk log writer has
    /// suspended persistence after a write failure (read-only volume,
    /// NAS timeout, full disk, permission flip mid-show). Operators must
    /// see the gap rather than discover it post-show. Re-arming happens
    /// when the host points the log at a new (or repaired) URL via
    /// `setFileURL`, which resets the state back to `.healthy`.
    @ViewBuilder
    private func persistenceSuspendedBanner(reason: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Disk log paused — events still captured in memory")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// Relative-window time filter rendered as a fixed picker. Storing
    /// "interval seconds" rather than a snapshot Date means the picker
    /// stays valid as the operator stares at the open viewer for hours.
    enum SinceFilter: String, Equatable, CaseIterable, Identifiable {
        case lastMinute
        case lastFiveMinutes
        case lastHour
        case allTime

        var id: String { rawValue }

        var label: String {
            switch self {
            case .lastMinute: "Last minute"
            case .lastFiveMinutes: "Last 5 minutes"
            case .lastHour: "Last hour"
            case .allTime: "All time"
            }
        }

        var seconds: TimeInterval? {
            switch self {
            case .lastMinute: 60
            case .lastFiveMinutes: 5 * 60
            case .lastHour: 60 * 60
            case .allTime: nil
            }
        }

        func cutoffDate(now: Date) -> Date? {
            guard let seconds else { return nil }
            return now.addingTimeInterval(-seconds)
        }
    }

    private static func defaultSaveAction(_ csv: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "show-log.csv"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }
}

private struct ShowLogRowView: View {
    let event: ShowLogEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(event.timestamp.formatted(date: .omitted, time: .standard))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)

            if let tc = event.chaseTimecode {
                Text(tc)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
            } else {
                Spacer().frame(width: 110)
            }

            Text(event.action.rawValue)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(actionColor)
                .frame(width: 130, alignment: .leading)

            Text(event.source.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)

            if let detail = event.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// High-signal actions get colour; everything else stays primary so the
    /// log doesn't read like a confetti cannon.
    private var actionColor: Color {
        switch event.action {
        case .panic, .missingMedia, .droppedFrame: .red
        case .lateTake: .orange
        case .clear, .blackout: .orange
        case .lockFileForeign: .orange
        case .go, .previous: .primary
        case .cueEnded, .takeLatency: .secondary
        case .showModeOn, .showModeOff: .accentColor
        case .oscAction, .httpAction, .timecodeTrigger: .secondary
        }
    }
}
