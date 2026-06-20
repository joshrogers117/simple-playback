import SwiftUI

struct InspectorView: View {
    var slide: Binding<MediaSlide>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Inspector")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if let slide {
                Form {
                    Section("Slide") {
                        TextField("Name", text: slide.title)
                        LabeledContent("Kind") {
                            Text(slide.wrappedValue.mediaKind.rawValue.capitalized)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Transform") {
                        Picker("Scale", selection: slide.settings.scaleMode) {
                            ForEach(ScaleMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }

                        Picker("Align", selection: slide.settings.alignment) {
                            ForEach(AlignmentPreset.allCases) { alignment in
                                Text(alignment.label).tag(alignment)
                            }
                        }

                        if slide.wrappedValue.settings.scaleMode == .custom {
                            VStack(alignment: .leading) {
                                Text("Custom Scale")
                                Slider(value: slide.settings.customScale, in: 0.1...3, step: 0.01)
                                Text("\(Int(slide.wrappedValue.settings.customScale * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                            GridRow {
                                Text("X")
                                TextField("X", value: slide.settings.offsetX, format: .number)
                            }
                            GridRow {
                                Text("Y")
                                TextField("Y", value: slide.settings.offsetY, format: .number)
                            }
                        }
                    }

                    Section("Effects") {
                        BlurControl(blurRadius: slide.settings.blurRadius)
                    }

                    if slide.wrappedValue.mediaKind == .video {
                        Section("Video") {
                            Toggle("Loop", isOn: slide.settings.loopVideo)
                            VStack(alignment: .leading) {
                                Text("Volume")
                                Slider(value: slide.settings.volume, in: 0...1, step: 0.01)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("No Slide Selected", systemImage: "sidebar.right")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct BlurControl: View {
    @Binding var blurRadius: Double
    @State private var text: String = ""
    @FocusState private var amountIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Blur")
            HStack(spacing: 8) {
                Slider(value: $blurRadius, in: 0...SlideSettings.maximumBlurRadius, step: 1)

                TextField("Blur", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(.callout.monospacedDigit())
                    .frame(width: 52)
                    .focused($amountIsFocused)
                    .onSubmit(commit)
                    .onChange(of: amountIsFocused) { _, focused in
                        if !focused { commit() }
                    }

                Text("px")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { text = Self.string(blurRadius) }
        // Keep the field in sync when the value changes elsewhere (slider drag,
        // selecting a different slide) — but never stomp on the user mid-edit.
        .onChange(of: blurRadius) { _, newValue in
            if !amountIsFocused { text = Self.string(newValue) }
        }
    }

    private func commit() {
        let parsed = Double(text.trimmingCharacters(in: .whitespaces)) ?? blurRadius
        let clamped = min(SlideSettings.maximumBlurRadius, max(0, parsed))
        blurRadius = clamped
        text = Self.string(clamped)
        // Resign focus so the slider re-lays-out to the committed position.
        amountIsFocused = false
    }

    private static func string(_ value: Double) -> String {
        String(Int(value.rounded()))
    }
}
