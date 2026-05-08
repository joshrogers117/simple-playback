import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// E8 — project lock file. Spec §3.16: warn on duplicate-open of NAS-shared
/// show files. The lock lives at `<bundle>/.lock` and records who has the
/// document open (PID + hostname + timestamp + app version). On open we read
/// it; if it represents a still-live owner we surface a non-modal banner with
/// "Open Anyway / Read Only / Cancel". On close we clear the file if we own
/// it.
///
/// **Cross-host realism**: a NAS-shared show may be claimed by a peer on a
/// different machine. We can't introspect a remote PID's liveness, so cross-
/// host locks fall back to a timestamp staleness window. Within the same host
/// we can ask the kernel whether the PID is alive.
struct ProjectLockFile: Codable, Equatable {

    /// PID of the process that wrote the lock.
    let pid: Int32
    /// `Host.current().localizedName` (or `gethostname` fallback) at write time.
    let hostname: String
    /// Wall-clock time the lock was written (refreshed on every write — see
    /// `refresh(now:)`).
    let timestamp: Date
    /// App version string for forensics — non-load-bearing today, but useful
    /// if a future version changes the lock layout.
    let applicationVersion: String?

    /// File name inside the bundle. The leading dot keeps it out of Finder's
    /// default file view.
    static let filename = ".lock"

    /// Cross-host staleness window. Locks older than this with a different
    /// hostname are considered stale (peer probably crashed without cleaning
    /// up). One hour is the conservative pick: a real operator on a remote
    /// host would see lock activity within minutes.
    static let foreignStaleAfter: TimeInterval = 60 * 60

    /// Same-host staleness window for the case where the PID can't be
    /// resolved (extremely rare — kill -0 returns success or ESRCH). Falls
    /// back to a tighter 5-minute window because we should know quickly when
    /// our own host has gone stale.
    static let localFallbackStaleAfter: TimeInterval = 5 * 60

    /// Result of evaluating an existing lock file against the current host /
    /// process. Drives the banner UX:
    /// - `.ours` → silent (re-opened our own document).
    /// - `.localLive` / `.foreignLive` → warn the operator.
    /// - `.localStale` / `.foreignStale` → safe to ignore + overwrite.
    enum Liveness: Equatable {
        /// The lock matches our own pid + hostname (idempotent reopen).
        case ours
        /// Same host, different PID, PID is still running.
        case localLive
        /// Same host, different PID, PID is dead.
        case localStale
        /// Different host, timestamp within `foreignStaleAfter`.
        case foreignLive
        /// Different host, timestamp older than `foreignStaleAfter`.
        case foreignStale
    }

    /// Pure-logic liveness evaluator. Tests pin every branch; production
    /// callers pass in the real `kill(pid, 0)` predicate.
    func liveness(
        now: Date,
        currentPID: Int32,
        currentHostname: String,
        isPIDAlive: (Int32) -> Bool,
        foreignStaleAfter: TimeInterval = ProjectLockFile.foreignStaleAfter,
        localFallbackStaleAfter: TimeInterval = ProjectLockFile.localFallbackStaleAfter
    ) -> Liveness {
        if hostname == currentHostname {
            if pid == currentPID {
                return .ours
            }
            if isPIDAlive(pid) {
                return .localLive
            }
            // PID is dead — local stale. Timestamp doesn't matter; the OS
            // recycled the slot.
            _ = localFallbackStaleAfter
            return .localStale
        } else {
            let age = now.timeIntervalSince(timestamp)
            if age > foreignStaleAfter {
                return .foreignStale
            }
            return .foreignLive
        }
    }

    /// Operator-facing banner copy. Kept in pure-logic so tests can pin the
    /// strings.
    var bannerSummary: String {
        let dateString = ProjectLockFile.bannerDateFormatter.string(from: timestamp)
        return "Opened on \(hostname) (PID \(pid)) at \(dateString)"
    }

    private static let bannerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()
}

/// CRUD against the `.lock` file inside a project bundle. All file I/O lives
/// behind injectable seams so tests can drive every branch without touching
/// the filesystem.
enum ProjectLockFileIO {

    /// Returns the lock-file URL inside `bundleURL`. Pure-logic — no I/O.
    static func lockURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(ProjectLockFile.filename, isDirectory: false)
    }

    /// Read + decode an existing lock file. Returns nil for "no lock" or
    /// malformed contents (we treat unreadable locks as no lock — safer to
    /// let the operator open than to refuse over a corrupt file).
    static func read(
        bundleURL: URL,
        fileReader: (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) -> ProjectLockFile? {
        let url = lockURL(in: bundleURL)
        guard let data = try? fileReader(url) else { return nil }
        return try? JSONDecoder().decode(ProjectLockFile.self, from: data)
    }

    /// Write a fresh lock file. Overwrites if one exists — callers handle
    /// "is it ours?" via `ProjectLockFile.liveness` before deciding to
    /// overwrite.
    static func write(
        _ lock: ProjectLockFile,
        bundleURL: URL,
        fileWriter: (URL, Data) throws -> Void = { url, data in
            try data.write(to: url, options: .atomic)
        }
    ) throws {
        let url = lockURL(in: bundleURL)
        let data = try JSONEncoder().encode(lock)
        try fileWriter(url, data)
    }

    /// Remove the lock file. Silent on absence (the bundle may have been
    /// cleaned up by another process, or never had a lock to begin with).
    static func remove(
        bundleURL: URL,
        fileRemover: (URL) throws -> Void = { url in
            try FileManager.default.removeItem(at: url)
        }
    ) {
        let url = lockURL(in: bundleURL)
        try? fileRemover(url)
    }
}

/// Captures the runtime signals (current PID, hostname, app version) so
/// callers don't have to assemble a `ProjectLockFile` by hand. Tests inject
/// fixed values; production reads from the OS.
struct ProjectLockFileSignals {

    let pid: Int32
    let hostname: String
    let applicationVersion: String?

    static func current() -> ProjectLockFileSignals {
        ProjectLockFileSignals(
            pid: ProjectLockFileSignals.currentPID(),
            hostname: ProjectLockFileSignals.currentHostname(),
            applicationVersion: ProjectLockFileSignals.currentApplicationVersion()
        )
    }

    /// Build a lock instance stamped with `now`.
    func makeLock(now: Date = Date()) -> ProjectLockFile {
        ProjectLockFile(
            pid: pid,
            hostname: hostname,
            timestamp: now,
            applicationVersion: applicationVersion
        )
    }

    static func currentPID() -> Int32 {
        #if canImport(Darwin)
        return getpid()
        #else
        return 0
        #endif
    }

    /// Prefer `gethostname(2)` — it's the kernel's canonical identifier and
    /// matches what other processes on the same machine see. `Host.current()`
    /// is the AppKit alternative but it's `@MainActor`-bound and overkill
    /// for a string we just need at write time.
    static func currentHostname() -> String {
        #if canImport(Darwin)
        var buf = [CChar](repeating: 0, count: 256)
        if gethostname(&buf, buf.count) == 0 {
            return String(cString: buf)
        }
        #endif
        return "unknown"
    }

    /// Standard "is this PID still alive" predicate: `kill(pid, 0)` returns
    /// 0 if the PID exists and we have permission to signal it, ESRCH if it
    /// does not. Permission errors (EPERM) mean the PID does exist — the
    /// signal was just blocked.
    static func isPIDAliveDefault(_ pid: Int32) -> Bool {
        #if canImport(Darwin)
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
        #else
        return false
        #endif
    }

    private static func currentApplicationVersion() -> String? {
        #if canImport(Darwin)
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        #else
        return nil
        #endif
    }
}
