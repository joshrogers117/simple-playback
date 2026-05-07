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
