# v2 Pre-Scope — Post-Show Summary Report

**Status**: in progress — first-slice (sub-tasks 1–5) shipped session 29.
**Filed**: 2026-05-08, session 28. **Updated**: 2026-05-08, session 29.
**Spec source**: `docs/spec/feature_spec.md` §4 item 18 ("Post-show summary report (CSV + human readable).").
**Progress source**: `docs/progress.md` G-postShow. Builds on v1 ShowLog (E3) + Take History (E5).

## Session 29 — what shipped

Five pure-logic commits land the data + format core. The operator-visible UI and the system-event integration delta are deferred pending operator input.

| Sub-task | Status | Commit | Tests |
|---|---|---|---|
| 1. `.cueEnded` log event + emit (Q2-A) | shipped | `showlog: emit .cueEnded log entry on every cue completion (post-show v2 Q2-A)` | +5 |
| 2. `.takeLatency` log event + emit (Q3-C) | shipped | `showlog: emit .takeLatency on every late-take verdict (post-show v2 Q3-C)` | +5 |
| 3. `PostShowSummary` reducer | shipped | `postshow: add PostShowSummary pure-logic reducer (post-show v2 first slice)` | +19 |
| 4. Markdown exporter | shipped | `postshow: add Markdown exporter for PostShowSummary (post-show v2 second slice)` | +15 |
| 5. CSV exporter | shipped | `postshow: add CSV exporter for PostShowSummary (post-show v2 third slice)` | +14 |
| 6. Sheet UI + toolbar wiring | shipped | `postshow: add PostShowSummaryView sheet + Post-Show toolbar button (sub-task 6)` | +6 |
| 7a. Lock-file foreign-host log integration (Q4-B subset) | shipped | `postshow: log foreign-lock detections + collect into systemEvents (sub-task 7 partial)` | +5 |
| 7b. Audio-device-flip log integration (Q4-B subset) | deferred | — | — |
| 7c. REF-state-flip log integration (Q4-B subset) | deferred | — | — |

**Total session delta**: 8 commits, 749 → 818 tests (+69).

**Decisions ratified**:

- **Q2 (cue runtime measurement) — A**: emit `.cueEnded` from `ShowController.handleCueEnded`. Detail field carries the same descriptor (`cue.number` if non-empty else `cue.title`) the `.go` event uses; reducer pairs them by descriptor + chronology FIFO with case-insensitive matching (per A2).
- **Q3 (latency-from-GO-to-first-frame) — C**: `.takeLatency` event for every late-take detector verdict (both on-time and late). Existing `.lateTake` continues to fire only when verdict crosses threshold (operator-readable highlight); `.takeLatency` is the histogram superset. Buckets: `<50ms`, `50-100ms`, `100-200ms`, `200-500ms`, `>=500ms`.
- **Q4 (system event filters) — A for v2.0**: just the v1 system events (`.missingMedia`, `.droppedFrame`, `.lateTake`, `.takeLatency`). The Q4-B widening is sub-task 7 and defers to operator review.
- **Q5 (format) — B**: Markdown for human consumption + CSV for the producer's spreadsheet. PDF / HTML deferred to v2.1.

**Decisions deferred** to a future session (need operator UX input):

- **Q1 (time window)**: D (since-launch with optional date-picker widening) is the my-recommendation default but the date-picker UX shape — single date vs range, multi-day file aggregation — is sheet-only and benefits from operator preview before locking in.
- **Q6 (sensitive-data redaction)**: C (operator-toggle in export sheet, default A unredacted) is the my-recommendation but defaults are easier to set after seeing one rehearsal's worth of source-attribution rows.

The pure-logic reducer + exporters are invariant under both Q1 and Q6 — Q1 is just "which events to pass to the reducer" (the exporters render whatever slice they're given); Q6 is a per-cell post-processing pass over the rendered output (a `RedactionRule` injection at view time).

## Carryover from session 28 (original pre-scope)

---

## Why v2, not v1

v1 ships the show log (E3) — every GO / PANIC / dropped-frame / late-take event lands in `<bundle>/Logs/<yyyy-MM-dd>.log` as RFC 4180 CSV, plus an in-app viewer with filter UI (E4). Take history (E5) holds the last 200 fires in memory + a viewer sheet. What's missing for the post-show ritual:

- **Aggregation** — the operator wants to see "5 dropped-frame bursts, 1 late take, 0 panics" not 5,000 rows of CSV.
- **Human-readable form** — Markdown / HTML / PDF that the operator can paste into a post-show email or share with the producer.
- **Cue performance summary** — for each cue: how often fired, total runtime, average latency from GO to first frame.
- **System events summary** — disk pressure, REF lock state changes, audio device flips, lock-file foreign-host detections.

The data is all in the log file already; the missing piece is a reducer + a presenter. That's a small feature — but the open product questions about format, audience, and what "summary" includes are big enough that v1 deferred.

## What "Post-show summary report" means in v1+ terms

A reducer over `<bundle>/Logs/*.log` plus an exporter:

- **Reducer**: pure-logic `PostShowSummary.fromLogs(_:dateRange:)` produces a `PostShowSummary` value with:
  - `totalGOs: Int`, `totalPanics: Int`, `totalClears: Int`, `totalBlackouts: Int`.
  - `cueStats: [CueID: CueStats]` (fires, total runtime, avg-latency-from-GO-to-first-frame).
  - `dropEvents: [DroppedFrameEvent]` (timestamp + cumulative drops + burst size).
  - `lateTakeEvents: [LateTakeEvent]` (timestamp + cue + latency).
  - `systemEvents: [SystemEvent]` (audio-device-flip, REF-lock-flip, lock-file-foreign-host, disk-log-paused).
  - `sourceMix: [Source: Int]` (count of events per source).
  - `showStartedAt`, `showEndedAt`, `peakConcurrency: Int`.
- **Exporters**:
  - `CSVExporter.export(_:)` → grouped CSV (one section per category).
  - `MarkdownExporter.export(_:)` → human-readable doc with section headings + tables.
  - `HTMLExporter.export(_:)` → same content as Markdown rendered to HTML.
- **UI**: toolbar "Post-Show Summary" button (next to "Show Log") opens a sheet with the rendered Markdown, Save / Copy buttons.

## Open product questions

1. **What time window does "post-show" cover?**
   - **A — Since app launch** (in-memory events).
   - **B — Today's log file** (parses `<bundle>/Logs/<today>.log`).
   - **C — Operator-picked range** (date picker in the sheet).
   - **D — A + C**: defaults to since-launch, operator can widen.
   - **My recommendation**: D. Most operators run the report at end-of-show wanting "what just happened"; the date-picker exists for the multi-day rehearsal cycle.

2. **Cue runtime measurement.**
   The log records GO timestamps; "cue ended" timestamps require `.cueEnded` events which v1 doesn't emit. Options:
   - **A — Add `.cueEnded` log events** in v2 (delta on E3) so "cue runtime" is precise.
   - **B — Estimate runtime from next GO**: cue X runtime = (next GO timestamp) - (cue X GO timestamp). Wrong for groups, autoFollow, autoContinue.
   - **C — Skip cue runtime in v2.0**, ship just fire-counts; add A later.
   - **My recommendation**: A. Adds ~30 LOC to ShowController (emit `.cueEnded` in `cueDidEnd` handler) and unblocks accurate runtime stats. Bundles as the first sub-task of this v2 item.

3. **Latency-from-GO-to-first-frame.**
   E3+ tail late-take detector already measures this (Path 1 callback) and emits `.lateTake` events when latency > threshold. Should the summary expose:
   - **A — Just the late-take outliers** (events already in the log).
   - **B — All cue fires' latency** (requires logging every Path 1 verdict, not just late ones).
   - **C — Histogram** (5 buckets: <50ms, 50-100ms, 100-200ms, 200-500ms, >500ms).
   - **My recommendation**: C. Operators want shape-of-distribution post-show; histogram is the cheapest way to show it. Requires the late-take detector to emit a verdict event for *every* take (fast path: emit `.takeLatency` events at all latencies; the existing `.lateTake` event becomes a subset).

4. **System event filters.**
   Which events count as "system" for the report's "system events" section?
   - **A — Just the v1 system events**: dropped-frame, late-take, missing-media, disk-log-paused.
   - **B — A + REF lock-state changes** (B6b) + audio-device-flips + lock-file foreign detections.
   - **My recommendation**: B. These are the events operators ask about post-show. Requires the relevant subsystems to push to the show log (most already do — REF chip flip, lock banner display).

5. **Format default — CSV, Markdown, HTML, or PDF?**
   - **A — Markdown only**, copy-to-clipboard or save-to-file.
   - **B — Markdown + CSV** (Markdown for humans, CSV for sharing with producer).
   - **C — All four**: Markdown / CSV / HTML / PDF.
   - **D — Markdown + HTML** (PDF requires more work; CSV is already in the log file).
   - **My recommendation**: B. Markdown for the post-show email, CSV for the producer's spreadsheet. PDF is a v2.1 add when operators ask for archived deliverables.

6. **Sensitive data.**
   Show log includes source attribution: OSC `host:port`, HTTP `tokenSuffix`. Should the post-show report:
   - **A — Include source attribution verbatim** — useful for debugging.
   - **B — Redact OSC IPs / HTTP tokens** to first-octet-only (`192.…`) or `***` — useful for sharing publicly.
   - **C — Operator-toggleable in the export sheet**.
   - **My recommendation**: C with default A (private to operator) and a "redact for sharing" toggle that switches to B. Clearly labeled at export time.

## Dependency map

- **`Services/PostShowSummary.swift`** (new) — pure-logic reducer. Reads `[ShowLogEvent]`, returns `PostShowSummary`. No I/O.
- **`Services/PostShowExporters.swift`** (new) — `CSVExporter`, `MarkdownExporter`, `HTMLExporter` — all pure functions over `PostShowSummary`.
- **`Views/PostShowSummaryView.swift`** (new) — sheet rendering Markdown via `Text(.init(markdown))`; toolbar Save / Copy / Redact buttons.
- **`ShowController.swift`** — emits `.cueEnded` in `cueDidEnd` handler (Q2-A delta).
- **`ShowLogEvent.Action`** — adds `.cueEnded`, `.takeLatency` (Q3-C delta).
- **`Services/ShowLog.swift`** — already has the parser shape (per session-25 P1 fix); reused.
- **REF-state / audio-device / lock-file subsystems** — emit corresponding `.systemEvent` rows (Q4-B delta) if not already.
- **`Views/RootView.swift`** — toolbar button next to Show Log.

## Suggested first-slice (5-7 commits)

1. **`.cueEnded` log event + emit from `ShowController.cueDidEnd`** (1 commit, ~50 LOC + 60 LOC tests). Q2-A delta. Lands in show log immediately, no new view.
2. **`.takeLatency` log event + emit from late-take detector for every verdict** (1 commit, ~60 LOC + 80 LOC tests). Q3-C delta.
3. **`PostShowSummary` reducer pure-logic** (1 commit, ~200 LOC + 200 LOC tests). Aggregates events into the summary value type.
4. **Markdown exporter** (1 commit, ~120 LOC + 80 LOC tests). Section headings, tables, latency histogram.
5. **CSV exporter** (1 commit, ~80 LOC + 60 LOC tests). One section per category.
6. **`PostShowSummaryView` sheet + toolbar wiring** (1 commit, ~150 LOC). Sheet renders Markdown; Save / Copy / Redact buttons. Date picker for Q1-D.
7. **REF / audio-device / lock-file system-event log integration** (1 commit, ~80 LOC + 60 LOC tests). Q4-B delta — push events from the relevant subsystems into the show log so the summary picks them up.

## Risks / unknowns

- **Log file size at scale**. Multi-hour shows produce thousands of events; the reducer reads the entire file in. Streaming reduce or pagination is overkill at corporate-AV scale (peak ~5K events / show). Document the assumption; revisit if a customer ships a 24-hour rehearsal use case.
- **Markdown rendering fidelity** in `Text(.init(markdown))`. Tables aren't supported in SwiftUI's built-in Markdown renderer. The sheet renders the Markdown source as preformatted text; the export path produces real Markdown for downstream tools that handle tables.
- **Redaction scope** (Q6). OSC host strings can carry hostname (`atem.local`), not just IPs. First-octet redaction needs to handle both; `RedactionRule` enum keeps this swappable.
- **Cue-id case-sensitivity**. Per A2, cue IDs are case-insensitive but storage may differ. The reducer's `cueStats` dictionary keys must be normalized (`lowercased()`) to merge variants.

## When to revisit

- Operators ask for PDF export → ship Q5-C (add a PDFKit-backed exporter following the C3 pattern).
- A producer wants a periodic "midshow snapshot" rather than post-show only → expose the reducer to the OSC / HTTP surface (`/sp/showsummary/since=...`).
- Multi-day shows want cumulative reports across multiple log files → extend the date picker to multi-file aggregation.

## Estimated effort

5-7 commits, ~740-960 LOC + ~540-720 LOC tests. The bulk is the reducer + exporters, both pure-logic and well-suited to fixture-based testing.
