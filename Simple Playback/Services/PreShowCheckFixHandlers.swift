import Foundation

/// E2 — per-row fix-action handlers for the pre-show check panel. Every
/// `PreShowCheck.Row` carries a stable `id`; the host (`RootView`) builds a
/// `PreShowCheckFixHandlers` whose `byRowID` dictionary maps each id to a
/// single closure that resolves the issue (open a deep-link, reveal the
/// project bundle, etc.). The view renders a "Fix" button only on rows the
/// host has registered something for, so rules without a sensible automatable
/// resolution (e.g. frame-rate conformance, which is project-edit territory)
/// stay read-only.
///
/// Tests inject custom handlers directly so the fix surface is unit-testable
/// without touching `NSWorkspace`.
struct PreShowCheckFixHandlers {

    /// Handlers keyed by `PreShowCheck.Row.id`. Missing ids → no Fix button.
    var byRowID: [String: () -> Void] = [:]

    func canFix(_ row: PreShowCheck.Row) -> Bool {
        byRowID[row.id] != nil
    }

    func fix(_ row: PreShowCheck.Row) {
        byRowID[row.id]?()
    }
}

/// macOS deep-link targets the host registers from. Exposed at module scope
/// so handlers and tests can both reference the URLs without duplication.
enum PreShowFixDeepLinks {

    /// System Settings → Sound. Legacy URL form; macOS 26's System Settings
    /// still resolves it. Used by the `system.audio` Fix (no audio device)
    /// and as a fallback for `output.reference` when Blackmagic Desktop Video
    /// Setup isn't installed.
    static let soundSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.sound"
    )!

    /// Standard install path for Blackmagic Desktop Video Setup. The DeckLink
    /// REF/format/output configuration lives there, so it's the right "Fix"
    /// destination when the operator's project expects external reference but
    /// the bridge reports `unlocked` or `notSupported`.
    static let blackmagicDesktopVideoSetupAppPath =
        "/Applications/Blackmagic Desktop Video Setup.app"
}
