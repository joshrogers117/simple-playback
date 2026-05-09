# Simple Playback

Simple Playback is a macOS playout app for professional video operators in corporate AV / broadcast / large-event environments. It runs cue-based show lists against Blackmagic DeckLink output (or a software preview), with PreShow integrity checks, an OSC / HTTP / WebSocket / OSCQuery show-control surface, and the kind of reliability guardrails (autosave, crash recovery, project lock file, dropped-frame counter, show log) you want when the curtain is up.

The v1 build is implemented and unit-tested. Hardware verification — SDI output, REF lock, LTC chase, real Companion / Stream Deck integration, real codec-inspector behaviour against operator-supplied media — still requires a rehearsal cycle on real gear; see `docs/manual_verification.md` for the consolidated checklist.

## v1 feature surface

**Show runtime (Phase A)**
- Cue model: any non-empty string id, continuation modes (hold / auto-continue / auto-follow), pre-wait, post-wait, per-cue notes
- Per-cue overrides: fade in/out, crossfade duration, hold-last-frame, loop, in/out points (project defaults inherited)
- Playhead + GO / PREV / PANIC / CLEAR / BLACKOUT with 50 ms retrigger debounce
- Show List view alongside the palette grid; drag-from-palette-to-list, per-cue inspector
- Edit / Show Mode toggle (⌘⇧L); hotkeys: Space = GO, Esc = Panic, ← = Previous, ⌘. = Clear
- `.splayback` projects round-trip as a bundle (`Show.json` + `Media/` + `Logs/` + `Cache/` + `Autosave/` + `.lock`); legacy flat-file projects migrate on first save

**Output pipeline (Phase B)**
- Typed Stage / Screen abstraction with role-aware Transport bindings (DeckLink, OS Display, NDI Full, Syphon, Operator-Mac window, file-record)
- Compositor with three layers (media, bug/logo, message/timer) and `{time_left}` countdown token
- DeckLink REF lock surfaced in the status bar; project-level "expects external reference" toggle drives an escalating banner when REF is unlocked
- 10-bit YUV 4:2:2 recommendation logic (info hint in the Output inspector when any clip in the project is >8-bit)
- Frame-rate conformance warning per cue when the clip's native rate differs from the active Stage (with 0.1 fps tolerance for the canonical fractional/integer pairs)

**Media pipeline (Phase C)**
- Codec inspector: long-GOP / VFR / 10-bit 4:2:0 / untagged-color / animated-image flags rendered as warning chips in the cue inspector
- Right-click → Transcode to ProRes 422 / 4444; non-modal progress strip in the palette
- PDF import via PDFKit (rasterize-on-import at Stage × 2)
- Keynote import via AppleScript-driven `.key` → PDF → bitmaps; non-modal "Keynote not installed" diagnostic
- Animated GIF / APNG detect + offer convert-to-ProRes-4444
- Image-sequence detect (`name.0001.png`) → encode-to-ProRes-4444 via `AVAssetWriter`; Add Folder… toolbar with per-sequence frame-rate picker
- Asset library (linked vs managed media; security-scoped bookmark + content hash + size + mtime); folder-level bookmarks for batch imports; missing-media banner with per-clip Locate, project-level Relink folder, and hash-based auto-relink
- Bundle for Travel — copy linked media into the project bundle for cross-host hand-off
- Embedded poster-frame thumbnails (palette renders even when media is offline)
- Filmstrip sprite-sheet generator (cue-inspector scrub UI consumer pending operator UX choice — see `docs/blockers.md`)

**Show control (Phase D)**
- OSC server (UDP + TCP) on `/sp/...` with curated namespace
- HTTP/JSON twin at `POST /api/v1/...` mirroring every OSC address
- WebSocket `GET /api/v1/events` for state push (10 Hz default)
- OSCQuery server at `GET /` publishing namespace with type/range/value/description
- Bonjour/mDNS discovery (`_simpleplayback._udp` + `_simpleplayback._tcp`)
- Bearer-token auth + capability flags (`read` / `fire` / `edit`); Show-Mode capability stripping
- LTC chase via Core Audio input (drop-frame, jam-sync), MTC chase via Core MIDI, internal TC generator for rehearsal
- Bitfocus Companion module — design doc only in `docs/phase_d/companion_module_design.md` (the JS module is a sibling-repo deliverable)

**Reliability (Phase E)**
- PreShow check panel with one-shot Fix actions (relink folder, open Sound preferences, reveal bundle in Finder, open Blackmagic Desktop Video Setup)
- Show log: per-action CSV writer at `<bundle>/Logs/<yyyy-MM-dd>.log` with viewer + filter UI (source / action / since)
- Dropped-frame counter (rolling 10s + cumulative) wired into the status bar and the show log
- Late-take detector — first composed frame for cue X reaching SDI vs GO timestamp; appends `.lateTake` events with latency
- Take history (in-memory circular buffer, viewer sheet)
- Autosave every 30 s + checkpoint on Show-Mode toggle; crash recovery banner with Restore / Discard
- Project lock file at `<bundle>/.lock` with banner on a foreign live lock

See [`docs/spec/feature_spec.md`](docs/spec/feature_spec.md) for the full v1 specification, and the per-phase summaries (`docs/phase_<a..f>_summary.md`) for what shipped and what's still hardware-bound.

## Show control quick reference

| Address                          | Cap   | Args / body              | Effect                                          |
|----------------------------------|-------|--------------------------|-------------------------------------------------|
| `/sp/go [target?]`               | fire  | optional cue number      | GO playhead (or jump to target)                 |
| `/sp/prev`                       | fire  | —                        | PREV playhead                                   |
| `/sp/panic [fade?]`              | fire  | optional fade seconds    | PANIC (fade everything to black)                |
| `/sp/clear`                      | fire  | —                        | CLEAR all                                       |
| `/sp/playhead <cueNumber>`       | fire  | string                   | Move playhead                                   |
| `/sp/load <cueNumber>`           | fire  | string                   | Mark cue loaded (preload)                       |
| `/sp/cue/<id>/play`              | fire  | —                        | Fire that cue                                   |
| `/sp/cue/<id>/stop [fade?]`      | fire  | optional fade seconds    | Stop cue (no-op when not running)               |
| `/sp/cue/<id>/scrub`             | fire  | float in [0,1]           | Scrub normalized                                |
| `/sp/cue/<id>/scrub/seconds`     | fire  | float seconds            | Scrub seconds                                   |
| `/sp/cue/<id>/opacity`           | fire  | float in [0,1]           | Cue opacity                                     |
| `/sp/cue/<id>/audio/level`       | fire  | float dB                 | Cue audio level                                 |
| `/sp/cue/<id>/in_point`          | edit  | float seconds            | Set in-point                                    |
| `/sp/cue/<id>/out_point`         | edit  | float seconds            | Set out-point                                   |
| `/sp/cue/<id>/loop`              | edit  | int (0/1)                | Toggle loop                                     |
| `/sp/cue/<id>/goto`              | edit  | next cue number          | Set continuation target                         |
| `/sp/cue/<id>/preload`           | fire  | —                        | Preload                                         |
| `/sp/cue/<id>/notes`             | edit  | string                   | Set notes                                       |
| `/sp/output/main/freeze`         | fire  | int (0/1)                | Freeze output                                   |
| `/sp/output/main/blackout`       | fire  | int (0/1)                | Blackout                                        |
| `/sp/look/<name>/recall`         | fire  | —                        | Recall a saved look                             |
| `/sp/timecode/source`            | fire  | string                   | Set TC source ("ltc:CoreAudio:0", "mtc:…", …)   |
| `/sp/timecode/engaged`           | fire  | int (0/1)                | Engage chase                                    |
| `/sp/timecode/offset`            | fire  | float seconds            | TC offset                                       |
| `/sp/show_mode`                  | fire  | int (0/1)                | Toggle Show Mode                                |
| `/sp/workspace/save`             | fire  | —                        | Save workspace (no-op until E10 lands)          |
| `/sp/workspace/reload`           | fire  | —                        | Reload workspace (no-op until E10 lands)        |
| `/sp/ping`                       | read  | —                        | Reply with `{ uptime }`                         |
| `/sp/subscribe`                  | read  | "host:port" or host, port| Add OSC UDP push subscriber                     |
| `/sp/unsubscribe`                | read  | same                     | Remove subscriber                               |

State reads (HTTP only):

| Route                   | Cap   | Returns                                                  |
|-------------------------|-------|----------------------------------------------------------|
| `GET /api/v1/state`     | read  | full state envelope (playhead, cues, timecode, flags)    |
| `GET /api/v1/cues`      | read  | flat cue list                                            |
| `GET /api/v1/cue/<id>`  | read  | one cue detail                                           |
| `GET /api/v1/events`    | read  | WebSocket upgrade — push state at 10 Hz                  |
| `GET /` (no `/api/v1/`) | read  | OSCQuery namespace (with `?HOST_INFO`, `?VALUE`)         |

Defaults — OSC on UDP+TCP `:53000`, HTTP+OSCQuery+WebSocket on `:53001`, localhost-bound. A default token with `read`+`fire` is seeded at start so localhost clients (Companion, TouchOSC) connect with no setup. Operators rotate via Settings.

Full reference with reply envelope shapes, capability semantics, and idempotency keying lives in [`docs/api.md`](docs/api.md).

## Companion module

The Bitfocus Companion v3 module is a sibling-repo deliverable; its design and the address coverage it ships against are documented in [`docs/phase_d/companion_module_design.md`](docs/phase_d/companion_module_design.md). Once published, install the module via Companion's module manager pointing at the repo, and Companion will discover live Simple Playback instances over Bonjour.

## Requirements

- macOS 26.0+ with Xcode installed
- Blackmagic Desktop Video runtime (for SDI output; the app runs without it for software-preview-only use)
- Blackmagic DeckLink SDK 16.0 copied into the repository root as:

```text
Blackmagic DeckLink SDK 16.0/
```

The SDK folder is intentionally not tracked in git. The project includes DeckLink headers from that local path.

## Build

```sh
xcodebuild -project "Simple Playback.xcodeproj" -scheme "Simple Playback" -destination 'platform=macOS' build
```

## Test

```sh
xcodebuild -project "Simple Playback.xcodeproj" -scheme "Simple Playback" -destination 'platform=macOS' test
```

## Manual verification

Hardware-bound verification steps (real DeckLink card, REF generator, OSC client, LTC generator, etc.) are consolidated in [`docs/manual_verification.md`](docs/manual_verification.md). The doc tags each step `[no-hw]` / `[hw]` / `[hw + REF gen]` / `[hw + receiver]` so a stock laptop can run the no-hw subset before promotion.

## Project format

`.splayback` documents are NSDocument bundles:

```text
MyShow.splayback/
  Show.json          # cue list, settings, security-scoped media bookmarks
  Media/             # managed media (Bundle for Travel target)
  Logs/              # per-day show logs (CSV)
  Cache/Renders/     # PDF / Keynote rasterizations
  Cache/Thumbnails/  # palette poster-frame thumbnails
  Cache/Filmstrips/  # 24-frame scrub sprites
  Autosave/          # autosave checkpoints
  Transcoded/        # ProRes outputs from Transcode action / Image Sequence encoder
  .lock              # active-document lock file
```

Legacy flat-file `.splayback` projects (single JSON) migrate to the bundle layout the next time the file is saved.

## Distribution

Release packaging, notarization, Sparkle updates, and GitHub Pages staging are documented in [Distribution/README.md](Distribution/README.md).

## Contributing

This is an autonomous-build project — work is tracked in `docs/progress.md`, decisions are logged in `docs/decision_log.md`, and stop-conditions live in `docs/blockers.md`. Read [`docs/runbook.md`](docs/runbook.md) before making changes.
