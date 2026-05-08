import Foundation
import XCTest
@testable import Simple_Playback

/// E7 — pure-logic detection of "is there an autosave checkpoint newer
/// than the saved Show.json?" The tests pin every branch — empty / no
/// directory / older / newer / equal / unparseable filenames.
final class CrashRecoveryDetectorTests: XCTestCase {

    private let bundleURL = URL(fileURLWithPath: "/tmp/sp-test-bundle.spb")

    /// Build a checkpoint filename for `(timestamp, reason)`.
    private func filename(_ timestamp: Date, _ reason: AutosaveCheckpoint.Reason) -> String {
        AutosaveCheckpoint(timestamp: timestamp, reason: reason).filename
    }

    func testReturnsNilWhenAutosaveDirectoryMissing() {
        let result = CrashRecoveryDetector.findRecoverableCheckpoint(
            bundleURL: bundleURL,
            directoryLister: { _ in throw CocoaError(.fileNoSuchFile) },
            modificationDate: { _ in nil }
        )
        XCTAssertNil(result)
    }

    func testReturnsNilWhenAutosaveDirectoryEmpty() {
        let result = CrashRecoveryDetector.findRecoverableCheckpoint(
            bundleURL: bundleURL,
            directoryLister: { _ in [] },
            modificationDate: { _ in Date() }
        )
        XCTAssertNil(result)
    }

    func testReturnsNilWhenOnlyUnparseableFilesPresent() {
        let result = CrashRecoveryDetector.findRecoverableCheckpoint(
            bundleURL: bundleURL,
            directoryLister: { _ in [".DS_Store", "garbage.json", "no_underscore.json"] },
            modificationDate: { _ in nil }
        )
        XCTAssertNil(result)
    }

    func testReturnsNewestCheckpointWhenNoShowJSONExists() {
        let early = Date(timeIntervalSinceReferenceDate: 0)
        let late = Date(timeIntervalSinceReferenceDate: 100)
        let result = CrashRecoveryDetector.findRecoverableCheckpoint(
            bundleURL: bundleURL,
            directoryLister: { _ in [
                filename(early, .showModeOn),
                filename(late, .showModeOff)
            ] },
            modificationDate: { _ in nil }
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.checkpoint.timestamp, late)
        XCTAssertEqual(result?.checkpoint.reason, .showModeOff)
    }

    func testReturnsNilWhenAllCheckpointsOlderThanShowJSON() {
        let early = Date(timeIntervalSinceReferenceDate: 0)
        let saved = Date(timeIntervalSinceReferenceDate: 200)
        let result = CrashRecoveryDetector.findRecoverableCheckpoint(
            bundleURL: bundleURL,
            directoryLister: { _ in [filename(early, .showModeOn)] },
            modificationDate: { _ in saved }
        )
        XCTAssertNil(result)
    }

    func testReturnsNilWhenCheckpointTimestampEqualsSavedMTime() {
        let same = Date(timeIntervalSinceReferenceDate: 100)
        let result = CrashRecoveryDetector.findRecoverableCheckpoint(
            bundleURL: bundleURL,
            directoryLister: { _ in [filename(same, .manual)] },
            modificationDate: { _ in same }
        )
        XCTAssertNil(result, "Equal timestamps shouldn't trigger recovery")
    }

    func testReturnsCheckpointWhenStrictlyNewerThanShowJSON() {
        let saved = Date(timeIntervalSinceReferenceDate: 100)
        let later = saved.addingTimeInterval(60)
        let result = CrashRecoveryDetector.findRecoverableCheckpoint(
            bundleURL: bundleURL,
            directoryLister: { _ in [filename(later, .showModeOn)] },
            modificationDate: { url in
                // Show.json gets the saved mtime; checkpoint files get nil.
                url.lastPathComponent == ProjectBundleLayout.projectFilename ? saved : nil
            }
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.checkpoint.timestamp, later)
    }

    func testIgnoresUnparseableFilenamesAlongsideValidOnes() {
        let later = Date(timeIntervalSinceReferenceDate: 100)
        let result = CrashRecoveryDetector.findRecoverableCheckpoint(
            bundleURL: bundleURL,
            directoryLister: { _ in [
                "garbage.txt",
                filename(later, .showModeOn),
                ".DS_Store"
            ] },
            modificationDate: { _ in nil }
        )
        XCTAssertEqual(result?.checkpoint.timestamp, later)
    }

    func testReadCheckpointDataReturnsBytesFromFile() throws {
        let fname = filename(Date(timeIntervalSinceReferenceDate: 0), .manual)
        let payload = Data("hello-world".utf8)
        let read = try CrashRecoveryDetector.readCheckpointData(
            bundleURL: bundleURL,
            filename: fname,
            fileReader: { url in
                XCTAssertTrue(url.path.hasSuffix("Autosave/\(fname)"))
                return payload
            }
        )
        XCTAssertEqual(read, payload)
    }

    func testDiscardCheckpointsRemovesAutosaveDirectory() throws {
        var removed: URL?
        try CrashRecoveryDetector.discardCheckpoints(
            bundleURL: bundleURL,
            directoryRemover: { url in removed = url }
        )
        XCTAssertEqual(removed?.path, bundleURL.appendingPathComponent("Autosave").path)
    }
}
