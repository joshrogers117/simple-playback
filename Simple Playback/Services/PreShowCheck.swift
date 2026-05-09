import Foundation

/// Pure-logic evaluator for the Phase E1 pre-show check panel. Spec §7:
///
/// > Pre-show check — media, DeckLink, disk, macOS energy/DND/screensaver/Spotlight,
/// > audio device, render path warmed.
///
/// This file covers the subset of checks that are pure-logic against the project plus
/// caller-supplied external signals (DeckLink lock state, etc.). System-level checks
/// (disk space, energy, Spotlight) plug in via additional rows the host appends to the
/// list — the evaluator does not import AppKit / IOKit / DeckLink itself.
///
/// Splitting the rules from the panel keeps every row independently unit-testable. The
/// host (RootView) renders the rows via `PreShowCheckView`; E2 (fix actions) maps each
/// row's `id` to a callback that resolves the issue.
enum PreShowCheck {

    /// External signals the host plumbs in. Every field is optional — when nil the
    /// corresponding row is either skipped (no signal to evaluate) or rendered as
    /// `.informational` ("not yet checked"). The pure-logic side stays free of AppKit /
    /// DeckLink imports; adapters live next to the host.
    struct Context: Equatable {
        /// Live DeckLink reference status, when a DeckLink output is configured. `nil`
        /// when no output is configured or the bridge has not yet reported.
        var deckLinkReferenceStatus: DeckLinkReferenceStatus?

        /// Free disk space available at the project bundle's enclosing volume, in bytes.
        /// `nil` skips the row (untitled documents, or the host has not yet sampled).
        var availableDiskBytes: Int64?

        /// Minimum bytes the operator considers safe for a full-show cache. Default 5 GB
        /// matches the spec's "leave room for capture and Cache/Renders" guidance — host
        /// can override per-project.
        var minimumDiskBytes: Int64 = 5_000_000_000

        /// Whether the host has confirmed an audio output device is available. `nil`
        /// when the host has not yet sampled.
        var audioDeviceAvailable: Bool?

        /// Whether the render path has pushed at least one composed frame through to
        /// its outputs since the controller started. Spec §3.16 lists "render path
        /// warmed" as a pre-show requirement — operators want to verify the pipeline
        /// isn't cold before a show. `nil` when the host has not yet sampled.
        var renderPathWarmed: Bool?

        /// Whether the host has registered a no-idle-sleep IOPM assertion, so macOS
        /// cannot idle-sleep the machine mid-show. Set to true when Show Mode is on
        /// and `EnergyAssertion.acquire()` succeeded. `nil` skips the row (host has
        /// not yet sampled). Spec §3.16 calls out energy / never-sleep among the
        /// macOS conditions a pre-show panel should verify.
        var systemPreventsIdleSleep: Bool?

        /// C7c — asset-library snapshot the host samples by walking the project's
        /// slide list and verifying each `MediaReference` resolves to a real file
        /// on disk. `nil` skips the row. Empty libraries (`totalSlideCount == 0`)
        /// render as an info row so the operator notices when a fresh project
        /// hasn't had any media imported yet.
        var assetLibraryStatus: AssetLibraryStatus?
    }

    enum DeckLinkReferenceStatus: Equatable {
        case notRequired
        case locked
        case unlocked
        case notSupported
    }

    /// One row in the pre-show panel.
    struct Row: Identifiable, Equatable {
        let id: String
        let severity: Severity
        let title: String
        let summary: String

        enum Severity: Equatable, Comparable {
            case ok
            case info
            case warning
            case error

            var sortOrder: Int {
                switch self {
                case .error: 0
                case .warning: 1
                case .info: 2
                case .ok: 3
                }
            }

            static func < (lhs: Severity, rhs: Severity) -> Bool {
                lhs.sortOrder < rhs.sortOrder
            }
        }
    }

    /// Evaluate the pure-logic + context-driven rules. Rows return in a stable order:
    /// errors first, then warnings, then info, then ok within each rule group. The `id`
    /// of each row is stable across runs so SwiftUI's diffing animates updates smoothly.
    static func evaluate(project: PlayoutProject, context: Context = Context()) -> [Row] {
        var rows: [Row] = []
        rows.append(evaluateMediaResolution(project: project))
        rows.append(contentsOf: evaluateFrameRateConformance(project: project))
        if let ten = evaluateTenBitRecommendation(project: project) {
            rows.append(ten)
        }
        if let codec = evaluateCodecAdvisory(project: project) {
            rows.append(codec)
        }
        if let ref = evaluateExternalReference(project: project, context: context) {
            rows.append(ref)
        }
        if let disk = evaluateDiskSpace(context: context) {
            rows.append(disk)
        }
        if let audio = evaluateAudioDevice(context: context) {
            rows.append(audio)
        }
        if let render = evaluateRenderPath(context: context) {
            rows.append(render)
        }
        if let energy = evaluateEnergy(context: context) {
            rows.append(energy)
        }
        if let library = evaluateAssetLibrary(context: context) {
            rows.append(library)
        }
        // Stable order: severity-major (errors first), title-tiebreak.
        return rows.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
            return lhs.title < rhs.title
        }
    }

    // MARK: - Rules

    /// Every cue references a slide in the project's asset library. Missing assets are
    /// the most common pre-show breakage (media on a removed external drive, deleted
    /// asset, mis-imported deck).
    static func evaluateMediaResolution(project: PlayoutProject) -> Row {
        let slideIDs = Set(project.slides.map(\.id))
        var missing: [String] = []
        for list in project.showLists {
            for cue in list.cues where !slideIDs.contains(cue.assetID) {
                missing.append(cue.number.isEmpty ? cue.title : cue.number)
            }
        }
        if missing.isEmpty {
            return Row(
                id: "media.resolution",
                severity: .ok,
                title: "Media",
                summary: "All cues resolve to a slide in the asset library."
            )
        }
        let preview = missing.prefix(3).joined(separator: ", ")
        let extra = missing.count > 3 ? " (+\(missing.count - 3) more)" : ""
        return Row(
            id: "media.resolution",
            severity: .error,
            title: "Media",
            summary: "\(missing.count) cue(s) missing media: \(preview)\(extra)."
        )
    }

    /// Frame-rate conformance for every video cue against the active Stage rate. Reuses
    /// the B14 evaluator. Mismatches don't block playback (AVFoundation re-times) but
    /// surface as a warning so the operator sees them once before the show rather than
    /// during.
    static func evaluateFrameRateConformance(project: PlayoutProject) -> [Row] {
        guard let stageFPS = project.stages.first?.framesPerSecond else {
            return [Row(
                id: "stage.frameRate",
                severity: .warning,
                title: "Stage",
                summary: "Stage has no configured frame rate."
            )]
        }
        let slidesByID = Dictionary(uniqueKeysWithValues: project.slides.map { ($0.id, $0) })
        var mismatchCount = 0
        var unknownCount = 0
        var checkedCount = 0
        for list in project.showLists {
            for cue in list.cues {
                guard let asset = slidesByID[cue.assetID], asset.mediaKind == .video else { continue }
                checkedCount += 1
                let conformance = FrameRateConformance(clipFPS: asset.nativeFrameRate, stageFPS: stageFPS)
                switch conformance.severity {
                case .mismatch: mismatchCount += 1
                case .unknown: unknownCount += 1
                case .match: break
                }
            }
        }
        if checkedCount == 0 {
            return [Row(
                id: "fps.conformance",
                severity: .info,
                title: "Frame Rate",
                summary: "No video cues to check."
            )]
        }
        if mismatchCount > 0 {
            let stageString = FrameRateConformance.format(stageFPS)
            return [Row(
                id: "fps.conformance",
                severity: .warning,
                title: "Frame Rate",
                summary: "\(mismatchCount) of \(checkedCount) video cue(s) do not match Stage \(stageString) fps — AVFoundation will re-time."
            )]
        }
        if unknownCount > 0 {
            return [Row(
                id: "fps.conformance",
                severity: .info,
                title: "Frame Rate",
                summary: "\(unknownCount) of \(checkedCount) video cue(s) have unknown native frame rate."
            )]
        }
        let stageString = FrameRateConformance.format(stageFPS)
        return [Row(
            id: "fps.conformance",
            severity: .ok,
            title: "Frame Rate",
            summary: "All \(checkedCount) video cue(s) match Stage \(stageString) fps."
        )]
    }

    /// Surface the B8 ten-bit-output recommendation as a pre-show informational row.
    /// Operators should know before the show whether the project's content benefits
    /// from 10-bit YUV output so they can verify the DeckLink mode is set accordingly.
    /// Returns nil when no flag is set (suppress the row entirely — pre-show panels with
    /// noise-rows degrade fast).
    static func evaluateTenBitRecommendation(project: PlayoutProject) -> Row? {
        guard project.recommendsTenBitOutput else { return nil }
        return Row(
            id: "output.tenBit",
            severity: .info,
            title: "Output",
            summary: "Project contains 10-bit content — 10-bit YUV output recommended."
        )
    }

    /// Roll up the C1 codec-inspector advisories (long-GOP / variable frame rate /
    /// untagged color) across the project as a single pre-show row. The cue inspector
    /// already renders one chip per flagged clip; this row tells the operator how many
    /// clips collectively carry each advisory before the show starts so the "should I
    /// transcode?" decision happens at the desk, not mid-show.
    ///
    /// Returns nil when no clip carries any of the three advisories — pre-show panels
    /// degrade fast with noise rows. Severity is `.info` because none of these flags
    /// block playback (AVFoundation handles long-GOP and VFR; untagged color falls back
    /// to sRGB), they only inform a transcode-or-accept decision.
    ///
    /// `tenBitYUV420` is intentionally excluded — it has its own dedicated row above
    /// (`evaluateTenBitRecommendation`) because it's an output-side recommendation, not
    /// a content-side advisory. `animatedImage` is also excluded — it's a "first frame
    /// only without transcode" hint that already surfaces as an inline transcode chip on
    /// the cue inspector and doesn't generalize to a roll-up message.
    static func evaluateCodecAdvisory(project: PlayoutProject) -> Row? {
        var longGOPCount = 0
        var variableFrameRateCount = 0
        var untaggedColorCount = 0
        for slide in project.slides {
            if slide.flags.longGOP { longGOPCount += 1 }
            if slide.flags.variableFrameRate { variableFrameRateCount += 1 }
            if slide.flags.untaggedColor { untaggedColorCount += 1 }
        }
        guard longGOPCount + variableFrameRateCount + untaggedColorCount > 0 else { return nil }
        var fragments: [String] = []
        if longGOPCount > 0 {
            fragments.append("\(longGOPCount) long-GOP")
        }
        if variableFrameRateCount > 0 {
            fragments.append("\(variableFrameRateCount) VFR")
        }
        if untaggedColorCount > 0 {
            fragments.append("\(untaggedColorCount) untagged-color")
        }
        let summary = "Codec advisories: \(fragments.joined(separator: ", ")) — review the cue inspector and consider Transcode to ProRes."
        return Row(
            id: "media.codec",
            severity: .info,
            title: "Codec",
            summary: summary
        )
    }

    /// Cross-checks the project's `expectsExternalReference` against the live DeckLink
    /// lock state. The escalation pattern matches the B6b status-bar banner: when
    /// reference is expected and the bridge reports `unlocked`, the row is an error
    /// (operator wants genlock and isn't getting it). Other combinations are info or
    /// suppressed.
    static func evaluateExternalReference(project: PlayoutProject, context: Context) -> Row? {
        guard project.expectsExternalReference else { return nil }
        guard let status = context.deckLinkReferenceStatus else {
            return Row(
                id: "output.reference",
                severity: .info,
                title: "Reference",
                summary: "External reference expected — DeckLink lock state not yet sampled."
            )
        }
        switch status {
        case .locked:
            return Row(
                id: "output.reference",
                severity: .ok,
                title: "Reference",
                summary: "External reference locked."
            )
        case .unlocked:
            return Row(
                id: "output.reference",
                severity: .error,
                title: "Reference",
                summary: "External reference expected — DeckLink reports free-running output."
            )
        case .notSupported:
            return Row(
                id: "output.reference",
                severity: .warning,
                title: "Reference",
                summary: "External reference expected — current DeckLink does not expose lock state."
            )
        case .notRequired:
            // expectsExternalReference is true, but the bridge claims the active output
            // does not require reference. Surface as info — likely the bridge is in a
            // transient state during setup; operators should re-check after arming.
            return Row(
                id: "output.reference",
                severity: .info,
                title: "Reference",
                summary: "External reference expected — DeckLink not yet armed."
            )
        }
    }

    /// Disk space row. Skipped (returns nil) when the host has no measurement to
    /// supply — untitled documents typically don't have a meaningful free-space target
    /// because the bundle isn't on disk yet.
    static func evaluateDiskSpace(context: Context) -> Row? {
        guard let available = context.availableDiskBytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        let availableString = formatter.string(fromByteCount: available)
        if available < context.minimumDiskBytes {
            let minimumString = formatter.string(fromByteCount: context.minimumDiskBytes)
            return Row(
                id: "system.disk",
                severity: .warning,
                title: "Disk",
                summary: "Free space \(availableString) is below the \(minimumString) safety floor."
            )
        }
        return Row(
            id: "system.disk",
            severity: .ok,
            title: "Disk",
            summary: "Free space: \(availableString)."
        )
    }

    /// Render path row. `renderPathWarmed == true` is OK; `false` is a warning
    /// ("render path cold — push at least one cue before the show"); nil is suppressed
    /// (host has not yet sampled).
    static func evaluateRenderPath(context: Context) -> Row? {
        guard let warmed = context.renderPathWarmed else { return nil }
        if warmed {
            return Row(
                id: "render.warmed",
                severity: .ok,
                title: "Render Path",
                summary: "Render path has pushed at least one frame to output."
            )
        }
        return Row(
            id: "render.warmed",
            severity: .warning,
            title: "Render Path",
            summary: "Render path is cold — fire a cue to warm the pipeline before doors open."
        )
    }

    /// Energy row. `systemPreventsIdleSleep == true` is OK ("we're holding a
    /// no-idle-sleep assertion — macOS will not put the machine to sleep");
    /// `false` is a warning ("system could idle-sleep mid-show — toggle Show Mode
    /// to engage the assertion"); nil is suppressed (host has not yet sampled).
    static func evaluateEnergy(context: Context) -> Row? {
        guard let asserted = context.systemPreventsIdleSleep else { return nil }
        if asserted {
            return Row(
                id: "system.energy",
                severity: .ok,
                title: "Energy",
                summary: "Idle sleep blocked — show machine will stay awake."
            )
        }
        return Row(
            id: "system.energy",
            severity: .warning,
            title: "Energy",
            summary: "macOS could idle-sleep mid-show — Show Mode engages a no-idle-sleep assertion."
        )
    }

    /// Asset-library row — every MediaSlide whose underlying file isn't on disk shows
    /// up here as an error; slides whose file is on disk but has changed since import
    /// (size/mtime delta vs the C7 fingerprint) show up as a warning. The cue-level
    /// "media.resolution" row above checks logical cue→slide pointer integrity; this
    /// row checks on-disk file health one rung deeper. They're independent: a project
    /// can pass one and fail the other. nil context skips the row entirely.
    static func evaluateAssetLibrary(context: Context) -> Row? {
        guard let status = context.assetLibraryStatus else { return nil }
        if status.totalSlideCount == 0 {
            return Row(
                id: "media.files",
                severity: .info,
                title: "Files",
                summary: "No media in the asset library."
            )
        }
        if status.offlineSlideCount > 0 {
            let preview = status.offlineSlideTitles.joined(separator: ", ")
            let extra = status.offlineSlideCount > status.offlineSlideTitles.count
                ? " (+\(status.offlineSlideCount - status.offlineSlideTitles.count) more)"
                : ""
            return Row(
                id: "media.files",
                severity: .error,
                title: "Files",
                summary: "\(status.offlineSlideCount) of \(status.totalSlideCount) media file(s) offline: \(preview)\(extra)."
            )
        }
        if status.staleSlideCount > 0 {
            let preview = status.staleSlideTitles.joined(separator: ", ")
            let extra = status.staleSlideCount > status.staleSlideTitles.count
                ? " (+\(status.staleSlideCount - status.staleSlideTitles.count) more)"
                : ""
            return Row(
                id: "media.files",
                severity: .warning,
                title: "Files",
                summary: "\(status.staleSlideCount) of \(status.totalSlideCount) media file(s) modified since import: \(preview)\(extra)."
            )
        }
        return Row(
            id: "media.files",
            severity: .ok,
            title: "Files",
            summary: "All \(status.totalSlideCount) media file(s) resolve."
        )
    }

    /// Audio device row. `audioDeviceAvailable == false` is an error — the show has no
    /// way to play audio; `true` is OK; nil is skipped (host has not yet sampled).
    static func evaluateAudioDevice(context: Context) -> Row? {
        guard let available = context.audioDeviceAvailable else { return nil }
        if available {
            return Row(
                id: "system.audio",
                severity: .ok,
                title: "Audio",
                summary: "Audio output device available."
            )
        }
        return Row(
            id: "system.audio",
            severity: .error,
            title: "Audio",
            summary: "No audio output device — embedded audio cues will not play."
        )
    }
}
