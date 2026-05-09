# Simple Playback — Show Control API Reference (v1)

This is the integrator reference for Simple Playback's show-control surface. Three transports talk to the same dispatcher, the same idempotency lockout, and the same capability check; the address space is identical, and a Companion module / TouchOSC layout / custom ops integration only needs to pick which transport to speak.

- **OSC** over UDP and TCP — `:53000` by default
- **HTTP/JSON** — `POST /api/v1/...` and `GET /api/v1/state` etc., port `:53001`
- **WebSocket** — `GET /api/v1/events` on the same `:53001` port for state push
- **OSCQuery** — `GET /` on `:53001` for namespace introspection

All replies carry `apiVersion`. The current value is **1**. The version bumps when the address shape changes in a backward-incompatible way; reply data fields are additive between versions.

---

## 1. Transports and ports

| Transport      | Default port | Bind     | Use case                                    |
|----------------|--------------|----------|---------------------------------------------|
| OSC UDP        | 53000        | 127.0.0.1| Companion, TouchOSC, custom OSC clients     |
| OSC TCP        | 53000        | 127.0.0.1| OSC over reliable transport                 |
| HTTP/JSON twin | 53001        | 127.0.0.1| curl, browser tooling, custom integrators   |
| WebSocket push | 53001        | 127.0.0.1| Live subscribers (10 Hz state push)         |
| OSCQuery       | 53001        | 127.0.0.1| Namespace introspection (`HOST_INFO`, etc.) |

Localhost-only by default. Operators rotate ports / bind addresses via Settings (Phase E10 — the workspace surface — has not landed; today the ports are configurable by editing `ShowControlStack.Configuration` at the call site).

### Bonjour / mDNS

Two service types are advertised:

- `_simpleplayback._udp` (OSC UDP, port 53000)
- `_simpleplayback._tcp` (OSC TCP + HTTP + WebSocket + OSCQuery, port 53001)

TXT record:

| Key         | Value                                          |
|-------------|------------------------------------------------|
| `version`   | App version string (e.g. "1.0")                |
| `product`   | `simpleplayback`                               |
| `api`       | `v1`                                           |
| `oscquery`  | `http://localhost:<httpPort>`                  |
| `transport` | `osc-udp,osc-tcp,http,websocket,oscquery`      |
| `workspace` | (optional) workspace name                      |

---

## 2. Authentication

Bearer-token auth with three capabilities:

| Capability | Grants                                                                 |
|------------|------------------------------------------------------------------------|
| `read`     | State reads (`GET /api/v1/state`, `/cues`, `/cue/<id>`), `/sp/ping`, subscribe / unsubscribe |
| `fire`     | All show-runtime verbs (GO, PREV, PANIC, CLEAR, cue play / stop / scrub / opacity / audio level / preload, output freeze / blackout, look recall, timecode, show_mode) |
| `edit`     | Project mutations (cue in_point / out_point / loop / goto / notes)     |

A default token with `read`+`fire` is seeded at app start so a localhost Companion or TouchOSC client connects with no setup. Operators rotate via Settings.

**Show-Mode capability stripping** — when `showMode` is true, the dispatcher strips `edit` from every non-admin token's effective set. This means a leaked OSC client cannot mutate cue data while a show is live. `read` and `fire` are unaffected.

**Bearer token transport**:

- HTTP — `Authorization: Bearer <token>` header (preferred), or `?token=<token>` query parameter (for browser tooling).
- OSC — first argument can be `<token>:<message>` for transports that lack out-of-band metadata. Most clients run on a token-pinned channel set up at connect time.

### Reply codes

Every reply (OSC `/reply` or HTTP body) carries:

```json
{
  "apiVersion": 1,
  "address": "/sp/cue/Q1/play",
  "status": "ok",
  "data": { "fired": "Q1" }
}
```

or, on rejection:

```json
{
  "apiVersion": 1,
  "address": "/sp/cue/Q1/play",
  "status": "error",
  "error": "unknown_cue"
}
```

Standard reject reasons:

| `error` value                      | Meaning                                                       |
|------------------------------------|---------------------------------------------------------------|
| `missing_capability:read`          | Token lacks `read` capability                                 |
| `missing_capability:fire`          | Token lacks `fire` (typical "viewer" token)                   |
| `missing_capability:edit`          | Show Mode is on, or token never had `edit`                    |
| `retrigger_lockout`                | Action arrived within 50 ms of an identical previous one      |
| `no_runtime`                       | App started without a project loaded                          |
| `unknown_cue`                      | Cue number not in the active show list                        |
| `unknown_route`                    | (HTTP) `POST` path doesn't map to any action                  |
| `go_failed` / `play_failed`        | Runtime refused the GO (e.g. blackout active, panic state)    |
| `not_running`                      | Cue stop on a cue that wasn't running                         |

**Idempotency** — every action carries an `idempotencyKey` (per-cue verbs key by cue number; global verbs by name). Two actions with the same key arriving within 50 ms collapse to one — the second returns `retrigger_lockout`. This keeps a long-press Stream Deck button from double-firing GO.

---

## 3. Address surface

### 3.1 Show-runtime verbs

| OSC                              | HTTP                          | Cap   | Args / body                             | Effect / `data` reply                         |
|----------------------------------|-------------------------------|-------|------------------------------------------|-----------------------------------------------|
| `/sp/go [target?]`               | `POST /api/v1/go`             | fire  | `target?` string                         | Fire playhead (or jump to cue). `{ fired: "Q1" }` |
| `/sp/prev`                       | `POST /api/v1/prev`           | fire  | —                                        | Move playhead back. `{ playhead: "Q0" }`      |
| `/sp/panic [fade?]`              | `POST /api/v1/panic`          | fire  | `fade?` seconds                          | Fade everything to black. `{ fade: 0.5 }`     |
| `/sp/clear`                      | `POST /api/v1/clear`          | fire  | —                                        | Stop everything. `{}`                         |
| `/sp/playhead <cueNumber>`       | `POST /api/v1/playhead`       | fire  | `target` string                          | Move playhead. `{ playhead: "Q1" }`           |
| `/sp/load <cueNumber>`           | `POST /api/v1/load`           | fire  | `target` string                          | Mark cue loaded. `{ loaded: "Q1" }`           |

### 3.2 Per-cue verbs

| OSC                                  | HTTP                                       | Cap   | Args / body                  | Notes                                       |
|--------------------------------------|--------------------------------------------|-------|------------------------------|---------------------------------------------|
| `/sp/cue/<id>/play`                  | `POST /api/v1/cue/<id>/play`               | fire  | —                            | Equivalent to `/sp/go <id>`                 |
| `/sp/cue/<id>/stop [fade?]`          | `POST /api/v1/cue/<id>/stop`               | fire  | `fade?` seconds              | No-op when not running                      |
| `/sp/cue/<id>/scrub`                 | `POST /api/v1/cue/<id>/scrub`              | fire  | float in [0,1] / `position`  | Normalized scrub                            |
| `/sp/cue/<id>/scrub/seconds`         | `POST /api/v1/cue/<id>/scrub/seconds`      | fire  | float seconds / `seconds`    | Seconds-based scrub                         |
| `/sp/cue/<id>/opacity`               | `POST /api/v1/cue/<id>/opacity`            | fire  | float / `value`              | Cue opacity                                 |
| `/sp/cue/<id>/audio/level`           | `POST /api/v1/cue/<id>/audio/level`        | fire  | float dB / `dB`              | Cue audio level                             |
| `/sp/cue/<id>/in_point`              | `POST /api/v1/cue/<id>/in_point`           | edit  | float seconds / `seconds`    | Sets cue in-point                           |
| `/sp/cue/<id>/out_point`             | `POST /api/v1/cue/<id>/out_point`          | edit  | float seconds / `seconds`    | Sets cue out-point                          |
| `/sp/cue/<id>/loop`                  | `POST /api/v1/cue/<id>/loop`               | edit  | int 0/1 / `enabled` bool     | Toggle loop                                 |
| `/sp/cue/<id>/goto`                  | `POST /api/v1/cue/<id>/goto`               | edit  | string / `next` string       | Set continuation target (ack-only in v1)    |
| `/sp/cue/<id>/preload`               | `POST /api/v1/cue/<id>/preload`            | fire  | —                            | Mark loaded                                 |
| `/sp/cue/<id>/notes`                 | `POST /api/v1/cue/<id>/notes`              | edit  | string / `text`              | Set cue notes                               |

The cue id is the cue's display number from the Show List (case-insensitive uniqueness; arbitrary non-empty strings allowed). For OSC, characters that are illegal in OSC paths must be URL-encoded.

**Scrub / opacity / audio_level acknowledgement-only fields** — without an active host interceptor (the playback layer wired into the dispatcher), these reply `{ "applied": false }` to indicate the address was understood but no effect was produced. The hosted app wires the host interceptor at start; integrators should treat `applied: false` as "this address is reachable but the runtime ignored it" rather than as a hard error.

### 3.3 Output verbs

| OSC                              | HTTP                                       | Cap   | Args / body              |
|----------------------------------|--------------------------------------------|-------|--------------------------|
| `/sp/output/main/freeze`         | `POST /api/v1/output/main/freeze`          | fire  | int 0/1 / `enabled` bool |
| `/sp/output/main/blackout`       | `POST /api/v1/output/main/blackout`        | fire  | int 0/1 / `enabled` bool |
| `/sp/look/<name>/recall`         | `POST /api/v1/look/<name>/recall`          | fire  | —                        |

### 3.4 Timecode verbs

| OSC                              | HTTP                                       | Cap   | Args / body                  |
|----------------------------------|--------------------------------------------|-------|------------------------------|
| `/sp/timecode/source`            | `POST /api/v1/timecode/source`             | fire  | string / `source` string     |
| `/sp/timecode/engaged`           | `POST /api/v1/timecode/engaged`            | fire  | int 0/1 / `enabled` bool     |
| `/sp/timecode/offset`            | `POST /api/v1/timecode/offset`             | fire  | float seconds / `seconds`    |

Source spec strings:

| Spec                              | Means                                                       |
|-----------------------------------|-------------------------------------------------------------|
| `off`                             | Disengage all chase                                         |
| `ltc:CoreAudio:<deviceIndex>`     | LTC over Core Audio input device (`0` is default input)     |
| `mtc:<midiSourceName>`            | MTC from a Core MIDI source                                 |
| `internal:<fps>`                  | Internal generator (rehearsal mode)                         |

### 3.5 Workspace and session verbs

| OSC                              | HTTP                                       | Cap   | Notes                                   |
|----------------------------------|--------------------------------------------|-------|-----------------------------------------|
| `/sp/show_mode`                  | `POST /api/v1/show_mode`                   | fire  | int 0/1 / `enabled` bool                |
| `/sp/workspace/save`             | `POST /api/v1/workspace/save`              | fire  | Ack-only in v1 (E10 deferred)           |
| `/sp/workspace/reload`           | `POST /api/v1/workspace/reload`            | fire  | Ack-only in v1 (E10 deferred)           |

### 3.6 Diagnostic verbs

| OSC                              | HTTP                                       | Cap   | Notes                                   |
|----------------------------------|--------------------------------------------|-------|-----------------------------------------|
| `/sp/ping`                       | `POST /api/v1/ping`                        | read  | `{ uptime: <seconds> }`                 |
| `/sp/subscribe`                  | (use WebSocket instead — see §4)           | read  | Adds OSC UDP push subscriber             |
| `/sp/unsubscribe`                | —                                          | read  | Removes subscriber                       |

`/sp/subscribe` argument forms (OSC):

- One string: `host:port` (e.g. `192.168.1.10:9000`)
- Two args: string `host`, int `port`

---

## 4. State reads and push subscriptions

### 4.1 HTTP one-shot reads

| Route                            | Cap  | Returns                                                       |
|----------------------------------|------|---------------------------------------------------------------|
| `GET /api/v1/state`              | read | Full state envelope (see §4.4)                                |
| `GET /api/v1/cues`               | read | Flat cue list `{ data: { cues: [...] } }`                     |
| `GET /api/v1/cue/<id>`           | read | One cue detail `{ data: { cue: {...} } }`                     |

### 4.2 WebSocket push (recommended)

```
GET /api/v1/events
Upgrade: websocket
```

After the standard upgrade handshake, the server pushes one text frame per change at up to 10 Hz. Frames are JSON objects in the shape:

```json
{
  "apiVersion": 1,
  "address": "/sp/state/globals",
  "data": {
    "playhead_id": "Q1",
    "playhead_name": "Walk-in Loop",
    "next_id": "Q2",
    "tc_locked": false,
    "tc_now": "00:00:00:00",
    "onair": true,
    "panic": false,
    "blackout": false,
    "show_mode": false,
    "uptime": 423.7
  }
}
```

Per-cue frames:

```json
{
  "apiVersion": 1,
  "address": "/sp/state/cue/Q1",
  "data": {
    "cue_id": "Q1",
    "cue_name": "Walk-in Loop",
    "cue_state": "running",
    "running": true,
    "standby": false,
    "is_playhead": true,
    "elapsed": 12.345,
    "remaining": 47.655,
    "cue_elapsed_string": "00:00:12.345",
    "cue_remaining_string": "00:00:47.655"
  }
}
```

The pump is idle (zero CPU) when no subscriber is connected — operators often run shows with no remote rig at all and the app does not waste cycles on speculative pushes.

The pump also emits per-cue feedback addresses for Companion to subscribe to discretely:

- `/sp/state/cue/<id>/running` `{ value: 0|1 }`
- `/sp/state/cue/<id>/standby` `{ value: 0|1 }`
- `/sp/state/cue/<id>/is_playhead` `{ value: 0|1 }`
- `/sp/state/cue/<id>/elapsed` `{ value: <float> }`
- `/sp/state/cue/<id>/remaining` `{ value: <float> }`

WebSocket clients receive ping frames (opcode `0x9`) from the server periodically and respond with pong (`0xA`). Closing the connection cleanly with a close frame (`0x8`) deregisters the subscriber.

### 4.3 OSC UDP push subscription

`/sp/subscribe <host>:<port>` registers the OSC UDP subscriber; the same `/sp/state/...` payloads stream out as OSC messages with one string argument carrying the JSON body. Unsubscribe via `/sp/unsubscribe <host>:<port>` or by dropping the connection — the server reaps stale subscribers when it cannot deliver.

### 4.4 State envelope shape

```json
{
  "apiVersion": 1,
  "address": "/api/v1/state",
  "status": "ok",
  "data": {
    "playhead": "Q1",
    "playheadName": "Walk-in Loop",
    "blackout": false,
    "panic": false,
    "onAir": true,
    "showMode": false,
    "uptime": 423.7,
    "timecode": {
      "source": "ltc:CoreAudio:0",
      "engaged": true,
      "locked": true,
      "now": "01:02:03:14",
      "offset": 0
    },
    "cues": [
      {
        "id": "Q1",
        "name": "Walk-in Loop",
        "continuation": "auto-follow",
        "preWait": 0,
        "postWait": 0,
        "notes": "",
        "state": "running",
        "running": true,
        "standby": false,
        "isPlayhead": true,
        "elapsed": 12.345,
        "remaining": 47.655
      }
    ]
  }
}
```

---

## 5. OSCQuery

Companion v3 and TouchOSC discover the namespace via OSCQuery (proposed standard). Simple Playback implements the subset they actually use:

- `GET /` — root container
- `GET /<path>` — subtree at that path (e.g. `/sp`, `/sp/cue/Q1`)
- `?HOST_INFO` query selector — discovery handshake
- `?VALUE` query selector — return just the current value of a node

Each node carries `FULL_PATH`, `DESCRIPTION`, `ACCESS`, `TYPE`, `CONTENTS`, and (for value-bearing nodes) `RANGE` and `VALUE`. `/sp/cue/<id>` subtrees are enumerated dynamically from the live show list.

`HOST_INFO` extensions advertised:

```
ACCESS, VALUE, RANGE, DESCRIPTION, LISTEN, PATH_CHANGED — true
TAGS, EXTENDED_TYPE, UNIT, CRITICAL, CLIPMODE — false
```

---

## 6. Timecode chase

LTC, MTC, and an internal generator share a state machine: select a source via `/sp/timecode/source`, engage with `/sp/timecode/engaged 1`, optionally apply a per-show offset via `/sp/timecode/offset <seconds>`. The state push reports `tc_locked` once the chase has acquired stable input, and `tc_now` carries the formatted timestamp (`HH:MM:SS:FF`).

Per-cue trigger mappings live on the cue model (Cue ↔ TC trigger time). Hardware verification (real LTC generator + real DeckLink reference clock) remains in `docs/manual_verification.md`.

---

## 7. Idempotency keying

Every action's idempotency key is unique enough to collapse "this exact request fired twice in 50 ms" without collapsing semantically distinct requests:

| Action                                  | Key                                         |
|-----------------------------------------|---------------------------------------------|
| `go(target)`                            | `go:<target?? "<playhead>">`                |
| `previous` / `panic` / `clear`          | `previous` / `panic` / `clear`              |
| `playhead(num)` / `load(num)`           | `playhead:<num.lower>` / `load:<num.lower>` |
| `cue.play(num)` / `cue.stop(num)`       | `cue.play:<num.lower>` / `cue.stop:<num.lower>` |
| `cue.scrub.norm(num)` / `cue.scrub.seconds(num)` | `cue.scrub.norm:<num.lower>` / `cue.scrub.seconds:<num.lower>` |
| `output.freeze(b)` / `output.blackout(b)` | `output.freeze:<bool>` / `output.blackout:<bool>` |
| `look.recall(name)`                     | `look.recall:<name>`                        |
| `tc.source(spec)` / `tc.engaged(b)` / `tc.offset(s)` | `tc.source:<spec>` / `tc.engaged:<bool>` / `tc.offset:<seconds>` |
| `subscribe(host,port)` / `unsubscribe(host,port)` | `subscribe:<host>:<port>` / `unsubscribe:<host>:<port>` |
| `ping` / `workspace.save` / `workspace.reload` | `ping` / `workspace.save` / `workspace.reload` |

Cue numbers are lowercased so a Companion preset firing `Q1` from one button and `q1` from another doesn't bypass the lockout.

---

## 8. Source attribution

The dispatcher tags every action with its source for the show log:

| Source                                  | Log entry shape                            |
|-----------------------------------------|--------------------------------------------|
| Local hotkey / palette button           | `operatorButton`                           |
| OSC UDP / TCP                           | `osc(host: "<ip>", port: <port>)`          |
| HTTP / WebSocket                        | `http(tokenSuffix: "<last 4>")`            |
| Timecode chase                          | `timecode`                                 |
| System / test                           | `system`                                   |

HTTP token suffixes are limited to the last 4 characters so a leaked log file cannot be replayed against the API. The full token is never written to disk.

---

## 9. Bonjour discovery example

`dns-sd -B _simpleplayback._tcp` from a peer machine should list every running instance:

```
Browsing for _simpleplayback._tcp
  Add  Local  Simple Playback
```

`dns-sd -L "Simple Playback" _simpleplayback._tcp` resolves to `<host>:<port>` plus the TXT record described in §1.

---

## 10. Worked examples

### 10.1 Fire a cue from curl

```sh
curl -X POST http://127.0.0.1:53001/api/v1/cue/Q1/play \
  -H "Authorization: Bearer YOUR_TOKEN"
# → {"apiVersion":1,"address":"/sp/cue/Q1/play","status":"ok","data":{"fired":"Q1"}}
```

### 10.2 Subscribe to state push (WebSocket)

```sh
websocat ws://127.0.0.1:53001/api/v1/events \
  -H "Authorization: Bearer YOUR_TOKEN"
# → stream of /sp/state/globals + /sp/state/cue/<id> JSON frames
```

### 10.3 GO with optional target (OSC over UDP)

`oscsend 127.0.0.1 53000 /sp/go s Q1`

Reply on the same address as `/reply`:
```
/sp/go/reply s {"apiVersion":1,"address":"/sp/go","status":"ok","data":{"fired":"Q1"}}
```

### 10.4 OSCQuery handshake

```sh
curl 'http://127.0.0.1:53001/?HOST_INFO'
# → JSON HostInfo with name, oscIP, oscPort, oscTransport, extensions
```

---

## 11. Versioning policy

`apiVersion` bumps when the address shape changes incompatibly (route renamed, argument types changed, capability requirement raised). Additive changes (new fields in a `data` payload, new verbs at new addresses, new state push fields) keep the same version — clients should ignore unknown fields and unknown addresses.

The Bonjour TXT `api=v1` value moves to `v2` in lockstep. An integrator that wants to support both versions can branch on TXT before connecting.

---

## 12. Not yet wired (v1 ack-only)

These addresses are reachable and parse correctly, but the runtime does not act on them in v1. Replies carry `applied: false` so an integrator can detect the gap rather than assume success.

- `/sp/cue/<id>/scrub` and `/sp/cue/<id>/scrub/seconds` — without a host interceptor wired
- `/sp/cue/<id>/opacity` and `/sp/cue/<id>/audio/level` — same
- `/sp/cue/<id>/goto` — chain-rewrite is a future feature
- `/sp/look/<name>/recall` — looks are a future feature
- `/sp/output/main/freeze` — host interceptor surface; default no-op ack
- `/sp/workspace/save` and `/sp/workspace/reload` — Phase E10 (Saved Workspaces) deferred

These will become full implementations in subsequent phases without changing the address shape.
