import Foundation
#if canImport(IOKit)
import IOKit.pwr_mgt
#endif

/// Spec §3.16 — pre-show check should warn when macOS could put the machine
/// to sleep mid-show. Rather than just *checking*, we *act*: while the
/// operator has Show Mode on, hold an `IOPMAssertionTypeNoIdleSleep`
/// assertion so the OS literally cannot idle-sleep. The assertion is dropped
/// on Show Mode off (or when the document closes).
///
/// `EnergyAssertion` wraps the IOKit calls behind a small main-actor object.
/// `acquire()` is idempotent — calling twice keeps a single assertion.
/// `release()` clears it. The status is published for the pre-show check
/// rule + the status-bar (future).
///
/// Test seam: an injectable `assertor`/`releaser` pair on the type lets us
/// unit-test the state transitions without engaging IOKit.
@MainActor
final class EnergyAssertion: ObservableObject {

    /// True while we hold a no-idle-sleep assertion.
    @Published private(set) var isHeld: Bool = false

    /// Human-readable label shown in `pmset -g assertions`. Operators
    /// debugging power management on a show machine see this string.
    static let assertionName = "Simple Playback — Show Mode"

    private var assertionID: UInt32 = 0

    /// Test seams. Production paths talk to IOKit; tests substitute closures
    /// that record state without invoking the kernel.
    private let assertor: (String) -> UInt32?
    private let releaser: (UInt32) -> Void

    init(
        assertor: @escaping (String) -> UInt32? = EnergyAssertion.defaultAssertor,
        releaser: @escaping (UInt32) -> Void = EnergyAssertion.defaultReleaser
    ) {
        self.assertor = assertor
        self.releaser = releaser
    }

    /// Acquire the assertion. No-op if already held.
    func acquire() {
        guard !isHeld else { return }
        guard let id = assertor(Self.assertionName) else {
            return
        }
        assertionID = id
        isHeld = true
    }

    /// Release the assertion. No-op if not held.
    func release() {
        guard isHeld else { return }
        releaser(assertionID)
        assertionID = 0
        isHeld = false
    }

    /// Default IOKit-backed assertor. Returns the assertion ID on success;
    /// nil on failure (a failed assertion still lets the show go on — the
    /// pre-show check just won't flip green for this row).
    nonisolated static func defaultAssertor(_ name: String) -> UInt32? {
        #if canImport(IOKit)
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &id
        )
        guard result == kIOReturnSuccess else { return nil }
        return UInt32(id)
        #else
        return nil
        #endif
    }

    /// Default IOKit-backed releaser. Errors from the kernel are silent —
    /// the worst case is the assertion linger until process exit, which
    /// macOS cleans up automatically.
    nonisolated static func defaultReleaser(_ id: UInt32) {
        #if canImport(IOKit)
        _ = IOPMAssertionRelease(IOPMAssertionID(id))
        #endif
    }
}
