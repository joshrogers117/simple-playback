import Foundation
import XCTest
@testable import Simple_Playback

/// E7 — pin the controller's state machine: evaluate sets `recoverable`,
/// `loadRecoverableData()` reads via the injected reader, `didRestore`
/// clears state, and `discard` removes via the injected remover.
@MainActor
final class CrashRecoveryControllerTests: XCTestCase {

    private let bundleURL = URL(fileURLWithPath: "/tmp/sp-test-bundle.spb")

    private func makeRecoverable() -> CrashRecoveryDetector.Recoverable {
        let cp = AutosaveCheckpoint(
            timestamp: Date(timeIntervalSinceReferenceDate: 100),
            reason: .showModeOn
        )
        return CrashRecoveryDetector.Recoverable(filename: cp.filename, checkpoint: cp)
    }

    func testEvaluateNilURLClearsRecoverable() {
        let controller = CrashRecoveryController(
            detector: { _ in self.makeRecoverable() },
            dataReader: { _, _ in Data() },
            discarder: { _ in }
        )
        controller.evaluate(bundleURL: bundleURL)
        XCTAssertNotNil(controller.recoverable)
        controller.evaluate(bundleURL: nil)
        XCTAssertNil(controller.recoverable)
    }

    func testEvaluateSetsRecoverableWhenDetectorReturnsCandidate() {
        let recoverable = makeRecoverable()
        let controller = CrashRecoveryController(
            detector: { _ in recoverable },
            dataReader: { _, _ in Data() },
            discarder: { _ in }
        )
        controller.evaluate(bundleURL: bundleURL)
        XCTAssertEqual(controller.recoverable?.filename, recoverable.filename)
    }

    func testLoadRecoverableDataInvokesReaderWithBundleURLAndFilename() {
        var capturedURL: URL?
        var capturedName: String?
        let recoverable = makeRecoverable()
        let controller = CrashRecoveryController(
            detector: { _ in recoverable },
            dataReader: { url, name in
                capturedURL = url
                capturedName = name
                return Data("payload".utf8)
            },
            discarder: { _ in }
        )
        controller.evaluate(bundleURL: bundleURL)
        let data = controller.loadRecoverableData()
        XCTAssertEqual(capturedURL, bundleURL)
        XCTAssertEqual(capturedName, recoverable.filename)
        XCTAssertEqual(data, Data("payload".utf8))
    }

    func testLoadRecoverableDataReturnsNilWhenReaderThrows() {
        let controller = CrashRecoveryController(
            detector: { _ in self.makeRecoverable() },
            dataReader: { _, _ in throw CocoaError(.fileReadCorruptFile) },
            discarder: { _ in }
        )
        controller.evaluate(bundleURL: bundleURL)
        XCTAssertNil(controller.loadRecoverableData())
    }

    func testDidRestoreClearsRecoverable() {
        let controller = CrashRecoveryController(
            detector: { _ in self.makeRecoverable() },
            dataReader: { _, _ in Data() },
            discarder: { _ in }
        )
        controller.evaluate(bundleURL: bundleURL)
        controller.didRestore()
        XCTAssertNil(controller.recoverable)
    }

    func testDiscardInvokesDiscarderAndClears() {
        var discardedURL: URL?
        let controller = CrashRecoveryController(
            detector: { _ in self.makeRecoverable() },
            dataReader: { _, _ in Data() },
            discarder: { url in discardedURL = url }
        )
        controller.evaluate(bundleURL: bundleURL)
        controller.discard()
        XCTAssertEqual(discardedURL, bundleURL)
        XCTAssertNil(controller.recoverable)
    }

    func testDiscardSwallowsDiscarderErrors() {
        let controller = CrashRecoveryController(
            detector: { _ in self.makeRecoverable() },
            dataReader: { _, _ in Data() },
            discarder: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
        controller.evaluate(bundleURL: bundleURL)
        controller.discard()
        XCTAssertNil(controller.recoverable, "Discard must clear state even when the remover fails")
    }
}
