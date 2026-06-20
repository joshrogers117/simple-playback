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
                        EffectSliderField(
                            title: "Blur",
                            value: slide.settings.blurRadius,
                            sliderRange: 0...SlideSettings.blurSliderMaximum,
                            typeBounds: 0...SlideSettings.maximumBlurRadius,
                            unit: "px",
                            rounding: 1,
                            decimals: 0
                        )
                        EffectSliderField(
                            title: "Hue",
                            value: slide.settings.hueShift,
                            sliderRange: -180...180,
                            typeBounds: -180...180,
                            unit: "°",
                            rounding: 1,
                            decimals: 0
                        )
                        EffectSliderField(
                            title: "Saturation",
                            value: slide.settings.saturation,
                            sliderRange: 0...200,
                            typeBounds: 0...200,
                            unit: "%",
                            rounding: 1,
                            decimals: 0
                        )
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

// A labeled slider paired with an editable value box. The field updates live as
// the slider is dragged, and the slider re-lays-out when a value is typed.
// `sliderRange` bounds the slider; `typeBounds` (>= sliderRange) bounds what can
// be typed, so values past the slider's max peg the thumb at the end.
private struct EffectSliderField: View {
    let title: String
    @Binding var value: Double
    let sliderRange: ClosedRange<Double>
    let typeBounds: ClosedRange<Double>
    let unit: String
    let rounding: Double
    let decimals: Int

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(
        title: String,
        value: Binding<Double>,
        sliderRange: ClosedRange<Double>,
        typeBounds: ClosedRange<Double>,
        unit: String,
        rounding: Double,
        decimals: Int
    ) {
        self.title = title
        self._value = value
        self.sliderRange = sliderRange
        self.typeBounds = typeBounds
        self.unit = unit
        self.rounding = rounding
        self.decimals = decimals
        // Seed the field at construction so it always shows the value, even for
        // rows that are realized lazily below the fold (onAppear isn't reliable).
        self._text = State(initialValue: Self.format(value.wrappedValue, decimals: decimals))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            HStack(spacing: 8) {
                // No `step:` so macOS doesn't draw the tick-mark rail; round in
                // the setter instead.
                Slider(
                    value: Binding(
                        get: { min(max(value, sliderRange.lowerBound), sliderRange.upperBound) },
                        set: { value = rounded($0) }
                    ),
                    in: sliderRange
                )

                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(.callout.monospacedDigit())
                    .frame(width: 52)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commit() }
                    }

                Text(unit)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        // Keep the field in sync when the value changes elsewhere (slider drag,
        // selecting a different slide) — but never stomp on the user mid-edit.
        .onChange(of: value) { _, newValue in
            if !isFocused { text = Self.format(newValue, decimals: decimals) }
        }
    }

    private func rounded(_ raw: Double) -> Double {
        guard rounding > 0 else { return raw }
        return (raw / rounding).rounded() * rounding
    }

    private func commit() {
        let parsed = Double(text.trimmingCharacters(in: .whitespaces)) ?? value
        value = min(typeBounds.upperBound, max(typeBounds.lowerBound, rounded(parsed)))
        text = Self.format(value, decimals: decimals)
        // Resign focus so the slider re-lays-out to the committed position.
        isFocused = false
    }

    private static func format(_ value: Double, decimals: Int) -> String {
        decimals <= 0 ? String(Int(value.rounded())) : String(format: "%.\(decimals)f", value)
    }
}
