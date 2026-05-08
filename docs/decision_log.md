# Decision Log

Append-only. Every non-obvious choice made during the autonomous build, with rationale and alternatives. Most recent entries at the bottom (newest commits at the bottom of git log; mirror that here so a `tail` reads the latest).

Format per entry:

```
## YYYY-MM-DD HH:MM — <topic>

**Decision**: <what>

**Why**: <rationale>

**Alternatives considered**: <list>

**Reversibility**: easy / medium / hard

**What I'd revisit if**: <signal>
```

---

## 2026-05-07 — Pre-kickoff decisions

The decisions captured in `docs/runbook.md` §1 are recorded there as the starting contract. This log records decisions made *during* the build.

---

## 2026-05-07 — A1: bundle format approach

**Decision**: One UTI (`com.josh.simpleplayback.project`) re-declared as conforming to `com.apple.package` + `public.composite-content`. NSDocument always writes a directory bundle containing `Show.json`. Read accepts both legacy regular-file `.spb` and v2 directory `.spb`.

**Why**: The two-UTI approach (separate identifiers for legacy vs v2) doubles the Info.plist surface and confuses Finder when both extensions overlap. A single UTI with permissive read is simpler and matches how Final Cut migrated `.fcpbundle`.

**Alternatives considered**:
- Two-UTI scheme with explicit "legacy" type → more surface, marginal benefit at v0.1.x.
- Stay flat JSON, defer bundle to a later phase → would force a second migration round-trip; fixed schema cost up front is cheaper.

**Reversibility**: medium. Could revert by removing `com.apple.package` from `UTTypeConformsTo`, but any users who have already saved a directory `.spb` would need a manual upgrade. Low risk at v0.1.x install base.

**What I'd revisit if**: Finder ever shows directory `.spb` files as folders rather than packages — would imply the UTI conformance isn't taking effect. Look at `lsregister -dump | grep simpleplayback` for diagnosis.

**Public API impact**:
- `PlayoutProject.formatVersion` now exists; defaults to `currentFormatVersion` (2) on init, decodes as 1 when the field is absent.
- `PlayoutProject.markCurrentFormatVersion()` upgrades a loaded legacy project. Called automatically inside `fileWrapper(ofType:)`.
- `SimplePlaybackProjectDocument.projectData(from:)` is the bundle-or-flat extraction helper exposed for tests.
- `ProjectBundleLayout.projectFilename` ("Show.json") names the central JSON inside the bundle.

---

## 2026-05-07 — B5: contained rewrite vs full driver replacement

**Decision**: Keep `VideoOutputDriver`/`CompositeVideoOutputDriver` as the (deviceID, modeID) primary-output surface used by `OutputSettingsStore` and the existing UI. Reimplement the concrete drivers as thin shims around the new `DeckLinkTransportSink` / `PreviewTransportSink`. Add a `TransportSinkRouter` to `PlaybackController` for *auxiliary* sinks; primary still flows through the driver, but every composed frame and audio block now also fans out to the router's auxiliary sinks.

**Why**: The recommended Phase B order said "contained rewrite that preserves existing behavior while opening the door for the rest." A clean primary→router migration would touch `OutputSettingsStore`, `RootView`, `OutputStatusBar`, the existing `PreviewVideoOutputDriver` test, and `PlaybackController` in one commit — tightly coupled, hard to land green per sub-task. The shim approach gets the same fan-out capability (B11 NDI can register a sink today) at a fraction of the diff, and a future B-phase can fully retire the driver layer in a second pass without breaking the rendering hot path.

**Alternatives considered**:
- Replace the driver layer wholesale with a `VideoOutputDeviceCatalog` + router-as-primary architecture. Rejected — too many touchpoints in one phase, and the existing `PreviewVideoOutputDriver` test would need to change shape.
- Skip auxiliary sinks for now and just ship the `TransportSink` protocol. Rejected — the protocol without a fan-out path is nominal-only; the `PlaybackController` integration is what proves the protocol works.

**Reversibility**: easy. The auxiliary router is purely additive — `PlaybackController.register(sink:)` is a new public API, and existing callers' rendering path is unchanged. Deleting it is a one-commit revert.

**What I'd revisit if**: a second DeckLink port (B6/B7) needs to drive its own primary output — at that point the driver-as-primary cap becomes painful and the catalog/router-as-primary refactor pays for itself. Track this in B6.

**Public API impact**:
- `protocol TransportSink` (sinkID, label, status, isRunning, activeStage, start/stop/submit).
- `struct TransportSinkStage` — Stage parameters as a sink needs them; init from `Stage`.
- `final class TransportSinkRouter` — fan-out + per-sink error capture.
- `PlaybackController.register(sink:)` / `unregister(sink:)` — register an aux sink; auto-starts if output is already running.
