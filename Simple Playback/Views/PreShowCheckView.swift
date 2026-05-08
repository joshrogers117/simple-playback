import SwiftUI

/// E1 pre-show check panel. Renders a single non-modal sheet with one row per
/// `PreShowCheck.Row` returned by the evaluator — error rows first, then warnings, then
/// info, then ok. Spec §7.
///
/// The panel does not own the rule logic — `RootView` builds the row list via
/// `PreShowCheck.evaluate(project:context:)` and passes it in. That keeps the panel free
/// of cross-system signal sampling (disk space, DeckLink lock state, audio device) and
/// makes the panel itself trivially previewable / testable in isolation.
///
/// **What's deferred to E2**: per-row "Fix" buttons. The current panel is read-only —
/// the operator sees the issues and resolves them outside the panel (relink missing
/// media, free up disk, plug in the reference cable). E2 wires fix actions per row id.
struct PreShowCheckView: View {
    let rows: [PreShowCheck.Row]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Pre-Show Check")
                    .font(.title3.bold())
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if rows.isEmpty {
                ContentUnavailableView(
                    "Nothing to check",
                    systemImage: "checklist",
                    description: Text("Add cues, slides, or arm an output to populate the check.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rows) { row in
                            PreShowCheckRowView(row: row)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 440)
    }
}

private struct PreShowCheckRowView: View {
    let row: PreShowCheck.Row

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.subheadline.bold())
                Text(row.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
    }

    private var iconName: String {
        switch row.severity {
        case .error: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        case .ok: "checkmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch row.severity {
        case .error: .red
        case .warning: .orange
        case .info: .yellow
        case .ok: .green
        }
    }

    private var rowBackground: Color {
        switch row.severity {
        case .error: Color.red.opacity(0.08)
        case .warning: Color.orange.opacity(0.06)
        case .info: Color.yellow.opacity(0.06)
        case .ok: Color.green.opacity(0.05)
        }
    }
}
