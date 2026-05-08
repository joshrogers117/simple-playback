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

    /// Native frame rate of the underlying media (FPS). Populated at import for video assets;
    /// `nil` for stills, audio-only files, or video imported before the field existed (legacy
    /// projects). Used by `FrameRateConformance` to flag clip-vs-Stage mismatches.
    var nativeFrameRate: Double?

    /// Codec-inspector flags populated at import (long-GOP / VFR / 10-bit 4:2:0 / untagged
    /// color). Empty (`MediaFlags.none`) for stills, audio-only sources, files imported before
    /// the field existed (legacy projects), or any inspection failure. Spec §3.10.
    var flags: MediaFlags

    init(url: URL, mediaKind: MediaKind, nativeFrameRate: Double? = nil, flags: MediaFlags = .none) {
        id = UUID()
        title = url.deletingPathExtension().lastPathComponent
        self.mediaKind = mediaKind
        media = MediaReference(url: url)
        settings = SlideSettings()
        self.nativeFrameRate = nativeFrameRate
        self.flags = flags
        if mediaKind == .video {
            settings.loopVideo = true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, mediaKind, media, settings, nativeFrameRate, flags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        mediaKind = try c.decode(MediaKind.self, forKey: .mediaKind)
        media = try c.decode(MediaReference.self, forKey: .media)
        settings = try c.decodeIfPresent(SlideSettings.self, forKey: .settings) ?? SlideSettings()
        nativeFrameRate = try c.decodeIfPresent(Double.self, forKey: .nativeFrameRate)
        flags = try c.decodeIfPresent(MediaFlags.self, forKey: .flags) ?? .none
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

/// Reasons an attempt to add or rename a cue can fail.
enum ShowListValidationError: Error, Equatable {
    case emptyCueNumber
    case duplicateCueNumber(String)
    case unknownCueID(UUID)
    case unknownAssetID(UUID)
}

/// An ordered list of `Cue`s with a playhead. Multiple `ShowList`s can coexist in a project
/// (e.g. main show vs. preshow vs. backups). Cue numbers are unique within a list,
/// case-insensitively.
struct ShowList: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = "Show"
    var cues: [Cue] = []

    /// UUID of the cue currently armed (the next to fire on GO). `nil` ⇔ playhead at end.
    var playheadCueID: UUID?

    init(
        id: UUID = UUID(),
        name: String = "Show",
        cues: [Cue] = [],
        playheadCueID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.cues = cues
        self.playheadCueID = playheadCueID ?? cues.first?.id
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case cues
        case playheadCueID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Show"
        cues = try container.decodeIfPresent([Cue].self, forKey: .cues) ?? []
        playheadCueID = try container.decodeIfPresent(UUID.self, forKey: .playheadCueID)
    }

    // MARK: Lookups

    func cue(id cueID: UUID) -> Cue? {
        cues.first(where: { $0.id == cueID })
    }

    func cueIndex(id cueID: UUID) -> Int? {
        cues.firstIndex(where: { $0.id == cueID })
    }

    /// Looks up a cue by its operator-visible number, case-insensitively.
    /// `"INTRO"` and `"intro"` resolve to the same cue.
    func cue(number: String) -> Cue? {
        let normalized = number.lowercased()
        return cues.first(where: { $0.number.lowercased() == normalized })
    }

    func cueIndex(number: String) -> Int? {
        let normalized = number.lowercased()
        return cues.firstIndex(where: { $0.number.lowercased() == normalized })
    }

    /// The cue currently armed at the playhead, or `nil` if the playhead is past the end.
    var playheadCue: Cue? {
        guard let playheadCueID else { return nil }
        return cue(id: playheadCueID)
    }

    var playheadIndex: Int? {
        guard let playheadCueID else { return nil }
        return cueIndex(id: playheadCueID)
    }

    /// Cue immediately after the playhead, or `nil` if playhead is at end.
    var nextCueAfterPlayhead: Cue? {
        guard let idx = playheadIndex else { return nil }
        let nextIdx = idx + 1
        return cues.indices.contains(nextIdx) ? cues[nextIdx] : nil
    }

    // MARK: Validation

    /// All current uniqueness/well-formedness violations. Empty array == valid.
    func validate() -> [ShowListValidationError] {
        var errors: [ShowListValidationError] = []
        var seen: [String: Int] = [:]
        for cue in cues {
            if cue.number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.emptyCueNumber)
                continue
            }
            let normalized = cue.number.lowercased()
            if let prior = seen[normalized] {
                _ = prior
                errors.append(.duplicateCueNumber(cue.number))
            } else {
                seen[normalized] = 1
            }
        }
        return errors
    }

    var isValid: Bool { validate().isEmpty }

    // MARK: Mutation helpers

    /// Inserts a cue at `index`, validating uniqueness first. Throws on collision or empty number.
    mutating func insert(_ cue: Cue, at index: Int) throws {
        let trimmed = cue.number.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ShowListValidationError.emptyCueNumber
        }
        if cueIndex(number: cue.number) != nil {
            throw ShowListValidationError.duplicateCueNumber(cue.number)
        }
        let bounded = max(0, min(index, cues.count))
        cues.insert(cue, at: bounded)
        if playheadCueID == nil {
            playheadCueID = cues.first?.id
        }
    }

    /// Appends a cue, validating uniqueness first.
    mutating func append(_ cue: Cue) throws {
        try insert(cue, at: cues.count)
    }

    /// Removes the cue at `index`, advancing the playhead if it sat on the removed cue.
    mutating func remove(at index: Int) {
        guard cues.indices.contains(index) else { return }
        let removed = cues.remove(at: index)
        if playheadCueID == removed.id {
            // Move playhead to the cue that took the removed slot, or the previous cue,
            // or nil if the list is empty.
            if cues.indices.contains(index) {
                playheadCueID = cues[index].id
            } else if !cues.isEmpty {
                playheadCueID = cues.last?.id
            } else {
                playheadCueID = nil
            }
        }
    }

    /// Moves the playhead to a specific cue. No-op if `cueID` is unknown.
    mutating func movePlayhead(to cueID: UUID) {
        guard cueIndex(id: cueID) != nil else { return }
        playheadCueID = cueID
    }

    /// Moves the playhead one cue forward. No-op if at end.
    mutating func advancePlayhead() {
        guard let idx = playheadIndex else { return }
        let nextIdx = idx + 1
        playheadCueID = cues.indices.contains(nextIdx) ? cues[nextIdx].id : nil
    }

    /// Moves the playhead one cue back. No-op if at the start.
    mutating func retreatPlayhead() {
        if let idx = playheadIndex {
            let prevIdx = idx - 1
            if cues.indices.contains(prevIdx) {
                playheadCueID = cues[prevIdx].id
            }
        } else if let last = cues.last {
            // Playhead past the end → step back to the last cue.
            playheadCueID = last.id
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
    /// Bumped when the on-disk schema changes. Files without this field are treated as v1 (legacy flat JSON).
    static let currentFormatVersion = 2

    var formatVersion: Int = PlayoutProject.currentFormatVersion

    /// Asset library — imported media, the palette source. Order is operator-significant.
    var slides: [MediaSlide] = []

    /// Ordered show lists. Each list is an independent cue sequence. v2 projects always have at
    /// least one list (created on demand when a project is fresh or migrated from v1).
    var showLists: [ShowList] = []

    /// ID of the show list currently displayed/edited in the UI. Resolves to the first list
    /// when nil or unknown.
    var activeShowListID: UUID?

    /// Composition surfaces — each Stage is a virtual raster the compositor renders into.
    /// Most projects have one Stage ("Program"); multi-screen shows add Confidence/Stage/etc.
    var stages: [Stage] = []

    /// Operator-named output destinations, role-typed. Cues reference screens by role; the
    /// physical binding (DeckLink port, OS display, NDI sender) lives in `OutputBindingProfile`
    /// per-machine — keeping the show file venue-portable.
    var screens: [Screen] = []

    var selectedDeviceID: String?
    var selectedModeID: String?
    var outputWidth: Int = 1920
    var outputHeight: Int = 1080
    var transitionSettings = PlayoutTransitionSettings()

    /// Operator declares this show requires an external reference (genlock). When true and the
    /// active DeckLink output reports `unlocked` (free-run), the status bar escalates from the
    /// informational orange chip to a red "REF EXPECTED" banner. Spec §3.7.
    var expectsExternalReference: Bool = false

    static let empty = PlayoutProject()

    init(
        formatVersion: Int = PlayoutProject.currentFormatVersion,
        slides: [MediaSlide] = [],
        showLists: [ShowList] = [],
        activeShowListID: UUID? = nil,
        stages: [Stage] = [],
        screens: [Screen] = [],
        selectedDeviceID: String? = nil,
        selectedModeID: String? = nil,
        outputWidth: Int = 1920,
        outputHeight: Int = 1080,
        transitionSettings: PlayoutTransitionSettings = PlayoutTransitionSettings(),
        expectsExternalReference: Bool = false
    ) {
        self.formatVersion = formatVersion
        self.slides = slides
        self.showLists = showLists
        self.activeShowListID = activeShowListID
        self.stages = stages
        self.screens = screens
        self.selectedDeviceID = selectedDeviceID
        self.selectedModeID = selectedModeID
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.transitionSettings = transitionSettings
        self.expectsExternalReference = expectsExternalReference
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case slides
        case showLists
        case activeShowListID
        case stages
        case screens
        case selectedDeviceID
        case selectedModeID
        case outputWidth
        case outputHeight
        case transitionSettings
        case expectsExternalReference
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        slides = try container.decodeIfPresent([MediaSlide].self, forKey: .slides) ?? []
        showLists = try container.decodeIfPresent([ShowList].self, forKey: .showLists) ?? []
        activeShowListID = try container.decodeIfPresent(UUID.self, forKey: .activeShowListID)
        stages = try container.decodeIfPresent([Stage].self, forKey: .stages) ?? []
        screens = try container.decodeIfPresent([Screen].self, forKey: .screens) ?? []
        selectedDeviceID = try container.decodeIfPresent(String.self, forKey: .selectedDeviceID)
        selectedModeID = try container.decodeIfPresent(String.self, forKey: .selectedModeID)
        outputWidth = try container.decodeIfPresent(Int.self, forKey: .outputWidth) ?? 1920
        outputHeight = try container.decodeIfPresent(Int.self, forKey: .outputHeight) ?? 1080
        transitionSettings = try container.decodeIfPresent(PlayoutTransitionSettings.self, forKey: .transitionSettings)
            ?? PlayoutTransitionSettings()
        expectsExternalReference = try container.decodeIfPresent(Bool.self, forKey: .expectsExternalReference) ?? false
    }

    /// Bumps `formatVersion` to the current value, ensures at least one show list exists, and
    /// resolves `activeShowListID` to a known list. Call before save.
    mutating func markCurrentFormatVersion() {
        formatVersion = PlayoutProject.currentFormatVersion
        if showLists.isEmpty {
            showLists.append(ShowList(name: "Show 1"))
        }
        if let activeID = activeShowListID, !showLists.contains(where: { $0.id == activeID }) {
            activeShowListID = showLists.first?.id
        }
        if activeShowListID == nil {
            activeShowListID = showLists.first?.id
        }
        // Seed a default Program stage + screen so output topology is always non-empty.
        // Operators can rename, retype, or add screens later.
        if stages.isEmpty {
            let stage = Stage(
                name: "Program",
                width: outputWidth,
                height: outputHeight
            )
            stages.append(stage)
        }
        if screens.isEmpty, let firstStage = stages.first {
            screens.append(Screen(role: .program, name: "Program", stageID: firstStage.id))
        }
    }

    /// The show list currently active in the UI, falling back to the first list. Returns nil
    /// only when the project has no lists at all (only possible with a fresh empty project that
    /// hasn't been saved yet).
    var activeShowList: ShowList? {
        if let id = activeShowListID, let list = showLists.first(where: { $0.id == id }) {
            return list
        }
        return showLists.first
    }

    /// Generates a default show list from the asset library: one cue per slide, in order,
    /// numbered 1, 2, 3.... Useful for migrating v1 projects whose slides are already meant
    /// to be the show.
    mutating func generateDefaultShowList(named name: String = "Show 1") {
        let cues = slides.enumerated().map { index, slide in
            Cue(
                number: "\(index + 1)",
                title: slide.title,
                assetID: slide.id
            )
        }
        let list = ShowList(name: name, cues: cues)
        showLists.append(list)
        if activeShowListID == nil {
            activeShowListID = list.id
        }
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
