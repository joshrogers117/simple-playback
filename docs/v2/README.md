# v2 Pre-Scope Index

Planning docs for v2 enablement candidates from `docs/spec/feature_spec.md` §4 and `docs/handoff.md`. Each doc captures: spec-text source, open product questions, dependency map, and a suggested first-slice. **None of the docs commit to scope or order** — they exist so a future planning round arrives at a clear go/no-go decision faster than starting from a cold spec read.

Filed: 2026-05-08, session 27. Doc-only deliverable; no code changes.

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

### Output / network

- **[NDI Full sender (B11)](ndi_full_sender.md)** — `NDITransportSink` plugged into the existing TransportSink router. SDK distribution decision is the precondition. 7-9 commits.

### Operational

- **[Bundle for Travel cross-host rehearsal](bundle_for_travel_cross_host.md)** — multi-machine rehearsal protocol + targeted fixes for cross-host bookmark / hostname / output-binding portability. 5-8 commits, mostly contingent on rehearsal findings.

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
```

No hard dependencies between candidates; the implicit ordering is **Brightness adapt → Director View → Saved Workspaces** if all three ship (each builds on the previous's window-management infra). The audio sub-phase is independent of the others but is the largest single piece of work; PowerPoint import is independent and second-largest.

---

## Highest-leverage candidates (one operator's read)

- **PowerPoint import** — directly unblocks operators who arrive at FOH with `.pptx` and no Office license. Highest "operator-visible immediately" value.
- **NDI Full sender** — unblocks every NDI-receiver workflow (ATEM ingest, Tricaster contribution, OBS, redundant feed). Highest infrastructure-multiplier value once the SDK distribution decision lands.
- **Audio sub-phase** — unblocks the projects that need real audio routing (multi-mix-bus shows, audio-only cues, background beds). High value but high cost; recommend treating each of C12 / C13 / C14 / C15 as a separate session sequence.

The remaining four (Director View / Saved Workspaces / Brightness adapt / Bundle cross-host) are quality-of-life polish for operators who already have v1 working — ship after the high-leverage candidates.

---

## What's deliberately not pre-scoped here

- **PowerPoint `.pptx` macros / VBA support** — out of scope at every horizon. Macro-driven rendering doesn't fit a deterministic playout engine.
- **Live captions** — v3 per spec §3.18.
- **HDR pipeline (HLG/PQ)** — v2 §4 item 19 explicitly waits on LED-wall vendor adoption.
- **MIDI Show Control / AppleScript dictionary / Watchout-class network-clustered display** — v2 §4 candidates lower in the priority stack; pre-scoping when one becomes near-term.

When one of these moves up the priority list, add a doc here and link from this index.
