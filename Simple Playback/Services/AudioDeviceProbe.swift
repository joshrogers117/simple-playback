import CoreAudio
import Foundation

/// Thin CoreAudio wrapper for the pre-show audio-device check. Asks the system
/// for the default output device — if there is one, the show has a place for
/// embedded audio cues to land. The probe is fast (a single
/// `AudioObjectGetPropertyData` call); safe to call from the main thread when
/// the operator opens the Pre-Show sheet.
///
/// `defaultOutputDeviceIDProvider` is an injectable hook so tests can pin both
/// "device present" and "no device" without manipulating the host's audio
/// configuration. Production reads `kAudioHardwarePropertyDefaultOutputDevice`
/// on the system object; failure paths (CoreAudio error or unknown device)
/// collapse to `kAudioObjectUnknown` so the caller always has a deterministic
/// answer.
enum AudioDeviceProbe {

    /// Test seam. Default reads the system-wide default output device.
    static var defaultOutputDeviceIDProvider: () -> AudioDeviceID = systemDefaultOutputDeviceID

    /// `true` when CoreAudio reports a default output device. macOS reports a
    /// default output device whenever any audio hardware is available — built-in
    /// speakers count, so a stock laptop returns `true`. The check fails only
    /// when no audio device is connected at all (e.g. a headless Mac mini with
    /// nothing wired to the audio jack and no aggregate device configured).
    static func isDefaultOutputDeviceAvailable() -> Bool {
        defaultOutputDeviceIDProvider() != kAudioObjectUnknown
    }

    private static func systemDefaultOutputDeviceID() -> AudioDeviceID {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else { return kAudioObjectUnknown }
        return deviceID
    }
}
