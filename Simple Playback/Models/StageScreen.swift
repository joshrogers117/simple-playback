import CoreGraphics
import Foundation

// MARK: - Stage

/// A virtual raster the compositor renders into. Multiple `Screen`s can attach to a single
/// `Stage`, optionally with per-attachment geometry transforms (corner-pin, edge blend).
///
/// Spec ref: research/output_pipeline.md §16 ("Stage ≠ Screen — composition surface and the
/// destination are different objects"). A Stage owns the compositor's frame format and
/// timing; Screens own the transport (DeckLink, NDI, OS display) the frame is delivered on.
struct Stage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var width: Int = 1920
    var height: Int = 1080
    /// Frame rate as numerator / denominator so 23.976 / 29.97 / 59.94 are exact.
    var frameRateNumerator: Int = 60_000
    var frameRateDenominator: Int = 1001  // 59.94 by default
    var colorSpace: ColorSpaceTag = .rec709
    var range: ColorRange = .limited

    var size: CGSize { CGSize(width: width, height: height) }
    var framesPerSecond: Double {
        guard frameRateDenominator > 0 else { return 60 }
        return Double(frameRateNumerator) / Double(frameRateDenominator)
    }

    init(
        id: UUID = UUID(),
        name: String,
        width: Int = 1920,
        height: Int = 1080,
        frameRateNumerator: Int = 60_000,
        frameRateDenominator: Int = 1001,
        colorSpace: ColorSpaceTag = .rec709,
        range: ColorRange = .limited
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.frameRateNumerator = frameRateNumerator
        self.frameRateDenominator = frameRateDenominator
        self.colorSpace = colorSpace
        self.range = range
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, width, height
        case frameRateNumerator, frameRateDenominator
        case colorSpace, range
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Program"
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1920
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1080
        frameRateNumerator = try c.decodeIfPresent(Int.self, forKey: .frameRateNumerator) ?? 60_000
        frameRateDenominator = try c.decodeIfPresent(Int.self, forKey: .frameRateDenominator) ?? 1001
        colorSpace = try c.decodeIfPresent(ColorSpaceTag.self, forKey: .colorSpace) ?? .rec709
        range = try c.decodeIfPresent(ColorRange.self, forKey: .range) ?? .limited
    }
}

/// Tagged color space for a Stage / Screen output. v1 surfaces the operator-relevant values.
enum ColorSpaceTag: String, Codable, CaseIterable, Identifiable {
    case sRGB
    case rec709
    case displayP3
    case rec2020HLG
    case rec2020PQ

    var id: String { rawValue }
    var label: String {
        switch self {
        case .sRGB: "sRGB"
        case .rec709: "Rec.709"
        case .displayP3: "Display P3"
        case .rec2020HLG: "Rec.2020 (HLG)"
        case .rec2020PQ: "Rec.2020 (PQ)"
        }
    }
}

/// Output range — limited (16–235 / 64–940) or full (0–255 / 0–1023).
enum ColorRange: String, Codable, CaseIterable, Identifiable {
    case limited
    case full
    var id: String { rawValue }
    var label: String { self == .limited ? "Limited (16–235)" : "Full (0–255)" }
}

// MARK: - Screen

/// Operator-named output destination. A Screen has a typed role (so the cue list references
/// "Program" / "Confidence" by intent, not by display index), a Stage to render from, and one
/// or more Transport bindings that carry the rendered frames to physical hardware.
///
/// The role + binding split keeps `.spb` show files venue-portable: project content references
/// roles, and per-machine configuration (`OutputBindingProfile`) maps roles to hardware.
struct Screen: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var role: ScreenRole = .program
    var name: String

    /// References the `Stage.id` this Screen renders from.
    var stageID: UUID

    init(
        id: UUID = UUID(),
        role: ScreenRole = .program,
        name: String,
        stageID: UUID
    ) {
        self.id = id
        self.role = role
        self.name = name
        self.stageID = stageID
    }

    private enum CodingKeys: String, CodingKey { case id, role, name, stageID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decodeIfPresent(ScreenRole.self, forKey: .role) ?? .program
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Program"
        stageID = try c.decode(UUID.self, forKey: .stageID)
    }
}

/// Typed Screen role — the show file references screens by role so it survives venue moves.
enum ScreenRole: String, Codable, CaseIterable, Identifiable {
    case program
    case confidence
    case multiviewer
    case mirror
    case auxiliary
    case streamOut

    var id: String { rawValue }
    var label: String {
        switch self {
        case .program: "Program"
        case .confidence: "Confidence"
        case .multiviewer: "Multiviewer"
        case .mirror: "Mirror"
        case .auxiliary: "Auxiliary"
        case .streamOut: "Stream Out"
        }
    }
}

// MARK: - Transport bindings (per-machine)

/// Per-machine binding from a Screen to physical hardware. Lives outside the project file
/// (in `OutputBindingProfile`) so the same `.spb` opens cleanly in different venues.
struct ScreenBinding: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var screenID: UUID
    var transport: TransportBinding

    /// Optional 4-corner warp. Identity = no warp.
    var cornerPin: CornerPin = .identity

    /// Optional soft-edge blend. nil = no blend.
    var edgeBlend: EdgeBlend?

    /// Optional reference to another Screen this Screen mirrors. Mirrored screens use the
    /// source Screen's stage; their own stageID is ignored.
    var mirrorsScreenID: UUID?

    /// Mark this binding as "in use" so the operator can spot a Screen that is currently
    /// rendering (helps debug why two outputs both think they own a port).
    var enabled: Bool = true

    init(
        id: UUID = UUID(),
        screenID: UUID,
        transport: TransportBinding,
        cornerPin: CornerPin = .identity,
        edgeBlend: EdgeBlend? = nil,
        mirrorsScreenID: UUID? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.screenID = screenID
        self.transport = transport
        self.cornerPin = cornerPin
        self.edgeBlend = edgeBlend
        self.mirrorsScreenID = mirrorsScreenID
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, screenID, transport, cornerPin, edgeBlend, mirrorsScreenID, enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        screenID = try c.decode(UUID.self, forKey: .screenID)
        transport = try c.decode(TransportBinding.self, forKey: .transport)
        cornerPin = try c.decodeIfPresent(CornerPin.self, forKey: .cornerPin) ?? .identity
        edgeBlend = try c.decodeIfPresent(EdgeBlend.self, forKey: .edgeBlend)
        mirrorsScreenID = try c.decodeIfPresent(UUID.self, forKey: .mirrorsScreenID)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// The actual hardware/software binding for a Screen.
enum TransportBinding: Codable, Hashable {
    case deckLink(deviceID: String, modeID: String, fillKey: Bool, audioEmbed: Bool, tenBit: Bool)
    case osDisplay(displayID: String)
    case ndi(senderName: String)
    case syphon(serverName: String)
    case operatorWindow                  // The operator-Mac multiviewer window in the app
    case fileRecord(url: URL)            // Reserved for v2 file-record sink

    /// Stable string for logs / OSC.
    var label: String {
        switch self {
        case .deckLink(let dev, let mode, let fillKey, let audio, let tenBit):
            let flags = [fillKey ? "fill+key" : "fill", audio ? "audio" : nil, tenBit ? "10-bit" : "8-bit"]
                .compactMap { $0 }.joined(separator: " ")
            return "DeckLink \(dev) (\(mode)) [\(flags)]"
        case .osDisplay(let id): return "Display \(id)"
        case .ndi(let name): return "NDI \(name)"
        case .syphon(let name): return "Syphon \(name)"
        case .operatorWindow: return "Operator window"
        case .fileRecord(let url): return "File \(url.lastPathComponent)"
        }
    }
}

/// 4-corner perspective warp expressed in normalized canvas coordinates (0...1).
struct CornerPin: Codable, Hashable {
    var topLeft: NormalizedPoint
    var topRight: NormalizedPoint
    var bottomLeft: NormalizedPoint
    var bottomRight: NormalizedPoint

    static let identity = CornerPin(
        topLeft: NormalizedPoint(x: 0, y: 0),
        topRight: NormalizedPoint(x: 1, y: 0),
        bottomLeft: NormalizedPoint(x: 0, y: 1),
        bottomRight: NormalizedPoint(x: 1, y: 1)
    )

    var isIdentity: Bool { self == .identity }
}

struct NormalizedPoint: Codable, Hashable {
    var x: Double
    var y: Double
}

/// Soft-edge blend along one or more edges. Width is in normalized 0..1 fraction of canvas.
struct EdgeBlend: Codable, Hashable {
    var leftWidth: Double = 0
    var rightWidth: Double = 0
    var topWidth: Double = 0
    var bottomWidth: Double = 0
    var gamma: Double = 2.2
    var power: Double = 1.0
}

// MARK: - Output binding profile (per-machine, persisted in UserDefaults)

/// A named set of `ScreenBinding`s for a particular machine. The active profile is stored
/// per-bundle-identifier in `UserDefaults`; the project file references screens by role.
///
/// Operators can save and recall multiple profiles for different venues (corporate
/// keynote rig vs. broadcast studio vs. rehearsal room).
struct OutputBindingProfile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = "Default"
    var bindings: [ScreenBinding] = []

    /// Resolves the binding for a given Screen (by ID), falling back to nil if unbound.
    func binding(forScreenID id: UUID) -> ScreenBinding? {
        bindings.first(where: { $0.screenID == id && $0.enabled })
    }
}
