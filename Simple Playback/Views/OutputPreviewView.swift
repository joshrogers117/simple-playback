import AVKit
import SwiftUI

struct OutputPreviewView: View {
    @ObservedObject var playback: PlaybackController
    @State private var isScrubbing = false
    @State private var scrubTime = 0.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tv")
                    .foregroundStyle(.secondary)
                Text("Program")
                    .font(.headline)
                if !playback.liveTitle.isEmpty {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(playback.liveTitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            ZStack {
                Rectangle()
                    .fill(.black)

                if let outputImage = playback.transitionPreviewImage {
                    Image(decorative: outputImage, scale: 1.0, orientation: .downMirrored)
                        .resizable()
                        .scaledToFit()
                } else if let image = playback.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "rectangle")
                        .font(.system(size: 54))
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .padding(18)

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text(formatTime(displayTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)

                    Slider(
                        value: scrubBinding,
                        in: 0...max(playback.videoDuration, 0.1),
                        onEditingChanged: handleScrubEditing
                    )
                    .disabled(playback.videoDuration <= 0)

                    Text(formatTime(playback.videoDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                }

                HStack(spacing: 28) {
                    Button {
                        playback.jumpVideo(by: -10)
                    } label: {
                        Image(systemName: "gobackward.10")
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.borderless)

                    Button {
                        playback.togglePlayback()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22))
                    }
                    .buttonStyle(.borderless)

                    Button {
                        playback.jumpVideo(by: 10)
                    } label: {
                        Image(systemName: "goforward.10")
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.borderless)
                }
                .frame(height: 28)
                .disabled(playback.videoDuration <= 0)
            }
            .opacity(playback.videoDuration > 0 ? 1 : 0.0)
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var displayTime: Double {
        min(isScrubbing ? scrubTime : playback.videoCurrentTime, playback.videoDuration)
    }

    private var scrubBinding: Binding<Double> {
        Binding {
            displayTime
        } set: { value in
            scrubTime = value
            playback.seekVideo(to: value, syncAudio: false)
        }
    }

    private func handleScrubEditing(_ editing: Bool) {
        if editing {
            isScrubbing = true
            scrubTime = playback.videoCurrentTime
        } else {
            isScrubbing = false
            playback.seekVideo(to: scrubTime, syncAudio: true)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let rounded = max(0, Int(seconds.rounded()))
        return "\(rounded / 60):\(String(format: "%02d", rounded % 60))"
    }
}

private struct PlayerPreviewSurface: NSViewRepresentable {
    var player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.controlsStyle = .none
        view.player = player
    }
}
