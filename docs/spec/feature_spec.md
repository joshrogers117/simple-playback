# Simple Playback — Feature Spec

A consolidated spec for the next phase of Simple Playback, drawn from four research reports:

- `../research/output_pipeline.md` — Output, render, DeckLink, NDI, color, genlock
- `../research/show_control.md` — OSC, timecode, Companion, remote control
- `../research/media_pipeline.md` — Codecs, import, asset model, audio
- `../research/operator_ux.md` — UI, hotkeys, show mode, reliability

Read those for rationale and source citations. This document is the contract.

---

## 1. Audience and positioning

Target user: a professional video operator running a corporate event, conference keynote, broadcast preroll/playout, or large-screen / LED-wall driven show. Not a worship operator. Not a switcher operator. Not a live-camera mixer.

Positioning principle, restated in product terms: **Simple Playback is a deterministic playout engine.** It plays the right frame on the right output at the right time, takes that takes when you press space, and never surprises the operator at 7:58pm. It is not an authoring tool, not a switcher, not a graphics engine. The closest archetypes are PlaybackPro Plus (corporate-event ethos) and Mitti (Mac cue-list shape) — not ProPresenter, not Resolume, not vMix.

The discipline rule: every feature in v1 is reachable from the 10-minute mental model — drag, click, space, esc, drag-to-list, edit↔show. If it is not reachable from those six steps, it goes to v2 or out of scope.

---

## 2. Architectural shape

### 2.1 The five primary objects

```
Project (.splayback bundle)
  └── Show List(s)            ordered cue lists; each cue references an Asset
        └── Cue               id, type, asset ref, in/out/loop/fades, continuation, notes
  └── Asset Library           palette of imported items
        └── Asset             ProRes/H264/HEVC/PNG/JPG/PDF-page/PPT-page/Keynote-page/audio
  └── Compositor              renders to N Stages (≤ 3 layers: bug, media, message)
  └── Stages                  virtual rasters with color space, range, frame rate, resolution
  └── Screens                 typed roles (Program, Confidence, Multiviewer, Mirror, Aux)
        └── Transport         DeckLink port(s), OS Display, NDI sender, Syphon, Window
  └── Output Profile          named snapshot of (Screens + bindings + geometry); venue-portable
```

### 2.2 The two cardinal separations

1. **Show intent vs venue binding.** The `.splayback` file holds named Screens by role ("Program", "Confidence"); the per-machine local config maps roles to physical hardware. Same show file moves between venues; only the right column changes. (Output report §2, §12.)
2. **Stage vs Screen.** A Stage is the composition surface (one render); a Screen is a destination (one transport). Multiple Screens can mirror or warp from the same Stage. This is QLab's discipline. (Output report §1d, §16.)

### 2.3 The single canonical action vocabulary

Every action a local operator can take has exactly one named action. That action is reachable from:

- a hotkey,
- the OSC namespace (`/sp/...`),
- the HTTP/JSON API (`POST /api/v1/...`),
- a Companion-bound button.

If a UI button does not map to a named action, it is not shippable. (Show-control report §4.)

---

## 3. v1 feature spec — must-haves

### 3.1 Show runtime

QLab vocabulary, adopted verbatim where it doesn't conflict with the palette UI Simple Playback already has.

- **Show List**: ordered list of Cues. Multiple lists per project. Cue numbers are free-form unique strings; default to "1, 2, ..." but renameable to "INTRO", "Q2.5", etc.
- **Continuation per cue**: `hold` | `auto-continue` (overlap; fires next when *pre-wait* completes) | `auto-follow` (sequential; fires next when this cue ends).
- **Pre-wait / post-wait** floats per cue (seconds).
- **GO** = fire playhead cue, advance playhead. `GO <cueId>` = jump and fire.
- **PREV** = step playhead back, do not fire.
- **PANIC** = fade-out everything over a configurable duration (default 0.5 s). Soft.
- **CLEAR** (hard kill) = instant cut to black, instant audio mute. No fade.
- **BLACKOUT** = latching black on Program output, audio independent.
- **Standby state** per cue: `idle` | `loaded` (pre-rolled) | `running` | `tail` (in crossfade).
- **Per-cue notes** field (QLab's killer feature) — visible on the standing-by cue, never hidden behind a hover.
- **Per-cue overrides** for fade in/out, crossfade duration, hold-last-frame, loop, in/out points; defaults inherit from project.

### 3.2 Palette + Show List dual surface

- Palette / Grid (the existing `SlideGridView`) remains the **asset library surface**. Items are takes — cells, drag-droppable, color-coded by asset type.
- **Show List** is added as a peer view: the **show surface**. References palette items by ID, preserves order, holds per-cue overrides.
- Both visible simultaneously; drag from palette to list. The grid is a library; the list is the show.

### 3.3 Preview / Program model

- **Default mode: single-output.** When no DeckLink output is configured, software preview *is* the program output. Take-on-click semantics, no second playhead. This is the launch experience for users without SDI gear.
- **Preview/Program mode is opt-in.** Turns on automatically when a DeckLink output is configured, or manually via project setting. Color discipline:
  - Preview tile: blue border, "PREVIEW" overlay.
  - Program tile: red border, "PROGRAM" overlay, elapsed/remaining counters.
  - When Program ends, Preview promotes per project setting (hold-last-frame | black | auto-Take next).
- Pre-roll the armed Preview clip's first ~2 s to GPU; show preroll status in Preview chrome.

### 3.4 Hotkeys (rebindable; printable map)

| Action | Default | Notes |
|---|---|---|
| GO / Take | Space | Globally hijacked when Show List has focus or in Show Mode |
| Previous (re-arm) | ← | Step playhead back |
| Take selected | Enter | Fire highlighted cue |
| Jump without taking | Cmd-Enter | Move playhead only |
| Soft Panic (fade all) | Esc | Configurable fade time |
| Hard Kill | Cmd-Esc | Instant black + audio mute |
| Blackout toggle | B | Latching, status bar shows BLACKOUT |
| Toggle Show Mode | Cmd-Shift-L | Confirm dialog |
| Pause/Resume Program | K | NLE JKL |
| Nudge ∓1s | J / L | NLE JKL |
| Numpad 0–9 | Jump to cue | Direct numpad addressing |
| Cmd-1…9 | Switch active Show List | |
| Toggle inspector | Cmd-I | |

Bindings are rebindable. Two scopes: **local** (project-attached, travels with `.splayback`) and **global** (user-attached). Print/export to PDF for FOH paper. (Operator UX §2.4, Show-control §9.)

### 3.5 Show Mode (safety lockout — first-class)

A workspace-level toggle, prominent in the title bar.

In Show Mode:
- Inspector hidden by default.
- All editing affordances disabled (drag-reorder, delete, asset rename, cue retarget).
- Destructive shortcuts disabled (Delete, Cmd-Z past last Show-mode-toggle checkpoint, Cmd-Backspace).
- Drag-and-drop into Show List silently ignored.
- Confirm-on-quit and confirm-on-Cmd-W while Program is non-empty.
- Modal dialogs are forbidden — any system warning routes to the non-modal Warnings panel.
- Remote API tokens drop to `read+fire` capability; `edit` is denied.
- Configurable GO debounce (default 250 ms), with brief red ring on GO during debounce.

Framed as "accident prevention," not security. (Operator UX §2.3, Show-control §7.1.)

### 3.6 Output pipeline

- **Typed Screens** with role: Program | Confidence | Multiviewer | Mirror | Auxiliary. Named, persisted, venue-bindable.
- **Stage** per Screen (or shared) holds the canvas: resolution, frame rate, color space, range.
- **Compositor** with three layers in v1:
  1. **Media** layer — the active cue (existing).
  2. **Bug / logo** layer — persistent corner graphic that survives takes.
  3. **Message / timer** layer — countdown timers, name-supers.
- **Transport bindings** per Screen:
  - DeckLink device + connector(s)
  - OS Display
  - NDI Full sender
  - Syphon publish
  - Operator-Mac window (Multiviewer-role default)

### 3.7 DeckLink integration (the differentiator)

Build this hard:

- **Sub-channel allocation** — explicitly mirror Desktop Video Setup state; never assume "device = single port."
- **Format negotiation** — pick output mode at start; mid-show change is a stop+restart.
- **10-bit YUV 4:2:2** default once any clip in the project is >8-bit.
- **REF input handling** — surface lock state in OutputStatusBar (Locked / Free-run / REF mismatch). Refuse silent free-run when REF is expected; warn loudly on REF format mismatch.
- **Fill + Key** on supported devices (Duo 2, Quad 2, 4K Extreme/12G, 8K Pro, UltraStudio 4K family) as a first-class output mode, not a hidden setting. Two paired SDI cables.
- **Frame-rate conformance warnings** — flag any clip whose native rate ≠ Screen rate at clip-into-show time and again in pre-show check; never silently re-time.
- **"Output in use" recovery** — detect lock conflicts, surface holding process best-effort, offer release-on-relaunch.
- **Audio embed** over SDI default-on with explicit channel-pair routing.
- **HDMI on DeckLink** is shown in the DeckLink section of the binding UI, never in "Mac Displays."
- **Hot-unplug** of UltraStudio surfaces a clear "transport lost" state, never silently downgrades to graphics.

(Output report §3, §14.)

### 3.8 NDI Full output

NDI Full sender as a transport binding for any Screen. Configurable sender name. Use cases: ATEM ingest, Tricaster, OBS contribution, redundant feed to backup machine, multi-viewer feed. NDI HX is out of scope for v1. (Output §4a.)

### 3.9 Color pipeline

- Working space: **Rec.709**, limited range, BT.1886, 8-bit (default).
- Per-Screen overrides: range (limited 16–235 / full 0–255); color space (Rec.709 / sRGB / Display P3).
- Per-clip ICC / NCLC tag respected on decode; "untagged → treating as sRGB" warning surfaced in inspector with override.
- Gamma-aware crossfades (linear-light internally where feasible).
- **Visible color chain** in inspector: e.g., "Clip P3 full → Composite linear → Output Rec.709 limited." No silent conversions.
- Mac preview is approximate, not WYSIWYG; document that explicitly. SDI is the ground truth.

### 3.10 Media pipeline

**Codecs (v1):**
- ProRes 422 (LT/Proxy variants) — primary.
- ProRes 4444 — for alpha (lower thirds, animated logos).
- H.264 / HEVC in MP4/MOV — accepted, with long-GOP scrubbing warning.
- Stills: PNG, JPEG, TIFF, HEIF.
- Audio: WAV, AIFF, CAF, AAC; MP3 accepted with timing warning.

**Import paths (v1):**
- Direct media drop (security-scoped bookmarked).
- PDF — PDFKit rasterize-on-import at output × 2; one page = one slide.
- Keynote `.key` — AppleScript-driven Keynote → PDF → bitmaps. Surface a clear "Keynote not installed" diagnostic if absent.
- Animated GIF / APNG — detect → offer convert-to-ProRes-4444.
- Image sequence folder (`name.0001.png`) — detect → offer encode-to-ProRes-4444 via `AVAssetWriter`. Do not play sequences directly.

**Out of v1**: PowerPoint `.pptx` import — operators export to PDF first. Re-evaluate in v2 (see §4).

**Transcoding posture:** never silent. Inspector flags risky media:
- Long-GOP H.264/HEVC: "may not scrub frame-accurately"
- VFR: "will not loop seamlessly"
- 10-bit 4:2:0 HEVC: "limited hardware decode"
- Untagged color: "treating as sRGB"

Right-click "Transcode to ProRes 422" writes to project-relative `Transcoded/` folder.

(Media report §1, §2, §3, §4, §5.)

### 3.11 Audio model

- Engine: 48 kHz / 32-bit float internal.
- Channels: 8 internal in v1 (16 advanced-later).
- Cue types: per-clip embedded audio, audio-only cue, background bed.
- Per-cue, per-output: volume (dB), mute, fade-in/out, crossfade override, routing override.
- Pitch-corrected varispeed via `AVAudioUnitTimePitch`.
- Output devices: CoreAudio main, CoreAudio aggregate, DeckLink SDI embed (up to 16 ch HD).
- Routing matrix at project level: cue → internal channel → device channel.

(Media report §7.)

### 3.12 Show control & remote API

**OSC over UDP + TCP** as the primary surface. **HTTP/JSON twin** mirrors every OSC address; **WebSocket** at `/api/v1/events` for push state. **OSCQuery** server publishes the namespace at runtime with type/range/value/description.

**Namespace root**: `/sp` (avoids collision with QLab's `/cue`).

Action surface (curated; not every internal field):

```
/sp/go [s cueId]                fire playhead or named cue
/sp/prev                        step playhead back
/sp/panic [f fadeSeconds]       soft fade-out everything
/sp/clear                       hard cut + audio mute
/sp/playhead s cueId            move playhead, do not fire
/sp/load s cueId                async warm-up (decode + GPU upload)

/sp/cue/{id}/play
/sp/cue/{id}/stop [f fadeSeconds]
/sp/cue/{id}/scrub f 0..1
/sp/cue/{id}/scrub/seconds f
/sp/cue/{id}/opacity f 0..1
/sp/cue/{id}/audio/level f dB
/sp/cue/{id}/in_point f seconds
/sp/cue/{id}/out_point f seconds
/sp/cue/{id}/loop i 0|1
/sp/cue/{id}/goto s nextId
/sp/cue/{id}/preload
/sp/cue/{id}/notes s "..."

/sp/output/main/freeze i 0|1
/sp/output/main/blackout i 0|1
/sp/look/{name}/recall

/sp/timecode/source s "ltc:input1" | "off"
/sp/timecode/engaged i 0|1
/sp/timecode/offset f seconds

/sp/show_mode i 0|1
```

Reserved selectors mirror QLab: `/sp/cue/playhead/*`, `/sp/cue/selected/*`, `/sp/cue/active/*`. Wildcards: `/sp/cue/*/stop`.

**Reply envelope** (OSC and HTTP): `{"status":"ok","address":...,"data":...}`. Idempotent action retrigger lockout (50 ms default).

**Subscription** via `/sp/subscribe s "host:port"`: pushes `/sp/state/cue/{id}/standby|running|elapsed|remaining`, `/sp/state/playhead`, `/sp/state/timecode/{locked,now}`, `/sp/state/output/onair`.

**Auth**: bearer-token, per-token capability flags (`read` / `fire` / `edit`). Default token `read+fire`. Show Mode strips `edit`. Bind localhost-only by default; explicit opt-in to `0.0.0.0`.

**Discovery**: Bonjour/mDNS — `_simpleplayback._udp` (OSC), `_simpleplayback._tcp` (HTTP). Advertise version + OSCQuery URL + workspace name.

(Show-control report §4.)

### 3.13 Timecode chasing (LTC, MTC)

- Sources: LTC over any Core Audio input channel; MTC over any Core MIDI input; internal generator for rehearsal.
- Frame rates: 23.976 / 24 / 25 / 29.97DF / 29.97NDF / 30.
- **Engagement state machine** (operator-visible): `Off → Armed → Chasing → Free-wheeling → Lost`. Default Off (ProPresenter's "Not Engaged"). Freewheel window default 2 s, max 10 s.
- Per-cue TC trigger time, TC out time, per-cue and per-show offsets.
- Drop-frame stored as both string and absolute frame count; canonical compare is frame count.
- Jam-sync: switch to internal clock on TC drop; re-lock or snap on return based on ±frames threshold (default ±2).
- Status row: incoming TC, playhead TC, delta in ms, color-coded green/yellow/red.

(Show-control report §5.)

### 3.14 Companion-friendly integration

Ship a Companion module in-house. Make a community module a 1–2 day project. Requirements baked in:

- Stable cue IDs that survive reorder.
- OSCQuery namespace introspection.
- TCP transport for high-volume subscriptions.
- Per-cue feedbacks: running, standby, is-playhead, elapsed > X, remaining < X.
- Per-cue variables: `cue_id`, `cue_name`, `cue_remaining_string`, `cue_elapsed_string`, plus globals `playhead_id`, `playhead_name`, `next_id`, `tc_locked`, `tc_now`, `onair`.
- `/sp/ping` heartbeat with uptime.
- Versioned API (`apiVersion` in every reply).

(Show-control report §6.)

### 3.15 Operator UX

Single primary window:

```
+--------------------------------------------------------------+
|  TITLE BAR  [EDIT / SHOW] toggle  | project | clock          |
+----------------------+----------------+----------------------+
|  Palette / Grid      |   Show List    |   Inspector          |
|  (assets)            |   (cues)       |   (selected cue)     |
+----------------------+----------------+----------------------+
|  PREVIEW (blue)      |   PROGRAM (red) — elapsed / remaining |
+----------------------+----------------------------------------+
|  STATUS BAR: outputs · dropped frames · cache · TC · log     |
+--------------------------------------------------------------+
```

- **Tear-off windows**: Preview, Program, Show List, Status, Director View.
- **Director View** for a second display: read-only, Program + next 3 cues + per-cue notes. No controls. Multi-operator workflow.
- **Saved Workspaces**: "Edit", "Rehearsal", "Show", "Single Screen" — window/panel layouts, not project content.
- **Dark theme** default (#121212-class background; not pure black).
- WCAG 4.5:1 minimum contrast; 7:1 for critical state (PROGRAM, BLACKOUT, ERROR).
- **Color is never the only signal** — every red has a label, every green has a check icon.
- Take/GO/Panic ≥ 44 pt; cue rows ≥ 32 pt; +25 % in Show Mode.
- **Visible heartbeat** dot in status bar — proves render thread is alive.
- **Brightness adapt** key for booth dimming separate from system brightness.

(Operator UX §2.5, §2.9, §2.14.)

### 3.16 Reliability & diagnostics

**Pre-show check** (PreFlight-style panel) — must run green before doors open:

- Every cue's media exists, decodes, has thumbnail, has known duration.
- Audio sample-rate and channel count align with output config.
- DeckLink device present, signal locked, format matches project, REF lock state acceptable.
- Disk free space > N minutes of show.
- macOS conditions: DND on, never-sleep while plugged, Spotlight not indexing media drive, screen saver disabled, automatic updates deferred, Time Machine paused, audio output device matches expected.
- Render path warmed: at least one frame pushed to each output.
- Per-row green/yellow/red with a "Fix" button.

**Show log** as a first-class window:

- Append-only, persisted in project bundle `Logs/<showdate>.log`.
- Every GO, panic, dropped frame, late take, missing-media error, DeckLink signal event, OSC action.
- Source attribution: local hotkey vs OSC ip:port vs HTTP token vs TC trigger.
- Timestamp: wall-clock + chase TC.
- Plaintext, exportable as CSV.
- Take history (recent 200) with replay scrub.

**Status bar**:

- Project name, current cue, elapsed/remaining, dropped-frame counter (rolling 10 s + cumulative), TC state, output state, log shortcut.

**Autosave**: every 30 s of edit activity to bundle `Autosave/`, last 20 retained. Checkpoint on every Show-mode toggle. Crash recovery on next launch with "what changed" summary.

**Project lock file**: warn on duplicate-open of NAS-shared show files.

**Panic / Clear / Blackout**: reserved hotkeys, never broken by modals, never reassigned without explicit override.

(Operator UX §2.7, §2.8; Show-control §7.3.)

### 3.17 Project file model

`.splayback` becomes a **macOS bundle**:

```
MyShow.splayback/
  Show.json                   project schema (formatVersion N)
  Bookmarks/                  security-scoped bookmark blobs
  Cache/
    Thumbnails/               320×180 poster JPEGs per asset
    Filmstrips/               16-frame sprite-sheet PNGs
    Waveforms/                downsampled audio peaks
    Renders/                  PDF→PNG, PPT→PNG, Keynote→PNG slide caches
  Transcoded/                 ProRes-converted copies of risky media
  Autosave/                   rolling autosave snapshots
  Logs/                       per-show event logs
  Media/                      (only present in "Bundle for Travel" mode)
```

- **Two media modes per asset**: Linked (default — bookmark + path + content hash + size + mtime) or Managed (copied into `Media/`).
- **Bundle for Travel** command (QLab's "Bundle Workspace") collects + verifies all linked media into `Media/` and rewrites references.
- **Missing-media UX**: never crash, never silently drop. Resolution order: bookmark → last absolute path → hash search in project + adjacent `Media/` → name+size search → mark offline. Non-modal banner: "N media items offline — Relink…". Per-clip Locate; project-level Relink folder.
- **Embedded thumbnails**: palette loads instantly even with media offline.
- **`formatVersion` field**: loader supports N-1 and N-2; never silent rewrite-on-open; Save-as creates new version with migration log.

(Media report §10, §11; Operator UX §2.6.)

### 3.18 Subtitles / overlay captions

Per-clip SRT / WebVTT sidecar; rendered in compositor as subtitle layer with style template (font, size, position, drop-shadow). Per-output toggle (e.g., burn into stream output, suppress on stage screen). Live captions are v2.

---

## 4. v2 / advanced roadmap

Ordered roughly by leverage:

1. **Output Profile / Looks** — saved venue topology snapshots. Switch venue-A/B without editing show.
2. **Confidence / Stage screen role** with independent content (program clean vs program with timer/notes).
3. **Tally inbound** — ATEM tally + NDI tally to surface on-air state in UI; outbound tally-driven auto-play per cue.
4. **MIDI Show Control adapter** as a thin layer over OSC.
5. **AppleScript dictionary** for macOS-native automation.
6. **Outbound network-cue mirroring** (primary → secondary follow-mode); enables main+backup playout machines.
7. **Group cues** (start-first, start-all, start-random, timeline group).
8. **Edge blend + 4-corner warp** for projection blends.
9. **Fill+Key as UI-first-class output mode** with paired-port wizard.
10. **HAP / HAP-Q / HAP-Alpha** codec support; **NotchLC** import.
11. **AV1** acceptance on M3+.
12. **PowerPoint `.pptx` import** — bundled LibreOffice headless → PDF → bitmaps, or detect installed Office. Deferred from v1 to keep the install footprint small.
13. **Hardware control surface mapper** (Stream Deck / X-Keys / Loupedeck): drag-action onto virtual button grid that mirrors connected device, print-export the layout.
14. **Watched asset drop folder** for content-runner workflow during show.
15. **Browser remote read-only monitor** (iPad).
16. **Multiviewer as SDI/NDI output** (not just operator-Mac window).
17. **External watchdog process** + auto-restart at last-armed cue.
18. **Post-show summary report** (CSV + human readable).
19. **HDR pipeline** (HLG/PQ) — only when LED-wall vendor adoption is mainstream.
20. **Art-Net / sACN inbound** for parameter control by lighting console.
21. **GPI/GPO bridge** via Ethernet GPIO box wrapped over OSC/HTTP.

---

## 5. Out of scope (defended)

These are deliberately refused; expanding to them changes the product.

- **Worship / church-specific UI** (Bible, scripture, song lyrics, lyric editor, presentation song-set workflows).
- **Eight-layer ProPresenter-style compositor** (mask + props + announcements + …). Three layers is the cap.
- **Live-camera input / built-in switcher.** The downstream switcher does this. Adding it explodes the test matrix.
- **Per-layer color grading / FX rack / shader chains.** Resolume territory.
- **Mesh warp / projection-mapping engine.** Use Resolume Arena, MapMap, or HeavyM.
- **ST 2110 native.** Bridge boxes (Macnica, AJA, Matrox) handle this.
- **Network-clustered display engine** (Watchout/Disguise multi-machine canvas).
- **Built-in streaming encoder / SRT egress.** Use OBS or hardware encoder.
- **Audio routing matrix beyond per-clip channel-pair selection.** Channel matrix is enough; do not become a DAW.
- **Lua/JS scripting cues** (QLab's Script cue is a feature-creep magnet).
- **Native DMX-512 RS-485 output.** Route via Art-Net/sACN if needed.
- **MQTT / Pioneer Pro DJ Link / TSL 5.0.** Niche.
- **Real-time multi-user editing** of the same project. Lock-on-open + last-writer-wins.
- **In-app authoring of motion graphics / templates beyond simple text overlays.**
- **General-purpose timeline editing** beyond per-cue in/out + fade.
- **Generic plugin / scripting host.**
- **A web *editor*** (vs read-only monitor). Editing happens locally on the show machine.

---

## 6. Anti-patterns checklist (binding)

Pin these to the wall — every PR review should confirm none have crept in:

- No modal dialog while Program is non-empty.
- No software-update prompt at app launch.
- No ambiguous Preview/Program color, position, or label.
- No silent file rename, relocation, or transcode.
- No critical state conveyed by tooltip alone.
- No single undo stack mixing edit and show-fire actions.
- No hidden destructive shortcut in Show Mode.
- No nondeterministic transition without a visible warning.
- No silent format / color / range / frame-rate conversion.
- No "auto-detect best output" magic.
- No mirror-by-checkbox on each display (mirror is a Screen relationship).
- No "the operator should have read the manual" — every show-time control is labeled, colored, and sized for a tired person in a dim booth.
- No Cmd-Z that could appear to "unfire" a cue.
- No cue-id case-sensitivity (operators trip).
- No exposing every internal property over OSC — curated action verbs only.
- No GUI-only-actionable cues (must be reachable from OSC/HTTP for redundancy).

---

## 7. Implementation phasing — concrete order of work

Suggested sequence; each phase is independently shippable and operator-visible.

**Phase A — Show runtime + UX scaffolding**
1. Convert `.splayback` to bundle format with `formatVersion` and migration of existing flat-file projects.
2. Add Show List view alongside `SlideGridView`.
3. Implement cue model (id, continuation, pre/post-wait, notes, overrides).
4. Implement playhead + GO/PREV/PANIC/CLEAR/BLACKOUT semantics.
5. Wire hotkey table; add Edit/Show mode toggle and lockouts.
6. Ship Preview/Program color discipline + counters.
7. Ship status bar with heartbeat dot, dropped-frame counter.

**Phase B — Output pipeline rework**
1. Introduce Stage and Screen abstractions; serialize Screen-by-name.
2. Refactor `VideoOutput.swift` and `DeckLinkBridge` so Screen → Transport binding is explicit.
3. Add Transport types: DeckLink, OS Display, NDI Full, Operator-Mac window (Multiviewer).
4. Add Mac-local config layer mapping role → device.
5. Surface REF lock state, format negotiation, "output in use" recovery.
6. Add Bug and Message overlay layers in compositor.
7. Color pipeline: per-Screen range/space; visible color chain in inspector; NCLC/ICC respect with overrides.

**Phase C — Media pipeline**
1. PDF import via PDFKit → bitmap-per-page.
2. Animated GIF detect + ProRes 4444 conversion.
3. Image-sequence detect + ProRes 4444 encode.
4. Inspector flags for long-GOP / VFR / 10-bit 4:2:0 / untagged color.
5. "Transcode to ProRes 422" right-click action.
6. PowerPoint import via bundled/detected LibreOffice → PDF → bitmaps.
7. Keynote import via AppleScript → PDF → bitmaps.
8. Asset-relink workflow: hash search, locate, change-source-folder, "Bundle for Travel".

**Phase D — Show control**
1. OSC server (UDP+TCP) on `/sp` with curated namespace.
2. HTTP/JSON twin, WebSocket `/api/v1/events`.
3. OSCQuery namespace publishing.
4. Bonjour/mDNS discovery.
5. Bearer-token auth + capability flags; Show-Mode capability stripping.
6. Subscription state push at 10 Hz when subscribed.
7. Companion module (in-house repo).
8. LTC chase (Core Audio input) with engagement state machine; MTC chase.

**Phase E — Reliability**
1. Pre-show check panel.
2. Show log writer + viewer.
3. Autosave + crash recovery.
4. Project lock file.
5. Take history with scrub.
6. Director View (read-only second display).

**Phase F — v2 enablement**
- Output Profile / Looks; tally; group cues; warp/blend; HAP; etc., per §4.

---

## 8. Open questions / decisions for the user

These need user input before phase scheduling locks in:

1. **Existing project compatibility.** The current `.splayback` is a flat file with slide list, settings, security-scoped bookmarks. Bundle migration: read flat → write bundle on save? Read both formats indefinitely? Hard cutover at a major version?
2. **License + distribution model.** Sparkle updates already in place; should the in-house Companion module live in this repo or a sibling? Public API a marketing asset or a quiet enabler?
3. **Codec policy strictness.** Should v1 actually *block* import of formats that cannot be played reliably (DPX/EXR/DXV) or always accept-and-warn?
4. **Single-screen mode.** Default to Program/Preview always (with software preview standing in for Program when no DeckLink), or default to single-output and require explicit opt-in to Preview/Program?
5. **Cue ID syntax.** Strict QLab compatibility (any string), or restrict to alphanumeric+`.`+`-` for OSC-cleanliness?
6. **macOS minimum target.** PDFKit and AVFoundation features assumed here are stable; any version floor we should commit to (e.g., macOS 14+) for Apple-Silicon-first ProRes acceleration?
7. **Phase A vs B priority.** Show runtime work (A) is operator-visible immediately; output pipeline rework (B) is invisible until C lands. Ship A first or interleave?

---

## 9. Reference & rationale

This spec is the synthesis. Source citations and competitive analysis live in the four research reports under `docs/research/`. When in doubt about *why* a recommendation is what it is, read those — they pin every decision to a competitor reference, a protocol spec, or an operator-forum signal.
