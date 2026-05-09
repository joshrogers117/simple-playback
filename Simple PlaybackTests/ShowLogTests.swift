import Foundation
import XCTest
@testable import Simple_Playback

/// E3a — show-log model + writer. Tests pin the CSV serialization shape (RFC
/// 4180 compliance), the file-writer behaviour (header on first write, append
/// on subsequent writes), and the source-attribution label form. The
/// integration with ShowController and the OSC/HTTP hub ships in a later
/// commit and has its own tests.
@MainActor
final class ShowLogTests: XCTestCase {

    private func makeEvent(
        action: ShowLogEvent.Action = .go,
        source: ShowLogEvent.Source = .localHotkey,
        detail: String? = nil,
        timecode: String? = nil
    ) -> ShowLogEvent {
        ShowLogEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            chaseTimecode: timecode,
            action: action,
            source: source,
            detail: detail
        )
    }

    // MARK: - CSV shape

    func testCSVLineHasFiveFieldsInFixedOrder() {
        let event = makeEvent(action: .go, source: .localHotkey, detail: "Q1")
        let parts = event.csvLine().split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 5, "Expected timestamp,tc,action,source,detail.")
        XCTAssertEqual(parts[2], "GO")
        XCTAssertEqual(parts[3], "local")
        XCTAssertEqual(parts[4], "Q1")
    }

    func testCSVLineFiveFieldShapeSurvivesCommaInDetail() {
        // Tightening the field-shape pin: the original test split on `,`
        // without honouring RFC 4180 quoting, so a future detail string
        // with an embedded comma would silently bump the field count and
        // pass a different per-cell layout. Re-pin via a quoted-aware
        // parser (count quote-balance manually).
        let event = makeEvent(action: .go, source: .localHotkey, detail: "Q,1")
        let line = event.csvLine()
        // Walk the line and split only on commas outside of `"..."`.
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        XCTAssertEqual(fields.count, 5, "Quoted detail must still produce 5 fields.")
        XCTAssertEqual(fields[2], "GO")
        XCTAssertEqual(fields[3], "local")
        XCTAssertEqual(fields[4], "\"Q,1\"")
    }

    func testCSVQuotesFieldsThatContainCommas() {
        let event = makeEvent(detail: "Cue 1, Reload Show")
        XCTAssertTrue(event.csvLine().contains("\"Cue 1, Reload Show\""))
    }

    func testCSVDoublesEmbeddedQuotes() {
        let event = makeEvent(detail: "Title with \"quotes\"")
        XCTAssertTrue(event.csvLine().contains("\"Title with \"\"quotes\"\"\""))
    }

    func testCSVPreservesEmptyTimecodeAsEmptyField() {
        let event = makeEvent(detail: "x", timecode: nil)
        // timestamp,tc,action,source,detail — tc field empty between two commas
        XCTAssertTrue(event.csvLine().contains(",,GO,"))
    }

    // MARK: - Source attribution

    func testSourceLabelLocalHotkey() {
        XCTAssertEqual(ShowLogEvent.Source.localHotkey.label, "local")
    }

    func testSourceLabelOSCIncludesHostAndPort() {
        let label = ShowLogEvent.Source.osc(host: "10.0.1.42", port: 53000).label
        XCTAssertEqual(label, "osc 10.0.1.42:53000")
    }

    func testSourceLabelHTTPRedactsAllButLastFour() {
        let label = ShowLogEvent.Source.http(tokenSuffix: "ab12").label
        XCTAssertTrue(label.contains("ab12"))
        XCTAssertFalse(label.contains("full"), "Token must not appear; only suffix.")
    }

    func testSourceLabelTimecodeIsCompact() {
        XCTAssertEqual(ShowLogEvent.Source.timecode.label, "tc")
    }

    // MARK: - In-memory append

    func testAppendStoresEventInOrder() {
        let log = ShowLog()
        log.appendNow(action: .go, source: .localHotkey, detail: "Q1")
        log.appendNow(action: .panic, source: .operatorButton)
        XCTAssertEqual(log.events.count, 2)
        XCTAssertEqual(log.events.first?.action, .go)
        XCTAssertEqual(log.events.last?.action, .panic)
    }

    func testExportCSVStartsWithHeader() {
        let log = ShowLog()
        log.appendNow(action: .clear, source: .system)
        let csv = log.exportCSV()
        XCTAssertTrue(csv.hasPrefix(ShowLog.csvHeader))
    }

    // MARK: - File writer hook

    func testSetFileURLSeedsHeaderViaWriterWhenFileMissing() {
        let log = ShowLog()
        var captured: [(URL, Data, Bool)] = []
        log.fileWriter = { url, data, append in
            captured.append((url, data, append))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent-\(UUID().uuidString).log")
        log.setFileURL(url)
        XCTAssertEqual(captured.count, 1)
        XCTAssertFalse(captured[0].2, "Header write must not be appending — overwrites a missing file.")
        XCTAssertEqual(String(data: captured[0].1, encoding: .utf8), ShowLog.csvHeader)
    }

    func testAppendAfterSetFileURLWritesAppendingLine() {
        let log = ShowLog()
        var appendWrites: [Data] = []
        var headerWritten = false
        log.fileWriter = { _, data, append in
            if append { appendWrites.append(data) } else { headerWritten = true }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-\(UUID().uuidString).log")
        log.setFileURL(url)
        XCTAssertTrue(headerWritten)
        log.appendNow(action: .go, source: .localHotkey, detail: "Q1")
        XCTAssertEqual(appendWrites.count, 1)
        let line = String(data: appendWrites[0], encoding: .utf8) ?? ""
        XCTAssertTrue(line.contains(",GO,local,Q1\n"))
    }

    func testFileWriterFailureSuppressesURLButKeepsInMemoryLog() {
        struct Boom: Error {}
        let log = ShowLog()
        log.fileWriter = { _, _, _ in throw Boom() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("boom-\(UUID().uuidString).log")
        log.setFileURL(url)
        XCTAssertNil(log.fileURL, "A failed seed write must clear the file URL so we don't retry on every event.")
        // In-memory append still works.
        log.appendNow(action: .clear, source: .system)
        XCTAssertEqual(log.events.count, 1)
    }

    // MARK: - Persistence state (F1 P1 session 25)

    func testInitialPersistenceStateIsHealthy() {
        let log = ShowLog()
        XCTAssertEqual(log.persistenceState, .healthy)
    }

    func testFailedSeedWriteFlipsPersistenceStateToSuspended() {
        struct Boom: Error {
            var localizedDescription: String { "synthetic boom" }
        }
        let log = ShowLog()
        log.fileWriter = { _, _, _ in throw Boom() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seed-fail-\(UUID().uuidString).log")
        log.setFileURL(url)
        guard case .suspended = log.persistenceState else {
            return XCTFail("Expected .suspended, got \(log.persistenceState)")
        }
    }

    func testFailedAppendFlipsPersistenceStateToSuspended() {
        struct Boom: Error {}
        let log = ShowLog()
        var allowSeed = true
        log.fileWriter = { _, _, append in
            if append || allowSeed {
                if append { throw Boom() }
                allowSeed = false
                return
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("append-fail-\(UUID().uuidString).log")
        log.setFileURL(url)
        XCTAssertEqual(log.persistenceState, .healthy, "Seed should succeed first.")
        log.appendNow(action: .go, source: .localHotkey)
        guard case .suspended = log.persistenceState else {
            return XCTFail("Expected .suspended after append failure")
        }
        // In-memory record still grew.
        XCTAssertEqual(log.events.count, 1)
        // fileURL was cleared so subsequent appends short-circuit.
        XCTAssertNil(log.fileURL)
    }

    func testReArmingFileURLResetsPersistenceStateToHealthy() {
        struct Boom: Error {}
        let log = ShowLog()
        log.fileWriter = { _, _, _ in throw Boom() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("re-arm-\(UUID().uuidString).log")
        log.setFileURL(url)
        guard case .suspended = log.persistenceState else {
            return XCTFail("Expected .suspended after seed failure")
        }
        // Operator points the writer at a healthy seam.
        log.fileWriter = { _, _, _ in /* succeed */ }
        let recovered = FileManager.default.temporaryDirectory.appendingPathComponent("recovered-\(UUID().uuidString).log")
        log.setFileURL(recovered)
        XCTAssertEqual(log.persistenceState, .healthy)
    }
}
