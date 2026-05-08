import CoreGraphics
import Foundation

/// Three-layer compositor state that survives takes (spec §3.6, §6 anti-pattern
/// "no eight-layer compositor"). The compositor renders, in this order:
///
///   1. Media layer (the active cue) — produced by `FrameRenderer`.
///   2. Bug / logo layer — persistent corner graphic.
///   3. Message / timer layer — countdown timer or name-super.
///
/// `CompositorOverlays` carries the bug + message state. The media layer is the input to the
/// `CompositorPipeline`; this struct only describes overlays. Both overlays default to disabled
/// so a fresh project has zero behavior change vs pre-B12.
struct CompositorOverlays: Codable, Hashable {
    var bug: BugOverlay = BugOverlay()
    var message: MessageOverlay = MessageOverlay()

    static let empty = CompositorOverlays()

    /// `true` when neither overlay would affect the output. Lets the pipeline short-circuit
    /// the compose step entirely — no allocations, base frame returned unchanged.
    var isInert: Bool { !bug.isVisible && !message.isVisible }

    private enum CodingKeys: String, CodingKey { case bug, message }

    init(bug: BugOverlay = BugOverlay(), message: MessageOverlay = MessageOverlay()) {
        self.bug = bug
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bug = try c.decodeIfPresent(BugOverlay.self, forKey: .bug) ?? BugOverlay()
        message = try c.decodeIfPresent(MessageOverlay.self, forKey: .message) ?? MessageOverlay()
    }
}

/// Persistent corner graphic. Image is referenced via `MediaReference` so the show file stays
/// venue-portable (security-scoped bookmark + path fallback). `media == nil` while `enabled`
/// is a "configured but no asset yet" state and renders nothing.
struct BugOverlay: Codable, Hashable {
    var enabled: Bool = false
    var media: MediaReference?
    var corner: BugCorner = .topRight
    /// Margin from the chosen corner, normalized to canvas width/height. Clamped to 0…0.5
    /// at composite time so a runaway value can't push the bug entirely off-screen.
    var marginPercent: Double = 0.03
    /// Bug height as a fraction of canvas height. Width preserves the bug's aspect ratio.
    var sizePercent: Double = 0.10
    /// Master alpha multiplier. 0…1.
    var opacity: Double = 1.0

    var isVisible: Bool { enabled && media != nil && opacity > 0 && sizePercent > 0 }

    private enum CodingKeys: String, CodingKey {
        case enabled, media, corner, marginPercent, sizePercent, opacity
    }

    init(
        enabled: Bool = false,
        media: MediaReference? = nil,
        corner: BugCorner = .topRight,
        marginPercent: Double = 0.03,
        sizePercent: Double = 0.10,
        opacity: Double = 1.0
    ) {
        self.enabled = enabled
        self.media = media
        self.corner = corner
        self.marginPercent = marginPercent
        self.sizePercent = sizePercent
        self.opacity = opacity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        media = try c.decodeIfPresent(MediaReference.self, forKey: .media)
        corner = try c.decodeIfPresent(BugCorner.self, forKey: .corner) ?? .topRight
        marginPercent = try c.decodeIfPresent(Double.self, forKey: .marginPercent) ?? 0.03
        sizePercent = try c.decodeIfPresent(Double.self, forKey: .sizePercent) ?? 0.10
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
    }
}

enum BugCorner: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }
}

/// Persistent text overlay — countdown timer, name super, or static message.
///
/// When `countdownTo` is set, the literal substring `{time_left}` in `text` is replaced with
/// the live remaining time formatted as `M:SS` (or `H:MM:SS` past one hour). An empty `text`
/// with a non-nil `countdownTo` renders just the countdown.
struct MessageOverlay: Codable, Hashable {
    var enabled: Bool = false
    var text: String = ""
    var position: MessagePosition = .lowerThird
    /// Font size as a fraction of canvas height. Clamped to 0.005…0.5 at composite time.
    var fontSizePercent: Double = 0.06
    var textColor: RGBAColor = .white
    /// Optional background pad behind the text. `nil` ⇒ no background.
    var backgroundColor: RGBAColor? = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.5)
    var opacity: Double = 1.0
    var countdownTo: Date?

    var isVisible: Bool {
        guard enabled, opacity > 0 else { return false }
        return countdownTo != nil || !text.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, text, position, fontSizePercent, textColor, backgroundColor, opacity, countdownTo
    }

    init(
        enabled: Bool = false,
        text: String = "",
        position: MessagePosition = .lowerThird,
        fontSizePercent: Double = 0.06,
        textColor: RGBAColor = .white,
        backgroundColor: RGBAColor? = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.5),
        opacity: Double = 1.0,
        countdownTo: Date? = nil
    ) {
        self.enabled = enabled
        self.text = text
        self.position = position
        self.fontSizePercent = fontSizePercent
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.opacity = opacity
        self.countdownTo = countdownTo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        position = try c.decodeIfPresent(MessagePosition.self, forKey: .position) ?? .lowerThird
        fontSizePercent = try c.decodeIfPresent(Double.self, forKey: .fontSizePercent) ?? 0.06
        textColor = try c.decodeIfPresent(RGBAColor.self, forKey: .textColor) ?? .white
        backgroundColor = try c.decodeIfPresent(RGBAColor.self, forKey: .backgroundColor)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        countdownTo = try c.decodeIfPresent(Date.self, forKey: .countdownTo)
    }
}

enum MessagePosition: String, Codable, CaseIterable, Identifiable {
    case top, lowerThird, center
    var id: String { rawValue }
    var label: String {
        switch self {
        case .top: "Top"
        case .lowerThird: "Lower Third"
        case .center: "Center"
        }
    }
}

/// Plain RGBA in 0…1 components. Codable for project persistence, with a `cgColor` accessor
/// for the compositor.
struct RGBAColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1.0

    static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)

    var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }
}
