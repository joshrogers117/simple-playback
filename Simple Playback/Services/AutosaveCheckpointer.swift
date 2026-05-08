import Foundation

/// E6 — autosave checkpoint. Independent of `NSDocument.autosavingDelay = 30`
/// (the 30-second autosave runs through NSDocument's normal autosave-in-place
/// machinery; that's the "rolling" save the operator sees on quit-without-save
/// recovery). This file handles the spec §3.16 *checkpoint* — a snapshot
/// pinned to a meaningful operator action (Show Mode toggle today) so the
/// operator can roll back to "what the project looked like the moment we went
/// live" rather than "what was on disk 20 seconds before".
///
/// On-disk shape: `<bundle>/Autosave/<timestamp>__<reason>.json`. The JSON
/// payload is the entire `PlayoutProject` so a checkpoint is independently
/// loadable. Newest 20 retained per the spec; older are pruned at write
/// time.
struct AutosaveCheckpoint: Equatable {
    let timestamp: Date
    let reason: Reason

    enum Reason: String, Equatable, CaseIterable {
        /// Operator turned Show Mode on (about to go live).
        case showModeOn = "show_mode_on"
        /// Operator turned Show Mode off (left live).
        case showModeOff = "show_mode_off"
        /// Reserved for a future "Checkpoint Now" affordance.
        case manual = "manual"
    }

    /// Filename within `<bundle>/Autosave/`. Uses an underscore-separated
    /// timestamp (`YYYY-MM-DDTHHmmssZ`) so files sort lexicographically by
    /// chronology and the format-version bump in the future doesn't fight
    /// with shell tab-completion.
    var filename: String {
        let stamp = AutosaveCheckpoint.timestampFormatter.string(from: timestamp)
        return "\(stamp)__\(reason.rawValue).json"
    }

    /// Parse a filename back into a checkpoint. Used by the prune step to
    /// sort by timestamp without trusting the file system's mtime
    /// (atime/mtime can drift on networked file systems).
    static func parse(filename: String) -> AutosaveCheckpoint? {
        // Format: `<stamp>__<reason>.json`
        guard filename.hasSuffix(".json") else { return nil }
        let trimmed = String(filename.dropLast(".json".count))
        let parts = trimmed.components(separatedBy: "__")
        guard parts.count == 2,
              let date = AutosaveCheckpoint.timestampFormatter.date(from: parts[0]),
              let reason = Reason(rawValue: parts[1]) else { return nil }
        return AutosaveCheckpoint(timestamp: date, reason: reason)
    }

    /// Lexically-sortable timestamp formatter. Independent of locale; UTC.
    /// Avoids `:` so the filename is portable across SMB and exFAT.
    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}

/// CRUD against `<bundle>/Autosave/`. Pure-logic split: production wires
/// real `FileManager` I/O, tests wire captured-list / captured-write
/// closures.
enum AutosaveCheckpointer {

    /// Spec §3.16: "every 30 s of edit activity to bundle Autosave/, last
    /// 20 retained." The 30 s side runs through NSDocument autosave-in-place;
    /// the *checkpoint* on Show-Mode toggle reuses the same retention.
    static let retentionLimit = 20

    /// Subdirectory inside the project bundle.
    static let directoryName = "Autosave"

    /// Resolve the autosave directory for a given bundle URL.
    static func directory(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Pure-logic: given a list of existing checkpoint filenames and a
    /// retention limit, return the *filenames* that should be pruned. Sorted
    /// oldest-first so the caller can delete in order without re-sorting.
    static func filenamesToPrune(
        existing filenames: [String],
        retentionLimit: Int = retentionLimit
    ) -> [String] {
        let parsed = filenames.compactMap { name -> (String, AutosaveCheckpoint)? in
            guard let cp = AutosaveCheckpoint.parse(filename: name) else { return nil }
            return (name, cp)
        }
        // Oldest first.
        let sorted = parsed.sorted { $0.1.timestamp < $1.1.timestamp }
        guard sorted.count > retentionLimit else { return [] }
        let pruneCount = sorted.count - retentionLimit
        return sorted.prefix(pruneCount).map { $0.0 }
    }

    /// Write a checkpoint to disk and prune older ones to fit the retention
    /// limit. Returns the URL written.
    @discardableResult
    static func writeCheckpoint(
        projectData: Data,
        bundleURL: URL,
        timestamp: Date = Date(),
        reason: AutosaveCheckpoint.Reason,
        retentionLimit: Int = retentionLimit,
        directoryCreator: (URL) throws -> Void = { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        },
        directoryLister: (URL) throws -> [String] = { url in
            try FileManager.default.contentsOfDirectory(atPath: url.path)
        },
        fileWriter: (URL, Data) throws -> Void = { url, data in
            try data.write(to: url, options: .atomic)
        },
        fileRemover: (URL) throws -> Void = { url in
            try FileManager.default.removeItem(at: url)
        }
    ) throws -> URL {
        let dir = directory(in: bundleURL)
        try directoryCreator(dir)
        let checkpoint = AutosaveCheckpoint(timestamp: timestamp, reason: reason)
        let url = dir.appendingPathComponent(checkpoint.filename)
        try fileWriter(url, projectData)

        // Prune. Read the directory *after* the write so the new checkpoint
        // counts toward the retention limit (a 21-deep history immediately
        // drops the oldest, keeping disk footprint bounded).
        let existing = (try? directoryLister(dir)) ?? []
        let toPrune = filenamesToPrune(existing: existing, retentionLimit: retentionLimit)
        for name in toPrune {
            try? fileRemover(dir.appendingPathComponent(name))
        }
        return url
    }
}
