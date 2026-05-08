# Companion Module Design — `bitfocus-companion-module-simpleplayback`

This document specifies the Bitfocus Companion module that drives Simple
Playback over OSC + OSCQuery + WebSocket. It is the contract a module
author follows — implementation is a 1–2 day project against the
[`companion-module-base`](https://github.com/bitfocus/companion-module-base)
template.

The module is **deferred from v1** as a deliverable artifact. The Swift
app side is feature-complete: every action listed here works against
the running app today via `/sp/...` OSC and `/api/v1/...` HTTP. The
JavaScript module just wraps those endpoints into Companion's
action/feedback/variable shape.

Status: design only. No JS code in this repo.

---

## Connection setup

Module config form (see `companion-module-base/wiki/Configuration`):

| Field | Type | Default | Purpose |
|---|---|---|---|
| `host` | text | `localhost` | OSC + HTTP host |
| `oscUDPPort` | number | `53000` | OSC UDP listen port on Simple Playback |
| `oscTCPPort` | number | `53000` | OSC TCP port (preferred for state subscription) |
| `httpPort` | number | `53001` | HTTP / OSCQuery / WebSocket port |
| `bearerToken` | text | (blank) | Optional auth token for `edit` actions |
| `transport` | dropdown | `tcp` | `udp` or `tcp` for outbound actions |
| `subscribeOnConnect` | checkbox | true | Auto-issue `/sp/subscribe` on init |

On `init`:
1. Open OSCQuery (`GET http://{host}:{httpPort}/?HOST_INFO`) to confirm
   the instance is alive and learn the `apiVersion`.
2. Open OSC TCP socket to `{host}:{oscTCPPort}`.
3. Open WebSocket to `ws://{host}:{httpPort}/api/v1/events`.
4. If `subscribeOnConnect`, send `/sp/subscribe s "{ourHost}:{ourPort}"`.
5. Pull initial cue list from `GET /api/v1/cues` and seed variable values.

On every `connected` event: refresh cue list. On `disconnected`: mark
all feedbacks dead, post `Cannot reach Simple Playback` to the module
log.

---

## Actions (outbound)

Every action in the table below maps directly to one OSC address. The
module's `doAction(actionId, params)` looks up the row and emits one
OSC message. For every action, the reply envelope (parsed from the
`/reply` OSC message or the HTTP 200 body) is recorded in the module's
log so debugging is one click away.

| Companion action ID | OSC address | Args | Description |
|---|---|---|---|
| `go` | `/sp/go` | (none) | GO playhead |
| `goCue` | `/sp/go` | `s cueId` | Jump and fire |
| `previous` | `/sp/prev` | (none) | Step playhead back |
| `panic` | `/sp/panic` | `f fade` | Soft fade-out everything |
| `clear` | `/sp/clear` | (none) | Hard cut + audio mute |
| `playhead` | `/sp/playhead` | `s cueId` | Move playhead, do not fire |
| `load` | `/sp/load` | `s cueId` | Async warm-up |
| `cuePlay` | `/sp/cue/{id}/play` | (none) | Fire this cue regardless of playhead |
| `cueStop` | `/sp/cue/{id}/stop` | `f fade` | Stop with default fade |
| `cueScrub` | `/sp/cue/{id}/scrub` | `f 0..1` | Seek normalized |
| `cueScrubSeconds` | `/sp/cue/{id}/scrub/seconds` | `f` | Seek absolute |
| `cueOpacity` | `/sp/cue/{id}/opacity` | `f 0..1` | |
| `cueAudioLevel` | `/sp/cue/{id}/audio/level` | `f dB` | |
| `cueLoop` | `/sp/cue/{id}/loop` | `i 0|1` | (edit cap) |
| `cueGoto` | `/sp/cue/{id}/goto` | `s nextId` | (edit cap) |
| `cuePreload` | `/sp/cue/{id}/preload` | (none) | Async warm-up |
| `cueNotes` | `/sp/cue/{id}/notes` | `s text` | (edit cap) |
| `outputFreeze` | `/sp/output/main/freeze` | `i 0|1` | |
| `outputBlackout` | `/sp/output/main/blackout` | `i 0|1` | |
| `lookRecall` | `/sp/look/{name}/recall` | (none) | (advanced-later) |
| `tcSource` | `/sp/timecode/source` | `s spec` | `ltc:input1`, `mtc:port`, `internal`, `off` |
| `tcEngaged` | `/sp/timecode/engaged` | `i 0|1` | |
| `tcOffset` | `/sp/timecode/offset` | `f seconds` | |
| `showMode` | `/sp/show_mode` | `i 0|1` | |

The cue ID drop-downs in the action editor are populated dynamically
from the OSCQuery namespace (`GET /sp/cue` returns the list of cue
nodes). Stale IDs are auto-pruned when the operator renumbers in the
app.

### Action presets

Pre-built presets shipped with the module:

| Preset | Action(s) | Default style |
|---|---|---|
| GO | `go` | green button, large white "GO" text |
| PREV | `previous` | yellow button, "←" |
| PANIC | `panic 0.5` | red button, "PANIC" |
| BLACK | `outputBlackout 1` | latching black, white text "BLACK" |
| Cue/N | `cuePlay {id}` per cue | one button per cue with title |

---

## Feedbacks (inbound — drive button color/text)

Feedbacks subscribe to either the WebSocket `/api/v1/events` stream or
the OSC subscription pushed at `/sp/state/...`. The module exposes the
following feedback types; each takes a cue ID parameter where
applicable.

| Feedback | Source address | Trigger |
|---|---|---|
| `cueRunning` | `/sp/state/cue/{id}/running` | `value` field == 1 |
| `cueStandby` | `/sp/state/cue/{id}/standby` | `value` field == 1 |
| `cueIsPlayhead` | `/sp/state/cue/{id}/is_playhead` | `value` field == 1 |
| `cueElapsedAtLeast` | `/sp/state/cue/{id}/elapsed` | param: seconds; trigger when `value >= seconds` |
| `cueRemainingAtMost` | `/sp/state/cue/{id}/remaining` | param: seconds; trigger when `value <= seconds` |
| `panicActive` | `/sp/state/globals` | `panic == true` |
| `blackoutActive` | `/sp/state/globals` | `blackout == true` |
| `tcLocked` | `/sp/state/globals` | `tc_locked == true` |
| `onAir` | `/sp/state/globals` | `onair == true` |
| `showModeActive` | `/sp/state/globals` | `show_mode == true` |

Each feedback exposes the standard Companion style overrides
(background, text, color, png) so an operator can colour their Stream
Deck buttons (running cue → red, standby → amber, idle → grey).

---

## Variables

Companion variables (`$(simpleplayback:variable_name)`) for use in
button text:

### Globals (one of each)

- `playhead_id` — cue number at the playhead (`"INTRO"`, `""` if past end)
- `playhead_name` — operator-visible cue title
- `next_id` — cue number after the playhead
- `tc_now` — current incoming TC string (`"01:23:45:00"`)
- `tc_locked` — `1` or `0`
- `onair` — `1` or `0`
- `panic` — `1` or `0`
- `blackout` — `1` or `0`
- `show_mode` — `1` or `0`
- `uptime` — seconds since the app started

### Per-cue (one of each, indexed by cue ID)

- `cue_<id>_id`
- `cue_<id>_name`
- `cue_<id>_state` — `idle` / `loaded` / `running` / `tail`
- `cue_<id>_elapsed` — float seconds
- `cue_<id>_remaining` — float seconds
- `cue_<id>_elapsed_string` — `HH:MM:SS.mmm`
- `cue_<id>_remaining_string` — `HH:MM:SS.mmm`

The module re-registers per-cue variables every time the cue list
changes (OSCQuery `?LISTEN` or WebSocket `/sp/state/cue/...` includes
new IDs).

---

## Error handling

- **OSC reply with `status: error`**: post the `error` field to the
  module log; flash the button orange for 250 ms.
- **HTTP 401 missing capability**: post a clear "edit denied — token
  is read+fire only" log line. Common when Show Mode strips edit.
- **Connection lost**: all feedbacks default to inactive; module status
  is `Disconnected`. Reconnect attempts every 5 s.
- **OSCQuery 404 on a cue**: the cue ID was renamed or deleted —
  remove the variable and feedback bindings, post a notice.

---

## Auto-fill

Module presets ship one auto-fill button: "Add buttons for every cue".
On click:
1. Fetch `/api/v1/cues`.
2. For each cue, create a button with `cuePlay` action and a
   `cueRunning` feedback that turns the button red while running.
3. Set the button label to `$(simpleplayback:cue_<id>_id)\n$(simpleplayback:cue_<id>_name)`.

This is the workflow Mitti and QLab modules use; it's the difference
between "module that exists" and "module operators actually use".

---

## Test plan

A minimal integration test (run on a Mac next to a running Simple
Playback instance):

1. Open Companion, add a Simple Playback connection at `localhost`.
2. Verify status reaches "Connected (apiVersion 1)" within 2 s.
3. Add a "GO" preset to a button. Press it — confirm the playhead
   advances in the app.
4. Add a `cueRunning(id="INTRO")` feedback to the same button. Fire
   `INTRO` from the app. Confirm the button turns red.
5. Drop the connection (kill the OSC socket). Confirm the feedback
   goes inactive within 5 s and the status flips to "Disconnected".

A live Stream Deck rehearsal is the only way to verify dim-booth
ergonomics. That step is in the Phase D summary.

---

## Repository layout (when the module is implemented)

```
companion-module-simpleplayback/
  package.json
  src/
    index.js            # main module entry
    actions.js          # action definitions (table above)
    feedbacks.js        # feedback definitions
    variables.js        # variable registration + update logic
    osc-client.js       # OSC + WebSocket transport
    oscquery-client.js  # cue list enumeration
  companion/
    HELP.md             # operator-facing help
    LICENSE
    manifest.json       # Bitfocus module manifest
  README.md
```

Submit as a PR against
[`bitfocus/companion-module-everything`](https://github.com/bitfocus/companion-bucket).
The Bitfocus core team typically reviews modules within a week.

---

## Sources

- Bitfocus Companion module-base wiki:
  <https://github.com/bitfocus/companion-module-base/wiki>
- Mitti Companion module (closest analogue):
  <https://github.com/bitfocus/companion-module-imimot-mitti>
- QLab Companion cookbook:
  <https://qlab.app/cookbook/more-advanced-companion/>
- Spec and research that grounded this design:
  - `docs/spec/feature_spec.md` §3.14
  - `docs/research/show_control.md` §6
