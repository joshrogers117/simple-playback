import Combine
import Sparkle
import SwiftUI

@main
struct SimplePlaybackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var outputSettings = OutputSettingsStore.shared
    private let updaterController: SPUStandardUpdaterController?

    init() {
        updaterController = SparkleConfiguration.isConfigured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
        DeckLinkDiagnostics.runIfRequested()
        // Stand up the show-control stack at app launch so external triggers (OSC,
        // HTTP, Companion) can connect immediately. The active runtime is rebound
        // each time a document's ShowController is created.
        ShowControlHub.shared.startIfNeeded()
    }

    var body: some Scene {
        WindowGroup("Project Launcher", id: StartupProjectLaunch.windowID) {
            StartupProjectLauncher()
        }
        .defaultSize(width: 100, height: 100)
        .windowResizability(.contentSize)

        Settings {
            OutputPreferencesView(outputSettings: outputSettings)
        }
        .commands {
            ProjectDocumentCommands()
            ShowListVisibilityCommands()
            DiagnosticsMenuCommands()

            if let updater = updaterController?.updater {
                CommandGroup(after: .appInfo) {
                    CheckForUpdatesView(updater: updater)
                }
            }
        }
    }
}

private enum SparkleConfiguration {
    static var isConfigured: Bool {
        hasConfiguredValue(for: "SUFeedURL") && hasConfiguredValue(for: "SUPublicEDKey")
    }

    private static func hasConfiguredValue(for key: String) -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return false
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("$(") && !trimmed.contains("REPLACE_")
    }
}

private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

private struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates...", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

private struct ProjectDocumentCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") {
                NSDocumentController.shared.newDocument(nil)
            }
            .keyboardShortcut("n")
        }

        CommandGroup(after: .newItem) {
            Button("Open Project...") {
                NSDocumentController.shared.openDocument(nil)
            }
            .keyboardShortcut("o")
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                NSApplication.shared.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("s")

            Button("Save As...") {
                NSApplication.shared.sendAction(#selector(NSDocument.saveAs(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}

private struct ShowListVisibilityCommands: Commands {
    @AppStorage("ui.showListVisible") private var showListVisible: Bool = true

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Toggle("Show Cue List", isOn: $showListVisible)
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}

private struct DiagnosticsMenuCommands: Commands {
    @FocusedValue(\.diagnosticsSheetBindings) private var bindings

    var body: some Commands {
        CommandMenu("Diagnostics") {
            Button("Show Log…") {
                bindings?.showLogPresented.wrappedValue = true
            }
            .disabled(bindings == nil)

            Button("Take History…") {
                bindings?.takeHistoryPresented.wrappedValue = true
            }
            .disabled(bindings == nil)

            Button("Post-Show Summary…") {
                bindings?.postShowSummaryPresented.wrappedValue = true
            }
            .disabled(bindings == nil)
        }
    }
}

enum StartupProjectLaunch {
    static let windowID = "startup-project-launcher"
    static let windowIdentifier = NSUserInterfaceItemIdentifier(windowID)

    static func firstExistingRecentProjectURL(
        from urls: [URL],
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        urls.first { fileExists($0) }
    }
}

@MainActor
private final class StartupProjectOpener {
    static let shared = StartupProjectOpener()

    private var handledStartupOpen = false

    func openStartupProjectIfNeeded() {
        guard !handledStartupOpen else { return }
        guard NSDocumentController.shared.documents.isEmpty else { return }
        handledStartupOpen = true
        openStartupProject()
    }

    private func openStartupProject() {
        let documentController = NSDocumentController.shared

        if let projectURL = StartupProjectLaunch.firstExistingRecentProjectURL(from: documentController.recentDocumentURLs) {
            documentController.openDocument(withContentsOf: projectURL, display: true) { document, _, _ in
                if document == nil {
                    self.openBlankProject()
                }
            }
            return
        }

        openBlankProject()
    }

    private func openBlankProject() {
        do {
            _ = try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        } catch {
            NSApplication.shared.presentError(error)
        }
    }
}

private struct StartupProjectLauncher: View {
    var body: some View {
        Color.clear
            .frame(width: 100, height: 100)
            .background(StartupWindowHider())
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    StartupProjectOpener.shared.openStartupProjectIfNeeded()
                    NSApplication.shared.windows
                        .filter { $0.identifier == StartupProjectLaunch.windowIdentifier }
                        .forEach { $0.close() }
                }
            }
    }
}

private struct StartupWindowHider: NSViewRepresentable {
    final class Coordinator {
        var scheduledClose = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(window: view.window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window, coordinator: context.coordinator)
        }
    }

    private func configure(window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        window.identifier = StartupProjectLaunch.windowIdentifier
        window.alphaValue = 0
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior.insert(.transient)

        guard !coordinator.scheduledClose else { return }
        coordinator.scheduledClose = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak window] in
            if window?.identifier == StartupProjectLaunch.windowIdentifier {
                window?.close()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Spec §3.16 — autosave every 30 s of edit activity. The setting
        // lives on NSDocumentController; combined with our document's
        // `autosavesInPlace = true`, the OS coalesces edits and writes back
        // to the same bundle URL after this delay. The Show-Mode-toggle
        // *checkpoint* (a separate snapshot to <bundle>/Autosave/) is wired
        // through SimplePlaybackProjectDocument.writeAutosaveCheckpoint.
        NSDocumentController.shared.autosavingDelay = 30

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            StartupProjectOpener.shared.openStartupProjectIfNeeded()
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        StartupProjectOpener.shared.openStartupProjectIfNeeded()
        return true
    }
}
