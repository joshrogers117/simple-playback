import Foundation
import XCTest
@testable import Simple_Playback

/// Pin the per-document bind-stack semantics on `ShowControlHub`. The hub
/// is a process-wide singleton, so every test starts with
/// `resetBindingsForTesting()` to avoid bleed-through from prior runs.
@MainActor
final class ShowControlHubTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ShowControlHub.shared.resetBindingsForTesting()
    }

    override func tearDown() {
        ShowControlHub.shared.resetBindingsForTesting()
        super.tearDown()
    }

    // MARK: - bind / unbind basics

    func testBindReturnsTokenAndIncreasesDepth() {
        XCTAssertEqual(ShowControlHub.shared.bindingDepthForTesting, 0)
        let token = ShowControlHub.shared.bind(runtime: nil)
        XCTAssertEqual(ShowControlHub.shared.bindingDepthForTesting, 1)
        ShowControlHub.shared.unbind(token: token)
        XCTAssertEqual(ShowControlHub.shared.bindingDepthForTesting, 0)
    }

    func testUnbindOfUnknownTokenIsNoOp() {
        let known = ShowControlHub.shared.bind(runtime: nil)
        ShowControlHub.shared.unbind(token: .placeholder)
        XCTAssertEqual(ShowControlHub.shared.bindingDepthForTesting, 1,
                       "Unbinding a token never registered must not affect any other binding.")
        ShowControlHub.shared.unbind(token: known)
    }

    func testPlaceholderTokenIsAccepted() {
        // Placeholder is the value `ShowController` uses as a `var`'s initial
        // value before the real bind happens; it must compare equal to itself
        // and unequal to any real token, and `unbind(token: .placeholder)`
        // must be a safe no-op.
        let real = ShowControlHub.shared.bind(runtime: nil)
        XCTAssertNotEqual(ShowControlHub.BindToken.placeholder, real)
        ShowControlHub.shared.unbind(token: .placeholder)
        XCTAssertEqual(ShowControlHub.shared.bindingDepthForTesting, 1)
        ShowControlHub.shared.unbind(token: real)
    }

    // MARK: - active binding routes the dispatcher fan-in

    func testFanInRoutesToMostRecentlyBoundCallback() {
        var aFires = 0
        var bFires = 0
        let aToken = ShowControlHub.shared.bind(runtime: nil) { _, _, _ in aFires += 1 }
        let bToken = ShowControlHub.shared.bind(runtime: nil) { _, _, _ in bFires += 1 }
        ShowControlHub.shared.stack.dispatcher.onActionDispatched?(
            .ping, .test, .ok(data: [:])
        )
        XCTAssertEqual(aFires, 0, "A is not the active binding (B was bound after A).")
        XCTAssertEqual(bFires, 1, "B is the most-recently-bound, so the fan-in routes to it.")
        ShowControlHub.shared.unbind(token: bToken)
        ShowControlHub.shared.unbind(token: aToken)
    }

    func testUnbindingActiveRestoresPreviousAsActive() {
        var aFires = 0
        var bFires = 0
        let aToken = ShowControlHub.shared.bind(runtime: nil) { _, _, _ in aFires += 1 }
        let bToken = ShowControlHub.shared.bind(runtime: nil) { _, _, _ in bFires += 1 }

        ShowControlHub.shared.unbind(token: bToken)
        ShowControlHub.shared.stack.dispatcher.onActionDispatched?(
            .ping, .test, .ok(data: [:])
        )
        XCTAssertEqual(aFires, 1, "After B unbinds, A is back on top and receives the dispatch.")
        XCTAssertEqual(bFires, 0)
        ShowControlHub.shared.unbind(token: aToken)
    }

    func testUnbindingNonActiveLeavesActiveUntouched() {
        var aFires = 0
        var bFires = 0
        let aToken = ShowControlHub.shared.bind(runtime: nil) { _, _, _ in aFires += 1 }
        let bToken = ShowControlHub.shared.bind(runtime: nil) { _, _, _ in bFires += 1 }

        // Pop the non-active (A) — B stays active.
        ShowControlHub.shared.unbind(token: aToken)
        ShowControlHub.shared.stack.dispatcher.onActionDispatched?(
            .ping, .test, .ok(data: [:])
        )
        XCTAssertEqual(aFires, 0)
        XCTAssertEqual(bFires, 1, "B remains active after a non-active binding is removed.")
        ShowControlHub.shared.unbind(token: bToken)
    }

    func testEmptyStackFanInIsHarmlessNoOp() {
        // No bindings — the fan-in should still exist (installed once at hub
        // construction) and tolerate being called.
        ShowControlHub.shared.stack.dispatcher.onActionDispatched?(
            .ping, .test, .ok(data: [:])
        )
        // Reaching here without crash is the assertion.
        XCTAssertEqual(ShowControlHub.shared.bindingDepthForTesting, 0)
    }

    // MARK: - dispatcher.runtime tracks the active binding

    func testActiveBindingControlsDispatcherRuntime() {
        let runtimeA = CueRuntime(showList: ShowList(name: "A"))
        let runtimeB = CueRuntime(showList: ShowList(name: "B"))

        let aToken = ShowControlHub.shared.bind(runtime: runtimeA)
        XCTAssertTrue(ShowControlHub.shared.stack.dispatcher.runtime === runtimeA)

        let bToken = ShowControlHub.shared.bind(runtime: runtimeB)
        XCTAssertTrue(ShowControlHub.shared.stack.dispatcher.runtime === runtimeB,
                      "Binding B replaces A as the active runtime.")

        ShowControlHub.shared.unbind(token: bToken)
        XCTAssertTrue(ShowControlHub.shared.stack.dispatcher.runtime === runtimeA,
                      "Unbinding the active runtime restores the previous one.")

        ShowControlHub.shared.unbind(token: aToken)
        XCTAssertNil(ShowControlHub.shared.stack.dispatcher.runtime,
                     "All bindings released ⇒ dispatcher has no runtime to target.")
    }
}
