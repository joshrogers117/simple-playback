import AppKit
import SwiftUI

/// E8 — project lock controller + banner. Owns the per-document lock state
/// machine and the foreign-lock notification surface.
///
/// **State machine** (driven by `evaluate(bundleURL:)`):
///
/// 1. fileURL nil (untitled doc) → idle, no lock activity.
/// 2. fileURL set + no `.lock` exists → write our lock, mark owned.
/// 3. fileURL set + lock exists, ours → reuse, refresh timestamp.
/// 4. fileURL set + lock exists, stale (local-PID-dead or foreign-old) →
///    overwrite with our lock, mark owned.
/// 5. fileURL set + lock exists, live (local-PID-alive or foreign-recent) →
///    set `foreignBanner` so the operator sees the warning. We do NOT
///    silently take the lock; the operator chooses.
///
/// On `release()` (called by NSDocument.close on owning lifecycle) the lock
/// file is removed.
@MainActor
final class ProjectLockController: ObservableObject {

    /// Non-nil when an evaluate found a live foreign lock. Drives the
    /// banner's visibility.
    @Published private(set) var foreignBanner: ProjectLockFile?

    /// The bundle whose lock we currently own (if any). Used by `release()`
    /// to know what file to remove.
    private(set) var ownedBundleURL: URL?

    /// The bundle URL the operator was trying to open when a foreign lock
    /// was detected. Captured so "Open Anyway" knows which bundle to
    /// overwrite.
    private(set) var pendingBundleURL: URL?

    /// v2 Post-Show Summary Q4-B — fires once when `evaluate(...)` first
    /// detects a live foreign lock for a given bundle. The host wires this
    /// to push a `.lockFileForeign` row into the show log so the post-show
    /// summary's systemEvents section includes it. Re-evaluating with the
    /// same lock does not re-fire (the controller exits the foreign branch
    /// on the second call once `foreignBanner` is already set).
    var onForeignLockDetected: ((ProjectLockFile) -> Void)?

    /// Test seams.
    private let signalsProvider: () -> ProjectLockFileSignals
    private let isPIDAlive: (Int32) -> Bool
    private let nowProvider: () -> Date
    private let reader: (URL) -> ProjectLockFile?
    private let writer: (ProjectLockFile, URL) throws -> Void
    private let remover: (URL) -> Void

    init(
        signalsProvider: @escaping () -> ProjectLockFileSignals = ProjectLockFileSignals.current,
        isPIDAlive: @escaping (Int32) -> Bool = ProjectLockFileSignals.isPIDAliveDefault,
        now: @escaping () -> Date = Date.init,
        reader: @escaping (URL) -> ProjectLockFile? = { ProjectLockFileIO.read(bundleURL: $0) },
        writer: @escaping (ProjectLockFile, URL) throws -> Void = { lock, url in
            try ProjectLockFileIO.write(lock, bundleURL: url)
        },
        remover: @escaping (URL) -> Void = { ProjectLockFileIO.remove(bundleURL: $0) }
    ) {
        self.signalsProvider = signalsProvider
        self.isPIDAlive = isPIDAlive
        self.nowProvider = now
        self.reader = reader
        self.writer = writer
        self.remover = remover
    }

    /// Evaluate the lock at `bundleURL`. Idempotent — calling twice with
    /// the same URL is safe (the second call sees `ownedBundleURL ==
    /// bundleURL` and refreshes the timestamp instead of double-writing).
    func evaluate(bundleURL: URL?) {
        guard let bundleURL else {
            // Untitled documents have no on-disk bundle to lock against.
            // If we were holding a lock for a previously-saved bundle,
            // release it (rare — most often this branch fires on initial
            // makeWindowControllers for a new doc).
            release()
            return
        }

        if ownedBundleURL == bundleURL {
            refreshOwnedLock()
            return
        }

        let signals = signalsProvider()
        if let existing = reader(bundleURL) {
            let liveness = existing.liveness(
                now: nowProvider(),
                currentPID: signals.pid,
                currentHostname: signals.hostname,
                isPIDAlive: isPIDAlive
            )
            switch liveness {
            case .ours:
                // Existing lock is ours (e.g. previous launch crashed before
                // releasing — but PID matches because we got the same slot).
                // Reuse + refresh.
                ownedBundleURL = bundleURL
                refreshOwnedLock()
                return
            case .localStale, .foreignStale:
                acquire(bundleURL: bundleURL, signals: signals)
                return
            case .localLive, .foreignLive:
                let isFirstDetection = (foreignBanner != existing)
                pendingBundleURL = bundleURL
                foreignBanner = existing
                if isFirstDetection {
                    onForeignLockDetected?(existing)
                }
                return
            }
        }
        acquire(bundleURL: bundleURL, signals: signals)
    }

    /// Operator chose "Open Anyway" — overwrite the lock with our own.
    /// The previous holder's lock is gone; if they reopen the file, they
    /// will see *our* lock and have to confirm in the same way.
    func openAnyway() {
        guard let bundleURL = pendingBundleURL else { return }
        let signals = signalsProvider()
        acquire(bundleURL: bundleURL, signals: signals)
        foreignBanner = nil
        pendingBundleURL = nil
    }

    /// Operator clicked the banner's dismiss control. Closes the banner
    /// without touching the lock — the foreign owner stays the lock holder.
    /// Edits in this window proceed (Show Mode and the rest of the
    /// app's safety rails apply normally), but the operator has chosen
    /// not to claim ownership.
    func dismissBanner() {
        foreignBanner = nil
        pendingBundleURL = nil
    }

    /// Release the lock if we own one. Called from
    /// `SimplePlaybackProjectDocument.close`.
    func release() {
        if let url = ownedBundleURL {
            remover(url)
            ownedBundleURL = nil
        }
        pendingBundleURL = nil
        foreignBanner = nil
    }

    private func acquire(bundleURL: URL, signals: ProjectLockFileSignals) {
        let lock = signals.makeLock(now: nowProvider())
        do {
            try writer(lock, bundleURL)
            ownedBundleURL = bundleURL
        } catch {
            // Best-effort. If we can't write the lock (read-only volume,
            // permission denied) we don't track ownership — and we don't
            // refuse to open the document. The lock is a soft warning, not
            // a hard gate.
            ownedBundleURL = nil
        }
    }

    private func refreshOwnedLock() {
        guard let url = ownedBundleURL else { return }
        let signals = signalsProvider()
        let lock = signals.makeLock(now: nowProvider())
        try? writer(lock, url)
    }
}

/// Banner rendered above the `OutputStatusBar` when the per-document
/// `ProjectLockController` has detected a live foreign lock. Operator picks
/// from "Open Anyway" (claim ownership) or dismisses to keep editing without
/// claiming. Spec §3.16 calls for a third "Read Only" option; that requires
/// document-wide read-only enforcement which is a separate v1 follow-up.
struct ProjectLockBannerView: View {
    @ObservedObject var controller: ProjectLockController

    var body: some View {
        if let lock = controller.foreignBanner {
            HStack(spacing: 8) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This show is open elsewhere")
                        .font(.callout.bold())
                    Text(lock.bannerSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Anyway") {
                    controller.openAnyway()
                }
                .controlSize(.small)
                Button(action: { controller.dismissBanner() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(Color.orange.opacity(0.30)),
                alignment: .bottom
            )
        }
    }
}
