import AVFoundation
import CoreMedia
import Foundation

/// Snapshot of a video track's metadata captured in one async hop. Bundles
/// the three properties the import pipeline reads (nominal frame rate,
/// minimum frame duration, format descriptions) so callers don't need to
/// hit the deprecated sync property accessors. The `track` itself is
/// included for the rare consumer that needs the full `AVAssetTrack`
/// (e.g. AVAssetReaderTrackOutput); new property reads should prefer
/// adding fields to this struct over reaching back through `track`.
struct AVTrackInspection {
    let track: AVAssetTrack
    let nominalFrameRate: Float
    let minFrameDuration: CMTime
    let formatDescriptions: [CMFormatDescription]
}

/// Async → sync bridge for `AVAssetTrack` loading. Consolidates the per-site
/// helpers that MediaImporter and MediaFlagsInspector each carried (sessions
/// 22) and extends them off the deprecated track *property* accessors
/// (`nominalFrameRate`, `minFrameDuration`, `formatDescriptions`) onto the
/// async `track.load(_:)` API.
///
/// Sync entry points are deliberate: every caller runs at import time, off
/// the render hot path, in a context where bridging async-to-sync via
/// DispatchSemaphore is the simplest shape that matches the rest of the
/// pipeline. The `@unchecked Sendable` carriers are safe because the
/// semaphore enforces happens-before across the AVF completion / Task
/// boundary.
///
/// **Async-API migration is paired with C12 audio engine refactor**, not a
/// v1 sub-task. Three call sites would need simultaneous migration —
/// MediaImporter (import-time, easy), MediaFlagsInspector (also import-time),
/// and AudioPump (whose `loadFirstAudioTrack(url:)` consumer sits on the
/// AVAssetReader prep path). AudioPump is the constraint: an async entry
/// point pulls a `Task { … }` boundary into the audio prep, which the v2
/// 48 kHz / 32-bit float / 8-channel routing-matrix work is going to
/// reshape anyway. Migrating now would mean rewriting the prep path twice;
/// migrating at the C12 boundary lets the new audio path land async-native.
/// Until then, the cooperative-pool footgun (sync entry blocking on a
/// detached Task) is mitigated by the import-time-only call discipline:
/// no caller runs from a hot render or audio queue.
enum AVTrackLoader {

    /// Load the first video track at `url` plus its frame-rate and
    /// format-description metadata. Returns `nil` when the asset has no
    /// video track or any property load fails. Synchronous; the caller
    /// blocks for typically a few ms while AVFoundation parses the
    /// container header.
    static func loadFirstVideoTrackInspection(url: URL) -> AVTrackInspection? {
        let asset = AVURLAsset(url: url)
        let box = InspectionBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            defer { semaphore.signal() }
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { return }
                async let nominal = track.load(.nominalFrameRate)
                async let minDuration = track.load(.minFrameDuration)
                async let formats = track.load(.formatDescriptions)
                let inspection = try await AVTrackInspection(
                    track: track,
                    nominalFrameRate: nominal,
                    minFrameDuration: minDuration,
                    formatDescriptions: formats
                )
                box.inspection = inspection
            } catch {
                // Leaves box.inspection nil — caller treats nil as "no video".
            }
        }
        semaphore.wait()
        return box.inspection
    }

    /// Load the first audio track at `url` along with the asset that owns
    /// it. AVAssetReader requires the parent asset (per Apple docs: "The
    /// track that you specify must be one of the tracks of the asset
    /// associated with this reader"); we return both because
    /// `AVAssetTrack.asset` is weak and the asset must outlive the
    /// reader's setup. Mirror of the video helper for AudioPump — the
    /// property reads aren't audio-relevant, so this stays at the
    /// bare-track shape rather than carrying an inspection bundle.
    static func loadFirstAudioTrack(url: URL) -> (asset: AVURLAsset, track: AVAssetTrack)? {
        let asset = AVURLAsset(url: url)
        let box = TrackBox()
        let semaphore = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .audio) { tracks, _ in
            box.tracks = tracks
            semaphore.signal()
        }
        semaphore.wait()
        guard let track = box.tracks?.first else { return nil }
        return (asset, track)
    }

    private final class InspectionBox: @unchecked Sendable {
        var inspection: AVTrackInspection?
    }

    private final class TrackBox: @unchecked Sendable {
        var tracks: [AVAssetTrack]?
    }
}
