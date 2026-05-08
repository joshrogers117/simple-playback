import Foundation

/// Adapters that translate live system signals into the pure-logic
/// `PreShowCheck.Context`. Keeping these in their own file lets `PreShowCheck.swift`
/// stay free of DeckLink / IOKit / CoreAudio imports — every rule remains
/// independently unit-testable from its source enum value.
extension PreShowCheck.DeckLinkReferenceStatus {

    /// Translate the live `DeckLinkTransportSink.ReferenceState` into the pre-show
    /// check's reference enum. The mapping mirrors how the B6 status-bar chip
    /// reads the bridge today:
    ///
    /// - `.idle` (bridge created but not yet armed) → `.notRequired`. Pre-show
    ///   reads this as "DeckLink not yet armed" — the operator should re-check
    ///   after starting output, not be alarmed mid-setup.
    /// - `.notSupported`, `.unlocked`, `.locked` map directly. PreShowCheck
    ///   escalates only when the operator's project intent
    ///   (`expectsExternalReference == true`) collides with `.unlocked`.
    static func from(_ state: DeckLinkTransportSink.ReferenceState)
        -> PreShowCheck.DeckLinkReferenceStatus
    {
        switch state {
        case .idle: return .notRequired
        case .notSupported: return .notSupported
        case .unlocked: return .unlocked
        case .locked: return .locked
        }
    }
}
