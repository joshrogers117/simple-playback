import AVFoundation
import SwiftUI

struct SlideGridView: View {
    @Binding var slides: [MediaSlide]
    @Binding var selectedSlideID: UUID?
    var liveSlideID: UUID?
    @Binding var transitionSettings: PlayoutTransitionSettings
    var takeAction: (MediaSlide) -> Void

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
                                    isLive: liveSlideID == slide.id
                                )
                                .onTapGesture {
                                    selectedSlideID = slide.id
                                    takeAction(slide)
                                }
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            PaletteTransitionControls(settings: $transitionSettings)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                ThumbnailView(slide: slide)
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
            image = await ThumbnailLoader.thumbnail(for: slide)
        }
    }
}

private enum ThumbnailLoader {
    static func thumbnail(for slide: MediaSlide) async -> NSImage? {
        guard let url = slide.media.resolvedURL() else { return nil }
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
