# v2 Pre-Scope — Watched Asset Drop Folder

**Status**: pre-scope (planning only — no code).
**Filed**: 2026-05-08, session 28.
**Spec source**: `docs/spec/feature_spec.md` §4 item 14 ("Watched asset drop folder for content-runner workflow during show.").
**Progress source**: not in `docs/progress.md` — v2 spec §4 candidate.

---

## Why v2, not v1

Corporate-AV shows often have a "content runner" — a producer or AD who delivers last-minute slates / videos / corrections to the playout machine while the show is running. v1's content-import flow is operator-explicit: the operator clicks Add, picks files, sees an import-status banner, and then the cue inspector. That's deliberate (per spec §3.10 "no silent file rename, relocation, or transcode"); the operator owns every asset in the project.

The watched-drop-folder pattern flips this for the content-runner case: a known location on disk where files dropped *appear in the palette as proposed slides* — but never auto-fire, never overwrite an existing slide, and require operator-explicit "accept" before becoming part of the show. The operator stays in the loop; the runner just gets a faster delivery channel than handing a USB drive across the booth.

v1 didn't ship this because:
- It is an explicit operator-experience-level integration, not a runtime feature.
- The "what triggers the watch" / "what filename conventions" / "where do new slides appear in the palette" / "what about transcoding" questions all need operator input.
- It overlaps with C8 (folder-level bookmarks) and C9 (missing-media UX) — both shipped in v1 and are the foundation this builds on.

## What "Watched asset drop folder" means in v1+ terms

A non-modal palette-side feature:

- **A `Drop/` folder** (configurable) under the project bundle, watched at the OS level (FSEvents or DispatchSource).
- **New files** appearing in `Drop/` go through the existing `MediaImporter.importSlides(...)` path, get fingerprinted, transcoded if applicable, and surface as a "Pending" group at the top of the palette.
- **Operator approval**: each pending slide has an Accept / Reject affordance. Accept moves the slide into the main palette; Reject deletes the file from `Drop/` (with confirmation if Show Mode is on).
- **Auto-naming** based on file name → cue title; operator edits in the inspector after accept.
- **No auto-fire, no auto-cue creation**: the slide appears in the palette only; building a cue from it is operator-explicit.

## Open product questions

1. **Drop folder location.**
   - **A — Inside the project bundle**: `<bundle>/Drop/`. Travels with the show; auto-creates on first watch.
   - **B — A user-configurable absolute path**: e.g., `~/Dropbox/ShowDrop/` for cross-machine delivery via a sync service.
   - **C — Both**: bundle default, optional override.
   - **My recommendation**: C. Bundle default for the in-booth case; configurable for the cross-machine case (the runner's laptop syncs Dropbox into the booth machine's local folder).

2. **Watch trigger granularity.**
   - **A — Watch on file rename / close** (FSEvents `kFSEventStreamEventFlagItemRenamed` + close notification). Most reliable indicator that a file is fully written.
   - **B — Watch on file create**: simplest, but partial files appear in the palette.
   - **C — Stability window**: a file appearing in `Drop/` is held for N seconds after last-modified before importing. Catches partial writes.
   - **My recommendation**: C with a 2-second window. Robust against incomplete copies / sync-service write patterns; small enough not to feel laggy.

3. **What file types are accepted?**
   - **A — Same set as drag-drop import** (image / video / PDF / Keynote — the v1 supported types).
   - **B — Stricter set** for drop folder (image / video only, no auto-rasterize of PDF / Keynote in case of long renders).
   - **C — Operator-configurable allowlist**.
   - **My recommendation**: A. Reuses MediaImporter's existing path; the C-banner surfaces import failures; nothing magic.

4. **Pending palette section UI.**
   - **A — A "Pending" tab** at the top of the palette with its own list.
   - **B — A pending banner** above the palette with a count + "Review pending" link.
   - **C — Inline at the top of the existing palette grid** with a visual flag (yellow border).
   - **My recommendation**: A. Operators expect a clear separation between "ready content" and "needs my review."

5. **Show Mode interaction.**
   - **A — Watch is suspended in Show Mode** — operator doesn't want surprises mid-show.
   - **B — Watch continues, but Accept is disabled** in Show Mode (drops queue silently; operator reviews after).
   - **C — Watch continues + Accept available**, with an extra confirmation in Show Mode.
   - **My recommendation**: B. The runner can keep delivering content; the operator reviews after the show or at a planned break. Show Mode's principle is "no surprise mutations during the show," and Accept is a mutation.

6. **Auto-transcode policy.**
   When a video is dropped that hits a transcode-recommendation flag (long-GOP, VFR, untagged color — per C1):
   - **A — Auto-transcode on drop** so the slide is play-ready when the operator accepts.
   - **B — Surface the recommendation, defer transcode** to operator click (current v1 inline transcode button behaviour).
   - **My recommendation**: B. Auto-transcoding consumes minutes of CPU + writes to disk; that's a side-effect operators want to authorize. Spec §3.10 "no silent transcode" applies.

7. **Reject behaviour.**
   - **A — Move file to `Drop/Rejected/`** (preserves the runner's work for re-delivery).
   - **B — Delete from `Drop/`**.
   - **C — Operator-configurable** (default A in Show Mode, B otherwise).
   - **My recommendation**: A. Preserves the runner's work; the operator can clean `Drop/Rejected/` post-show without it cluttering the palette.

## Dependency map

- **`Services/DropFolderWatcher.swift`** (new) — wraps `DispatchSource.makeFileSystemObjectSource` (or FSEvents); emits a debounced "new file ready" stream gated by a stability window.
- **`Services/PendingDropQueue.swift`** (new) — pure-logic queue + lifecycle: pending → accepted (moved into palette) | rejected (moved to `Drop/Rejected/`).
- **`PlayoutProject.dropFolderConfig: DropFolderConfig?`** (new) — per-project enable + path override (Q1-C).
- **`MediaImporter`** — reused as-is; the drop watcher routes new files through `importSlidesAndReport(...)`.
- **`Views/PaletteView.swift`** — Pending tab (Q4-A) + Accept / Reject buttons.
- **`Views/RootView.swift`** — wires `DropFolderWatcher` lifecycle to project-open / project-close + Show Mode transitions.
- **C8 folder-bookmark integration**: dropped files inside a folder bookmark stay linked-mode (don't get copied into the bundle) — match the existing C8 path.

## Suggested first-slice (5-7 commits)

1. **`DropFolderConfig` model + project decode-if-present** (1 commit, ~80 LOC + 60 LOC tests). Per-project config stored in `PlayoutProject.dropFolderConfig`.
2. **`DropFolderWatcher` pure-logic stability-window** (1 commit, ~150 LOC + 120 LOC tests). Reads file modification times via injectable provider; emits `.ready(URL)` after 2 seconds of inactivity.
3. **`DropFolderWatcher` FSEvents binding** (1 commit, ~120 LOC). Real-FS watcher feeding the pure-logic stability-window.
4. **`PendingDropQueue` pure-logic** (1 commit, ~120 LOC + 80 LOC tests). Pending → accepted | rejected with file-move semantics; Show Mode interaction (Q5-B).
5. **Pending tab in palette** (1 commit, ~150 LOC). Tab UI + Accept / Reject affordances.
6. **Project lifecycle wiring + Show Mode integration** (1 commit, ~80 LOC). Watcher starts on project open; suspends Accept on Show Mode (Q5-B).
7. **Reject → `Drop/Rejected/` move** (1 commit, ~40 LOC + 40 LOC tests). Q7-A.

## Risks / unknowns

- **FSEvents reliability on network volumes**. Some NAS mounts don't fire FSEvents reliably. The stability-window approach (Q2-C) is robust against missed events because it polls the file's mtime; document the network-volume limitation.
- **Sandbox + watched folder access**. Watching an arbitrary user-picked path requires a security-scoped bookmark (the C8 mechanism is the foundation). Reuse `Services/FolderBookmarkRegistry`.
- **Concurrent drops + race**. Two files dropped within milliseconds: ensure the queue handles them in order. Use a serial dispatch queue inside `PendingDropQueue`.
- **Filename collisions**. A file dropped with the same name as one already in the palette — does Accept overwrite? Match the C-banner's "name collision deduper" pattern (rename to `name (1).ext`).

## When to revisit

- Operators ask for auto-cue-creation (drop a file → cue appears in show list at playhead) → ship as v2.1; current scope is palette-only.
- Multi-runner workflows want per-runner authentication → much larger scope; new spec conversation.
- Cloud-storage integrations (Dropbox-aware client, CloudKit-aware sync) → out of scope unless the corporate-AV target operator asks; the file-system watcher is sync-service-agnostic.

## Estimated effort

5-7 commits, ~740-940 LOC + ~300-380 LOC tests. The pure-logic pieces (stability window, pending queue) carry most of the test weight; the UI and FSEvents binding are mechanical.
