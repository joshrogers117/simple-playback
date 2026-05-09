# v2 Pre-Scope — MIDI Show Control Adapter

**Status**: pre-scope (planning only — no code).
**Filed**: 2026-05-08, session 28.
**Spec source**: `docs/spec/feature_spec.md` §4 item 4 ("MIDI Show Control adapter as a thin layer over OSC.").
**Progress source**: not in `docs/progress.md` — v2 spec §4 candidate; pre-scoped here for the future autonomy session that picks it up.

---

## Why v2, not v1

MSC (MIDI Show Control, MMA RP-002) is the broadcast / theatre / cruise-line lighting-and-sound integration protocol — a fixed-format System Exclusive message over MIDI that lighting consoles and sound desks emit on cue. Operators in those verticals expect MSC inbound; the corporate-AV target operator doesn't. v1 shipped OSC + HTTP + WebSocket + OSCQuery as the integrator surface, which covers the "modern" integrator (Companion, ATEM software, Tricaster, OBS) and the in-house "we wrote a controller in Python" integrator. MSC is the lighting-console-driven integrator who arrives with an Eos / GrandMA / Hog and expects MIDI cables.

Per the spec, MSC is "a thin layer over OSC." The shape: a Core MIDI input, a per-cue command parser, a translator that maps MSC commands onto the existing `ShowControlAction` vocabulary, and the action ships through the existing dispatcher (capability check, idempotency lockout, source attribution = `.midi(...)`). Adding a new transport doesn't change the action surface or the show-runtime API.

## What "MIDI Show Control adapter" means in v1+ terms

A new transport that turns inbound MIDI SysEx into `ShowControlAction` values:

- **Listener**: `Services/MIDIShowControlListener.swift` — wraps `MIDIClient` + `MIDIInputPort`, consumes any selected Core MIDI source.
- **Decoder**: `Services/MIDIShowControlDecoder.swift` — pure-logic SysEx → `MSCCommand` decoder. MSC SysEx format: `F0 7F <device-id> 02 <command-format> <command> <data...> F7`.
- **Action mapping**: `Services/MIDIShowControlMapper.swift` — pure-logic translator from `MSCCommand` to `ShowControlAction` (GO → `.go`, STOP → `.cueStop`, RESUME → `.cuePlay`, FIRE → `.cuePlay`, ALL_OFF → `.panic(fade: 0)`, RESET → `.clear`).
- **Dispatcher source**: `ShowControlSource.midi(deviceID: Int, source: String?)`.
- **Configuration**: `MSCSettings` panel in app preferences — input device picker, MSC device-ID filter (a single MIDI cable can carry many devices' messages; filter to ours).

## Open product questions

1. **MSC device ID — fixed or operator-configurable?**
   The MSC device ID is a single byte (0..126) that addresses a specific receiver on the MIDI bus. Lighting consoles routinely have one device addressing multiple sound / playback systems.
   - **A — Fixed**: Simple Playback always responds to a hardcoded device ID (e.g. `0x10`). Simple, no UI, but conflicts when an operator already has another device on `0x10`.
   - **B — Operator-configurable** (default `0x10`): preferences panel exposes the picker.
   - **C — All-call only**: Simple Playback responds to broadcast (`0x7F`) only.
   - **My recommendation**: B with default `0x10`. Most operators run a single Simple Playback instance per MSC bus; the operator-configurable knob covers the "two instances on one bus" edge case without front-loading UI.

2. **MSC command-format filter — Sound General, Lighting General, "any"?**
   Each MSC SysEx carries a command format byte (e.g. `0x01` = Lighting, `0x10` = Sound General, `0x60` = All-Types). Simple Playback is a video-playback engine — does it answer to Lighting commands?
   - **A — Sound General + All-Types only**: matches the spec interpretation.
   - **B — Any command format**: lighting console operators commonly route GO commands without distinguishing format.
   - **My recommendation**: B in practice (operators don't want to debug command-format mismatches at FOH); A documented in the doc as the strict interpretation, with a "respond to any format" preferences toggle defaulting to on.

3. **GO with no cue argument — fire playhead or reject?**
   MSC GO can be sent with no cue / cue-list bytes. The Simple Playback dispatcher's `.go(target: nil)` already fires the playhead.
   - **My recommendation**: map MSC GO with no args directly to `.go(target: nil)`. Mirrors the OSC `/sp/go` behaviour.

4. **Cue ID encoding.**
   MSC cue IDs are ASCII bytes terminated by `0x00`, `0x7F`, or end-of-message. Simple Playback cue IDs are case-insensitive arbitrary strings (per A2). The mapping is straightforward but: "QUE 1.5" vs "1.5" — does the mapper treat the leading "QUE " as a prefix or as part of the ID?
   - **My recommendation**: strip "QUE " / "CUE " prefixes (common console output), then look up by `runtime.showList.cue(number:)`.

5. **Source attribution in show log.**
   Show log column "source": currently `local`, `osc h:p`, `http …xxxx`, `tc`, `system`. New value:
   - **A — `msc dev<N>`** (just the device ID).
   - **B — `msc <source-name> dev<N>`** (Core MIDI endpoint name + device ID).
   - **My recommendation**: B. The Core MIDI endpoint name ("Eos / Output 1") is what operators ask for in post-show debriefs.

6. **Capability mapping.**
   The OSC / HTTP transports use bearer tokens for capability gating. MSC has no auth (it's a wire protocol); every connected MIDI device gets the same access.
   - **A — Always grant `read + fire`** (no edits).
   - **B — Operator-configurable per source.**
   - **C — Always grant the full `read + fire + edit` set.**
   - **My recommendation**: A. Show Mode strips `edit` from non-admin tokens already (D6); pinning MSC to `read + fire` is the safest default and matches the lighting-console use case (fire cues, don't edit show structure).

## Dependency map

- **`Services/MIDIShowControlListener.swift`** (new) — Core MIDI subscription. Reuses any `MIDIClient` infrastructure already in the LTC/MTC chase code (`docs/progress.md` D13).
- **`Services/MIDIShowControlDecoder.swift`** (new) — pure-logic SysEx parser; emits `MSCCommand` enum.
- **`Services/MIDIShowControlMapper.swift`** (new) — pure-logic `MSCCommand → ShowControlAction` mapper.
- **`ShowControlDispatcher`** — `ShowControlSource.midi(...)` case added; no other changes.
- **`ShowLogEvent.Source`** — `.midi(deviceID: Int, sourceName: String?)` case added; CSV `label` formatter extended.
- **`Views/PreferencesView.swift`** (new or extend existing) — MSC settings panel (input picker, device-ID picker, command-format filter toggle).
- **`SimplePlaybackApp` / `ShowController`** — instantiate the listener at app launch when MSC is enabled in preferences; route decoded actions through the dispatcher.

## Suggested first-slice (4-6 commits)

1. **`MSCCommand` model + `MIDIShowControlDecoder` pure-logic** (1 commit, ~150 LOC + 200 LOC tests). Pure SysEx → command parser; canonical SysEx fixtures for each command (GO, STOP, RESUME, FIRE, ALL_OFF, RESET).
2. **`MIDIShowControlMapper` pure-logic** (1 commit, ~80 LOC + 80 LOC tests). `MSCCommand → ShowControlAction` translation; cue-ID prefix stripping (Q4); GO-no-args → playhead (Q3).
3. **`ShowControlSource.midi(...)` + `ShowLogEvent.Source.midi(...)` plumbing** (1 commit, ~60 LOC + 30 LOC tests). Source-attribution end-to-end through dispatcher → show log.
4. **`MIDIShowControlListener`** (1 commit, ~150 LOC). Core MIDI subscription; SysEx batch handling; routes decoded commands through mapper into dispatcher. Headless test seam: an injectable `decoder` + `mapper` so listener can be exercised without real MIDI.
5. **Preferences UI** (1 commit, ~120 LOC). Input picker, device-ID picker, format-filter toggle. Reads / writes `UserDefaults`.
6. **Capability default + Show Mode interaction** (1 commit, ~40 LOC). Pin `read + fire` (Q6-A) at the listener boundary; verify Show Mode strip applies as expected.

## Risks / unknowns

- **SysEx batch handling**: Core MIDI delivers SysEx in segments. Listener must reassemble before passing to decoder.
- **Pre-existing LTC/MTC infrastructure overlap**: D12-D14 already have `MIDIClient` machinery. Reuse the same client; don't open a second MIDI client.
- **Console-quirks**: Eos and GrandMA emit slightly different SysEx for the same logical "GO" — extra trailing bytes, alternate command formats. The decoder should be permissive (ignore unknown trailing bytes; log unrecognised commands rather than crash).
- **Capability lift**: MSC has no auth. Pinning `read + fire` (Q6-A) is the right default but not bulletproof — anyone with a MIDI cable can fire cues. Document the trust-the-network assumption in `docs/api.md`.

## When to revisit

- Operators ask for MSC outbound (Simple Playback emits cue events as MSC) → spec §4 is silent on outbound; new conversation needed.
- Lighting console emits `cue list` arguments (multi-cue-list shows) → MSC supports it; map to a future multi-show-list feature if v2 ships one.
- An integrator asks for command-format filter `0x01` (Lighting) only → swap Q2 default.

## Estimated effort

4-6 commits, ~600-800 LOC + ~310-410 LOC tests. The decoder + mapper are pure logic and easy to test; the listener is the smallest surface area and reuses existing MIDI client.
