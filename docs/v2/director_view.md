# v2 Pre-Scope — Director View (E9)

**Status**: pre-scope (planning only — no code).
**Filed**: 2026-05-08, session 27.
**Spec source**: `docs/spec/feature_spec.md` §3.15 ("Director View for a second display: read-only, Program + next 3 cues + per-cue notes. No controls. Multi-operator workflow") and §3.15 layout block ("Tear-off windows: Preview, Program, Show List, Status, Director View").
**Progress source**: `docs/progress.md` E9 ("Director View tear-off window (read-only, Program + next 3 + notes)") — pending; deferred per `docs/handoff.md` "v2 enablement candidates" as UX-design heavy.

---

## Why v2, not v1

The v1 product is operator-on-the-show-machine. Director View is fundamentally a **second-operator** workflow — a director or technical director on a second display sees what the show operator is firing. The v1 target use case (single-operator corporate AV / event playout) doesn't generate enough demand for the multi-operator surface; deferred until the "we have a director and an operator" use case is validated against real shows.

Two reasons it's UX-design heavy rather than implementation-heavy:

1. **The information density question is open.** Spec §3.15 says "Program + next 3 cues + per-cue notes" — but on a 27" director display that's a lot of empty space. Operators may want elapsed/remaining counters, take history, dropped-frame indicator, TC chase state, operator's GO log. Each addition risks crowding the "no controls" discipline; each subtraction risks the director feeling under-informed.
2. **The window-management story is open.** macOS multi-display has rough edges: `NSWindow.collectionBehavior`, full-screen on a second display, what happens when the second display is unplugged mid-show, how the window survives a rejoin. None of these have a single "right" answer.

## What "Director View" means in v1+ terms

A separate top-level `NSWindow` driven by SwiftUI scene that:

- Mirrors `PlaybackController`'s published state (program cue, next 3 cues, current notes, current playhead).
- Renders **read-only**: no buttons, no inputs, no shortcuts that fire cues. Even hovering or right-clicking shouldn't surface mutation surface.
- Sized for a 1920×1080 or 2560×1440 secondary display by default.
- Persists location across launches (per-display fingerprint, like Xcode does for its window restore).
- Survives the second display being unplugged and rejoined; on unplug, snaps back to the primary display with a "Director View on `<display name>` is now on `<primary>`" toast.
- Hidden by default; toggled via View → Director View menu and a dedicated `Cmd-Shift-D` hotkey.

## Open product questions

These need an operator-side answer before any code lands:

1. **Information density — what fields?**
   The spec says Program + next 3 + notes. Candidates beyond that, ordered by likelihood of being wanted:
   - **A — Add elapsed/remaining counters** (large digits, secondary to cue title). Likely yes.
   - **B — Add dropped-frame chip** (orange when active). Quiet when healthy.
   - **C — Add TC chase state + delta**. Useful when the show is TC-driven; clutter otherwise.
   - **D — Add take history sidebar** (last 5 fires). Nice for "what just happened."
   - **E — Add Show List fragment** (current section + headers). Helps the director know how far in we are.
   - **F — Add operator-input field** (director types a note that flashes on the operator's main view). This crosses into mutation surface; out of scope for read-only.
   - **My recommendation**: A + B as default; C + D + E behind a "Show advanced fields" project setting. F is v3.

2. **Layout — single-pane vs split?**
   - **A — Single full-window column** (Program top half, next 3 + notes bottom half). Maximum legibility from across the booth.
   - **B — Two-column** (Program left, next 3 right; notes anchored bottom). Better information density.
   - **C — Three-row** (Program top, next 3 middle, notes + advanced bottom). Most flexible, most fragile to small windows.
   - **My recommendation**: A. The director display is read at a glance; legibility wins over information density.

3. **Color discipline.**
   The Program tile in the operator window is red-bordered (per spec §3.3 Preview/Program model). The director's Program tile should match — same red border, same "PROGRAM" overlay. Confirm the operator visual is replicated exactly (vs. simplified for the director's distance).

4. **Hotkey behaviour.**
   Director View shouldn't accept any cue-fire hotkeys (no Space / Esc / B / etc.) when focused. Current hotkey wiring in `Views/RootView.swift` uses `.keyboardShortcut(_:modifiers:)` on root-level views; need to verify that focus-following-keyboard-shortcuts won't accidentally let Space-on-DirectorView fire a cue. Probably needs a window-level `NSEvent` interceptor that suppresses cue-fire keys.

5. **Multi-display fingerprinting.**
   When the operator has 3+ displays (built-in + secondary monitor + DeckLink fed projector), Director View should remember which display it lived on last session. macOS `NSScreen.deviceDescription[.NSScreenNumber]` is unstable across reboots; need a stable display ID via `CGDisplayCreateUUIDFromDisplayID` + persisted in user defaults.

6. **What happens when the operator opens DJ View while Show Mode is on?**
   - **A — Same behaviour** (Director View can be opened/closed mid-show; doesn't affect Show Mode lockout).
   - **B — Lock out toggle in Show Mode** (window state freezes at Show Mode entry).
   - **My recommendation**: A. Director View is read-only; opening/closing it is not a destructive action.

## Dependency map

- **`Views/RootView.swift`** — current root view owns the operator's main UI; Director View is a parallel scene driven by the same `ShowController` / `PlaybackController` published state.
- **`SimplePlaybackApp.swift`** — adds a `WindowGroup(id: "DirectorView")` next to the existing main window scene.
- **`PlaybackController` published state** — `liveSlideID`, `videoDuration`, `videoElapsed`, `transitionPreviewImage` are all already published. Director View subscribes via `@ObservedObject`. No new state needed for the basic view.
- **`ShowController.showList` + `playheadCueID`** — drives the "next 3 cues" computation; pure-logic helper `nextCues(from:limit:)` lives where? Recommend a new pure-logic file `Services/ShowListProjections.swift` so the helper can be tested in isolation and reused by Director View / OSC `/sp/state/playhead` push subscriptions.
- **Display-management helpers** — new `Services/DirectorViewWindowManager.swift` owning the persisted display ID, the unplug-fallback snap-back, the "show on display N" target.
- **Hotkey suppression** — new `NSEvent` local monitor scoped to the Director View window NSWindow, intercepting Space / Esc / B / Cmd-Shift-L / Cmd-1..9 / numpad 0-9 / J / K / L / Enter / Cmd-Enter / numpad and forwarding to nowhere.
- **Manual verification** — new section in `docs/manual_verification.md` for Director View on a second display: verify content updates live, verify unplug fallback, verify hotkey lockout, verify display-fingerprint restoration after restart.

## Suggested first-slice (5-7 commits)

1. **`ShowListProjections.swift`** (1 commit, ~80 LOC + ~120 LOC tests).
   - Pure-logic `nextCues(showList:from:limit:)`. Tests cover edge cases: playhead at end, playhead at empty list, `limit > remaining`.
   - Unblocks both Director View and a future improvement to OSC `/sp/state/playhead` subscription payloads.

2. **DirectorView SwiftUI scaffold** (1 commit, ~250 LOC).
   - Top-level `View` consuming `ShowController` + `PlaybackController` ObservedObject.
   - Layout per Option A (single-column Program + next 3 + notes).
   - Color discipline matches operator's Program tile (red border).
   - No interaction handlers.

3. **Window scene wiring** (1 commit, ~150 LOC).
   - `WindowGroup(id: "DirectorView")` in `SimplePlaybackApp`.
   - View → Director View menu item; `Cmd-Shift-D` shortcut.
   - Default opens centered on the primary display, sized 1280×720.

4. **Hotkey suppression** (1 commit, ~120 LOC + 60 LOC tests).
   - `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` scoped to the Director View window.
   - Drops Space / Esc / B / Cmd-Shift-L / Cmd-1..9 / numpad 0-9 / J / K / L / Enter / Cmd-Enter from reaching the runtime.
   - Test seam: pure-logic `DirectorViewKeyFilter.shouldSuppress(event:)` over an NSEvent stand-in.

5. **Display-fingerprint persistence** (1 commit, ~150 LOC + 80 LOC tests).
   - `DirectorViewWindowManager` owns last-display UUID; on launch, finds the matching `NSScreen` and sets the window frame onto it.
   - Fallback to primary display when last-display absent.
   - Pure-logic test covers: unknown UUID, multiple matching UUIDs (impossible per Apple but defended), empty screen list.

6. **Display unplug fallback** (1 commit, ~100 LOC + 60 LOC tests).
   - `NSApplication.didChangeScreenParametersNotification` observer.
   - When the Director View's current screen disappears, snap to primary, surface a `Toast` (reuse `ImportStatusBanner` shape or build a new toast service).
   - Test seam: pure-logic `DirectorViewDisplayPolicy.recoverFrame(currentFrame:availableScreens:)`.

7. **Manual rehearsal section** (1 commit, doc-only). New section in `docs/manual_verification.md`.

## Optional extensions (each adds 1-2 commits)

- **Advanced fields toggle** (Option D candidates from question 1) — 1 commit each for elapsed/remaining counters, dropped-frame chip, TC chase, take history sidebar, Show List fragment.
- **Director View OSC subscribe target** — let an external display (iPad running a web client) subscribe to the same projections payload via WebSocket. This crosses into v3 (per spec §4 item 15: browser remote read-only monitor).

## Risks / unknowns

- **macOS focus-following-keyboard-shortcuts behaviour.** SwiftUI's `.keyboardShortcut` modifier attaches to the focused view's window; a Director View window that takes focus could absorb cue hotkeys. The hotkey suppression above plus a `becomesKey: false` window may handle it, but this needs a real two-display rehearsal.
- **Window frame restoration vs full-screen.** A director with a dedicated display may want the window full-screen; macOS's full-screen on a secondary display has historically been finicky (creates a new Space, complicates app-quit). Recommend: ship windowed-only first; full-screen-on-secondary-display as a v2.1 follow-up.
- **High-DPI text legibility.** A 27" 4K display 8 feet away renders SwiftUI default fonts smaller than ideal. Need explicit large-font sizing per the "tired person in a dim booth" anti-pattern (spec §6).

## When to revisit

- Multi-operator workflows become a real customer ask → ship and iterate.
- iPad remote-monitor (spec §4 item 15) ships → likely renders Director View on iPad redundant for the corporate-AV market; reconsider scope.
- Show Mode evolves to lock the Director View toggle → revisit Q6.

## Estimated effort

5-7 commits, ~850-1100 LOC + ~320-450 LOC tests. The bulk is the SwiftUI layout + display-management; hotkey suppression and pure-logic projections are small.
