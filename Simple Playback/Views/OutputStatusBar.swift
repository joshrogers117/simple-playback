import SwiftUI

struct OutputStatusBar: View {
    @ObservedObject var playback: PlaybackController

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(playback.isRunning ? Color.red : Color.secondary)
                .frame(width: 8, height: 8)
            Text(playback.status)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            if let refState = playback.deckLinkReferenceState {
                referenceStatusChip(refState)
            }
        }
        .font(.callout)
        .padding(14)
        .background(.bar)
    }

    @ViewBuilder
    private func referenceStatusChip(_ state: DeckLinkTransportSink.ReferenceState) -> some View {
        let palette = referencePalette(state)
        HStack(spacing: 4) {
            Image(systemName: palette.icon).font(.caption2)
            Text("REF: \(state.label)").font(.caption.weight(.semibold))
        }
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(palette.background)
        )
        .help(referenceTooltip(state))
    }

    private func referencePalette(_ state: DeckLinkTransportSink.ReferenceState) -> (foreground: Color, background: Color, icon: String) {
        switch state {
        case .locked: return (.green, Color.green.opacity(0.15), "checkmark.circle.fill")
        case .unlocked: return (.orange, Color.orange.opacity(0.18), "exclamationmark.triangle.fill")
        case .notSupported: return (.secondary, Color.secondary.opacity(0.12), "minus.circle")
        case .idle: return (.secondary, Color.secondary.opacity(0.12), "circle")
        }
    }

    private func referenceTooltip(_ state: DeckLinkTransportSink.ReferenceState) -> String {
        switch state {
        case .locked:
            return "External reference locked. Output is genlocked."
        case .unlocked:
            return "External reference present but not locked. Output is free-running — confirm REF input is correct."
        case .notSupported:
            return "This DeckLink hardware does not provide an external reference input."
        case .idle:
            return "Reference status will appear when DeckLink output is running."
        }
    }
}

struct OutputPreferencesView: View {
    @ObservedObject var outputSettings: OutputSettingsStore
    @StateObject private var playback = PlaybackController()

    var body: some View {
        Form {
            Section("Output") {
                Picker("Device", selection: deviceSelection) {
                    ForEach(playback.devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }

                Picker("Mode", selection: modeSelection) {
                    ForEach(playback.modes(for: outputSettings.selectedDeviceID)) { mode in
                        Text(mode.name).tag(Optional(mode.id))
                    }
                }

                HStack(spacing: 10) {
                    Circle()
                        .fill(playback.devices.isEmpty ? Color.secondary : Color.green)
                        .frame(width: 8, height: 8)

                    Text(playback.status)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Button {
                        refreshDevices()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(20)
        .onAppear {
            refreshDevices()
        }
        .onChange(of: playback.devices) {
            outputSettings.applyDefaults(using: playback)
        }
    }

    private var deviceSelection: Binding<String?> {
        Binding {
            outputSettings.selectedDeviceID
        } set: { newValue in
            outputSettings.selectDevice(newValue, using: playback)
        }
    }

    private var modeSelection: Binding<String?> {
        Binding {
            outputSettings.selectedModeID
        } set: { newValue in
            outputSettings.selectedModeID = newValue
        }
    }

    private func refreshDevices() {
        playback.refreshDevices()
        outputSettings.applyDefaults(using: playback)
    }
}
