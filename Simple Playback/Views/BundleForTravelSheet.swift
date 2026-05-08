import SwiftUI

/// Confirmation + progress + result sheet for the C7d Bundle for Travel
/// command. Drives off the coordinator's `state`:
/// - `.idle` shows the plan summary plus Confirm/Cancel.
/// - `.running` swaps in a progress bar + Cancel.
/// - `.finished` / `.failed` / `.cancelled` show a result summary + Done.
struct BundleForTravelSheet: View {
    @ObservedObject var coordinator: BundleForTravelCoordinator
    let plan: BundleForTravelPlanReport
    let mediaDirectoryURL: URL
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bundle for Travel")
                .font(.title2.bold())

            content

            Divider()

            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .idle:
            planSummary
        case .running(let progress):
            progressView(progress)
        case .finished:
            resultRow(symbol: "checkmark.circle.fill", color: .green,
                      message: "Copied \(plan.copyCount) media file\(plan.copyCount == 1 ? "" : "s") into the project bundle.")
        case .failed(let err):
            resultRow(symbol: "exclamationmark.triangle.fill", color: .orange,
                      message: err.errorDescription ?? "Bundle for Travel failed.")
        case .cancelled:
            resultRow(symbol: "xmark.circle.fill", color: .secondary,
                      message: "Bundle for Travel cancelled.")
        }
    }

    @ViewBuilder
    private var planSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Copy linked media into the project bundle so the show is venue-portable.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                summaryRow(label: "Files to copy", value: "\(plan.copyCount)")
                summaryRow(label: "Total size", value: Self.byteCountFormatter.string(fromByteCount: plan.totalBytes))
                if !plan.alreadyManagedSlideIDs.isEmpty {
                    summaryRow(label: "Already managed", value: "\(plan.alreadyManagedSlideIDs.count)",
                               valueColor: .secondary)
                }
                if !plan.offlineSlideIDs.isEmpty {
                    summaryRow(label: "Offline (skipped)", value: "\(plan.offlineSlideIDs.count)",
                               valueColor: .orange)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if !plan.offlineSlideIDs.isEmpty {
                Text("Offline media will be left as-is. Use Pre-Show ▸ Fix to relink before bundling, or skip and relink in the new venue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Destination: \(mediaDirectoryURL.path)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func progressView(_ progress: BundleForTravelProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: Double(progress.completedCount),
                         total: Double(max(progress.totalCount, 1)))
                .progressViewStyle(.linear)

            HStack {
                Text("\(progress.completedCount) of \(progress.totalCount)")
                Spacer()
                Text(byteString(copied: progress.bytesCopied, total: progress.totalBytes))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let name = progress.currentFilename {
                Text("Copying: \(name)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func resultRow(symbol: String, color: Color, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func summaryRow(label: String, value: String, valueColor: Color = .primary) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(valueColor)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var buttons: some View {
        switch coordinator.state {
        case .idle:
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(plan.copyCount == 0 ? "Done" : "Bundle", action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .disabled(plan.copyCount == 0)
        case .running:
            Button("Cancel", role: .destructive) { coordinator.cancel() }
                .keyboardShortcut(.cancelAction)
        case .finished, .failed, .cancelled:
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func byteString(copied: Int64, total: Int64) -> String {
        let f = Self.byteCountFormatter
        return "\(f.string(fromByteCount: copied)) of \(f.string(fromByteCount: total))"
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
}
