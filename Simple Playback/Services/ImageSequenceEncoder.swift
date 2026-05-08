import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// Encodes a list of frame URLs (the output of `ImageSequenceDetector` — PNG / JPEG / TIFF /
/// EXR) into a single ProRes 4444 .mov via `AVAssetWriter`. Spec §3.10 — "Image sequence
/// folder (`name.0001.png`) — detect → offer encode-to-ProRes-4444 via `AVAssetWriter`.
/// Do not play sequences directly."
///
/// Mirrors the C2 `TranscodeJob` shape: `@MainActor` `ObservableObject`, `state` enum
/// (`.idle / .running / .completed(URL) / .failed(String) / .cancelled`), `progress`
/// fraction. The session-7 / 9 progress strip (`TranscodeProgressStrip`) can render either
/// job kind once C5c plumbs the folder-drop UX through it.
///
/// **Frame rate is operator-supplied.** The detector returns frames in counter order with
/// no temporal information attached — sequences exported from VFX / compositing pipelines
/// are typically 24 / 25 / 30 / 48 / 60 fps depending on the production. Picking a default
/// at the encoder layer would commit a UX choice the operator hasn't made; the choice
/// belongs to C5c (folder-drop UI). Until then, callers must pass a frameRate explicitly.
@MainActor
final class ImageSequenceEncoder: ObservableObject, Identifiable {
    let id = UUID()

    /// Frame URLs in playback order. Caller is responsible for ordering — typically the
    /// detector's `Sequence.frameURLs`, which is sorted by counter.
    let frameURLs: [URL]
    let destinationURL: URL
    let frameRate: Int
    /// Operator-visible label for the progress surface — typically the detected sequence's
    /// baseName (e.g. `"shot01"`). Kept here so the progress row stays meaningful even if
    /// the underlying frame URLs become stale.
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

    private var encodeTask: Task<Void, Never>?

    init(frameURLs: [URL], destinationURL: URL, frameRate: Int, displayLabel: String) {
        self.frameURLs = frameURLs
        self.destinationURL = destinationURL
        self.frameRate = frameRate
        self.displayLabel = displayLabel
    }

    /// Kicks off the encode. The completion closure runs on the main actor when the
    /// encoder reaches a terminal state. Calling start() more than once is a no-op.
    func start(completion: @escaping @MainActor (Result<URL, ImageSequenceEncodeError>) -> Void) {
        guard state == .idle else { return }
        guard frameURLs.count >= 1 else {
            state = .failed("no frames")
            completion(.failure(.noFrames))
            return
        }
        guard frameRate >= 1 else {
            state = .failed("frame rate must be ≥ 1, got \(frameRate)")
            completion(.failure(.invalidFrameRate(frameRate)))
            return
        }
        state = .running

        let frames = frameURLs
        let dest = destinationURL
        let rate = frameRate
        let totalFrames = frames.count

        encodeTask = Task.detached { [weak self] in
            do {
                try await ImageSequenceEncoder.runEncode(
                    frames: frames,
                    destinationURL: dest,
                    frameRate: rate,
                    onProgress: { fraction in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if fraction != self.progress {
                                self.progress = fraction
                            }
                        }
                    },
                    isCancelled: { Task.isCancelled }
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.progress = 1.0
                    self.state = .completed(dest)
                    completion(.success(dest))
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.state = .cancelled
                    completion(.failure(.cancelled))
                }
            } catch let error as ImageSequenceEncodeError {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.state = .failed(error.errorDescription ?? "\(error)")
                    completion(.failure(error))
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let message = error.localizedDescription
                    self.state = .failed(message)
                    completion(.failure(.writerSetupFailed(message)))
                }
            }
            _ = totalFrames
        }
    }

    /// Cancels the underlying encode. Safe to call before start() (no-op) or after
    /// completion (no-op). The completion closure passed to start() will fire with
    /// `.cancelled` if the encode was running.
    func cancel() {
        guard !state.isTerminal else { return }
        encodeTask?.cancel()
    }

    // MARK: - Encode pipeline

    /// Runs the AVAssetWriter pipeline. Detached from the actor so the synchronous
    /// CGImageSource / CVPixelBuffer fill work doesn't block the main thread on long
    /// sequences. Progress / cancellation are routed via closures so this stays free of
    /// SwiftUI / actor concerns and is unit-testable in isolation if a future refactor
    /// pulls it into a free function.
    private static func runEncode(
        frames: [URL],
        destinationURL: URL,
        frameRate: Int,
        onProgress: @escaping (Double) -> Void,
        isCancelled: @escaping () -> Bool
    ) async throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        guard let firstImage = makeCGImage(from: frames[0]) else {
            throw ImageSequenceEncodeError.unreadableFrame(frames[0])
        }
        let width = firstImage.width
        let height = firstImage.height
        guard width > 0, height > 0 else {
            throw ImageSequenceEncodeError.unreadableFrame(frames[0])
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mov)
        } catch {
            throw ImageSequenceEncodeError.writerSetupFailed(error.localizedDescription)
        }

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.proRes4444,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )

        guard writer.canAdd(input) else {
            throw ImageSequenceEncodeError.writerSetupFailed("writer rejected ProRes 4444 input at \(width)×\(height)")
        }
        writer.add(input)

        guard writer.startWriting() else {
            let reason = writer.error?.localizedDescription ?? "startWriting() returned false"
            throw ImageSequenceEncodeError.writerSetupFailed(reason)
        }
        writer.startSession(atSourceTime: .zero)

        defer {
            // Defensive — if we throw out the back, make sure we don't leak the writer in
            // an indeterminate state. finishWriting on a non-running writer is a no-op.
            input.markAsFinished()
        }

        let timescale = CMTimeScale(frameRate)
        let total = frames.count

        for (index, url) in frames.enumerated() {
            if isCancelled() {
                writer.cancelWriting()
                throw CancellationError()
            }

            guard let image = makeCGImage(from: url) else {
                writer.cancelWriting()
                throw ImageSequenceEncodeError.unreadableFrame(url)
            }

            // Wait for the input to drain before appending. Spinning briefly here is
            // canonical AVAssetWriter usage — the input flips ready as the encoder drains
            // the queue.
            while !input.isReadyForMoreMediaData {
                if isCancelled() {
                    writer.cancelWriting()
                    throw CancellationError()
                }
                try await Task.sleep(nanoseconds: 5_000_000) // 5 ms
            }

            guard let pool = adaptor.pixelBufferPool else {
                writer.cancelWriting()
                throw ImageSequenceEncodeError.writerSetupFailed("pixel buffer pool unavailable")
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                writer.cancelWriting()
                throw ImageSequenceEncodeError.appendFailed("pool exhausted at frame \(index)")
            }

            try fillPixelBuffer(buffer, with: image, width: width, height: height)

            let pts = CMTime(value: CMTimeValue(index), timescale: timescale)
            if !adaptor.append(buffer, withPresentationTime: pts) {
                let reason = writer.error?.localizedDescription ?? "adaptor.append returned false"
                writer.cancelWriting()
                throw ImageSequenceEncodeError.appendFailed("frame \(index): \(reason)")
            }

            // Tick progress on a fractional basis the strip can render. Use (i+1)/total
            // so the bar reaches 1.0 only after the final append.
            onProgress(Double(index + 1) / Double(total))
        }

        input.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if writer.status != .completed {
            let reason = writer.error?.localizedDescription ?? "writer.status = \(writer.status.rawValue)"
            throw ImageSequenceEncodeError.finishFailed(reason)
        }
    }

    /// Decode a still URL (PNG / JPEG / TIFF / EXR) into a CGImage via Image I/O. Returns
    /// nil for unreadable / unsupported input. `nonisolated` because it touches no
    /// instance state — letting test code call it from a non-MainActor context.
    nonisolated static func makeCGImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Fills `buffer` (BGRA, premultiplied first, byte-order 32-little) with `image`,
    /// scaled to fit the buffer's dimensions. Frame size mismatches between sequence
    /// frames and the canonical first-frame size are fit-into-canvas rather than thrown —
    /// some operators export anamorphic / mixed-aspect frames and would prefer a soft
    /// landing.
    private static func fillPixelBuffer(_ buffer: CVPixelBuffer, with image: CGImage, width: Int, height: Int) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw ImageSequenceEncodeError.appendFailed("CVPixelBufferGetBaseAddress returned nil")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: bitmapInfo
        ) else {
            throw ImageSequenceEncodeError.appendFailed("CGContext init failed")
        }

        // Clear to transparent first — ProRes 4444 carries alpha and we want a clean
        // canvas if the source frame is smaller than the canonical size.
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

/// What the coordinator hands back on a successful encode. Mirrors `TranscodeOutcome` —
/// the caller (RootView) does the actual splice into `project.slides`; the coordinator
/// stays free of project-state knowledge.
struct ImageSequenceEncodeOutcome {
    /// Detected sequence's baseName; the operator-visible label of the resulting slide.
    let baseName: String
    let siblingSlide: MediaSlide
}

/// Owns live `ImageSequenceEncoder` instances for one window/document. Operators see the
/// running jobs in the same non-modal progress surface as transcodes (C2c
/// `TranscodeProgressStrip`) once C5c plumbs the folder-drop UX.
///
/// Mirrors `TranscodeCoordinator`'s shape (jobs list + injectable sibling-importer test
/// seam) so the eventual C5c integration is symmetric — no parallel decisions about how
/// progress / cancellation / sibling-slide construction should look.
@MainActor
final class ImageSequenceEncodeCoordinator: ObservableObject {

    /// Test seam — given the encoded `.mov` URL, return the MediaSlide that lands in the
    /// asset library. Default delegates to `MediaImporter.importSlides(from:)` so the
    /// resulting slide carries fresh `nativeFrameRate` + `MediaFlags` populated by the C1
    /// inspector. Tests substitute a stub that synthesizes a deterministic slide.
    static var siblingImporter: (URL) -> MediaSlide? = { url in
        MediaImporter.importSlides(from: [url]).first
    }

    @Published private(set) var jobs: [ImageSequenceEncoder] = []

    /// Kicks off an encode for the given detected sequence. The coordinator builds the
    /// destination URL (`<destinationDirectory>/<UUID>.mov`), starts the encoder, and on
    /// success constructs an outcome whose sibling slide is named after the detected
    /// sequence's baseName.
    @discardableResult
    func encode(
        sequence: ImageSequenceDetector.Sequence,
        frameRate: Int,
        destinationDirectory: URL,
        completion: @MainActor @escaping (Result<ImageSequenceEncodeOutcome, ImageSequenceEncodeError>) -> Void
    ) -> ImageSequenceEncoder? {
        let dest = destinationDirectory
            .appendingPathComponent("\(UUID().uuidString).mov", isDirectory: false)
        let label = sequence.baseName
        let encoder = ImageSequenceEncoder(
            frameURLs: sequence.frameURLs,
            destinationURL: dest,
            frameRate: frameRate,
            displayLabel: label
        )
        jobs.append(encoder)

        encoder.start { [weak self] result in
            guard let self else { return }
            self.jobs.removeAll { $0.id == encoder.id }
            switch result {
            case .success(let url):
                guard var sibling = ImageSequenceEncodeCoordinator.siblingImporter(url) else {
                    completion(.failure(.finishFailed("encoded file did not import as a video slide")))
                    return
                }
                sibling.title = label
                completion(.success(ImageSequenceEncodeOutcome(
                    baseName: label,
                    siblingSlide: sibling
                )))
            case .failure(let error):
                completion(.failure(error))
            }
        }
        return encoder
    }

    /// Cancels every running encode. Used by the document-close path so we don't leak
    /// orphaned encoder tasks.
    func cancelAll() {
        for job in jobs {
            job.cancel()
        }
    }
}

enum ImageSequenceEncodeError: LocalizedError, Equatable {
    case noFrames
    case invalidFrameRate(Int)
    case unreadableFrame(URL)
    case writerSetupFailed(String)
    case appendFailed(String)
    case finishFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noFrames:
            "Image sequence is empty."
        case .invalidFrameRate(let rate):
            "Frame rate must be ≥ 1, got \(rate)."
        case .unreadableFrame(let url):
            "Frame is not readable: \(url.lastPathComponent)"
        case .writerSetupFailed(let reason):
            "Encoder setup failed: \(reason)"
        case .appendFailed(let reason):
            "Frame append failed: \(reason)"
        case .finishFailed(let reason):
            "Encoder finalization failed: \(reason)"
        case .cancelled:
            "Image sequence encode cancelled."
        }
    }
}
