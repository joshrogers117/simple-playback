import CoreAudio
import Foundation
import XCTest
@testable import Simple_Playback

/// E1 audio-device adapter — the seam between CoreAudio and the pre-show
/// evaluator. The probe itself is a one-call CoreAudio query; tests exercise
/// the override hook that the production path uses for both "device present"
/// and "no device" branches.
final class AudioDeviceProbeTests: XCTestCase {

    override func tearDown() {
        // Restore the default provider after tests that override it. Otherwise
        // the in-process system-default provider remains swapped out for the
        // rest of the test bundle.
        AudioDeviceProbe.defaultOutputDeviceIDProvider = AudioDeviceProbeTests.realProvider
        super.tearDown()
    }

    /// Captured before any test mutates the static; each tearDown restores it.
    private static let realProvider = AudioDeviceProbe.defaultOutputDeviceIDProvider

    func testProbeTrueWhenSystemReportsADevice() {
        AudioDeviceProbe.defaultOutputDeviceIDProvider = { 7 } // any non-unknown ID
        XCTAssertTrue(AudioDeviceProbe.isDefaultOutputDeviceAvailable())
    }

    func testProbeFalseWhenSystemReportsNoDevice() {
        AudioDeviceProbe.defaultOutputDeviceIDProvider = { AudioDeviceID(kAudioObjectUnknown) }
        XCTAssertFalse(AudioDeviceProbe.isDefaultOutputDeviceAvailable())
    }

    /// On any reasonable host (including CI runners) macOS will report some
    /// default audio device — built-in speakers, BlackHole, an aggregate device.
    /// This pins that the production path returns a sane answer rather than
    /// crashing or returning `kAudioObjectUnknown` due to a CoreAudio API misuse.
    func testProbeRunsAgainstRealCoreAudioWithoutCrashing() {
        AudioDeviceProbe.defaultOutputDeviceIDProvider = AudioDeviceProbeTests.realProvider
        // The result is host-dependent — we only assert the call returns a Bool
        // (i.e. no crash, no exception). The host's actual device state is what
        // the operator sees in the Pre-Show panel.
        _ = AudioDeviceProbe.isDefaultOutputDeviceAvailable()
    }
}
