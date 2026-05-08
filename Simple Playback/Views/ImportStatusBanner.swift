import SwiftUI

/// Aggregates non-modal failure notices from the media-pipeline subsystems (PDF rasterize,
/// Keynote AppleScript, ProRes transcode, plus unsupported drops). Operators previously
/// lost these — every failing path either returned an empty array or fired and forgot —
/// and the banner is the single surface that closes the loop without a modal sheet.
///
/// The banner is per-document: each `RootView` owns its own `@StateObject`. Failures are
/// append-only until the operator dismisses, so a second failed import doesn't silently
/// overwrite the first.
@MainActor
final class ImportStatusBanner: ObservableObject {
    @Published private(set) var failures: [MediaImportFailure] = []

    /// Append a batch of failures (the typical shape — `MediaImportReport.failures`).
    func record(_ batch: [MediaImportFailure]) {
        guard !batch.isEmpty else { return }
        failures.append(contentsOf: batch)
    }

    /// Append a transcode failure. Transcode runs through `TranscodeCoordinator`, not the
    /// importer, but the banner unifies all media-pipeline errors so the operator sees
    /// "things that didn't work" in one place.
    func recordTranscode(url: URL?, error: TranscodeError) {
        failures.append(MediaImportFailure(
            url: url,
            kind: .transcode,
            summary: error.errorDescription ?? "Transcode failed"
        ))
    }

    /// Operator clicked the dismiss control on the banner.
    func dismiss() {
        failures.removeAll()
    }

    /// Operator-facing one-liner for the banner. Singular vs. plural — small detail, but
    /// "1 items" looks unprofessional in a live show context.
    var headline: String {
        switch failures.count {
        case 0: return ""
        case 1: return "1 item failed to import"
        default: return "\(failures.count) items failed to import"
        }
    }
}

/// Non-modal banner rendered above the `OutputStatusBar` whenever the per-document
/// `ImportStatusBanner` has any pending failures. Spec §3.10 requires "Surface a clear
/// 'Keynote not installed' diagnostic if absent" — this is the surface for that and for
/// every other media-pipeline failure mode (PDF rasterize, ProRes transcode, unsupported
/// file types).
struct ImportStatusBannerView: View {
    @ObservedObject var banner: ImportStatusBanner
    @State private var showDetails = false

    var body: some View {
        if !banner.failures.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(banner.headline)
                    .font(.callout)
                Spacer()
                Button("Show Details") {
                    showDetails.toggle()
                }
                .controlSize(.small)
                .popover(isPresented: $showDetails) {
                    detailsPopover
                        .frame(minWidth: 320, idealWidth: 380, maxWidth: 540)
                }
                Button(action: banner.dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.10))
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(Color.red.opacity(0.25)),
                alignment: .bottom
            )
        }
    }

    @ViewBuilder
    private var detailsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import failures")
                .font(.headline)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(banner.failures) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.summary)
                                .font(.callout)
                            if let url = failure.url {
                                Text(url.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(14)
    }
}
