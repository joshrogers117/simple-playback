import SwiftUI

/// Persistent banner that surfaces the offline-slide count above
/// `OutputStatusBar`. Closes the C9 gap where the relink action lived only
/// inside the Pre-Show sheet — operators expect a non-modal "things to fix"
/// surface visible at all times, like the import-status banner that sits in
/// the same vertical stack.
///
/// The banner reads from a static `AssetLibraryStatus` snapshot — the host
/// recomputes via `AssetLibraryProbe` whenever `project.slides` (or the
/// bundle media URL) changes. The banner itself is presentation-only.
struct MissingMediaBannerView: View {
    let status: AssetLibraryStatus
    let onRelink: () -> Void
    let canRelink: Bool

    var body: some View {
        if status.offlineSlideCount > 0 {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.folder.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.large)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.callout.weight(.semibold))
                    if !status.offlineSlideTitles.isEmpty {
                        Text(subhead)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                if canRelink {
                    Button("Relink…", action: onRelink)
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.12))
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
    }

    /// Operator-facing headline. Singular/plural rendered explicitly because
    /// "1 media items offline" reads as a typo in live-show context.
    var headline: String {
        switch status.offlineSlideCount {
        case 1: return "1 media item offline"
        default: return "\(status.offlineSlideCount) media items offline"
        }
    }

    /// Comma-separated preview of the first few offline titles. Bounded by
    /// `AssetLibraryProbe`'s `previewLimit`, so even projects with hundreds
    /// of missing slides render a tight preview line.
    var subhead: String {
        let titles = status.offlineSlideTitles.joined(separator: ", ")
        if status.offlineSlideCount > status.offlineSlideTitles.count {
            let extra = status.offlineSlideCount - status.offlineSlideTitles.count
            return "\(titles), and \(extra) more"
        }
        return titles
    }
}
