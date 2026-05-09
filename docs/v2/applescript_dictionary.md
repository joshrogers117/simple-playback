# v2 Pre-Scope — AppleScript Dictionary

**Status**: pre-scope (planning only — no code).
**Filed**: 2026-05-08, session 28.
**Spec source**: `docs/spec/feature_spec.md` §4 item 5 ("AppleScript dictionary for macOS-native automation.").
**Progress source**: not in `docs/progress.md` — v2 spec §4 candidate.

---

## Why v2, not v1

AppleScript and the modern AppleScript-Objective-C bridge (Scripting Bridge / `OSAKit`) are the macOS-native way to drive an app from another app — Keynote driving slides into a separate playout system, Apple Reminders firing a cue at a scheduled time, Hammerspoon mapping a hotkey to a custom action. v1 shipped OSC + HTTP for cross-platform integration; AppleScript is the macOS-only "every other Mac app speaks this" path that operators ask for once they've used QLab or ProPresenter (both have rich AS dictionaries).

The mechanics: declare a `.sdef` (Scripting Definition) bundle resource describing classes, properties, and commands; subclass `NSScriptCommand` for each command; populate `NSScriptObjectSpecifier` chains for each addressable property. The work is mechanical but tedious — every supported verb needs an `NSScriptCommand` handler, every queryable property needs a `objectSpecifier` getter, and the .sdef XML has to stay in lock-step with the implementation.

Spec §4 is one line. The shape is "expose the OSC action surface as AppleScript verbs," but AS introduces things OSC doesn't have: addressable object specifiers (`every cue whose state is "running"`), tell-block scripting style, and synchronous return values that scripts can branch on.

## What "AppleScript dictionary" means in v1+ terms

A `.sdef` resource declaring at minimum:

- **Application class** (top-level), addressable. Properties: `version`, `apiVersion`, `documents`, `frontmost`.
- **Document class** (= one open `.spb` bundle). Properties: `name`, `path`, `modified`, `showMode`, `playheadCueID`, `liveCueID`, `cues` (element).
- **Cue class** (per-cue). Properties: `id`, `number`, `name`, `notes`, `state`, `continuation`, `preWait`, `postWait`. Commands: `fire`, `stop`, `goto`.
- **Show verbs as commands**: `go`, `previous`, `panic`, `clear`, `blackout`, `set show mode`.
- **Capability**: AppleScript auto-grants `read + fire + edit` to any local script (the user has to explicitly allow Apple Events on this app per Apple's automation security model).

## Open product questions

1. **Editing scope.**
   `set notes of cue 1 of front document to "..."` is an edit operation. Does Show Mode lock it out the same way it strips `edit` from OSC tokens?
   - **A — Yes, Show Mode strips edit verbs** for AppleScript scripts identically to OSC. Predictable.
   - **B — No, AppleScript bypasses Show Mode** because the user explicitly allowed the script.
   - **C — Operator-configurable per script** (impossible to enforce without identifying the calling script).
   - **My recommendation**: A. Show Mode is a safety net regardless of source. The operator who deliberately allowed Apple Events to a script is presumably also the operator who toggled Show Mode on; the strip is the "I'm running a show" guarantee.

2. **Element-specifier semantics.**
   AS supports complex specifiers: `every cue whose state is "standby"`, `cue 3 of show list 1 of front document`. Implementing all of these is a lot of glue. What's the minimum?
   - **A — Just `cue id "INTRO"` and `cue 1`** (numeric index + by-ID).
   - **B — A + `every cue whose ...`** for state, continuation, name-contains.
   - **C — Full QLab-grade specifier coverage**.
   - **My recommendation**: A for v2.0; B as a v2.1 follow-up if operators ask. Most automation scripts are one-shot fire-by-id calls.

3. **Synchronous return values.**
   `set fired_cue to fire cue id "INTRO" of front document`. Should `fire` block until the take has reached the output, or return immediately with the cue's ID?
   - **A — Return immediately** with `{cue_id, fired_at_iso8601}` (mirror of OSC).
   - **B — Return after the take is queued** (very fast — sync to playhead update).
   - **C — Return after the first composed frame** (Path 1 from late-take detector — slow, several frames).
   - **My recommendation**: A. AS scripts that need "wait until on screen" loop on `state of cue X` polling; binding sync semantics into the `fire` verb adds unbounded blocking risk.

4. **Property-write triggering events.**
   `set show mode of front document to true` — should this fire `.showModeOn` in the show log with source `system`?
   - **A — Yes, log every property write** with `source: applescript`. Symmetrical to OSC source attribution.
   - **B — Log only show-affecting writes** (showMode toggles, cue notes edits during show).
   - **C — No log entries for property writes**, only for command invocations.
   - **My recommendation**: A. Use a new `ShowLogEvent.Source.applescript(processName: String)` that records the calling app's name (Apple Events surfaces it).

5. **Interaction with the existing OSC `.cueNotes` / `.cueGoto` ack-only stubs.**
   Some ack-only OSC verbs (`/sp/cue/{id}/notes`, `/sp/cue/{id}/goto`, etc.) are listed in `docs/api.md` as "v1 ack-only — host interceptor not wired." AppleScript would be the second consumer of those stubs. Should the AS surface ship before or after those stubs are wired?
   - **My recommendation**: AS ships only the verbs that have working host interceptors. The ack-only OSC verbs are not part of the v2.0 AS dictionary — they show up when each interceptor lands.

6. **Sandbox / Apple Events entitlement.**
   The app already declares `com.apple.security.automation.apple-events` (for Keynote driving). Adding incoming Apple Events handlers requires the app to be a *target*, which is the default for any GUI app — no extra entitlement, but the calling script needs to be granted access by the user via macOS Privacy settings the first time.
   - **My recommendation**: document this in `docs/api.md` AppleScript appendix; no entitlement change.

## Dependency map

- **`Resources/SimplePlayback.sdef`** (new) — XML scripting definition. Loaded automatically by macOS when registered in `Info.plist` (`OSAScriptingDefinition` key + `NSAppleScriptEnabled = YES`).
- **`Scripting/`** (new directory) — one file per addressable class:
  - `Scripting/SPApplication.swift` — addresses `NSApplication`'s scripting; routes to `documents`, `frontmost`.
  - `Scripting/SPDocument.swift` — `NSScriptObjectSpecifier`-aware `NSDocument` extension.
  - `Scripting/SPCue.swift` — addresses individual cues; reads from the active document's `runtime.showList`.
- **`Scripting/Commands/`** — `NSScriptCommand` subclasses for `go`, `previous`, `panic`, `clear`, `fire`, `stop`, `goto`.
- **`ShowControlSource.applescript(processName: String?)`** + `ShowLogEvent.Source.applescript(...)` — new source-attribution case.
- **`ShowControlHub` / `ShowController`** — new entry path bypassing the dispatcher's network-queue hop, since AS handlers run on main already. Same dispatcher action shape, same `notifyDispatched`.
- **`Info.plist`** — `NSAppleScriptEnabled = YES`, `OSAScriptingDefinition = SimplePlayback.sdef`.

## Suggested first-slice (5-7 commits)

1. **`SimplePlayback.sdef` v0** (1 commit, ~120 LOC XML). Application + Document + Cue classes; verbs `go`, `previous`, `panic`, `clear`. Read-only properties only.
2. **`Scripting/SPApplication` + `SPDocument` glue** (1 commit, ~150 LOC). Object specifiers wired up; `Info.plist` flag flipped.
3. **`SPCue` + element specifiers (A from Q2)** (1 commit, ~150 LOC + 100 LOC tests).
4. **Show-verb commands** (1 commit, ~150 LOC). `go`, `previous`, `panic`, `clear`, `set show mode` route through the dispatcher with `ShowControlSource.applescript(...)`. Q1-A: Show Mode strips `edit`.
5. **Per-cue commands** (1 commit, ~120 LOC). `fire cue X`, `goto cue X`. Reuses dispatcher actions.
6. **Source attribution + show-log integration** (1 commit, ~80 LOC + 60 LOC tests). `ShowLogEvent.Source.applescript(processName:)` end-to-end.
7. **`docs/api.md` AppleScript appendix** (1 commit, doc-only). Verbs, examples, sandbox / Privacy settings note.

## Risks / unknowns

- **Sandboxed app + Apple Events**: Simple Playback is sandboxed. Receiving Apple Events from outside processes requires the calling script to be granted access via Privacy → Automation. Document this as a one-time setup step.
- **Element specifier complexity**: even Q2-A (numeric index + by-ID) requires correct `NSScriptObjectSpecifier` chains. Apple's Cocoa Scripting Programming Guide is the reference; budget extra time on the first commit for shape research.
- **Synchronous AS expectations**: AppleScript expects `fire cue X` to return synchronously. The dispatcher's runtime hop is sync (it uses `DispatchQueue.main.sync`), but AS handlers run on main already, so the test-path branch (`Thread.isMainThread`) keeps things synchronous. Verify there's no chained main-actor → main-actor await that would deadlock.
- **`.sdef` and `Info.plist` order**: macOS reads the .sdef path from `Info.plist` at app launch. Wrong path = silent feature drop. Test by running `osascript -e 'tell app "Simple Playback" to activate'` after each commit.

## When to revisit

- Operators / scripters ask for `every cue whose ...` queries → ship Q2-B as a v2.1 follow-up.
- Apple deprecates Carbon-era ScriptingBridge → migrate to whichever modern surface replaces it (Cocoa Scripting + `NSScriptCommand` is the long-term path).
- An integrator asks for AS event handlers (script subscribes to "cue fired" events) → AS supports this via `NSAppleEventManager`; new conversation needed.

## Estimated effort

5-7 commits, ~770-1000 LOC + ~160-220 LOC tests. The .sdef XML and the NSScriptCommand glue are mechanical but have to be exact; budget extra session time on the first commit for shape exploration.
