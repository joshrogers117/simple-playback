# Phase F — v2 enablement / cleanup pass — Summary

Phase F is the v1 wrap-up sweep. By spec §4 the v2 items are large enough that each deserves its own planning round; F's deliverable is the operator-visible cleanup that lets v1 be promoted with high confidence:

- F1 — code-reviewer sweep against the cumulative v1 diff (act on P0/P1 findings)
- F2 — README.md refresh (feature list, OSC API quickref, Companion install pointer)
- F3 — `docs/api.md` (OSC + HTTP + WebSocket + OSCQuery integrator reference)
- F4 — `docs/manual_verification.md` (consolidated rehearsal checklist; what to run on stock laptop vs hardware)
- F5 — test fixture audit (every committed fixture has a regeneration script)
- F6 — final phase summary + handoff document

**Phase F status**: complete for v1 as of session 26. F1 actionable items shipped (1 P0 + 4 P1s; 3 P2 deferred — one of those P2s shipped opportunistically in session 28). F2/F3/F4/F5/F6 all shipped. The v1 build is **code-complete**; production promotion still depends on the rehearsal cycle in `docs/manual_verification.md`.

Sessions 27-28 added **v2 enablement pre-scoping** (`docs/v2/`) — doc-only and orthogonal to Phase F's v1 close-out, but recorded here because it's the natural next-after-Phase-F deliverable in the autonomous loop's option menu. Session 28 also shipped a tiny F1 P2 follow-up to close a Swift-concurrency hazard in the dispatcher's show-log fan-out.

---

## Session 28 (2026-05-08) — Option D reviewer sweep + Option F more v2 pre-scoping

2 commits, 747 → 749 tests (+2). Session ran two of the autonomous-friendly options from the session-27 next-session prompt menu in one batch: Option D (reviewer sweep against the session 25-27 cumulative diff) and Option F (pre-scope additional v2 candidates not in the session-27 batch).

### What shipped — F1 P2 follow-up: dispatcher onActionDispatched main hop

The reviewer sweep against `git diff development~10..HEAD` flagged one P2 finding in the session-25 P0 dispatcher fix: `runOnMain` moved CueRuntime mutation onto main, but the `onActionDispatched` callback was still invoked on the calling thread (network queue for OSC/HTTP). Its production consumer is `ShowController.recordDispatchedAction`, a `@MainActor`-isolated method that calls `ShowLog.appendNow` (also `@MainActor`). Same Swift concurrency hazard as the just-fixed runtime hop, one layer further out.

Shipped a `notifyDispatched(...)` helper that hops to main when called from off-main; routed the three callback fire sites (capability rejection, idempotency rejection, post-perform) through it. Async (not sync) to avoid a class of network-queue → main deadlock when the callback eventually appends to the show log. Two new pin tests in `ShowControlTests.swift` cover both the success-path and rejection-path callback firing on main from an off-main caller.

Decision-log entry covers the alternatives considered (sync hop / consumer-side hop / @MainActor signature) + the leverage call.

### What shipped — `docs/v2/` 6 more candidates

Six additional planning docs + a refreshed README index covering the highest-leverage spec §4 items not pre-scoped in session 27:

- `docs/v2/output_profile_looks.md` (spec §4 #1) — closes the loop on Phase B's schema-only `OutputBindingProfile`. Addresses the per-project-vs-per-machine question (recommend: both, with project carrying defaults + machine overriding), the Look-recall fade semantics (recommend: gamma-aware crossfade default, per-Look configurable), the active-profile drift detection, the recall-failure-fallback banner. Unblocks the long-promised `/sp/look/recall` ack-only stub. 5-7 commits estimated.
- `docs/v2/midi_show_control.md` (spec §4 #4) — inbound MSC SysEx → `ShowControlAction` translator, "thin layer over OSC" per spec. Addresses the device-ID configuration question (recommend: configurable, default `0x10`), the command-format filter (recommend: any with operator-toggleable strict mode), the cue-ID prefix-stripping convention, and the MSC capability default (recommend: `read + fire`). 4-6 commits estimated.
- `docs/v2/applescript_dictionary.md` (spec §4 #5) — `.sdef`-defined macOS-native automation surface. Addresses the Show Mode interaction (recommend: AS edits stripped in Show Mode same as OSC), element-specifier scope (recommend: numeric index + by-ID for v2.0), synchronous return semantics (recommend: return immediately mirror OSC). 5-7 commits estimated.
- `docs/v2/group_cues.md` (spec §4 #7) — `.startFirst` / `.startAll` / `.startRandom` / `.timeline` group fire modes. Addresses nesting depth (recommend: one level only for v2.0), cue-id namespacing (recommend: flat global per A2), PANIC scope (recommend: blanket safety), `.startAll` pre-wait policy, `.timeline` continuation. Touches cue model + runtime + Show List view + OSC. 6-9 commits estimated; flagged as the highest-risk surface for compositor concurrency interactions with B12.
- `docs/v2/post_show_summary.md` (spec §4 #18) — reducer over the Show Log + Markdown / CSV exporters. Addresses time-window scope (recommend: since-launch default + operator-picked range), cue-runtime measurement (recommend: emit `.cueEnded` events as a delta on E3), latency-distribution shape (recommend: histogram), system-event coverage (recommend: REF flips + audio device flips + lock-file detections), redaction toggle for sharing. 5-7 commits estimated.
- `docs/v2/watched_drop_folder.md` (spec §4 #14) — content-runner workflow built on C8 folder bookmarks + C9 missing-media UX. Addresses drop-folder location (recommend: bundle default + configurable override), watch-trigger granularity (recommend: 2-second stability window), Show Mode interaction (recommend: watch continues, Accept disabled), auto-transcode policy, reject behaviour. 5-7 commits estimated.

`docs/v2/README.md` updated:
- Index entries for the 6 new candidates.
- Cross-candidate dependency map extended to cover all 13 candidates (with explicit "what runs first" orderings).
- Highest-leverage ranking expanded to call out Output Profile / Looks + the MSC / AppleScript "integrator surface v2" cluster.
- "Deliberately not pre-scoped" section enumerated per-item rationale for the remaining ~8 spec §4 items (Confidence/Stage screen role, Tally inbound, Outbound network-cue mirroring, Edge blend, Fill+Key, codec-specific work, Hardware control surface mapper, Browser remote monitor, Multiviewer SDI, External watchdog, Art-Net/sACN, GPI/GPO bridge).

### Why this batch isn't part of Phase F proper

Same reasoning as session 27: Phase F was scoped per `docs/runbook.md` §4 as the v1 cleanup pass; v2-roadmap planning is separate. The autonomous loop's option menu lists "Option F — pre-scope an additional v2 candidate not in the current menu" as the next-after-Phase-F follow-up move; the user noted at session-28 kickoff that prior sessions clear at ~15 % context used and asked for longer / wider runs when the work fits. The 13 v2 candidates now pre-scoped cover essentially every spec §4 item that's both autonomous-friendly to plan and plausible-near-term; the remaining 8 are deliberate non-pre-scopes per the README rationale.

### Test surface session 28

747 → 749 tests (+2). The two new tests are the dispatcher off-main → main pin tests (success-path and rejection-path callback). All 749 pass.

### Manual verification session 28

The dispatcher fix has no operator-visible behaviour change — same callback semantics, same show-log entries, same OSC reply envelopes. Manual rehearsal step: verify that an OSC GO from a remote Companion controller still produces a Show Log entry with `osc h:p` source attribution (covered by `docs/manual_verification.md` Phase D rehearsal section already; no new step needed).

The v2 doc batch is doc-only; nothing to rehearse.

---

## Session 27 (2026-05-08) — Option C v2 enablement pre-scoping

1 commit, doc-only. 747 tests unchanged (no code changes). Phase F itself was untouched; this session ran the Option C "pre-scope a v2 sub-phase" path from the next-session prompt menu, expanded to cover all the major v2 enablement candidates from `docs/handoff.md`'s catalogue.

### What shipped — `docs/v2/`

Seven planning docs + an index (8 files, ~970 lines total):

- `docs/v2/README.md` — index + cross-candidate dependency map + highest-leverage candidate ranking. The dependency map records that Brightness adapt → Director View → Saved Workspaces is the implicit ordering if all three ship (each builds on the previous's window-management infra), and that the audio sub-phase / NDI Full / PowerPoint import are independent of one another.
- `docs/v2/powerpoint_import.md` — `.pptx` rasterize path mirroring C6 Keynote shape. Covers the bundled-LibreOffice vs detect-installed-Office decision (with operational cost: ~250 MB sub-bundle for LO vs operator-side install friction for Office), the hidden-slide / animation-build / speaker-notes / font-fallback policy questions, and a 5-stage first-slice (PowerPointImporter skeleton → MediaImporter routing → optional LibreOffice fallback → policy commits → C-banner integration). 5-8 commits estimated.
- `docs/v2/ndi_full_sender.md` — `NDITransportSink` plugged into the existing `protocol TransportSink` router. Pre-conditions: SDK distribution decision (bundle the redistributable vs detect installed NDI Tools — recommend bundle), sender-name configurability, sender-group support, audio-embed default. First-slice walks SDK ingestion → bridge skeleton → BGRA→UYVY pixel converter → sink lifecycle → audio embed → inspector UI → PreShowCheck row → phase summary. 7-9 commits estimated.
- `docs/v2/audio_subphase.md` — the largest v2 candidate (C12 engine refactor + C13 cue types + C14 per-cue overrides + C15 SRT/WebVTT subtitles). Records the dependency on the F1 P2 AVTrackLoader async-API migration (per the session-26 decision-log entry, that lock-in's "paired work" is here). Decomposes into four sub-phases (mix-bus parity-mode → per-cue overrides → audio cue types → subtitles) plus an optional fifth (multi-device output + SDI embed). Open product questions cover routing-matrix UX surface (recommend: Simple-by-default + Advanced disclosure), background-bed slot count, sample-rate conversion policy, SDI channel mapping default, subtitle burn-in vs out-of-band. 20-26 commits estimated.
- `docs/v2/director_view.md` — read-only Program + next 3 + notes second-display window. Records the open product questions (information-density baseline, layout, color discipline, hotkey suppression, multi-display fingerprinting, Show Mode interaction). First-slice introduces a reusable `Services/ShowListProjections.swift` pure-logic helper as the leaf-first commit, then SwiftUI scaffold → window scene wiring → hotkey suppression → display-fingerprint persistence → unplug fallback → manual rehearsal section. 5-7 commits estimated.
- `docs/v2/saved_workspaces.md` — Edit / Rehearsal / Show / Single Screen layout presets with hotkey switching. Records the preset-only-vs-user-defined scope question (recommend: presets only for v2, user-defined for v3), the project-bundle hint stamping question (stamp active-workspace name; restore best-effort on the destination machine), the Show Mode interaction (workspace switches are no-ops in Show Mode). 5-7 commits estimated.
- `docs/v2/brightness_adapt.md` — booth dimming overlay separate from system brightness; smallest v2 candidate (3-4 commits). Records the open hotkey-chord question, the four-step-cycle vs continuous slider call, the Preview/Program tile-mask discipline (the Preview/Program tiles stay bright while the rest of the operator window dims, via SwiftUI mask rectangles).
- `docs/v2/bundle_for_travel_cross_host.md` — multi-machine rehearsal protocol + Phase 1 pre-rehearsal infrastructure (4 commits — `lastSavedOnHost` schema field, `CrossHostProbe` pure-logic, import-status banner row, PreShowCheck row), then a Phase 2 rehearsal with 0 commits (operator activity), then Phase 3 targeted fixes contingent on rehearsal findings. 5-8 commits estimated for the autonomous-friendly part; Phase 3 scope depends on what the rehearsal exposes.

### Why this isn't part of Phase F proper

Phase F was scoped per `docs/runbook.md` §4 as the cleanup pass; the v2-roadmap planning is separate. But the autonomous loop's option menu (per `docs/handoff.md`) lists "Option C — Pre-scope a v2 sub-phase" as the next-after-Phase-F move, and the user noted at session-27 kickoff that prior sessions clear and restart at ~15 % context used; pushing for "longer/wider" sessions when the work fits.

The choice to pre-scope **all major candidates in one session** (rather than picking one) is a leverage call. The docs share structure and dependencies; doing them together produces a cohesive v2 menu where the dependency map across candidates can be reasoned about. A separate session per candidate would have duplicated context-reading cost without producing the cross-candidate dependency map.

### What's not in `docs/v2/`

- **C11-4 cue-inspector filmstrip scrub UI** — still an open product blocker in `docs/blockers.md`. It's a v1 punch-list item, not a v2 candidate; pre-scoping it would duplicate the blocker entry. The Option-A static / Option-B drag-scrub / Option-C click-to-set-inPoint analysis already lives there.
- **F1 P2 deferred items** — closed at session 26 (ProjectLockFile lock-in + AVTrackLoader scoping to C12 + CompositorOverlays redundancy re-eval).
- **v2 §4 candidates lower in priority stack** — Output Profile / Looks, tally inbound, MIDI Show Control, AppleScript dictionary, group cues, edge-blend, HAP/HAP-Q, AV1, watched-asset folder, browser remote monitor, multiviewer SDI, external watchdog, post-show summary, HDR, Art-Net/sACN, GPI/GPO. Listed in `docs/v2/README.md` "What's deliberately not pre-scoped here" as candidates to add a doc for when one moves up the priority list.

### Test surface session 27

747 tests, unchanged. Doc-only commit; no code paths touched.

### Manual verification session 27

Doc-only; nothing to rehearse.

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
