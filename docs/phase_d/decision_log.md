# Phase D Decision Log

Append-only log of non-obvious choices made while implementing Phase D (show
control + remote API). Mirrors the format of `docs/decision_log.md` so the
main thread can fold these in at merge time.

---

## 2026-05-07 — Hand-roll OSC, HTTP, WebSocket, OSCQuery, LTC decoder

**Decision**: Implement OSC encode/decode, the HTTP/WS server, OSCQuery JSON
publisher, and the LTC audio decoder by hand against `Network.framework` and
`AVFoundation`. No new Swift Package dependencies for Phase D.

**Why**:
- Network.framework's `NWListener` covers UDP, TCP, and TCP-with-`tls` cleanly
  on macOS 26. Localhost-only is the default per spec §3.12; the surface area
  we expose to the network is small and deterministic.
- OSC 1.0 is a tiny binary protocol (4-byte aligned strings, blobs, type-tag
  string starting `,`). Encoding and decoding the half-dozen tag types we
  need (`s`, `i`, `f`, `b`) is well under 200 lines. A dependency drags in
  bundling, multiple transports we don't need, and a build-graph entry that
  the main thread has to vet.
- HTTP/1.1 with WebSocket upgrade for localhost is similarly small. The HTTP
  side only handles `GET`, `POST`, and `Upgrade: websocket`. We don't ship a
  general-purpose HTTP server.
- OSCQuery is just JSON over HTTP — exactly the same JSON we already build
  for the HTTP/JSON twin, with a different namespace shape.
- LTC decoding via a Goertzel-style biphase-mark detector is ~150 lines and
  matches the open-source `libltc` algorithm. Pulling `libltc` would mean a
  C-library bridging header and a `BUILD_LIBRARY_FOR_DISTRIBUTION` chain we
  don't otherwise need. The audio rate is 48 kHz so the math is simple.

**Alternatives considered**:
- `OSCKit` (sammysmallman) — well-maintained but adds an SPM dep, brings in
  its own type system (we'd wrap it anyway), and doesn't help with the HTTP
  surface or OSCQuery.
- `Vapor` / `Hummingbird` — overkill for a localhost JSON server with a
  single WebSocket route.
- `libltc` — would be the right call if we needed encode + decode + jam-sync
  + drop-frame TC math from a battle-tested library; for decode-only at
  48 kHz with the engagement state machine we own, hand-rolling is cleaner.

**Reverse if**: any of the hand-rolled pieces grow past ~500 lines or we
discover an OSC corner case (typed bundles, address-pattern matching with
`{a,b}` alternation) that's actually hard to get right. Either trigger flips
the decision to OSCKit in a single commit.

---

## 2026-05-07 — Show-control surface attaches to `CueRuntime` via callbacks

**Decision**: The `ShowControlState` snapshot the OSC/HTTP transports read
from is built by listening to `CueRuntime`'s public callbacks
(`onCueFired`, `onCueEnded`, `onCueStateChanged`, `onPlayheadChanged`,
`onPanicChanged`, `onBlackoutChanged`, `onCleared`). The runtime itself is
not modified.

**Why**: `CueRuntime` is on the locked-files list. The callbacks already
expose every state change we need. Wiring through those keeps the boundary
clean and means the show-control stack tests in isolation against a
`CueRuntime` instance with a manual scheduler — the same pattern the
existing tests use.

**Trade-off**: anything `CueRuntime` doesn't expose (e.g. live elapsed/
remaining inside a cue, since the runtime doesn't track media position),
the show-control layer has to compute itself or cache from the playback
controller. For Phase D we surface elapsed/remaining as zero/unknown
unless a future hook is added; the spec lists it as a state push but does
not dictate that the values must be live during Phase D — see
`subscription state push` notes in §3.12.

---

## 2026-05-07 — Default ports

**Decision**:
- OSC UDP listen: `53000` (matches QLab default; spec §3.12 references it).
- OSC TCP listen: `53000` (same port, separate transport).
- HTTP+WebSocket+OSCQuery: `53001` (one port above OSC; OSCQuery clients
  expect HTTP next to OSC).
- UDP reply port (when not specified by sender): `53011` (per
  show-control research §4.3 recommendation).
- Bonjour service types: `_simpleplayback._udp` for OSC,
  `_simpleplayback._tcp` for HTTP/JSON twin.

All ports are configurable; defaults bind to `127.0.0.1` only.

---

## 2026-05-07 — Companion module ships as design doc, not v1 binary

**Decision**: Per spec §3.14 "Companion module (separate target / sibling
repo decision logged)", we ship `docs/phase_d/companion_module_design.md`
documenting the module's actions, feedbacks, variables, and presets. The
actual JS module is a 1–2 day project for a Companion module author and
lives in a separate repo when written.

**Why**: A Companion module is a JavaScript package (Node.js,
`companion-module-base`) — it cannot ship inside the Swift app target.
A sibling repo would need its own CI, npm publishing, and Bitfocus
upstream review. The design doc enumerates every binding so the work is
mechanical when scheduled.

The OSCQuery server we ship makes the module nearly auto-generatable:
the cue list is enumerable, every action has a description, and per-cue
feedback subscriptions are first-class.
