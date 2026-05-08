import AppKit
import SwiftUI

/// E7 — crash-recovery controller + banner. Owns the per-document
/// recovery state (is there an autosave newer than Show.json?) and
/// surfaces a banner with Restore / Discard.
@MainActor
final class CrashRecoveryController: ObservableObject {

    /// Non-nil after a successful `evaluate(bundleURL:)` call when a
    /// checkpoint newer than Show.json was found. Drives the banner's
    /// visibility.
    @Published private(set) var recoverable: CrashRecoveryDetector.Recoverable?

    /// The bundle URL the recoverable checkpoint belongs to. Captured at
    /// evaluate time so Restore / Discard know what bundle to read /
    /// remove from.
    private(set) var bundleURL: URL?

    /// Test seam — replaceable detector entry points so tests don't need
    /// to touch the filesystem.
    private let detector: (URL) -> CrashRecoveryDetector.Recoverable?
    private let dataReader: (URL, String) throws -> Data
    private let discarder: (URL) throws -> Void

    nonisolated init(
        detector: @escaping (URL) -> CrashRecoveryDetector.Recoverable? = {
            CrashRecoveryDetector.findRecoverableCheckpoint(bundleURL: $0)
        },
        dataReader: @escaping (URL, String) throws -> Data = { url, name in
            try CrashRecoveryDetector.readCheckpointData(bundleURL: url, filename: name)
        },
        discarder: @escaping (URL) throws -> Void = { url in
            try CrashRecoveryDetector.discardCheckpoints(bundleURL: url)
        }
    ) {
        self.detector = detector
        self.dataReader = dataReader
        self.discarder = discarder
    }

    /// Evaluate the bundle for a recoverable checkpoint. Idempotent. Sets
    /// `recoverable` on success; clears it when no candidate exists.
    func evaluate(bundleURL: URL?) {
        guard let bundleURL else {
            recoverable = nil
            self.bundleURL = nil
            return
        }
        self.bundleURL = bundleURL
        recoverable = detector(bundleURL)
    }

    /// Read the recoverable checkpoint's payload. Returns nil and clears
    /// the banner state on failure (best-effort: we'd rather quietly fall
    /// back to the saved Show.json than crash recovery itself crash).
    @discardableResult
    func loadRecoverableData() -> Data? {
        guard let bundleURL, let recoverable else { return nil }
        let data = try? dataReader(bundleURL, recoverable.filename)
        return data
    }

    /// Operator picked Restore. The host calls this *after* it has
    /// successfully decoded and applied the checkpoint payload to the
    /// project. Clears the banner so the operator doesn't see it again
    /// on the next document re-evaluate.
    func didRestore() {
        recoverable = nil
    }

    /// Operator picked Discard — wipe the autosave directory and clear
    /// the banner. Best-effort; failures are swallowed because the
    /// banner is a recovery affordance, not a hard gate.
    func discard() {
        if let bundleURL {
            try? discarder(bundleURL)
        }
        recoverable = nil
    }
}

/// Banner rendered above the `OutputStatusBar` when a recoverable
/// checkpoint was detected at document open. Operator picks Restore
/// (load the checkpoint into the project) or Discard (wipe autosaves).
struct CrashRecoveryBannerView: View {
    @ObservedObject var controller: CrashRecoveryController
    /// Called when the operator clicks Restore. The host applies the
    /// payload to the project and then calls `controller.didRestore()`.
    var onRestore: () -> Void = {}

    var body: some View {
        if let recoverable = controller.recoverable {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Autosave newer than saved project")
                        .font(.callout.bold())
                    Text(summary(recoverable))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore") { onRestore() }
                    .controlSize(.small)
                Button("Discard") { controller.discard() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.yellow.opacity(0.14))
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(Color.yellow.opacity(0.30)),
                alignment: .bottom
            )
        }
    }

    private func summary(_ recoverable: CrashRecoveryDetector.Recoverable) -> String {
        let date = recoverable.checkpoint.timestamp.formatted(
            date: .abbreviated,
            time: .standard
        )
        return "Snapshot from \(date) (\(reasonLabel(recoverable.checkpoint.reason)))"
    }

    private func reasonLabel(_ reason: AutosaveCheckpoint.Reason) -> String {
        switch reason {
        case .showModeOn: "Show Mode on"
        case .showModeOff: "Show Mode off"
        case .manual: "Manual"
        }
    }
}
