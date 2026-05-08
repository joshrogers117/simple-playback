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
        if let ref = evaluateExternalReference(project: project, context: context) {
            rows.append(ref)
        }
        if let disk = evaluateDiskSpace(context: context) {
            rows.append(disk)
        }
        if let audio = evaluateAudioDevice(context: context) {
            rows.append(audio)
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
