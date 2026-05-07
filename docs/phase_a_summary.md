# Phase A — Show runtime + UX scaffolding — Summary

**Status**: Substantively complete. Runnable app with cue list runtime wired into UI. 68 tests, all green. 9 commits on `development` between `4e9859e` (planning artifacts) and `59deead` (end-to-end integration tests).

## What shipped

### Project file format
- `.spb` is now a macOS package bundle. `Show.json` lives at the bundle root; subsequent phases drop sibling folders (`Logs/`, `Cache/`, `Transcoded/`, `Autosave/`) without changing the schema.
- `PlayoutProject.formatVersion` (`= 2` for fresh projects); legacy v1 flat-JSON files decode with `formatVersion = 1` and upgrade to v2 the next time the user saves.
- `markCurrentFormatVersion()` ensures every saved project has at least one show list and a valid `activeShowListID`.
- Reader accepts both v2 directory bundles and legacy regular-file `.spb` JSON via `SimplePlaybackProjectDocument.projectData(from:)`.

### Cue / Show / Runtime model
- **`Cue`** — UUID id, free-form non-empty number (`"INTRO"`, `"Q12"`, `"Steve"` — case-insensitive uniqueness), title, asset reference, continuation flag, pre/post-wait, notes, overrides.
- **`CueContinuation`** — `hold` / `autoContinue` / `autoFollow`.
- **`CueOverrides`** — optional fade in/out, crossfade, hold-last-frame, loop, in/out points. nil → inherit from project defaults.
- **`ShowList`** — ordered `[Cue]` with playhead, validated (case-insensitive uniqueness, no empty numbers), with insert/append/remove/move-playhead helpers.
- **`PlayoutProject.showLists`** + `activeShowListID` — multiple coexisting lists; `generateDefaultShowList()` builds one cue per slide for v1 → v2 migration.

### Cue runtime state machine (`Simple Playback/Playback/CueRuntime.swift`)
- Pure state machine — no rendering, no AVFoundation. Drives the show via callbacks.
- Verbs: `go()`, `go(targetNumber:)`, `previous()`, `panic(fade:)`, `panicCompleted()`, `clear()`, `toggleBlackout()`, `setBlackout(_:)`, `cueDidEnd(cueID:)`, `markLoaded`, `unloadCue`, `replaceShowList`, `mutateShowList`.
- Per-cue states: `idle` / `loaded` / `running` / `tail`.
- GO debounce (default 250 ms), panic-in-progress lockout, idempotent retrigger.
- **Continuation timing**: `auto-continue` chains immediately to the next cue (recursively); `auto-follow` schedules the next cue after `cue.postWait` via the injected `CueScheduler`. Panic / clear / list-mutation cancel pending follow-ups.
- Time injection (`clock` closure) and scheduler injection (`CueScheduler` protocol) make every timing-sensitive behavior deterministic in tests.

### App integration
- **`ShowController`** (`Playback/ShowController.swift`) — owns the `CueRuntime`, observes its callbacks, translates `cueFired` into `playback.take(slide:)` against the asset library. Holds the operator-only `showMode` flag. Per-cue crossfade override resolves through the project default. Soft panic auto-resolves after the configured fade so GO unlocks.
- **`ShowListView`** (`Views/ShowListView.swift`) — a SwiftUI view of the active list with playhead/live/standby badges, drop target for asset UUIDs dragged from the palette, transport bar (Previous, GO, Panic). Empty-state offers "Generate from Library" when slides exist.
- **`SlideGridView`** — tiles are now `.draggable(slide.id.uuidString)`.
- **`RootView`** — three-column `HSplitView` (Asset Palette | Show List | Inspector). Inspector switches between `CueInspectorView` (number, title, continuation segmented picker, pre/post-wait, notes editor) and the existing slide `InspectorView`.
- **Hotkeys**: Space → GO, Esc → Panic, ← → Previous, Cmd-. → Clear, Cmd-Shift-L → Toggle Show Mode. Wired via SwiftUI `.keyboardShortcut`. User-rebindable scheme deferred to A7b.
- **Show Mode** (toolbar toggle): disables Add Media, Delete Slide, drag-reorder, list deletion. Confirm-on-quit-while-live and modal-forbidden invariant deferred to A6b after Phase B's live-state hookup.

## Tests (68 total)

| Area | Coverage |
|---|---|
| File format | format-version migration, bundle round-trip, legacy flat read, missing-file rejection, file-extension and document-type Info.plist registration |
| Cue model | defaults, override emptiness detection, JSON round-trip with all fields, missing-field decoding |
| ShowList | empty list, init seeds playhead, case-insensitive lookup, duplicate rejection, empty-number rejection, validate-all-duplicates, advance/retreat through end-of-list, remove-at-playhead behavior, move-playhead unknown-id no-op, JSON round-trip |
| CueRuntime | idle init, GO fires + advances, debounce within and past window, GO(targetNumber) jump+fire, unknown-number rejection, panic-in-progress and empty-list rejections, PREV without fire, panic→tail+GO-lock, panicCompleted drain+unlock, CLEAR force-idle, blackout toggle/idempotent, cueDidEnd transition, markLoaded/unloadCue round-trip, mutateShowList drops removed-cue state, replaceShowList preserves overlapping IDs |
| Continuation timing | auto-continue chains immediately, stops at hold and end-of-list, auto-follow schedules with postWait, zero postWait fires on next tick, panic / clear / cue-removal cancel pending follows, multi-cue auto-follow chain resolves, scheduler cancellation idempotency |
| End-to-end | bundle round-trips populated show list, generate-default-list + repeated GO walks playhead off the end |
| Pre-existing | image scaling, frame blending, frame renderer fast path, media-kind classification, preview driver smoke, DeckLink bridge runtime query |

## Manual verification needed (not autonomous-testable)

The runtime is verified end-to-end at the model level. The UI integration needs human eyeballs:

1. Launch `Simple Playback`, open a fresh project, drop a few clips into the palette.
2. Click **Generate from Library** in the empty Show List → cues `1`, `2`, `3` appear with correct titles.
3. Press **Space** → first cue fires, playhead moves to second, blue highlight on next cue.
4. Press **Space** again → second cue takes over.
5. Press **Esc** → panic fades; brief GO lockout, then auto-resumes.
6. Toggle **Show Mode** (Cmd-Shift-L) → the toolbar add/delete buttons grey out; drag-reorder is disabled.
7. Select a cue → the inspector shows number, title, continuation picker, pre/post-wait, notes editor.
8. Edit a cue's continuation to **Auto-follow** with `postWait = 0.5` → after the cue ends, the next cue auto-fires after the half-second wait.
9. Drag a slide from the palette into the Show List → a new cue appears at the bottom with the next available number.

## Known gaps / deferred work

- **A6b** — modal-forbidden invariant (no system modals while a cue is on Program), confirm-on-quit-while-live. Needs Phase B's "live state on Program" signal.
- **A7b** — user-rebindable hotkey scheme + printable export. Current scheme is hard-coded SwiftUI `.keyboardShortcut`. Move to a settings table backed by NSEvent monitoring.
- **A8** — Preview/Program color discipline. The current `OutputPreviewView` is a single-screen preview. Splitting into Preview/Program with red/blue chrome is a Phase B deliverable since it needs the new compositor topology.
- **A9** — Status bar enhancements (dropped-frame counter, TC indicator, log shortcut, heartbeat dot). Reasonably moved to Phase E (reliability).
- **Media missing on cue fire** — currently the runtime calls `cueDidEnd` immediately so chains advance. Phase C's media-relink UX will surface this as a non-blocking warning per cue.
- **Crossfade duration override per cue** — wired through `effectiveTransitionSettings(for:)` but the inspector doesn't expose the override field yet (Phase C work).

## Merge concerns from the parallel Phase D agent

The `isolation: "worktree"` parameter on the spawned agent did **not** create a real isolated working directory — the Phase D agent has been writing into the main `Simple Playback/ShowControl/` directory and `Simple PlaybackTests/ShowControlTests.swift` directly. As of this summary, `git status` shows the agent has untracked or unstaged work in:

- `Simple Playback/ShowControl/OSCServer.swift`
- `Simple Playback/ShowControl/SubscriptionRegistry.swift`
- `Simple PlaybackTests/ShowControlTests.swift`

The earlier files (`OSCMessage`, `OSCAddressMap`, `ShowControlActions`, `ShowControlDispatcher`, `ShowControlState`) and `docs/phase_d/decision_log.md` were swept into commit `eb96f93` by `git add -A`. They build and don't break tests, but they're not "merged" in the usual sense — they're just orphaned across the boundary. When the Phase D agent finishes, it'll either commit to its worktree branch (which now points at a state without those files) or leave more untracked deltas in the main tree.

**Action for the next session**: review the agent's full output in `docs/phase_d/`, decide whether to keep its work, and either complete-and-commit the trailing files or revert to a clean state.

## Recommended next phase

Phase B (output pipeline rework) is the next foundational step. It refactors `VideoOutput.swift` and `DeckLinkBridge.mm` against the spec's typed Stage/Screen/Transport abstraction, surfaces REF lock state, makes 10-bit YUV the default for >8-bit clips, handles "output in use" recovery, and adds the persistent bug + message overlay layers in the compositor. Phase B is sequential — it cannot run in parallel with anything else because it touches the rendering hot path.

After Phase B, Phase C (media pipeline) and the remainder of Phase D (whatever the parallel agent left undone) can run in parallel safely.
