import AVFoundation
import CoreMedia
import Foundation

/// AVFoundation adapter that extracts the structured inputs `MediaFlagsEvaluator` needs
/// from a video asset on disk, then calls into the pure-logic evaluator.
///
/// All inspection runs synchronously on the import thread — the same pattern
/// `MediaImporter.nativeFrameRate(for:)` already uses. Slow on huge files (a few hundred
/// milliseconds), acceptable because import isn't on the render hot path.
///
/// Best-effort: when AVFoundation doesn't expose a particular property (bit depth,
/// chroma subsampling), this falls back to a conservative "don't flag" result rather than
/// false-positive. Operators can right-click → Transcode anyway if they want.
enum MediaFlagsInspector {

    /// Fractional tolerance for the "declared rate vs min frame duration" check. 0.1% of the
    /// declared rate covers normal floating-point drift between `1/nominalFrameRate` and
    /// `minFrameDuration.seconds`; anything bigger means the shortest gap between frames is
    /// substantially shorter than the average — the signature of a VFR mux.
    private static let vfrFractionalTolerance: Double = 0.001

    /// Returns the flag set for the asset at `url`. Returns `.none` for stills, audio-only
    /// files, missing files, or any inspection failure — never throws. Empty flags is the
    /// "I couldn't inspect this" sentinel; downstream UI just shows nothing.
    static func inspect(url: URL) -> MediaFlags {
        guard let track = loadFirstVideoTrackSync(url: url) else { return .none }
        guard let formatDescription = (track.formatDescriptions as? [CMFormatDescription])?.first else {
            return .none
        }

        let codec = codecFamily(from: formatDescription)
        let hasColorPrimariesTag = colorPrimariesPresent(in: formatDescription)
        let bitsPerComponent = bitsPerComponent(in: formatDescription)
        let chromaSubsampling420 = chromaIsLikely420(codec: codec, formatDescription: formatDescription)
        let frameRateInconsistent = frameRateLooksVariable(track: track)

        return MediaFlagsEvaluator.evaluate(
            codec: codec,
            bitsPerComponent: bitsPerComponent,
            chromaSubsampling420: chromaSubsampling420,
            hasColorPrimariesTag: hasColorPrimariesTag,
            frameRateInconsistent: frameRateInconsistent
        )
    }

    // MARK: - Codec

    private static func codecFamily(from formatDescription: CMFormatDescription) -> CodecFamily {
        let subtype = CMFormatDescriptionGetMediaSubType(formatDescription)
        return CodecFamily.from(fourCC: fourCCString(from: subtype))
    }

    /// Convert an OSType / FourCC to its 4-character string. CoreMedia stores these as
    /// big-endian 32-bit ints; the byte order is the readable one.
    private static func fourCCString(from code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    // MARK: - Color tagging

    private static func colorPrimariesPresent(in formatDescription: CMFormatDescription) -> Bool {
        guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any] else {
            return false
        }
        let key = kCMFormatDescriptionExtension_ColorPrimaries as String
        guard let primaries = extensions[key] else { return false }
        // Apple sometimes sets the key to `kCMFormatDescriptionColorPrimaries_ITU_R_709_2`,
        // sometimes to a string. Either presence counts as "tagged"; absence (or empty
        // string) counts as untagged.
        if let s = primaries as? String { return !s.isEmpty }
        return true
    }

    // MARK: - Bit depth

    /// Best-effort bit depth probe. AVFoundation exposes `BitsPerComponent` for some encoders
    /// (Apple Compressor, Final Cut Pro). For sources that don't tag it, we fall back to
    /// checking the human-readable `FormatName` for "Main 10" / "10-bit" hints.
    /// Returns `nil` when neither check yields a verdict — the evaluator treats `nil` as
    /// 8-bit, so we err on the side of not flagging.
    private static func bitsPerComponent(in formatDescription: CMFormatDescription) -> Int? {
        guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any] else {
            return nil
        }
        let bpcKey = kCMFormatDescriptionExtension_BitsPerComponent as String
        if let bpc = extensions[bpcKey] as? NSNumber {
            return bpc.intValue
        }
        let formatNameKey = kCMFormatDescriptionExtension_FormatName as String
        if let name = extensions[formatNameKey] as? String {
            let lower = name.lowercased()
            if lower.contains("main 10") || lower.contains("10-bit") || lower.contains("10 bit") {
                return 10
            }
        }
        return nil
    }

    /// 4:2:0 detection without decoding a frame: HEVC SDR sources are 4:2:0 by overwhelming
    /// convention (Main / Main 10 profiles). 4:2:2 HEVC is a separate profile that Apple
    /// Compressor labels as "Main 4:2:2 10" in `FormatName`. We treat HEVC as 4:2:0 by
    /// default and downgrade if the format name explicitly says 4:2:2.
    ///
    /// For non-HEVC codecs the chroma question doesn't matter (the evaluator only consults
    /// it for HEVC), so this returns `false` for everything else.
    private static func chromaIsLikely420(codec: CodecFamily, formatDescription: CMFormatDescription) -> Bool {
        guard codec == .hevc else { return false }
        if let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any],
           let name = extensions[kCMFormatDescriptionExtension_FormatName as String] as? String {
            let lower = name.lowercased()
            if lower.contains("4:2:2") || lower.contains("422") || lower.contains("4:4:4") || lower.contains("444") {
                return false
            }
        }
        return true
    }

    // MARK: - VFR

    /// Heuristic: AVFoundation reports `nominalFrameRate == 0` for non-CFR sources, and the
    /// declared rate diverges from `minFrameDuration` for VFR muxes. Either condition flags
    /// the clip as "not constant frame rate." False negatives (genuinely VFR clips that
    /// muxed cleanly enough that AVFoundation reports a steady rate) are a known limitation
    /// of metadata-only inspection — a full timestamp scan is out of scope for v1 import.
    private static func frameRateLooksVariable(track: AVAssetTrack) -> Bool {
        let nominal = Double(track.nominalFrameRate)
        if nominal <= 0 { return true }

        let minDuration = track.minFrameDuration
        guard minDuration.isValid, minDuration.seconds > 0 else { return false }

        let derivedFromMinDuration = 1.0 / minDuration.seconds
        return abs(derivedFromMinDuration - nominal) > nominal * Self.vfrFractionalTolerance
    }

    // MARK: - Async-bridge helper

    /// Same DispatchSemaphore + `@unchecked Sendable` carrier shape as
    /// `MediaImporter.loadFirstVideoTrackSync` (session 21–22 — see Option-J
    /// commits) — bridges the deprecated sync `tracks(withMediaType:)` to the
    /// non-deprecated callback variant `loadTracks(withMediaType:_:)`. Local
    /// to MediaFlagsInspector to keep MediaImporter's helper private; both
    /// helpers are intentionally tiny and could be merged in a future
    /// refactor if a third site needs the same shape.
    private static func loadFirstVideoTrackSync(url: URL) -> AVAssetTrack? {
        let asset = AVURLAsset(url: url)
        let box = TrackLoadBox()
        let semaphore = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .video) { tracks, _ in
            box.tracks = tracks
            semaphore.signal()
        }
        semaphore.wait()
        return box.tracks?.first
    }

    private final class TrackLoadBox: @unchecked Sendable {
        var tracks: [AVAssetTrack]?
    }
}
