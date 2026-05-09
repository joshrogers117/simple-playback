# Phase F — v2 enablement / cleanup pass — Summary

Phase F is the v1 wrap-up sweep. By spec §4 the v2 items are large enough that each deserves its own planning round; F's deliverable is the operator-visible cleanup that lets v1 be promoted with high confidence:

- F1 — code-reviewer sweep against the cumulative v1 diff (act on P0/P1 findings)
- F2 — README.md refresh (feature list, OSC API quickref, Companion install pointer)
- F3 — `docs/api.md` (OSC + HTTP + WebSocket + OSCQuery integrator reference)
- F4 — `docs/manual_verification.md` (consolidated rehearsal checklist; what to run on stock laptop vs hardware)
- F5 — test fixture audit (every committed fixture has a regeneration script)
- F6 — final phase summary + handoff document

**Phase F status**: complete for v1 as of session 26. F1 actionable items shipped (1 P0 + 4 P1s; 3 P2 deferred for future-session pickup); F2/F3/F4/F5/F6 all shipped. The v1 build is **code-complete**; production promotion still depends on the rehearsal cycle in `docs/manual_verification.md`.

---

## Session 26 (2026-05-08) — F5 fixture audit + F6 handoff doc

2 commits (this session), 747 tests unchanged (doc / script-only). Phase F closes for v1.

### F5 — `Scripts/regenerate-fixtures.sh` + `docs/test_fixtures.md`

The audit confirmed **zero committed binary fixtures** under `Simple PlaybackTests/`. Every test synthesizes its inputs at runtime — five canonical patterns:

- **PDF** via `CGDataConsumer` + `CGPDFContext` (canonical: `PDFImporterTests.makeTestPDF`).
- **Tiny H.264 `.mov`** via `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor` (canonical: `AVTrackLoaderTests.makeTinyH264Movie`; extended-with-codec variant in `MediaFlagsTests`).
- **Still PNG** via `CGContext` bitmap → `NSBitmapImageRep` → `.representation(using: .png, …)` (canonical: `MediaImporterPDFTests.makeStillPNG`).
- **Animated GIF / APNG** via `CGImageDestinationCreateWithURL` + per-frame `CGImageDestinationAddImage` (canonical: `AnimatedImageInspectorTests.makeGIF` / `makeAPNG`).
- **Sentinel `Data` blobs** for format-detection / failure-path tests (`Data()`, `Data([0x00, 0x01, 0x02])`, `Data("x".utf8)`).

`Scripts/regenerate-fixtures.sh` is the policy guard. It walks `Simple PlaybackTests/`, exits 0 if every file is `.swift` (with a `.DS_Store` exception), and exits 1 listing offenders if any non-Swift file appears. The script reserves an `ALLOWED_FIXTURES` array for future documented exceptions; today the array is empty. Manual run; not wired into CI per the runbook prohibition. Both polarities verified — clean repo emits "policy intact"; a planted `_fake.bin` flips it to exit 1 with the offender printed.

`docs/test_fixtures.md` documents the policy, catalogues the synthesis patterns, names the canonical helper for each, and lists the tests that use it. The "Adding a fixture if you must" section is the checklist a future contributor should follow if synthesis genuinely won't work — placement under `Simple PlaybackTests/Fixtures/<area>/`, per-fixture script under `Scripts/regenerate-fixtures/<name>.sh`, `ALLOWED_FIXTURES` update, doc update here, decision-log rationale entry.

### F6 — `docs/handoff.md`

Single-document handoff for the v1 build. Three audiences:

- **Integrators** → `docs/api.md`. Transports, ports, Bonjour, auth, every OSC/HTTP/WS/OSCQuery address with sample replies, OSCQuery handshake, timecode source-spec, idempotency keying, source-attribution mapping, worked examples, "not yet wired (v1 ack-only)" appendix.
- **Operators** → `docs/manual_verification.md` for the rehearsal protocol; README at the repo root for the feature surface walkthrough. Plus a "behaviour you should know about before the first show" list (Show Mode gating, PreShow check fix actions, crash recovery banner semantics, project-lock-file foreign-live banner, show-log persistence-suspended banner).
- **Future autonomy sessions** → `docs/runbook.md` + `docs/progress.md` + the per-phase summaries + `docs/decision_log.md` + `docs/blockers.md`. Read-order for picking up the loop.

Also catalogues:
- The open product blocker (C11-4 cue-inspector filmstrip scrub UI).
- Hardware-bound items (B6 REF format mismatch, B7/B9/B10/B11/B13/B15, C8 cross-host rehearsal, D12–D14 LTC/MTC/internal-TC verification, E1+ macOS-condition adapters).
- F1 P2 deferred items (project-lock-file hostname canonicalization, AVTrackLoader semaphore bridge, CompositorOverlays didSet ordering pin).
- Audio sub-phase explicitly out of scope for v1 (C12–C15).
- v2 enablement candidates (PowerPoint import, audio sub-phase, NDI Full sender, Director View, Saved Workspaces, brightness adapt key, Bundle for Travel cross-host rehearsal).

### CompositorOverlays didSet ordering pin — re-evaluated, dropped from session-26 scope

The session-25 deferred list called this out as a "low real-world risk" pin for Phase F. In session 26 I re-read `PlaybackController.republishComposedPreview()` (line 1186) and traced the publish path: `compositorOverlays = …` on main → `syncOutput` to read the snapshot → `compositor.compose(...)` back on main → `publishTransitionPreview(...)` which does `DispatchQueue.main.async { self.transitionPreviewImage = image }`. Two rapid writes from main enqueue their async-publish blocks in arrival order, and the main runloop drains FIFO from the same thread, so the order is preserved by construction. A meaningful pin would need pixel-content assertion to confirm the second image actually reflects the second overlays state, which pulls in a full pipeline — not a cheap test. Re-classified as redundant for v1; the deferred-item entry in `docs/handoff.md` notes the contract is FIFO-preserved but a Phase F entry-point that adds programmatic overlay automation should re-evaluate. No commit needed; this paragraph is the close-out.

### What's left in Phase F

Nothing for v1 close. The three F1 P2 deferred items remain as future-session pickup; they are documented in `docs/handoff.md`.

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
