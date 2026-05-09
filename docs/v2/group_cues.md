# v2 Pre-Scope — Group Cues

**Status**: pre-scope (planning only — no code).
**Filed**: 2026-05-08, session 28.
**Spec source**: `docs/spec/feature_spec.md` §4 item 7 ("Group cues (start-first, start-all, start-random, timeline group).").
**Progress source**: not in `docs/progress.md` — v2 spec §4 candidate.

---

## Why v2, not v1

The v1 cue model ships a flat list with one running cue at a time (per A4: GO / PREV / PANIC / CLEAR + autoContinue / autoFollow continuation). That's enough for a single-screen single-track corporate-AV show. Group cues are the QLab-style abstraction that lets the operator say "this slate group starts together," "this transition fires the next of N options at random," "this timeline group fires sub-cues at offsets relative to group start."

v1 deferred because group cues touch every layer:

- **Cue model** — a Cue can contain other Cues; recursive playback.
- **Runtime** — multiple cues running concurrently; per-group fire mode.
- **Show List view** — nested rendering; expand/collapse; reorder within a group.
- **OSC / HTTP** — `fire cue X` semantics extend to group fire modes.
- **Show log** — group-fire events log their children too?

Each of those decisions is a real conversation. The corporate-AV target operator asked for nothing of this kind during v1 spec; QLab-experience operators are the ones who want it.

## What "Group cues" means in v1+ terms

A new cue kind that contains an ordered list of child cues plus a fire-mode policy:

- **Cue.kind = .single | .group(GroupMode)** (new). `.single` is the v1 cue.
- **`GroupMode`**:
  - `.startFirst` — fire the first cue, leave the rest as standby (operator GOs through subsequent cues normally).
  - `.startAll` — fire all child cues simultaneously (with their own pre-waits respected).
  - `.startRandom` — pick one child at random and fire it; standby the rest.
  - `.timeline` — fire each child at offset T relative to group fire (T from a per-child `groupOffset: TimeInterval`).
- **Show List view** — nested `DisclosureGroup` with hover-affordance reorder.
- **OSC** — `fire cue id "GROUP_X"` fires the group; child cues remain individually addressable (`fire cue id "GROUP_X.SLATE_A"` or similar).

## Open product questions

1. **Nesting depth.**
   - **A — One level only**: groups can't contain groups.
   - **B — Two levels**: group of groups allowed (matches Theatre conventions).
   - **C — Unlimited depth**.
   - **My recommendation**: A for v2.0. Most use cases (slate group, transition group, random slate) fit one level. Unlimited recursion is a UX trap (what does "PANIC" do five levels deep?). v2.1 can add B if operators ask.

2. **Cue-id namespacing for children.**
   - **A — Flat global namespace**: child cue IDs must still be unique across the whole show.
   - **B — Group-scoped IDs**: `GROUP_X.SLATE_A` etc., with dot-notation addressing in OSC.
   - **My recommendation**: A. Keeps the v1 case-insensitive uniqueness invariant (A2) intact and avoids breaking existing OSC integrations. Operators who want grouping aliases can use prefix conventions (`G1_SLATE_A`).

3. **PANIC behavior.**
   - **A — PANIC stops every running cue everywhere** including all children of running groups. Matches v1.
   - **B — PANIC stops the *playhead* group only**, leaving other running groups alone.
   - **My recommendation**: A. PANIC is "blanket safety" by spec (§3.5); group-scoped panic violates the "one big red button" mental model.

4. **`.startAll` and pre-waits.**
   When a group has `.startAll` and three children with pre-waits 0 / 0.5 / 1.0 seconds:
   - **A — Pre-waits respected**: each child fires at group-start + its own pre-wait.
   - **B — Pre-waits ignored**: all children fire at group-start.
   - **C — Operator-configurable per group**: a `respectChildPreWaits: Bool` flag on the group.
   - **My recommendation**: A. The whole point of pre-wait is to slip a cue's start; the group fire-mode is "start all together" — which means "all start their own staged-start sequences together," not "discard staging." Operators wanting B can set child pre-waits to zero.

5. **`.timeline` continuation policy.**
   When a `.timeline` group's last child finishes, does the group fire its `.continuation` (autoContinue / autoFollow) or stop?
   - **A — Group continuation honoured** as if it were a single cue (longest-running child = "the group"; group's postWait fires when the longest child ends).
   - **B — Group always halts at end**, ignoring `.continuation`.
   - **My recommendation**: A. Lets timeline groups chain into the next show segment.

6. **Show log entries.**
   `.startAll` group with three children fires:
   - **A — One `.go` entry per child** + a `.go` entry for the group itself.
   - **B — Just one `.go` for the group** with `detail: "fired 3 children: SLATE_A, SLATE_B, SLATE_C"`.
   - **C — Configurable per project** (verbose / compact).
   - **My recommendation**: B. Operator-readable log without flooding; the verbose form is reconstructible from the group's child list at log-replay time.

7. **OSC `fire group cue X` semantics.**
   When the integrator fires the group via `/sp/cue/GROUP_X/play`:
   - **A — Always fires the whole group** per its mode.
   - **B — Fires the group in `.startFirst` mode regardless of authored mode** (useful for "treat group as advance one")
   - **My recommendation**: A. Authored mode is ground truth; operators wanting a "fire first child only" can address the child directly.

## Dependency map

- **`Models/Cue.swift`** — `kind: CueKind` (new); `groupMode: GroupMode?` for `.group` kind; `groupOffset: TimeInterval?` (per-child timeline offset). Decode-if-present for legacy projects (default `.single`).
- **`Models/CueKind.swift`** + **`Models/GroupMode.swift`** (new).
- **`Runtime/CueRuntime.swift`** — `go(targetID:)` resolves to a group-aware fire path; group fires call `goSingle(...)` for each child according to mode. New `runningGroupIDs: Set<UUID>` to track in-flight groups + their children.
- **`Views/ShowListView.swift`** — `DisclosureGroup` rendering of group children; drag-drop reorder within a group (existing reorder code applies recursively).
- **`Views/CueInspectorView.swift`** — group-mode picker; per-child timeline offset picker for `.timeline` groups.
- **`ShowControlDispatcher`** — `.go(target:)` already addresses any cue ID; group-fire semantics live in the runtime, not the dispatcher.
- **`ShowLog`** — Q6-B compact entry shape.
- **`PlaybackController`** — `.startAll` and `.timeline` groups fire multiple `take(...)` calls concurrently. The compositor's three-layer cap (B12) means simultaneous-running cues compete for the media layer; resolve via "last cue fired wins on the media layer; bug + message overlays remain composited."

## Suggested first-slice (6-9 commits)

1. **Cue model + decoder migration** (1 commit, ~120 LOC + 80 LOC tests). `CueKind`, `GroupMode`, `groupOffset`. Legacy decode = `.single`.
2. **`CueRuntime` group-aware go path** (1 commit, ~150 LOC + 200 LOC tests). `goSingle` extracted; `goGroup` dispatches per mode.
3. **Show List nested rendering** (1 commit, ~150 LOC). DisclosureGroup; expand/collapse.
4. **Cue inspector group-mode picker** (1 commit, ~100 LOC).
5. **Per-child timeline offset for `.timeline` groups** (1 commit, ~80 LOC + 60 LOC tests). Pure logic for offset ordering.
6. **PANIC across running groups** (1 commit, ~80 LOC + 60 LOC tests). Q3-A.
7. **Show log group-fire entries** (1 commit, ~60 LOC + 40 LOC tests). Q6-B compact form.
8. **OSC fire-group integration** (1 commit, ~40 LOC + 80 LOC tests). Q7-A.
9. **Compositor concurrency policy** (1 commit, ~80 LOC + 60 LOC tests). Last-cue-wins on media layer; bug + message overlays composite from the most recent fire.

## Risks / unknowns

- **Compositor concurrency**. Spec §3.6 caps the compositor at three layers (media + bug + message). Concurrent media cues from a `.startAll` group is undefined v1 behaviour — pick "last cue fired wins on media layer" and document.
- **Show List drag-drop with nested groups**. Dragging a cue into / out of a group changes its group-membership; dragging a group into another group is forbidden by Q1-A. UI needs explicit drop zones for "enter group" vs "place after group."
- **`runtime.markLoaded` for groups**. The OSC `.load(cueNumber:)` action marks a cue loaded but doesn't fire it. For groups, this would mean "load all children." Practical?
- **Crash recovery (E7) state replay**. The autosave checkpoint must capture `runningGroupIDs` so a recovery session can faithfully restore "this group is mid-fire."

## When to revisit

- Operators ask for nested groups (Q1-B) → ship in v2.1.
- A specific show needs `.startRandom` weighted (some children more likely than others) → extend `GroupMode.startRandom` with weights.
- Lighting console integration (post-MIDI Show Control) needs to fire individual children of a group → already addressable via cue-id namespace; no schema change.

## Estimated effort

6-9 commits, ~860-1180 LOC + ~580-820 LOC tests. The runtime changes are the high-risk surface; everything else is mechanical. Pin tests for every group mode + every interaction with `.continuation`.
