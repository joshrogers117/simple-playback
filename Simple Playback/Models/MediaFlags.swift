import Foundation

/// Codec family inferred from the format description's media subtype FourCC.
///
/// Long-GOP scrubbing warnings only apply to inter-frame codecs (`h264`, `hevc`); intra-only
/// codecs (ProRes, DNxHD/HR, MJPEG, Animation, Uncompressed) decode every frame independently
/// and do not warrant the warning.
///
/// Spec ref: feature_spec.md §3.10 ("Long-GOP H.264/HEVC: 'may not scrub frame-accurately'").
enum CodecFamily: String, Codable, Hashable {
    case proRes
    case h264
    case hevc
    case dnx
    case animation
    case mjpeg
    case uncompressed
    case other
    case unknown

    /// True for codecs that use inter-frame prediction; scrubbing through these decodes
    /// from the nearest keyframe rather than directly to the requested frame.
    var isLongGOPCapable: Bool {
        switch self {
        case .h264, .hevc: return true
        case .proRes, .dnx, .animation, .mjpeg, .uncompressed, .other, .unknown: return false
        }
    }

    /// Map a CoreMedia FourCC (e.g. `'avc1'`, `'hvc1'`, `'apch'`) to a `CodecFamily`.
    /// Returns `.unknown` for codes we haven't characterized — conservative; we'd rather miss
    /// a long-GOP flag than false-positive on an intra codec we don't recognize.
    static func from(fourCC: String) -> CodecFamily {
        switch fourCC {
        case "avc1", "avc3": return .h264
        case "hvc1", "hev1", "dvh1", "dvhe": return .hevc
        case "apco", "apcs", "apcn", "apch", "ap4h", "ap4x": return .proRes
        case "AVdn", "AVdh": return .dnx
        case "rle ", "rle": return .animation
        case "jpeg", "mjpa", "mjpb": return .mjpeg
        case "2vuy", "v210", "v408", "v308", "BGRA", "yuvs": return .uncompressed
        default: return .other
        }
    }
}

/// Per-clip risk flags surfaced to the operator. Populated at import-time by
/// `MediaFlagsInspector` and persisted on `MediaSlide.flags`. The compositor and runtime do
/// not consult these flags — they exist purely to drive the inspector's "Transcoding posture:
/// never silent" warnings (spec §3.10).
///
/// Each flag is a hint, not a hard error. Operators can ship the show as-is or right-click
/// the asset → Transcode to ProRes 422 (C2) to render a clean copy.
struct MediaFlags: Codable, Hashable {
    /// True for inter-frame codecs (H.264, HEVC). These don't scrub frame-accurately —
    /// AVFoundation seeks to the nearest keyframe, then decodes forward.
    var longGOP: Bool

    /// True when the source declares a variable frame rate (frame durations are not constant).
    /// Loops across a VFR clip don't seam cleanly because the loop boundary may land mid-GOP
    /// or mid-frame-duration.
    var variableFrameRate: Bool

    /// True for 10-bit 4:2:0 sources (HEVC Main 10 in 4:2:0). Apple Silicon decodes these in
    /// hardware; older Intel Macs may fall back to software decode and stall on busy timelines.
    var tenBitYUV420: Bool

    /// True when the source has no embedded color tag (no NCLC / no ICC profile). The
    /// compositor treats untagged sources as sRGB; this flag tells the operator that's a
    /// guess, not a declaration.
    var untaggedColor: Bool

    static let none = MediaFlags(
        longGOP: false,
        variableFrameRate: false,
        tenBitYUV420: false,
        untaggedColor: false
    )

    /// Whether any flag is set. Used by inspector views to decide whether to render the
    /// "warnings" section at all.
    var hasAnyFlag: Bool {
        longGOP || variableFrameRate || tenBitYUV420 || untaggedColor
    }

    private enum CodingKeys: String, CodingKey {
        case longGOP, variableFrameRate, tenBitYUV420, untaggedColor
    }

    init(
        longGOP: Bool = false,
        variableFrameRate: Bool = false,
        tenBitYUV420: Bool = false,
        untaggedColor: Bool = false
    ) {
        self.longGOP = longGOP
        self.variableFrameRate = variableFrameRate
        self.tenBitYUV420 = tenBitYUV420
        self.untaggedColor = untaggedColor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        longGOP = try c.decodeIfPresent(Bool.self, forKey: .longGOP) ?? false
        variableFrameRate = try c.decodeIfPresent(Bool.self, forKey: .variableFrameRate) ?? false
        tenBitYUV420 = try c.decodeIfPresent(Bool.self, forKey: .tenBitYUV420) ?? false
        untaggedColor = try c.decodeIfPresent(Bool.self, forKey: .untaggedColor) ?? false
    }
}

/// Pure-logic evaluator: maps the structured properties read off an asset into a
/// `MediaFlags` value. AVFoundation is intentionally not imported here — the AVAsset adapter
/// in `MediaFlagsInspector` extracts these inputs and calls in. That split keeps every flag
/// rule unit-testable without committing fixture media.
enum MediaFlagsEvaluator {

    /// 4:2:0 chroma subsampling for HEVC Main 10. The pixel-format FourCC is read off the
    /// format description's `kCMFormatDescriptionExtension_FormatName` / pixel-format extensions.
    /// Documented here as a fixed list (vs. probing every CV pixel format) because we only
    /// care about the 4:2:0/10-bit intersection.
    static let tenBit420PixelFormatCodes: Set<String> = [
        "x420", // kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        "xf20", // kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    ]

    /// Compute the flag set from already-extracted asset metadata.
    ///
    /// - Parameters:
    ///   - codec: family inferred from the format description FourCC.
    ///   - bitsPerComponent: per-component bit depth (8 or 10 typical). Pass `nil` if
    ///     the asset doesn't expose it (ProRes, uncompressed) — we never flag those as
    ///     10-bit 4:2:0 because it's a codec-shape that doesn't apply.
    ///   - chromaSubsampling420: true if the source is 4:2:0 (HEVC's typical mode for SDR).
    ///   - hasColorPrimariesTag: true if the format description has a populated
    ///     `kCMFormatDescriptionExtension_ColorPrimaries` extension; false for untagged.
    ///   - frameRateInconsistent: true if AVFoundation reports `nominalFrameRate <= 0` or the
    ///     declared rate disagrees with `minFrameDuration` beyond tolerance — both indicate
    ///     the source is not constant-frame-rate.
    static func evaluate(
        codec: CodecFamily,
        bitsPerComponent: Int?,
        chromaSubsampling420: Bool,
        hasColorPrimariesTag: Bool,
        frameRateInconsistent: Bool
    ) -> MediaFlags {
        let isLongGOP = codec.isLongGOPCapable
        let isTenBit420 = codec == .hevc
            && chromaSubsampling420
            && (bitsPerComponent ?? 8) >= 10
        return MediaFlags(
            longGOP: isLongGOP,
            variableFrameRate: frameRateInconsistent,
            tenBitYUV420: isTenBit420,
            untaggedColor: !hasColorPrimariesTag
        )
    }

    /// Operator-facing one-line warning strings. Stable copy — UI tests can exact-match.
    /// Spec §3.10 wording is preserved verbatim where the spec was prescriptive.
    static func warning(for kind: WarningKind) -> String {
        switch kind {
        case .longGOP: return "Long-GOP — may not scrub frame-accurately."
        case .variableFrameRate: return "Variable frame rate — will not loop seamlessly."
        case .tenBitYUV420: return "10-bit 4:2:0 HEVC — limited hardware decode."
        case .untaggedColor: return "Untagged color — treating as sRGB."
        }
    }

    enum WarningKind: Hashable {
        case longGOP
        case variableFrameRate
        case tenBitYUV420
        case untaggedColor
    }
}

extension MediaFlags {
    /// The set of warning kinds that should be surfaced for this flag set. Empty when no
    /// flags are set. Order is stable: long-GOP, VFR, 10-bit 4:2:0, untagged color — most
    /// to least likely to require operator action.
    var activeWarnings: [MediaFlagsEvaluator.WarningKind] {
        var out: [MediaFlagsEvaluator.WarningKind] = []
        if longGOP { out.append(.longGOP) }
        if variableFrameRate { out.append(.variableFrameRate) }
        if tenBitYUV420 { out.append(.tenBitYUV420) }
        if untaggedColor { out.append(.untaggedColor) }
        return out
    }
}
