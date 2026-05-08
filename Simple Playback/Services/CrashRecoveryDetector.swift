import Foundation

/// E7 — crash-recovery detection. On document open, look at
/// `<bundle>/Autosave/` for any checkpoint newer than the on-disk
/// `Show.json`. If one exists, the previous app session likely
/// terminated abnormally (regular Save/Quit overwrites Show.json,
/// keeping it ahead of any checkpoint). Surface a banner offering to
/// restore from the latest checkpoint.
///
/// Pure-logic: `findRecoverableCheckpoint` decides eligibility from
/// directory contents and modification dates. Tests inject the listing
/// + mtime callbacks; production wires `FileManager`.
enum CrashRecoveryDetector {

    /// Outcome of a recovery scan.
    struct Recoverable: Equatable {
        /// Filename inside `<bundle>/Autosave/`.
        let filename: String
        /// Parsed checkpoint metadata (timestamp + reason).
        let checkpoint: AutosaveCheckpoint
    }

    /// Look up a candidate checkpoint to offer for recovery. Returns nil
    /// when the bundle has no autosave directory, no parseable
    /// checkpoints, or every checkpoint is older than Show.json.
    static func findRecoverableCheckpoint(
        bundleURL: URL,
        directoryLister: (URL) throws -> [String] = { url in
            try FileManager.default.contentsOfDirectory(atPath: url.path)
        },
        modificationDate: (URL) -> Date? = { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return values?.contentModificationDate
        }
    ) -> Recoverable? {
        let autosaveDir = AutosaveCheckpointer.directory(in: bundleURL)
        let showJSON = bundleURL.appendingPathComponent(ProjectBundleLayout.projectFilename)
        let savedMTime = modificationDate(showJSON)

        let filenames: [String]
        do {
            filenames = try directoryLister(autosaveDir)
        } catch {
            // Most common cause: directory does not exist (no checkpoint
            // has ever been written). Treat as "nothing to recover".
            return nil
        }

        let parsed: [Recoverable] = filenames.compactMap { name in
            guard let cp = AutosaveCheckpoint.parse(filename: name) else { return nil }
            return Recoverable(filename: name, checkpoint: cp)
        }
        // Newest first — recovery offers the latest snapshot.
        let sorted = parsed.sorted { $0.checkpoint.timestamp > $1.checkpoint.timestamp }
        guard let candidate = sorted.first else { return nil }

        // If we have a saved Show.json, only suggest recovery when the
        // checkpoint is strictly newer than the saved project. Equal
        // timestamps don't trigger recovery — they typically mean a
        // clean shutdown after Show Mode toggle.
        if let savedMTime,
           candidate.checkpoint.timestamp <= savedMTime {
            return nil
        }
        return candidate
    }

    /// Read the project bundle from a checkpoint file. Returns the raw
    /// JSON data so callers can decode it into their own `PlayoutProject`
    /// (decoder knowledge stays in the document layer).
    static func readCheckpointData(
        bundleURL: URL,
        filename: String,
        fileReader: (URL) throws -> Data = { url in
            try Data(contentsOf: url)
        }
    ) throws -> Data {
        let url = AutosaveCheckpointer.directory(in: bundleURL)
            .appendingPathComponent(filename)
        return try fileReader(url)
    }

    /// Discard *every* checkpoint in the autosave directory. Operators
    /// pick this when they don't want the recovered state — typically
    /// because they know what they were doing when the app died.
    static func discardCheckpoints(
        bundleURL: URL,
        directoryRemover: (URL) throws -> Void = { url in
            try FileManager.default.removeItem(at: url)
        }
    ) throws {
        let dir = AutosaveCheckpointer.directory(in: bundleURL)
        try directoryRemover(dir)
    }
}
