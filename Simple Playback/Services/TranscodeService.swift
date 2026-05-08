import AVFoundation
import Foundation

/// ProRes presets the operator can pick from the asset library context menu. ProRes 422 is
/// the default for risky-codec rescue (long-GOP / VFR / 10-bit 4:2:0 / untagged color, all
/// the inspector flags from C1). ProRes 4444 is the alpha-bearing path used by C4 (animated
/// GIF) and C5 (image sequences) once those land — keeping the enum small now means C4/C5
/// extend `TranscodePreset` rather than introducing a parallel transcode surface.
enum TranscodePreset: String, Codable, Hashable, CaseIterable {
    case proRes422
    case proRes4444

    var label: String {
        switch self {
        case .proRes422: "ProRes 422"
        case .proRes4444: "ProRes 4444"
        }
    }

    /// AVFoundation preset constant. The "LPCM" suffix means audio is pulled into LPCM
    /// (uncompressed) — that's the operator-correct choice for playout where every clip
    /// should be intra-frame and uncompressed-audio for scrub safety.
    var avPresetName: String {
        switch self {
        case .proRes422: AVAssetExportPresetAppleProRes422LPCM
        case .proRes4444: AVAssetExportPresetAppleProRes4444LPCM
        }
    }

    var fileExtension: String { "mov" }
    var avFileType: AVFileType { .mov }
}

enum TranscodeError: LocalizedError, Equatable {
    case sourceNotReadable(URL)
    case presetIncompatible(String)
    case exportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .sourceNotReadable(let url):
            "Source media is not readable: \(url.lastPathComponent)"
        case .presetIncompatible(let preset):
            "AVFoundation cannot transcode this asset to \(preset)."
        case .exportFailed(let reason):
            "Transcode failed: \(reason)"
        case .cancelled:
            "Transcode cancelled."
        }
    }
}

/// Pure-logic helpers around transcode plumbing — no AVFoundation state. Matches the C3/C6
/// shape: pure `enum` namespace plus the `TranscodeJob` ObservableObject for the live
/// AVAssetExportSession side.
enum TranscodeService {

    /// Sibling-slide title that the operator sees in the palette after a successful
    /// transcode. Spec §3.10 calls this a "transcode to ProRes" action — the resulting
    /// slide should be obviously paired with its source.
    static func siblingTitle(originalTitle: String, preset: TranscodePreset) -> String {
        "\(originalTitle) (\(preset.label))"
    }

    /// On-disk filename. UUID-keyed so concurrent transcodes of files with the same
    /// basename never collide, matching the C3 PDF batch-directory pattern.
    static func destinationFilename(preset: TranscodePreset) -> String {
        "\(UUID().uuidString).\(preset.fileExtension)"
    }

    /// Whether the asset library should offer a transcode at all. False for static stills
    /// (no point transcoding a PNG to ProRes), audio-only files, broken assets — the menu
    /// item should be hidden in those cases. Animated GIF / APNG (`.image` slides whose
    /// `flags.animatedImage` is true, per C4) are eligible: today they only play their
    /// first frame, and the C4 chip's recommendation is to transcode to ProRes 4444 to
    /// recover full motion. AVFoundation reads animated GIFs through `AVURLAsset` on
    /// modern macOS, so the export-session path works the same as the video case.
    static func canTranscode(slide: MediaSlide) -> Bool {
        guard slide.media.resolvedURL() != nil else { return false }
        if slide.mediaKind == .video { return true }
        if slide.mediaKind == .image && slide.flags.animatedImage { return true }
        return false
    }

    /// Operator-friendly order for the right-click menu. Animated GIF / APNG sources lead
    /// with ProRes 4444 (alpha-bearing — typical animated-GIF use cases like lower-thirds
    /// and logo bugs need the alpha channel preserved). All other transcode-eligible
    /// sources lead with ProRes 422 — the standard "rescue a long-GOP / VFR clip" path.
    /// Both presets are always returned so the operator can override the default.
    static func preferredPresetOrder(for slide: MediaSlide) -> [TranscodePreset] {
        if slide.flags.animatedImage {
            return [.proRes4444, .proRes422]
        }
        return [.proRes422, .proRes4444]
    }
}

/// Wraps `AVAssetExportSession` for a single transcode. ObservableObject so the UI can
/// bind a non-modal progress surface without re-rendering the whole palette on every
/// progress tick.
@MainActor
final class TranscodeJob: ObservableObject, Identifiable {
    let id = UUID()
    let sourceURL: URL
    let destinationURL: URL
    let preset: TranscodePreset
    /// Operator-visible label, derived from the source slide's title at job-creation
    /// time. Kept here so the progress surface can render a meaningful row even after
    /// the source slide is deleted from the palette mid-transcode.
    let displayLabel: String

    @Published private(set) var progress: Double = 0
    @Published private(set) var state: State = .idle

    enum State: Equatable {
        case idle
        case running
        case completed(URL)
        case failed(String)
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .idle, .running: false
            case .completed, .failed, .cancelled: true
            }
        }

        var isRunning: Bool {
            self == .running
        }
    }

    private var exportTask: Task<Void, Never>?
    private var stateObserverTask: Task<Void, Never>?

    init(sourceURL: URL, destinationURL: URL, preset: TranscodePreset, displayLabel: String) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.preset = preset
        self.displayLabel = displayLabel
    }

    /// Kicks off the export. The completion closure runs on the main actor when the
    /// session reaches a terminal state. Calling start() more than once is a no-op.
    func start(completion: @escaping @MainActor (Result<URL, TranscodeError>) -> Void) {
        guard state == .idle else { return }
        state = .running

        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset.avPresetName) else {
            state = .failed("preset \(preset.avPresetName) is unavailable")
            completion(.failure(.presetIncompatible(preset.avPresetName)))
            return
        }

        // Make sure the destination directory exists. If the file is already present from
        // a prior aborted run, AVAssetExportSession will refuse to overwrite — clear it.
        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
        } catch {
            state = .failed("could not prepare destination: \(error.localizedDescription)")
            completion(.failure(.exportFailed(error.localizedDescription)))
            return
        }

        session.shouldOptimizeForNetworkUse = false

        let dest = destinationURL
        let fileType = preset.avFileType

        // Observe progress via the modern `states(updateInterval:)` AsyncSequence rather
        // than KVO/polling. The sequence emits `.exporting(Progress)` ticks while the
        // export is running.
        stateObserverTask = Task { @MainActor [weak self] in
            for await progressState in session.states(updateInterval: 0.2) {
                guard let self else { return }
                if case .exporting(let progress) = progressState {
                    let fraction = progress.fractionCompleted
                    if fraction != self.progress {
                        self.progress = fraction
                    }
                }
            }
        }

        exportTask = Task { @MainActor [weak self] in
            do {
                try await session.export(to: dest, as: fileType)
                guard let self else { return }
                self.stateObserverTask?.cancel()
                self.stateObserverTask = nil
                self.progress = 1.0
                self.state = .completed(dest)
                completion(.success(dest))
            } catch is CancellationError {
                guard let self else { return }
                self.stateObserverTask?.cancel()
                self.stateObserverTask = nil
                self.state = .cancelled
                completion(.failure(.cancelled))
            } catch {
                guard let self else { return }
                self.stateObserverTask?.cancel()
                self.stateObserverTask = nil
                if (error as NSError).code == NSUserCancelledError {
                    self.state = .cancelled
                    completion(.failure(.cancelled))
                } else {
                    let message = error.localizedDescription
                    self.state = .failed(message)
                    completion(.failure(.exportFailed(message)))
                }
            }
        }
    }

    /// Cancels the underlying export. Safe to call before start() (no-op) or after
    /// completion (no-op). The completion closure passed to start() will fire with
    /// `.cancelled` if the session was running.
    func cancel() {
        guard !state.isTerminal else { return }
        exportTask?.cancel()
        stateObserverTask?.cancel()
    }
}

/// What the coordinator hands back on a successful transcode. The caller (RootView) does
/// the actual splice into `project.slides`; the coordinator stays free of project-state
/// knowledge so it can be unit-tested in isolation.
struct TranscodeOutcome {
    /// `MediaSlide.id` of the source slide. Used to insert the sibling slide right after
    /// the original in the asset library — non-destructive A/B per the C2 design note.
    let sourceSlideID: UUID
    let preset: TranscodePreset
    let siblingSlide: MediaSlide
}

/// Owns the live `TranscodeJob` instances for one window/document. Operators see the
/// running jobs rendered as a non-modal progress surface (C2c) without freezing the UI.
@MainActor
final class TranscodeCoordinator: ObservableObject {

    /// Test seam — the post-transcode re-import that yields the sibling slide. The
    /// default delegates to `MediaImporter.importSlides(from:)` so the sibling carries
    /// fresh `nativeFrameRate` + `MediaFlags` (cleared long-GOP / VFR / 10-bit-4:2:0
    /// flags after a successful ProRes transcode are exactly what the operator wants
    /// to see in the inspector). Tests substitute a stub that produces a deterministic
    /// MediaSlide so the wiring is verifiable without re-running AVFoundation.
    static var siblingImporter: (URL) -> MediaSlide? = { url in
        MediaImporter.importSlides(from: [url]).first
    }

    @Published private(set) var jobs: [TranscodeJob] = []

    /// Kicks off a transcode for `slide` against `destinationDirectory`. The slide is
    /// expected to be a video whose URL resolves; `TranscodeService.canTranscode` is
    /// the gate the UI uses, but this method returns nil for invariant violations so
    /// the caller can short-circuit.
    @discardableResult
    func transcode(
        slide: MediaSlide,
        preset: TranscodePreset,
        destinationDirectory: URL,
        completion: @MainActor @escaping (Result<TranscodeOutcome, TranscodeError>) -> Void
    ) -> TranscodeJob? {
        guard let source = slide.media.resolvedURL() else {
            completion(.failure(.sourceNotReadable(slide.media.resolvedURL() ?? URL(fileURLWithPath: ""))))
            return nil
        }
        let dest = destinationDirectory
            .appendingPathComponent(TranscodeService.destinationFilename(preset: preset), isDirectory: false)
        let label = TranscodeService.siblingTitle(originalTitle: slide.title, preset: preset)
        let job = TranscodeJob(sourceURL: source, destinationURL: dest, preset: preset, displayLabel: label)
        jobs.append(job)

        let sourceID = slide.id
        job.start { [weak self] result in
            guard let self else { return }
            self.jobs.removeAll { $0.id == job.id }
            switch result {
            case .success(let url):
                guard var sibling = TranscodeCoordinator.siblingImporter(url) else {
                    completion(.failure(.exportFailed("transcoded file did not import as a video slide")))
                    return
                }
                sibling.title = label
                completion(.success(TranscodeOutcome(
                    sourceSlideID: sourceID,
                    preset: preset,
                    siblingSlide: sibling
                )))
            case .failure(let error):
                completion(.failure(error))
            }
        }
        return job
    }

    /// Cancels every running job. Used by the document close path so we don't leak
    /// orphaned export sessions.
    func cancelAll() {
        for job in jobs {
            job.cancel()
        }
    }
}
