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
    static let maximumBlurRadius = 100.0
    static let blurSliderMaximum = 15.0

    var scaleMode: ScaleMode = .fit
    var alignment: AlignmentPreset = .center
    var customScale: Double = 1.0
    var offsetX: Double = 0
    var offsetY: Double = 0
    var loopVideo: Bool = false
    var volume: Double = 1.0
    var blurRadius: Double = 0
    var hueShift: Double = 0       // degrees, -180...180
    var saturation: Double = 100   // percent, 0 = grayscale, 100 = unchanged

    init() {}

    private enum CodingKeys: String, CodingKey {
        case scaleMode
        case alignment
        case customScale
        case offsetX
        case offsetY
        case loopVideo
        case volume
        case blurRadius
        case hueShift
        case saturation
    }

    // Decodes missing keys to their defaults so projects saved by older
    // versions (which predate fields like blurRadius) still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scaleMode = try container.decodeIfPresent(ScaleMode.self, forKey: .scaleMode) ?? .fit
        alignment = try container.decodeIfPresent(AlignmentPreset.self, forKey: .alignment) ?? .center
        customScale = try container.decodeIfPresent(Double.self, forKey: .customScale) ?? 1.0
        offsetX = try container.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try container.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
        loopVideo = try container.decodeIfPresent(Bool.self, forKey: .loopVideo) ?? false
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
        blurRadius = try container.decodeIfPresent(Double.self, forKey: .blurRadius) ?? 0
        hueShift = try container.decodeIfPresent(Double.self, forKey: .hueShift) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 100
    }
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
    var slides: [MediaSlide] = []
    var selectedDeviceID: String?
    var selectedModeID: String?
    var outputWidth: Int = 1920
    var outputHeight: Int = 1080
    var transitionSettings = PlayoutTransitionSettings()

    static let empty = PlayoutProject()

    init(
        slides: [MediaSlide] = [],
        selectedDeviceID: String? = nil,
        selectedModeID: String? = nil,
        outputWidth: Int = 1920,
        outputHeight: Int = 1080,
        transitionSettings: PlayoutTransitionSettings = PlayoutTransitionSettings()
    ) {
        self.slides = slides
        self.selectedDeviceID = selectedDeviceID
        self.selectedModeID = selectedModeID
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.transitionSettings = transitionSettings
    }

    private enum CodingKeys: String, CodingKey {
        case slides
        case selectedDeviceID
        case selectedModeID
        case outputWidth
        case outputHeight
        case transitionSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slides = try container.decodeIfPresent([MediaSlide].self, forKey: .slides) ?? []
        selectedDeviceID = try container.decodeIfPresent(String.self, forKey: .selectedDeviceID)
        selectedModeID = try container.decodeIfPresent(String.self, forKey: .selectedModeID)
        outputWidth = try container.decodeIfPresent(Int.self, forKey: .outputWidth) ?? 1920
        outputHeight = try container.decodeIfPresent(Int.self, forKey: .outputHeight) ?? 1080
        transitionSettings = try container.decodeIfPresent(PlayoutTransitionSettings.self, forKey: .transitionSettings)
            ?? PlayoutTransitionSettings()
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
