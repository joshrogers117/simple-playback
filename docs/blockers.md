# Blockers

Anything in this file with a status of `open` halts the autonomous loop. The user resolves them by editing this file (changing status to `resolved` and adding a `Resolution:` line) or by sending a follow-up message that addresses the blocker.

If this file is empty (only this header) the loop runs.

Format per entry:

```
## <title>

- **Status**: open | resolved
- **Filed**: <ISO timestamp>
- **What's blocked**: <task ID from progress.md, e.g. A4>
- **Background**: <one paragraph>
- **Options**:
  - **A**: <description> — pros, cons
  - **B**: <description> — pros, cons
- **My recommendation**: <which and why>
- **Need from you**: <one sentence>
- **Resolution** (filled by user): <choice + any notes>
```

---

## C11 cue-inspector filmstrip scrub UI — surface design

- **Status**: open
- **Filed**: 2026-05-08
- **What's blocked**: C11 final sub-task (C11-4 — scrub UI consumer in the cue inspector). Generator (C11-1), coordinator (C11-2), and import-time enqueue + cache directory (C11-3) all shipped; the cache populates at video import. The remaining piece is the UI that reads `<filmstripDir>/<slide.id>.png` and lets the operator scrub.
- **Background**: The filmstrip cache is a 6×4 grid (24 frames default) at 160×90 per cell, packed in a 960×360 PNG (~50 KB). The intended consumer is the cue inspector (`CueInspectorView` in `Views/RootView.swift`, currently lines 1177–1305) — for video cues, show the filmstrip below the "Asset" row + above the Continuation picker so the operator can preview where in the clip the take starts. Several operator-visible decisions need to land before the consumer can be built.
- **Options**:
  - **A**: **Static thumbnail strip** — render the 24 frames as a horizontal strip (auto-fit to inspector width). No drag interaction; just a visual reference. Pros: simple, no behavior surprise, fits any inspector width. Cons: doesn't help the operator pick a starting frame; doesn't justify the 24-frame extraction over a single poster (which C10 already provides).
  - **B**: **Drag-to-scrub thumbnail** — a single 160×90 thumbnail. Drag horizontally to scrub through the 24 frames; releasing pins the chosen one. Optionally: tapping the chosen frame sets `cue.inPoint` (per spec §3.5 "in/out points"). Pros: makes the filmstrip useful as a quick preview tool. Cons: needs a clear "what does releasing do" rule — does it set a new inspector preview frame, or modify the slide/cue? Also: no obvious affordance that says "drag me" without a label.
  - **C**: **Inline horizontal strip + click-to-set-inPoint** — render all 24 frames as a strip; clicking a frame sets the cue in-point (offset = frame index × duration / 24). Pros: most discoverable; the in-point integration is a real workflow win. Cons: requires wiring `cue.inPoint` (a future Phase A leftover; not currently used in the runtime — would expand C11's scope into the cue model).
- **My recommendation**: **Option A** for v1 ship — static, decorative-only, lowest-risk. The filmstrip cache populates the same way regardless, so a future upgrade to B or C can swap the consumer without re-doing the import path. Option C is the operator's preferred answer per spec intent but pulls cue.inPoint scoping in alongside.
- **Need from you**: Pick A / B / C, plus any guidance on inspector placement (below "Asset" row vs in a new "Preview" section) and on whether a regeneration affordance is needed when the cache file is missing (e.g., bundle moved across machines and Filmstrips/ wasn't bundled; today the cache is silent-missing and the import-time enqueue only fires on first import).
- **Resolution** (filled by user):
