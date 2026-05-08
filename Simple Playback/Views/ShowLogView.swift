import AppKit
import SwiftUI

/// E3d — read-only show-log viewer. Renders one row per `ShowLogEvent` in
/// chronological order with optional severity-style colour for high-signal
/// actions (PANIC, MISSING_MEDIA). An Export CSV button funnels
/// `ShowLog.exportCSV()` into an `NSSavePanel`.
///
/// Filtering by source / action range is deferred to E4 — the v1 surface is
/// "open the sheet, scroll, eyeball, export".
struct ShowLogView: View {

    @ObservedObject var log: ShowLog
    let onClose: () -> Void

    /// Test seam — production opens an `NSSavePanel`; tests can substitute a
    /// closure that invokes the writer with a synthetic URL.
    var saveAction: (String) -> Void = ShowLogView.defaultSaveAction

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Show Log")
                    .font(.title3.bold())
                Text("\(log.events.count) event(s)")
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

            Divider()

            if log.events.isEmpty {
                ContentUnavailableView(
                    "No events yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Fire a cue or trigger an action to populate the log.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(log.events.enumerated()), id: \.offset) { _, event in
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
        case .clear, .blackout: .orange
        case .go, .previous: .primary
        case .showModeOn, .showModeOff: .accentColor
        case .oscAction, .httpAction, .timecodeTrigger: .secondary
        }
    }
}
