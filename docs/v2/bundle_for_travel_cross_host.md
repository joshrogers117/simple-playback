# v2 Pre-Scope — Bundle for Travel Cross-Host Rehearsal

**Status**: pre-scope (planning only — no code).
**Filed**: 2026-05-08, session 27.
**Spec source**: `docs/spec/feature_spec.md` §3.17 ("Bundle for Travel command (QLab's 'Bundle Workspace') collects + verifies all linked media into Media/ and rewrites references"). Implementation foundation shipped session 17 per `docs/phase_c_summary.md`.
**Progress source**: `docs/progress.md` C7d (foundation) + C8 (folder bookmarks consumer threading session 22). Cross-host rehearsal is the open item per `docs/handoff.md` "Hardware-bound" section ("C8 cross-host folder-bookmark rehearsal — sandbox-vs-NAS folder bookmarks, security-scoped folder access on a moved bundle").

---

## Why v2, not v1

The v1 build shipped Bundle for Travel as a **single-host** feature: an operator on Machine A presses "Bundle for Travel," the linked media gets copied into the bundle's `Media/` directory, and references are rewritten to point inside the bundle. Same operator, same machine, the bundle is now self-contained.

The cross-host story is the operationally important one — the operator copies the bundled `.spb` to Machine B (USB key, NAS share, file transfer) and opens it there. Three failure modes have been documented but not rehearsed against real silicon:

1. **Sandbox-vs-NAS folder bookmarks.** macOS sandboxed apps need security-scoped bookmarks for any file outside the bundle. Bundle for Travel collects everything *inside*, but the C8 folder-bookmark layer (session 21–22) lets Machine A retain *external* folder references for media that wasn't bundled. On Machine B, those security-scoped bookmarks resolve to nothing (they're machine-local URLs). The fallback chain in `MediaResolver` handles this — but never been tested against a real NAS-mounted share with two different machines.
2. **Security-scoped folder access on a moved bundle.** When a bundle is opened on Machine B, the `Bookmarks/` directory inside the bundle holds bookmarks Machine A created. macOS rejects them on a different host (signed with a different `kIOPlatformUUIDKey`). `MediaResolver` is supposed to fall through to bundle-relative `Media/` for managed assets and to "missing media" for linked-and-not-bundled assets. The pre-show check banner + Locate UI cover the latter — needs verification.
3. **Different macOS versions / locale / display environments.** Machine A might be macOS 26.0 with a 5K Studio Display; Machine B might be macOS 25.4 with a 1080p projector. Stage definitions, Output bindings, screen role assignments are all per-machine — but the project bundle stamps them. The Output Profile / venue-binding split (spec §2.2 cardinal separation 1) handles this in design; rehearsal needs to verify that opening the bundle on a venue with different hardware doesn't crash.

This isn't a code deliverable — it's a rehearsal protocol + small follow-up code surface that surfaces only after the rehearsal exposes specific bugs.

## What "Bundle for Travel cross-host rehearsal" means in v1+ terms

A multi-machine rehearsal cycle that exercises the move-the-bundle workflow against real hardware. The deliverable is:

- **A documented rehearsal protocol** (extending `docs/manual_verification.md`) that an operator can run against two real Macs with shared / unshared filesystems.
- **A bug list** captured during rehearsal that becomes the v2 follow-up commits.
- **Targeted fixes** for the bugs discovered (each one a separate commit per the runbook).

Likely follow-up code surface (predicted; the rehearsal will refine):

- **Stale-bookmark detection on bundle open**: when `Bookmarks/<id>.bookmark` was created by another host, mark the asset offline immediately and surface in the import-status banner with a "Locate folder" affordance, instead of letting the resolver chain time out.
- **Cross-host warning banner**: when a project is opened on a different host than its last save (host UUID stamped in `Show.json`), surface a one-time non-modal banner: "This project was last saved on `<hostname>`. Verify external media in the pre-show check."
- **Pre-show check `media.crossHost` row**: explicit row that goes orange (warning) when the project's last-saved host UUID doesn't match the current host, listing the count of foreign-host bookmarks. Operator clicks Fix → Pre-Show check `media.files` flow already covers the relink.
- **Output Profile portability**: if Machine B doesn't have a DeckLink card matching Machine A's, the binding falls back to Preview / OS Display — already true per the v1 binding model, but the surface should warn explicitly.
- **Time zone / locale stamping**: project's saved-at timestamp should preserve UTC + machine TZ; display in operator-local TZ on open. Probably a no-op given Foundation's `Date` semantics but worth a pin test.

## Open product questions

These need an operator-side answer before any code lands:

1. **Two-machine rehearsal scope — what's the minimum viable rehearsal?**
   - **A — One direction**: Machine A bundles → copy via USB → Machine B opens. Verifies the dominant case.
   - **B — Two directions**: also test Machine B saves changes → copy back → Machine A opens.
   - **C — NAS-shared simultaneous open**: both machines open the same bundle at the same time (project-lock-file ensures one is "view-only" via the foreign-live banner shipped E8).
   - **My recommendation**: A as the v2 minimum; B and C as v2.1 follow-ups.

2. **Stale-bookmark detection — eager or lazy?**
   - **A — Eager** (on bundle open): scan all bookmarks at load time; flag stale ones immediately.
   - **B — Lazy** (on first access): bookmarks resolve when a cue tries to play; fail at that moment.
   - **My recommendation**: A. Eager scan + a one-time non-modal banner means the operator sees the issue at load-time, not at fire-time. Slight cost (~10-50ms per bookmark on bundle open) is acceptable.

3. **Cross-host warning banner — where does it live?**
   - **A — Inline in the import-status banner** (the existing C-banner shape). Stacks with other import status messages.
   - **B — Dedicated cross-host banner above the import-status banner**. More prominent for a more important message.
   - **C — Pre-show check row only**, no transient banner.
   - **My recommendation**: A + C. The import-status banner is dismissable; the pre-show check row is canonical.

4. **Hostname display — "Studio iMac" or `Marks-MacBook-Pro.local`?**
   The v1 ProjectLockFile uses `gethostname(2)` (per session-26 lock-in in `decision_log.md`). For the cross-host warning, the same source should be canonical. But `gethostname(2)` returns `Marks-MacBook-Pro.local` which is operator-confusing. Alternatives:
   - **A — `gethostname(2)` raw.** Matches the lock file; technically correct; visually noisy.
   - **B — `Host.current().localizedName`** (e.g., "Mark's MacBook Pro"). Operator-friendly; mismatched with lock file source.
   - **C — `gethostname(2)` raw, but render with `.local` suffix stripped in the banner**. Best of both.
   - **My recommendation**: C. Lock file stays canonical; banner display is cosmetic.

5. **What about audio device fingerprinting?**
   Machine A might have an Apollo Twin set as default output; Machine B has built-in speakers. The project doesn't stamp the audio device today; the v2 audio sub-phase (per `audio_subphase.md`) is where multi-device routing lands. For v2 cross-host rehearsal, recommend: surface a warning row in the pre-show check when the project's expected audio devices aren't all present on the current host. Re-uses the v2 audio routing matrix as the source of expectations.

## Dependency map

- **`Services/BundleForTravelCoordinator`** (session 17) — already collects + verifies + applies. No changes for the rehearsal.
- **`Services/MediaResolver`** (session 16, refined session 21-22) — already handles fallback waterfall: bookmark / originalPath / hash / size+name / offline. Cross-host failure surfaces as offline at `MediaResolver.resolve(...)` returning nil.
- **`Services/AssetLibraryProbe`** (session 16) — `pre-show check media.files` row driver. Already classifies missing media as error. Would gain a sibling probe: `Services/CrossHostProbe.swift` evaluating the saved-host vs current-host mismatch.
- **`PlayoutProject` schema** — adds optional `lastSavedOnHost: String?` field stamped on every save with `gethostname(2)`. Legacy projects decode with nil.
- **`Views/RootView.swift` import-status banner** — surfaces the cross-host banner when `lastSavedOnHost != currentHost && lastSavedOnHost != nil`.
- **`Views/PreShowCheckView.swift`** — adds the `media.crossHost` row when applicable.
- **`docs/manual_verification.md`** — adds a Cross-Host Rehearsal section enumerating the verification steps for question 1's Option A.

## Suggested first-slice (5-8 commits, contingent on rehearsal findings)

### Phase 1 — Pre-rehearsal infrastructure (3-4 commits, autonomous-friendly)

1. **`PlayoutProject.lastSavedOnHost` + persistence** (1 commit, ~80 LOC + ~60 LOC tests).
   - Optional field; stamped on save via `SimplePlaybackProjectDocument.fileWrapper(ofType:)`.
   - `currentHostname()` reused from `ProjectLockFile.swift` per session-26 lock-in.

2. **`Services/CrossHostProbe.swift`** (1 commit, ~120 LOC + ~80 LOC tests).
   - Pure-logic evaluator: `evaluate(project:currentHost:) -> CrossHostStatus { .matches | .differentHost(savedOn:) | .firstSaveOnThisHost }`.
   - Tests cover: nil saved-host, matching host, foreign host, host with `.local` suffix.

3. **Cross-host import-status banner row** (1 commit, ~80 LOC).
   - `ImportStatusBanner` adds a `.crossHost(savedOn: String)` case.
   - Surfaces on first open of a project saved on a foreign host; dismissable; doesn't reappear until next save-and-reopen elsewhere.

4. **PreShowCheck `media.crossHost` row** (1 commit, ~100 LOC + ~80 LOC tests).
   - Orange warning when `CrossHostProbe.evaluate(...)` returns `.differentHost`.
   - Detail line lists the saved hostname.
   - Fix action: opens NSOpenPanel for a Relink folder (re-uses C9 `media.files` fix shape).

### Phase 2 — Rehearsal (no commits; operator activity)

5. **Manual rehearsal session** — operator runs the cross-host rehearsal protocol:
   - Machine A: create a project with mixed managed and linked media; bundle for travel; copy to USB.
   - Machine B: open the bundle from USB; verify pre-show check rows; fire each cue.
   - Capture issues into a session-N rehearsal log.

### Phase 3 — Targeted fixes (variable count, dependent on Phase 2 findings)

6. **Stale-bookmark eager detection** (1 commit, ~120 LOC + ~80 LOC tests). On bundle open, call `URL.resolveBookmarkData(...)` for each bookmark; mark stale ones offline immediately.
7. **Audio-device warning row** (1 commit). Predicates on the v2 audio sub-phase landing first; defer if audio sub-phase isn't yet shipped.
8. **Output-binding fallback warning** (1 commit). When the saved Output binding references a DeckLink device not present on the current host, fall back to Preview + surface a warning in the pre-show check.
9. **Phase summary update** (1 commit). `docs/phase_c_summary.md` cross-host rehearsal section updated with rehearsal findings.

### Phase 4 — Reverse direction + simultaneous open (v2.1)

10. Reverse direction (Q1 Option B) — verify save-on-B / open-on-A is symmetric.
11. NAS simultaneous open (Q1 Option C) — verify the foreign-live lock banner shipped E8 fires correctly.

## Risks / unknowns

- **macOS sandbox & NAS interaction.** macOS sandboxed apps + SMB/AFP shares have historically had bookmark-resolution issues. The rehearsal might surface "bookmark resolves on Machine A, doesn't resolve on Machine B even on the same NAS" — would require either a full-disk-access escape hatch (large entitlement footprint, App Store rejection) or a "Locate folder" workflow that creates fresh bookmarks per-host.
- **Hostname stability across power events.** macOS hostname can change after a network change (e.g., DHCP-assigned hostname differs from local hostname). Need to verify `gethostname(2)` returns a stable value across this; if not, add an "operator-named host" preference.
- **Bundle size on USB.** Bundle for Travel can balloon a 50 GB media set into a 50 GB bundle. USB 3.0 / Thunderbolt is fine; SMB over slow venue Wi-Fi is not. Document recommendation: USB 3+ or Thunderbolt only.
- **Read-only NAS shares.** Some venues mount the NAS read-only by default; saving the project back to the NAS fails silently or hangs. The v1 show-log persistence-suspended banner (session 25 F1 P1) surfaces show-log writer failures; need a similar banner for autosave failures during cross-host rehearsal.

## When to revisit

- After Phase 2 rehearsal — the rehearsal findings drive Phase 3 scope.
- After v2 audio sub-phase ships — audio device fingerprinting becomes feasible (Q5).
- When NAS-shared simultaneous open becomes a real customer ask (Q1 Option C).

## Estimated effort

Phase 1: 3-4 commits, ~380-460 LOC + ~220-280 LOC tests. Autonomous-friendly; can land before rehearsal.
Phase 2: 0 commits; rehearsal session. Operator-led.
Phase 3: 2-5 commits depending on what Phase 2 surfaces. Each fix is small.
Phase 4: 2-3 commits for reverse-direction + NAS-simultaneous, deferred to v2.1.
