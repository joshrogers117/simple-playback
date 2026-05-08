import SwiftUI

/// E5 — read-only take-history viewer. Renders the last N cue fires
/// (newest first) so an operator can scroll back through what's gone
/// out tonight. Each row shows wall-clock time, cue number, title, and
/// the duration sampled at fire time.
///
/// Replay scrub is **deferred**: it would require a runtime entry point
/// to "fire cue X with original parameters at offset Y" which doesn't
/// exist yet. This sheet is the data foundation for that future
/// iteration.
struct TakeHistoryView: View {

    @ObservedObject var history: TakeHistory
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Take History")
                    .font(.title3.bold())
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if history.entries.isEmpty {
                ContentUnavailableView(
                    "No takes yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Fire a cue to start the history.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(history.latestEntries) { entry in
                            TakeHistoryRowView(entry: entry)
                            Divider()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 380, idealHeight: 480)
    }

    private var countLabel: String {
        let n = history.entries.count
        return "\(n) take\(n == 1 ? "" : "s")"
    }
}

private struct TakeHistoryRowView: View {
    let entry: TakeHistoryEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)

            Text(entry.cueNumber.isEmpty ? "—" : entry.cueNumber)
                .font(.system(.caption, design: .monospaced).bold())
                .frame(width: 70, alignment: .leading)

            Text(entry.cueTitle)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if let duration = entry.durationSecondsAtFire {
                Text(formattedDuration(duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
