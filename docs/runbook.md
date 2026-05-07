# Autonomous Runbook — Simple Playback v1

This is the operating contract for the long-running autonomous build of the v1 feature set defined in `docs/spec/feature_spec.md`. It captures the decisions made before kickoff and the rules I follow during the run.

If you're reading this mid-run to course-correct: edit this file directly. I re-read it at the top of every iteration.

---

## 1. Decisions made before kickoff

| Decision | Choice |
|---|---|
| Phase scope per autonomous run | All of A → F, with mandatory checkpoints between phases |
| Commit policy | Commit per sub-task to `development` locally; never push |
| Branch strategy | Single branch `development`; no sub-feature branches |
| Swift Package dependencies | Allowed where mature libraries exist (OSC, OSCQuery, LTC decoder, NDI SDK, etc.) |
| macOS minimum target | Match project default (currently macOS 26.0) |
| `.splayback` migration | Read flat format, write bundle on next save |
| Single-screen default | Single-output; Preview/Program is opt-in once a DeckLink is configured |
| Codec policy | Accept-and-warn for everything AVFoundation can decode; surface non-blocking warnings on long-GOP, VFR, untagged color |
| PowerPoint import | **Out of scope for v1.** Moved to v2 roadmap. |
| Keynote import | In scope for v1 — AppleScript-driven Keynote → PDF → bitmaps |
| PDF import | In scope for v1 — PDFKit rasterize-on-import |
| Cue ID syntax | Any non-empty string; OSC paths URL-encode as needed; case-insensitive uniqueness |
| Blocker resolution | Spawn a `code-reviewer` or research subagent to break technical ties; on product-decision blockers, stop and write to `docs/blockers.md` |
| Test media fixtures | Committed to repo (~20–50 MB target). Stored under `Simple PlaybackTests/Fixtures/`. |

---

## 2. Operating contract

### 2.1 Iteration loop
Each iteration follows this shape:

1. Read `docs/runbook.md`, `docs/progress.md`, `docs/blockers.md`.
2. If `docs/blockers.md` has any unresolved entries → stop and surface them.
3. Pick the next sub-task from `docs/progress.md`.
4. Implement: code + tests in the same iteration.
5. Run `xcodebuild build` and `xcodebuild test`. Both must pass.
6. On green: commit with a message that names the sub-task.
7. Update `docs/progress.md` (mark sub-task done, log timestamp).
8. Update `docs/decision_log.md` if the iteration involved a non-obvious choice.
9. If at a phase boundary → run §2.5 phase-end checklist.

### 2.2 Commit conventions
- One sub-task per commit. Imperative mood, concise.
- Format: `<area>: <change>` — e.g. `runtime: add Cue.continuationMode and pre/post-wait fields`.
- Commit only files I intended to change. Never `git add -A`.
- Never push. Never force-push. Never amend a published commit.

### 2.3 Build/test discipline
- The build must be green at the end of every iteration. If a sub-task lands in a half-broken state, the iteration is not complete.
- Tests written in the same iteration as the code they cover.
- Coverage target: every public API on a new or modified type has at least one unit test.
- Integration tests (OSC server round-trip, project file round-trip, cue runtime) live under `Simple PlaybackTests/Integration/`.
- If `xcodebuild test` would take longer than 5 minutes, run `build` continuously and `test` at sub-task boundaries.

### 2.4 Blocker policy
**Technical blocker** — uncertainty about a Swift API, library choice, design tradeoff with no clear product impact:
1. Spawn a `code-reviewer` or `general-purpose` subagent with the specific question.
2. Take the answer, log the decision in `docs/decision_log.md`, proceed.
3. If the subagent's answer is itself ambiguous → escalate to product blocker (below).

**Product blocker** — anything user-visible (UI text, hotkey defaults, file format, behavior the user would want to weigh in on) where I'd normally ask:
1. Stop the loop.
2. Write entry to `docs/blockers.md` with: what's blocked, options I considered, my best-guess recommendation, what I need from the user.
3. Commit progress so far. Wait for next session.

**Compile/test failure** — if I can't resolve in 3 attempts:
1. Spawn a `code-reviewer` subagent to read the diff and the failure.
2. If still stuck after the reviewer's input → product blocker.
3. Never bypass tests with `--no-test`, `if false`, or commenting them out. Never use `--no-verify`.

### 2.5 Phase-end checklist
Before declaring a phase complete:
1. Run full `xcodebuild test` — all tests pass.
2. Run a `code-reviewer` subagent against `git diff <phase-start>..HEAD`. Act on any P0/P1 findings before marking the phase done.
3. Manually run the app once via `xcodebuild build` + `open` and click through the new feature surfaces. (I can't *test* UX, but I can verify the app launches and the new surfaces are reachable.)
4. Write `docs/phase_<X>_summary.md`: what shipped, what tests cover it, what manual rehearsal steps you need to run, known gaps.
5. Update `docs/progress.md` checkpoint.
6. Commit the phase summary as the final commit of the phase.

### 2.6 Hard stop conditions
I stop the loop and write to `docs/blockers.md` if any of:
- Build fails 3 attempts in a row on a single sub-task.
- A test that was passing yesterday is now failing because of my changes (regression — never commit through one).
- I would need to disable, skip, or remove an existing test to proceed.
- I would need to modify CI, signing, notarization, or Sparkle update infrastructure.
- I would need to push to a remote, modify git history, or run a destructive git command.
- A sub-agent surfaces a "this is wrong" verdict on architecture I've already shipped.
- I would need to add a dependency that's larger than 100 MB or has license incompatible with the project.
- The autonomous run has been going for >24 hours of wall-clock time without a phase boundary.

### 2.7 Resumability
The state for resuming the loop lives entirely in:
- `docs/runbook.md` (this file — operating contract)
- `docs/progress.md` (what's done, what's next)
- `docs/decision_log.md` (every non-obvious choice)
- `docs/blockers.md` (what's stopping me)
- The git log on `development`

Anyone (or any future iteration) reading those four files plus the spec can pick up the loop without prior context.

---

## 3. Files I maintain throughout the run

### 3.1 `docs/progress.md`
Living checklist organized by phase. Each sub-task has a status (`pending` / `in_progress` / `done` / `blocked`) and a one-line note when transitioning. Updated every iteration.

### 3.2 `docs/decision_log.md`
Append-only. One entry per non-obvious choice, with: timestamp, what was decided, why, alternatives considered, what I'd do differently if I learned otherwise. The kind of decisions that go here:
- "Chose OSCKit over hand-rolled OSC because…"
- "Wired the cue-runtime state machine on Combine rather than raw async sequences because…"
- "Embedded thumbnails as base64 inline rather than sidecar cache because…"

### 3.3 `docs/blockers.md`
Stops the loop until you respond. Format per blocker:

```
## <blocker title>
- **Filed**: <timestamp>
- **What's blocked**: <task>
- **Options**:
  - A: <option> — pros, cons
  - B: <option> — pros, cons
- **My recommendation**: <which and why>
- **Need from you**: <one sentence>
```

### 3.4 `docs/phase_<X>_summary.md`
Written at every phase boundary. What shipped, what tests cover it, what manual steps you need to run on real hardware, known gaps.

---

## 4. Phase order (from spec §7)

I'll work through these in order. Each is independently shippable.

- **Phase A** — Show runtime + UX scaffolding (cue model, GO semantics, Show List, Show Mode, hotkeys, Preview/Program color discipline, status bar)
- **Phase B** — Output pipeline rework (typed Screens, Stage abstraction, DeckLink REF/format/output-in-use, NDI Full output, color pipeline, overlay layers)
- **Phase C** — Media pipeline (PDF/Keynote import, codec inspector flags, transcode action, asset relink, animated GIF / image-sequence conversion)
- **Phase D** — Show control (OSC + HTTP + WebSocket + OSCQuery, Bonjour, auth, Companion module, LTC chase)
- **Phase E** — Reliability (pre-show check, show log, autosave, crash recovery, Director View, project lock file)
- **Phase F** — v2 enablement on top of v1 (open question — likely stops here for review)

Each phase has its own decomposition in `docs/progress.md`.

---

## 5. What I will *not* do autonomously

These require explicit user confirmation even if everything else is green:

- Push to a git remote.
- Force-push, rebase published commits, or rewrite history.
- Modify or remove existing tests.
- Change CI, signing, notarization, or Sparkle update configuration.
- Add a dependency >100 MB or non-OSS-friendly license.
- Modify `Distribution/`, the appcast, or anything user-visible related to releases.
- Run `git clean`, `git reset --hard` past my own work, or any destructive git op.
- Delete files I didn't create unless removing a corresponding addition.
- Modify the Blackmagic SDK directory.
- Change the bundle identifier, app name, or icon.

If a sub-task seems to require any of these → product blocker.

---

## 6. Verification realism

The spec is for a live-show playout app. "95 % confident high reliability" is a real ambition; here is what that confidence means at the end of an autonomous run:

**What I can deliver autonomously:**
- All v1 features per spec implemented and unit-tested.
- Integration tests covering cue runtime, OSC API round-trips, project file round-trips, color pipeline math, frame-rate conformance, asset relink, codec inspector flags.
- Pixel-diff tests for PDF/Keynote import.
- Headless OSC client tests covering the full action surface.
- A simulated DeckLink mock so cue-output paths get exercised in tests.
- Code-reviewer-clean diffs at every phase boundary.

**What still requires you / hardware:**
- Verifying SDI output looks right on a real DeckLink card.
- Verifying genlock, fill+key, format negotiation on real hardware.
- LTC chase against a real generator.
- Real Companion + Stream Deck integration test.
- UI feel and hotkey ergonomics in a dim booth.
- Color accuracy on an SDI reference monitor.
- A real rehearsal cycle.

The phase summaries call out exactly which tests cover what and which manual rehearsal steps remain. "Ready for your rehearsal" is the deliverable.

---

## 7. Kickoff signal

When you're ready, the start command is:

```
/loop
```

with no interval — that puts me in self-paced dynamic mode. I'll iterate, commit, and update the log files until I hit a phase boundary or a blocker. The `/loop` will resume automatically across sessions; you stop it with Ctrl-C or by editing `docs/blockers.md` to halt.
