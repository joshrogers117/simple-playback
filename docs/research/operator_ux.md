# Operator UX, Workflow & Reliability — Research Report

Scope: how a corporate AV / broadcast / large-event operator actually drives a playback tool, and what Simple Playback should adopt, defer, or refuse. Other reports cover output/render, show-control wiring, and media import; this one stays in the operator's seat.

---

## 1. Reference apps and what they teach

### 1.1 PlaybackPro Plus (DT Videolabs) — the corporate-event archetype
- Built explicitly for "the corporate/industrial video portion of the industry"; the explicit design goal is that the least tech-aware staffer can run a show.
- **Hardware-color discipline**: Preview controls are blue, Program controls are red, Loop/Temp is yellow, Take is the big green double-wide button on the left, Kill is its red mirror on the right. Colors exist so operators "under fire and not really wanting to actually read a label" still hit the right button. (PLSN review.)
- **Preview/Program model** copied from production switchers: a clip is loaded into Preview, "Take" sends it to Program. When a Program clip ends, the next Preview clip auto-promotes.
- **Per-clip metadata travels with the take**: in/out points, fade in, fade out, levels, geometry attach to the clip and apply automatically when Taken.
- **End All (Esc)** is a global "fade everything to nothing" — audio + video together, distinct from Kill and from end-of-clip fade.
- **Goto 10/20/30** rehearsal markers that jump into a clip — small, easy, loved by ops doing cue-to-cues.
- **Dedicated PreFlight checklist**: a separate utility that audits OS conditions (display config, screen saver, energy saver, indexing, encryption, audio device, login items) before show. Treated as part of the product.
- Sources: <https://plsn.com/articles/road-tests/playbackpro-plus/>, <https://www.dtvideolabs.com/preflight/>, <https://www.dtvideolabs.com/user-guide-playbackproplus-x/>, <https://www.dtvideolabs.com/playbackpro-playbackpro-plus-controllers/>.

### 1.2 Mitti — the Mac cue-list archetype
- Single-window layout: cue list left, Cue Inspector right, Preview top-right, Playhead + waveform below. One screen, one mental model.
- **Hotkeys**: Spacebar = play/pause, Enter = play selected, Cmd-Enter = jump to selected without playing, ↑/↓ = move selection, Alt-↑/↓ = trigger previous/next, Cmd-U = expand/collapse cue, **Cmd-Esc = Panic**.
- **Panic is configurable**: "Fade out & Pause" or "Fade out & Rewind" — operator picks the post-panic state.
- Cues collapsed/expanded; default is per-show preference.
- Stream Deck integration is drag-and-drop. OSC port 51000 default.
- Sources: <https://imimot.com/help/mitti/cues/>, <https://imimot.com/help/mitti/getting-started/>, <https://imimot.com/help/mitti/external-controls/>.

### 1.3 QLab — the cue-list discipline reference
- **Spacebar = GO, Esc = Panic** are reserved. Panic fades and stops everything per a user-set Panic Duration.
- **Edit mode vs Show mode** is first-class. Show mode hides the inspector, removes the toolbar, enlarges the GO button on secondary windows. Acknowledged not as security but as accident prevention.
- **Minimum-time-between-GOs**: configurable debounce protecting keyboard, mouse, MIDI, OSC simultaneously. UI shows red border on GO during debounce.
- **Broken cues** render with a red X and tooltip; **Workspace Status window** has a Warnings tab listing every broken or non-breaking warning with "Inspect Cue" jump-to-source. QLab 5 splits warnings into "breaking" vs "non-breaking."
- **Cue numbers**: any string, must be unique. **Cue names**: any string, not unique, default to filename. Renaming cascades to dependent cues using default names.
- **Notes field** lives next to GO, shows standing-by cue's notes — searchable, formatted, supports emoji. Most-praised QLab feature for designer↔operator comms.
- **Multiple cue lists per workspace**: master list firing Start cues into Audio/Video/Light lists is a common pattern.
- **Bundle workspace** copies media into a folder for portability.
- Sources: <https://qlab.app/docs/v5/fundamentals/cues/>, <https://qlab.app/docs/v5/fundamentals/workspace/>, <https://qlab.app/docs/v5/fundamentals/workspace-settings/>, <https://qlab.app/docs/v5/tools/workspace-status-window/>, <https://qlab.app/docs/v5/general/keyboard-shortcuts/>, <https://qlab.app/release-notes/5.2/>.

### 1.4 ProPresenter — operator-view philosophy
- "Multi-View" so operator sees inputs and outputs simultaneously. Looks/Stage Display let operator preview a feed that is NOT what audience sees.
- Volunteer/operator guides are official content — recognition that operator is often the weakest link.
- Pattern lift for SP: separate "operator-only" status surface vs program output.
- Sources: <https://support.renewedvision.com/hc/en-us/articles/360041345954-Understanding-The-ProPresenter-User-Interface>, <https://www.renewedvision.com/blog/volunteer-operators-guide-to-propresenter-7>, <https://www.renewedvision.com/propresenter/stage-display>.

### 1.5 vMix — shortcut/preset patterns
- **Local vs Global Shortcuts**: shortcut binds to loaded preset (travels with show) or to global vMix settings (travels with operator). Both explicit.
- **Shortcut Templates**: importable/exportable, printable for FOH paper reference.
- Sources: <https://www.vmix.com/help25/ShortcutReference.html>, <https://www.vmix.com/help23/LocalGlobalShortcuts.html>, <https://www.vmix.com/help25/ShortcutTemplates.html>.

### 1.6 Renewed Vision PVP — UI adapts to complexity
- "If you have a more simple set up, say just a single screen, the UI adapts to your needs." Lift this principle: don't penalize the simple show with the complex show's chrome.
- Source: <https://renewedvision.com/provideoplayer/>.

### 1.7 Disguise / Watchout — high-end reference (light)
- Cue List as column-rich grid with timecode/MIDI/OSC tag columns; built for *long* shows with filtering.
- **Set List** concept: a curated subset of tracks the operator currently cares about, separate from the full asset pool. Same idea as a tonight-only playlist drawn from a library.
- Sources: <https://help.disguise.one/designer/timeline-tracks-transports/cue-list>, <https://help.disguise.one/designer/timeline-tracks-transports/set-list>, <https://docs.dataton.com/watchout-7/time/cue.html>.

### 1.8 Operator-forum signals
- ControlBooth playback-console threads: drag-and-drop config, single-screen workflows, M-series Macs, separate hardware video send. Operators dislike "complex rig from the start." (<https://www.controlbooth.com/threads/playback-console.50741/>.)
- AVFX best-practices: redundancy on every link, "never run a show on single points of failure," full simulated tech runs (not just clicker presses), back-up engineer trainable on the show. (<https://www.avfx.com/2025/04/event-production-best-practices/>.)

---

## 2. Specific question answers

### 2.1 Palette/grid vs cue-list — when each is right
- **Palette/grid** wins when each item is a self-contained take, show order is fluid, the operator responds to a director's call, most cells are stills or short videos. Corporate keynote / awards / sponsor reels.
- **Cue list** wins when order is largely fixed, cues have temporal dependencies (auto-follows, fade-and-stop chains), and rehearsal discipline matters (cue numbers spoken aloud).
- **They coexist.** QLab supports Cue Carts (a button grid). PlaybackPro has a Playlist alongside the palette. Right architecture: **palette is the asset surface; cue list is the show surface**. Drag from palette to list. Both visible at once.
- For SP specifically: SlideGridView is already a palette. The missing surface is an ordered, time-aware **Show List** that references palette items.

### 2.2 Preview/Program model
- **Preview/Program is the right default** for a single-screen operator with a large external program output. The corporate AV world expects it.
- "Arming" ≠ "taking." Visual contract:
  - Armed item highlighted **blue** with "PREVIEW" overlay.
  - Live item highlighted **red** with "PROGRAM" overlay, elapsed/remaining counters.
  - When Program ends, Preview promotes (operator-chosen behavior: hold last frame, black, or auto-Take next).
- Single-screen mode (no DeckLink output) collapses to "Take = play in software preview."

### 2.3 Show mode / lockouts / safety
- Adopt QLab's **Edit / Show mode** as a top-level toggle with an unmistakable title-bar indicator.
- In Show mode: inspector hidden by default; destructive shortcuts (Delete, Cmd-Z past a checkpoint, asset rename) disabled; palette drag-rearrange disabled; accidental drops silently ignored. Grid still selects/arms; list still GOes.
- **Confirm-on-quit** while a clip is on Program. Confirm-on-Cmd-W on the project window.
- **Minimum interval between GOs**: configurable, default 250 ms; visualize with a brief red ring on GO.
- Frame Show mode honestly: accident prevention, not security.

### 2.4 Hotkey conventions (defaults; user-rebindable)

| Action | Default | Rationale |
|---|---|---|
| GO / Take | **Spacebar** | QLab + Mitti |
| Panic / End All | **Esc** | QLab + PlaybackPro reserved |
| Hard Kill (no fade) | **Cmd-Esc** | Mitti's panic, repurposed |
| Blackout toggle | **B** | ATEM/vision-mixer convention |
| Preview next | **↓** | Mitti |
| Preview previous | **↑** | Mitti |
| Take selected | **Enter** | Mitti |
| Jump without taking | **Cmd-Enter** | Mitti |
| Pause/Resume Program | **K** | NLE JKL |
| Nudge ∓1s | **J / L** | NLE convention |
| Toggle Show mode | **Cmd-Shift-L** | "Lock" |
| Numpad 0–9 | Jump to cue/cell | Numpad has no other use |
| Cmd-1…9 | Switch active Show List | Mac tab convention |
| Toggle inspector | **Cmd-I** | QLab |

All bindings rebindable per-project (local) and per-user (global), per vMix's split. Provide a printable, exportable map.

### 2.5 Multi-window layout
Recommended primary surface (single laptop, 1440p+):

```
+--------------------------------------------------------------+
|  TITLE BAR  [EDIT / SHOW] toggle  | project name | clock     |
+----------------------+----------------+----------------------+
|  Palette / Grid      |   Show List    |   Inspector          |
|  (assets)            |   (cues)       |   (selected item)    |
+----------------------+----------------+----------------------+
|  PREVIEW (armed, blue)  |   PROGRAM (live, red, counters)    |
+----------------------+----------------------------------------+
|  STATUS BAR: output health, dropped frames, cache, log link  |
+--------------------------------------------------------------+
```

- Split: assets (left) → show (center) → details (right) → preview/program (bottom).
- Tear-off windows: Preview, Program, Show List, Status, **Operator/Director window** for second display. Save/restore named **Workspaces** ("Edit", "Rehearsal", "Show", "Tech Booth Single Screen").
- In single-screen mode (no DeckLink), Program in the bottom-right *is* the program; otherwise it's a software mirror of the DeckLink frame.

### 2.6 Project file UX
- **`.splayback` should be a macOS bundle**, not flat. Bundles are user-portable via Finder drag and naturally hold media, thumbnail cache, autosave history, recovery folder.
- **Two reference modes per asset**: link-by-path (default) or copy-into-bundle. Provide an explicit **"Collect / Bundle for Travel"** command (QLab's Bundle Workspace) that copies referenced media in and rewrites paths.
- **Missing media handling**: never crash, never silently drop. Mark cues with red-X, list in Warnings panel, surface a **Relink** dialog with fuzzy-match suggestions on open.
- **Recent projects** with thumbnails, separate from macOS recents, ranked by 30-day access frequency.
- **Autosave** every 30 s of edit activity to a sibling `Autosave/` inside the bundle, retain last 20, plus a checkpoint at every Show-mode toggle.
- **Crash recovery**: on launch after dirty exit, offer to restore last autosave with a "what changed" summary.
- **Project lock file**: warn if same `.splayback` is already open elsewhere (NAS-shared show files are common in corporate AV).

### 2.7 Reliability patterns
- **Pre-show check** modeled on PlaybackPro's PreFlight, built in:
  - Every cue's media exists, decodes, has thumbnail, has known duration, audio sample-rate matches output.
  - DeckLink device present, signal locked, format matches project.
  - Disk free space > N minutes of show.
  - macOS conditions: DND on, "never sleep" while plugged in, Time Machine paused, Spotlight not indexing media drive, screen saver disabled, automatic updates deferred, audio output device matches expectation.
  - Render path warmed: at least one frame pushed to each output.
  - Result: green/yellow/red panel with a "Fix" button per row.
- **Warm cache / preroll**: optionally preroll the next-armed clip's first ~2 s into GPU memory; show preroll status in Preview chrome.
- **Watchdog**: separate process monitors output heartbeat; on a hang, reports loudly (loud is good — silent hangs in dim booths are the worst failure). Optionally writes a minidump and graceful-restarts at the last-armed cue.
- **Panic / blackout / clear**:
  - **Esc** = soft panic (configurable fade, default 0.5 s, audio + video, leaves Program empty).
  - **Cmd-Esc** = hard kill (instant black, instant audio mute).
  - **B** = toggle blackout (latching; status bar shows BLACKOUT in red).
  - These hotkeys can never be broken, never reassigned without explicit override, never put behind a modal.
- **Two-finger confirmation** for destructive actions in Show mode.

### 2.8 Logging & post-show review
- **Show log** as a first-class window. Every GO, panic, dropped frame, late take, missing-media error, DeckLink signal event timestamped to wall-clock + SMPTE.
- Log persists in bundle `Logs/<showdate>.log`; rotated, plaintext, exportable as CSV.
- **Dropped-frame counter** in status bar with rolling 10-second window and per-clip totals; post-show summary highlights worst cue.
- **Take history** (recent 200) with replay-style scrub: "what cue fired at 14:32:18?"

### 2.9 Operator ergonomics on a single laptop in a dim venue
- **Default to dark theme** with #121212-class background, not pure black, to avoid halation against bright preview thumbs (NN/G + Smashing Mag dark-mode guidance).
- WCAG 4.5:1 minimum contrast on status text. Critical state (PROGRAM, BLACKOUT, ERROR) hits 7:1.
- **Color is never the only signal** — every red also has a label, every green also has a check icon. QLab 5.2 expanded its palette specifically for color-vision-deficient users.
- **Hit targets**: Take/GO/Panic ≥ 44 pt. Cue rows ≥ 32 pt high. Increase by 25 % in Show mode.
- **Status bar always-visible**: project name, current cue, elapsed/remaining, output state, dropped-frame count, log shortcut.
- **Brightness adapt**: one-key dim/undim of operator UI separately from system brightness, for booths where the laptop screen is also a venue light source.

### 2.10 Onboarding — the 10-minute mental model
PlaybackPro's reputation is "approachable." The model that fits in 10 minutes:
1. Drag media onto the palette → it appears.
2. Click a tile → it's armed in Preview (blue).
3. Hit Spacebar → it's live on Program (red).
4. Hit Esc → everything fades to black.
5. Drag tiles into Show List in order if you want a planned flow.
6. Toggle Edit/Show mode when the doors open.

If a feature can't be deferred without breaking those six steps, it goes in v1; otherwise v2+. PlaybackPro's success is largely that the demo *is* the product.

### 2.11 Hardware control surface mapping (on-screen UX only)
- The on-screen story for Stream Deck/X-Keys/Loupedeck is **drag a cue or action onto a virtual button grid that mirrors the device layout** (Mitti's pattern). Transport to the device is the show-control report's job.
- The mapper should:
  - Render the correct button count for the connected device (Companion's well-known gap; operators complain).
  - Show button labels exactly as they'll appear on the device.
  - Allow per-page assignments and a "show page" concept that travels with the project.
  - Print-export a paper layout (vMix Shortcut Templates pattern) for FOH reference.
- Bind an action, not a cue ID: "GO next in active Show List" survives editing better than "fire cue 17."

### 2.12 Multi-operator workflows
- Common roles: **director** (calling), **playback tech** (running SP), **content runner** (delivering files), **slides op**. Director rarely touches the laptop; SP must be one-person operable from one keyboard.
- Patterns to support:
  - Read-only **Director View** window: Program + next 3 cues + notes, opens on a second display, no controls. Lifted from QLab/ProPresenter.
  - **Note field per cue** (QLab's killer feature): director writes "wait for VO," operator sees it on the standing-by cue.
  - **Asset drop folder**: watched folder where the content runner drops files mid-show; SP imports + thumbnails into a "New" palette section without disturbing the active show.
- Out of scope (defer): real multi-user editing on the same project. Lock-on-open, last-writer-wins is plenty.

### 2.13 Anti-patterns to refuse
- **Modal dialogs that can appear during a show.** Modal license-warning, modal "you have unsaved changes," modal first-run welcome — none can ever steal focus while a clip is on Program.
- **Software updates that prompt at launch.** Defer all update checks until project closes.
- **Ambiguous next/now state.** Never let Preview and Program look similar. Always color, always label, always counter.
- **Auto-advance you can't see coming.** If a cue auto-fires the next, render a visible countdown.
- **Hidden destructive shortcuts.** Cmd-Backspace deleting a palette cell with no undo is a show-killer; Show mode disables it.
- **Nondeterministic transitions.** A 0.5 s crossfade must be 0.5 s every take; if it can't be (file not warm), surface as a warning.
- **"Helpful" auto-organize** that renames, moves, or renumbers without a user-visible diff.
- **Tooltips as critical UI.** If the only way to know a cue is broken is to hover, the cue isn't broken loudly enough.
- **Single global undo across edit + show actions.** Show actions (GO, panic, take) are not undoable; never let Cmd-Z look like it might unfire a cue.

### 2.14 Accessibility for tired ops at 2 a.m.
- Keyboard-only operability for every show-time action; mouse is convenience, not requirement.
- Large, *consistent* hit targets at *consistent* positions: GO is always bottom-right of the Show List, Panic always bottom-left, never moves.
- **Audible cue confirmation**: optional click on GO and a different click on Panic, routable to booth headset, off by default.
- VoiceOver labels on all transport controls.
- **Visible heartbeat**: a small pulsing dot in the status bar that proves the render thread is alive. If it freezes, the operator sees it before the audience does.

---

## 3. Concrete recommendations for Simple Playback

### 3.1 UI architecture (must-have, v1)
- Single primary window matching §2.5: Palette | Show List | Inspector across the top, Preview | Program across the bottom, persistent status bar.
- **Add a Show List view** as a peer to SlideGridView. References palette items, preserves order, supports per-cue notes and per-cue overrides (fade in/out, hold-last-frame). Grid is library; list is show.
- **Edit/Show mode toggle** in the title bar. Persist mode in the project; default Edit.
- **Saved Workspaces** ("Edit", "Rehearsal", "Show", "Single Screen") — window/panel layouts, not project content.
- Tear-off **Director View** (Program + next 3 + notes) for second display.
- Dark-by-default, WCAG-compliant, color + label + icon for every state.

### 3.2 Hotkey scheme (must-have, v1)
- The defaults table in §2.4. Make every binding rebindable.
- Local (project) keymap travels with `.splayback`.
- Global (user) keymap overlays.
- Export to printable PDF.

### 3.3 Show-mode safety affordances (must-have, v1)
- Edit/Show toggle.
- Confirm-on-quit while live.
- Disabled destructive shortcuts in Show mode.
- Configurable GO debounce with visible indicator.
- Esc / Cmd-Esc / B reserved and uninterruptible by modals.
- No modal dialogs may appear while Program is non-empty.

### 3.4 Reliability & diagnostics
v1:
- Pre-show check panel (media, DeckLink, disk, macOS energy/DND/screensaver/Spotlight).
- Missing-media red-X + relink dialog on open.
- Show log persisted in bundle.
- Status-bar dropped-frame counter and render heartbeat dot.
- Autosave every 30 s + on Show-mode toggle.
- Crash-recovery on next launch.

v2:
- External watchdog process.
- Warm-cache preroll for next-armed cue.
- Post-show summary report (CSV + human readable).
- "Bundle for Travel" command that collects + verifies media.

### 3.5 Project file UX (must-have, v1)
- Keep `.splayback` as a macOS bundle.
- Recent Projects with thumbnails.
- Asset references either linked or copied; explicit Bundle for Travel command.
- Lock file to warn on duplicate open.
- Autosave history retained inside the bundle.

### 3.6 Hardware-surface mapping (advanced-later, v2)
- Drag-and-drop virtual mapper that mirrors device button counts.
- Bind to actions, not cue IDs.
- Print-export the layout.
- Wire-up itself is the show-control report's territory.

### 3.7 Out of scope to keep simple
- Real-time multi-user editing.
- Worship-specific UI.
- In-app authoring of complex motion graphics (this is a *playback* tool).
- General-purpose timeline editing beyond per-cue in/out + fade.
- Generic plugin/scripting host.

---

## 4. Anti-patterns checklist (pin to the wall)
- No modal during a live take.
- No auto-update prompt at launch.
- No ambiguous Preview/Program color or position.
- No silent file rename / relocation.
- No critical info conveyed by tooltip alone.
- No single undo stack that mixes edit and show actions.
- No hidden destructive shortcut in Show mode.
- No nondeterministic transition without a visible warning.
- No "the operator should have read the manual" — every show-time control must be labeled, colored, sized for a tired person in the dark.

---

## Sources
- PlaybackPro Plus PLSN review — https://plsn.com/articles/road-tests/playbackpro-plus/
- PlaybackPro Plus X user guide — https://www.dtvideolabs.com/user-guide-playbackproplus-x/
- PlaybackPro Plus 40-key controller manual — https://www.dtvideolabs.com/resources/previous-versions/ControllerManual-40key-Legacy.pdf
- DT Videolabs PreFlight — https://www.dtvideolabs.com/preflight/
- Mitti Cues — https://imimot.com/help/mitti/cues/
- Mitti Getting Started — https://imimot.com/help/mitti/getting-started/
- Mitti External Controls — https://imimot.com/help/mitti/external-controls/
- Mitti Stream Deck plugin — https://imimot.com/blog/stream-deck-updates/
- QLab 5 Cues — https://qlab.app/docs/v5/fundamentals/cues/
- QLab 5 Cue Lists — https://qlab.app/docs/v5/fundamentals/cue-lists/
- QLab 5 Workspace — https://qlab.app/docs/v5/fundamentals/workspace/
- QLab 5 Workspace Settings — https://qlab.app/docs/v5/fundamentals/workspace-settings/
- QLab 5 Status Window — https://qlab.app/docs/v5/tools/workspace-status-window/
- QLab 5 Keyboard Shortcuts — https://qlab.app/docs/v5/general/keyboard-shortcuts/
- QLab 5.2 release notes — https://qlab.app/release-notes/5.2/
- Gareth Fry QLab troubleshooting — http://www.garethfry.co.uk/qlab-troubleshooting
- ProPresenter UI overview — https://support.renewedvision.com/hc/en-us/articles/360041345954-Understanding-The-ProPresenter-User-Interface
- ProPresenter Stage Display — https://www.renewedvision.com/propresenter/stage-display
- ProPresenter Volunteer Operator's Guide — https://www.renewedvision.com/blog/volunteer-operators-guide-to-propresenter-7
- vMix Shortcut Reference — https://www.vmix.com/help25/ShortcutReference.html
- vMix Local vs Global Shortcuts — https://www.vmix.com/help23/LocalGlobalShortcuts.html
- vMix Shortcut Templates — https://www.vmix.com/help25/ShortcutTemplates.html
- ProVideoPlayer (PVP) — https://renewedvision.com/provideoplayer/
- Disguise Cue List — https://help.disguise.one/designer/timeline-tracks-transports/cue-list
- Disguise Set List — https://help.disguise.one/designer/timeline-tracks-transports/set-list
- Watchout 7 Cue — https://docs.dataton.com/watchout-7/time/cue.html
- AVFX event production best practices — https://www.avfx.com/2025/04/event-production-best-practices/
- ControlBooth playback console thread — https://www.controlbooth.com/threads/playback-console.50741/
- Rocktzar QLab organization — https://www.rocktzar.com/qlab-organization-multiple-cue-lists-and-house-music/
- NN/G Dark Mode UX — https://www.nngroup.com/articles/dark-mode-users-issues/
- Smashing Magazine Inclusive Dark Mode — https://www.smashingmagazine.com/2025/04/inclusive-dark-mode-designing-accessible-dark-themes/
- macOS Bundle (Wikipedia) — https://en.wikipedia.org/wiki/Bundle_(macOS)
