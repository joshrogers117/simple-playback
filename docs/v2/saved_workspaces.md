# v2 Pre-Scope — Saved Workspaces (E10)

**Status**: pre-scope (planning only — no code).
**Filed**: 2026-05-08, session 27.
**Spec source**: `docs/spec/feature_spec.md` §3.15 ("Saved Workspaces: 'Edit', 'Rehearsal', 'Show', 'Single Screen' — window/panel layouts, not project content").
**Progress source**: `docs/progress.md` E10 ("Saved Workspaces") — pending; deferred per `docs/handoff.md` "v2 enablement candidates" as UX-design heavy.

---

## Why v2, not v1

Saved Workspaces are a layout-management feature, not a runtime feature — they don't change what the app *does*; they change how the operator sees what it does. The v1 surface intentionally ships a single layout for a single operator (palette + show list + inspector + preview/program); the corporate-AV target operator has been using that layout for the entire build.

Two reasons it's UX-design heavy:

1. **The set of preset workspaces is opinionated.** Spec lists four ("Edit", "Rehearsal", "Show", "Single Screen") but doesn't pin what each one shows / hides. "Edit" presumably has the inspector + asset library prominent; "Show" presumably hides the inspector and enlarges the program tile; "Rehearsal" is somewhere between. Each preset is a designed layout, not a generated one.
2. **The persistence shape interacts with project portability.** Workspaces are *not* project content (per spec) — they're per-machine, per-user settings. But operators expect "the show I bundled for travel restores to my Show layout when I open it on a different machine," which crosses the boundary. Resolution: workspace presets are per-machine, but the *active workspace name* could optionally be stamped in the project bundle so an operator-bundled-for-travel project hints "open me in Show mode" on the destination machine.

## What "Saved Workspaces" means in v1+ terms

A `Workspaces` data model + UI:

- A `Workspace` is named (preset names + user-defined) and captures: which top-level windows are open (Main / Director / Preview / Program / ShowLog / TakeHistory), each window's position + size + which display, and per-window panel visibility (Inspector visible? Show List width? Palette width? Preview/Program ratio?).
- A small set of factory presets ship with the app (Edit / Rehearsal / Show / Single Screen) and are non-editable but cloneable.
- Operator-defined workspaces can be added via "Save Current as Workspace…" → naming + optional project-bundle hint.
- A View → Workspace menu lets the operator switch active workspace at any time, with a `Cmd-Shift-W` cycle hotkey (or numbered shortcuts `Cmd-Ctrl-1..9` for the first 9).
- Active workspace persists across launches per machine + per user.

## Open product questions

These need an operator-side answer before any code lands:

1. **Preset layouts — what does each preset show?**
   The spec names four; recommended defaults:
   - **A — Edit**: Main window full screen on primary, all panels visible (Palette + Show List + Inspector + Preview/Program), Inspector wide, Show List narrower, no tear-off windows.
   - **B — Rehearsal**: Main window primary, Inspector hidden, Show List wider, Director View open on secondary if a second display is connected.
   - **C — Show**: Main window primary with Show List + Preview/Program (Inspector hidden, Palette hidden or collapsed), Director View on secondary, ShowLog tear-off on tertiary if available, Take History off.
   - **D — Single Screen**: Main window full screen, Show List + Preview/Program only, Inspector hidden, Palette as compact strip.
   - **My recommendation**: ship A/B/C/D as defined; user-defined presets cover deltas.

2. **Is "operator-defined workspace" a v2 feature, or is it v3?**
   - **A — v2 ships presets only.** Lower scope, faster ship, same operator value (the four presets are the dominant cases).
   - **B — v2 ships presets + user-defined.** Operator-defined adds significant UX surface ("Save current as…", management UI, rename, delete).
   - **My recommendation**: A. The four presets cover ~90 % of the demand; user-defined workspaces are v3.

3. **Workspace switch — instantaneous, animated, or with confirmation?**
   - **A — Instantaneous.** Window positions snap; tear-off windows close/open immediately.
   - **B — Animated.** Smooth resize / fade. Visually polished but ~300 ms feels slow when an operator is racing to fix a wrong layout 10 minutes before doors.
   - **C — Confirmation when in Show Mode.** The "I just bumped Cmd-Ctrl-1 by accident" defense.
   - **My recommendation**: A always; ignore the switch entirely when in Show Mode (treat workspace shortcuts as edit actions, not show actions). Mirrors the existing Show Mode lockout.

4. **Project-bundle hint stamping.**
   - **A — Stamp** the active workspace name into the project bundle's `Show.json` so opening it on another machine attempts to restore that workspace name. Falls back to default if name doesn't exist on the new machine.
   - **B — Don't stamp.** Workspaces are per-machine; portability is an anti-goal.
   - **My recommendation**: A — stamp the name, restore best-effort. The "other machine doesn't have that workspace" fallback is to open in default workspace.

5. **What survives across machines vs stays per-machine?**
   - Display assignments are inherently per-machine (display UUIDs differ).
   - Window sizes / positions are per-machine (display geometry differs).
   - Panel visibility is *theoretically* portable (Inspector hidden / shown is the same on any machine).
   - Workspace name + panel-visibility intent: portable.
   - Workspace window geometry: per-machine.
   - **My recommendation**: workspace stores intent (panel visibility, window roles, which displays) per-machine; portable layer is "active workspace name" only.

6. **Tear-off windows — are they workspace-controlled or independent?**
   Director View, Show Log, Take History are tear-off windows that today open via menu. In a workspace context, "Show" workspace might want Director View auto-open and Show Log on tertiary. Confirm: workspace owns tear-off-window-lifecycle (workspace switch closes the previous workspace's tear-offs; opens the new workspace's tear-offs).

## Dependency map

- **`Services/WorkspaceManager.swift`** (new) — owns the active workspace, the preset list, the persistence layer (per-machine via `UserDefaults`).
- **`Workspace` data model** — name, list of windows-and-their-states, panel-visibility flags, optional display-UUID hints (per-machine restoration).
- **`SimplePlaybackApp.swift`** — applies workspace at launch; owns workspace cycle hotkey.
- **`Views/RootView.swift`** — reads panel-visibility from the active workspace; Inspector / Show List width / Palette state are bound to workspace state.
- **`SimplePlaybackProjectDocument.swift`** — optional `activeWorkspaceName: String?` field in `Show.json` (Q4 above).
- **`Views/DirectorViewWindowManager`** + **show-log / take-history window managers** — workspace switches drive their show/hide.
- **Migration** — legacy projects (no `activeWorkspaceName` field) decode with nil; behaviour is "use whatever workspace is currently active on this machine," which equals current v1 behaviour.

## Suggested first-slice (5-7 commits)

1. **`Workspace` data model + WorkspaceManager** (1 commit, ~250 LOC + ~150 LOC tests).
   - `struct Workspace { name, windows: [WindowState], panels: PanelVisibility, displayHints: [String: UUID] }`.
   - `class WorkspaceManager: ObservableObject` exposes `activeWorkspace`, `setActive(name:)`, `availablePresets`.
   - Persists to `UserDefaults` at the active-workspace level.

2. **Four factory presets** (1 commit, ~150 LOC + ~80 LOC tests).
   - Hard-coded presets matching Q1 above. Pin names; pin panel visibility.

3. **RootView panel-visibility binding** (1 commit, ~120 LOC).
   - Inspector / Show List width / Palette state read from `WorkspaceManager.activeWorkspace.panels`.
   - Visual smoke-test: switching between Edit and Show toggles inspector visibility live.

4. **Workspace switch UI** (1 commit, ~80 LOC).
   - View → Workspace menu lists presets; checkmarks the active.
   - `Cmd-Shift-W` cycles forward; `Cmd-Shift-Opt-W` cycles backward.

5. **Tear-off window lifecycle** (1 commit, ~150 LOC + ~80 LOC tests).
   - Workspace switches drive `DirectorViewWindowManager` / show-log / take-history open/close per workspace's `windows: [WindowState]` list.

6. **Show Mode interaction** (1 commit, ~60 LOC + 40 LOC tests).
   - Workspace switch hotkeys are no-op in Show Mode; menu items disabled. Mirrors existing edit-action lockout shape.

7. **Project-bundle hint stamping** (1 commit, ~80 LOC + 40 LOC tests).
   - `Show.json` adds optional `activeWorkspaceName`. Stamped on save when active workspace is non-default. Read on open and applied if the named workspace exists locally; else log the miss to `decision_log.md`-style debug log and stay on default.

## Risks / unknowns

- **macOS window restoration baseline.** macOS `NSDocument` already restores window geometry on document re-open; the workspace layer needs to **override** the default restoration when the workspace specifies a target geometry. Naming clash is real; need to gate the override behind "workspace is active and specifies a geometry."
- **Display-UUID stability across reboots.** Same concern as Director View pre-scope (Q5 there): `CGDisplayCreateUUIDFromDisplayID` is stable across reboots but unstable across display swap.
- **Workspace fight with full-screen mode.** Operators may have the Main window full-screen; switching to Single Screen workspace should reset to windowed. macOS full-screen-exit is animated; document the brief flicker.
- **Operator confusion vs operator power.** Hidden panels (Inspector hidden in Show workspace) may surprise an operator who's used to the Edit layout. Recommend: status-bar tooltip or transient toast on workspace switch ("Workspace: Show — Inspector hidden") for the first ~3 seconds.

## When to revisit

- Operators ask for >4 user-defined workspaces → bump to user-defined ship (Q2 Option B).
- Show Mode evolves to forbid workspace switching even via menu → tighten Q3.
- Multi-display rehearsal surfaces window-position-restoration bugs → revisit display fingerprint policy.

## Estimated effort

5-7 commits, ~890-1100 LOC + ~390-470 LOC tests. The complexity is in the SwiftUI panel-visibility binding (state propagation through deeply nested views) and the tear-off window lifecycle.
