import Foundation
import XCTest
@testable import Simple_Playback

/// E3b — verb-level show-log integration. Pin that every operator-driven
/// verb on `ShowController` records a corresponding event with the source
/// label the caller passed (defaulting to `.operatorButton` for the UI
/// path). Missing-media is also covered — the runtime fires a cue against
/// an absent asset and the controller logs a `.missingMedia` system event.
@MainActor
final class ShowControllerLogTests: XCTestCase {

    private func makeController(
        showList: ShowList = ShowList(name: "Test"),
        assetLookup: @escaping (UUID) -> MediaSlide? = { _ in nil }
    ) -> (controller: ShowController, log: ShowLog) {
        let playback = PlaybackController()
        let controller = ShowController(
            showList: showList,
            playback: playback,
            assetLookup: assetLookup,
            transitionSettings: { PlayoutTransitionSettings() },
            outputBinding: { (nil, nil) }
        )
        let log = ShowLog()
        controller.showLog = log
        return (controller, log)
    }

    private func cueWithSlide() -> (cue: Cue, slide: MediaSlide) {
        let slide = MediaSlide(url: URL(fileURLWithPath: "/tmp/a.mov"), mediaKind: .video)
        let cue = Cue(number: "1", title: "First", assetID: slide.id)
        return (cue, slide)
    }

    func testGORecordsEventWithCueDetailAndSource() {
        let (cue, slide) = cueWithSlide()
        let list = ShowList(name: "Show", cues: [cue])
        let (controller, log) = makeController(showList: list, assetLookup: { id in
            id == slide.id ? slide : nil
        })
        controller.go(source: .localHotkey)
        XCTAssertEqual(log.events.count, 1)
        XCTAssertEqual(log.events.first?.action, .go)
        XCTAssertEqual(log.events.first?.source, .localHotkey)
        XCTAssertEqual(log.events.first?.detail, "1")
    }

    func testGODefaultsToOperatorButtonSource() {
        let (cue, slide) = cueWithSlide()
        let list = ShowList(name: "Show", cues: [cue])
        let (controller, log) = makeController(showList: list, assetLookup: { _ in slide })
        controller.go()
        XCTAssertEqual(log.events.first?.source, .operatorButton)
    }

    func testPreviousLogsEvent() {
        let (controller, log) = makeController()
        controller.previous()
        XCTAssertEqual(log.events.last?.action, .previous)
    }

    func testPanicLogsActionWithFadeDetail() {
        let (controller, log) = makeController()
        controller.panic(fade: 0.5)
        XCTAssertEqual(log.events.last?.action, .panic)
        XCTAssertTrue(log.events.last?.detail?.contains("fade=") ?? false)
    }

    func testClearLogsEvent() {
        let (controller, log) = makeController()
        controller.clear()
        XCTAssertEqual(log.events.last?.action, .clear)
    }

    func testToggleBlackoutLogsEvent() {
        let (controller, log) = makeController()
        controller.toggleBlackout()
        XCTAssertEqual(log.events.last?.action, .blackout)
    }

    func testToggleShowModeRecordsOnAndOff() {
        let (controller, log) = makeController()
        XCTAssertFalse(controller.showMode)
        controller.toggleShowMode()
        XCTAssertEqual(log.events.last?.action, .showModeOn)
        controller.toggleShowMode()
        XCTAssertEqual(log.events.last?.action, .showModeOff)
    }

    // MARK: - OSC / dispatched-action attribution (E3c)

    /// Pin the `ShowControlSource` → `ShowLogEvent.Source` mapping. This is
    /// the seam between the OSC/HTTP dispatcher and the show log; tests fix
    /// the per-case translation so renaming on either side trips the test.
    func testOSCSourceTranslationCarriesHostAndPort() {
        let src = ShowControlSource.osc(host: "10.0.1.7", port: 53000, transport: .udp)
        XCTAssertEqual(src.toShowLogSource(), .osc(host: "10.0.1.7", port: 53000))
    }

    func testHTTPSourceTranslationCollapsesTokenToLastFour() {
        let src = ShowControlSource.http(token: "abcdef1234", host: "operator-mac.lan")
        XCTAssertEqual(src.toShowLogSource(), .http(tokenSuffix: "1234"))
    }

    func testHTTPSourceTranslationKeepsShortTokensVerbatim() {
        let src = ShowControlSource.http(token: "ab", host: "host")
        XCTAssertEqual(src.toShowLogSource(), .http(tokenSuffix: "ab"))
    }

    func testTimecodeSourceTranslation() {
        XCTAssertEqual(ShowControlSource.timecode.toShowLogSource(), .timecode)
    }

    func testLocalSourceTranslatesToOperatorButton() {
        XCTAssertEqual(ShowControlSource.local.toShowLogSource(), .operatorButton)
    }

    // MARK: - Dispatcher → show-log integration

    func testDispatchedGOLogsViaShowLog() {
        let (cue, slide) = cueWithSlide()
        let list = ShowList(name: "Show", cues: [cue])
        let (controller, log) = makeController(showList: list, assetLookup: { _ in slide })
        // ShowController's init has already wired itself to the hub's
        // dispatcher. Simulate an OSC GO landing on the dispatcher.
        let source = ShowControlSource.osc(host: "192.168.1.10", port: 53000, transport: .udp)
        ShowControlHub.shared.stack.dispatcher.onActionDispatched?(
            .go(target: nil),
            source,
            .ok(data: [:])
        )
        // Drain main runloop in case any async chain follows.
        let exp = expectation(description: "main runloop tick")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(log.events.contains { $0.action == .go && $0.source == .osc(host: "192.168.1.10", port: 53000) },
                      "Dispatched GO must land in the show log with OSC attribution.")
        _ = controller // keep alive
    }

    func testDispatchedShowModeMapsToOnOrOffEvent() {
        let (controller, log) = makeController()
        let source = ShowControlSource.osc(host: "h", port: 1, transport: .tcp)
        ShowControlHub.shared.stack.dispatcher.onActionDispatched?(
            .showMode(enabled: true), source, .ok(data: [:]))
        XCTAssertEqual(log.events.last?.action, .showModeOn)
        ShowControlHub.shared.stack.dispatcher.onActionDispatched?(
            .showMode(enabled: false), source, .ok(data: [:]))
        XCTAssertEqual(log.events.last?.action, .showModeOff)
        _ = controller
    }

    func testDispatchedPingDoesNotLog() {
        let (controller, log) = makeController()
        let source = ShowControlSource.osc(host: "h", port: 1, transport: .udp)
        ShowControlHub.shared.stack.dispatcher.onActionDispatched?(.ping, source, .ok(data: [:]))
        XCTAssertFalse(log.events.contains { $0.action == .oscAction },
                       "Diagnostic chatter (ping/subscribe) must not flood the operator log.")
        _ = controller
    }

    func testDispatchedNonVerbActionLogsAsOSCAction() {
        let (controller, log) = makeController()
        let source = ShowControlSource.osc(host: "h", port: 1, transport: .udp)
        ShowControlHub.shared.stack.dispatcher.onActionDispatched?(
            .cuePlay(cueNumber: "5"), source, .ok(data: [:]))
        XCTAssertEqual(log.events.last?.action, .oscAction)
        XCTAssertTrue(log.events.last?.detail?.contains("cuePlay 5") ?? false)
        _ = controller
    }

    func testGOWithMissingAssetLogsMissingMediaSystemEvent() {
        let cue = Cue(number: "9", title: "Orphan", assetID: UUID())
        let list = ShowList(name: "Show", cues: [cue])
        let (controller, log) = makeController(showList: list, assetLookup: { _ in nil })
        controller.go()
        // Wait for the runtime callback chain to drain — onCueFired posts back via
        // DispatchQueue.main.async, so we tick the run-loop.
        let exp = expectation(description: "main runloop tick")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        // Two events expected: GO (from controller.go) and MISSING_MEDIA (from
        // handleCueFired's guard let asset = ...).
        XCTAssertTrue(log.events.contains { $0.action == .missingMedia },
                      "Missing-media must be logged as a system event.")
        let missing = log.events.first(where: { $0.action == .missingMedia })
        XCTAssertEqual(missing?.source, .system)
        XCTAssertEqual(missing?.detail, "9")
    }
}
