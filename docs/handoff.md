# Simple Playback v1 — Handoff

This is the F6 deliverable from the autonomous v1 build. It is the single document a new collaborator should read first; everything else in `docs/` is referenced from here.

**v1 status at handoff (session 26, 2026-05-08)**: code-complete. 747 tests pass. 8 commits + 5 hardening commits in the F1 reviewer sweep. Three deferred F1 P2 items documented for future-session pickup. F2 README, F3 `docs/api.md`, F4 `docs/manual_verification.md`, F5 `docs/test_fixtures.md`, F6 (this file) shipped. **Production promotion still depends on the hardware-bound rehearsal in `docs/manual_verification.md`** — no code path replaces a rehearsal cycle on a real DeckLink card and a reference monitor.

---

## Who reads what

### If you are an integrator

You're wiring Simple Playback into a Companion module, a custom OSC controller, a scheduling system, or a third-party show-control surface. **Read `docs/api.md`.** It is the contract:

- Transports, ports, Bonjour service names
- Auth + capability semantics (`read` / `fire` / `edit`, Show-Mode capability stripping)
- Every OSC, HTTP, WebSocket, and OSCQuery address with sample reply envelopes
- Timecode source-spec strings and chase engagement rules
- Idempotency keying (50 ms retrigger lockout)
- Source-attribution mapping (how OSC / HTTP / TC / local sources show up in the show log)
- Worked `curl` / `websocat` / `oscsend` examples
- "Not yet wired (v1 ack-only)" appendix calling out scrub / opacity / audio-level / goto / look-recall / output-freeze / workspace-save until host interceptors land

The Companion module is a sibling-repo deliverable. The JavaScript module's design doc lives in `docs/phase_d/companion_module_design.md` — it specifies the actions, feedbacks, and variables Companion needs to expose; the OSC/HTTP surface in `api.md` is what it talks to.

### If you are an operator

You're running a show. **Read `docs/manual_verification.md`.** It is the consolidated rehearsal checklist: every "needs hardware" verification step from phases A–E in one place, sectioned by phase, marked `[no-hw]` / `[hw]` / `[hw + REF gen]` / `[hw + receiver]` so you can run the no-hardware items on a stock laptop and stage the hardware items for a real rehearsal cycle.

The README at the repo root has the v1 feature surface walkthrough and an OSC quick-reference table. If you've never seen the app, start there, then go to `docs/manual_verification.md` for the rehearsal protocol.

Operator-visible behaviour you should know about before the first show:

- **Show Mode** (⌘⇧L) — gates editing, strips `edit` capability from remote tokens, and freezes drag-reorder. Toggle into Show Mode before doors-open.
- **PreShow check panel** — toolbar button before doors. Each row that fails has either an inline Fix button (relink folder, open Sound preferences, reveal bundle in Finder, open Blackmagic Desktop Video Setup) or is project-edit territory (the cue inspector takes you there).
- **Crash recovery** — if the app crashes mid-show, relaunching shows a banner with **Restore** / **Discard**. Restore loads the newest autosave that's strictly newer than the on-disk `Show.json`; Discard drops the autosaves and continues from disk.
- **Project lock file** — a foreign live lock (another machine has the same `.spb` open) shows a banner with **Open Anyway** / **Dismiss**. Dismiss is the safe default; Open Anyway is for the case where you knowingly want a second-operator confidence-monitor view of the same bundle.
- **Show log** — every GO / PREV / PANIC / CLEAR / dropped-frame burst / late-take event lands in `<bundle>/Logs/<yyyy-MM-dd>.log` (CSV, RFC 4180). The viewer's filter UI (source / action / since) is for post-show triage. If the writer fails (read-only volume, NAS timeout), an orange "Disk log paused" banner surfaces; the rest of the app keeps running.

### If you are a future autonomy session

You're picking up the autonomous build for v2 or follow-on hardening. **Read in this order:**

1. `docs/runbook.md` — the operating contract. §2 still applies. Commit per sub-task to `development`, never push, never `--no-verify`, never `git add -A`. Blocker policy and hard-stop conditions are unchanged.
2. `docs/progress.md` — living checklist. Phase A/D done; Phase B at v1 close (B1–B5, B12, B14, B16); Phase C closed session 19 with C8/C11 punch-list; Phase E mostly done; Phase F has F1/F2/F3/F4/F5/F6 done as of session 26.
3. `docs/blockers.md` — at handoff, **C11-4 cue-inspector filmstrip scrub UI** is the open product blocker. Read the three options before resuming C11.
4. The phase summaries — `docs/phase_a_summary.md`, `docs/phase_b_summary.md`, `docs/phase_c_summary.md`, `docs/phase_d/`, `docs/phase_e_summary.md`, `docs/phase_f_summary.md` — for what shipped and what was deferred per phase.
5. `docs/spec/feature_spec.md` — the v1 spec. §3.10, §3.16, §3.17, §6 are the most-referenced sections for the deferred items.
6. `docs/decision_log.md` — append-only. The session-25 entry catalogues the F1 P2 deferred items with rationale.
7. `docs/test_fixtures.md` — the synthesis-only fixture policy. New tests synthesize their inputs; `Scripts/regenerate-fixtures.sh` defends the policy.

The `git log --oneline development` is authoritative for what landed when. Per-session commit groupings cluster cleanly (sessions 11–25 ran 4–11 commits each); the next-session prompt at `~/Desktop/Simple Playback — Next Session Prompt.md` is refreshed at the end of every session and points you at where to pick up.

---

## What's deferred from v1

Three categories: open product blockers (need operator UX input), hardware-bound items (need a real card + rehearsal), and F1 P2 reviewer-sweep items (small, future-session pickup).

### Open product blocker

- **C11-4 — cue-inspector filmstrip scrub UI**. Generator + coordinator + import-time enqueue + cache directory all shipped. Filed in `docs/blockers.md` with three options (static strip vs drag-scrub vs click-to-set-inPoint), placement question, and a missing-cache regenerate affordance question. Waiting on operator UX choice.

### Hardware-bound (need a real DeckLink + rehearsal)

These are not bugs — they are integrations that no unit test can exercise without real silicon and real signal. Each is documented in the relevant phase summary and rolled up in `docs/manual_verification.md`.

- **B6 REF format-mismatch warning** — needs an SDK API that v15.3.1 `IDeckLinkOutput` doesn't expose; small SDK spike before scoping.
- **B7 DeckLink format negotiation** — explicit at start, mid-show change requires re-arm.
- **B8 10-bit YUV 4:2:2** — recommendation logic ships; applying it as the actual default at DeckLink-binding-creation needs UI surface + hardware verification.
- **B9 "Output in use" detection + recovery path**.
- **B10 SDI audio embed with channel-pair routing**.
- **B11 NDI Full sender as a TransportSink** — schema exists; needs the NDI Advanced SDK (license + binary distribution decision).
- **B13 Color pipeline — NCLC/ICC respect with overrides + gamma-aware crossfade**.
- **B15 Hot-unplug handling** (UltraStudio Thunderbolt).
- **C8 cross-host folder-bookmark rehearsal** — sandbox-vs-NAS folder bookmarks, security-scoped folder access on a moved bundle.
- **D12–D14 LTC / MTC chase + internal generator** — code paths in place; hardware verification needs a real LTC generator + real Core MIDI source.
- **E1+ macOS-condition adapters** (Spotlight / DND / Time Machine / screensaver) — each is fragile or privacy-blocked on modern macOS; pre-show check stays on the cards already shipped (audio, disk, REF, energy, render-path).

### F1 P2 deferred items (future-session pickup)

Small, well-scoped, no UX questions:

- **Project-lock-file hostname canonicalization** (`Services/ProjectLockFile.swift:198`). Today uses `gethostname(2)`. Cross-host rehearsal needed before committing to either `gethostname` or `Host.current().localizedName`. Whichever wins, document the choice in `decision_log.md` and add a manual rehearsal step.
- **`AVTrackLoader.loadFirstVideoTrackInspection` async API migration** (`Services/AVTrackLoader.swift:42-62`). Today blocks the calling thread on a semaphore. A true `async` entry point is cleaner; needs simultaneous migration of MediaImporter / MediaFlagsInspector / AudioPump.
- **`CompositorOverlays.didSet` ordering pin**. Two rapid overlay edits during a take publish the preview images via `DispatchQueue.main.async` — FIFO from main is order-preserving, but a small ordering test would lock the contract before Phase F adds programmatic overlay automation.

### Audio sub-phase (out of scope for v1)

- **C12 audio engine refactor** — 48 kHz / 32-bit float, 8 internal channels, routing matrix.
- **C13 audio cue types**.
- **C14 per-cue audio**.
- **C15 SRT/WebVTT subtitle sidecar render**.

The runbook scoped these out at kickoff; the v1 audio path is the existing AudioPump + CoreAudio sink. v2 enablement candidates below.

---

## v2 enablement candidates

Spec §4 lists the v2 items; each deserves its own planning round. The ones with the most user pull at handoff:

- **PowerPoint import** — explicitly out of scope for v1 per the runbook kickoff. v2 is likely AppleScript-driven `.pptx` → PDF → bitmaps mirroring the Keynote import path; the harder problem is non-Mac authoring tools and the variety of export quirks.
- **Audio sub-phase (C12–C15)** — the v1 audio path works for the corporate-AV target; v2 expands to a routing matrix + per-cue audio + sidecar render.
- **NDI Full sender (B11)** — schema in place, blocked on an SDK distribution decision (license + binary).
- **Director View (E9)** — read-only Program + next 3 + notes, multi-display tear-off. UX-design heavy; product blocker on layout.
- **Saved Workspaces (E10)** — UX-design heavy; product blocker.
- **Brightness adapt key (E11)** — booth dimming separate from system brightness. Default chord + scope (operator window vs program output) are open UX questions.
- **Bundle for Travel cross-host rehearsal** — the foundation shipped session 17; multi-host rehearsal closes the loop.

---

## Repository pointers

The README at the repo root is the entry point for someone who's never seen the app. From there:

- **`Simple Playback/`** — the app source. Organized by area: `Playback/`, `Output/`, `Compositor/`, `ShowControl/`, `Services/`, `Views/`, `Support/`.
- **`Simple PlaybackTests/`** — the test target. 747 tests across the suite. No committed binary fixtures (see `docs/test_fixtures.md`).
- **`Scripts/`** — release tooling (DMG, notarization, Sparkle appcast) plus `regenerate-fixtures.sh`. Distribution scripts are out-of-scope for autonomous changes per the runbook.
- **`docs/`** — everything in this handoff.
- **`Distribution/`, `build/distribution/`** — release artifacts. Treat as read-only from autonomous sessions.
- **`Blackmagic DeckLink SDK 16.0/`** — vendored SDK. Treat as read-only.
- **`project.yml`** — XcodeGen source of truth. Run `xcodegen generate` after adding new Swift files.

Build / test commands:

```bash
xcodebuild -project "Simple Playback.xcodeproj" -scheme "Simple Playback" -destination 'platform=macOS' build
xcodebuild -project "Simple Playback.xcodeproj" -scheme "Simple Playback" -destination 'platform=macOS' test
```

Both must be green at every commit (runbook §2.3).

---

## Closing note

The v1 build was driven by 26 autonomous sessions over a single calendar day (2026-05-08), with a stable iteration shape — read runbook + progress, pick a sub-task, commit per sub-task, surface decisions in `decision_log.md`, file a blocker if the next move needs operator input. The shape is preserved in `docs/runbook.md` for the next session.

What this build delivers: code-complete, internally consistent, deeply unit-tested implementation of the v1 feature surface defined in `docs/spec/feature_spec.md`. What it does not deliver: any signal that has not been pulled across real silicon. The handoff treats those as separable problems; **`docs/manual_verification.md` is the bridge.**
