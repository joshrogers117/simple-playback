import CoreGraphics
import Foundation

/// C11 — background-queue coordinator for filmstrip sprite-sheet
/// generation. Mirrors `TranscodeCoordinator` / `BundleForTravelCoordinator`
/// shape: `@MainActor ObservableObject`, jobs list for the operator-
/// visible progress strip, sibling-output splice via completion handler.
///
/// Why a coordinator at all rather than calling `FilmstripGenerator`
/// inline at import time: extracting 24 frames through
/// `AVAssetImageGenerator` is synchronous and can take hundreds of
/// milliseconds (multi-GB H.264 sources) — running on main would hitch
/// the UI. The coordinator hops the heavy work to `Task.detached` and
/// publishes the running-jobs list so a future progress strip can render
/// the in-flight set just like transcode/encode jobs do today.
///
/// De-dupe: one job per `slideID`. Repeated `enqueue` calls while a job
/// is running are no-ops — operator-driven re-imports of the same slide
/// don't stack multiple extractions of the same source.
///
/// Cancellation: out of scope for v1. The synchronous extraction loop
/// inside `FilmstripGenerator.generateSpriteSheet` is uninterruptible
/// mid-frame; a future refactor could thread cancellation between
/// extractions, but typical 24-frame jobs finish under a second on a
/// modern host. Document close drops the coordinator (and the in-flight
/// task's result is discarded by the weak-self capture).
@MainActor
final class FilmstripCoordinator: ObservableObject {

    enum Outcome: Equatable {
        case completed(URL)
        case failed(FilmstripGenerator.Failure)
    }

    /// Test seam — the pure-logic generator. Default delegates to
    /// `FilmstripGenerator.generateSpriteSheet`. Tests substitute a stub
    /// that records calls without going through AVFoundation. Async to
    /// match the migrated `image(at:)` extraction loop and to honor
    /// Task cancellation between frames natively.
    nonisolated(unsafe) static var generator: @Sendable (URL, Int, Int, CGSize) async throws -> Data = { url, count, cols, size in
        try await FilmstripGenerator.generateSpriteSheet(
            for: url,
            frameCount: count,
            columns: cols,
            frameSize: size
        )
    }

    /// Test seam — file writer. Default ensures the parent directory
    /// exists and writes atomically so a crash mid-write doesn't leave
    /// a truncated PNG. Tests substitute a stub that records the
    /// (data, url) pair without touching disk.
    nonisolated(unsafe) static var writer: (Data, URL) throws -> Void = { data, url in
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    @Published private(set) var jobs: [Job] = []

    /// One running filmstrip generation. Identifiable so SwiftUI can
    /// render the running set in a progress strip.
    final class Job: Identifiable, Equatable {
        let id = UUID()
        let slideID: UUID
        let sourceURL: URL
        let destinationURL: URL

        init(slideID: UUID, sourceURL: URL, destinationURL: URL) {
            self.slideID = slideID
            self.sourceURL = sourceURL
            self.destinationURL = destinationURL
        }

        static func == (lhs: Job, rhs: Job) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// Whether a filmstrip job is currently running for `slideID`.
    func isRunning(slideID: UUID) -> Bool {
        jobs.contains { $0.slideID == slideID }
    }

    /// Kicks off filmstrip generation. Repeated enqueue for an already-
    /// running slide is a no-op. Completion runs on the main actor when
    /// the detached task finishes (success or failure).
    func enqueue(
        slideID: UUID,
        sourceURL: URL,
        destinationURL: URL,
        frameCount: Int = FilmstripGenerator.defaultFrameCount,
        columns: Int = FilmstripGenerator.defaultColumns,
        frameSize: CGSize = FilmstripGenerator.defaultFrameSize,
        completion: (@MainActor (Outcome) -> Void)? = nil
    ) {
        if isRunning(slideID: slideID) { return }
        let job = Job(slideID: slideID, sourceURL: sourceURL, destinationURL: destinationURL)
        jobs.append(job)

        let captureSlideID = slideID
        let captureFrameCount = frameCount
        let captureColumns = columns
        let captureFrameSize = frameSize
        let captureSource = sourceURL
        let captureDestination = destinationURL

        Task.detached { [weak self] in
            let outcome: Outcome
            do {
                let data = try await Self.generator(
                    captureSource,
                    captureFrameCount,
                    captureColumns,
                    captureFrameSize
                )
                try Self.writer(data, captureDestination)
                outcome = .completed(captureDestination)
            } catch is CancellationError {
                // A cancelled job is silently dropped — the host (typically
                // the document closing) doesn't need a failure entry.
                await MainActor.run { [weak self] in
                    self?.removeJob(forSlide: captureSlideID)
                }
                return
            } catch let failure as FilmstripGenerator.Failure {
                outcome = .failed(failure)
            } catch {
                // Non-FilmstripGenerator throw means the writer raised —
                // surface as encodingFailed since the generator emitted
                // bytes that we couldn't persist.
                outcome = .failed(.encodingFailed)
            }
            await MainActor.run { [weak self] in
                self?.removeJob(forSlide: captureSlideID)
                completion?(outcome)
            }
        }
    }

    private func removeJob(forSlide slideID: UUID) {
        jobs.removeAll { $0.slideID == slideID }
    }
}
