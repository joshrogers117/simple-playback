import AppKit
import Combine
import SwiftUI

// Wraps the document in an ObservableObject so edits made through SwiftUI
// bindings (e.g. the Inspector) republish and re-render the live UI. Without
// this, the hand-rolled Binding's getter read a plain stored property with no
// publisher, so changes persisted but never updated the views or live output.
final class PlaybackDocumentStore: ObservableObject {
    @Published var document: SimplePlaybackDocument

    init(document: SimplePlaybackDocument = SimplePlaybackDocument()) {
        self.document = document
    }
}

private struct ProjectDocumentHost: View {
    @ObservedObject var store: PlaybackDocumentStore
    @ObservedObject var outputSettings: OutputSettingsStore

    var body: some View {
        RootView(document: $store.document, outputSettings: outputSettings)
    }
}

final class SimplePlaybackProjectDocument: NSDocument {
    private let store = PlaybackDocumentStore()
    private var changeObserver: AnyCancellable?

    override class var autosavesInPlace: Bool {
        true
    }

    override init() {
        super.init()
        hasUndoManager = true
    }

    override func makeWindowControllers() {
        let rootView = ProjectDocumentHost(
            store: store,
            outputSettings: OutputSettingsStore.shared
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.minSize = NSSize(width: 980, height: 640)
        window.title = displayName
        window.representedURL = fileURL

        // Mark the document dirty on edits made through the SwiftUI bindings.
        // dropFirst skips the value present at subscription time (the loaded or
        // empty project) so opening a document does not flag it as edited.
        changeObserver = store.$document
            .dropFirst()
            .sink { [weak self] _ in
                self?.updateChangeCount(.changeDone)
            }

        addWindowController(NSWindowController(window: window))
    }

    override func data(ofType typeName: String) throws -> Data {
        try JSONEncoder.simplePlayback.encode(store.document.project)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let project = try JSONDecoder.simplePlayback.decode(PlayoutProject.self, from: data)
        store.document = SimplePlaybackDocument(project: project)
    }

    override func fileNameExtension(forType typeName: String, saveOperation: SaveOperationType) -> String? {
        "spb"
    }
}
