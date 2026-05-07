import AppKit
import SwiftUI

/// On-disk layout of the v2 project bundle.
enum ProjectBundleLayout {
    /// Top-level JSON file inside the bundle holding the `PlayoutProject` schema.
    static let projectFilename = "Show.json"
}

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

    /// Bundle-aware reader. Accepts both the v2 directory bundle (`Show.json` inside) and legacy
    /// v1 flat JSON files. Old files are upgraded to v2 the next time the user saves.
    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        let data = try Self.projectData(from: fileWrapper)
        playbackDocument.project = try JSONDecoder.simplePlayback.decode(PlayoutProject.self, from: data)
    }

    /// Bundle writer. Always writes a directory containing `Show.json`. Subsequent phases drop
    /// additional sub-folders here (Logs/, Cache/, Transcoded/, Autosave/) without changing the
    /// schema version.
    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        playbackDocument.project.markCurrentFormatVersion()
        let data = try JSONEncoder.simplePlayback.encode(playbackDocument.project)
        let projectWrapper = FileWrapper(regularFileWithContents: data)
        projectWrapper.preferredFilename = ProjectBundleLayout.projectFilename
        let bundleWrapper = FileWrapper(directoryWithFileWrappers: [
            ProjectBundleLayout.projectFilename: projectWrapper
        ])
        return bundleWrapper
    }

    override func fileNameExtension(forType typeName: String, saveOperation: SaveOperationType) -> String? {
        "spb"
    }

    /// Extracts the project JSON payload from either a v2 directory bundle or a legacy flat file.
    static func projectData(from fileWrapper: FileWrapper) throws -> Data {
        if fileWrapper.isDirectory {
            guard let projectWrapper = fileWrapper.fileWrappers?[ProjectBundleLayout.projectFilename],
                  let data = projectWrapper.regularFileContents else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return data
        }
        guard let data = fileWrapper.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
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
