import SwiftUI

@main
struct SimplePlayoutApp: App {
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
