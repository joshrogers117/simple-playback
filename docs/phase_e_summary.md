# Phase E — Reliability — Summary

**Status (session 12 — 2026-05-08)**: **Phase E started**. E1 (pre-show check panel) shipped end-to-end: pure-logic `PreShowCheck.evaluate(project:context:)` + sheet UI + toolbar "Pre-Show" button. Six rules wired (media resolution, FPS conformance, 10-bit recommendation, external-reference × DeckLink lock, disk space, audio device); two system-signal adapters (DeckLink lock state, audio device availability) are deferred to follow-up sessions because their adapters don't exist yet. 21 tests in `PreShowCheckTests`. The panel is read-only — E2 fix actions are deferred.

---

## What shipped in session 12 (E1 first slice)

### `Services/PreShowCheck.swift` — pure-logic evaluator

- **`PreShowCheck.evaluate(project:context:)`** — entry point. Returns an ordered `[Row]` (errors first → warnings → info → ok; title-tiebreak within severity). Each rule is its own `static func` so tests can drive each rule independently.
- **`PreShowCheck.Row { id, severity, title, summary }`** — operator-facing row. `id` is stable across runs ("media.resolution", "fps.conformance", "output.tenBit", "output.reference", "system.disk", "system.audio") so SwiftUI's diffing animates updates smoothly and so E2 can map fix actions per id.
- **`PreShowCheck.Severity { error, warning, info, ok }`** — sort-ordered. `Comparable` so callers can `.sorted` directly.
- **`PreShowCheck.Context`** — value type the host populates with system signals. Fields are optional; nil signals "host hasn't sampled yet" and the corresponding row is either suppressed or rendered as informational. Keeps the evaluator free of AppKit / IOKit / DeckLink imports — the rules stay unit-testable.

### Rules

| Rule | Severity logic | Notes |
|---|---|---|
| Media resolution | `.ok` when every cue's `assetID` is in `project.slides`; `.error` otherwise. Summary lists the first 3 missing cue numbers + count of remaining. | Most common pre-show breakage (media moved off external drive, deleted asset). |
| Frame-rate conformance | `.ok` when every video cue matches Stage rate (B14 evaluator with 0.1 fps tolerance); `.warning` on any mismatch; `.info` when no video cues present or only unknown rates; `.warning` when project has no Stage. | Reuses `FrameRateConformance` from B14 — same severity decisions as the cue-inspector chip but aggregated. |
| 10-bit recommendation | `.info` when `project.recommendsTenBitOutput` (B8); suppressed entirely when no 10-bit content present. | Pre-show panels degrade fast with noise rows — suppression is the right default. |
| External reference | `.ok` when expected + DeckLink reports `locked`; `.error` when expected + `unlocked` (matches B6b banner escalation); `.warning` when expected + `notSupported`; `.info` when expected + `notRequired` or status not yet sampled; suppressed when `expectsExternalReference` is false. | Cross-checks project intent vs live bridge state. |
| Disk space | `.ok` when `availableDiskBytes >= minimumDiskBytes` (default 5 GB); `.warning` otherwise. Suppressed when host has not sampled. | Host samples via `URLResourceValues.volumeAvailableCapacity`. |
| Audio device | `.ok` when host reports device available; `.error` when host reports false. Suppressed when host has not sampled. | Audio adapter not yet built — row is suppressed today. |

### `Views/PreShowCheckView.swift` — sheet

- Renders the row list with severity-coloured icons (`.error` red, `.warning` orange, `.info` yellow, `.ok` green) and matching translucent backgrounds. Title in subheadline-bold; summary in callout-secondary, fixed-vertical so multi-line summaries don't truncate.
- Empty-state: `ContentUnavailableView` with a checklist icon and a hint to add cues / arm output.
- Read-only — E2 will add per-row "Fix" buttons keyed off `Row.id`.

### `RootView` wiring

- Toolbar "Pre-Show" button (checklist icon) presents the sheet via `@State preShowCheckPresented`.
- `preShowCheckContext()` builds the `Context` synchronously: free disk space at `projectBundleURLProvider() ?? RootView.untitledRenderRoot` via `URLResourceValues.volumeAvailableCapacity`. DeckLink lock-state and audio-device fields stay nil this iteration — their adapters don't exist yet.

---

## Tests added (session 12 — E1)

| Test | What it covers |
|---|---|
| `PreShowCheckTests.testMediaRowOKWhenAllCuesResolve` | Happy path. |
| `PreShowCheckTests.testMediaRowErrorWhenCueAssetMissing` | Missing assetID → `.error`; cue number appears in summary. |
| `PreShowCheckTests.testMediaRowSummaryTruncatesAtThree` | "+N more" suffix when >3 cues missing. |
| `PreShowCheckTests.testFPSRowOKWhenAllVideosMatchStage` | `30` Stage + 30/29.97 cues → ok (both within fractional/integer tolerance). |
| `PreShowCheckTests.testFPSRowWarningWhenAnyVideoMismatches` | 60 Stage + 24 cue → warning, "AVFoundation will re-time" copy. |
| `PreShowCheckTests.testFPSRowInfoWhenNoVideoCues` | Image-only project → info, "No video cues to check". |
| `PreShowCheckTests.testFPSRowWarningWhenStageMissingFrameRate` | No stage → warning, id `stage.frameRate`. |
| `PreShowCheckTests.testTenBitRowSuppressedWhenNoTenBitContent` | nil row when no flag — pre-show panels degrade fast with noise. |
| `PreShowCheckTests.testTenBitRowInfoWhenAnyTenBitContentPresent` | Any video slide with `flags.tenBitYUV420` → info. |
| `PreShowCheckTests.testReferenceRowSuppressedWhenNotExpected` | `expectsExternalReference == false` → suppressed entirely. |
| `PreShowCheckTests.testReferenceRowOKWhenLocked` | Status `.locked` → ok. |
| `PreShowCheckTests.testReferenceRowErrorWhenExpectedButUnlocked` | Status `.unlocked` → error (matches B6b banner escalation). |
| `PreShowCheckTests.testReferenceRowWarningWhenDeckLinkDoesNotSupportLock` | Status `.notSupported` → warning. |
| `PreShowCheckTests.testReferenceRowInfoWhenLockNotYetSampled` | Status nil → info ("not yet sampled"). |
| `PreShowCheckTests.testDiskRowSuppressedWhenNoMeasurement` | Context.availableDiskBytes nil → suppressed. |
| `PreShowCheckTests.testDiskRowOKWhenAboveFloor` | 50 GB above 5 GB default floor → ok. |
| `PreShowCheckTests.testDiskRowWarningBelowFloor` | 1 GB below 5 GB → warning. |
| `PreShowCheckTests.testAudioRowSuppressedWhenNoMeasurement` | nil → suppressed. |
| `PreShowCheckTests.testAudioRowErrorWhenNoDevice` | false → error. |
| `PreShowCheckTests.testAudioRowOKWhenDevicePresent` | true → ok. |
| `PreShowCheckTests.testEvaluateSortsErrorsBeforeWarningsBeforeInfoBeforeOk` | Top-level sort invariant — error rows surface first. |

Total: 383 tests, all green (was 341 at session start; +42 across all session-12 work).

---

## Manual verification needed (E1 deltas)

1. With a fresh project (no slides, no cues), open Pre-Show. Panel renders three rows: media `.ok` ("All cues resolve"), fps `.warning` (no Stage), disk `.ok`/`.warning` depending on host. No reference row, no 10-bit row, no audio row (suppressed).
2. Add a 30 fps Stage, drop two video clips at 30 fps + 24 fps, build a Show List of two cues — one referencing each clip. Pre-Show shows fps `.warning` ("1 of 2 video cue(s) do not match Stage 30 fps").
3. Delete one of the source assets via the asset library. Pre-Show now also shows media `.error` listing the orphaned cue.
4. Toggle `expectsExternalReference` on the Output inspector. Pre-Show adds a reference row at `.info` severity ("not yet sampled"). With a DeckLink wired up and the bridge reporting `unlocked`, the row escalates to `.error` (matches the B6b status-bar banner). With `locked`, it drops to `.ok`. *DeckLink Context plumbing is not yet wired this session, so the row stays at `.info` until the adapter lands.*
5. Drop a 10-bit HEVC source into the project. Pre-Show adds the `output.tenBit` info row. Drop only 8-bit content into a fresh project — the row is suppressed entirely.
6. The Encode button on the Add Folder…  sheet shares the same disk-space concerns; if disk space drops below the floor mid-show, Pre-Show flags it next time the operator opens the panel.

---

## Still deferred (E1+)

- **DeckLink lock-state Context plumbing** — needs a small `PlaybackController` → `PreShowCheck.DeckLinkReferenceStatus` adapter that translates the existing bridge-reported state into the evaluator's enum. The B6 status-bar chip already reads the lock state — the same source can feed Pre-Show.
- **Audio-device Context plumbing** — needs a CoreAudio adapter that asks `kAudioHardwarePropertyDefaultOutputDevice` whether anything is connected. Cheap if nothing is plugged in — the OS reports a default device.
- **macOS energy / DND / screensaver / Spotlight checks** — each is a small `IOKit` / `NSWorkspace` / `NSUserNotification` query. Spec §7 lists them as separate rows. Each is independently testable.
- **Render-path-warmed signal** — operator-facing "the pipeline has rendered first frames since launch" check. The compositor / playback controller can flip a bool when first frame lands.
- **E2 — Fix actions per row** — every row whose cause is automatable gets a "Fix" button. Examples: relink missing media (file picker), free up disk (open Finder to project bundle), open Privacy & Security → Automation (already shipped on the import-banner; same deep-link can ride the audio/reference rows).
- **E3+ rest of Phase E** — show log writer, autosave, crash recovery, project lock file, Director View, saved Workspaces, brightness adapt key. Each item is independent.

---

## Recommended next pick

- **DeckLink lock-state adapter for Pre-Show** — small, tightens the existing E1 rule. Read the bridge state from PlaybackController (the OutputStatusBar already does this), translate to `PreShowCheck.DeckLinkReferenceStatus`, plumb into `preShowCheckContext()`. ~1 commit.
- **E2 fix actions for media + audio rows** — adds operator-actionable buttons to the highest-impact rows. Audio "Fix" deep-links to Sound preferences; media "Fix" opens a relink picker.
- **E3 (show log writer)** — independent, no UX questions, ships incrementally.

Phase B leftovers (B7, B11, B13, plus the full Phase B summary) and Phase C tail (C7+ asset library / audio engine / subtitles) remain as background work that can be picked off between Phase E iterations.
