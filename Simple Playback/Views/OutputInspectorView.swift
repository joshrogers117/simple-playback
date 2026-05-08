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

                if project.recommendsTenBitOutput {
                    Divider()
                    tenBitRecommendationSection
                }
            }
            .padding(16)
        }
    }

    /// Phase B8 hint. Surfaces when any video slide in the project is flagged 10-bit (C1's
    /// `flags.tenBitYUV420`). Informational only — no auto-toggle, since changing the
    /// DeckLink output format mid-show is a deliberate re-arm action that belongs to B7.
    @ViewBuilder
    private var tenBitRecommendationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pixel format")
                .font(.subheadline.bold())
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("10-bit content detected")
                        .font(.callout)
                    Text("At least one video in this project is 10-bit. Configure the DeckLink output as 10-bit YUV 4:2:2 to preserve quality (spec §3.10).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.yellow.opacity(0.10))
            )
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
