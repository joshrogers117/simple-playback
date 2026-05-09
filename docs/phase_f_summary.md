# Phase F — v2 enablement / cleanup pass — Summary

Phase F is the v1 wrap-up sweep. By spec §4 the v2 items are large enough that each deserves its own planning round; F's deliverable is the operator-visible cleanup that lets v1 be promoted with high confidence:

- F1 — code-reviewer sweep against the cumulative v1 diff (act on P0/P1 findings)
- F2 — README.md refresh (feature list, OSC API quickref, Companion install pointer)
- F3 — `docs/api.md` (OSC + HTTP + WebSocket + OSCQuery integrator reference)
- F4 — `docs/manual_verification.md` (consolidated rehearsal checklist; what to run on stock laptop vs hardware)
- F5 — test fixture audit (every committed fixture has a regeneration script)
- F6 — final phase summary + handoff document

---

## Session 25 (2026-05-08) — F1 reviewer sweep + F2 README + F3 api.md

7 commits, 741 → 747 tests (+6). All 5 actionable findings from the F1 reviewer pass shipped as hardening commits, plus F2 + F3 doc-only deliverables.

### F1 reviewer punch list outcome

The F1 sweep found **1 P0 + 4 P1s + 3 deferred items** against the cumulative diff from Phase A start through the session-24 close. All 5 actionable findings folded in this session.

**P0 — `CueRuntime` unsynchronized across OSC/HTTP queues vs main** (`Simple Playback/Playback/CueRuntime.swift` consumed by `ShowControlDispatcher.swift`).

OSC and HTTP arrive on `NWConnection` queues; local operator GO/PREV/PANIC/CLEAR runs on main via `ShowController`. Without serialization a Companion fire racing an operator press could mutate `showList`, `cueStates`, `panicActive`, and the GO debounce simultaneously from two threads. The smallest correct fix wraps the host-interceptor + `perform()` block inside `dispatch(...)` in a `Thread.isMainThread`-guarded `DispatchQueue.main.sync` hop. Capability check + idempotency lockout stay off main (they already use their own synchronization). The thread-guard avoids deadlocking when XCTest happens to call `dispatch` from the main thread; tests that already exercise `dispatcher.dispatch(...)` continue to pass.

Two new pin tests in `ShowControlTests`: off-main dispatch hops to main + returns synchronously, and on-main dispatch doesn't deadlock.

**P1 — `FilmstripCoordinator.writer` Sendable seam** (`Services/FilmstripCoordinator.swift:53`). The static `writer` test seam was `nonisolated(unsafe)` but the closure type was plain `(Data, URL) throws -> Void`, captured implicitly inside `Task.detached`. Mismatch with the sibling `generator` seam two lines up. Fix: annotate with `@Sendable`. Closes a Swift 6 strict-concurrency hole; no test churn (pure closure substitutions already meet `@Sendable`).

**P1 — `PlaybackController.hasRenderedAnyFrame` flipped off main** (`PlaybackController.swift:1404`). `submitFrame` runs on `outputQueue`; flipping the `@Published` flag from there published a Combine notification on the wrong thread the first time a session composed a frame. Mirrored the dropped-frame-counter pattern at line 1481: dispatch the flip back to main with a re-check guard so the hop only fires once per session.

**P1 — `CompositeVideoOutputDriver.activeDriver` raced between video + audio queues** (`Output/VideoOutput.swift:118`). `submitVideoFrame` runs on the playback `outputQueue`; `submitAudioPCM16` runs on a separate audio queue. Both read `activeDriver` while `start`/`stop` write it. Same Swift memory-model hazard the C16 close-out fixed for `CompositorPipeline.bundleMediaDirectory`. Fix mirrored the existing pattern: backing storage `_activeDriver` + computed `activeDriver` going through `driverLock: NSLock`. Public surface unchanged.

**P1 — `ShowLog` silently dropped persistence on writer failure** (`ShowLog.swift:168-174`). On a failed CSV write the writer cleared `fileURL = nil` and continued in memory with no operator-visible signal. Spec §3.16 lists the on-disk log as a v1 reliability artifact, so silent drop is not acceptable. Added `@Published var persistenceState: .healthy | .suspended(reason: String)`; failures flip the state and clear `fileURL` so subsequent appends short-circuit. `ShowLogView` renders an orange banner. Operator re-arms via `setFileURL`, which resets to `.healthy`. 4 new pin tests in `ShowLogTests`. (Detail also lives in `phase_e_summary.md` session-25 entry — Phase E owns the show-log primitive.)

### Deferred (P2 — future-session pickup)

- **Project-lock-file hostname canonicalization** — `ProjectLockFile.swift:198` uses `gethostname(2)` while other macOS apps may record `Host.current().localizedName`. Two writers using the two APIs would not see each other's locks as `localLive`. Cross-host rehearsal needed before committing to one source.
- **`AVTrackLoader.loadFirstVideoTrackInspection` semaphore bridge** — issues `Task.detached` then blocks the calling thread on a semaphore. Acceptable today (every caller is import-time / off-render-hot-path) but blocking the cooperative thread pool from a sync entry is a known footgun. Migrate to a true async API at the Phase F audio refactor.
- **`PlaybackController.compositorOverlays.didSet` re-publish ordering** — two rapid overlay edits during a take can interleave the published preview images out of order. Low real-world risk (operator-paced edits) but worth a small ordering pin if Phase F adds programmatic overlay automation.

### F2 — README.md

Grew from a 36-line stub into a v1 feature surface walkthrough — Phase A/B/C/D/E inventories, OSC quick-reference table, project-bundle layout, hardware-verification cross-reference. Companion module path documented as a sibling-repo deliverable.

### F3 — docs/api.md

New 441-line integrator reference: transports + ports + Bonjour, auth + capability semantics, every OSC/HTTP/WS address with sample reply envelopes, OSCQuery handshake (`HOST_INFO`, `VALUE`), timecode source-spec strings, idempotency keying table, source-attribution mapping, worked curl/websocat/oscsend examples, "not yet wired (v1 ack-only)" appendix calling out scrub / opacity / audio-level / goto / look-recall / output-freeze / workspace-save until host interceptors land. Cross-linked from README.md.

### Test surface session 25

747 tests across the suite (was 741 at session-24 close):
- `ShowLogTests` +4 (persistence-state pins)
- `ShowControlTests` +2 (off-main hop + on-main no-deadlock pins)

### Manual verification session 25

The session-25 changes are all software-only — the threading hops and the persistence banner verify without hardware. Manual rehearsal items from prior sessions (DeckLink REF lock, LTC chase, real Companion, etc.) remain unchanged in `docs/manual_verification.md`.

### What's left in Phase F

- F1 P2 deferred items (above) — pick up when the next reviewer-sweep session runs.
- F5 — test fixture audit. Each fixture committed under `Simple PlaybackTests/Fixtures/` should have a regeneration script. Today most fixtures are inline-built or tiny synthetic data; the few binary fixtures (PDFs, sample images) need a script in `Scripts/` so a future maintainer can regenerate from source.
- F6 — final phase summary + handoff document. Written once F5 closes and any further reviewer-sweep findings settle. The handoff doc points integrators at `docs/api.md`, points operators at `docs/manual_verification.md`, points future autonomy sessions at `docs/runbook.md` + `docs/progress.md`, and lists the v2-enablement candidates (PowerPoint import, audio sub-phase, etc.).
