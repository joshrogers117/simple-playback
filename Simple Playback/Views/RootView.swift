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
    /// C7d — Bundle for Travel coordinator. Owns the active copy pass; the
    /// confirm sheet binds to it. Lifetime is the document window.
    @StateObject private var bundleForTravelCoordinator = BundleForTravelCoordinator()
    /// C11 — background filmstrip-sprite-sheet generator. Auto-enqueued by
    /// the import path (video imports only); the future cue-inspector
    /// scrub UI consumes the resulting `<slide.id>.png` lazily on open.
    @StateObject private var filmstripCoordinator = FilmstripCoordinator()
    /// E3 — append-only show log for this document. Wired into ShowController
    /// after configuration so every verb (GO/PANIC/CLEAR/BLACKOUT/Show-Mode)
    /// records to the journal. Persistence destination is set in
    /// `bindShowLogFile()` once the document has a bundle URL.
    @StateObject private var showLog = ShowLog()
    /// E5 — last 200 cue fires for the open document. Owned at the view
    /// layer so it follows the document lifecycle (cleared on close).
    @StateObject private var takeHistory = TakeHistory()
    /// E8 — project lock controller. Owned by the NSDocument (so the lock is
    /// released even if SwiftUI teardown beats us to it); RootView observes
    /// the published banner state to surface the warning.
    @ObservedObject private var lockController: ProjectLockController
    /// E7 — crash-recovery controller. Same ownership story as
    /// `lockController` — the NSDocument owns the controller so the
    /// evaluate-on-fileURL-change machinery runs at the right time.
    @ObservedObject private var crashRecoveryController: CrashRecoveryController
    /// C7d — bundle-URL signal mirrored from `NSDocument.fileURL`. RootView
    /// observes it so a Save-As (the only way the bundle URL changes after
    /// open) refreshes `playback.bundleMediaDirectory` and the C9 missing-
    /// media banner. Default is a fresh observer for previews / tests that
    /// don't construct an NSDocument.
    @ObservedObject private var bundleURLObserver: BundleURLObserver
    /// E7 — Restore handler. Implemented by the NSDocument so the project
    /// decoder + change-count plumbing stays there. Returns true on success.
    private let restoreFromCheckpoint: () -> Bool
    /// E6 — autosave checkpoint hook. Called by RootView when the operator
    /// toggles Show Mode. The closure is implemented by the NSDocument so
    /// the project encoder + bundle layout can stay there.
    private let autosaveCheckpoint: (AutosaveCheckpoint.Reason) -> Void
    /// E1+ energy — no-idle-sleep IOPM assertion. Held while Show Mode is on
    /// so macOS cannot put the machine to sleep mid-show. Released on Show
    /// Mode off and on document close (RootView .onDisappear).
    @StateObject private var energyAssertion = EnergyAssertion()
    /// Tracks the previous Show Mode value so the `.onChange` hook only
    /// fires the checkpoint on real transitions (not the initial nil →
    /// false ShowController-load).
    @State private var lastShowMode: Bool?
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
    /// Toggle for the Phase E3 show-log viewer.
    @State private var showLogPresented: Bool = false
    /// Toggle for the Phase E5 take-history sheet.
    @State private var takeHistoryPresented: Bool = false

    @State private var postShowSummaryPresented: Bool = false
    /// C7d — non-nil while the Bundle for Travel sheet is on-screen. Holds the
    /// pre-computed plan so summary + progress + result all read off the same
    /// snapshot.
    @State private var pendingBundleForTravel: BundleForTravelPlanReport?
    /// C9 persistent banner — current asset-library status, recomputed
    /// whenever `project.slides` changes. Driven by `AssetLibraryProbe.evaluate`
    /// with the bundle-aware online check so a moved bundle's managed assets
    /// classify correctly. Empty (no banner) when no slides are offline.
    @State private var assetLibraryStatus: AssetLibraryStatus = .empty
    /// Coalesces rapid `project.slides` change bursts (drag-reorder, multi-
    /// import, bulk-delete) into a single recompute. Each `evaluate` call
    /// stats every slide; without the 250 ms collapse window a 500-slide
    /// reorder would fire 500 sequential `FileManager.fileExists` syscalls.
    @State private var assetLibraryRecomputeDebouncer = Debouncer(interval: .milliseconds(250))
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
        projectBundleURLProvider: @escaping () -> URL? = { nil },
        lockController: ProjectLockController,
        crashRecoveryController: CrashRecoveryController = CrashRecoveryController(),
        bundleURLObserver: BundleURLObserver = BundleURLObserver(),
        restoreFromCheckpoint: @escaping () -> Bool = { false },
        autosaveCheckpoint: @escaping (AutosaveCheckpoint.Reason) -> Void = { _ in }
    ) {
        self._document = document
        self.outputSettings = outputSettings
        self.projectBundleURLProvider = projectBundleURLProvider
        self.lockController = lockController
        self.crashRecoveryController = crashRecoveryController
        self.bundleURLObserver = bundleURLObserver
        self.restoreFromCheckpoint = restoreFromCheckpoint
        self.autosaveCheckpoint = autosaveCheckpoint
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

                Button {
                    showLogPresented = true
                } label: {
                    Label("Show Log", systemImage: "list.bullet.rectangle")
                }
                .help("Open the show log — every cue fire, panic, clear, missing-media, OSC action.")

                Button {
                    takeHistoryPresented = true
                } label: {
                    Label("Take History", systemImage: "clock.arrow.circlepath")
                }
                .help("Open the take history — the last 200 cue fires in this session.")

                Button {
                    postShowSummaryPresented = true
                } label: {
                    Label("Post-Show", systemImage: "doc.text.below.ecg")
                }
                .help("Open the post-show summary — totals, per-cue runtime, latency histogram, drop / late-take detail.")

                Button {
                    presentBundleForTravelSheet()
                } label: {
                    Label("Bundle for Travel", systemImage: "shippingbox")
                }
                .help("Copy linked media into the project bundle so the show is venue-portable.")
                .disabled(!canBundleForTravel)

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
            // v2 Post-Show Summary Q4-B — push a `.lockFileForeign` row into
            // the show log on first detection of a live foreign lock so the
            // post-show summary's systemEvents picks it up. The closure
            // strongly captures `showLog` (a @StateObject class instance);
            // the closure dies when `lockController` is released by the
            // owning NSDocument.
            let log = showLog
            lockController.onForeignLockDetected = { lock in
                log.appendNow(
                    action: .lockFileForeign,
                    source: .system,
                    detail: "host=\(lock.hostname) pid=\(lock.pid)"
                )
            }
            lockController.evaluate(bundleURL: projectBundleURLProvider())
            playback.bundleMediaDirectory = bundleMediaDirectory()
            playback.folderBookmarks = projectFolderBookmarkLookup()
            recomputeAssetLibraryStatus()
        }
        .onChange(of: document.project.slides) {
            assetLibraryRecomputeDebouncer.schedule {
                recomputeAssetLibraryStatus()
            }
        }
        .onChange(of: bundleURLObserver.bundleURL) {
            // Save-As (or initial document open) just changed the bundle URL.
            // Refresh playback's bundle-aware resolution and the missing-media
            // banner so they don't keep using the stale `nil` from `.onAppear`.
            playback.bundleMediaDirectory = bundleMediaDirectory()
            recomputeAssetLibraryStatus()
        }
        .onChange(of: document.project.folderBookmarks) {
            // C8 v1.1 — keep the playback / compositor lookup in sync with the
            // project's bookmark list so an Add Folder import (or future
            // bookmark-edit affordance) takes effect on the next take without
            // a save / reopen.
            playback.folderBookmarks = projectFolderBookmarkLookup()
            recomputeAssetLibraryStatus()
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
        .onChange(of: showController.controller?.showMode) { _, newValue in
            handleShowModeChange(newValue)
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
        .sheet(isPresented: $showLogPresented) {
            ShowLogView(log: showLog, onClose: { showLogPresented = false })
        }
        .sheet(isPresented: $takeHistoryPresented) {
            TakeHistoryView(history: takeHistory, onClose: { takeHistoryPresented = false })
        }
        .sheet(isPresented: $postShowSummaryPresented) {
            PostShowSummaryView(log: showLog, onClose: { postShowSummaryPresented = false })
        }
        .sheet(isPresented: bundleForTravelSheetBinding) {
            if let plan = pendingBundleForTravel,
               let bundleURL = projectBundleURLProvider() {
                let mediaDir = bundleURL.appendingPathComponent(
                    ProjectBundleLayout.mediaDirectory,
                    isDirectory: true
                )
                BundleForTravelSheet(
                    coordinator: bundleForTravelCoordinator,
                    plan: plan,
                    mediaDirectoryURL: mediaDir,
                    onConfirm: { runBundleForTravel(plan: plan, mediaDirectoryURL: mediaDir) },
                    onCancel: { dismissBundleForTravelSheet() },
                    onClose: { dismissBundleForTravelSheet() }
                )
            }
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
                },
                relinkSlide: { slide in
                    relinkSlideViaOpenPanel(slide)
                },
                bundleMediaDirectory: bundleMediaDirectory(),
                folderBookmarks: projectFolderBookmarkLookup(),
                thumbnailCacheDirectory: thumbnailRootDirectory()
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
                    Button {
                        showController.controller?.panic()
                    } label: {
                        Label("FTB", systemImage: "exclamationmark.octagon.fill")
                    }
                    .tint(.red)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Fade to Black — fade everything currently on Program down to black (Esc)")

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

                MissingMediaBannerView(
                    status: assetLibraryStatus,
                    onRelink: { chooseRelinkFolderAndApply() },
                    canRelink: !(showController.controller?.showMode ?? false)
                )

                ProjectLockBannerView(controller: lockController)

                CrashRecoveryBannerView(
                    controller: crashRecoveryController,
                    onRestore: { _ = restoreFromCheckpoint() }
                )

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
                },
                bundleMediaDirectory: bundleMediaDirectory(),
                folderBookmarks: projectFolderBookmarkLookup()
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
            showController.controller?.takeHistory = takeHistory
            bindShowLogFile()
        }
        syncCompositorOverlays()
    }

    /// Bind the show-log writer to a path inside the project bundle when one
    /// exists. Untitled documents have no bundle on disk yet — events stay
    /// in memory until the operator saves. Idempotent.
    private func bindShowLogFile() {
        guard let bundleURL = projectBundleURLProvider() else { return }
        let logsURL = bundleURL.appendingPathComponent(ProjectBundleLayout.logsDirectory, isDirectory: true)
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

    /// E6 checkpoint hook. Fires whenever Show Mode flips between true/false
    /// after the initial load. The first non-nil value seeds `lastShowMode`
    /// without writing a checkpoint — that prevents a spurious "show mode
    /// off" snapshot at app launch on every project open.
    private func handleShowModeChange(_ newValue: Bool?) {
        guard let newValue else { return }
        defer { lastShowMode = newValue }
        // Energy assertion follows showMode regardless of whether this is the
        // first observation (nil → false on load also reaches here): we want
        // the assertion to land the moment the operator flips into Show Mode,
        // not one toggle later.
        if newValue {
            energyAssertion.acquire()
        } else {
            energyAssertion.release()
        }
        guard let last = lastShowMode, last != newValue else { return }
        autosaveCheckpoint(newValue ? .showModeOn : .showModeOff)
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
        ctx.systemPreventsIdleSleep = energyAssertion.isHeld
        let mediaDir = bundleMediaDirectory()
        let folderBookmarks = projectFolderBookmarkLookup()
        ctx.assetLibraryStatus = AssetLibraryProbe.evaluate(
            slides: document.project.slides,
            isOnline: AssetLibraryProbe.makeIsOnline(
                bundleMediaDirectory: mediaDir,
                folderBookmarks: folderBookmarks
            ),
            resolveURL: AssetLibraryProbe.makeResolveURL(
                bundleMediaDirectory: mediaDir,
                folderBookmarks: folderBookmarks
            )
        )
        return ctx
    }

    /// C8 — id → `FolderBookmark` lookup the resolver / probe / relink-plan
    /// callsites consume. Built fresh from `document.project.folderBookmarks`
    /// so a bookmark added by an Add Folder import shows up in the next
    /// pre-show / resolution pass without an extra refresh hop.
    private func projectFolderBookmarkLookup() -> [UUID: FolderBookmark] {
        Dictionary(uniqueKeysWithValues:
            document.project.folderBookmarks.map { ($0.id, $0) }
        )
    }

    /// C7d — current project bundle's `<bundle>/Media/` URL, when one exists.
    /// Used by the playback hot path and the pre-show check to make managed
    /// references resolve correctly even when the bundle has been moved
    /// between machines (stale absolute path / bookmark).
    private func bundleMediaDirectory() -> URL? {
        projectBundleURLProvider()?.appendingPathComponent(
            ProjectBundleLayout.mediaDirectory,
            isDirectory: true
        )
    }

    /// C9 — refresh `assetLibraryStatus` from the live asset library.
    /// `AssetLibraryProbe.evaluate` is pure-logic O(slides), but `liveIsOnline`
    /// stats each slide, so on a 500-slide deck this is ~500 syscalls. Burst
    /// callers (slide-change `onChange`) route through
    /// `assetLibraryRecomputeDebouncer`; one-shot callers (`.onAppear`,
    /// bundle-URL change) call this directly so the banner refreshes
    /// immediately when the bundle moves.
    private func recomputeAssetLibraryStatus() {
        let mediaDir = bundleMediaDirectory()
        let folderBookmarks = projectFolderBookmarkLookup()
        assetLibraryStatus = AssetLibraryProbe.evaluate(
            slides: document.project.slides,
            isOnline: AssetLibraryProbe.makeIsOnline(
                bundleMediaDirectory: mediaDir,
                folderBookmarks: folderBookmarks
            ),
            resolveURL: AssetLibraryProbe.makeResolveURL(
                bundleMediaDirectory: mediaDir,
                folderBookmarks: folderBookmarks
            )
        )
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

        // media.files — operator picks a relink folder; we walk every offline
        // slide through the C7c MediaResolver waterfall and apply the resulting
        // plan to project.slides. C9-flavored: closes the duplicate-of-Pre-Show
        // gap by giving the operator a one-click "find the missing files in
        // this folder" action.
        handlers.byRowID["media.files"] = {
            chooseRelinkFolderAndApply()
        }

        return handlers
    }

    private var bundleForTravelSheetBinding: Binding<Bool> {
        Binding(
            get: { pendingBundleForTravel != nil },
            set: { newValue in
                if !newValue { dismissBundleForTravelSheet() }
            }
        )
    }

    private var canBundleForTravel: Bool {
        guard projectBundleURLProvider() != nil else { return false }
        return !document.project.slides.isEmpty
    }

    /// Toolbar entry-point for the C7d Bundle for Travel command. Computes
    /// the plan synchronously against the current slide list (cheap — pure
    /// logic over the asset library) and presents the confirm sheet. The
    /// actual copying happens inside the coordinator on confirm.
    private func presentBundleForTravelSheet() {
        guard let bundleURL = projectBundleURLProvider() else { return }
        let mediaDir = bundleURL.appendingPathComponent(
            ProjectBundleLayout.mediaDirectory,
            isDirectory: true
        )
        let report = BundleForTravelPlan.plan(
            slides: document.project.slides,
            resolve: { ref in
                MediaResolver.resolve(
                    reference: ref,
                    searchRoots: [],
                    bundleMediaDirectory: mediaDir
                )
            }
        )
        bundleForTravelCoordinator.reset()
        pendingBundleForTravel = report
    }

    /// Operator confirmed the plan — kick off the copy pass. On success we
    /// apply the plan to `project.slides` (kind flips to `.managed`,
    /// originalPath rewrites to the bundle Media/ destination, fingerprint
    /// refreshes against the freshly copied file). The sheet stays on-screen
    /// in its terminal state so the operator can read the summary before
    /// dismissing.
    private func runBundleForTravel(
        plan: BundleForTravelPlanReport,
        mediaDirectoryURL: URL
    ) {
        bundleForTravelCoordinator.start(
            plan: plan,
            mediaDirectoryURL: mediaDirectoryURL
        ) { result in
            if case .success(let completedPlan) = result {
                let updated = BundleForTravelPlan.apply(
                    plan: completedPlan,
                    to: document.project.slides,
                    mediaDirectoryURL: mediaDirectoryURL
                )
                document.project.slides = updated
            }
        }
    }

    private func dismissBundleForTravelSheet() {
        pendingBundleForTravel = nil
        bundleForTravelCoordinator.reset()
    }

    /// C9 — single-slide relink action wired to the SlideGridView Locate…
    /// context menu. Operator picks one file via NSOpenPanel; we splice the new
    /// reference (with a fresh fingerprint) into `project.slides` for that
    /// specific slide. Independent of the bulk folder-relink Fix handler;
    /// useful when the operator already knows the new file's exact location.
    private func relinkSlideViaOpenPanel(_ slide: MediaSlide) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Locate"
        panel.message = "Pick the file that should replace \(slide.title)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let index = document.project.slides.firstIndex(where: { $0.id == slide.id }) else { return }
        var updated = document.project.slides[index]
        let inferredKind = AssetRelinkPlan.inferKind(
            existing: updated.media.kind,
            newURL: url,
            bundleMediaDirectory: bundleMediaDirectory()
        )
        updated.media = MediaReference(
            url: url,
            fingerprint: try? AssetFingerprinter.fingerprint(url: url),
            kind: inferredKind
        )
        document.project.slides[index] = updated
    }

    /// Operator-triggered relink action wired into the `media.files` Pre-Show
    /// fix button. NSOpenPanel for folder selection; result feeds the C7c
    /// resolver via AssetRelinkPlan; the resulting updates land in
    /// `document.project.slides`. Surfaces a one-line summary on the import
    /// status banner so the operator gets feedback even when the sheet has
    /// been dismissed.
    private func chooseRelinkFolderAndApply() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose Relink Folder"
        panel.message = "Pick a folder. Simple Playback will search it for any media files that are currently offline."
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let report = AssetRelinkPlan.plan(
            slides: document.project.slides,
            searchRoots: [folder],
            // C8 — thread the project's folder-bookmark lookup so the relink
            // plan can mark slides as "still online via folder bookmark"
            // (recovered through rung 2) without proposing a redundant
            // contentHash/nameAndSize update for them.
            resolve: AssetRelinkPlan.liveResolve(
                folderBookmarks: projectFolderBookmarkLookup(),
                bundleMediaDirectory: bundleMediaDirectory()
            )
        )
        guard !report.updates.isEmpty else {
            // Nothing matched — surface so the operator doesn't think the click
            // did nothing. Use the import-status banner; it's the existing
            // non-modal failure surface.
            importStatus.record([
                MediaImportFailure(
                    url: folder,
                    kind: .unsupportedMedia,
                    summary: "No offline media found in \(folder.lastPathComponent)."
                )
            ])
            return
        }
        let updated = AssetRelinkPlan.apply(
            plan: report,
            to: document.project.slides,
            bundleMediaDirectory: bundleMediaDirectory()
        )
        document.project.slides = updated
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
            // C8 — folder-mode addMedia. Captures one FolderBookmark for the
            // folder, registers it on the project, and stamps every imported
            // MediaReference with the bookmark id + a relative path. Resolver
            // rung 2 will recover these slides if a clip is later moved within
            // the imported folder.
            addMedia(confirmed.standaloneMediaURLs, folderURL: confirmed.folderURL)
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

    private func addMedia(_ urls: [URL], folderURL: URL? = nil) {
        guard !(showController.controller?.showMode ?? false) else { return }
        // C8 — folder-mode opt-in. When the operator imports through Add
        // Folder…  / a folder-drop with a single common parent, capture one
        // FolderBookmark for that parent, register it in the project, and
        // hand it to the importer so every slide gets the folder-bookmark
        // fields stamped.
        let registered = folderURL.map(registerFolderBookmark)
        let context = currentMediaImportContext(
            folderBookmark: registered,
            folderRoot: folderURL
        )
        let report = MediaImporter.importSlidesAndReport(from: urls, context: context)
        importStatus.record(report.failures)
        guard !report.slides.isEmpty else { return }
        document.project.slides.append(contentsOf: report.slides)
        selectedSlideID = report.slides.last?.id
    }

    /// C8 — append a `FolderBookmark` to `project.folderBookmarks` for the
    /// given folder URL and return it. If a bookmark with the same originalPath
    /// already exists, reuse its id instead of registering a duplicate so the
    /// project file doesn't accumulate redundant blobs across re-imports of
    /// the same folder.
    private func registerFolderBookmark(_ folderURL: URL) -> FolderBookmark {
        let normalized = folderURL.standardizedFileURL.path
        if let existing = document.project.folderBookmarks
            .first(where: { $0.originalPath == normalized }) {
            return existing
        }
        let bookmark = FolderBookmark(folderURL: folderURL)
        document.project.folderBookmarks.append(bookmark)
        return bookmark
    }

    /// Builds the per-import context the importer needs for source formats that require
    /// conversion (PDF today). The raster size is the active Stage's pixel dimensions × 2
    /// (spec §3.10), and the render root is project-bundle-relative (`Cache/Renders/`)
    /// when the document has been saved, app-support otherwise. App-support fallbacks
    /// stay portable across launches but require a future "Bundle for Travel" pass to
    /// migrate them into the bundle for venue handoff.
    private func currentMediaImportContext(
        folderBookmark: FolderBookmark? = nil,
        folderRoot: URL? = nil
    ) -> MediaImportContext {
        let stage = document.project.stages.first
        let baseWidth = stage?.width ?? document.project.outputWidth
        let baseHeight = stage?.height ?? document.project.outputHeight
        let rasterSize = CGSize(width: max(1, baseWidth) * 2, height: max(1, baseHeight) * 2)
        let filmstripDir = filmstripRootDirectory()
        let coordinator = filmstripCoordinator
        return MediaImportContext(
            rasterSize: rasterSize,
            renderRootDirectory: renderRootDirectory(),
            thumbnailRootDirectory: thumbnailRootDirectory(),
            enqueueFilmstrip: { slideID, sourceURL in
                let destination = filmstripDir
                    .appendingPathComponent("\(slideID.uuidString).png")
                coordinator.enqueue(
                    slideID: slideID,
                    sourceURL: sourceURL,
                    destinationURL: destination
                )
            },
            folderBookmark: folderBookmark,
            folderRoot: folderRoot
        )
    }

    /// C11 — where per-slide filmstrip sprite-sheet PNGs land. Bundle-
    /// relative when the document is saved (spec §3.17
    /// `<bundle>/Cache/Filmstrips/`); App Support fallback per
    /// untitled-session ID otherwise. Mirrors `thumbnailRootDirectory()`
    /// shape so the cue-inspector scrub UI can read from the same place
    /// writes go regardless of save state.
    func filmstripRootDirectory() -> URL {
        if let bundleURL = projectBundleURLProvider() {
            return bundleURL.appendingPathComponent(
                ProjectBundleLayout.filmstripsDirectory,
                isDirectory: true
            )
        }
        return RootView.untitledFilmstripRoot
            .appendingPathComponent(untitledSessionID.uuidString, isDirectory: true)
    }

    private static let untitledFilmstripRoot: URL = {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Simple Playback", isDirectory: true)
            .appendingPathComponent("Filmstrips", isDirectory: true)
    }()

    /// C10 — where per-slide poster JPEGs land. Bundle-relative when the
    /// document is saved (spec §3.17 `<bundle>/Cache/Thumbnails/`); App
    /// Support fallback per untitled-session ID otherwise. The directory is
    /// also handed to the SlideGridView palette so the offline-source
    /// fallback path can read from the same place writes go.
    func thumbnailRootDirectory() -> URL {
        if let bundleURL = projectBundleURLProvider() {
            return bundleURL.appendingPathComponent(
                ProjectBundleLayout.thumbnailsDirectory,
                isDirectory: true
            )
        }
        return RootView.untitledThumbnailRoot
            .appendingPathComponent(untitledSessionID.uuidString, isDirectory: true)
    }

    private static let untitledThumbnailRoot: URL = {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Simple Playback", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }()

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
        let mediaDir = bundleMediaDirectory()
        let folderBookmarks = projectFolderBookmarkLookup()
        let sourceURL = slide.media.resolvedURL(
            bundleMediaDirectory: mediaDir,
            folderBookmarks: folderBookmarks
        )
        transcodeCoordinator.transcode(
            slide: slide,
            preset: preset,
            destinationDirectory: dest,
            bundleMediaDirectory: mediaDir,
            folderBookmarks: folderBookmarks
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
    /// C7d — current project bundle's `<bundle>/Media/` URL when one exists.
    /// Threaded into the inline transcode-eligibility check so a moved bundle's
    /// managed assets don't render as un-transcodable in the cue inspector.
    var bundleMediaDirectory: URL? = nil
    /// C8 v1.1 — id → `FolderBookmark` lookup; threaded into the inline
    /// transcode-eligibility check alongside `bundleMediaDirectory` so a
    /// folder-renamed source still reports as transcode-eligible.
    var folderBookmarks: [UUID: FolderBookmark] = [:]

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
                           TranscodeService.canTranscode(
                               slide: asset,
                               bundleMediaDirectory: bundleMediaDirectory,
                               folderBookmarks: folderBookmarks
                           ),
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
