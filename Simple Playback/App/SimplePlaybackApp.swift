import Combine
import Sparkle
import SwiftUI

@main
struct SimplePlaybackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var outputSettings = OutputSettingsStore()
    private let updaterController: SPUStandardUpdaterController?

    init() {
        updaterController = SparkleConfiguration.isConfigured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
        DeckLinkDiagnostics.runIfRequested()
    }

    var body: some Scene {
        DocumentGroup(newDocument: SimplePlaybackDocument()) { file in
            RootView(document: file.$document, outputSettings: outputSettings)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    DocumentLifecycle.openBlankProject()
                }
                .keyboardShortcut("n")
            }

            if let updater = updaterController?.updater {
                CommandGroup(after: .appInfo) {
                    CheckForUpdatesView(updater: updater)
                }
            }
        }

        Settings {
            OutputPreferencesView(outputSettings: outputSettings)
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

private enum DocumentLifecycle {
    static func openBlankProject() {
        do {
            _ = try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        } catch {
            NSApplication.shared.presentError(error)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var handledStartupOpen = false

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if handledStartupOpen {
            openBlankProject()
        } else {
            openStartupProjectIfNeeded()
        }
        return true
    }

    private func openStartupProjectIfNeeded() {
        guard !handledStartupOpen else { return }
        handledStartupOpen = true
        openStartupProject()
    }

    private func openStartupProject() {
        let documentController = NSDocumentController.shared

        if let projectURL = documentController.recentDocumentURLs.first,
           FileManager.default.fileExists(atPath: projectURL.path) {
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
        DocumentLifecycle.openBlankProject()
    }
}
