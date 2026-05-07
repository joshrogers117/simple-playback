import SwiftUI

@main
struct SimplePlayoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var outputSettings = OutputSettingsStore()

    init() {
        DeckLinkDiagnostics.runIfRequested()
    }

    var body: some Scene {
        DocumentGroup(newDocument: SimplePlayoutDocument()) { file in
            RootView(document: file.$document, outputSettings: outputSettings)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    NSDocumentController.shared.newDocument(nil)
                }
                .keyboardShortcut("n")
            }
        }

        Settings {
            OutputPreferencesView(outputSettings: outputSettings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        DispatchQueue.main.async {
            self.openStartupProject()
        }
        return false
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
        NSDocumentController.shared.newDocument(nil)
    }
}
