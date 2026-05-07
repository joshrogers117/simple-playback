import AppKit
import SwiftUI

final class SimplePlaybackProjectDocument: NSDocument {
    private var playbackDocument = SimplePlaybackDocument()

    override class var autosavesInPlace: Bool {
        true
    }

    override init() {
        super.init()
        hasUndoManager = true
    }

    override func makeWindowControllers() {
        let rootView = RootView(
            document: documentBinding,
            outputSettings: OutputSettingsStore.shared
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.minSize = NSSize(width: 980, height: 640)
        window.title = displayName
        window.representedURL = fileURL

        addWindowController(NSWindowController(window: window))
    }

    override func data(ofType typeName: String) throws -> Data {
        try JSONEncoder.simplePlayback.encode(playbackDocument.project)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        playbackDocument.project = try JSONDecoder.simplePlayback.decode(PlayoutProject.self, from: data)
    }

    override func fileNameExtension(forType typeName: String, saveOperation: SaveOperationType) -> String? {
        "spb"
    }

    private var documentBinding: Binding<SimplePlaybackDocument> {
        Binding { [weak self] in
            self?.playbackDocument ?? SimplePlaybackDocument()
        } set: { [weak self] newDocument in
            self?.playbackDocument = newDocument
            self?.updateChangeCount(.changeDone)
        }
    }
}
