import SwiftUI

/// Operator-supplied configuration for one Add Folder…  import (C5c-b). Built once when
/// the open panel returns and the folder walk completes; consumed when the operator hits
/// "Encode" in the sheet (or dismissed on Cancel).
///
/// **Frame rate is operator-supplied per sequence** — there is no committed default at
/// the encoder layer (see `ImageSequenceEncoder` doc) or at the project layer. The
/// `frameRate == 0` sentinel means "operator hasn't picked yet"; the sheet's Encode
/// button stays disabled until every sequence-marked-encode has a non-zero rate.
struct PendingFolderImport: Identifiable, Equatable {
    let id: UUID
    let folderURL: URL
    var sequencePlans: [SequencePlan]
    let standaloneMediaURLs: [URL]

    init(id: UUID = UUID(), folderURL: URL, plan: AddFolderImporter.Plan) {
        self.id = id
        self.folderURL = folderURL
        self.sequencePlans = plan.sequences.map { SequencePlan(sequence: $0) }
        self.standaloneMediaURLs = plan.standaloneMediaURLs
    }

    /// True when every sequence the operator wants to encode has a frame rate selected,
    /// AND there's actually something to do (at least one sequence to encode OR at least
    /// one standalone file to import). The Encode button drives off this.
    var canConfirm: Bool {
        let hasAnyAction = sequencePlans.contains(where: { $0.encode }) || !standaloneMediaURLs.isEmpty
        guard hasAnyAction else { return false }
        return sequencePlans.allSatisfy { !$0.encode || $0.frameRate >= 1 }
    }

    /// Sequence plans the operator confirmed for encoding (encode == true && rate ≥ 1).
    var encodableSequences: [SequencePlan] {
        sequencePlans.filter { $0.encode && $0.frameRate >= 1 }
    }

    struct SequencePlan: Identifiable, Equatable {
        let id: UUID
        let sequence: ImageSequenceDetector.Sequence
        /// `0` means "operator hasn't picked yet" — encode is gated on `>= 1`.
        var frameRate: Int
        var encode: Bool

        init(id: UUID = UUID(), sequence: ImageSequenceDetector.Sequence, frameRate: Int = 0, encode: Bool = true) {
            self.id = id
            self.sequence = sequence
            self.frameRate = frameRate
            self.encode = encode
        }
    }
}

/// Sheet rendered after Add Folder…  detects sequences. Operators see one row per
/// detected sequence (basename, frame count, ext, pad) with a per-sequence frame-rate
/// picker (24/25/30/48/50/60 plus a free-form text field for any other integer rate).
/// Standalone media (singletons + non-image files) are listed below as a count, since
/// they pass straight through `MediaImporter` without confirmation.
///
/// The sheet does not perform the encode itself — it hands the confirmed `PendingFolderImport`
/// back to the host (RootView) which routes sequences through the encode coordinator and
/// standalone URLs through the media importer.
struct AddFolderImportSheet: View {
    @Binding var pending: PendingFolderImport
    let onConfirm: (PendingFolderImport) -> Void
    let onCancel: () -> Void

    static let presetFrameRates: [Int] = [24, 25, 30, 48, 50, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Folder")
                    .font(.title3.bold())
                Text(pending.folderURL.lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if pending.sequencePlans.isEmpty {
                noSequencesNotice
            } else {
                sequencesList
            }

            if !pending.standaloneMediaURLs.isEmpty {
                Divider()
                Text(standaloneSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Encode") { onConfirm(pending) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!pending.canConfirm)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 240)
    }

    @ViewBuilder
    private var noSequencesNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("No image sequences detected. Standalone files will be imported as-is.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sequencesList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Image sequences")
                .font(.subheadline.bold())
            Text("Pick a frame rate per sequence. Image sequences carry no timing info — typical rates are 24 or 30 fps depending on source.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        ScrollView {
            VStack(spacing: 8) {
                ForEach($pending.sequencePlans) { $plan in
                    SequenceRow(plan: $plan)
                }
            }
        }
        .frame(minHeight: 120, maxHeight: 280)
    }

    private var standaloneSummary: String {
        let n = pending.standaloneMediaURLs.count
        return n == 1
            ? "Plus 1 standalone file will be imported as-is."
            : "Plus \(n) standalone files will be imported as-is."
    }
}

private struct SequenceRow: View {
    @Binding var plan: PendingFolderImport.SequencePlan

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $plan.encode)
                .toggleStyle(.checkbox)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(plan.sequence.baseName)
                    .font(.callout.bold())
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: $plan.frameRate) {
                Text("— fps").tag(0)
                ForEach(AddFolderImportSheet.presetFrameRates, id: \.self) { rate in
                    Text("\(rate) fps").tag(rate)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 100)
            .disabled(!plan.encode)

            TextField("fps", value: $plan.frameRate, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.callout.monospacedDigit())
                .frame(width: 56)
                .disabled(!plan.encode)
                .help("Custom integer fps — overrides the preset picker.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(plan.encode ? 0.06 : 0.02))
        )
    }

    private var detailLine: String {
        let count = plan.sequence.frameURLs.count
        let ext = plan.sequence.fileExtension.uppercased()
        let pad = plan.sequence.counterPadWidth
        return "\(count) frames • \(ext) • \(pad)-digit counter"
    }
}
