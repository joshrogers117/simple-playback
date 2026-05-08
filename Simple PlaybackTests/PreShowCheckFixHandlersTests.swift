import Foundation
import XCTest
@testable import Simple_Playback

/// E2 — fix-action wiring for the pre-show check panel. Tests pin the
/// dispatch behaviour (handler invoked exactly when the row id matches)
/// and the deep-link URL contracts the host registers from. Production
/// handlers themselves call into NSWorkspace and aren't exercised here;
/// the host registers them in `RootView.preShowCheckFixHandlers()`.
final class PreShowCheckFixHandlersTests: XCTestCase {

    private func row(_ id: String, severity: PreShowCheck.Row.Severity = .error) -> PreShowCheck.Row {
        PreShowCheck.Row(id: id, severity: severity, title: "Test", summary: "")
    }

    func testCanFixIsFalseForUnregisteredRow() {
        let handlers = PreShowCheckFixHandlers()
        XCTAssertFalse(handlers.canFix(row("media.resolution")))
    }

    func testCanFixIsTrueWhenHandlerRegistered() {
        var handlers = PreShowCheckFixHandlers()
        handlers.byRowID["system.audio"] = {}
        XCTAssertTrue(handlers.canFix(row("system.audio")))
    }

    func testFixInvokesRegisteredHandlerOnce() {
        var callCount = 0
        var handlers = PreShowCheckFixHandlers()
        handlers.byRowID["system.disk"] = { callCount += 1 }
        handlers.fix(row("system.disk"))
        XCTAssertEqual(callCount, 1)
    }

    func testFixIsNoOpForUnregisteredRow() {
        // The dispatcher must not crash on a row id with no registered
        // handler — silently doing nothing is the right behaviour.
        let handlers = PreShowCheckFixHandlers()
        handlers.fix(row("output.tenBit"))
        // No assertion needed; the test passes if `fix` returns cleanly.
    }

    func testFixDispatchesByExactRowID() {
        var diskCalls = 0
        var audioCalls = 0
        var handlers = PreShowCheckFixHandlers()
        handlers.byRowID["system.disk"] = { diskCalls += 1 }
        handlers.byRowID["system.audio"] = { audioCalls += 1 }

        handlers.fix(row("system.disk"))
        XCTAssertEqual(diskCalls, 1)
        XCTAssertEqual(audioCalls, 0)

        handlers.fix(row("system.audio"))
        XCTAssertEqual(diskCalls, 1)
        XCTAssertEqual(audioCalls, 1)
    }

    // MARK: - Deep-link URL contracts

    /// Pin the System Settings → Sound URL form. macOS 26's System Settings
    /// still resolves the legacy `com.apple.preference.sound` form; the
    /// operator's flow on the audio fix depends on this URL.
    func testSoundSettingsURLIsValidDeepLink() {
        let url = PreShowFixDeepLinks.soundSettings
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        XCTAssertTrue(url.absoluteString.contains("com.apple.preference.sound"))
    }

    /// Pin the Blackmagic Desktop Video Setup install path. The host gates
    /// the `output.reference` Fix button on this file's existence — if
    /// Blackmagic moves the install location, the gate trips.
    func testBlackmagicDesktopVideoSetupPathIsCanonicalApplications() {
        let path = PreShowFixDeepLinks.blackmagicDesktopVideoSetupAppPath
        XCTAssertTrue(path.hasPrefix("/Applications/"))
        XCTAssertTrue(path.hasSuffix("Blackmagic Desktop Video Setup.app"))
    }
}
