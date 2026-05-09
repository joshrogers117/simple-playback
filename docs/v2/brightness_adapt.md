# v2 Pre-Scope — Brightness Adapt Key (E11)

**Status**: pre-scope (planning only — no code).
**Filed**: 2026-05-08, session 27.
**Spec source**: `docs/spec/feature_spec.md` §3.15 ("Brightness adapt key for booth dimming separate from system brightness").
**Progress source**: `docs/progress.md` E11 ("Brightness adapt key (booth dimming separate from system brightness)") — pending; deferred per `docs/handoff.md` "v2 enablement candidates".

---

## Why v2, not v1

Booth dimming is a small feature with disproportionate UX questions. The implementation is a SwiftUI overlay (`Color.black.opacity(...)`) over the operator's main window with a hotkey that cycles dim levels — maybe 200 LOC. The questions are:

- **What's the default chord?** Operators' fingers are full of show-fire shortcuts (Space, Esc, B, Cmd-Shift-L, Cmd-1..9, etc.).
- **What's dimmed — operator window only, or also program output?** Spec says "separate from system brightness," which leaves both readings open.
- **How many dim levels — toggle, three-step, continuous?**

None of those have a defensible default without operator input. v1 deferred because the UX-design conversation hadn't happened.

## What "Brightness adapt key" means in v1+ terms

A booth-darkening overlay system:

- A **dim level** state (0% / 25% / 50% / 75%) controlling a SwiftUI `Color.black.opacity(level)` overlay over the operator's main window.
- **Independent of macOS system brightness**: the macOS display brightness controls the entire screen; this controls only Simple Playback's window. Allows the operator to leave the menu bar / Dock fully visible while Simple Playback dims.
- A **dedicated hotkey chord** that cycles or steps through levels.
- Persists across launches per machine (not per project — booth dimming is operator preference, not show content).
- **Excludes the program / preview tile content** by default — the operator needs to see what's on the program output even when the rest of the UI is dimmed.

## Open product questions

These need an operator-side answer before any code lands:

1. **Hotkey chord — what's the default?**
   The constraint: avoid every show-fire / Show Mode / numpad / project shortcut. Candidates:
   - **A — `Cmd-Shift-Period`** (like macOS Spotlight zoom-out). Free of conflicts; not very mnemonic.
   - **B — `F11` / `Shift-F11`** as up/down. Free of conflicts; F11 is a legacy "show desktop" key on Macs but rebindable.
   - **C — `Cmd-Shift-Up` / `Cmd-Shift-Down`** as up/down. Mnemonic but `Cmd-Up` is in some text-editing contexts.
   - **D — Dedicated brightness-up / brightness-down media keys** with `Cmd` modifier (avoids stealing the system's bare F1 / F2 keys). Mnemonic but requires `Cmd-F1 / Cmd-F2` which on some Macs is mapped to display-mirroring.
   - **My recommendation**: A as primary; document that operators can rebind via the existing hotkey scheme (which spec §3.4 promises is rebindable).

2. **Step pattern — toggle, three-step, four-step, continuous?**
   - **A — Toggle**: full-bright ↔ a single configurable dim level.
   - **B — Three-step**: 0% / 33% / 66% cycle.
   - **C — Four-step**: 0% / 25% / 50% / 75% cycle.
   - **D — Continuous**: hold-and-drag a dim slider.
   - **My recommendation**: C. Four steps gives enough range; cycle is simpler than continuous and doesn't need a slider UI.

3. **What's dimmed?**
   - **A — Whole operator window** including chrome. Dim is uniform.
   - **B — Operator window but the Program tile stays bright**. Operator must see program at full brightness regardless.
   - **C — Operator window but Program + Preview tiles stay bright**. Same logic, applied to both.
   - **My recommendation**: C. The dim is for the booth; the show content tiles stay readable. Implementation: SwiftUI overlay covers Main window but masks out the Preview/Program tile rectangles via `mask(...)` modifier.

4. **Does the dim apply to tear-off windows (Director View, Show Log, Take History)?**
   - **A — Yes, all top-level Simple Playback windows dim together.**
   - **B — Director View dims independently** (it may be on a different display with different ambient brightness).
   - **C — Director View doesn't dim; Show Log / Take History dim.**
   - **My recommendation**: A. Per-window dim adds UX complexity for a niche case; ship A, let operator preference inform v2.1 if needed.

5. **Program output — is the program output (DeckLink / NDI / OS Display) ever dimmed?**
   - **A — Never**. Program output is the ground truth; dimming it would mis-represent show content.
   - **B — Optional, per-Screen toggle**. Some venues want a "rehearsal mode" where program output dims with the operator window.
   - **My recommendation**: A. The "rehearsal dim" use case is solved by the project's BLACKOUT verb; brightness adapt is operator-side only.

6. **State persistence.**
   Dim level on quit:
   - **A — Persist** across launches (per-machine `UserDefaults`). Operator's last setting is restored.
   - **B — Reset** to 0 on every launch. Predictable, but annoying for operators who always want booth-dim.
   - **My recommendation**: A.

7. **Show Mode interaction.**
   - **A — Brightness adapt is independent of Show Mode.** Booth dim is not destructive; cycling levels mid-show is fine.
   - **B — Lock the chord in Show Mode.** "Don't change anything I'm not deliberately doing during the show" applies.
   - **My recommendation**: A. Booth-dim during a show is the actual use case.

## Dependency map

- **`Services/BrightnessAdapt.swift`** (new) — pure-logic state machine for dim level (0..3) with `cycle()` / `set(level:)`. Persists to `UserDefaults`.
- **`Views/BrightnessOverlay.swift`** (new) — SwiftUI overlay rendered in `RootView` over the entire content area, masking out Program + Preview tile rectangles. Reads dim level from `BrightnessAdapt`.
- **`Views/RootView.swift`** — adds the overlay layer on top of the existing content; bound to `BrightnessAdapt.level`.
- **Hotkey wiring in `RootView` or `SimplePlaybackApp`** — `.keyboardShortcut(...)` handler that calls `BrightnessAdapt.cycle()`.
- **Director View / Show Log / Take History windows** — same `BrightnessOverlay` rendered as a top-level layer. Single source-of-truth `BrightnessAdapt` instance shared across windows.
- **Tile masking** — Preview / Program tile views report their rectangles via `GeometryReader` and a shared `@Published` `programTileFrame: CGRect`; overlay applies a clear-mask cutout at that rect.

## Suggested first-slice (3-4 commits)

1. **`BrightnessAdapt` pure-logic state machine** (1 commit, ~80 LOC + 60 LOC tests).
   - Level enum (`.bright | .dim25 | .dim50 | .dim75`) + cycle() + set(level:).
   - Persists to `UserDefaults`; restored on init.
   - Test seam: injectable `defaults: UserDefaults` for in-memory testing.

2. **`BrightnessOverlay` SwiftUI view** (1 commit, ~120 LOC).
   - `Color.black.opacity(level.opacityValue)` covering the parent.
   - Optional `holes: [CGRect]` parameter for masking out tiles.
   - Animated transition (~150 ms ease-in-out) when level changes.

3. **RootView integration + hotkey** (1 commit, ~150 LOC).
   - Overlay wrapping the main content; reports Preview / Program tile rectangles via PreferenceKey.
   - `Cmd-Shift-Period` cycles level via `BrightnessAdapt.cycle()`.
   - Verify: cycle from 0 → 25 → 50 → 75 → 0 visibly dims the operator window while leaving Preview/Program tile content bright.

4. **Director View / tear-off integration** (1 commit, ~80 LOC).
   - Each tear-off window also wraps in `BrightnessOverlay` reading the same `BrightnessAdapt` instance.
   - Verify: cycling level dims all open Simple Playback windows simultaneously (Q4 Option A).

## Risks / unknowns

- **`Color.black.opacity(...)` over GPU video.** A SwiftUI overlay on top of a `MTKView`-backed Preview/Program tile may interact oddly with the Metal compositing path. Recommend masking out the tile rects (Q3 Option C) so the overlay never blends with GPU content.
- **Mask hole accuracy.** As tile rectangles change (resize, hide/show panels), the overlay's hole list needs to update. SwiftUI `PreferenceKey` is the standard pattern; small risk of frame lag (~1 frame).
- **Color discipline interaction.** Dim doesn't change the Preview/Program red border palette (per spec §3.3). The masking-out preserves it; but the rest of the chrome (status bar, palette, show list) does dim, which means the visual "REF EXPECTED" red banner from B6b also dims. That's acceptable — operators dimming the booth are accepting reduced visibility everywhere except the program tile.
- **Multi-monitor consistency.** A second monitor with Director View at full brightness and the main monitor at 50% dim is the right behaviour by Q4-A. Confirm before shipping.

## When to revisit

- Per-window dim becomes a real ask (Q4 Option B) → ship.
- Operators want a wider step range (eight steps?) → trivial extension; rebuild the enum.
- LED-wall venues want the program output to dim too (Q5 Option B) → ship as a per-Screen toggle.

## Estimated effort

3-4 commits, ~430-520 LOC + ~120-160 LOC tests. The smallest of the v2 candidates by far; the value is in resolving the UX questions before the code lands.
