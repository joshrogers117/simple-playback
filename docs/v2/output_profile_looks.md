# v2 Pre-Scope — Output Profile / Looks

**Status**: pre-scope (planning only — no code).
**Filed**: 2026-05-08, session 28.
**Spec source**: `docs/spec/feature_spec.md` §2.1 ("Output Profile — named snapshot of (Screens + bindings + geometry); venue-portable") and §4 item 1 ("Output Profile / Looks — saved venue topology snapshots. Switch venue-A/B without editing show.").
**Progress source**: `docs/progress.md` B4 (`OutputBindingProfile` schema-only — UI defers).

---

## Why v2, not v1

The v1 build shipped `OutputBindingProfile` as a schema-only type during Phase B (B4). The data shape — `role → device + mode` mapping per machine — exists. What v1 deferred:

- **Operator-visible UI** for naming / saving / switching profiles.
- **Multiple profiles per project**, each addressable by name.
- **`/sp/look/recall` OSC verb** (already in the surface but ack-only — see `docs/api.md` "Not yet wired" appendix).
- **The "Look" half** — independent of Output Profile: per-Screen color / range / overlay defaults, recallable mid-show.

Spec §2.1 separates them deliberately: an **Output Profile** is venue topology (which DeckLink, what mode, which Screen role). A **Look** is per-Screen visual settings (color space override, gamma curve, overlay defaults) that a director might want to A/B during a show. The v1 deferred both because the OSC ack-only stub gave integrators a path forward without locking the UX.

## What "Output Profile / Looks" means in v1+ terms

Two related-but-independent features:

### Output Profile

A named snapshot of `[Screen → (deviceID, modeID, geometry)]` plus per-Screen `expectsExternalReference`, persisted as part of `PlayoutProject` (or as a per-machine override stored alongside). When the operator switches venues — laptop output for editing, two-DeckLink rig for show — they recall a profile rather than walking the Output inspector for every Screen.

- **Data shape**: `OutputProfile { id: UUID, name: String, bindings: [Screen.id: OutputBindingProfile.Binding] }`.
- **Storage**: `PlayoutProject.outputProfiles: [OutputProfile]` + `activeOutputProfileID: UUID?`. Defaults to a single auto-generated "Default" profile derived from the current bindings.
- **UI**: Output inspector tab gains a profile picker (top-of-pane) and a "Save as new profile" menu.
- **Recall**: switching the active profile re-binds every Screen via the existing TransportSinkRouter / DeckLinkVideoOutputDriver path.

### Look

A named snapshot of `[Screen → (color: ColorSpace, range: VideoRange, gamma: GammaCurve, overlays: CompositorOverlays)]`, addressable by name. The director / TD recalls a Look mid-show (`/sp/look/recall name`) to flip from "rehearsal layout" to "show overlays" without editing.

- **Data shape**: `Look { id: UUID, name: String, screens: [Screen.id: ScreenLookSettings] }`.
- **Storage**: `PlayoutProject.looks: [Look]` + `activeLookID: UUID?`.
- **UI**: Looks panel under the Overlays inspector tab. Save current per-Screen settings as a new Look; recall an existing one via dropdown or hotkey.
- **OSC**: `/sp/look/recall name` (already in the surface; needs the host interceptor wired up in `ShowController`).

## Open product questions

1. **Profile / Look — per-project or per-machine?**
   - **A — Per-project, lives in the bundle.** Pro: operator carries the profile with the show. Con: a show authored on a 2-display laptop carries laptop bindings into a 6-DeckLink venue rig.
   - **B — Per-machine, separate from project.** Pro: machine-local truth survives moving a show. Con: no way to author "the venue I always use" alongside the show file itself.
   - **C — Both: project carries default profiles, machine overrides.** Most flexible; matches what the v1 schema-only `OutputBindingProfile` already implies.
   - **My recommendation**: C. Project carries an array of named profiles (the show author's intent); the machine remembers which one is active locally + can override individual bindings (as the rig in front of the operator).

2. **Look recall semantics — instant or fadeable?**
   - **A — Instant**: flip overlays / color settings on the next frame.
   - **B — Crossfade (default 0.5 s)**: gamma-aware crossfade between Looks (mirrors B13 spec language).
   - **C — Per-Look configurable**: each Look stores its own recall fade duration.
   - **My recommendation**: B as the default with C available — the recall hotkey is "I want the show to look different *now*" but a hard cut on overlays is jarring.

3. **Hotkey scheme.**
   - **A — Function keys**: F5..F12 bind to Looks 1..8.
   - **B — `Cmd-1..9`**: maps to Looks; conflicts with cue-number jump.
   - **C — Cmd-Shift-1..9**: free; mnemonic.
   - **D — No default hotkey**, recall via toolbar dropdown or OSC only.
   - **My recommendation**: D as the default with operator opt-in via the rebindable hotkey scheme (spec §3.4).

4. **Active-profile drift detection.**
   When the operator manually edits a Screen binding while a profile is active, do we (a) warn that the profile is now dirty, (b) silently mark dirty + show a "Save changes to profile?" affordance, (c) immediately update the profile?
   - **My recommendation**: B. Operators don't always want to save; non-modal prompt lets them defer.

5. **Profile recall failure mode.**
   Recalling a profile that references a DeckLink no longer attached:
   - **A — Banner**: "Profile X expects 'UltraStudio Mini' — not detected. Falling back to operator-Mac window for that Screen."
   - **B — Hard error**: refuse to switch; keep current bindings.
   - **C — Silent fallback** to a software preview.
   - **My recommendation**: A. Spec §3.7 already establishes the "show diagnostic up front" pattern (REF banner, Output in use); this matches.

6. **Look + Output Profile interaction.**
   Are they coupled (recall a Look = recall an Output Profile too) or independent?
   - **My recommendation**: independent. Operator may want to flip overlays while the rig stays the same, or swap rigs without touching overlays. Two named lists, two recall verbs.

## Dependency map

- **`Services/OutputProfileStore.swift`** (new) — pure-logic CRUD over the `[OutputProfile]` array on `PlayoutProject`; manages `activeOutputProfileID`; emits a recall delta that the host applies via `TransportSinkRouter`.
- **`Services/LookStore.swift`** (new) — same shape for `[Look]`; emits a recall delta that the host applies via `PlaybackController.compositorOverlays` / per-Screen color settings.
- **`Models/OutputProfile.swift`** (new) — Codable struct.
- **`Models/Look.swift`** (new) — Codable struct.
- **`Models/PlayoutProject.swift`** — adds `outputProfiles: [OutputProfile]`, `activeOutputProfileID: UUID?`, `looks: [Look]`, `activeLookID: UUID?`. Decode-if-present for legacy projects (default to single auto-generated profile + no Looks).
- **`Views/OutputInspectorView.swift`** — profile picker top-of-pane, "Save as new" menu.
- **`Views/OverlaysInspectorView.swift`** — Looks panel.
- **`ShowController.swift`** — host-interceptor wiring for `.lookRecall(name:)` (currently ack-only) reaches into `LookStore.recall(name:)`.
- **`ShowControlDispatcher`** — `.lookRecall` already in the action set; no schema change.

## Suggested first-slice (5-7 commits)

1. **`Models/OutputProfile.swift` + `Models/Look.swift` + `PlayoutProject` extensions** (1 commit, ~150 LOC + 80 LOC tests). Codable round-trip + decode-if-present for legacy.
2. **`OutputProfileStore` pure-logic** (1 commit, ~120 LOC + 100 LOC tests). CRUD + recall delta computation.
3. **`LookStore` pure-logic** (1 commit, ~120 LOC + 100 LOC tests).
4. **Output inspector profile picker UI** (1 commit, ~150 LOC). Picker, "Save as new", drift detection (Q4-B).
5. **Looks panel under Overlays inspector** (1 commit, ~150 LOC). List, recall, save current.
6. **Recall wiring** (1 commit, ~120 LOC). `ShowController` interceptor for `.lookRecall`; `OutputProfileStore.applyDelta` reaches into `TransportSinkRouter`; failure-fallback banner (Q5-A).
7. **Crossfade transition for Look recall** (1 commit, ~80 LOC). Gamma-aware crossfade between current and target compositor overlays (mirrors B13 language).

## Risks / unknowns

- **Output Profile recall and a running show.** Switching DeckLink bindings while a cue is running drops the in-flight frame. Spec §3.7 implies "explicit at start, mid-show change requires re-arm" (matches B7 language). Make recall a mid-show op only when no cue is running, or surface a confirmation.
- **Look crossfade math.** `CompositorOverlays` overlay images and message text don't have a defined linear interpolation; per-pixel crossfade is feasible but expensive at 4K. Constrain the crossfade to opacity / colors of the existing overlays during transition rather than rebuilding the composite.
- **Drift-marking race.** If an operator edits a binding while a recall delta is in flight, the dirty-mark and the delta race. Serialise on the same queue as `OutputProfileStore.recall`.

## When to revisit

- Operators ask for keyboard-recall hotkeys → ship Q3-A or B as the default.
- LED-wall venues need a "rehearsal Look" with darker overlays + a "show Look" with primary overlays → already covered by independent recall (Q6).
- Director View (E9) needs to read the active Look name → expose `LookStore.activeLook` as `@Published`.

## Estimated effort

5-7 commits, ~890-1080 LOC + ~280-360 LOC tests. Most of the surface is data + store; the UI deltas are small and reuse existing inspector chrome.
