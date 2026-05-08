import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Binding var document: SimplePlaybackDocument
    @ObservedObject var outputSettings: OutputSettingsStore
    @StateObject private var playback = PlaybackController()
    @StateObject private var showController: ShowControllerHolder
    @State private var selectedSlideID: UUID?
    @State private var selectedCueID: UUID?
    @State private var dropTargeted = false

    init(document: Binding<SimplePlaybackDocument>, outputSettings: OutputSettingsStore) {
        self._document = document
        self.outputSettings = outputSettings
        _showController = StateObject(wrappedValue: ShowControllerHolder())
    }

    private var selectedSlideBinding: Binding<MediaSlide>? {
        guard let selectedSlideID,
              let index = document.project.slides.firstIndex(where: { $0.id == selectedSlideID }) else {
            return nil
        }
        return $document.project.slides[index]
    }

    private var selectedCueBinding: Binding<Cue>? {
        guard let selectedCueID,
              let listIdx = activeShowListIndex,
              let cueIdx = document.project.showLists[listIdx].cues.firstIndex(where: { $0.id == selectedCueID }) else {
            return nil
        }
        return $document.project.showLists[listIdx].cues[cueIdx]
    }

    private var activeShowListIndex: Int? {
        guard let id = document.project.activeShowListID else {
            return document.project.showLists.indices.first
        }
        return document.project.showLists.firstIndex(where: { $0.id == id })
    }

    var body: some View {
        Group {
            if let controller = showController.controller {
                mainLayout(controller: controller)
            } else {
                ProgressView("Preparing show…")
                    .frame(minWidth: 980, minHeight: 640)
                    .onAppear {
                        configureShowController()
                    }
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    openMediaPanel()
                } label: {
                    Label("Add Media", systemImage: "plus")
                }
                .disabled(showController.controller?.showMode == true)

                Button(role: .destructive) {
                    deleteSelectedSlide()
                } label: {
                    Label("Delete Slide", systemImage: "trash")
                }
                .disabled(selectedSlideID == nil || showController.controller?.showMode == true)

                Spacer()

                Toggle(isOn: showModeBinding) {
                    Label(
                        showController.controller?.showMode == true ? "Show Mode" : "Edit Mode",
                        systemImage: showController.controller?.showMode == true ? "lock.fill" : "pencil"
                    )
                }
                .toggleStyle(.button)
                .help("Toggle Show Mode (Cmd-Shift-L) — disables destructive shortcuts and editing")
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
        .onAppear {
            playback.refreshDevices()
            applyOutputDefaults()
            ensureProjectHasShowList()
            configureShowController()
        }
        .onChange(of: playback.devices) {
            applyOutputDefaults()
        }
        .onChange(of: outputSettings.selectedDeviceID) {
            playback.refreshDevices()
            outputSettings.applyDefaults(using: playback)
        }
        .onChange(of: document.project.activeShowListID) {
            syncActiveShowList()
        }
        .onChange(of: activeShowListSnapshot) {
            syncActiveShowList()
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

    @ViewBuilder
    private func mainLayout(controller: ShowController) -> some View {
        HSplitView {
            SlideGridView(
                slides: $document.project.slides,
                selectedSlideID: $selectedSlideID,
                liveSlideID: playback.liveSlideID,
                transitionSettings: $document.project.transitionSettings,
                takeAction: takeSlide
            )
            .frame(minWidth: 320, idealWidth: 460)

            ShowListView(
                showController: controller,
                project: $document.project,
                selectedCueID: $selectedCueID
            )
            .frame(minWidth: 280, idealWidth: 360)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Spacer()

                    Button {
                        clearOutput()
                    } label: {
                        Label("Clear Output", systemImage: "stop.circle")
                    }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!playback.isRunning)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)

                OutputPreviewView(playback: playback)

                OutputStatusBar(playback: playback)

                Divider()

                if let selectedCueBinding {
                    CueInspectorView(
                        cue: selectedCueBinding,
                        slides: document.project.slides,
                        stageFPS: document.project.stages.first?.framesPerSecond
                    )
                } else if let selectedSlideBinding {
                    InspectorView(slide: selectedSlideBinding)
                } else {
                    InspectorPlaceholder()
                }
            }
            .frame(minWidth: 320, idealWidth: 380)
        }
    }

    private var showModeBinding: Binding<Bool> {
        Binding {
            showController.controller?.showMode ?? false
        } set: { newValue in
            showController.controller?.showMode = newValue
        }
    }

    /// Lightweight snapshot used to detect when the active show list's contents change so the
    /// runtime can re-sync. Watches the cue IDs and playhead.
    private var activeShowListSnapshot: ShowListSnapshot? {
        guard let idx = activeShowListIndex else { return nil }
        let list = document.project.showLists[idx]
        return ShowListSnapshot(
            id: list.id,
            playheadCueID: list.playheadCueID,
            cueIDs: list.cues.map(\.id),
            cueNumbers: list.cues.map(\.number)
        )
    }

    private func ensureProjectHasShowList() {
        if document.project.showLists.isEmpty {
            document.project.markCurrentFormatVersion()
        }
    }

    private func configureShowController() {
        guard let activeList = document.project.activeShowList else { return }
        if showController.controller == nil {
            let docBinding = $document
            showController.controller = ShowController(
                showList: activeList,
                playback: playback,
                assetLookup: { [docBinding] id in
                    docBinding.wrappedValue.project.slides.first(where: { $0.id == id })
                },
                transitionSettings: { [docBinding] in
                    docBinding.wrappedValue.project.transitionSettings
                },
                outputBinding: { [outputSettings] in
                    (outputSettings.selectedDeviceID, outputSettings.selectedModeID)
                }
            )
        }
    }

    private func syncActiveShowList() {
        guard let controller = showController.controller,
              let activeList = document.project.activeShowList else { return }
        controller.syncShowListFromProject(activeList)
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
        guard !(showController.controller?.showMode ?? false) else { return }
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
        showController.controller?.clear()
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
        guard !(showController.controller?.showMode ?? false) else { return }
        let imported = MediaImporter.importSlides(from: urls)
        guard !imported.isEmpty else { return }
        document.project.slides.append(contentsOf: imported)
        selectedSlideID = imported.last?.id
    }
}

/// SwiftUI `@StateObject` requires the wrapped value to be initialized eagerly, but our
/// `ShowController` needs callbacks that close over the document binding (only available
/// inside `body`). We wrap the optional in this small holder so the controller can be
/// created lazily once the document/playback are ready.
@MainActor
final class ShowControllerHolder: ObservableObject {
    @Published var controller: ShowController?
}

/// Cheap-to-compare snapshot used by the active-show-list change detector.
private struct ShowListSnapshot: Equatable {
    let id: UUID
    let playheadCueID: UUID?
    let cueIDs: [UUID]
    let cueNumbers: [String]
}

private struct InspectorPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.and.text.magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Select a cue or asset to inspect")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

/// Inspector for a selected cue: number, title, continuation, pre/post-wait, notes.
private struct CueInspectorView: View {
    @Binding var cue: Cue
    let slides: [MediaSlide]
    let stageFPS: Double?

    private var asset: MediaSlide? {
        slides.first(where: { $0.id == cue.assetID })
    }

    private var assetTitle: String {
        asset?.title ?? "(missing media)"
    }

    private var conformance: FrameRateConformance? {
        guard let asset, asset.mediaKind == .video, let stageFPS else { return nil }
        return FrameRateConformance(clipFPS: asset.nativeFrameRate, stageFPS: stageFPS)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Cue")
                    .font(.headline)

                LabeledContent("Number") {
                    TextField("Number", text: $cue.number)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                LabeledContent("Title") {
                    TextField("Title", text: $cue.title)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent("Asset") {
                    Text(assetTitle)
                        .foregroundStyle(.secondary)
                }

                if let conformance, conformance.severity == .mismatch {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(conformance.summary)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.orange.opacity(0.12))
                    )
                    .help("Right-click in the asset library → Transcode to ProRes 422 to render a Stage-rate copy.")
                }

                Divider()

                Picker("Continuation", selection: $cue.continuation) {
                    ForEach(CueContinuation.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent("Pre-wait") {
                    TimeIntervalField(value: $cue.preWait)
                }

                LabeledContent("Post-wait") {
                    TimeIntervalField(value: $cue.postWait)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes")
                        .font(.subheadline.bold())
                    TextEditor(text: $cue.notes)
                        .font(.callout)
                        .frame(minHeight: 80, maxHeight: 200)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                }
            }
            .padding(16)
        }
    }
}

private struct TimeIntervalField: View {
    @Binding var value: TimeInterval

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 2
        f.minimum = 0
        return f
    }()

    var body: some View {
        HStack(spacing: 6) {
            TextField("Seconds", value: $value, formatter: Self.formatter)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospacedDigit())
                .frame(width: 64)
            Text("sec")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
