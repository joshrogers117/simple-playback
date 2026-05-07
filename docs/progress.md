# Progress — Simple Playback v1 Autonomous Build

Living checklist. Sub-tasks marked `pending` / `in_progress` / `done` / `blocked`. I update this every iteration.

Source of truth for what's left: this file. Source of truth for *why* it's broken into these tasks: `docs/spec/feature_spec.md` §7. Source of truth for how I work: `docs/runbook.md`.

---

## Current state

- **Active phase**: A
- **Last commit**: A4c — Continuation timing
- **Branch**: `development`

---

## Phase A — Show runtime + UX scaffolding

- [x] A1: Convert `.splayback` to bundle format with `formatVersion` and read-flat / write-bundle migration
- [x] A2: Cue model — id (any non-empty string, case-insensitive uniqueness), continuation (hold/auto-continue/auto-follow), pre-wait, post-wait, notes
- [x] A3: Per-cue overrides — fade in/out, crossfade duration, hold-last-frame, loop, in/out points; defaults inherit from project
- [x] A4: Playhead + GO / PREV / PANIC / CLEAR / BLACKOUT semantics, with debounce
  - [x] A4a: ShowList struct (ordered cues, lookup by id/number, validation, playhead, mutation helpers)
  - [x] A4b: CueRuntime state machine — GO / PREV / PANIC / CLEAR / BLACKOUT with debounce
  - [x] A4c: Continuation timing — autoContinue (immediate chain) and autoFollow (postWait on cue-end)
- [ ] A5: Show List view alongside `SlideGridView`; drag-from-palette-to-list; per-cue inspector
- [ ] A6: Edit / Show Mode toggle in title bar; lockouts in Show Mode (no destructive shortcuts, no editing affordances, confirm-on-quit while live, modal-forbidden invariant)
- [ ] A7: Hotkey table (rebindable, local + global scope, printable export)
- [ ] A8: Single-output default; Preview/Program opt-in; color discipline (blue/red borders, PREVIEW/PROGRAM overlays, elapsed/remaining counters)
- [ ] A9: Status bar — outputs, dropped frames, cache, TC, log shortcut, render heartbeat dot
- [ ] A10: Per-cue notes field (visible on standing-by cue, not tooltip-only)
- [ ] A11: Show List integration tests (cue-runtime state machine, GO/PREV/PANIC behavior, debounce, continuation modes)
- [ ] A12: Project-bundle round-trip tests (read flat → write bundle → reopen → parity)
- [ ] A13: Phase A summary + manual rehearsal steps

## Phase B — Output pipeline rework

- [ ] B1: Stage abstraction (resolution, frame rate, color space, range)
- [ ] B2: Screen abstraction with typed roles (Program, Confidence, Multiviewer, Mirror, Auxiliary)
- [ ] B3: Transport binding layer — DeckLink, OS Display, NDI Full, Operator-Mac window
- [ ] B4: Per-machine local config mapping role → device (separate from project file)
- [ ] B5: Refactor `VideoOutput.swift` and `DeckLinkBridge` against the new abstraction
- [ ] B6: DeckLink REF input handling — surface lock state, refuse silent free-run when expected, warn on format mismatch
- [ ] B7: DeckLink format negotiation — explicit at start, mid-show change requires re-arm
- [ ] B8: 10-bit YUV 4:2:2 default when any clip in the project is >8-bit
- [ ] B9: "Output in use" detection + recovery path
- [ ] B10: Audio embed over SDI with channel-pair routing
- [ ] B11: NDI Full sender as a transport binding
- [ ] B12: Compositor — three layers (media, bug/logo, message/timer)
- [ ] B13: Color pipeline — per-Screen range/space; visible color chain in inspector; NCLC/ICC respect with overrides; gamma-aware crossfade
- [ ] B14: Frame-rate conformance warnings at clip-into-show time and pre-show
- [ ] B15: Hot-unplug handling (UltraStudio Thunderbolt)
- [ ] B16: Phase B summary + DeckLink mock layer for tests + manual rehearsal steps

## Phase C — Media pipeline

- [ ] C1: Codec inspector — long-GOP / VFR / 10-bit 4:2:0 / untagged color flags
- [ ] C2: Right-click "Transcode to ProRes 422" action; writes to project-relative `Transcoded/`
- [ ] C3: PDF import via PDFKit → bitmap-per-page at output × 2
- [ ] C4: Animated GIF / APNG detect → offer convert-to-ProRes-4444
- [ ] C5: Image-sequence detect (`name.0001.png`) → offer encode-to-ProRes-4444 via `AVAssetWriter`
- [ ] C6: Keynote import — AppleScript-driven `.key` → PDF → bitmaps; "Keynote not installed" diagnostic
- [ ] C7: Asset library — linked vs managed media; security-scoped bookmark + path + content hash + size + mtime
- [ ] C8: Folder-level bookmarks for batch imports
- [ ] C9: Missing-media UX — non-modal banner, per-clip Locate, project-level Relink folder, hash-based auto-relink
- [ ] C10: Embedded poster-frame thumbnails (palette loads with media offline)
- [ ] C11: Filmstrip thumbnail sprite-sheets (background queue)
- [ ] C12: Audio engine refactor — 48 kHz / 32-bit float, 8 internal channels, routing matrix
- [ ] C13: Audio cue types — embedded, audio-only cue, background bed
- [ ] C14: Per-cue audio: volume, mute, fade-in/out, crossfade override, varispeed with pitch correction
- [ ] C15: SRT/WebVTT subtitle sidecar render (subtitle layer in compositor)
- [ ] C16: Phase C summary + manual rehearsal steps

## Phase D — Show control

- [ ] D1: OSC server (UDP + TCP) on `/sp` with curated namespace
- [ ] D2: HTTP/JSON twin (`/api/v1/...`) mirroring every OSC address
- [ ] D3: WebSocket `/api/v1/events` for state push
- [ ] D4: OSCQuery server publishing namespace with type/range/value/description
- [ ] D5: Bonjour/mDNS discovery (`_simpleplayback._udp` + `_simpleplayback._tcp`)
- [ ] D6: Bearer-token auth + capability flags (`read` / `fire` / `edit`); Show-Mode capability stripping
- [ ] D7: Subscription state push at 10 Hz when subscribed
- [ ] D8: Per-cue feedbacks (running, standby, is-playhead, elapsed > X, remaining < X)
- [ ] D9: Per-cue variables + globals (cue_id, cue_name, playhead_id, tc_locked, tc_now, onair, …)
- [ ] D10: Ping/heartbeat (`/sp/ping` → `/sp/pong f uptime`)
- [ ] D11: Versioned API (`apiVersion` in every reply); idempotent action retrigger lockout (50 ms)
- [ ] D12: LTC chase via Core Audio input — engagement state machine, per-cue trigger/offset, drop-frame handling, jam-sync
- [ ] D13: MTC chase via Core MIDI input
- [ ] D14: Internal TC generator for rehearsal
- [ ] D15: Companion module (separate target / sibling repo decision logged)
- [ ] D16: Headless OSC client integration tests covering full action surface
- [ ] D17: Phase D summary + manual rehearsal steps

## Phase E — Reliability

- [ ] E1: Pre-show check panel — media, DeckLink, disk, macOS energy/DND/screensaver/Spotlight, audio device, render path warmed
- [ ] E2: "Fix" actions per pre-show row where automatable
- [ ] E3: Show log writer — append-only, persisted in bundle `Logs/`
- [ ] E4: Show log viewer with filtering (source, action type, time range)
- [ ] E5: Take history (recent 200) with replay scrub
- [ ] E6: Autosave every 30 s + checkpoint on Show-mode toggle
- [ ] E7: Crash recovery on next launch with "what changed" summary
- [ ] E8: Project lock file — warn on duplicate-open
- [ ] E9: Director View tear-off window (read-only, Program + next 3 + notes)
- [ ] E10: Saved Workspaces ("Edit", "Rehearsal", "Show", "Single Screen")
- [ ] E11: Brightness adapt key (booth dimming separate from system brightness)
- [ ] E12: Phase E summary + manual rehearsal steps

## Phase F — v2 enablement (likely stops here for review)

This phase is intentionally light — by spec §4 the v2 items are large enough that each deserves its own planning round. Phase F is the cleanup pass:

- [ ] F1: Code-reviewer subagent against the full v1 diff; act on P0/P1 findings
- [ ] F2: README.md update — feature list, screenshots, OSC API quickref, Companion install
- [ ] F3: docs/api.md — OSC + HTTP API reference for integrators
- [ ] F4: docs/manual_verification.md — consolidated list of every "needs hardware" verification step from phases A–E
- [ ] F5: Test fixture audit — every fixture committed has a script that regenerates it
- [ ] F6: Final phase summary + handoff document
