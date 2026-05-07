import Foundation
import CoreGraphics
import UniformTypeIdentifiers

enum MediaKind: String, Codable, CaseIterable, Identifiable {
    case image
    case video

    var id: String { rawValue }
}

enum ScaleMode: String, Codable, CaseIterable, Identifiable {
    case fit
    case fill
    case stretch
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        case .stretch: "Stretch"
        case .custom: "Custom"
        }
    }
}

enum AlignmentPreset: String, Codable, CaseIterable, Identifiable {
    case center
    case top
    case bottom
    case leading
    case trailing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .center: "Center"
        case .top: "Top"
        case .bottom: "Bottom"
        case .leading: "Left"
        case .trailing: "Right"
        }
    }
}

struct MediaReference: Codable, Hashable {
    var originalPath: String
    var bookmarkData: Data?

    init(url: URL) {
        originalPath = url.path
        bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolvedURL() -> URL? {
        if let bookmarkData {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url
            }
        }

        let fallback = URL(fileURLWithPath: originalPath)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }
}

struct SlideSettings: Codable, Hashable {
    var scaleMode: ScaleMode = .fit
    var alignment: AlignmentPreset = .center
    var customScale: Double = 1.0
    var offsetX: Double = 0
    var offsetY: Double = 0
    var loopVideo: Bool = false
    var volume: Double = 1.0
}

struct MediaSlide: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var mediaKind: MediaKind
    var media: MediaReference
    var settings: SlideSettings = SlideSettings()

    init(url: URL, mediaKind: MediaKind) {
        id = UUID()
        title = url.deletingPathExtension().lastPathComponent
        self.mediaKind = mediaKind
        media = MediaReference(url: url)
        settings = SlideSettings()
        if mediaKind == .video {
            settings.loopVideo = true
        }
    }
}

/// How a cue chains into the next cue when GO advances the playhead.
/// Mirrors QLab's three-state continuation flag.
enum CueContinuation: String, Codable, CaseIterable, Identifiable {
    /// Operator must press GO again to advance.
    case hold
    /// Fires the next cue when this cue's pre-wait completes — the two cues overlap.
    case autoContinue
    /// Fires the next cue when this cue ends — the two cues are sequential.
    case autoFollow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hold: "Hold"
        case .autoContinue: "Auto-continue"
        case .autoFollow: "Auto-follow"
        }
    }
}

/// Optional per-cue overrides on top of the underlying asset's settings and the project defaults.
/// `nil` means "inherit from parent (asset settings or project defaults)".
struct CueOverrides: Codable, Hashable {
    var fadeIn: TimeInterval?
    var fadeOut: TimeInterval?
    var crossfadeDuration: TimeInterval?
    var holdLastFrame: Bool?
    var loop: Bool?
    /// Trim points relative to media start, in seconds. `nil` means use full asset.
    var inPoint: TimeInterval?
    var outPoint: TimeInterval?

    static let none = CueOverrides()

    var isEmpty: Bool {
        fadeIn == nil &&
        fadeOut == nil &&
        crossfadeDuration == nil &&
        holdLastFrame == nil &&
        loop == nil &&
        inPoint == nil &&
        outPoint == nil
    }
}

/// A single playable item in a `ShowList`. References an asset by ID and carries cue-runtime
/// metadata (number, title, continuation, pre/post-wait, notes, overrides).
///
/// Cue identifiers are operator-supplied strings (`"INTRO"`, `"Q12"`, `"Steve"`); the `Cue.id`
/// is a stable UUID so cue numbers can change without breaking external references.
/// Uniqueness of `number` is enforced at the `ShowList` level (case-insensitive).
struct Cue: Identifiable, Codable, Hashable {
    var id: UUID = UUID()

    /// Operator-visible cue number/name. Free-form non-empty string. Unique within a `ShowList`,
    /// case-insensitive.
    var number: String

    /// Operator-visible title. Defaults to the asset's title; can be overridden.
    var title: String

    /// References a `MediaSlide.id` in the asset library.
    var assetID: UUID

    var continuation: CueContinuation = .hold

    /// Seconds to wait before this cue actually starts after GO. Drives the auto-continue overlap.
    var preWait: TimeInterval = 0

    /// Seconds to wait after this cue's natural end before auto-follow fires the next cue.
    var postWait: TimeInterval = 0

    /// Operator notes — visible on the standing-by cue, lifted into the Director View.
    var notes: String = ""

    /// Per-cue overrides; nil-valued fields inherit from the asset's `SlideSettings` or project defaults.
    var overrides: CueOverrides = .none

    init(
        id: UUID = UUID(),
        number: String,
        title: String,
        assetID: UUID,
        continuation: CueContinuation = .hold,
        preWait: TimeInterval = 0,
        postWait: TimeInterval = 0,
        notes: String = "",
        overrides: CueOverrides = .none
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.assetID = assetID
        self.continuation = continuation
        self.preWait = preWait
        self.postWait = postWait
        self.notes = notes
        self.overrides = overrides
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case number
        case title
        case assetID
        case continuation
        case preWait
        case postWait
        case notes
        case overrides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        number = try container.decode(String.self, forKey: .number)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        assetID = try container.decode(UUID.self, forKey: .assetID)
        continuation = try container.decodeIfPresent(CueContinuation.self, forKey: .continuation) ?? .hold
        preWait = try container.decodeIfPresent(TimeInterval.self, forKey: .preWait) ?? 0
        postWait = try container.decodeIfPresent(TimeInterval.self, forKey: .postWait) ?? 0
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        overrides = try container.decodeIfPresent(CueOverrides.self, forKey: .overrides) ?? .none
    }
}

struct PlayoutTransitionSettings: Codable, Hashable {
    static let minimumDuration = 0.1
    static let maximumDuration = 30.0

    var crossfadeEnabled = false
    var crossfadeDuration = 0.5

    static func clampedDuration(_ duration: Double) -> Double {
        min(maximumDuration, max(minimumDuration, duration))
    }
}

struct PlayoutProject: Codable, Hashable {
    /// Bumped when the on-disk schema changes. Files without this field are treated as v1 (legacy flat JSON).
    static let currentFormatVersion = 2

    var formatVersion: Int = PlayoutProject.currentFormatVersion
    var slides: [MediaSlide] = []
    var selectedDeviceID: String?
    var selectedModeID: String?
    var outputWidth: Int = 1920
    var outputHeight: Int = 1080
    var transitionSettings = PlayoutTransitionSettings()

    static let empty = PlayoutProject()

    init(
        formatVersion: Int = PlayoutProject.currentFormatVersion,
        slides: [MediaSlide] = [],
        selectedDeviceID: String? = nil,
        selectedModeID: String? = nil,
        outputWidth: Int = 1920,
        outputHeight: Int = 1080,
        transitionSettings: PlayoutTransitionSettings = PlayoutTransitionSettings()
    ) {
        self.formatVersion = formatVersion
        self.slides = slides
        self.selectedDeviceID = selectedDeviceID
        self.selectedModeID = selectedModeID
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.transitionSettings = transitionSettings
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case slides
        case selectedDeviceID
        case selectedModeID
        case outputWidth
        case outputHeight
        case transitionSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        slides = try container.decodeIfPresent([MediaSlide].self, forKey: .slides) ?? []
        selectedDeviceID = try container.decodeIfPresent(String.self, forKey: .selectedDeviceID)
        selectedModeID = try container.decodeIfPresent(String.self, forKey: .selectedModeID)
        outputWidth = try container.decodeIfPresent(Int.self, forKey: .outputWidth) ?? 1920
        outputHeight = try container.decodeIfPresent(Int.self, forKey: .outputHeight) ?? 1080
        transitionSettings = try container.decodeIfPresent(PlayoutTransitionSettings.self, forKey: .transitionSettings)
            ?? PlayoutTransitionSettings()
    }

    /// Bumps `formatVersion` to the current value. Call before save to mark a project as upgraded.
    mutating func markCurrentFormatVersion() {
        formatVersion = PlayoutProject.currentFormatVersion
    }
}

struct ScalingGeometry {
    static func mediaRect(
        sourceSize: CGSize,
        canvasSize: CGSize,
        mode: ScaleMode,
        alignment: AlignmentPreset = .center,
        customScale: Double = 1,
        offset: CGPoint = .zero
    ) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0, canvasSize.width > 0, canvasSize.height > 0 else {
            return CGRect(origin: .zero, size: canvasSize)
        }

        if mode == .stretch {
            return CGRect(origin: .zero, size: canvasSize)
        }

        let fitScale = min(canvasSize.width / sourceSize.width, canvasSize.height / sourceSize.height)
        let fillScale = max(canvasSize.width / sourceSize.width, canvasSize.height / sourceSize.height)
        let scale: CGFloat

        switch mode {
        case .fit:
            scale = fitScale
        case .fill:
            scale = fillScale
        case .stretch:
            scale = fitScale
        case .custom:
            scale = fitScale * max(0.05, CGFloat(customScale))
        }

        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        var origin = CGPoint(
            x: (canvasSize.width - size.width) / 2,
            y: (canvasSize.height - size.height) / 2
        )

        switch alignment {
        case .center:
            break
        case .top:
            origin.y = 0
        case .bottom:
            origin.y = canvasSize.height - size.height
        case .leading:
            origin.x = 0
        case .trailing:
            origin.x = canvasSize.width - size.width
        }

        origin.x += offset.x
        origin.y += offset.y

        return CGRect(origin: origin, size: size)
    }
}

extension UTType {
    static let simplePlaybackProject = UTType(exportedAs: "com.josh.simpleplayback.project", conformingTo: .json)
}
