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
        }
        .font(.callout)
        .padding(14)
        .background(.bar)
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
