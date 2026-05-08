import SwiftUI

/// Inspector for project-level output settings. Today this surface holds only the
/// "expects external reference" (genlock) toggle from spec §3.7; B7 (format negotiation),
/// B8 (10-bit YUV), and B13 (color pipeline) will populate further sections here.
///
/// The toggle is project-level, not per-Stage: a show file declares a single REF
/// expectation that travels with it between venues. When set and the active DeckLink
/// reports `unlocked` (free-run), the status bar escalates to a red banner.
struct OutputInspectorView: View {
    @Binding var project: PlayoutProject

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Output")
                    .font(.headline)

                stageSummary

                Divider()

                referenceSection
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var stageSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stage")
                .font(.subheadline.bold())
            if let stage = project.stages.first {
                LabeledContent("Name", value: stage.name)
                LabeledContent("Resolution", value: "\(stage.width) × \(stage.height)")
                LabeledContent("Frame rate", value: stageFPSDescription(stage))
                LabeledContent("Color space", value: stage.colorSpace.label)
                LabeledContent("Range", value: stage.range.label)
            } else {
                Text("Stage initializes when the project is saved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var referenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reliability")
                .font(.subheadline.bold())

            Toggle(isOn: $project.expectsExternalReference) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Expects external reference (genlock)")
                    Text("When on, free-run on the DeckLink output triggers a red banner instead of the orange chip.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private func stageFPSDescription(_ stage: Stage) -> String {
        let fps = stage.framesPerSecond
        let formatted: String
        if fps.isFinite, abs(fps - fps.rounded()) < 0.001 {
            formatted = String(format: "%.0f", fps)
        } else {
            formatted = String(format: "%.3f", fps)
        }
        return "\(formatted) fps (\(stage.frameRateNumerator)/\(stage.frameRateDenominator))"
    }
}
