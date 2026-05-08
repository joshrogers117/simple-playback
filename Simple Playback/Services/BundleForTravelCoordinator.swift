import Foundation

enum BundleForTravelError: LocalizedError, Equatable {
    case mediaDirectoryUnwriteable(URL, String)
    case copyFailed(URL, String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .mediaDirectoryUnwriteable(let url, let reason):
            "Could not prepare \(url.lastPathComponent): \(reason)"
        case .copyFailed(let url, let reason):
            "Could not copy \(url.lastPathComponent): \(reason)"
        case .cancelled:
            "Bundle for Travel cancelled."
        }
    }
}

/// Live runtime state of one Bundle for Travel pass. Pure data — the coordinator
/// owns the lifecycle and republishes this for the progress sheet.
struct BundleForTravelProgress: Equatable {
    var completedCount: Int
    var totalCount: Int
    var bytesCopied: Int64
    var totalBytes: Int64
    var currentFilename: String?

    static let zero = BundleForTravelProgress(
        completedCount: 0,
        totalCount: 0,
        bytesCopied: 0,
        totalBytes: 0,
        currentFilename: nil
    )
}

/// Coordinates a C7d Bundle for Travel copy pass. Owns the I/O loop, publishes
/// progress, and exposes a cancel hook. Pure-logic plan/apply lives in
/// `BundleForTravelPlan`; this coordinator runs the live copies and signals
/// the host (RootView) to apply the plan to `project.slides` on completion.
///
/// **Threading limitation (known)**: the copy loop runs on the main actor.
/// `FileManager.copyItem` is synchronous; while a multi-GB file is copying,
/// the UI freezes (the progress bar can't tick mid-file, the Cancel button
/// can't be hit until the active copy returns). This is acceptable for v1
/// because typical show-sized media (single-digit GB per file) copies in
/// seconds on local SSDs; the concern is multi-tens-of-GB bundles to slower
/// volumes. A future iteration should hop the per-file copy to a detached
/// Task — out of scope here because the existing static-closure test seam
/// shape interacts awkwardly with `@Sendable` and we'd rather not regress
/// the stable test contract before there's a real perf ask.
///
/// Test seams: `copyFile`, `ensureDirectory`, `removeItem` are all injectable
/// statics. The coordinator's state machine is unit-tested via stubs that
/// drive synchronous completions.
@MainActor
final class BundleForTravelCoordinator: ObservableObject {

    enum State: Equatable {
        case idle
        case running(BundleForTravelProgress)
        case finished(BundleForTravelPlanReport)
        case failed(BundleForTravelError)
        case cancelled

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .idle

    /// Live default — copies a file from `source` to `destination`. Tests
    /// substitute a stub that records calls without touching the filesystem.
    static var copyFile: (URL, URL) throws -> Void = { source, destination in
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// Live default — ensures the parent directory exists. Idempotent; the
    /// FileManager call already handles the "already exists" path.
    static var ensureDirectory: (URL) throws -> Void = { url in
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    /// Live default — removes a file if present. Used to clear stale
    /// destinations from a prior aborted run before re-copying.
    static var removeItem: (URL) -> Void = { url in
        try? FileManager.default.removeItem(at: url)
    }

    private var isCancelled = false
    private var workTask: Task<Void, Never>?

    /// Kick off a Bundle for Travel pass. The coordinator copies each
    /// operation on a detached task (sequential — operators expect a
    /// predictable progress curve over a small number of large files), then
    /// invokes `completion` on the main actor. The host applies the plan to
    /// `project.slides` from there.
    ///
    /// Calling `start` while `state.isRunning` is true is a no-op so an
    /// accidental double-tap doesn't stack two passes.
    func start(
        plan: BundleForTravelPlanReport,
        mediaDirectoryURL: URL,
        completion: @escaping @MainActor (Result<BundleForTravelPlanReport, BundleForTravelError>) -> Void
    ) {
        guard !state.isRunning else { return }
        guard !plan.operations.isEmpty else {
            // Nothing to copy — finish immediately. The host can still apply()
            // to flip kind on already-managed slides (no-op) and refresh
            // fingerprints, but practically there's no work.
            state = .finished(plan)
            completion(.success(plan))
            return
        }

        isCancelled = false
        let initialProgress = BundleForTravelProgress(
            completedCount: 0,
            totalCount: plan.operations.count,
            bytesCopied: 0,
            totalBytes: plan.totalBytes,
            currentFilename: plan.operations.first?.destinationFilename
        )
        state = .running(initialProgress)

        let mediaDir = mediaDirectoryURL
        workTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Ensure the bundle's Media/ directory exists. Failure here aborts
            // the whole pass — we'd rather show one clean error than fail per
            // operation with the same root cause.
            do {
                try Self.ensureDirectory(mediaDir)
            } catch {
                let err = BundleForTravelError.mediaDirectoryUnwriteable(
                    mediaDir,
                    error.localizedDescription
                )
                self.state = .failed(err)
                completion(.failure(err))
                return
            }

            var bytesCopied: Int64 = 0
            for (index, op) in plan.operations.enumerated() {
                if self.isCancelled {
                    self.state = .cancelled
                    completion(.failure(.cancelled))
                    return
                }

                self.state = .running(BundleForTravelProgress(
                    completedCount: index,
                    totalCount: plan.operations.count,
                    bytesCopied: bytesCopied,
                    totalBytes: plan.totalBytes,
                    currentFilename: op.destinationFilename
                ))

                let destination = op.destinationURL(inMediaDirectory: mediaDir)
                Self.removeItem(destination)
                do {
                    try Self.copyFile(op.sourceURL, destination)
                } catch {
                    let err = BundleForTravelError.copyFailed(
                        op.sourceURL,
                        error.localizedDescription
                    )
                    self.state = .failed(err)
                    completion(.failure(err))
                    return
                }

                if let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
                    bytesCopied += Int64(size)
                }
            }

            let finalProgress = BundleForTravelProgress(
                completedCount: plan.operations.count,
                totalCount: plan.operations.count,
                bytesCopied: bytesCopied,
                totalBytes: plan.totalBytes,
                currentFilename: nil
            )
            self.state = .running(finalProgress)
            self.state = .finished(plan)
            completion(.success(plan))
        }
    }

    /// Operator-driven cancel. The active copy completes (we don't interrupt
    /// FileManager mid-copy — that risks a partial-file mess); subsequent
    /// operations are skipped and the state machine flips to `.cancelled`.
    func cancel() {
        guard state.isRunning else { return }
        isCancelled = true
    }

    /// Reset the coordinator to idle so a subsequent run isn't gated by the
    /// previous terminal state.
    func reset() {
        state = .idle
        isCancelled = false
        workTask = nil
    }
}
