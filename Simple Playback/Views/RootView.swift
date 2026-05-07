import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Binding var document: SimplePlaybackDocument
    @ObservedObject var outputSettings: OutputSettingsStore
    @StateObject private var playback = PlaybackController()
    @State private var selectedSlideID: UUID?
    @State private var dropTargeted = false

    private var selectedSlideBinding: Binding<MediaSlide>? {
        guard let selectedSlideID,
              let index = document.project.slides.firstIndex(where: { $0.id == selectedSlideID }) else {
            return nil
        }
        return $document.project.slides[index]
    }

    var body: some View {
        HStack(spacing: 0) {
            SlideGridView(
                slides: $document.project.slides,
                selectedSlideID: $selectedSlideID,
                liveSlideID: playback.liveSlideID,
                transitionSettings: $document.project.transitionSettings,
                takeAction: takeSlide
            )
            .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Spacer()

                    Button {
                        clearOutput()
                    } label: {
                        Label("Clear Output", systemImage: "stop.circle")
                    }
                    .disabled(!playback.isRunning)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)

                OutputPreviewView(playback: playback)

                OutputStatusBar(playback: playback)

                Divider()

                InspectorView(slide: selectedSlideBinding)
            }
            .frame(width: 360)
        }
        .frame(minWidth: 980, minHeight: 640)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    openMediaPanel()
                } label: {
                    Label("Add Media", systemImage: "plus")
                }

                Button(role: .destructive) {
                    deleteSelectedSlide()
                } label: {
                    Label("Delete Slide", systemImage: "trash")
                }
                .disabled(selectedSlideID == nil)

            }
        }
        .onAppear {
            playback.refreshDevices()
            applyOutputDefaults()
        }
        .onChange(of: playback.devices) {
            applyOutputDefaults()
        }
        .onChange(of: outputSettings.selectedDeviceID) {
            playback.refreshDevices()
            outputSettings.applyDefaults(using: playback)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    private func applyOutputDefaults() {
        outputSettings.applyDefaults(using: playback)
    }

    private func takeSlide(_ slide: MediaSlide) {
        if let selectedDeviceID = outputSettings.selectedDeviceID,
           !playback.devices.contains(where: { $0.id == selectedDeviceID }) {
            playback.refreshDevices()
            outputSettings.applyDefaults(using: playback)
        }

        playback.take(
            slide: slide,
            deviceID: outputSettings.selectedDeviceID,
            modeID: outputSettings.selectedModeID,
            transitionSettings: document.project.transitionSettings
        )
    }

    private func deleteSelectedSlide() {
        guard let selectedSlideID,
              let index = document.project.slides.firstIndex(where: { $0.id == selectedSlideID }) else {
            return
        }
        document.project.slides.remove(at: index)
        self.selectedSlideID = document.project.slides.indices.contains(index)
            ? document.project.slides[index].id
            : document.project.slides.last?.id
    }

    private func clearOutput() {
        playback.clear()
    }

    private func openMediaPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie, .video]
        if panel.runModal() == .OK {
            addMedia(panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsurl = item as? NSURL {
                    url = nsurl as URL
                } else {
                    url = nil
                }

                guard let url else { return }
                DispatchQueue.main.async {
                    addMedia([url])
                }
            }
        }
        return true
    }

    private func addMedia(_ urls: [URL]) {
        let imported = MediaImporter.importSlides(from: urls)
        guard !imported.isEmpty else { return }
        document.project.slides.append(contentsOf: imported)
        selectedSlideID = imported.last?.id
    }
}
