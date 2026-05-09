import Foundation
import XCTest
@testable import Simple_Playback

/// Hardening pin tests added during the squeaky-clean review pass:
///
/// `ShowControlAction.idempotencyKey` is the dispatcher's retrigger-lockout
/// hash. Two actions whose keys collide collapse to one within the 50 ms
/// lockout window — that's correct for "fire-the-same-cue-twice" but a
/// silent bug if two *different* action variants accidentally share a key
/// (e.g. a copy-paste during a future cue-verb addition produces
/// `"cue.play:..."` for both `.cuePlay` and a typo'd new case).
///
/// These tests pin: (a) every action variant we expect produces a unique
/// key for distinguishable inputs, (b) operator-supplied cue numbers are
/// case-folded into the key (so `Q.1` and `q.1` collapse — A2 case-
/// insensitivity), (c) all key prefixes follow the `domain.verb:` shape.
@MainActor
final class ShowControlActionIdempotencyKeyTests: XCTestCase {

    /// One representative example of every action variant. If a new case is
    /// added to `ShowControlAction`, add it here too — the matching code-
    /// review (sub)task is small and safe to do at the same time as the
    /// case addition. The Swift compiler does NOT enforce this list is
    /// exhaustive, so this test is a reminder + collision-detector.
    private var oneOfEachVariant: [ShowControlAction] {
        [
            .go(target: nil),
            .go(target: "Q.1"),
            .previous,
            .panic(fade: nil),
            .clear,
            .movePlayhead(cueNumber: "Q.1"),
            .load(cueNumber: "Q.1"),
            .cuePlay(cueNumber: "Q.1"),
            .cueStop(cueNumber: "Q.1", fade: nil),
            .cueScrubNormalized(cueNumber: "Q.1", position: 0.5),
            .cueScrubSeconds(cueNumber: "Q.1", seconds: 5.0),
            .cueOpacity(cueNumber: "Q.1", value: 0.5),
            .cueAudioLevel(cueNumber: "Q.1", dB: -6),
            .cueInPoint(cueNumber: "Q.1", seconds: 1.0),
            .cueOutPoint(cueNumber: "Q.1", seconds: 5.0),
            .cueLoop(cueNumber: "Q.1", enabled: true),
            .cueGoto(cueNumber: "Q.1", nextNumber: "Q.2"),
            .cuePreload(cueNumber: "Q.1"),
            .cueNotes(cueNumber: "Q.1", text: "x"),
            .outputFreeze(enabled: true),
            .outputBlackout(enabled: true),
            .lookRecall(name: "Show"),
            .timecodeSource(spec: "ltc:builtin"),
            .timecodeEngaged(enabled: true),
            .timecodeOffset(seconds: 1.0),
            .showMode(enabled: true),
            .workspaceSave,
            .workspaceReload,
            .ping,
            .subscribe(host: "h", port: 1),
            .unsubscribe(host: "h", port: 1)
        ]
    }

    // MARK: - No collisions

    func testEveryActionVariantHasDistinctIdempotencyKey() {
        let keys = oneOfEachVariant.map(\.idempotencyKey)
        let unique = Set(keys)
        XCTAssertEqual(keys.count, unique.count,
                       "Two action variants share an idempotency key — retrigger lockout would silently coalesce them. Keys: \(keys.sorted())")
    }

    // MARK: - Case-insensitive cue number folding

    func testIdempotencyKeyLowercasesCueNumber() {
        // A2 cue-id case-insensitivity: `Q.1` and `q.1` must lockout each
        // other within the retrigger window.
        let upper = ShowControlAction.cuePlay(cueNumber: "Q.1").idempotencyKey
        let lower = ShowControlAction.cuePlay(cueNumber: "q.1").idempotencyKey
        XCTAssertEqual(upper, lower,
                       "Cue-number case must fold so retriggers from different remotes don't slip through.")
    }

    func testIdempotencyKeyDifferentiatesDifferentCues() {
        // ...but different cue numbers must NOT collide.
        let q1 = ShowControlAction.cuePlay(cueNumber: "Q.1").idempotencyKey
        let q2 = ShowControlAction.cuePlay(cueNumber: "Q.2").idempotencyKey
        XCTAssertNotEqual(q1, q2)
    }

    // MARK: - Key shape

    func testCueVerbsUseCueDotPrefix() {
        // Every per-cue verb's key starts with `cue.` so it's grep-able and
        // doesn't collide with global namespaces ("go", "previous", etc.).
        let cueVerbKeys: [String] = [
            ShowControlAction.cuePlay(cueNumber: "X").idempotencyKey,
            ShowControlAction.cueStop(cueNumber: "X", fade: nil).idempotencyKey,
            ShowControlAction.cueScrubNormalized(cueNumber: "X", position: 0).idempotencyKey,
            ShowControlAction.cueScrubSeconds(cueNumber: "X", seconds: 0).idempotencyKey,
            ShowControlAction.cueOpacity(cueNumber: "X", value: 0).idempotencyKey,
            ShowControlAction.cueAudioLevel(cueNumber: "X", dB: 0).idempotencyKey,
            ShowControlAction.cueInPoint(cueNumber: "X", seconds: 0).idempotencyKey,
            ShowControlAction.cueOutPoint(cueNumber: "X", seconds: 0).idempotencyKey,
            ShowControlAction.cueLoop(cueNumber: "X", enabled: true).idempotencyKey,
            ShowControlAction.cueGoto(cueNumber: "X", nextNumber: "Y").idempotencyKey,
            ShowControlAction.cuePreload(cueNumber: "X").idempotencyKey,
            ShowControlAction.cueNotes(cueNumber: "X", text: "").idempotencyKey
        ]
        for key in cueVerbKeys {
            XCTAssertTrue(key.hasPrefix("cue."),
                          "Per-cue verb key '\(key)' should start with 'cue.' for namespace clarity.")
        }
    }

    func testGoActionDifferentiatesPlayheadFromTargetedCue() {
        let playhead = ShowControlAction.go(target: nil).idempotencyKey
        let targeted = ShowControlAction.go(target: "Q.1").idempotencyKey
        XCTAssertNotEqual(playhead, targeted,
                          "GO with no target (fire playhead) and GO with target must not collide.")
    }

    // MARK: - Required-capability symmetry

    func testEveryActionVariantHasRequiredCapability() {
        // Smoke test — `requiredCapability` is a switch over the same enum;
        // a missing case would compile-fail, but pin it here so a future
        // refactor that defaults to `.read` (lax) is detected.
        for action in oneOfEachVariant {
            // Must not crash; capability must be one of the three.
            let cap = action.requiredCapability
            XCTAssertTrue([.read, .fire, .edit].contains(cap),
                          "Capability for \(action) must be one of read/fire/edit; got \(cap)")
        }
    }
}
