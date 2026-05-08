import Foundation
import XCTest
@testable import Simple_Playback

/// E4 — pure-logic filter tests. Pin every Source / Action bucket and the
/// "since" date filter. Combined-filter tests verify the predicates AND
/// together (not OR) so the operator can narrow down a busy log without
/// surprises.
@MainActor
final class ShowLogFilterTests: XCTestCase {

    private func event(
        action: ShowLogEvent.Action = .go,
        source: ShowLogEvent.Source = .localHotkey,
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ShowLogEvent {
        ShowLogEvent(
            timestamp: timestamp,
            chaseTimecode: nil,
            action: action,
            source: source,
            detail: nil
        )
    }

    private func makeLog(_ events: [ShowLogEvent]) -> ShowLog {
        let log = ShowLog()
        for event in events {
            log.append(event)
        }
        return log
    }

    // MARK: - SourceFilter

    func testSourceFilterAllMatchesEveryVariant() {
        let f = ShowLog.SourceFilter.all
        XCTAssertTrue(f.matches(.localHotkey))
        XCTAssertTrue(f.matches(.operatorButton))
        XCTAssertTrue(f.matches(.osc(host: "h", port: 1)))
        XCTAssertTrue(f.matches(.http(tokenSuffix: "x")))
        XCTAssertTrue(f.matches(.timecode))
        XCTAssertTrue(f.matches(.system))
    }

    func testSourceFilterLocalGroupsHotkeyAndOperatorButton() {
        let f = ShowLog.SourceFilter.local
        XCTAssertTrue(f.matches(.localHotkey))
        XCTAssertTrue(f.matches(.operatorButton))
        XCTAssertFalse(f.matches(.osc(host: nil, port: nil)))
        XCTAssertFalse(f.matches(.http(tokenSuffix: nil)))
        XCTAssertFalse(f.matches(.system))
    }

    func testSourceFilterOSCMatchesOnlyOSC() {
        XCTAssertTrue(ShowLog.SourceFilter.osc.matches(.osc(host: "h", port: 1)))
        XCTAssertFalse(ShowLog.SourceFilter.osc.matches(.http(tokenSuffix: "x")))
        XCTAssertFalse(ShowLog.SourceFilter.osc.matches(.localHotkey))
    }

    func testSourceFilterHTTPMatchesOnlyHTTP() {
        XCTAssertTrue(ShowLog.SourceFilter.http.matches(.http(tokenSuffix: "abc")))
        XCTAssertFalse(ShowLog.SourceFilter.http.matches(.osc(host: nil, port: nil)))
        XCTAssertFalse(ShowLog.SourceFilter.http.matches(.system))
    }

    func testSourceFilterTimecodeMatchesOnlyTimecode() {
        XCTAssertTrue(ShowLog.SourceFilter.timecode.matches(.timecode))
        XCTAssertFalse(ShowLog.SourceFilter.timecode.matches(.localHotkey))
    }

    func testSourceFilterSystemMatchesOnlySystem() {
        XCTAssertTrue(ShowLog.SourceFilter.system.matches(.system))
        XCTAssertFalse(ShowLog.SourceFilter.system.matches(.localHotkey))
    }

    // MARK: - ActionFilter

    func testActionFilterAllMatchesEveryAction() {
        let f = ShowLog.ActionFilter.all
        for action in ShowLogEvent.Action.allCases {
            XCTAssertTrue(f.matches(action), "all should match \(action.rawValue)")
        }
    }

    func testActionFilterRuntimeVerbsCoversShowSurface() {
        let f = ShowLog.ActionFilter.runtimeVerbs
        XCTAssertTrue(f.matches(.go))
        XCTAssertTrue(f.matches(.previous))
        XCTAssertTrue(f.matches(.panic))
        XCTAssertTrue(f.matches(.clear))
        XCTAssertTrue(f.matches(.blackout))
        XCTAssertTrue(f.matches(.showModeOn))
        XCTAssertTrue(f.matches(.showModeOff))
        XCTAssertFalse(f.matches(.oscAction))
        XCTAssertFalse(f.matches(.httpAction))
        XCTAssertFalse(f.matches(.timecodeTrigger))
        XCTAssertFalse(f.matches(.missingMedia))
        XCTAssertFalse(f.matches(.droppedFrame))
    }

    func testActionFilterRemoteActionsCoversOSCHTTPTC() {
        let f = ShowLog.ActionFilter.remoteActions
        XCTAssertTrue(f.matches(.oscAction))
        XCTAssertTrue(f.matches(.httpAction))
        XCTAssertTrue(f.matches(.timecodeTrigger))
        XCTAssertFalse(f.matches(.go))
        XCTAssertFalse(f.matches(.missingMedia))
    }

    func testActionFilterSystemEventsCoversMissingMediaAndDroppedFrame() {
        let f = ShowLog.ActionFilter.systemEvents
        XCTAssertTrue(f.matches(.missingMedia))
        XCTAssertTrue(f.matches(.droppedFrame))
        XCTAssertFalse(f.matches(.go))
        XCTAssertFalse(f.matches(.oscAction))
    }

    // MARK: - filteredEvents

    func testFilteredEventsAllReturnsEverything() {
        let log = makeLog([event(action: .go), event(action: .panic)])
        XCTAssertEqual(log.filteredEvents(source: .all, action: .all).count, 2)
    }

    func testFilteredEventsBySourceOSC() {
        let log = makeLog([
            event(source: .localHotkey),
            event(source: .osc(host: "h", port: 1)),
            event(source: .osc(host: "h", port: 2)),
            event(source: .system)
        ])
        let osc = log.filteredEvents(source: .osc, action: .all)
        XCTAssertEqual(osc.count, 2)
    }

    func testFilteredEventsCombinesSourceAndAction() {
        let log = makeLog([
            event(action: .go, source: .osc(host: "h", port: 1)),
            event(action: .panic, source: .osc(host: "h", port: 1)),
            event(action: .go, source: .localHotkey),
        ])
        let oscRuntime = log.filteredEvents(source: .osc, action: .runtimeVerbs)
        XCTAssertEqual(oscRuntime.count, 2)
    }

    func testFilteredEventsSinceDropsEarlier() {
        let now = Date()
        let log = makeLog([
            event(timestamp: now.addingTimeInterval(-3_600)), // 1h ago
            event(timestamp: now.addingTimeInterval(-30)),    // 30s ago
            event(timestamp: now)
        ])
        let recent = log.filteredEvents(
            source: .all,
            action: .all,
            since: now.addingTimeInterval(-60)
        )
        XCTAssertEqual(recent.count, 2)
    }

    func testFilteredEventsEmptyWhenNoneMatch() {
        let log = makeLog([event(action: .go, source: .localHotkey)])
        XCTAssertEqual(log.filteredEvents(source: .osc, action: .all).count, 0)
    }
}
