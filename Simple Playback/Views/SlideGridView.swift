import AVFoundation
import SwiftUI

struct SlideGridView: View {
    @Binding var slides: [MediaSlide]
    @Binding var selectedSlideID: UUID?
    var liveSlideID: UUID?
    @Binding var transitionSettings: PlayoutTransitionSettings
    var takeAction: (MediaSlide) -> Void
    /// Live transcode jobs for the active document. Rendered as a non-modal progress
    /// strip just above the transition controls so the operator sees them in context
    /// with the source slides without a modal sheet (Show Mode forbids modals per
    /// spec §3.5 — even in Edit Mode, a multi-minute ProRes export should not gate
    /// the operator's other work).
    var transcodeJobs: [TranscodeJob] = []
    /// Live image-sequence encode jobs (C5c). Same non-modal progress idiom as
    /// transcodes — the operator sees both kinds of "background ProRes work" stacked
    /// in one strip just above the transition controls.
    var encodeJobs: [ImageSequenceEncoder] = []
    /// Transcode menu enablement — passed `false` while the document is in Show Mode.
    var transcodeEnabled: Bool = true
    /// Asks the host to kick off a transcode for the source slide via the coordinator.
    var requestTranscode: (MediaSlide, TranscodePreset) -> Void = { _, _ in }
    /// Asks the host to cancel a running transcode.
    var cancelTranscode: (TranscodeJob) -> Void = { _ in }
    /// Asks the host to cancel a running image-sequence encode.
    var cancelEncode: (ImageSequenceEncoder) -> Void = { _ in }
    /// C9 — operator-triggered single-slide relink. Default no-op so existing call
    /// sites stay green; RootView wires an NSOpenPanel that picks one file and
    /// rewrites this slide's MediaReference to point at it (refreshing the
    /// fingerprint).
    var relinkSlide: (MediaSlide) -> Void = { _ in }
    /// C7d — current project bundle's `<bundle>/Media/` URL when one exists.
    /// Threaded into palette thumbnails and the right-click transcode gate so a
    /// moved bundle's managed assets resolve correctly.
    var bundleMediaDirectory: URL? = nil
    /// C10 — directory where the importer cached per-slide poster JPEGs.
    /// ThumbnailLoader falls back to `<dir>/<slide.id>.jpg` when the source
    /// asset is offline so the palette still renders. Default nil for
    /// previews / tests.
    var thumbnailCacheDirectory: URL? = nil

    private let columns = [
        GridItem(.adaptive(minimum: 148, maximum: 190), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Media Palette")
                    .font(.headline)
                Spacer()
                Text("\(slides.count)")
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            Group {
                if slides.isEmpty {
                    ContentUnavailableView("No Media", systemImage: "rectangle.stack.badge.plus")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                                SlideTile(
                                    number: index + 1,
                                    slide: slide,
                                    isSelected: selectedSlideID == slide.id,
                                    isLive: liveSlideID == slide.id,
                                    bundleMediaDirectory: bundleMediaDirectory,
                                    thumbnailCacheDirectory: thumbnailCacheDirectory
                                )
                                .onTapGesture {
                                    selectedSlideID = slide.id
                                    takeAction(slide)
                                }
                                .draggable(slide.id.uuidString)
                                .contextMenu {
                                    slideContextMenu(for: slide)
                                }
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !transcodeJobs.isEmpty || !encodeJobs.isEmpty {
                Divider()
                BackgroundJobsStrip(
                    transcodeJobs: transcodeJobs,
                    cancelTranscode: cancelTranscode,
                    encodeJobs: encodeJobs,
                    cancelEncode: cancelEncode
                )
            }

            Divider()

            PaletteTransitionControls(settings: $transitionSettings)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func slideContextMenu(for slide: MediaSlide) -> some View {
        if transcodeEnabled, TranscodeService.canTranscode(slide: slide, bundleMediaDirectory: bundleMediaDirectory) {
            ForEach(TranscodeService.preferredPresetOrder(for: slide), id: \.self) { preset in
                Button("Transcode to \(preset.label)") {
                    requestTranscode(slide, preset)
                }
            }
            Divider()
        }
        Button("Locate…") {
            relinkSlide(slide)
        }
    }
}

/// Non-modal progress strip rendered above the palette transition controls. One row
/// per running job — clip name, progress bar, percent, cancel. On completion the
/// coordinator removes the job from its list and the row disappears; the sibling
/// MediaSlide appears in the palette grid above as the splice lands. Operators reading
/// the palette at a glance can tell "X is transcoding" vs "X finished, here's the
/// sibling" without a modal sheet.
///
/// Renders both transcode jobs (C2) and image-sequence encodes (C5c) in one strip so
/// operators see all background ProRes work in one place. The two job types share the
/// same row visual; they differ only in the help text on the cancel button.
private struct BackgroundJobsStrip: View {
    let transcodeJobs: [TranscodeJob]
    let cancelTranscode: (TranscodeJob) -> Void
    let encodeJobs: [ImageSequenceEncoder]
    let cancelEncode: (ImageSequenceEncoder) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(transcodeJobs) { job in
                TranscodeProgressRow(job: job, cancel: { cancelTranscode(job) })
            }
            ForEach(encodeJobs) { job in
                ImageSequenceProgressRow(job: job, cancel: { cancelEncode(job) })
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct TranscodeProgressRow: View {
    @ObservedObject var job: TranscodeJob
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayLabel)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
            }
            Text(percentLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Cancel transcode")
        }
    }

    private var percentLabel: String {
        let pct = Int((job.progress * 100).rounded())
        return "\(pct)%"
    }
}

private struct ImageSequenceProgressRow: View {
    @ObservedObject var job: ImageSequenceEncoder
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayLabel)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
            }
            Text(percentLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Cancel image-sequence encode")
        }
    }

    private var percentLabel: String {
        let pct = Int((job.progress * 100).rounded())
        return "\(pct)%"
    }
}

private struct PaletteTransitionControls: View {
    @Binding var settings: PlayoutTransitionSettings
    @FocusState private var durationIsFocused: Bool

    private var duration: Binding<Double> {
        Binding {
            settings.crossfadeDuration
        } set: { value in
            settings.crossfadeDuration = PlayoutTransitionSettings.clampedDuration(value)
        }
    }

    private static let durationFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Crossfade", isOn: $settings.crossfadeEnabled)
                .toggleStyle(.switch)

            Slider(
                value: duration,
                in: PlayoutTransitionSettings.minimumDuration...PlayoutTransitionSettings.maximumDuration,
                step: 0.1
            )
                .frame(width: 96)

            TextField("Seconds", value: duration, formatter: Self.durationFormatter)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.callout.monospacedDigit())
                .frame(width: 56)
                .focused($durationIsFocused)
                .onSubmit {
                    durationIsFocused = false
                }

            Text("sec")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct SlideTile: View {
    var number: Int
    var slide: MediaSlide
    var isSelected: Bool
    var isLive: Bool
    var bundleMediaDirectory: URL?
    var thumbnailCacheDirectory: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                ThumbnailView(
                    slide: slide,
                    bundleMediaDirectory: bundleMediaDirectory,
                    thumbnailCacheDirectory: thumbnailCacheDirectory
                )
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("\(number)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(6)

                if isLive {
                    HStack(spacing: 4) {
                        Image(systemName: "record.circle.fill")
                        Text("Live")
                    }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.red, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(6)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: slide.mediaKind == .video ? "film" : "photo")
                    .foregroundStyle(.secondary)
                Text(slide.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout)
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isSelected ? 2 : 1)
        }
    }
}

private struct ThumbnailView: View {
    var slide: MediaSlide
    var bundleMediaDirectory: URL?
    var thumbnailCacheDirectory: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: slide.mediaKind == .video ? "film" : "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: slide.id) {
            image = await ThumbnailLoader.thumbnail(
                for: slide,
                bundleMediaDirectory: bundleMediaDirectory,
                thumbnailCacheDirectory: thumbnailCacheDirectory
            )
        }
    }
}

enum ThumbnailLoader {
    /// Best-effort thumbnail for a palette tile. Tries the live source URL
    /// first (existing behavior — generates from the actual asset). Falls
    /// back to the C10 cached `<thumbnailCacheDirectory>/<slide.id>.jpg`
    /// when the source is offline so a moved or relinked bundle still
    /// renders the palette.
    static func thumbnail(
        for slide: MediaSlide,
        bundleMediaDirectory: URL? = nil,
        thumbnailCacheDirectory: URL? = nil
    ) async -> NSImage? {
        if let live = await liveThumbnail(for: slide, bundleMediaDirectory: bundleMediaDirectory) {
            return live
        }
        return cachedThumbnail(for: slide, in: thumbnailCacheDirectory)
    }

    /// Locate the cached poster on disk if one exists. Synchronous — the
    /// JPEG is small enough that `NSImage(contentsOf:)` doesn't need to
    /// hop a queue.
    static func cachedThumbnail(for slide: MediaSlide, in directory: URL?) -> NSImage? {
        guard let directory else { return nil }
        let url = directory.appendingPathComponent("\(slide.id.uuidString).jpg")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    private static func liveThumbnail(for slide: MediaSlide, bundleMediaDirectory: URL?) async -> NSImage? {
        guard let url = slide.media.resolvedURL(bundleMediaDirectory: bundleMediaDirectory) else { return nil }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if slide.mediaKind == .image {
            return NSImage(contentsOf: url)
        }

        return await Task.detached(priority: .userInitiated) {
            let asset = AVAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 360)
            if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                return NSImage(cgImage: cgImage, size: .zero)
            }
            return nil
        }.value
    }
}
