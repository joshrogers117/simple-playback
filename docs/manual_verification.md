# Manual Verification — Simple Playback v1

This document consolidates every "needs hardware" verification step from `docs/phase_*_summary.md` into a single rehearsal checklist. Run these on real operator media + real hardware before promoting v1 to "production-ready." Each step exercises a code path that is unit-tested at the model/pipeline layer but never run against the variety of real-world inputs that production media + real cards bring.

**File status**: F4 (Phase F prep) — written session 24 against the Phase A–E summaries on `development` at HEAD `1a94f80`. Refresh whenever a phase summary's manual-rehearsal section changes.

**How to use this file**:

- Each section's tests assume the previous phase's tests are clean.
- Items marked **[no-hw]** can be exercised on a stock laptop with no DeckLink card or NDI receiver. Run these first to catch regressions.
- Items marked **[hw]** require a real card (DeckLink Mini Recorder / Duo 2 / UltraStudio / etc.) plus an SDI reference monitor.
- Items marked **[hw + REF gen]** also need an external reference (genlock) generator.
- Items marked **[hw + receiver]** need a separate machine to receive (NDI receiver, OSC client, etc.).

Run a **full rehearsal cycle** (a complete show from doors-open through curtain) at least once before treating a build as production-ready. Every phase summary's hardware-only verification list is reproduced below.

---

## Phase A — Show runtime + UX scaffolding

These verify the cue-runtime + Show List UI integration. None requires hardware beyond the operator workstation.

1. **[no-hw] App launches, project opens** — Launch `Simple Playback`, open a fresh project, drop a few clips into the palette.
2. **[no-hw] Generate-from-Library** — Click **Generate from Library** in the empty Show List → cues `1`, `2`, `3` appear with correct titles.
3. **[no-hw] Space → GO** — Press **Space** → first cue fires, playhead moves to second, blue highlight on next cue.
4. **[no-hw] Repeat take** — Press **Space** again → second cue takes over.
5. **[no-hw] Esc → Panic** — Press **Esc** → panic fades; brief GO lockout, then auto-resumes.
6. **[no-hw] Show Mode toggle** — Toggle **Show Mode** (Cmd-Shift-L) → the toolbar add/delete buttons grey out; drag-reorder is disabled.
7. **[no-hw] Cue inspector** — Select a cue → the inspector shows number, title, continuation picker, pre/post-wait, notes editor.
8. **[no-hw] Auto-follow timing** — Edit a cue's continuation to **Auto-follow** with `postWait = 0.5` → after the cue ends, the next cue auto-fires after the half-second wait.
9. **[no-hw] Drag from palette to list** — Drag a slide from the palette into the Show List → a new cue appears at the bottom with the next available number.

---

## Phase B — Output pipeline rework

These verify the renderer + compositor + REF policy + frame-rate conformance. Most need real DeckLink hardware; a few exercise the in-app preview only.

### Software-only

1. **[no-hw] Output topology venue-portability** — open a project on machine A with a DeckLink output bound, save, reopen on machine B without that DeckLink. Verify the project file decodes cleanly, the per-machine `OutputBindingProfile` falls back to the default Program stage / OS display path, and the show file itself is unchanged on disk.
2. **[no-hw] 10-bit recommendation hint** — import a 10-bit HEVC Main-10 clip into a project. Output inspector should show the yellow "10-bit recommended" hint. Remove the clip, hint disappears.
3. **[no-hw] FPS conformance — cue inspector** — import a 23.976 clip into a project whose Stage is 59.94. Cue inspector renders an FPS conformance chip with "FPS: 23.976 → 59.94". Match is suppressed (no chip when within tolerance).
4. **[no-hw] FPS conformance — pre-show check** — open Pre-Show. The same mismatched cue surfaces a Pre-Show row "Frame rate mismatch: Clip 23.976 ≠ Stage 59.94". Multiple mismatched cues each get their own row.
5. **[no-hw] Compositor overlays — preview tile** — open a fresh project, switch the inspector to Overlays. Enable the bug, pick a PNG → bug renders in the in-app preview after the next take. Cycle the corner picker (TL/TR/BL/BR) → bug repositions on preview without needing another take. Sliders for size / margin / opacity update the preview live.
6. **[no-hw] Message overlay + countdown — preview tile** — enable the message, type `Doors in {time_left}`, set a target 60s in the future → preview shows `Doors in 1:00` and ticks down.

### Hardware-bound

7. **[hw] REF chip palette** — with a DeckLink card attached, select it as the output and start playback. Verify the REF chip appears in the lower-right of the status row. Stop output → REF chip disappears. Restart → chip re-appears at the new state.
8. **[hw + REF gen] REF chip — locked / unlocked / not-supported** — with a REF generator connected and locked, chip is **green / "REF: Locked"**. With no REF, chip is **orange / "REF: Free-run"**. On a card without external reference input (e.g. UltraStudio Mini Recorder), chip is **gray / "REF: Not supported"**.
9. **[hw + REF gen] REF expectation banner** — toggle "Expects external reference (genlock)" on in the Output inspector. With REF disconnected, the red banner ("REF EXPECTED — Output is free-running") appears above the status row. Reconnect REF → banner disappears, chip turns green. On a `notSupported` card with the toggle on, no banner appears (hardware fact ≠ contradiction). Save the project, reopen — toggle persists.
10. **[hw] Compositor overlays at SDI** — same overlays-inspector sequence as #5, but verify the bug + message render on the SDI feed at the chosen position. Crossfade between two video cues with overlays on → bug + message persist crisply through the dissolve on BOTH the in-app preview and the SDI output (no double-bake on the trailing frame).
11. **[hw] TransportSinkRouter fan-out (smoke)** — verify the existing crossfade and take semantics are unchanged from pre-B5 — a quick smoke-rehearsal of two video cues with crossfade enabled confirms the router did not regress the rendering hot path.

### Still deferred (cannot verify autonomously OR with current hardware)

- **[hw] SDI output looks right on a real reference monitor** (B5 / B12 / B13 visual confirmation).
- **[hw] Genlock + fill+key on a Duo 2** (B6 / B7 hardware path).
- **[hw] 10-bit YUV 4:2:2 format negotiation against a real card** (B8 hardware path).
- **[hw] "Output in use" recovery when another app holds the port** (B9, deferred).
- **[hw] Audio embed channel-pair routing against an SDI receiver** (B10, deferred).
- **[hw + receiver] NDI Full sender picked up by a real NDI receiver** (B11, deferred).
- **[hw] Hot-unplug + reconnect of an UltraStudio Thunderbolt mid-show** (B15, deferred).
- **[hw] Color pipeline conversion accuracy on a Rec.709 / Rec.2020 HLG / PQ reference monitor** (B13, deferred).
- **REF format-mismatch detection vs Stage frame rate** (B6 remainder) — blocked at the SDK level: the v15.3.1 / v16.0 `IDeckLinkOutput` interface's `BMDReferenceStatus` exposes only locked / unlocked / notSupported. There is no incoming-REF frame-rate query path. Cannot ship without a Blackmagic SDK API change.

---

## Phase C — Media pipeline

These run on real operator media. None is purely autonomy-testable because the real-world variety of codecs / containers / image sequences / Keynote decks / multi-GB ProRes files / cross-host bundles exceeds anything an autonomous build can fixture.

1. **[no-hw] Codec inspector flags** — import a long-GOP H.264 clip, a 10-bit HEVC Main-10 clip, a VFR phone clip, and a clip with NCLC tags missing. Verify the cue inspector renders one yellow chip per applicable flag below the FPS warning. The 10-bit chip should also turn on the Output inspector's "10-bit recommended" hint via B8.
2. **[no-hw] PDF import** — import a multi-page PDF whose pages mix portrait and landscape and contain at least one heavy-vector page. Verify rasters land in `<bundle>/Cache/Renders/<slide.id>.png` at output × 2, the palette tiles render the rasters, and a re-save of the project doesn't re-rasterize.
3. **[no-hw] Keynote import (machine WITH Keynote)** — import a `.key` file on a machine with Keynote installed. Verify the AppleScript prompt fires the first time and the import completes.
4. **[no-hw] Keynote import (machine WITHOUT Keynote)** — verify the import-status banner shows the "Keynote not installed" failure (no modal alert).
5. **[no-hw] Animated GIF / APNG** — import a multi-frame GIF and an animated PNG. Right-click → Transcode menu should lead with ProRes 4444 (not 422). Run the transcode and verify the resulting `.mov` plays smoothly with frames preserved.
6. **[no-hw] Image sequence** — drop a folder containing `frame.0001.png` … `frame.0240.png`. Verify the Add Folder sheet groups them into one sequence; pick 30 fps; confirm; verify the resulting ProRes 4444 `.mov` plays at the right rate.
7. **[no-hw] ProRes transcode** — right-click an H.264 clip → Transcode to ProRes 422. Verify the non-modal progress strip ticks, a sibling slide is appended on success, and the source slide's flag chip disappears (it now has a `.mov` sibling).
8. **[no-hw] Asset fingerprinting + relink** — import a clip, save the project, move the file to a new directory, reopen. Pre-Show `media.files` row should show "1 offline." Use Locate Folder → pick the new parent directory → relink applies and the file is found by content hash + name+size.
9. **[no-hw] Per-slide Locate** — for a single offline slide, right-click → Locate… → pick the new file. Verify the slide rebinds with a refreshed fingerprint (not stale).
10. **[no-hw] Bundle for Travel cross-host** — bundle a project on machine A (toolbar → Bundle for Travel → confirm), copy the entire `.splayback` bundle to machine B, open it. Verify managed assets play, compositor overlays render, palette thumbnails light up (live + offline-fallback paths), and the right-click "Transcode to ProRes" stays enabled for managed sources. Verify the missing-media banner doesn't false-positive.
11. **[no-hw] Save-As of untitled** — open a new doc, drop a clip, Save-As to a new bundle URL. Verify the asset-library banner doesn't flicker between offline / online; managed playback (after Bundle for Travel) resolves via the new bundle's `Media/` on the next take.
12. **[no-hw] C10 thumbnails offline path** — import a clip, save the project, delete the source from disk, close-and-reopen the project. Palette tile should still render the cached poster instead of the placeholder icon.
13. **[no-hw] Bundle for Travel partial-copy cleanup** — fill the destination disk to within a few MB, kick a Bundle for Travel pass, observe the failure banner. Verify the destination directory does NOT contain a truncated copy of the file that failed to copy.
14. **[no-hw] Stale-bookmark recovery** — open a project whose bookmarked source files have been moved/deleted on the host machine without project-side relink. Verify the offline-count banner is correct, `TranscodeService.canTranscode` is False (right-click menu hides Transcode), and `Locate…` finds the new path.
15. **[no-hw] Codec advisory pre-show row (session 24)** — import a long-GOP clip + a VFR clip + an untagged-color clip into one project. Open Pre-Show. Verify a single info-severity row "Codec advisories: 1 long-GOP, 1 VFR, 1 untagged-color — review the cue inspector and consider Transcode to ProRes." appears. Remove the long-GOP clip; verify the row updates to omit the long-GOP fragment. Remove every flagged clip; verify the row disappears.

### Still deferred (cannot verify autonomously)

- **C7 fingerprinting against multi-GB ProRes files** — verify SHA-256 streaming completes within reasonable time on multi-GB sources.
- **C8 folder bookmarks against real cross-host scenarios** — sandbox-vs-NAS folder bookmarks, security-scoped folder access on a moved bundle.
- **C5 image-sequence encodes against EXR / TIFF / mixed-aspect / multi-thousand-frame real-world sequences**.
- **C6 Keynote exports against real-world variety of operator decks**.
- **C2 ProRes transcodes against real-world variety of H.264 / HEVC / VFR / 10-bit sources**.
- **C11 filmstrip extraction against multi-GB sources** — generator pure-logic shipped; consumer UI is open product blocker.

---

## Phase D — Show control

These need real OSC clients (e.g. `oscsend`), real Companion + Stream Deck, and a real LTC generator.

1. **[receiver] OSC GO** — `oscsend localhost 53000 /sp/go ,s "Q1"` triggers the named cue. Show log records the GO with source `OSC`.
2. **[receiver] OSC server discovery** — `dns-sd -B _simpleplayback._udp` shows the running instance.
3. **[receiver] HTTP/JSON API** — `curl -X POST http://localhost:53001/api/v1/go -d '{"cueID":"Q1"}' -H "Content-Type: application/json"`. Same effect; show log records source `HTTP <token-last-4>`.
4. **[receiver] WebSocket events** — `wscat -c ws://localhost:53001/api/v1/events`. Take cues; verify state push at 10 Hz with `cueFired`, `running`, `tcLocked` fields.
5. **[receiver] OSCQuery namespace** — `curl http://localhost:53001/?HOST_INFO`. Verify the response advertises every OSC address with type/range/value/description.
6. **[receiver] Bearer-token auth + capability flags** — start the server with `read` token; verify only read-only addresses respond. Switch to `fire`; GO works. Show Mode strips the `edit` capability.
7. **[receiver] Companion module** — install the Companion module from `docs/phase_d/companion_module_design.md`. Verify the cue-list buttons fire correctly, feedbacks update in real time.
8. **[hw] LTC chase against real generator** — feed LTC over a CoreAudio input. Verify engagement state machine ticks through Idle → Listening → Engaged. Pick a cue with an `ltcTrigger` set; verify the cue fires at the configured timecode. Drop-frame TC (29.97 / 59.94) verifies separately.
9. **[hw] MTC chase via Core MIDI input** — same as LTC but over MIDI Time Code.
10. **[hw + receiver] Internal TC generator for rehearsal** — verify the internal generator produces stable TC with a downstream receiver locked.

### Still deferred (cannot verify autonomously)

- **Real Companion + Stream Deck integration test** — UX feel and button latency in a dim booth.
- **LTC chase against drift / re-jam / drop-frame edge cases on real hardware**.

---

## Phase E — Reliability

Most of these need induced failures (CPU stalls, force-quit, lock-file rewrites). Run them on a separate test bundle so you don't damage the real show file.

### Pre-show + show log + autosave

1. **[no-hw] Pre-show check signal coverage** — open Pre-Show. Verify rows for media-resolution, media-files, FPS conformance, 10-bit recommendation, codec advisory, external-reference (when configured), disk space, audio device, render-path-warmed, energy. Row severity sort: errors first, then warnings, info, OK.
2. **[no-hw] Pre-show fix actions** — for each row with a Fix button, click it and verify the right behavior:
   - `system.audio` → opens System Settings → Sound.
   - `system.disk` → reveals the bundle in Finder.
   - `output.reference` → opens Blackmagic Desktop Video Setup.
   - `media.files` → NSOpenPanel relink folder; auto-relinks via content hash + name+size waterfall.
3. **[no-hw] Show log writer** — fire several cues, switch through hotkey + OSC + HTTP + TC sources. Open the show log viewer; verify chronological list, source labels, action labels.
4. **[no-hw] Show log filters** — filter by Source = OSC, Action = Show verbs, Since = Last minute. Verify the count switches from "N events" to "N of M events" and rows match the filters. Reset; full log returns.
5. **[no-hw] Show log export** — click Export CSV → save → open in a spreadsheet. Verify RFC-4180 quoting on cells with commas / newlines / quotes.
6. **[no-hw] Show log persistence** — fire cues over a multi-hour show against a saved bundle. Verify `<bundle>/Logs/<yyyy-MM-dd>.log` accumulates rows. Reopen the project the next day; old rows persist; new rows append to the new day's log.
7. **[no-hw] Autosave — 30 s rolling** — open a project, edit a slide title, idle 35 s. Verify the bundle's `Show.json` mtime advanced.
8. **[no-hw] Autosave — Show-Mode checkpoint** — toggle Show Mode on. Verify `<bundle>/Autosave/<timestamp>__show_mode_on.json` was created. Toggle off; verify `<timestamp>__show_mode_off.json`. Repeat 21 times; verify only the newest 20 remain.

### Live-show instrumentation

9. **[no-hw] Dropped-frame chip — clean show** — open a project, take a slide, watch the status bar — chip should remain hidden. Toggle through several cues; chip stays hidden as long as no drops are detected.
10. **[no-hw] Dropped-frame chip — induced stall** — with a video cue running, deliberately stress the system (open Activity Monitor's "All Processes, Hierarchically" and let it CPU-pin a core; or run `yes >/dev/null` in Terminal). The chip should appear, escalate to orange when a stall happens, and return to secondary checkmark when rolling resets to 0 after 10 seconds.
11. **[no-hw] Dropped-frame log debounce** — induce a stall. Open the show log — there should be at most one `.droppedFrame` row per ~1 s of stall, with detail `drops=N cumulative=M`.
12. **[no-hw] Dropped-frame counter resets on output stop** — after drops have accumulated, click "Clear Output". The chip disappears.
13. **[no-hw] Late-take detection** — in a project with at least one large H.264 clip, fire it via GO. If the load latency exceeds the threshold, the show log records a `.lateTake` event with detail `latency=Nms cue=<descriptor>`.

### Take history + crash recovery + lock file

14. **[no-hw] Take history — empty / first take** — open a fresh project. Click Take History; sheet shows "No takes yet". Take a cue; reopen — one row with that cue's number/title.
15. **[no-hw] Take history — capacity** — fire a cue 250 times via OSC or repeated GO. Open Take History; should show exactly 200 rows, most recent at top.
16. **[no-hw] Take history — title pin** — fire a cue named "Opener". In edit mode, rename the cue to "Renamed". Take History should still show "Opener" for the prior fire.
17. **[no-hw] Crash recovery — happy path** — open a saved `.spb` project. Toggle Show Mode on, then off. Force-quit the app (`kill -9 <pid>`). Reopen. The yellow recovery banner should appear with "Snapshot from <recent date> (Show Mode off)". Click Restore; the project state from the checkpoint loads. Save; the banner stays away on next reopen.
18. **[no-hw] Crash recovery — Discard path** — same setup but click Discard. Verify `<bundle>/Autosave/` is gone. Reopen; banner does not appear.
19. **[no-hw] Crash recovery — equal mtime no banner** — open a saved project. Toggle Show Mode on, then save normally (Cmd-S). Force-quit and reopen. The banner should NOT appear.
20. **[no-hw] Crash recovery — restored doc is dirty** — Restore from a checkpoint. The window title should show the unsaved-changes dot; Cmd-S writes the recovered state to Show.json.
21. **[no-hw] Project lock file — same-host duplicate open** — open a saved `.spb`. Verify `<bundle>/.lock` exists. Open the same project a second time. Banner reads "This show is open elsewhere — Opened on <hostname> (PID <N>) at <date>". Click Open Anyway; the lock is overwritten.
22. **[no-hw] Project lock file — close releases** — quit the app. Verify `<bundle>/.lock` is gone after quit.
23. **[no-hw] Project lock file — stale local PID** — write a synthetic lock with a dead PID. Open the project. Banner should NOT appear (PID dead → stale → silently overwritten).
24. **[no-hw] Project lock file — foreign-host live** — write a synthetic lock with a different hostname + recent timestamp. Banner appears. Click Dismiss; the foreign lock stays in place. Click Open Anyway; the lock now reads our hostname.
25. **[hw] Energy assertion — pmset visibility** — toggle Show Mode on. `pmset -g assertions` shows a `NoIdleSleep` named `Simple Playback — Show Mode`. On a laptop on battery: with Show Mode on, the system should not idle-sleep even after the configured idle timeout elapses.

### Still deferred

- **E1+ macOS-condition tail** — DND / screensaver / Spotlight / Time Machine pre-show checks. Each fragile or privacy-blocked on modern macOS; deferred entirely.
- **E5 replay scrub** — sheet shows the history; the runtime can't yet "fire cue X with original parameters at offset Y."
- **E7 "what changed" summary** — banner today says "snapshot from <date> (<reason>)". A future iteration could decode the checkpoint and Show.json, diff them, and surface "5 cues changed, 2 added".
- **E8 read-only-mode banner option** — the third banner option from spec §3.16 still needs document-wide read-only enforcement.
- **E9 Director View tear-off window** — read-only Program + next 3 + notes (open product blocker on layout choices).
- **E10 Saved Workspaces** — Edit / Rehearsal / Show / Single-Screen (open product blocker on UX).
- **E11 Brightness adapt key** — booth-dim key separate from system brightness (open product blocker on chord choice).

### Multi-host / NAS-specific (cannot verify autonomously)

- **Lock-file behaviour against real NAS-shared multi-host scenarios** — two machines opening the same `.spb` from a SMB share, foreign-host stale-window timing on networked filesystem mtime drift. Confirm the foreign-host banner copy reads naturally with the `gethostname(2)` form (`Joshs-Mac.local`); if operators find the trailing `.local` confusing, file a UX issue rather than swapping the API — see the lock-in rationale in `Services/ProjectLockFile.swift:currentHostname()`.
- **Asset-library fingerprinting against multi-GB ProRes files** — SHA-256 streaming on GB-scale sources.
- **Show-log persistence over multi-hour shows** — file rotation, concurrent log appends, log-file integrity on a long uninterrupted run.

---

## Hardware-only verification — consolidated checklist

This is the union of every `[hw]` and `[hw + ...]` step above plus the deferred-due-to-hardware items. Use it as a pre-promotion gate.

- SDI output looks right on a real reference monitor (Phase B5 / B12 / B13).
- DeckLink REF chip palette + REF banner across locked / free-run / not-supported (Phase B6 / B6b).
- Compositor overlays + crossfade through overlays at SDI (Phase B12).
- TransportSinkRouter fan-out smoke (Phase B5).
- Genlock + fill+key on a Duo 2 (Phase B6 / B7).
- 10-bit YUV 4:2:2 format negotiation on a real card (Phase B8).
- "Output in use" recovery (Phase B9).
- Audio embed channel-pair routing (Phase B10).
- NDI Full sender picked up by a real receiver (Phase B11).
- Hot-unplug + reconnect of an UltraStudio Thunderbolt mid-show (Phase B15).
- Color pipeline accuracy on a Rec.709 / Rec.2020 HLG / PQ reference monitor (Phase B13).
- LTC chase + drop-frame TC + jam-sync against a real generator (Phase D12).
- MTC chase via Core MIDI input (Phase D13).
- Companion + Stream Deck integration (Phase D15).
- Energy assertion on a laptop on battery (Phase E1+).
- Real rehearsal cycle — full show from doors-open through curtain.

---

## Cross-references

- `docs/phase_a_summary.md` — Phase A summary + manual-rehearsal section (lines 48-61).
- `docs/phase_b_summary.md` — Phase B summary (session-24 close-out section: 10-step rehearsal + hardware-only list at top).
- `docs/phase_c_summary.md` — Phase C summary (session-19 C16 13-step rehearsal section).
- `docs/phase_d/companion_module_design.md` — Companion module install guidance.
- `docs/phase_e_summary.md` — Phase E summary (session-13/14/15 manual-rehearsal sections).

When a phase summary's manual-rehearsal section changes, refresh this file. Steps that move from "deferred" to "shipped" should drop their `[deferred]` tag and gain a numbered step here.
