import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// v2 Post-Show Summary — operator-facing sheet rendering a `PostShowSummary`
/// computed from the live in-memory show log. Spec §4 item 18.
///
/// **Scope decisions for v2.0** (taken from `docs/v2/post_show_summary.md`'s
/// my-recommendation defaults; revisit when operators rehearse):
///
/// - **Q1 — time window**: since-launch only. The reducer reads
///   `log.events` (every event observed since the document opened). The
///   date-picker widening (Q1-D) is a v2.1 add when operators ask for
///   multi-day rehearsal-cycle reports.
/// - **Q5 — format default**: Markdown for human-paste, CSV for the
///   producer's spreadsheet. Both are saveable; Markdown is what the sheet
///   renders for preview.
/// - **Q6 — sensitive-data redaction**: skipped for v2.0 (default A —
///   unredacted). Operators in corporate-AV / broadcast typically share
///   post-show reports inside the tour / event team rather than publicly;
///   the redaction toggle ships in v2.1 once an operator explicitly asks.
///
/// SwiftUI's `Text(.init(markdown:))` doesn't render Markdown tables — the
/// sheet shows the raw Markdown in a monospaced ScrollView so the operator
/// sees the export shape verbatim. The Save / Copy paths produce the same
/// real Markdown / CSV string for downstream tools that handle tables.
struct PostShowSummaryView: View {

    @ObservedObject var log: ShowLog
    let onClose: () -> Void

    /// Test seam — production opens an `NSSavePanel`; tests can substitute a
    /// closure that records the call without I/O.
    var saveAction: (String, ExportFormat) -> Void = PostShowSummaryView.defaultSaveAction
    /// Test seam — production writes to NSPasteboard; tests can substitute.
    var copyAction: (String) -> Void = PostShowSummaryView.defaultCopyAction

    enum ExportFormat: String, Equatable {
        case markdown
        case csv

        var displayName: String {
            switch self {
            case .markdown: return "Markdown"
            case .csv: return "CSV"
            }
        }

        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .csv: return "csv"
            }
        }

        var contentType: UTType {
            switch self {
            case .markdown: return .plainText
            case .csv: return .commaSeparatedText
            }
        }
    }

    private var summary: PostShowSummary {
        PostShowSummary.from(events: log.events)
    }

    private var renderedMarkdown: String {
        PostShowMarkdownExporter.export(summary)
    }

    private var renderedCSV: String {
        PostShowCSVExporter.export(summary)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Post-Show Summary")
                    .font(.title3.bold())
                Text(eventCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy Markdown") {
                    copyAction(renderedMarkdown)
                }
                .disabled(log.events.isEmpty)
                Menu("Save…") {
                    Button("Markdown (.md)") {
                        saveAction(renderedMarkdown, .markdown)
                    }
                    Button("CSV (.csv)") {
                        saveAction(renderedCSV, .csv)
                    }
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
                    description: Text("The show log is empty. Fire a cue to populate it.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(renderedMarkdown)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 880, minHeight: 480, idealHeight: 600)
    }

    private var eventCountLabel: String {
        let n = log.events.count
        return "from \(n) event\(n == 1 ? "" : "s")"
    }

    // MARK: - Default actions

    private static func defaultSaveAction(_ contents: String, _ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "post-show-summary.\(format.fileExtension)"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? contents.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    private static func defaultCopyAction(_ contents: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(contents, forType: .string)
    }
}
