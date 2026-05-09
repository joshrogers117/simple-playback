# v2 Pre-Scope Index

Planning docs for v2 enablement candidates from `docs/spec/feature_spec.md` §4 and `docs/handoff.md`. Each doc captures: spec-text source, open product questions, dependency map, and a suggested first-slice. **None of the docs commit to scope or order** — they exist so a future planning round arrives at a clear go/no-go decision faster than starting from a cold spec read.

Filed: 2026-05-08, session 27. Doc-only deliverable; no code changes. **Session 28** (2026-05-08) added 6 more candidates from spec §4: Output Profile / Looks, MIDI Show Control, AppleScript dictionary, Group Cues, Post-Show Summary, Watched Drop Folder. **Session 29** (2026-05-08) began the first v2 sub-phase — Post-Show Summary pure-logic core + Markdown + CSV exporters shipped; see `post_show_summary.md` "Session 29 — what shipped" for the slice manifest.

---

## When to read these

- **Before starting a v2 sub-phase** — read the relevant doc, answer the open product questions, then plan the first-slice as a normal autonomous loop.
- **When prioritizing v2 scope** — read the "Estimated effort" + "Risks / unknowns" sections across docs to compare candidates.
- **When the spec evolves** — update the relevant doc's "Spec source" link and re-evaluate the open questions.

These docs are **not** the contract — `docs/spec/feature_spec.md` is. These are pre-decision aids.

---

## Candidates

### Operator-visible features

- **[PowerPoint import](powerpoint_import.md)** — `.pptx` rasterize-to-bitmaps via bundled LibreOffice or detect-installed-Office, mirroring the C6 Keynote shape. Operationally complex (license + binary distribution). 5-8 commits.
- **[Audio sub-phase (C12-C15)](audio_subphase.md)** — engine refactor (48 kHz / 32-bit float / 8 internal channels / routing matrix), audio cue types (audio-only, background bed), per-cue audio overrides, SRT/WebVTT subtitle render. Largest v2 candidate. 20-26 commits across four sub-phases.
- **[Director View (E9)](director_view.md)** — read-only Program + next 3 + notes second-display window. UX-design heavy; 5-7 commits.
- **[Saved Workspaces (E10)](saved_workspaces.md)** — Edit / Rehearsal / Show / Single Screen layout presets with hotkey switching. UX-design heavy; 5-7 commits.
- **[Brightness adapt key (E11)](brightness_adapt.md)** — booth dimming overlay separate from system brightness. Smallest v2 candidate; 3-4 commits.
- **[Group Cues](group_cues.md)** — `.startFirst` / `.startAll` / `.startRandom` / `.timeline` group fire modes. QLab-style abstraction; touches cue model, runtime, show list view, OSC. 6-9 commits.
- **[Watched Drop Folder](watched_drop_folder.md)** — content-runner workflow; new files in `Drop/` appear in palette as pending slides for operator approval. Builds on C8 folder-bookmark + C9 missing-media UX. 5-7 commits.

### Output / network

- **[NDI Full sender (B11)](ndi_full_sender.md)** — `NDITransportSink` plugged into the existing TransportSink router. SDK distribution decision is the precondition. 7-9 commits.
- **[Output Profile / Looks](output_profile_looks.md)** — named venue topology snapshots (Output Profile) + named per-Screen visual settings (Look) recallable via OSC. Builds on Phase B `OutputBindingProfile` schema. 5-7 commits.

### Integrator surface

- **[MIDI Show Control adapter](midi_show_control.md)** — inbound MSC SysEx → `ShowControlAction` translator, "thin layer over OSC" per spec §4. Lighting-console integration. 4-6 commits.
- **[AppleScript dictionary](applescript_dictionary.md)** — `.sdef`-defined macOS-native automation surface; show verbs as commands, cue / document classes as addressable objects. 5-7 commits.

### Operational

- **[Bundle for Travel cross-host rehearsal](bundle_for_travel_cross_host.md)** — multi-machine rehearsal protocol + targeted fixes for cross-host bookmark / hostname / output-binding portability. 5-8 commits, mostly contingent on rehearsal findings.
- **[Post-Show Summary Report](post_show_summary.md)** — reducer over the Show Log + Markdown / CSV exporters. Builds on E3 ShowLog + E5 TakeHistory. 5-7 commits. **First slice (sub-tasks 1-5) shipped session 29 — pure-logic core + Markdown + CSV exporters; sheet UI + system-event integration deferred.**

---

## Dependency map across candidates

```
[PowerPoint import]            independent
[NDI Full sender]              independent (uses existing TransportSink)
[Brightness adapt key]         independent (UI overlay only)
[Director View]                ↓ ShowListProjections (new helper, reusable)
[Saved Workspaces]             ↓ Director View tear-off lifecycle
[Audio sub-phase]              ↓ AVTrackLoader async migration (F1 P2 deferred)
                               ↓ enables OSC /sp/cue/{id}/audio/level wiring
[Bundle for Travel cross-host] ↓ optional: audio device fingerprinting
                                  (predicate on audio sub-phase shipping first)
[Output Profile / Looks]       ↓ B4 OutputBindingProfile schema (already in v1)
                               ↓ wires the OSC /sp/look/recall ack-only stub
[MIDI Show Control]            ↓ reuses Core MIDI client from D13 (MTC chase)
                               ↓ adds ShowControlSource.midi(...) attribution
[AppleScript dictionary]       ↓ reuses ShowControlDispatcher action surface
                               ↓ adds ShowControlSource.applescript(...) attribution
[Group Cues]                   ↓ touches Cue model + CueRuntime + Show List view
                               ↓ runtime concurrency interacts with compositor (B12)
[Post-Show Summary]            ↓ reads E3 ShowLog files
                               ↓ requires emitting `.cueEnded` + per-take latency events
[Watched Drop Folder]          ↓ reuses C8 folder bookmarks + MediaImporter
```

No hard dependencies between candidates. Implicit orderings:

- **Brightness adapt → Director View → Saved Workspaces** if all three ship (each builds on the previous's window-management infra).
- **MIDI Show Control + AppleScript dictionary** can ship in either order; both add a `ShowControlSource` case + dispatcher entry path with no shared infrastructure beyond the dispatcher itself.
- **Output Profile / Looks** unblocks `/sp/look/recall` from the v1 ack-only appendix.
- **Post-Show Summary** is gated on emitting `.cueEnded` and per-take latency events — small deltas to ShowController + the late-take detector.

The audio sub-phase is independent of the others but is the largest single piece of work; PowerPoint import is independent and second-largest. Group cues is third-largest by LOC + risk.

---

## Highest-leverage candidates (one operator's read)

- **PowerPoint import** — directly unblocks operators who arrive at FOH with `.pptx` and no Office license. Highest "operator-visible immediately" value.
- **NDI Full sender** — unblocks every NDI-receiver workflow (ATEM ingest, Tricaster contribution, OBS, redundant feed). Highest infrastructure-multiplier value once the SDK distribution decision lands.
- **Audio sub-phase** — unblocks the projects that need real audio routing (multi-mix-bus shows, audio-only cues, background beds). High value but high cost; recommend treating each of C12 / C13 / C14 / C15 as a separate session sequence.
- **Output Profile / Looks** — closes the loop on Phase B's schema-only `OutputBindingProfile` and ships the long-promised `/sp/look/recall`. Operators who run multiple venues (touring AV crews, multi-room corporate shows) ask for this directly.
- **MIDI Show Control + AppleScript dictionary** — both small (4-7 commits each) and unblock specific integrator audiences (lighting consoles for MSC, Mac-native automation scripts for AS). Ship together as an "integrator surface v2" cluster.

The remaining six (Director View / Saved Workspaces / Brightness adapt / Bundle cross-host / Group Cues / Post-Show Summary / Watched Drop Folder) split into two tiers:

- **Operator polish** (Director View / Saved Workspaces / Brightness adapt / Watched Drop Folder) — quality-of-life for v1-deployed operators.
- **Workflow extensions** (Group Cues / Post-Show Summary / Bundle cross-host) — net-new capability that some operators will love and others won't notice.

---

## What's deliberately not pre-scoped here

- **PowerPoint `.pptx` macros / VBA support** — out of scope at every horizon. Macro-driven rendering doesn't fit a deterministic playout engine.
- **Live captions** — v3 per spec §3.18.
- **HDR pipeline (HLG/PQ)** — v2 §4 item 19 explicitly waits on LED-wall vendor adoption.
- **Watchout-class network-clustered display engine** — explicitly listed as out of scope per spec §5.
- **Confidence / Stage screen role** with independent content (spec §4 #2) — partially covered by Director View; pre-scope as a separate candidate when it becomes near-term.
- **Tally inbound** (spec §4 #3) — narrow integrator audience; pre-scope when an operator asks.
- **Outbound network-cue mirroring** (spec §4 #6) — primary → secondary follow-mode for redundant playout machines; pre-scope when redundancy becomes a real operator requirement.
- **Edge blend + 4-corner warp** (spec §4 #8) — projection-blend territory; spec §5 lists "mesh warp / projection-mapping engine" as out of scope, edge-blend is the borderline case worth re-evaluating only when an operator explicitly asks.
- **Fill+Key UI-first-class output mode** (spec §4 #9) — paired-port wizard, hardware-bound; pre-scope alongside a real DeckLink-keyer rehearsal.
- **HAP / NotchLC / AV1 codec acceptance** (spec §4 #10, #11) — codec-pipeline extensions; pre-scope when an operator brings real-world media that requires them.
- **Hardware control surface mapper** (spec §4 #13) — Stream Deck / X-Keys / Loupedeck; the v1 Companion module covers the Stream Deck path. Pre-scope when operators ask for native (non-Companion) control surface support.
- **Browser remote read-only monitor** (spec §4 #15) — iPad confidence monitor; depends on the WebSocket subscription surface (D7).
- **Multiviewer as SDI / NDI output** (spec §4 #16) — beyond operator-Mac window; depends on how Director View v1 lands.
- **External watchdog process + auto-restart** (spec §4 #17) — reliability infra; pre-scope when an operator reports an unrecoverable mid-show crash.
- **Art-Net / sACN inbound** (spec §4 #20) — lighting-console parameter control; narrow audience.
- **GPI/GPO bridge over Ethernet** (spec §4 #21) — older-broadcast integration; pre-scope when an operator asks.

When one of these moves up the priority list, add a doc here and link from this index.
