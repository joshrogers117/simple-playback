import AppKit
import SwiftUI

/// On-disk layout of the v2 project bundle.
enum ProjectBundleLayout {
    /// Top-level JSON file inside the bundle holding the `PlayoutProject` schema.
    static let projectFilename = "Show.json"

    /// Per-spec §3.17, rasterized assets (PDF→PNG today; future PPT/Keynote→PNG) live
    /// inside the bundle so the show file remains venue-portable. C3 PDF import writes
    /// per-batch UUID subdirectories under this path.
    static let rendersDirectory = "Cache/Renders"

    /// Per-spec §3.17, ProRes-converted copies of risky media live here. C2 right-click
    /// transcode writes one `<UUID>.mov` per transcode under this path, sibling to the
    /// original slide in the asset library.
    static let transcodedDirectory = "Transcoded"

    /// Per-spec §3.17, "only present in Bundle for Travel mode". C7d copies linked
    /// media into this directory and rewrites `MediaReference.kind` to `.managed` so
    /// the bundle is venue-portable. The MediaResolver short-circuits to this folder
    /// before falling through to the on-disk original path for managed assets.
    static let mediaDirectory = "Media"
}

final class SimplePlaybackProjectDocument: NSDocument {
    private var playbackDocument = SimplePlaybackDocument()
    /// E8 — per-document lock controller. Acquires/releases `<bundle>/.lock`
    /// across the document lifecycle. Lifetime is tied to the NSDocument so
    /// the lock is dropped when the user closes the window even if SwiftUI
    /// teardown ordering would otherwise leak it.
    private let lockController = ProjectLockController()
    /// E7 — per-document crash-recovery controller. On document open, scans
    /// `<bundle>/Autosave/` for any checkpoint newer than the on-disk
    /// `Show.json`. The banner surfaces in `RootView`.
    private let crashRecoveryController = CrashRecoveryController()
    /// Tracks `NSDocument.fileURL` changes — fires on the initial open path
    /// (set after `read(from:)` completes) and on Save-As (operator picks a
    /// new destination). Each change triggers a lock re-evaluation.
    private var fileURLObservation: NSKeyValueObservation?

    override class var autosavesInPlace: Bool {
        true
    }

    /// E6 — write an autosave checkpoint to `<bundle>/Autosave/`. Best-effort:
    /// untitled documents (no fileURL yet) and serialization failures are
    /// silent. Pruning happens inside the checkpointer.
    func writeAutosaveCheckpoint(reason: AutosaveCheckpoint.Reason) {
        guard let bundleURL = fileURL else { return }
        do {
            let data = try JSONEncoder.simplePlayback.encode(playbackDocument.project)
            try AutosaveCheckpointer.writeCheckpoint(
                projectData: data,
                bundleURL: bundleURL,
                reason: reason
            )
        } catch {
            // Best-effort. A failed checkpoint should never abort the
            // operator action that triggered it (Show Mode toggle).
        }
    }

    override init() {
        super.init()
        hasUndoManager = true
        fileURLObservation = observe(\.fileURL, options: [.initial, .new]) { [weak self] doc, _ in
            let url = doc.fileURL
            Task { @MainActor [weak self] in
                self?.lockController.evaluate(bundleURL: url)
                self?.crashRecoveryController.evaluate(bundleURL: url)
            }
        }
    }

    override func makeWindowControllers() {
        let rootView = RootView(
            document: documentBinding,
            outputSettings: OutputSettingsStore.shared,
            projectBundleURLProvider: { [weak self] in self?.fileURL },
            lockController: lockController,
            crashRecoveryController: crashRecoveryController,
            restoreFromCheckpoint: { [weak self] in
                self?.restoreProjectFromRecoverableCheckpoint() ?? false
            },
            autosaveCheckpoint: { [weak self] reason in
                self?.writeAutosaveCheckpoint(reason: reason)
            }
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

    /// Release the per-document lock when the window closes. NSDocument calls
    /// `close` on the main thread for the user-initiated close path; we
    /// release before chaining to `super` so a re-open in the same session
    /// (e.g. revert) sees a clean slate.
    override func close() {
        lockController.release()
        super.close()
    }

    /// E7 — load the recoverable checkpoint into `playbackDocument.project`,
    /// notifying the controller. Returns true on success so the caller (the
    /// banner's Restore button) can drive UX from the result. Marks the doc
    /// dirty so the operator's first save persists the recovered state.
    @MainActor
    func restoreProjectFromRecoverableCheckpoint() -> Bool {
        guard let data = crashRecoveryController.loadRecoverableData() else {
            return false
        }
        do {
            let restored = try JSONDecoder.simplePlayback.decode(PlayoutProject.self, from: data)
            playbackDocument.project = restored
            updateChangeCount(.changeDone)
            crashRecoveryController.didRestore()
            return true
        } catch {
            return false
        }
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
