# Show Control, Automation, and Remote Control — Research Report

Scope: external triggering, remote operation, automation, and show-control integrations for **Simple Playback**, a macOS playout tool for corporate AV, broadcast, and large-screen/LED-wall environments. Out of scope: render pipeline, codecs, importers, operator UX visuals.

---

## 1. Survey of reference systems

### 1.1 QLab 5 (Figure 53) — the gold standard cue-list runtime

QLab is the reference vocabulary the entire entertainment-tech industry borrows from. It dominates theatre and is widely used in corporate playback when an operator needs more than a single-clip player.

Concrete observations:

- **Cue identifiers are arbitrary strings.** "All cue numbers in a given workspace must be unique. Cue numbers do not need to be consecutive, nor do they need to be digits. Acceptable cue numbers could be 1, 1.5, A, AA, A.5, Preshow Music, or Steve." Operators rely on stable, human-meaningful IDs (Q1, Q2.5, INTRO, BUMPER) for years across iterated shows.
- **Continuation modes** are a 3-state flag per cue: `Do not continue` (hold), `Auto-continue` (start the next when *pre-wait* completes — they overlap), `Auto-follow` (start the next after this cue ends). Universal abstraction.
- **Group cues** wrap children with policies: Start First, Start All, Start Random, Timeline. Auto-follow chains inside groups create deterministic sequences, separate from the user's GO playhead.
- **Playhead is a cursor in the cue list.** GO without args fires the playhead cue, advances. GO with a cue-number arg jumps the playhead and fires.
- **OSC dictionary**: addresses are `/cue/{identifier}/{command}` with reserved identifiers `/cue/selected`, `/cue/playhead`, `/cue/active`, `/cue/*`, plus `/workspace/{id}/...`. Replies on UDP go back on port 53001 (configurable via `/udpReplyPort`). TCP is required for variables/feedback because of state-traffic volume. Default OSC listen port: 53000.
- **Reply envelope**: JSON `{"status":"ok","address":...,"data":...}`. Every command can succeed silently or echo a structured reply.
- **Show Mode** is the workspace lockout: restricts collaborators to view-only — no editing, no playhead movement, no GO from remote — while local operator retains control. Explicitly described as a *safety* mechanism, not security.
- **Network cues** let one workspace fire OSC at another (or itself) — the basis for main+backup mirroring.

Sources: <https://qlab.app/docs/v5/scripting/osc-dictionary-v5/>, <https://qlab.app/docs/v5/fundamentals/cue-lists/>, <https://qlab.app/docs/v5/fundamentals/cue-sequences/>, <https://qlab.app/docs/v5/networking/network-cues/>, <https://qlab.app/docs/v5/fundamentals/workspace-settings/>.

### 1.2 Mitti (Imimot) — the closest Simple Playback analogue

- **Cue IDs are uppercase, max 6 chars**, default to playlist index but renameable (`INTRO`). OSC then targets them: `/mitti/INTRO/play`. Same pattern as QLab, narrower keyspace.
- **OSC default port 51000; OSCQuery** server at `http://localhost:51000` lets clients introspect the namespace and current values. Modern bidirectional OSC pattern.
- **GoTo cue** lets non-consecutive cues chain at runtime; OSC `/mitti/{cueid}/setGotoToCueID` lets external systems rewrite the chain.
- **Tally-driven playback**: auto-play when ATEM selects its input, auto-act when NDI tallies it Program. Asymmetric — Mitti reacts to being on-air.
- **MTC/LTC follower with Jam-Sync**: when TC drops, switches to internal SMPTE clock; seamlessly returns when TC reappears. Per-cue TC in/out points and offsets.
- Companion module exposes per-cue feedbacks/variables, made dynamic by OSCQuery.

Sources: <https://imimot.com/help/mitti/external-controls/>, <https://imimot.com/help/mitti/integrations/>, <https://imimot.com/help/mitti/mtc-ltc-timecode-follower-mode/>.

### 1.3 Bitfocus Companion + Stream Deck — the de-facto operator surface

Operators almost never trigger pro playback by hammering keyboard shortcuts on the playback machine. They build a Stream Deck through Companion. Companion is open-source, free, dominant glue.

- **Companion abstractions**: connections (modules), buttons, presets, **actions** (outbound), **feedbacks** (inbound, drive button color/text/state), **variables** (`$(mitti:cue_name)`).
- Control sources: Stream Deck, emulator, web, OSC, TCP, UDP, HTTP, WebSocket, Art-Net.
- Module quality is gated by upstream API. QLab module needs TCP (feedback volume); Mitti module needed OSCQuery before per-cue dynamic feedback worked.
- The cleanest target API for a new module is "OSC over UDP for actions, OSCQuery or WebSocket for feedback subscription." HTTP/REST is fallback.

Implication: ship a Companion module yourself (or design the API so a community module is a weekend's work). Without Stream Deck buttons, professional adoption is dramatically slower.

Sources: <https://github.com/bitfocus/companion>, <https://github.com/bitfocus/companion-module-base/wiki/Feedbacks>, <https://qlab.app/cookbook/more-advanced-companion/>.

### 1.4 ProPresenter — adjacent, but instructive on timecode

ProPresenter has per-playlist timeline with SMPTE-triggered slide cues. Status states are revealing: `Not Engaged` / `Stopped` / `Playing`. "Not Engaged" is explicit operator opt-out so a stale TC source can't fire cues. This three-state pattern (off / armed / chasing) is the right model. Source: <https://support.renewedvision.com/hc/en-us/articles/7798653564563-Timecode-in-ProPresenter>.

### 1.5 vMix — the broadcast-leaning analogue

vMix exposes shortcuts bound to anything: keyboard, MIDI, HTTP/REST endpoint, Web Controller URL, Stream Deck plugin. Every action a user can do is a named shortcut function with parameters — one flat function table that all surfaces hit. The right architecture: define one canonical action vocabulary, then expose it identically over OSC, HTTP, and key-binding. Sources: <https://www.vmix.com/help26/KeyboardShortcuts.html>, <https://vmixapi.com/>.

### 1.6 PlaybackPro Plus — the corporate-AV incumbent

DT Videolabs PlaybackPro Plus speaks UDP/TCP listeners on port 7000 plus proprietary "SimpleSync" protocol for tight main+backup. DT18 hardware drives up to four PlaybackPro instances over Ethernet. The corporate-rental baseline: simple text commands over TCP/UDP, dedicated 12-key/multi-system controllers, redundant playout an explicit feature. Sources: <https://www.dtvideolabs.com/user-guide-simplesync-x/>, <https://www.dtvideolabs.com/playbackpro-plus-3/>.

### 1.7 Disguise (d3) and Watchout — high-end media servers

Both expose JSON-over-TCP and OSC, accept LTC for timeline chase, consume DMX/Art-Net/sACN for parameter control. Operators on those platforms expect *any* parameter is reachable from any control protocol. Out of scope for Simple Playback's MVP but sets expectations. Sources: <https://help.disguise.one/designer/devices/dmx-device>, <https://help.disguise.one/designer/timeline-tracks-transports/midi/setup-midi-show-control>.

---

## 2. Show-control protocol landscape

Ranked by relevance for **corporate-AV / broadcast playout**:

1. **OSC over UDP/TCP** — universal lingua franca. Trivially bridged from Companion, TouchOSC, QLab, Eos, Disguise, every hardware controller. **Must-have.**
2. **HTTP/REST + WebSocket** — fallback for environments without OSC libraries (browser remote, web automation). **Must-have at MVP.**
3. **MIDI / MTC / MIDI Show Control (MSC)** — MTC is MIDI-carried timecode; MSC is the 1991 standardized cue-trigger SysEx (Go, Stop, Resume, Load, Set, with cue/list/path). Show callers' Eos consoles still emit MSC. **Should-have.**
4. **LTC (linear timecode over audio)** — universal show-clock; received via any audio input. **Must-have for anything timeline-driven.**
5. **GPI/GPO contact closure** — cheapest, most reliable trigger ever invented; rented as Ethernet GPI boxes (Studio Technologies 394/395 on Dante) or USB. Easily emulated via OSC/HTTP webhook from a $40 Ethernet-GPIO bridge — building it natively is rarely worth it. **Nice-to-have.**
6. **Art-Net / sACN (E1.31) DMX over IP** — when a lighting console drives playback parameters. Niche; **advanced-later.**
7. **Tally — NDI tally, ATEM tally** — *inbound* so UI knows on-air status; can also be an *outbound trigger* for auto-play. **Nice-to-have at MVP, must-have soon after.**
8. **PJLink** — projector control over TCP, useful for unified power/shutter/input automation. **Nice-to-have, side macro.**
9. **DMX-512 raw RS-485** — needs a hardware dongle; almost no operator wires it directly. **Skip;** route via Art-Net/sACN.
10. **Pioneer Pro DJ Link** — niche to live-music corporate. **Out-of-scope.**
11. **MQTT** — IoT/installation-only. **Out-of-scope.**
12. **AppleScript / JXA** — free, macOS-native; trivial once a stable scripting dictionary exists. **Should-have post-MVP.**

**Recommendation**: ship **OSC + HTTP/JSON + LTC chase** at MVP. Add **MIDI/MSC + tally + Companion module** in v2. Defer everything else.

Sources: <https://en.wikipedia.org/wiki/MIDI_Show_Control>, <https://art-net.org.uk/>, <https://tvnewscheck.com/tech/article/studio-technologies-dante-enabled-model-394-gpi-interface-model-395-gpo-interface-now-shipping/>, <https://pjlink.jbmia.or.jp/english/data_cl2/PJLink_5-1.pdf>.

---

## 3. Cue list runtime model — recommendations

Adopt the **QLab vocabulary** verbatim. It already maps onto Simple Playback's palette/take model.

- **Cue list = ordered playlist** (Simple Playback already has this; addition is GO semantics).
- **Cue identifier**: free-form string, unique per show. Default `1, 2, …` but rename to `Q1`, `Q2.5`, `INTRO`. Don't make IDs case-sensitive (QLab does, operators trip).
- **Continuation per cue**: `hold` | `auto-continue` (overlap; fires next when this cue's *pre-wait* completes — gives crossfade automatically) | `auto-follow` (sequential; fires next when this cue ends).
- **Pre-wait / post-wait** floats (seconds), drive auto-continue/auto-follow timing.
- **GO** = "fire cue at playhead, advance playhead." `PREV` re-arms previous. `PANIC` = fade-out-and-stop-everything over a configurable time (default 0.5 s).
- **CLEAR** = immediate cut to black across all outputs, kills audio, leaves cue list state alone.
- **Group cue (later)**: start-first / start-all. MVP defers this in favor of auto-follow chains.
- **GO target argument**: GO with a cue ID jumps and fires.
- **Standby state** per cue: `idle` | `loaded` (preroll-warmed) | `running` | `tail` (post-fire crossfade tail).
- **Hotkey defaults**: spacebar=GO, ←=PREV, Esc=PANIC, `.`=CLEAR. Match QLab/Mitti — corporate ops have muscle memory.

Sources: <https://qlab.app/docs/v5/fundamentals/cue-sequences/>, <https://imimot.com/help/mitti/cues/>.

---

## 4. Recommended OSC/HTTP API surface

Design principle: **one canonical action namespace, exposed identically over OSC, HTTP/JSON, and WebSocket events**. Every UI action a local operator can take must be reachable remotely. This is the vMix pattern and the only one that doesn't end in three diverging surfaces.

### 4.1 Namespace

Root: `/sp` (short, doesn't collide with QLab's `/cue` if running on the same network).

### 4.2 OSC address conventions

```
/sp/go                               -> fire playhead cue, advance
/sp/go            s "INTRO"          -> jump playhead to "INTRO" and fire
/sp/prev                             -> step playhead back
/sp/panic                            -> fade-out everything
/sp/panic         f 0.0              -> hard cut
/sp/clear                            -> immediate black + audio mute
/sp/playhead      s "BUMPER"         -> move playhead, do not fire
/sp/load          s "BUMPER"         -> warm-up cue (decode, GPU upload)

/sp/cue/{id}/play                    -> fire this cue regardless of playhead
/sp/cue/{id}/stop                    -> stop this cue with default fade
/sp/cue/{id}/stop f 0.0              -> hard stop
/sp/cue/{id}/scrub f 0.0..1.0        -> seek normalized
/sp/cue/{id}/scrub/seconds f 12.345  -> seek absolute
/sp/cue/{id}/opacity f 0.0..1.0
/sp/cue/{id}/audio/level f -inf..0 dB
/sp/cue/{id}/in_point f seconds
/sp/cue/{id}/out_point f seconds
/sp/cue/{id}/loop i 0|1
/sp/cue/{id}/goto s "OTHERID"        -> set chain target (Mitti pattern)
/sp/cue/{id}/preload                 -> async warm-up
/sp/cue/{id}/notes s "..."           -> operator-visible note

/sp/output/main/freeze i 0|1         -> freeze frame on program output
/sp/output/main/blackout i 0|1
/sp/look/{name}/recall               -> recall a saved output configuration

/sp/timecode/source s "ltc:input1"   -> select TC source, or "off"
/sp/timecode/engaged i 0|1           -> arm/disarm TC chasing
/sp/timecode/offset f seconds        -> per-show TC offset

/sp/show_mode i 0|1                  -> safety lockout
/sp/workspace/save
/sp/workspace/reload
```

Wildcards: `/sp/cue/*/stop` stops every running cue. Reserved selectors mirror QLab: `/sp/cue/playhead/*`, `/sp/cue/selected/*`, `/sp/cue/active/*` (matches all currently-running cues).

### 4.3 Replies and feedback (bidirectional)

- **OSC reply**: UDP replies to sender's IP on port `53011` by default (configurable via `/sp/udpReplyPort`). TCP replies on the same socket. Reply envelope is JSON in an OSC string argument:
  ```
  /reply  s "{\"address\":\"/sp/go\",\"status\":\"ok\",\"data\":{\"fired\":\"INTRO\",\"playhead\":\"BUMPER\"}}"
  ```
  Mirrors QLab so toolchains designed against QLab work nearly unchanged.

- **OSCQuery**: HTTP server on the same port the OSC UDP socket listens on. Returns the full namespace as JSON, including `RANGE`, `TYPE`, `VALUE`, `DESCRIPTION` for every endpoint. This is what made Mitti's Companion module dynamic per-cue. Without OSCQuery, every integrator hand-types your address book.

- **Subscription / push**: clients call `/sp/subscribe s "host:port"` to receive state-change pushes:
  ```
  /sp/state/playhead              s "BUMPER"
  /sp/state/cue/{id}/standby      i 0|1
  /sp/state/cue/{id}/running      i 0|1
  /sp/state/cue/{id}/elapsed      f seconds
  /sp/state/cue/{id}/remaining    f seconds
  /sp/state/timecode/locked       i 0|1
  /sp/state/timecode/now          s "01:00:00:00"
  /sp/state/output/onair          i 0|1
  ```
  Push frequency for elapsed/remaining: 10 Hz when ≥1 client subscribes, 0 Hz otherwise.

### 4.4 HTTP/JSON twin

Mirror every OSC address as `POST /api/v1/...` with a JSON body. `GET` returns current state of any addressable resource. WebSocket at `/api/v1/events` carries the same push messages as OSC subscription.

```
POST /api/v1/go                    {"target":"INTRO"}
POST /api/v1/cue/INTRO/play
GET  /api/v1/cue/INTRO              -> full cue state JSON
GET  /api/v1/state                  -> snapshot of everything
WS   /api/v1/events                 -> stream of state-change frames
```

### 4.5 Authentication

Bearer-token + per-token capability flags: `read`, `fire`, `edit`. Default token has `read+fire`. Show Mode flips all non-admin tokens to `read`. Bind to localhost-only by default; explicit opt-in to `0.0.0.0`.

### 4.6 Discovery

Bonjour/mDNS service: `_simpleplayback._udp` (OSC) and `_simpleplayback._tcp` (HTTP). Advertise version, OSCQuery URL, workspace name. Companion can auto-find instances. (OSCQuery best practice.)

Sources: <https://qlab.app/docs/v5/scripting/osc-queries/>, <https://github.com/Vidvox/OSCQueryProposal>, <https://imimot.com/help/mitti/external-controls/>.

---

## 5. Recommended timecode model

### 5.1 Sources

- **LTC** via any selectable Core Audio input channel (mono). Decoder must accept 23.976 / 24 / 25 / 29.97DF / 29.97NDF / 30 fps.
- **MTC** via any Core MIDI input.
- **Internal generator** for testing and rehearsal.

### 5.2 Engagement state machine (operator-visible)

`Off` → `Armed` → `Chasing` → `Free-wheeling` → `Lost`

- `Off`: no TC processing. (ProPresenter's "Not Engaged" — explicit operator opt-out.)
- `Armed`: source selected, waiting for stable input.
- `Chasing`: receiving TC, transport locked. Display delta in ms between TC and playhead.
- `Free-wheeling`: TC dropped, internal clock continuing at last known rate. Configurable freewheel window (default 2 s, max 10 s).
- `Lost`: freewheel window expired. Cue continues to play to natural out point but TC-triggered cues no longer fire.

### 5.3 Per-cue TC behavior

- Optional **TC trigger time** (in: SMPTE string).
- Optional **TC out time** (cue auto-stops at this TC).
- **TC offset** per cue and per show (subtracted from incoming TC). Latency compensation.
- **Drop-frame awareness**: store TC as both string and absolute-frame-count; canonical compare is frame count, operator UI is the SMPTE string. 23.976 has no DF representation — UI must reflect that.

### 5.4 Jam-sync semantics

Match Mitti: when TC drops below threshold, switch to internal clock; when TC returns and is within ±1 frame of expected internal position, snap; if outside threshold, **re-lock** (jump the playhead). Threshold operator-configurable; default ±2 frames.

### 5.5 Display

Always show three values on a single status row: incoming TC, playhead TC, delta in ms. Color: green (locked, |delta|<½ frame), yellow (drifting), red (lost/freewheeling). Broadcast control-room convention.

Sources: <https://manual.ardour.org/synchronization/timecode-generators-and-slaves/>, <https://imimot.com/help/mitti/mtc-ltc-timecode-follower-mode/>, <https://blog.frame.io/2017/07/17/timecode-and-frame-rates/>.

---

## 6. Companion-friendly integration shape

To make a high-quality Companion module a 1–2 day project:

1. **Stable cue IDs that survive reorder.** Companion modules cache button bindings against IDs, not list positions. If operator reorders, button feedback must continue tracking the same cue.
2. **OSCQuery server** so the module can enumerate cues at runtime and offer them in dropdowns.
3. **TCP transport** for subscription channel (UDP-only feedback drops packets and module devs hate it). Offer both; document TCP for production.
4. **Per-cue feedbacks**: `cue running`, `cue standby`, `cue is playhead`, `cue elapsed > X`, `cue remaining < X`. Map directly to Stream Deck button colors.
5. **Per-cue variables**: `cue_id`, `cue_name`, `cue_remaining_string`, `cue_elapsed_string`, plus globals `playhead_id`, `playhead_name`, `next_id`, `tc_locked`, `tc_now`, `onair`.
6. **Idempotent actions.** Sending `/sp/cue/INTRO/play` twice in 50 ms (button bounce, network retry) must not double-fire. Per-cue retrigger lockout (50 ms default).
7. **Heartbeat**: `/sp/ping` → `/sp/pong f uptime_seconds`. Companion uses for connection-status pip.
8. **Versioned API**: include `apiVersion` in every reply. Bump it when address shapes change.

Maintain the Companion module in-house — vMix, Mitti, ProPresenter all benefitted from owning their module rather than waiting for community.

Sources: <https://github.com/bitfocus/companion-module-base/wiki/Feedbacks>, <https://github.com/bitfocus/companion-module-imimot-mitti/issues/8>.

---

## 7. Show Mode, redundancy, and live safety

### 7.1 Show Mode (must-have)

A single workspace toggle that:

- Disables every editing affordance in the UI (greyed; cannot drag-reorder, delete cues, retarget media).
- Locks remote API tokens to `read+fire` capability set. No `edit`.
- Disables global hotkeys outside the cue window (`⌘N`, `⌘S`, drag-and-drop into the playlist).
- Adds confirmation modals to `Quit` and `Open Project`.
- Bright UI affordance ("SHOW MODE" red bar). Operators rely on the visual.
- Toggleable only via a confirm dialog, ideally a settings-pane checkbox rather than a hotkey, to prevent accidental disable.

Match QLab's exact framing — "safety, not security." Don't oversell as auth.

### 7.2 Main + backup redundancy (advanced-later, but architect for it now)

- Two Simple Playback machines load the same `.splayback` project.
- Both subscribe to the same LTC source.
- Both expose `/sp/...` OSC.
- "Primary" sends every fired action as a Network cue / OSC mirror to the secondary (`/sp/cue/INTRO/play` echoed). Secondary is "follow-mode": ignores its local hotkeys, mirrors primary.
- Failover is **manual** — flip the program-output crosspoint at the SDI router. Don't try to be a hot-fail-over IP system.
- Pattern is QLab Network Cue + PlaybackPro SimpleSync.

MVP: ship "follow-mode" toggle + outbound mirror address. v2: build the explicit redundancy UI.

### 7.3 Logging and audit (must-have, often neglected)

Append-only event log to disk:

- timestamp (system + chase TC),
- source (local hotkey / OSC ip:port / HTTP token / TC trigger / network mirror),
- action (`go`, `panic`, `cue.play INTRO`, `edit INTRO out_point=12.5`),
- result (`ok` / error),
- playhead before/after,
- on-air state.

Two practical wins: post-mortems after a missed cue, and "did the show caller actually press GO at 02:14:33?" verification. Rotate per show; embed log path in `.splayback`.

Live undo: redo all edits live (multi-level), but pause undo of *fire* operations — once a cue has fired to a screen full of people, "undoing" is meaningless. Distinguish edit-undo from cue-history.

Source: <https://groups.google.com/g/qlab/c/InHMWGUSxxw>.

---

## 8. Tally and on-air awareness

Two flows:

- **Inbound tally to UI**: connect to ATEM (Blackmagic SDK), NDI source list, or TSL UMD/3.1 over UDP. Mark which Simple Playback output is currently on-air. Color the program window red when live. Allow N tally inputs mapped to N outputs.
- **Outbound auto-play on tally**: optional per-cue or per-output. "When my SDI feed becomes program on ATEM, fire this cue." Mitti pattern. Useful for stings/bumpers in a corporate keynote.

Skip TSL 3.1/5.0 until v2; ATEM + NDI tally cover the vast majority of corporate plus broadcast-prosumer.

Sources: <https://imimot.com/help/mitti/integrations/>, <https://github.com/josephdadams/ProTally>.

---

## 9. Hotkey conventions

Default bindings (configurable). Match QLab/Mitti so corporate ops don't relearn:

| Action | Key | Notes |
| --- | --- | --- |
| GO (fire playhead) | Space | universal |
| Previous | ← | step playhead back |
| Stop selected | Esc | not panic |
| Panic (fade everything) | ⌘. | configurable fade time |
| Hard clear / blackout | \ | instant |
| Go to top | ⌘↑ | playhead to first cue |
| Renumber selected | N | QLab-compatible |
| Toggle Show Mode | ⌘⇧L | confirm dialog |
| Load (preroll) selected | ⌘L | warm without firing |

Spacebar is sacrosanct: it must always GO, even when text fields have focus inside the cue inspector — globally re-route Space to GO when the playlist has focus or when Show Mode is on. QLab calls this the "space hijack" pattern.

Sources: <https://qlab.app/cookbook/space-hijack/>, <https://qlab.app/docs/v5/general/keyboard-shortcuts/>.

---

## 10. Complexity anti-patterns

- **Don't invent a new cue numbering syntax.** `Q1.5` works. Anything fancier (decimals beyond 2 places, dotted hierarchy 1.2.3) creates surprise sort orders.
- **Don't expose every internal property over OSC.** Pick action verbs, not field setters. `/sp/cue/INTRO/audio/level` good; `/sp/cue/INTRO/internal/_decoderHint` bad. Curated public surface, versioned spec.
- **Don't make MIDI Show Control core.** Operators who need MSC have an Eos console; expose MSC as a thin adapter on top of OSC, not the trunk of the API.
- **Don't conflate "remote control" with "remote editing"** in v1. Start with `read+fire` only. Editing remotely from an iPad is a 10× complexity step and rarely needed in corporate AV.
- **Don't hot-fail-over the SDI feed automatically.** Detection is unreliable; the operator must commit. Expose mirroring + manual switch.
- **Don't roll your own DMX-512 library.** Output via Art-Net/sACN through OLA or a USB DMX bridge if needed.
- **Don't gate Companion adoption behind a paid SDK or NDA.** OSC is free; OSCQuery is free; ship the spec.
- **Don't trust the system clock for timing.** Use mach_absolute_time / `CMClock` for sub-frame scheduling; use TC chase only for timeline anchoring.
- **Don't overload "GO" with smart logic.** GO fires the playhead. Period. Smart behaviors live in cue continuation flags.

---

## 11. Phasing — must-have / advanced-later / out-of-scope

**Must-have for pro corporate AV (v1.x):**

- GO/PREV/PANIC/CLEAR with QLab-style continuation modes
- Stable, renameable cue IDs
- OSC API on UDP+TCP, HTTP/JSON twin, WebSocket events
- OSCQuery server + Bonjour discovery
- Show Mode lockout
- Spacebar GO and the standard hotkey table
- Append-only event log
- LTC chase with engagement state machine + per-cue TC trigger/offset
- Companion module (in-house)
- Bearer-token auth, localhost-bind by default

**Advanced-later (v2):**

- Group cues / fire groups / start-random / Timeline group
- MIDI Show Control adapter
- Outbound network-cue mirroring for main+backup
- Tally in (ATEM + NDI) and tally-driven auto-play
- AppleScript dictionary
- Art-Net/sACN inbound for parameter control
- Browser remote read-only monitor (iPad)
- Multi-machine sync verification (heartbeat + drift report)

**Out-of-scope (keep it simple):**

- Lua/JS scripting cues (QLab v5's Script cue is a feature-creep magnet)
- Native DMX-512 RS-485 output
- Direct Pioneer Pro DJ Link
- MQTT / IoT integration
- A web *editor* (vs read-only monitor) — editing happens locally on the show machine
- TSL 5.0 tally

---

## 12. Source appendix

- QLab 5 OSC dictionary: <https://qlab.app/docs/v5/scripting/osc-dictionary-v5/>
- QLab 5 cue lists: <https://qlab.app/docs/v5/fundamentals/cue-lists/>
- QLab 5 cue sequences: <https://qlab.app/docs/v5/fundamentals/cue-sequences/>
- QLab 5 OSC queries: <https://qlab.app/docs/v5/scripting/osc-queries/>
- QLab 5 network cues: <https://qlab.app/docs/v5/networking/network-cues/>
- QLab 5 workspace settings (Show Mode): <https://qlab.app/docs/v5/fundamentals/workspace-settings/>
- QLab keyboard shortcuts: <https://qlab.app/docs/v5/general/keyboard-shortcuts/>
- QLab cookbook — Companion: <https://qlab.app/cookbook/more-advanced-companion/>
- QLab cookbook — space hijack: <https://qlab.app/cookbook/space-hijack/>
- Mitti external controls: <https://imimot.com/help/mitti/external-controls/>
- Mitti integrations (ATEM, NDI, Companion): <https://imimot.com/help/mitti/integrations/>
- Mitti MTC/LTC follower (jam-sync): <https://imimot.com/help/mitti/mtc-ltc-timecode-follower-mode/>
- Mitti changelog / cue-ID system: <https://imimot.com/help/mitti/changelog/>
- Bitfocus Companion: <https://github.com/bitfocus/companion>
- Companion module-base feedbacks: <https://github.com/bitfocus/companion-module-base/wiki/Feedbacks>
- Companion module-base variables: <https://deepwiki.com/bitfocus/companion-module-base/4.3-variables>
- ProPresenter timecode: <https://support.renewedvision.com/hc/en-us/articles/7798653564563-Timecode-in-ProPresenter>
- vMix shortcut function reference: <https://www.vmix.com/help25/ShortcutFunctionReference.html>
- vMix Web Controller: <https://www.vmix.com/help25/WebController.html>
- vMix unofficial API: <https://vmixapi.com/>
- DT Videolabs PlaybackPro Plus & SimpleSync: <https://www.dtvideolabs.com/user-guide-simplesync-x/>
- Disguise DMX device: <https://help.disguise.one/designer/devices/dmx-device>
- Disguise MSC: <https://help.disguise.one/designer/timeline-tracks-transports/midi/setup-midi-show-control>
- MIDI Show Control overview: <https://en.wikipedia.org/wiki/MIDI_Show_Control>
- TouchOSC editor messages: <https://hexler.net/touchosc/manual/editor-messages-osc>
- OSC Query Proposal: <https://github.com/Vidvox/OSCQueryProposal>
- Ardour timecode generators/slaves: <https://manual.ardour.org/synchronization/timecode-generators-and-slaves/>
- Frame.io timecode primer (DF/NDF/pulldown): <https://blog.frame.io/2017/07/17/timecode-and-frame-rates/>
- Art-Net: <https://art-net.org.uk/>
- PJLink v2 spec: <https://pjlink.jbmia.or.jp/english/data_cl2/PJLink_5-1.pdf>
- ProTally (TSL/ATEM/NDI tally): <https://github.com/josephdadams/ProTally>
- Studio Technologies Dante GPI/GPO: <https://tvnewscheck.com/tech/article/studio-technologies-dante-enabled-model-394-gpi-interface-model-395-gpo-interface-now-shipping/>
- Companion-Mitti dynamic feedback issue: <https://github.com/bitfocus/companion-module-imimot-mitti/issues/8>
- QLab show-mode discussion: <https://groups.google.com/g/qlab/c/InHMWGUSxxw>
