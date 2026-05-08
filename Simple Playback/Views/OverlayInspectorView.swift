import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Inspector controls for the persistent compositor overlays attached to a `Stage` —
/// bug image (corner logo) and message text (lower-third / countdown timer).
///
/// Edits flow back to the project via the bound `CompositorOverlays`. The companion
/// `.onChange(of:)` in `RootView` mirrors the current value into `PlaybackController`
/// so changes take effect on the next composed frame.
struct OverlayInspectorView: View {
    @Binding var overlays: CompositorOverlays

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Stage Overlays")
                    .font(.headline)

                BugSection(bug: $overlays.bug)
                Divider()
                MessageSection(message: $overlays.message)
            }
            .padding(16)
        }
    }
}

private struct BugSection: View {
    @Binding var bug: BugOverlay

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bug / Logo")
                    .font(.subheadline.bold())
                Spacer()
                Toggle("Enabled", isOn: $bug.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            HStack(spacing: 8) {
                Text(bugImageDescription)
                    .font(.callout)
                    .foregroundStyle(bug.media == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseBugImage() }
                    .buttonStyle(.bordered)
                if bug.media != nil {
                    Button(role: .destructive) {
                        bug.media = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove bug image")
                }
            }

            Picker("Corner", selection: $bug.corner) {
                ForEach(BugCorner.allCases) { corner in
                    Text(corner.label).tag(corner)
                }
            }
            .pickerStyle(.segmented)

            sliderRow(
                label: "Size",
                value: $bug.sizePercent,
                range: 0.02...0.50,
                formatted: percentString(bug.sizePercent)
            )

            sliderRow(
                label: "Margin",
                value: $bug.marginPercent,
                range: 0...0.20,
                formatted: percentString(bug.marginPercent)
            )

            sliderRow(
                label: "Opacity",
                value: $bug.opacity,
                range: 0...1,
                formatted: percentString(bug.opacity)
            )
        }
        .disabled(!bug.enabled)
        .opacity(bug.enabled ? 1 : 0.55)
    }

    private var bugImageDescription: String {
        guard let media = bug.media else { return "No image selected" }
        return URL(fileURLWithPath: media.originalPath).lastPathComponent
    }

    private func chooseBugImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .image]
        if panel.runModal() == .OK, let url = panel.url {
            bug.media = MediaReference(url: url)
            if !bug.enabled {
                bug.enabled = true
            }
        }
    }
}

private struct MessageSection: View {
    @Binding var message: MessageOverlay

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Message / Timer")
                    .font(.subheadline.bold())
                Spacer()
                Toggle("Enabled", isOn: $message.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Message text — use {time_left} for countdown", text: $message.text)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("Position", selection: $message.position) {
                ForEach(MessagePosition.allCases) { pos in
                    Text(pos.label).tag(pos)
                }
            }
            .pickerStyle(.segmented)

            sliderRow(
                label: "Font Size",
                value: $message.fontSizePercent,
                range: 0.02...0.20,
                formatted: percentString(message.fontSizePercent)
            )

            sliderRow(
                label: "Opacity",
                value: $message.opacity,
                range: 0...1,
                formatted: percentString(message.opacity)
            )

            HStack(spacing: 12) {
                ColorPicker("Text", selection: textColorBinding, supportsOpacity: false)
                Toggle("Background", isOn: backgroundEnabledBinding)
                    .toggleStyle(.checkbox)
                if message.backgroundColor != nil {
                    ColorPicker("", selection: backgroundColorBinding, supportsOpacity: true)
                        .labelsHidden()
                }
            }

            CountdownEditor(message: $message)
        }
        .disabled(!message.enabled)
        .opacity(message.enabled ? 1 : 0.55)
    }

    private var textColorBinding: Binding<Color> {
        Binding(
            get: { Color(cgColor: message.textColor.cgColor) ?? .white },
            set: { message.textColor = RGBAColor(color: $0) }
        )
    }

    private var backgroundEnabledBinding: Binding<Bool> {
        Binding(
            get: { message.backgroundColor != nil },
            set: { enabled in
                if enabled, message.backgroundColor == nil {
                    message.backgroundColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.5)
                } else if !enabled {
                    message.backgroundColor = nil
                }
            }
        )
    }

    private var backgroundColorBinding: Binding<Color> {
        Binding(
            get: {
                guard let bg = message.backgroundColor else { return .black.opacity(0.5) }
                return Color(cgColor: bg.cgColor) ?? .black
            },
            set: { message.backgroundColor = RGBAColor(color: $0) }
        )
    }
}

private struct CountdownEditor: View {
    @Binding var message: MessageOverlay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Countdown to a target time", isOn: countdownEnabledBinding)
                .toggleStyle(.checkbox)

            if let _ = message.countdownTo {
                DatePicker("Target", selection: countdownDateBinding, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)

                Text("Use {time_left} in the text to substitute the live countdown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var countdownEnabledBinding: Binding<Bool> {
        Binding(
            get: { message.countdownTo != nil },
            set: { enabled in
                if enabled, message.countdownTo == nil {
                    message.countdownTo = Date().addingTimeInterval(60)
                } else if !enabled {
                    message.countdownTo = nil
                }
            }
        )
    }

    private var countdownDateBinding: Binding<Date> {
        Binding(
            get: { message.countdownTo ?? Date().addingTimeInterval(60) },
            set: { message.countdownTo = $0 }
        )
    }
}

@ViewBuilder
private func sliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>, formatted: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatted)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        Slider(value: value, in: range)
    }
}

private func percentString(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

extension RGBAColor {
    /// Initializer for SwiftUI `Color` interop. Falls back to the source `Color`'s sRGB
    /// representation; if that fails (e.g. system dynamic colors), defaults to white.
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.white
        self.init(
            red: Double(ns.redComponent),
            green: Double(ns.greenComponent),
            blue: Double(ns.blueComponent),
            alpha: Double(ns.alphaComponent)
        )
    }
}
