import Foundation

/// Process-wide singleton that owns the single `ShowControlStack` and routes
/// remote-driven actions (OSC, HTTP, OSCQuery) to whichever document is
/// currently the "active" remote-control target.
///
/// **Per-document bind stack semantics** (replaces the prior
/// "most-recently-bound wins, prior bindings discarded" behaviour):
///
/// - Each `ShowController` (one per open NSDocument) calls `bind(...)` from
///   its initializer and gets back a `BindToken`. The token is stored on the
///   controller and unwound from `deinit` (or any explicit teardown).
/// - The stack of bindings is ordered by `bind` call order; the
///   most-recently-bound entry is the **active** one. The active binding's
///   runtime is what `dispatcher.runtime` points at, and its
///   `onActionDispatched` callback is what the dispatcher's fan-in invokes.
/// - When the active document closes, its `deinit` calls `unbind(token:)`,
///   which pops the entry. The previously-active binding (one entry below
///   on the stack) becomes active again automatically — opening doc B then
///   closing it returns remote control to doc A.
/// - If the active binding is unbound but other bindings remain, the
///   most-recently-bound *remaining* entry becomes active. If all
///   bindings are unbound, the dispatcher's runtime + callback are nil
///   (the OSC/HTTP listeners stay up but every action that needs a
///   runtime returns `no_runtime`).
///
/// This matches the natural operator mental model: open a confidence-monitor
/// document while the show is running and remote control still drives the
/// show document, because the show document was bound first and stays on the
/// stack; close the confidence-monitor and nothing changes (its binding was
/// transient). Open a second show document and remote control routes to the
/// new document; close it and remote control returns to the original. The
/// alternative — front-window-wins — would require NSWindow key/main
/// observation and a separate "is this the show window" toggle, both of
/// which are operator-visible UX choices that benefit from rehearsal review
/// (see `docs/decision_log.md` 2026-05-09 entry for the option matrix).
@MainActor
final class ShowControlHub {
    static let shared = ShowControlHub()

    let stack: ShowControlStack

    /// Opaque token returned from `bind(...)`. The caller stores it and
    /// passes it back to `unbind(token:)` when the binding should be
    /// released. UUID-backed so token comparison is value-equal and the
    /// token survives copy / capture without any reference semantics
    /// surprises.
    struct BindToken: Equatable {
        fileprivate let id: UUID
        fileprivate init() { self.id = UUID() }
        private init(placeholderID: UUID) { self.id = placeholderID }
        /// Placeholder token used by callers (e.g., `ShowController`) that
        /// need a stored-property initial value for definite-initialisation
        /// before the real bind happens later in the same `init` body. The
        /// hub never sees this value — it's never inserted into `bindings`,
        /// so `unbind(token: .placeholder)` is a no-op (matches the "unbind
        /// of unknown token is no-op" contract).
        static let placeholder = BindToken(placeholderID: UUID())
    }

    /// One per-document binding entry. `runtime` and `callback` are both
    /// captured weakly via the strong references the binding caller holds:
    /// when the caller deallocates without explicitly calling `unbind`, the
    /// stale entry stays on the stack until the next `bind` / `unbind` cycle
    /// triggers `applyActiveBinding`, but the dispatcher's `runtime` is
    /// re-assigned at every `applyActiveBinding` call so a stale top-of-
    /// stack entry pointing at a deallocated runtime cannot leak across
    /// the boundary. Production callers are expected to call `unbind` from
    /// `deinit`; the weak indirection is defensive, not the primary
    /// lifecycle hook.
    private struct Binding {
        let token: BindToken
        let runtime: CueRuntime?
        let onActionDispatched: (ShowControlAction, ShowControlSource, ShowControlActionResult) -> Void
    }

    private var bindings: [Binding] = []

    private init() {
        self.stack = ShowControlStack(runtime: nil)
        installFanIn()
    }

    /// Starts the underlying stack on first call. Idempotent.
    func startIfNeeded() {
        if !stack.isRunning {
            stack.start()
        }
    }

    /// Push a new binding. Returns a token the caller must hand back to
    /// `unbind(token:)` when the binding should be released (typically
    /// from the caller's `deinit`). The new binding becomes active
    /// immediately.
    @discardableResult
    func bind(
        runtime: CueRuntime?,
        onActionDispatched: @escaping (ShowControlAction, ShowControlSource, ShowControlActionResult) -> Void
    ) -> BindToken {
        let token = BindToken()
        bindings.append(Binding(token: token, runtime: runtime, onActionDispatched: onActionDispatched))
        applyActiveBinding()
        return token
    }

    /// Convenience overload for callers that don't care about
    /// `onActionDispatched` (most production callers do; tests sometimes
    /// don't). The callback is a no-op closure so the fan-in still has
    /// something to call without crashing.
    @discardableResult
    func bind(runtime: CueRuntime?) -> BindToken {
        bind(runtime: runtime, onActionDispatched: { _, _, _ in })
    }

    /// Pop the binding identified by `token`. If the popped binding was
    /// active, the next-most-recently-bound entry becomes active. No-op if
    /// the token is unknown (already unbound, or never registered).
    func unbind(token: BindToken) {
        bindings.removeAll { $0.token == token }
        applyActiveBinding()
    }

    /// Test seam — clear all bindings. Production never calls this. Tests
    /// that exercise the bind stack reset between cases use this so prior
    /// test residue doesn't leak into the next.
    func resetBindingsForTesting() {
        bindings.removeAll()
        applyActiveBinding()
    }

    /// Test seam — the count of currently-bound entries.
    var bindingDepthForTesting: Int { bindings.count }

    func stop() {
        stack.stop()
    }

    /// Re-route the dispatcher's runtime + callback to the most-recently-
    /// bound entry (or nil if the stack is empty). Called after every
    /// `bind` / `unbind` so a single source of truth governs which document
    /// remote control targets.
    private func applyActiveBinding() {
        if let active = bindings.last {
            stack.bindRuntime(active.runtime)
        } else {
            stack.bindRuntime(nil)
        }
    }

    /// Install a single fan-in closure on the dispatcher that routes every
    /// dispatched action to the currently-active binding's callback. The
    /// dispatcher exposes `onActionDispatched` as a single slot; the fan-in
    /// is the indirection that makes the slot multi-document-safe without
    /// the dispatcher needing to know about the bind stack at all.
    private func installFanIn() {
        stack.dispatcher.onActionDispatched = { [weak self] action, source, result in
            // Hop to main if not already there — the dispatcher's main-hop
            // helper for the callback already does this for off-main
            // transports; the extra capture-then-dispatch here is harmless
            // when called from on-main and necessary if a future
            // dispatcher path skips the hop.
            guard let self else { return }
            if Thread.isMainThread {
                self.dispatchToActiveBinding(action, source, result)
            } else {
                DispatchQueue.main.async {
                    self.dispatchToActiveBinding(action, source, result)
                }
            }
        }
    }

    private func dispatchToActiveBinding(
        _ action: ShowControlAction,
        _ source: ShowControlSource,
        _ result: ShowControlActionResult
    ) {
        bindings.last?.onActionDispatched(action, source, result)
    }
}
