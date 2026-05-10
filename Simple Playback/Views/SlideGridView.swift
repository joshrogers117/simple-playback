import AppKit
import AVFoundation
import SwiftUI

/// Pure-SwiftUI slider with a flat dark track + lighter fill from the left
/// edge to the thumb. Used in place of `Slider` so the appearance can be
/// fully controlled (the system slider draws a bright unfilled track in dark
/// mode that can't be hidden via `.tint`).
struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0.1

    private let trackHeight: CGFloat = 5
    private let thumbDiameter: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let span = range.upperBound - range.lowerBound
            let normalized = span > 0
                ? max(0, min(1, (value - range.lowerBound) / span))
                : 0
            let usableWidth = max(0, width - thumbDiameter)
            let thumbX = thumbDiameter / 2 + usableWidth * CGFloat(normalized)

            ZStack(alignment: .leading) {
                // Unfilled track (dark)
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color(white: 0.28))
                    .frame(height: trackHeight)
                    .padding(.horizontal, thumbDiameter / 2)

                // Filled portion (lighter, left → thumb)
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color(white: 0.55))
                    .frame(width: max(0, thumbX - thumbDiameter / 2), height: trackHeight)
                    .padding(.leading, thumbDiameter / 2)

                // Thumb
                Circle()
                    .fill(Color(white: 0.85))
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: Color.black.opacity(0.4), radius: 1.5, y: 1)
                    .offset(x: thumbX - thumbDiameter / 2)
            }
            .frame(height: max(trackHeight, thumbDiameter))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let clampedX = max(0, min(usableWidth, drag.location.x - thumbDiameter / 2))
                        let proposed = range.lowerBound + Double(clampedX / max(usableWidth, 1)) * span
                        let snapped = step > 0
                            ? (proposed / step).rounded() * step
                            : proposed
                        let clamped = max(range.lowerBound, min(range.upperBound, snapped))
                        if abs(value - clamped) > 0.0001 {
                            value = clamped
                        }
                    }
            )
        }
    }
}

/// NSSlider wrapper with a custom-drawn track: a slightly taller bar that
/// fills from the left as the value increases. Replaces the system slider's
/// bright white default fill (which clashed with the dark theme) with a
/// muted accent fill.
struct TracklessSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0.1

    func makeCoordinator() -> Coordinator { Coordinator(value: $value, step: step) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        let cell = TracklessSliderCell()
        cell.minValue = range.lowerBound
        cell.maxValue = range.upperBound
        cell.doubleValue = value
        cell.isContinuous = true
        slider.cell = cell
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        context.coordinator.step = step
        if abs(slider.doubleValue - value) > 0.0001 {
            slider.doubleValue = value
        }
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
    }

    final class Coordinator {
        var value: Binding<Double>
        var step: Double
        init(value: Binding<Double>, step: Double) {
            self.value = value
            self.step = step
        }

        @objc func changed(_ sender: NSSlider) {
            let raw = sender.doubleValue
            let snapped = step > 0 ? (raw / step).rounded() * step : raw
            if snapped != sender.doubleValue {
                sender.doubleValue = snapped
            }
            value.wrappedValue = snapped
        }
    }
}

/// NSSliderCell that paints a dark unfilled track and a brighter "filled"
/// portion from the left edge to the thumb. Slightly taller (5 pt) than
/// the system default for better hit feedback.
private final class TracklessSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let trackHeight: CGFloat = 5
        let trackRect = NSRect(
            x: rect.minX,
            y: rect.midY - trackHeight / 2,
            width: rect.width,
            height: trackHeight
        )
        let radius = trackHeight / 2

        // Unfilled track (dark gray)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius)
        NSColor(white: 0.28, alpha: 1.0).setFill()
        trackPath.fill()

        // Filled portion (left → current value)
        let total = maxValue - minValue
        guard total > 0 else { return }
        let progress = max(0, min(1, (doubleValue - minValue) / total))
        guard progress > 0 else { return }
        let filledRect = NSRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: trackRect.width * CGFloat(progress),
            height: trackRect.height
        )
        let filledPath = NSBezierPath(roundedRect: filledRect, xRadius: radius, yRadius: radius)
        NSColor(white: 0.55, alpha: 1.0).setFill()
        filledPath.fill()
    }
}

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
    /// C8 v1.1 — id → `FolderBookmark` lookup mirroring the project's
    /// folder-bookmark registry. Threaded into palette thumbnails (so a
    /// folder-renamed source still renders its live thumbnail via rung-2)
    /// and the right-click transcode gate (so the same source still offers
    /// the Transcode menu).
    var folderBookmarks: [UUID: FolderBookmark] = [:]
    /// C10 — directory where the importer cached per-slide poster JPEGs.
    /// ThumbnailLoader falls back to `<dir>/<slide.id>.jpg` when the source
    /// asset is offline so the palette still renders. Default nil for
    /// previews / tests.
    var thumbnailCacheDirectory: URL? = nil
    /// Operator-triggered "Add Media" action. Surfaced from the empty-state
    /// CTA so a fresh project can start the import flow without hunting in
    /// the toolbar. Default no-op for previews / tests.
    var addMediaAction: () -> Void = {}
    /// Operator-triggered "Add Folder" action. Same empty-state CTA story
    /// as `addMediaAction` — shown only when the palette has no slides yet.
    var addFolderAction: () -> Void = {}

    private let columns = [
        GridItem(.adaptive(minimum: 148, maximum: 190), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                    .foregroundStyle(.secondary)
                Text("Media Palette")
                    .font(.headline)
                Spacer()
                if !slides.isEmpty {
                    Text("\(slides.count) \(slides.count == 1 ? "clip" : "clips")")
                        .foregroundStyle(.secondary)
                        .font(.callout.monospacedDigit())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            Group {
                if slides.isEmpty {
                    emptyState
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
                                    folderBookmarks: folderBookmarks,
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
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Media Yet", systemImage: "rectangle.stack.badge.plus")
        } description: {
            Text("Drop clips, images, or PDFs here — or use the buttons below. Click any thumbnail to send it to output, or drag onto the cue list to build cues.")
        } actions: {
            HStack(spacing: 10) {
                Button {
                    addMediaAction()
                } label: {
                    Label("Add Media", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    addFolderAction()
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func slideContextMenu(for slide: MediaSlide) -> some View {
        if transcodeEnabled, TranscodeService.canTranscode(
            slide: slide,
            bundleMediaDirectory: bundleMediaDirectory,
            folderBookmarks: folderBookmarks
        ) {
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
    @State private var isEditing: Bool = false
    @State private var editBuffer: String = ""
    /// Local mirror driven by the slider during drag — Slider/binding round-
    /// trips through @Binding don't propagate to dependent views during a
    /// continuous drag, so the Text below reads off this @State instead.
    @State private var liveDuration: Double = 0.5

    private func formatDuration(_ value: Double) -> String {
        Self.durationFormatter.string(from: NSNumber(value: value))
            ?? String(format: "%.1f", value)
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
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            CustomSlider(
                value: $liveDuration,
                range: PlayoutTransitionSettings.minimumDuration...PlayoutTransitionSettings.maximumDuration,
                step: 0.1
            )
                .frame(width: 96, height: 16)

            durationField

            Text("sec")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear {
            liveDuration = settings.crossfadeDuration
        }
        .onChange(of: liveDuration) { _, newValue in
            let clamped = PlayoutTransitionSettings.clampedDuration(newValue)
            if abs(settings.crossfadeDuration - clamped) > 0.0001 {
                settings.crossfadeDuration = clamped
            }
        }
        .onChange(of: settings.crossfadeDuration) { _, newValue in
            if abs(liveDuration - newValue) > 0.0001 {
                liveDuration = newValue
            }
        }
    }

    @ViewBuilder
    private var durationField: some View {
        if isEditing {
            TextField("Seconds", text: $editBuffer)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.callout.monospacedDigit())
                .frame(width: 56)
                .focused($durationIsFocused)
                .onSubmit { commitEdit() }
                .onChange(of: durationIsFocused) { _, focused in
                    if !focused { commitEdit() }
                }
                .onAppear {
                    durationIsFocused = true
                }
        } else {
            Text(formatDuration(liveDuration))
                .font(.callout.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 56, alignment: .trailing)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    editBuffer = formatDuration(liveDuration)
                    isEditing = true
                }
        }
    }

    private func commitEdit() {
        if let parsed = Self.durationFormatter.number(from: editBuffer)?.doubleValue {
            let clamped = PlayoutTransitionSettings.clampedDuration(parsed)
            settings.crossfadeDuration = clamped
            liveDuration = clamped
        }
        isEditing = false
    }
}

private struct SlideTile: View {
    var number: Int
    var slide: MediaSlide
    var isSelected: Bool
    var isLive: Bool
    var bundleMediaDirectory: URL?
    var folderBookmarks: [UUID: FolderBookmark] = [:]
    var thumbnailCacheDirectory: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                ThumbnailView(
                    slide: slide,
                    bundleMediaDirectory: bundleMediaDirectory,
                    folderBookmarks: folderBookmarks,
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
    var folderBookmarks: [UUID: FolderBookmark] = [:]
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
                folderBookmarks: folderBookmarks,
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
        folderBookmarks: [UUID: FolderBookmark] = [:],
        thumbnailCacheDirectory: URL? = nil
    ) async -> NSImage? {
        if let live = await liveThumbnail(
            for: slide,
            bundleMediaDirectory: bundleMediaDirectory,
            folderBookmarks: folderBookmarks
        ) {
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

    private static func liveThumbnail(
        for slide: MediaSlide,
        bundleMediaDirectory: URL?,
        folderBookmarks: [UUID: FolderBookmark]
    ) async -> NSImage? {
        guard let url = slide.media.resolvedURL(
            bundleMediaDirectory: bundleMediaDirectory,
            folderBookmarks: folderBookmarks
        ) else { return nil }
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
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 360)
            if let result = try? await generator.image(at: .zero) {
                return NSImage(cgImage: result.image, size: .zero)
            }
            return nil
        }.value
    }
}
