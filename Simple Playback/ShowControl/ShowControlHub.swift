import Foundation

/// Process-wide singleton that owns the single `ShowControlStack` and rebinds it to the
/// active document's `CueRuntime`. Multi-document support: the most recently bound
/// runtime wins, since the OSC/HTTP listeners can only target one runtime at a time.
@MainActor
final class ShowControlHub {
    static let shared = ShowControlHub()

    let stack: ShowControlStack

    private init() {
        self.stack = ShowControlStack(runtime: nil)
    }

    /// Starts the underlying stack on first call. Idempotent.
    func startIfNeeded() {
        if !stack.isRunning {
            stack.start()
        }
    }

    /// Rebinds the dispatcher's runtime. Documents call this from their `ShowController`
    /// initializer so external triggers fire against their show list.
    func bind(runtime: CueRuntime?) {
        stack.bindRuntime(runtime)
    }

    func stop() {
        stack.stop()
    }
}
