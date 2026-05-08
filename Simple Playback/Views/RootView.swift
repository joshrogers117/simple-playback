import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Binding var document: SimplePlaybackDocument
    @ObservedObject var outputSettings: OutputSettingsStore
    @StateObject private var playback = PlaybackController()
    @StateObject private var showController: ShowControllerHolder
    @StateObject private var transcodeCoordinator = TranscodeCoordinator()
    @StateObject private var encodeCoordinator = ImageSequenceEncodeCoordinator()
    @StateObject private var importStatus = ImportStatusBanner()
    /// E3 — append-only show log for this document. Wired into ShowController
    /// after configuration so every verb (GO/PANIC/CLEAR/BLACKOUT/Show-Mode)
    /// records to the journal. Persistence destination is set in
    /// `bindShowLogFile()` once the document has a bundle URL.
    @StateObject private var showLog = ShowLog()
    @State private var selectedSlideID: UUID?
    @State private var selectedCueID: UUID?
    @State private var dropTargeted = false
    @State private var inspectorMode: InspectorMode = .selection
    /// Set when the operator picks a folder via Add Folder…  and the C5c walk + detect
    /// completes. Drives the modal sheet that asks for per-sequence frame rates before
    /// kicking off ProRes 4444 encodes.
    @State private var pendingFolderImport: PendingFolderImport?
    /// Toggle for the Phase E1 pre-show check sheet. The rows are computed on demand
    /// when the sheet opens (cheap — pure-logic over the project + sampled signals).
    @State private var preShowCheckPresented: Bool = false
    /// Stable per-window UUID. Untitled documents — which have no fileURL yet —
    /// rasterize PDFs (and transcode to ProRes) into an app-support subdirectory keyed
    /// by this ID so concurrent untitled windows don't collide.
    @State private var untitledSessionID = UUID()

    /// Returns the current document's bundle URL, or `nil` for an untitled document.
    /// Driven by `SimplePlaybackProjectDocument.fileURL`. RootView only reads this when
    /// it needs to write rasterized imports into the bundle (C3 PDF import today).
    private let projectBundleURLProvider: () -> URL?

    init(
        document: Binding<SimplePlaybackDocument>,
        outputSettings: OutputSettingsStore,
        projectBundleURLProvider: @escaping () -> URL? = { nil }
    ) {
        self._document = document
        self.outputSettings = outputSettings
        self.projectBundleURLProvider = projectBundleURLProvider
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

                Button {
                    openFolderPanel()
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
                .help("Walk a folder for image sequences, then encode each as ProRes 4444.")
                .disabled(showController.controller?.showMode == true)

                Button(role: .destructive) {
                    deleteSelectedSlide()
                } label: {
                    Label("Delete Slide", systemImage: "trash")
                }
                .disabled(selectedSlideID == nil || showController.controller?.showMode == true)

                Button {
                    preShowCheckPresented = true
                } label: {
                    Label("Pre-Show", systemImage: "checklist")
                }
                .help("Run the pre-show check — media resolution, frame-rate conformance, output, system signals.")

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
        .onChange(of: document.project.stages.first?.compositorOverlays) {
            syncCompositorOverlays()
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
        .sheet(isPresented: $preShowCheckPresented) {
            PreShowCheckView(
                rows: PreShowCheck.evaluate(
                    project: document.project,
                    context: preShowCheckContext()
                ),
                fixHandlers: preShowCheckFixHandlers(),
                onClose: { preShowCheckPresented = false }
            )
        }
        .sheet(item: $pendingFolderImport) { _ in
            // The closure parameter is read-only; we drive the sheet from the @State so
            // edits flow through the binding. The wrapper view keeps the binding non-nil
            // for the sheet's lifetime.
            if let binding = pendingFolderImportBinding {
                AddFolderImportSheet(
                    pending: binding,
                    onConfirm: { confirmed in
                        confirmFolderImport(confirmed)
                        pendingFolderImport = nil
                    },
                    onCancel: { pendingFolderImport = nil }
                )
            }
        }
    }

    private var pendingFolderImportBinding: Binding<PendingFolderImport>? {
        guard pendingFolderImport != nil else { return nil }
        return Binding(
            get: { pendingFolderImport ?? PendingFolderImport(folderURL: URL(fileURLWithPath: "/"), plan: .empty) },
            set: { pendingFolderImport = $0 }
        )
    }

    @ViewBuilder
    private func mainLayout(controller: ShowController) -> some View {
        HSplitView {
            SlideGridView(
                slides: $document.project.slides,
                selectedSlideID: $selectedSlideID,
                liveSlideID: playback.liveSlideID,
                transitionSettings: $document.project.transitionSettings,
                takeAction: takeSlide,
                transcodeJobs: transcodeCoordinator.jobs,
                encodeJobs: encodeCoordinator.jobs,
                transcodeEnabled: !(showController.controller?.showMode ?? false),
                requestTranscode: { slide, preset in
                    requestTranscode(slide: slide, preset: preset)
                },
                cancelTranscode: { job in
                    job.cancel()
                },
                cancelEncode: { job in
                    job.cancel()
                }
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

                ImportStatusBannerView(banner: importStatus)

                OutputStatusBar(
                    playback: playback,
                    referenceExpected: document.project.expectsExternalReference
                )

                Divider()

                inspectorModePicker

                Divider().padding(.top, 8)

                inspectorContent
            }
            .frame(minWidth: 320, idealWidth: 380)
        }
    }

    @ViewBuilder
    private var inspectorModePicker: some View {
        Picker("Inspector", selection: $inspectorMode) {
            ForEach(InspectorMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch inspectorMode {
        case .selection:
            selectionInspector
        case .overlays:
            overlaysInspector
        case .output:
            OutputInspectorView(project: $document.project)
        }
    }

    @ViewBuilder
    private var selectionInspector: some View {
        if let selectedCueBinding {
            CueInspectorView(
                cue: selectedCueBinding,
                slides: document.project.slides,
                stageFPS: document.project.stages.first?.framesPerSecond,
                showMode: showController.controller?.showMode ?? false,
                requestTranscode: { slide, preset in
                    requestTranscode(slide: slide, preset: preset)
                }
            )
        } else if let selectedSlideBinding {
            InspectorView(slide: selectedSlideBinding)
        } else {
            InspectorPlaceholder()
        }
    }

    @ViewBuilder
    private var overlaysInspector: some View {
        if let overlaysBinding = firstStageOverlaysBinding {
            OverlayInspectorView(overlays: overlaysBinding)
        } else {
            InspectorPlaceholder(message: "Save the project to initialize the Stage.")
        }
    }

    private var firstStageOverlaysBinding: Binding<CompositorOverlays>? {
        guard !document.project.stages.isEmpty else { return nil }
        return Binding(
            get: { document.project.stages[0].compositorOverlays },
            set: { document.project.stages[0].compositorOverlays = $0 }
        )
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
            showController.controller?.showLog = showLog
            bindShowLogFile()
        }
        syncCompositorOverlays()
    }

    /// Bind the show-log writer to a path inside the project bundle when one
    /// exists. Untitled documents have no bundle on disk yet — events stay
    /// in memory until the operator saves. Idempotent.
    private func bindShowLogFile() {
        guard let bundleURL = projectBundleURLProvider() else { return }
        let logsURL = bundleURL.appendingPathComponent("Logs", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let stamped = formatter.string(from: Date())
        let logFileURL = logsURL.appendingPathComponent("\(stamped).log")
        showLog.setFileURL(logFileURL)
    }

    private func syncActiveShowList() {
        guard let controller = showController.controller,
              let activeList = document.project.activeShowList else { return }
        controller.syncShowListFromProject(activeList)
    }

    private func syncCompositorOverlays() {
        guard let controller = showController.controller else { return }
        let overlays = document.project.stages.first?.compositorOverlays ?? .empty
        controller.applyCompositorOverlays(overlays)
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
        var types: [UTType] = [.image, .movie, .video, .pdf]
        if let keynote = UTType("com.apple.iwork.keynote.key") {
            types.append(keynote)
        }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK {
            addMedia(panel.urls)
        }
    }

    /// Builds the pre-show check Context with whatever signals the host can sample
    /// synchronously without blocking the UI. Today: free disk space at the project
    /// bundle's enclosing volume (or the app-support fallback for untitled documents);
    /// the DeckLink reference state PlaybackController already exposes for the B6/B6b
    /// status-bar chip; and the CoreAudio default-output-device probe.
    private func preShowCheckContext() -> PreShowCheck.Context {
        var ctx = PreShowCheck.Context()
        let probeURL = projectBundleURLProvider() ?? RootView.untitledRenderRoot
        if let values = try? probeURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let bytes = values.volumeAvailableCapacity {
            ctx.availableDiskBytes = Int64(bytes)
        }
        if let live = playback.deckLinkReferenceState {
            ctx.deckLinkReferenceStatus = .from(live)
        }
        ctx.audioDeviceAvailable = AudioDeviceProbe.isDefaultOutputDeviceAvailable()
        ctx.renderPathWarmed = playback.hasRenderedAnyFrame
        return ctx
    }

    /// Build the per-row fix-action handler dictionary the Pre-Show sheet uses.
    /// Each id maps to a single closure; rows without an entry render no Fix
    /// button. Handlers stay simple (one deep-link / Finder-reveal each) so
    /// the resolution path is easy for the operator to understand at a glance.
    private func preShowCheckFixHandlers() -> PreShowCheckFixHandlers {
        var handlers = PreShowCheckFixHandlers()

        // system.audio — open System Settings → Sound. Same deep-link as
        // standalone "no audio device" rescue.
        handlers.byRowID["system.audio"] = {
            NSWorkspace.shared.open(PreShowFixDeepLinks.soundSettings)
        }

        // system.disk — reveal the project bundle in Finder so the operator
        // can clean up locally. For untitled documents (no bundle on disk
        // yet) the Save-As affordance is the right answer; we suppress the
        // Fix button in that case.
        if let bundleURL = projectBundleURLProvider() {
            handlers.byRowID["system.disk"] = {
                NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
            }
        }

        // output.reference — open Blackmagic Desktop Video Setup if installed.
        // That's where REF/format/output configuration lives. Skip the Fix
        // button entirely if the app isn't on disk; the operator's path is
        // hardware-side (plug in a REF cable) and we'd rather show no Fix
        // than a dead button.
        let dvsPath = PreShowFixDeepLinks.blackmagicDesktopVideoSetupAppPath
        if FileManager.default.fileExists(atPath: dvsPath) {
            let dvsURL = URL(fileURLWithPath: dvsPath)
            handlers.byRowID["output.reference"] = {
                NSWorkspace.shared.open(dvsURL)
            }
        }

        return handlers
    }

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Folder"
        if panel.runModal() == .OK, let url = panel.url {
            presentFolderImport(at: url)
        }
    }

    /// Walk the chosen folder and present the confirm sheet. If the walk itself fails
    /// (folder unreadable), surface via the import-status banner — it's the same uniform
    /// non-modal failure surface as PDF/Keynote/transcode errors.
    private func presentFolderImport(at folderURL: URL) {
        guard !(showController.controller?.showMode ?? false) else { return }
        do {
            let plan = try AddFolderImporter.plan(folderURL: folderURL)
            pendingFolderImport = PendingFolderImport(folderURL: folderURL, plan: plan)
        } catch {
            importStatus.record([
                MediaImportFailure(
                    url: folderURL,
                    kind: .unsupportedMedia,
                    summary: "Could not read folder \(folderURL.lastPathComponent): \(error.localizedDescription)"
                )
            ])
        }
    }

    /// Operator pressed Encode in the sheet. Kick off one encode job per sequence with
    /// the operator-supplied frame rate, and import the standalone files via the
    /// existing media-importer path.
    private func confirmFolderImport(_ confirmed: PendingFolderImport) {
        if !confirmed.standaloneMediaURLs.isEmpty {
            addMedia(confirmed.standaloneMediaURLs)
        }

        let dest = transcodedRootDirectory()
        for plan in confirmed.encodableSequences {
            encodeCoordinator.encode(
                sequence: plan.sequence,
                frameRate: plan.frameRate,
                destinationDirectory: dest
            ) { [self] result in
                switch result {
                case .success(let outcome):
                    document.project.slides.append(outcome.siblingSlide)
                    selectedSlideID = outcome.siblingSlide.id
                case .failure(let error):
                    if case .cancelled = error { return }
                    importStatus.record([
                        MediaImportFailure(
                            url: plan.sequence.frameURLs.first,
                            kind: .transcode,
                            summary: error.errorDescription ?? "Image-sequence encode failed"
                        )
                    ])
                }
            }
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
        let context = currentMediaImportContext()
        let report = MediaImporter.importSlidesAndReport(from: urls, context: context)
        importStatus.record(report.failures)
        guard !report.slides.isEmpty else { return }
        document.project.slides.append(contentsOf: report.slides)
        selectedSlideID = report.slides.last?.id
    }

    /// Builds the per-import context the importer needs for source formats that require
    /// conversion (PDF today). The raster size is the active Stage's pixel dimensions × 2
    /// (spec §3.10), and the render root is project-bundle-relative (`Cache/Renders/`)
    /// when the document has been saved, app-support otherwise. App-support fallbacks
    /// stay portable across launches but require a future "Bundle for Travel" pass to
    /// migrate them into the bundle for venue handoff.
    private func currentMediaImportContext() -> MediaImportContext {
        let stage = document.project.stages.first
        let baseWidth = stage?.width ?? document.project.outputWidth
        let baseHeight = stage?.height ?? document.project.outputHeight
        let rasterSize = CGSize(width: max(1, baseWidth) * 2, height: max(1, baseHeight) * 2)
        return MediaImportContext(rasterSize: rasterSize, renderRootDirectory: renderRootDirectory())
    }

    private func renderRootDirectory() -> URL {
        if let bundleURL = projectBundleURLProvider() {
            return bundleURL.appendingPathComponent(
                ProjectBundleLayout.rendersDirectory,
                isDirectory: true
            )
        }
        return RootView.untitledRenderRoot
            .appendingPathComponent(untitledSessionID.uuidString, isDirectory: true)
    }

    private static let untitledRenderRoot: URL = {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Simple Playback", isDirectory: true)
            .appendingPathComponent("Renders", isDirectory: true)
    }()

    /// C2: where ProRes-converted siblings land. Mirrors the C3 `renderRootDirectory`
    /// shape — bundle-relative when the document is saved (spec §3.17 `<bundle>/Transcoded/`)
    /// and an App Support fallback for untitled documents (the same future "Bundle for
    /// Travel" pickup applies). Orphaned transcodes accumulate when the operator deletes a
    /// sibling slide; a future "Compact project" action would walk the bundle and remove
    /// transcodes no MediaSlide resolves to (filed as a known gap).
    private func transcodedRootDirectory() -> URL {
        if let bundleURL = projectBundleURLProvider() {
            return bundleURL.appendingPathComponent(
                ProjectBundleLayout.transcodedDirectory,
                isDirectory: true
            )
        }
        return RootView.untitledTranscodedRoot
            .appendingPathComponent(untitledSessionID.uuidString, isDirectory: true)
    }

    private static let untitledTranscodedRoot: URL = {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Simple Playback", isDirectory: true)
            .appendingPathComponent("Transcoded", isDirectory: true)
    }()

    /// Kicks off a transcode for `slide` and splices the resulting sibling slide into
    /// `project.slides` immediately after the source on completion. Failures are
    /// silent today — a future "import status banner" (deferred from C3) would expose
    /// `TranscodeError.exportFailed` and per-batch counts. Cancellations are silent
    /// by design.
    private func requestTranscode(slide: MediaSlide, preset: TranscodePreset) {
        let dest = transcodedRootDirectory()
        let sourceURL = slide.media.resolvedURL()
        transcodeCoordinator.transcode(
            slide: slide,
            preset: preset,
            destinationDirectory: dest
        ) { [self] result in
            switch result {
            case .success(let outcome):
                if let idx = document.project.slides.firstIndex(where: { $0.id == outcome.sourceSlideID }) {
                    document.project.slides.insert(outcome.siblingSlide, at: idx + 1)
                } else {
                    document.project.slides.append(outcome.siblingSlide)
                }
                selectedSlideID = outcome.siblingSlide.id
            case .failure(let error):
                // Cancelled transcodes are operator-initiated; silent is the right UX.
                // Other errors land in the banner so the operator sees what failed.
                if case .cancelled = error { return }
                importStatus.recordTranscode(url: sourceURL, error: error)
            }
        }
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
    var message: String = "Select a cue or asset to inspect"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.and.text.magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

enum InspectorMode: String, CaseIterable, Identifiable {
    case selection
    case overlays
    case output

    var id: String { rawValue }
    var label: String {
        switch self {
        case .selection: "Selection"
        case .overlays: "Overlays"
        case .output: "Output"
        }
    }
}

/// Inspector for a selected cue: number, title, continuation, pre/post-wait, notes.
private struct CueInspectorView: View {
    @Binding var cue: Cue
    let slides: [MediaSlide]
    let stageFPS: Double?
    /// When true, the inline transcode button is hidden so operators can't kick off
    /// edits during a live show. Mirrors SlideGridView's `transcodeEnabled` gating.
    var showMode: Bool = false
    /// Set by RootView's selection inspector (Option B / C-inline-transcode). Optional
    /// because preview-only inspector renders elsewhere may not need to plumb the
    /// transcode coordinator. When present + the asset is transcode-eligible + not in
    /// Show Mode, the chip group renders an inline "Transcode to ProRes …" button so
    /// operators can act on inspector warnings without hunting through the asset-library
    /// context menu.
    var requestTranscode: ((MediaSlide, TranscodePreset) -> Void)? = nil

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

                if let asset, asset.flags.hasAnyFlag {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(asset.flags.activeWarnings, id: \.self) { warning in
                            MediaFlagWarningChip(warning: warning)
                        }
                        if let requestTranscode, !showMode,
                           TranscodeService.canTranscode(slide: asset),
                           let preferred = TranscodeService.preferredPresetOrder(for: asset).first {
                            Button {
                                requestTranscode(asset, preferred)
                            } label: {
                                Label("Transcode to \(preferred.label)", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.caption)
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 2)
                            .help("Run the transcode now — produces a sibling \"\(asset.title) (\(preferred.label))\" slide.")
                        }
                    }
                    .help("Inspector flags. Click Transcode (or right-click the asset in the palette) to render a ProRes copy.")
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

/// Single-line warning chip for one `MediaFlagsEvaluator.WarningKind`. Yellow palette
/// (informational) — distinct from the orange FPS-mismatch banner above so an operator
/// reading the inspector at a glance can tell "shape problem" (orange, action recommended)
/// from "metadata caveat" (yellow, FYI).
private struct MediaFlagWarningChip: View {
    let warning: MediaFlagsEvaluator.WarningKind

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.yellow)
            Text(MediaFlagsEvaluator.warning(for: warning))
                .font(.caption)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.yellow.opacity(0.12))
        )
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
