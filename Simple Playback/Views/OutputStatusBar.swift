import SwiftUI

struct OutputStatusBar: View {
    @ObservedObject var playback: PlaybackController
    /// Project-level "expects external reference" toggle. When true and the active DeckLink
    /// reports `unlocked` (free-run), the chip escalates to a prominent red banner above the
    /// status row so a free-run state can't be missed in a dim booth. Spec §3.7.
    var referenceExpected: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if shouldShowFreeRunBanner {
                freeRunBanner
            }
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
    }

    /// True when the operator declared this show needs genlock and the DeckLink output is
    /// running but free-running. `idle` and `notSupported` deliberately don't escalate
    /// — they're not contradictions of the operator's expectation.
    var shouldShowFreeRunBanner: Bool {
        Self.evaluateFreeRunBanner(
            referenceExpected: referenceExpected,
            referenceState: playback.deckLinkReferenceState
        )
    }

    /// Pure decision used by the view. Extracted so tests can exercise every reference
    /// state × expectation combination without standing up a real `PlaybackController`.
    static func evaluateFreeRunBanner(
        referenceExpected: Bool,
        referenceState: DeckLinkTransportSink.ReferenceState?
    ) -> Bool {
        guard referenceExpected else { return false }
        return referenceState == .unlocked
    }

    @ViewBuilder
    private var freeRunBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout.weight(.bold))
            VStack(alignment: .leading, spacing: 1) {
                Text("REF EXPECTED — Output is free-running")
                    .font(.callout.weight(.semibold))
                Text("Verify the external reference signal is connected and locked.")
                    .font(.caption)
                    .opacity(0.95)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.red)
        .help("This project declares it needs an external reference (genlock), but the DeckLink output is currently free-running. Verify REF input or turn off the REF expectation in the Output inspector.")
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
        case .unlocked:
            // When REF is expected, the banner above carries the loud signal; the chip
            // stays orange so the redundant red-on-red doesn't drown out other state.
            return (.orange, Color.orange.opacity(0.18), "exclamationmark.triangle.fill")
        case .notSupported: return (.secondary, Color.secondary.opacity(0.12), "minus.circle")
        case .idle: return (.secondary, Color.secondary.opacity(0.12), "circle")
        }
    }

    private func referenceTooltip(_ state: DeckLinkTransportSink.ReferenceState) -> String {
        switch state {
        case .locked:
            return "External reference locked. Output is genlocked."
        case .unlocked:
            return referenceExpected
                ? "REF expected by the project but the DeckLink output is free-running. Verify the reference signal."
                : "External reference present but not locked. Output is free-running — confirm REF input is correct."
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
