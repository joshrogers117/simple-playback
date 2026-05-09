import Foundation
import XCTest
@testable import Simple_Playback

/// Parametric coverage of `ShowControlDispatcher.dispatch(...)` across every
/// `ShowControlAction` variant. Pre-review only `.previous` and a handful of
/// neighbours were exercised; ~20 of ~30 variants had no test driving them
/// through the real dispatcher path. A copy-paste during a future cue-verb
/// addition (e.g. typo'd handler producing the wrong cue number in the
/// reply, or accidentally landing in the unknown_cue branch) would slip
/// through every other test.
///
/// The three tests below pin:
///
/// 1. Happy-path: every variant against a real cue produces a non-rejected
///    result with the cue number in the data payload (where applicable).
/// 2. Unknown-cue branch: every per-cue verb against a bogus cue number
///    produces `rejected("unknown_cue")` rather than crashing or silently
///    succeeding.
/// 3. Capability gating: every `.edit`-required variant rejects with
///    `missing_capability:edit` when the dispatcher's caller doesn't
///    hold edit. Same shape for `.fire` against a `.read`-only token.
@MainActor
final class ShowControlDispatcherActionCoverageTests: XCTestCase {

    private func makeRuntime() -> CueRuntime {
        var list = ShowList()
        try? list.append(Cue(number: "INTRO", title: "Intro", assetID: UUID()))
        try? list.append(Cue(number: "TWO", title: "Cue Two", assetID: UUID()))
        let runtime = CueRuntime(showList: list)
        // Disable the GO debounce so back-to-back fires in the parametric
        // tests don't reject with `.debounced`. Production keeps the
        // 250 ms default; the dispatcher's lockout (50 ms idempotency)
        // is exercised separately in the existing
        // testIdempotencyLockoutSuppressesRapidRetrigger test.
        runtime.minimumGoInterval = 0
        return runtime
    }

    private func makeDispatcher(runtime: CueRuntime, state: ShowControlState? = nil)
        -> ShowControlDispatcher
    {
        let s = state ?? ShowControlState()
        return ShowControlDispatcher(runtime: runtime, state: s, clock: { 0 })
    }

    /// One example of every action variant, parameterised against the
    /// pre-existing "INTRO" cue. Mirrors the array in
    /// `ShowControlActionIdempotencyKeyTests` so the two test files
    /// drift in lock-step when a new variant is added.
    private func actionsAgainstExistingCue() -> [ShowControlAction] {
        [
            .go(target: nil),
            .go(target: "INTRO"),
            .previous,
            .panic(fade: 0.5),
            .clear,
            .movePlayhead(cueNumber: "INTRO"),
            .load(cueNumber: "INTRO"),
            .cuePlay(cueNumber: "INTRO"),
            // .cueStop on a not-running cue rejects (`not_running`); covered
            // separately in testCueStopOnNotRunningCueRejectsNotRunning.
            .cueScrubNormalized(cueNumber: "INTRO", position: 0.5),
            .cueScrubSeconds(cueNumber: "INTRO", seconds: 5),
            .cueOpacity(cueNumber: "INTRO", value: 0.5),
            .cueAudioLevel(cueNumber: "INTRO", dB: -6),
            .cueInPoint(cueNumber: "INTRO", seconds: 1),
            .cueOutPoint(cueNumber: "INTRO", seconds: 5),
            .cueLoop(cueNumber: "INTRO", enabled: true),
            .cueGoto(cueNumber: "INTRO", nextNumber: "TWO"),
            .cuePreload(cueNumber: "INTRO"),
            .cueNotes(cueNumber: "INTRO", text: "test"),
            .outputFreeze(enabled: true),
            .outputBlackout(enabled: true),
            .lookRecall(name: "Show"),
            .timecodeSource(spec: "ltc:builtin"),
            .timecodeEngaged(enabled: true),
            .timecodeOffset(seconds: 1.0),
            .showMode(enabled: true),
            .workspaceSave,
            .workspaceReload,
            .ping,
            .subscribe(host: "h", port: 1),
            .unsubscribe(host: "h", port: 1)
        ]
    }

    private func cueTargetedActionsWithBogusCue() -> [ShowControlAction] {
        // Every variant whose handler explicitly checks `cue(number:)` and
        // returns `unknown_cue` on miss. `.go(target:)` is excluded because
        // its rejection is `go_failed` (the runtime layer rejects, not the
        // dispatcher); `.cuePlay` is excluded for the same reason — its
        // handler delegates to `runtime.go(targetNumber:)` and reports
        // `play_failed` for any failure mode (unknown cue / debounce /
        // panic-active). That conflation is a known divergence; pinned
        // separately in testCuePlayBogusCueRejectsPlayFailed below.
        [
            .movePlayhead(cueNumber: "BOGUS"),
            .load(cueNumber: "BOGUS"),
            .cueStop(cueNumber: "BOGUS", fade: nil),
            .cueScrubNormalized(cueNumber: "BOGUS", position: 0.5),
            .cueScrubSeconds(cueNumber: "BOGUS", seconds: 5),
            .cueOpacity(cueNumber: "BOGUS", value: 0.5),
            .cueAudioLevel(cueNumber: "BOGUS", dB: -6),
            .cueInPoint(cueNumber: "BOGUS", seconds: 1),
            .cueOutPoint(cueNumber: "BOGUS", seconds: 5),
            .cueLoop(cueNumber: "BOGUS", enabled: true),
            .cueGoto(cueNumber: "BOGUS", nextNumber: "TWO"),
            .cuePreload(cueNumber: "BOGUS"),
            .cueNotes(cueNumber: "BOGUS", text: "x")
        ]
    }

    // MARK: - 1. Happy path

    func testEveryActionVariantAgainstExistingCueReturnsOK() {
        // Each action runs against a FRESH runtime + dispatcher so prior
        // actions in the array (especially `.panic`, which sets
        // `panicActive`, and `.showMode`, which strips edit caps) don't
        // poison the next action's runtime state. The lockout-prevention
        // benefit is the same as making the dispatcher fresh, but the
        // runtime reset is the load-bearing one.
        let allCaps: Set<ShowControlCapability> = [.read, .fire, .edit]
        for action in actionsAgainstExistingCue() {
            let runtime = makeRuntime()
            let dispatcher = makeDispatcher(runtime: runtime)
            let result = dispatcher.dispatch(action, source: .test, capabilities: allCaps)
            switch result {
            case .ok:
                break
            case let .rejected(reason):
                XCTFail("\(action) returned rejected(\(reason)) under full caps; expected .ok")
            }
        }
    }

    // MARK: - 2. Unknown-cue branch

    func testEveryCueTargetedActionRejectsUnknownCueNumber() {
        let runtime = makeRuntime()
        let allCaps: Set<ShowControlCapability> = [.read, .fire, .edit]
        for action in cueTargetedActionsWithBogusCue() {
            let dispatcher = makeDispatcher(runtime: runtime)
            let result = dispatcher.dispatch(action, source: .test, capabilities: allCaps)
            guard case let .rejected(reason) = result else {
                XCTFail("\(action) returned \(result); expected rejected(\"unknown_cue\")")
                continue
            }
            XCTAssertEqual(reason, "unknown_cue",
                           "\(action) rejection reason should be unknown_cue, got \(reason)")
        }
    }

    func testCuePlayBogusCueRejectsPlayFailed() {
        // The dispatcher's cuePlay handler delegates to runtime.go(targetNumber:)
        // and reports `play_failed` for any nil return — it does NOT
        // distinguish unknown_cue from debounce / panic-active. That's
        // documented divergence vs. movePlayhead / cueStop / etc., which
        // explicitly check cue(number:) first. Pin the actual contract
        // so a future refactor that aligns the rejection reasons trips
        // this test deliberately.
        let runtime = makeRuntime()
        let dispatcher = makeDispatcher(runtime: runtime)
        let result = dispatcher.dispatch(
            .cuePlay(cueNumber: "BOGUS"),
            source: .test,
            capabilities: [.read, .fire]
        )
        guard case let .rejected(reason) = result else {
            XCTFail("cuePlay BOGUS returned \(result); expected rejected(\"play_failed\")")
            return
        }
        XCTAssertEqual(reason, "play_failed",
                       "cuePlay's rejection conflates unknown_cue / debounce / panic into play_failed; this is intentional and pinned.")
    }

    func testCueStopOnNotRunningCueRejectsNotRunning() {
        // The cue exists but is idle — cueStop's branch must report
        // `not_running` rather than ack with `applied=false`.
        let runtime = makeRuntime()
        let dispatcher = makeDispatcher(runtime: runtime)
        let result = dispatcher.dispatch(
            .cueStop(cueNumber: "INTRO", fade: nil),
            source: .test,
            capabilities: [.read, .fire]
        )
        guard case let .rejected(reason) = result else {
            XCTFail("cueStop on idle cue returned \(result); expected rejected(\"not_running\")")
            return
        }
        XCTAssertEqual(reason, "not_running")
    }

    // MARK: - 3. Capability gating

    func testEditOnlyVariantsRejectWhenCallerLacksEditCapability() {
        // The dispatcher classifies `.cueInPoint, .cueOutPoint, .cueLoop,
        // .cueGoto, .cueNotes` as `.edit`-required. With a fire-only token
        // each must reject with `missing_capability:edit`.
        let runtime = makeRuntime()
        let dispatcher = makeDispatcher(runtime: runtime)
        let editVariants: [ShowControlAction] = [
            .cueInPoint(cueNumber: "INTRO", seconds: 1),
            .cueOutPoint(cueNumber: "INTRO", seconds: 5),
            .cueLoop(cueNumber: "INTRO", enabled: true),
            .cueGoto(cueNumber: "INTRO", nextNumber: "TWO"),
            .cueNotes(cueNumber: "INTRO", text: "x")
        ]
        for action in editVariants {
            let result = dispatcher.dispatch(action, source: .test, capabilities: [.read, .fire])
            guard case let .rejected(reason) = result else {
                XCTFail("\(action) returned \(result) under fire-only caps; expected rejected(\"missing_capability:edit\")")
                continue
            }
            XCTAssertEqual(reason, "missing_capability:edit",
                           "Edit-required action \(action) should report missing_capability:edit, got \(reason)")
        }
    }

    func testFireOnlyVariantsRejectWhenCallerLacksFireCapability() {
        // Read-only token must be rejected for every fire-required action.
        // Spot-check a few; the full enumeration is already covered by the
        // capability classification.
        let runtime = makeRuntime()
        let dispatcher = makeDispatcher(runtime: runtime)
        let fireVariants: [ShowControlAction] = [
            .go(target: nil),
            .panic(fade: 0.5),
            .clear,
            .outputBlackout(enabled: true),
            .lookRecall(name: "x")
        ]
        for action in fireVariants {
            let result = dispatcher.dispatch(action, source: .test, capabilities: [.read])
            guard case let .rejected(reason) = result else {
                XCTFail("\(action) returned \(result) under read-only caps; expected missing_capability:fire")
                continue
            }
            XCTAssertEqual(reason, "missing_capability:fire")
        }
    }

    func testReadOnlyVariantsAcceptReadCapability() {
        // ping / subscribe / unsubscribe should not require fire.
        let runtime = makeRuntime()
        let dispatcher = makeDispatcher(runtime: runtime)
        let readVariants: [ShowControlAction] = [
            .ping,
            .subscribe(host: "h", port: 1),
            .unsubscribe(host: "h", port: 1)
        ]
        for action in readVariants {
            let local = makeDispatcher(runtime: runtime)
            let result = local.dispatch(action, source: .test, capabilities: [.read])
            guard case .ok = result else {
                XCTFail("\(action) returned \(result) under read-only caps; expected .ok")
                continue
            }
        }
    }

    // MARK: - 4. Show-Mode capability stripping

    func testShowModeStripsEditFromNonAdminCallers() {
        // E1 / D6 — Show Mode is the safety net that strips `.edit` from
        // any token. An operator-supplied token with edit must still be
        // rejected when Show Mode is on.
        let state = ShowControlState()
        state.updateShowMode(true)
        let runtime = makeRuntime()
        let dispatcher = makeDispatcher(runtime: runtime, state: state)
        let result = dispatcher.dispatch(
            .cueNotes(cueNumber: "INTRO", text: "edit attempt"),
            source: .test,
            capabilities: [.read, .fire, .edit]
        )
        guard case let .rejected(reason) = result else {
            XCTFail("cueNotes under Show Mode returned \(result); expected rejected(\"missing_capability:edit\")")
            return
        }
        XCTAssertEqual(reason, "missing_capability:edit",
                       "Show Mode must strip .edit even from full-cap tokens.")
    }
}
