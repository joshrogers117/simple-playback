import Foundation

/// Coalesces a burst of `schedule(_:)` calls into a single deferred
/// invocation. Each `schedule` cancels any pending work and arms a fresh
/// timer. The action runs when the timer expires without being superseded.
///
/// Used by `RootView.recomputeAssetLibraryStatus` so a 500-slide drag-reorder
/// (which fires `onChange(of: project.slides)` 500 times) collapses into one
/// `AssetLibraryProbe.evaluate` walk instead of 500 sequential
/// `FileManager.fileExists` bursts. The pure-logic walk is O(slides); the
/// syscalls are the hot path.
///
/// `@MainActor`-isolated so the action runs on the main thread (matching
/// SwiftUI `@State` write expectations). The sleep closure is injectable so
/// unit tests drive the wait window with a controllable delay.
@MainActor
final class Debouncer {
    private var task: Task<Void, Never>?
    private let interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        interval: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.interval = interval
        self.sleep = sleep
    }

    deinit {
        task?.cancel()
    }

    /// Cancels any pending action and arms a fresh one. The action runs after
    /// `interval` elapses without another `schedule` call. If `schedule` is
    /// called again before the timer expires, the prior pending action is
    /// dropped.
    func schedule(_ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        let interval = self.interval
        let sleep = self.sleep
        task = Task { @MainActor in
            do {
                try await sleep(interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    /// Drops any pending action without invoking it.
    func cancel() {
        task?.cancel()
        task = nil
    }
}
