# Phase C — Media pipeline — Summary

**Status (session 23 — 2026-05-08)** — Option-J shared async loader + AudioPump bridge. 4 commits, 730 → 735 tests (+5). One coherent thread:

1. **Option J — `Services/AVTrackLoader.swift` + AudioPump bridge (4 commits, +5 tests)** — collapses the per-site `loadFirstVideoTrackSync` helpers MediaImporter and MediaFlagsInspector each carried (sessions 22) into a single shared async-bridge loader. `AVTrackLoader.loadFirstVideoTrackInspection(url:)` returns an `AVTrackInspection` value-type bundle (`track`, `nominalFrameRate: Float`, `minFrameDuration: CMTime`, `formatDescriptions: [CMFormatDescription]`) loaded in one async hop — `loadTracks(withMediaType: .video)` followed by three concurrent `async let track.load(.nominalFrameRate / .minFrameDuration / .formatDescriptions)` calls — bridged back to sync via `Task.detached` + `DispatchSemaphore` + `@unchecked Sendable` carrier. MediaImporter's `nativeFrameRate(for:)` and `hasVideoTrack(_:)` and MediaFlagsInspector's `inspect(url:)` + `frameRateLooksVariable(...)` all read from the bundle, so the deprecated track-property accessors leave both files. AudioPump picks up a separate `AVTrackLoader.loadFirstAudioTrack(url:)` entry point that returns `(asset, track)` (AVAssetReader requires the asset that owns the track and `AVAssetTrack.asset` is weak); same bridge shape, audio-track reads only. `AVTrackLoaderTests` pin the contract directly (+5 tests).

   The Option-J track-loading deprecation surface listed in the session-22 prompt is now closed. The `AVAssetTrack` *property* deprecation surface (`nominalFrameRate`, `minFrameDuration`, `formatDescriptions`) is also gone from active code paths; those names persist only in `AVTrackInspection` field declarations and doc-comments. Track-loading is uniformly off `tracks(withMediaType:)` across MediaImporter, MediaFlagsInspector, AudioPump, FilmstripGenerator, and FilmstripCoordinator. The remaining Option-J consideration is that future SDK gates may make the deprecation hard errors — consolidating into one shared loader makes that gate a one-file change.

   Audit confirmation: the E3+ Path-1 token-arming surface (`take()` direct, `commitPreparedVideoTransition`, `commitPreparedImageTransition` both branches) and dropping surface (`clear()`, `stopOutput()`) are correctly handled; other `submitFrame` callsites (`renderCurrentVideoFrame` video timer, `renderStillTransitionFrame` still-transition timer, `renderOutgoingHandoffFrame` handoff timer) intentionally do NOT arm — they consume tokens armed by their take-origin (correctly, since they ARE the first composed frame for that take) or run with a nil token. Existing pins (`testClearDropsArmedToken`, `testStopOutputDropsArmedToken`, `testSubsequentSimulationDoesNotRefireSameTake`) cover the contract.

**Still deferred for v1.1.x** — cross-host folder-bookmark scenario rehearsal (sandbox-vs-NAS, security-scoped folder access on a moved bundle).

---

**Status (session 22 — 2026-05-08)** — C8 v1.1 follow-up (folder-bookmark threading through every read path) + Option-J async-bridge sweep (MediaImporter, MediaFlagsInspector, PlaybackController copyCGImage). 7 commits, 725 → 730 tests (+5). Two threads:

1. **C8 v1.1 — folder-bookmark consumer threading (3 commits, +5 tests)** — closes the v1.1 follow-up the session-21 foundation flagged. `PlaybackController.folderBookmarks: [UUID: FolderBookmark]` mirrors to `CompositorPipeline.folderBookmarks` in `didSet` (same lock + invalidation discipline as `bundleMediaDirectory`); `take()`'s resolvedURL call consumes the rung-2 fallback so a folder-renamed source still plays. `TranscodeService.canTranscode` + `TranscodeCoordinator.transcode` gain `folderBookmarks: [UUID: FolderBookmark]` parameters (defaulted empty so legacy callsites compile unchanged). `SlideGridView` palette tiles + the right-click Transcode gate + `ThumbnailLoader.thumbnail(...)` thread the lookup through. RootView publishes `playback.folderBookmarks` from `document.project.folderBookmarks` on `.onAppear` and on every `.onChange` of that array (the same hook recomputes the missing-media banner since the probe consumes the same lookup). The folder-bookmark fallback now fires uniformly across every read path — playback, compositor, transcode, palette tile, pre-show, relink. Test pins: `testTakeResolvesViaFolderBookmarkWhenPerFilePathIsDead`, `testFolderBookmarksAssignmentPersists`, `testFolderBookmarksChangeInvalidatesBugImageCache`, `testCanTranscodeUsesFolderBookmarkFallback`, `testAsyncLoaderResolvesViaFolderBookmark`.

2. **Option J — async-bridge sweep (3 commits, 0 new tests; existing suites pin behavior)** — extends the session-21 ThumbnailGenerator bridge pattern (DispatchSemaphore + `@unchecked Sendable` carrier) to three more sites: `MediaImporter.nativeFrameRate` + `MediaImporter.hasVideoTrack` (single shared `loadFirstVideoTrackSync` helper bridging `loadTracks(withMediaType:_:)`), `MediaFlagsInspector.inspect` (local duplicate of the same helper — both are tiny enough that future merge into a `Services/AVTrackLoader.swift` is a clean follow-up), and `PlaybackController.renderFirstPreparedFrame` (bridges `generateCGImageAsynchronously` for the first-prepared-frame extract; sits on `videoPreparationQueue`, off the render hot path). Public APIs unchanged. Track-property reads (`nominalFrameRate`, `minFrameDuration`, `formatDescriptions`) remain deprecated per SourceKit but xcodebuild build doesn't surface them today — those are the property-level next layer when a future SDK trips the gate.

**Still deferred for v1.1.x** — the Option-J `AudioPump` `tracks(withMediaType:)` site; track-property-level async bridges; cross-host folder-bookmark scenario rehearsal (sandbox-vs-NAS, security-scoped folder access on a moved bundle). *(Session 23 update: AudioPump + track-property bridges shipped — see session-23 entry above.)*

---

**Status (session 21 — 2026-05-08)** — C8 folder-level bookmarks landed as a 5-commit foundation, plus an Option-J ThumbnailGenerator deprecation bridge and the E3+ Path-1 outgoing-handoff race fix. 6 commits, 696 → 725 tests (+29). Three threads:

1. **E3+ Path 1 race fix (1 commit, 0 new tests; behavior pinned by inline doc-comment)** — the late-take token was armed on main inside `commitPreparedVideoTransition` / `commitPreparedImageTransition` *before* the `syncOutput { cancelOutgoingHandoffTimer; submitFrame }` block ran. Between the arm and the syncOutput, the outgoing-handoff timer (started by `stopMediaOnly(preservingMediaForTransition: true)`) could tick on `outputQueue` and submit an outgoing-video frame, consuming the token and firing `onFirstComposedFrameForCue` with `firedAt` ahead of the new cue's actual first composed frame. The late-take detector would record `latency≈0` for what should have been a slow new-cue load. Fix moves arming into the same syncOutput block (or, for the still-transition image path, a `syncOutput { cancelOutgoing… ; arm }` immediately before `startStillTransition`), so the cancel + arm + first submit are atomic relative to the handoff timer. The race is timing-dependent and hard to reproduce deterministically without invasive AVFoundation instrumentation; the in-source doc-comments at the three callsites + the existing test suite (which still passes) are the pin.

2. **Option J — ThumbnailGenerator async-bridge (1 commit, 0 new tests)** — `copyCGImage(at:actualTime:)` was deprecated in macOS 15. The Swift async replacement (`image(at:)`) requires an async context, but `MediaImporter.thumbnailEncoder` is a sync closure and the importer's slide-construction loop is synchronous through every callsite — a straight async migration would ripple through MediaImporter → RootView/ImageSequenceEncoder/TranscodeService and ~25 tests. Used the non-deprecated completion-handler variant `generateCGImageAsynchronously(for:completionHandler:)` and bridged it to a sync result via `DispatchSemaphore` + a small `@unchecked Sendable` box. The semaphore enforces the happens-before relationship that the box doesn't express on its own. Public API unchanged.

3. **C8 folder-level bookmarks foundation (5 commits, 696 → 725, +29 tests across the session)** — closes a v1-deferred Phase C tail item. Five commits land the foundation:

   - **C8-1** — `FolderBookmark` value type (`Identifiable`, `Codable`, `Hashable`); `init(folderURL:label:)` captures the bookmark; `resolvedDirectory(fileExists:)` resolves with bookmark→originalPath fallback. `PlayoutProject.folderBookmarks: [FolderBookmark]` registry. `MediaReference.folderBookmarkID + folderRelativePath` decode-if-present so pre-C8 projects round-trip cleanly. 5 FolderBookmark tests + 4 MediaReference field tests + 2 PlayoutProject round-trip tests.
   - **C8-2** — `MediaResolutionStep.folderBookmark` step + `MediaResolver.resolve(reference:searchRoots:bundleMediaDirectory:folderBookmarks:fileExists:listFiles:fileSize:fingerprintAt:)`. New rung 2 between `.original` and `.contentHash`: when reference has both `folderBookmarkID + folderRelativePath` and the project lookup contains the matching `FolderBookmark`, resolve to `<bookmark.directory>/<relative>` with no walk. `AssetRelinkPlan.plan` treats `.folderBookmark` as `unchangedOnlineSlideIDs`. 5 MediaResolverTests pin the rung's fire conditions and shadowing rules.
   - **C8-3** — `MediaImportContext.folderBookmark + folderRoot` (the two travel together). `MediaImporter.importSlidesAndReport` stamps every direct image/video MediaReference when both are set. `MediaImporter.folderRelativePath(of:under:)` is the pure-logic helper — path-component comparison after URL standardization rejects sibling-prefix collisions (`Show` vs `ShowFootage`) and exact-equality (file == root). PDF/Keynote rasterized slides and image-sequence encoded outputs do NOT pick up the folder bookmark — their media is bundle-internal. 9 new MediaImporterFolderBookmarkTests.
   - **C8-4** — `RootView.addMedia(_:folderURL:)` + `registerFolderBookmark(_:)`. The Add Folder…  path's `confirmFolderImport` calls `addMedia(confirmed.standaloneMediaURLs, folderURL: confirmed.folderURL)`. `registerFolderBookmark` dedupes by `originalPath` so re-imports of the same folder don't accumulate redundant blobs. `currentMediaImportContext` gains optional `folderBookmark + folderRoot` parameters; default-nil callers are unchanged.
   - **C8-5** — `MediaReference.resolvedURL(bundleMediaDirectory:folderBookmarks:)` overload re-implements the rung-2 logic at the model layer so the playback-shaped read paths can consume the bookmark without going through the full resolver. Existing single-arg / bundle-only overloads forward with `[:]`. `AssetLibraryProbe.makeIsOnline/makeResolveURL` gain folderBookmarks-aware overloads; bundle-only overloads forward. `AssetRelinkPlan.liveResolve(folderBookmarks:bundleMediaDirectory:)` is a factory closure RootView passes to `chooseRelinkFolderAndApply`. `RootView.projectFolderBookmarkLookup()` builds the dict from current project state on each call. 2 new MediaReferenceTests pin the rung-2 recovery + nil-on-empty-lookup short-circuit.

**Still deferred for C8 (v1.1 follow-up)** — threading `folderBookmarks` through `PlaybackController.bundleMediaDirectory`, `CompositorPipeline.bundleMediaDirectory`, `TranscodeService.canTranscode/source-URL lookup`, and `SlideGridView` palette thumbnails. Today these read via the bundle-only `resolvedURL(bundleMediaDirectory:)` overload — folder-bookmark fallback fires for pre-show check and Locate Folder relink only. A clip moved within its imported folder will play correctly after the operator re-opens the project (the new bookmark+relative path were stamped at import) but a *live* in-place rename still triggers a missing-media offline-banner until pre-show or the relink Fix runs. Bundle-aware threading mirrored the C7d pattern (one PR per consumer); folder-bookmark threading repeats it once the consumer-side surfaces are needed.

---

**Status (session 20 — 2026-05-08)** — Phase C close-out tail. 7 commits, 680 → 696 tests (+16). Three threads:

1. **Deferred reviewer-finding hardening sweep (3 commits, +11 tests)** — closes the three P1s session 19 left open: MediaResolver early-exit for unfingerprinted references; Debouncer + recomputeAssetLibraryStatus collapse on slide-change bursts; AssetRelinkPlan kind inference from bundle-Media URL containment. Phase C P1 surface is now empty.
2. **C11-3 importer hook + filmstripRootDirectory (1 commit, +3 tests)** — `MediaImportContext.enqueueFilmstrip` closure auto-fires for video imports; `RootView.filmstripRootDirectory()` mirrors `thumbnailRootDirectory()` (bundle-relative when saved, App Support per-session for untitled); `ProjectBundleLayout.filmstripsDirectory = "Cache/Filmstrips"`. Cache populates ahead of the UI consumer landing.
3. **Option J — async AV API modernization (2 commits, +1 test)** — FilmstripGenerator + FilmstripCoordinator off `tracks(withMediaType:)` / `duration` / `copyCGImage(at:actualTime:)` to `loadTracks(withMediaType:)` / `load(.duration)` / `image(at:)`. The per-frame extraction loop honors `Task.checkCancellation()` between frames; CancellationError is caught at the coordinator and silently drops the job. SlideGridView's poster-frame loader picks up the same migration since it was already inside a `Task.detached`. Remaining deprecated AV sites (ThumbnailGenerator, PlaybackController, MediaImporter) sit on synchronous callers (palette render, video timer, import inline) where async migration ripples wider; deferred.

**C11-4 cue-inspector scrub UI consumer is filed as a product blocker** in `docs/blockers.md` — needs operator-visible UX choice (static-strip vs drag-scrub vs click-to-set-inPoint, inspector placement, missing-cache regenerate affordance).

---

**Status (session 19 — 2026-05-08) — C16 Phase C close-out + C11 partial + Path 1 late-take**. Phase C is declared complete for v1. 8 commits this session, 657 → 680 tests (+23). The session bundled three discrete pieces:

1. **C16 close-out (3 commits, +2 tests)** — code-reviewer pass against the full Phase C diff (`48a8b0a..HEAD`, 17,500+ lines across 100+ files) surfaced six P1 findings; three folded in as correctness/safety hardening (compositor sync race, BundleForTravel partial-copy leak, MediaReference bookmark fileExists). Three deferred to a future hardening sweep, documented inline. C16 doc consolidates the Phase C surface and 13-step manual rehearsal checklist.
2. **E3+ Path 1 callback upgrade (2 commits, +6 tests)** — adds `PlaybackController.onFirstComposedFrameForCue` callback fired exactly once per take when the first composed frame reaches `submitFrame`. ShowController switches its late-take detector source from `playback.$liveSlideID` to the new callback, closing the image-cue limitation in the Path 2 proxy. Documented in `phase_e_summary.md`.
3. **C11 partial — generator + coordinator (2 commits, +15 tests)** — `FilmstripGenerator` pure-logic sprite-sheet PNG + `FilmstripCoordinator` background-queue state machine. UI / import-hook / scrub-view consumer deferred to a future session that lands the inspector surface alongside.

### C16 — Code-reviewer P1 fixes folded in this session

### C16 — Code-reviewer P1 fixes folded in this session

- **`CompositorPipeline.bundleMediaDirectory` race** — synchronize the property through the existing `cacheLock`. Previously a plain `var` was read off the playback `outputQueue` while being written on main; reading a heap-typed `URL?` without synchronization is undefined behavior and the resolved-URL cache key was coupled to the value. Setter now swaps and invalidates atomically. Pin: existing `testBundleMediaDirectoryChangeInvalidatesBugImageCache` still holds.
- **`BundleForTravelCoordinator` partial-copy leak** — when `FileManager.copyItem` throws (out-of-space, source vanished mid-copy), it can leave a partial file at the destination. Add a `removeItem(destination)` call in the failure catch block before flipping to `.failed`. Mirrors `TranscodeJob.removePartialFileIfNeeded`. Pin: `testFailedCopyClearsPartialDestinationBeforeReportingFailure` asserts the contract — pre-copy clear-stale + post-failure cleanup are both `removeItem` calls.
- **`MediaReference.resolvedURL(bundleMediaDirectory:)` bookmark branch** — gate the bookmark-resolves-to-deleted-file path on `FileManager.default.fileExists(atPath:)`. Pre-fix, `URL(resolvingBookmarkData:...)` would return a stale URL pointing at a deleted file, and `TranscodeService.canTranscode` (which only checked `resolvedURL(...) != nil`) treated that as "online." Pin: `testResolvedURLReturnsNilWhenBookmarkResolvesToDeletedFile` builds a bookmark over a real file, deletes the file, and asserts `resolvedURL()` returns nil.

### C16 — Reviewer findings folded in during session 20 hardening sweep

All three deferred findings closed. 3 commits, +12 tests.

- **`MediaResolver` short-circuits unfingerprinted references before the search-root walk.** Pre-C7 (legacy) references have nil fingerprint → both `storedHash` and `storedSize` are nil → rung 2 (content hash) and rung 3 (name + size) both require stored values and can never match. The fix returns `.offline` before enumerating any roots; on a 500-slide deck this changes O(slides × roots × files) syscalls to zero. Pin: `testSkipsSearchRootWalkWhenReferenceHasNoFingerprint` puts an `XCTFail` in the listFiles closure so a regression that re-introduces the walk fails loud.
- **`Services/Debouncer.swift` coalesces slide-change recompute bursts.** New `@MainActor` class wraps a `Task` cancellation handle with a configurable interval (250 ms in the asset-library path). `RootView.onChange(of: project.slides)` now routes through `assetLibraryRecomputeDebouncer.schedule { ... }`; the `.onAppear` and bundle-URL change call sites still recompute immediately so the banner doesn't lag a save-as. A 500-slide drag-reorder collapses to one `AssetLibraryProbe.evaluate` call instead of 500. 4 tests cover burst-collapse, cancel-drops-pending, single-fire after interval, and the injected-sleep test seam.
- **`AssetRelinkPlan.apply` infers kind from bundle-Media containment.** New `bundleMediaDirectory` parameter (defaults to nil for backward compat with untitled-document callers). `inferKind(existing:newURL:bundleMediaDirectory:)` is exposed as a static helper so the per-slide Locate context menu (which doesn't go through `apply`) gets the same rule. Path-component descendant check rejects sibling-with-shared-prefix directories (`Media` vs `MediaCache`) and the bundle directory itself. RootView's `chooseRelinkFolderAndApply` and `relinkSlideViaOpenPanel` both pass the live bundle URL. 6 new pin tests cover nil-bundle, inside-bundle, outside-bundle, sibling-prefix collision, exact-equality edge case, and end-to-end apply() semantics for both directions.

### C16 — Phase C feature inventory (what shipped over Sessions 6–19)

**Codec inspector and pipeline flags**

- C1 long-GOP / VFR / 10-bit 4:2:0 / untagged-color flags via `MediaFlagsEvaluator` and `MediaFlagsInspector`; populated at import; rendered as `MediaFlagWarningChip` rows below the FPS conformance warning in the cue inspector.
- B8 `PlayoutProject.recommendsTenBitOutput` (Phase B reuse — keys off `flags.tenBitYUV420`).

**Importers**

- C3 PDF rasterize-on-import via PDFKit at output × 2 → `<bundle>/Cache/Renders/`.
- C6 Keynote `.key` → AppleScript export to PDF → bitmap rasterize. `NSAppleEventsUsageDescription` + `com.apple.security.automation.apple-events` entitlement.
- C4 animated GIF / APNG detection → ProRes 4444 leads in right-click menu.
- C5 image-sequence detection (`name.NNN[N].ext`, 3- or 4-digit counters, multi-dot basenames, gaps) + ProRes 4444 encode via `AVAssetWriter`.
- C5c folder-drop UX with per-sequence frame-rate confirm sheet (24 / 25 / 30 / 48 / 50 / 60 + custom integer); standalone files routed through `MediaImporter`, sequences through `ImageSequenceEncodeCoordinator`.

**Transcode pipeline**

- C2 right-click ProRes 422 / 4444 transcode action; `TranscodeService` + `TranscodeCoordinator` + `Transcoded/` bundle layout; non-modal progress strip.
- Inline transcode chip on the cue inspector flag warnings (Show-Mode-gated).
- Animated-image presets order ProRes 4444 first; widened `canTranscode` to animated images.
- Partial-file cleanup on cancel (C2/C5c gap close).

**Asset library — C7**

- C7a `AssetFingerprinter` (CryptoKit SHA-256 streaming, 1 MiB chunked) + `MediaAssetFingerprint { contentHash, size, mtime }`.
- `MediaReference.kind: .linked | .managed` and `MediaReference.fingerprint`; legacy projects decode-if-present.
- C7b importer-time fingerprint population (failure non-blocking).
- C7c `MediaResolver` waterfall — bookmark/originalPath → contentHash search → name+size search → offline.
- C7d Bundle for Travel — `BundleForTravelPlan` (filename-collision dedup, already-managed skip, offline skip), `BundleForTravelCoordinator` (state machine + injectable I/O seams), `BundleForTravelSheet` (idle plan summary → progress → result), toolbar action gated on saved bundle.
- Bundle-aware `MediaReference.resolvedURL(bundleMediaDirectory:)` overload + `MediaResolver.bundleMedia` rung 0 + `AssetLibraryProbe.makeIsOnline(bundleMediaDirectory:)` so a moved bundle's managed assets play.
- Session-18 punch list close-out — `CompositorPipeline.bundleMediaDirectory`, `TranscodeService.canTranscode(slide:bundleMediaDirectory:)`, `BundleURLObserver` Save-As symmetry, threading the bundle dir through palette + cue inspector.
- Session-19 hardening (this session) — atomic property synchronization, partial-copy cleanup, bookmark fileExists check.

**Missing-media UX — C9**

- C9 first slice — `AssetRelinkPlan` pure-logic plan + apply over `MediaResolver`. Pre-Show `media.files` row Fix handler opens NSOpenPanel and applies the plan project-wide; empty match surfaces via the import-status banner.
- C9 second slice — per-slide right-click → Locate… in `SlideGridView` for one-shot file picks.
- C9 third slice — persistent missing-media banner above `OutputStatusBar` (`MissingMediaBannerView`), recomputed on slide mutation. Shows offline-count without requiring Pre-Show.

**Thumbnails — C10**

- `ThumbnailGenerator` 320×180 JPEG (~10 KB at quality 0.75); image branch via NSImage/NSBitmapImageRep, video branch via `AVAssetImageGenerator` at `.zero` with `requestedTimeToleranceBefore/After = .positiveInfinity`.
- `MediaImporter.thumbnailEncoder` static-var seam writes `<bundle>/Cache/Thumbnails/<slide.id>.jpg` for every direct image/video import + every PDF/Keynote rasterized page. Failures silent.
- `SlideGridView` offline fallback — live source URL first, then `<dir>/<slide.id>.jpg` synchronously. Palette grid renders even after the source is gone.

**Import status banner**

- `ImportStatusBanner` ObservableObject + view rendered above `OutputStatusBar`. Routes PDF / Keynote / unsupported / transcode (non-cancel) failures and is the single uniform non-modal failure surface.
- Apple-events deep-link button on Keynote-import failures (Option E session 12).
- Modal `Keynote not installed` `NSAlert` removed (C-banner-c, session 11).

### C16 — Consolidated manual rehearsal steps for Phase C

Run these on real operator media before promoting Phase C to "production-ready." Each step exercises a code path that was unit-tested but never run against the variety of real-world inputs that production media brings.

1. **Codec inspector flags** — import a long-GOP H.264 clip, a 10-bit HEVC Main-10 clip, a VFR phone clip, and a clip with NCLC tags missing. Verify the cue inspector renders one yellow chip per applicable flag below the FPS warning. The 10-bit chip should also turn on the Output inspector's "10-bit recommended" hint via B8.
2. **PDF import** — import a multi-page PDF whose pages mix portrait and landscape and contain at least one heavy-vector page. Verify rasters land in `<bundle>/Cache/Renders/<slide.id>.png` at output × 2, the palette tiles render the rasters, and a re-save of the project doesn't re-rasterize.
3. **Keynote import** — import a `.key` file on a machine with Keynote installed. Verify the AppleScript prompt fires the first time and the import completes. Then import on a machine where Keynote is uninstalled — verify the import-status banner shows the "Keynote not installed" failure (no modal alert).
4. **Animated GIF** — import a multi-frame GIF and an animated PNG. Right-click → Transcode menu should lead with ProRes 4444 (not 422). Run the transcode and verify the resulting `.mov` plays smoothly with frames preserved.
5. **Image sequence** — drop a folder containing `frame.0001.png` … `frame.0240.png`. Verify the Add Folder sheet groups them into one sequence; pick 30 fps; confirm; verify the resulting ProRes 4444 `.mov` plays at the right rate.
6. **ProRes transcode** — right-click an H.264 clip → Transcode to ProRes 422. Verify the non-modal progress strip ticks, a sibling slide is appended on success, and the source slide's flag chip disappears (it now has a `.movsibling).
7. **Asset fingerprinting + relink** — import a clip, save the project, move the file to a new directory, reopen. Pre-Show `media.files` row should show "1 offline." Use Locate Folder → pick the new parent directory → relink applies and the file is found by content hash + name+size.
8. **Per-slide Locate** — for a single offline slide, right-click → Locate… → pick the new file. Verify the slide rebinds with a refreshed fingerprint (not stale).
9. **Bundle for Travel cross-host** — bundle a project on machine A (toolbar → Bundle for Travel → confirm), copy the entire `.splayback` bundle to machine B, open it. Verify managed assets play, compositor overlays render, palette thumbnails light up (live + offline-fallback paths), and the right-click "Transcode to ProRes" stays enabled for managed sources. Verify the missing-media banner doesn't false-positive.
10. **Save-As of untitled** — open a new doc, drop a clip, Save-As to a new bundle URL. Verify the asset-library banner doesn't flicker between offline / online; managed playback (after Bundle for Travel) resolves via the new bundle's `Media/` on the next take.
11. **C10 thumbnails offline path** — import a clip, save the project, delete the source from disk, close-and-reopen the project. Palette tile should still render the cached poster instead of the placeholder icon.
12. **Bundle for Travel partial-copy cleanup (session-19 fix)** — fill the destination disk to within a few MB, kick a Bundle for Travel pass, observe the failure banner. Verify the destination directory does NOT contain a truncated copy of the file that failed to copy.
13. **Stale-bookmark recovery (session-19 fix)** — open a project whose bookmarked source files have been moved/deleted on the host machine without project-side relink. Verify the offline-count banner is correct (every stale bookmark is reported), `TranscodeService.canTranscode` is False (right-click menu hides Transcode), and `Locate…` finds the new path.

### C16 — What's scoped out of v1 Phase C

- **C8 — folder-level bookmarks for batch imports.** Today every imported file gets its own security-scoped bookmark; for folder imports (C5c), a 50-clip folder produces 50 bookmark blobs in the project file. The spec implies a folder-level bookmark + per-file relative path. Architectural change — adds a `FolderBookmark` model, modifies `MediaImporter` to opt into folder-mode when the source is a single parent directory, and the resolver gains a fallback rung that joins folder-bookmark + relative path. Bigger than C7d (3-5 commits over 1-2 sessions). Filed.
- **C11 — filmstrip thumbnail sprite-sheets (background queue).** Generator + coordinator landed in session 19 (see C11 section below). Remaining for a future session: import-time auto-enqueue hook in `MediaImporter`, RootView wiring of the bundle-relative output dir (mirroring `thumbnailRootDirectory()`), inspector-bound scrub UI consumer.
- **C12 — audio engine refactor.** 48 kHz / 32-bit float, 8 internal channels, routing matrix. Substantial; deserves its own sub-phase.
- **C13 — audio cue types.** Embedded, audio-only cue, background bed.
- **C14 — per-cue audio.** Volume, mute, fade-in/out, crossfade override, varispeed with pitch correction.
- **C15 — SRT/WebVTT subtitle sidecar render.** Subtitle layer in compositor.

The audio block (C12-C15) is large enough to be its own pickup. C8 is an autonomy-friendly Phase C tail task. C11 is half-landed and the remaining tail (UI integration) is the natural pickup once a scrub surface design exists.

### C11 — What landed in session 19 (generator + coordinator)

- **C11-1 — `Services/FilmstripGenerator.swift` pure-logic.** `generateSpriteSheet(for:frameCount:columns:frameSize:)` produces a sprite-sheet PNG with `frameCount` evenly-distributed thumbnails across the video duration, composed in a fixed-grid layout. Defaults: 24 frames (6 cols × 4 rows), 160×90 per cell → 960×360 sprite (~50 KB at typical-content compression). Centered sample distribution (`D × (i + 0.5)/N`) avoids decode-at-EOF failures. Pure-logic helpers `sampleTimestamps(durationSeconds:frameCount:)` and `gridPixelSize(frameCount:columns:frameSize:)` exposed for tests. 10 tests including an end-to-end pin against a 30-frame H.264 movie built via AVAssetWriter (mirrors `TranscodeServiceTests` fixture pattern).
- **C11-2 — `Services/FilmstripCoordinator.swift` background queue.** `@MainActor ObservableObject` mirrors `BundleForTravelCoordinator` / `TranscodeCoordinator` shape. `enqueue(slideID:sourceURL:destinationURL:...)` hops the synchronous extraction loop to `Task.detached`, completes on main with `.completed(URL)` or `.failed(FilmstripGenerator.Failure)`. De-dupe — one job per `slideID`, repeated enqueues while running are no-ops. Cancellation deferred for v1 (typical 24-frame jobs finish under a second). Injectable `generator` + `writer` static seams for test isolation. 5 tests cover success, repeated-enqueue no-op, generator failure passthrough, writer failure as `.encodingFailed`, distinct-slides-run-concurrently.
- **What's deferred** — auto-enqueue at video import time (a thin `MediaImporter` hook similar to C10's `thumbnailEncoder` seam), RootView's `filmstripRootDirectory()` mirroring `thumbnailRootDirectory()`, and the actual scrub-UI consumer in the cue inspector. The natural pickup ships these together since each requires a clear UI surface decision.

### C16 — Test inventory at Phase C close

659 tests total at HEAD on `development`. Phase C-direct test files (file count and approximate test counts):

- `MediaFlagsEvaluatorTests.swift` (~10), `MediaFlagsInspectorTests.swift` (~6), `MediaImporterTests.swift` (~12), `MediaImporterKeynoteTests.swift` (~5), `MediaImporterPDFTests.swift` (~4), `MediaImporterAnimatedImageTests.swift` (~4), `MediaImporterThumbnailTests.swift` (4)
- `PDFImporterTests.swift` (~8), `KeynoteImporterTests.swift` (~9), `AnimatedImageInspectorTests.swift` (~5)
- `ImageSequenceDetectorTests.swift` (~9), `ImageSequenceEncoderTests.swift` + `ImageSequenceEncodeCoordinatorTests.swift` (~10), `AddFolderImporterTests.swift` (7), `PendingFolderImportTests.swift` (7)
- `TranscodeServiceTests.swift` (~14), `TranscodeCoordinatorTests.swift` (~10)
- `AssetFingerprinterTests.swift` (~5), `MediaResolverTests.swift` (~17 incl. session-19 stale-bookmark pin), `AssetRelinkPlanTests.swift` (~6), `AssetLibraryProbeTests.swift` (~6)
- `BundleForTravelPlanTests.swift` (~6), `BundleForTravelCoordinatorTests.swift` (~6 incl. session-19 partial-copy pin)
- `ThumbnailGeneratorTests.swift` (4), `SlideGridViewThumbnailFallbackTests.swift` (4)
- `CompositorPipelineTests.swift` (~6 incl. C7d bundle-dir invalidation pin)
- `ImportStatusBannerTests.swift` (~4)

Phase D / Phase E interaction tests (`PreShowCheckTests`, `PreShowCheckFixHandlersTests`, `ShowControllerLogTests`, `ShowControllerLateTakeLogTests`, etc.) reuse Phase C primitives but are out of scope here.

---

**Status (session 18 — 2026-05-08)**: Closed the session-17 C7d punch list (P1 read-side bundle-aware resolution + Save-As bundle-dir refresh) and shipped **C10 embedded poster-frame thumbnails** end-to-end. 4 commits in C7-finalization + 3 commits in C10. 645 → 657 tests (+12); 637 → 657 across the full session counting the late-take live integration in Phase E (+20). Shape mirrors session-17 — pure-logic service + thin host wiring + a small UI surface per commit.

- **Z1 (C7 punch list)** — Bundle-aware resolution threaded through every read path that the C7d landing missed:
  - `CompositorPipeline.bundleMediaDirectory: URL?` with `didSet` invalidating the bug-image cache. Default resolver + cache key both go through `resolvedURL(bundleMediaDirectory:)`.
  - `PlaybackController.bundleMediaDirectory.didSet` mirrors to the compositor — one source of truth drives both primary take and overlay resolution.
  - `TranscodeService.canTranscode(slide:bundleMediaDirectory:)` + `TranscodeCoordinator.transcode(...bundleMediaDirectory:)` so re-transcode finds managed sources on a moved bundle.
  - `SlideGridView` (palette thumbnails + right-click menu) and `CueInspectorView` (inline transcode-eligibility chip) both thread the bundle dir.
  - Tests: `CompositorPipelineTests.testBundleMediaDirectoryChangeInvalidatesBugImageCache`; `TranscodeServiceTests.testCanTranscodeUsesBundleMediaDirectoryForManagedSlides`.

- **Z2 (C7 punch list)** — `BundleURLObserver` (small ObservableObject) owned by `SimplePlaybackProjectDocument`, republished from the existing fileURL KVO observer alongside `lockController.evaluate`. RootView's `.onChange(of: bundleURLObserver.bundleURL)` refreshes both `playback.bundleMediaDirectory` and the C9 missing-media banner. Symmetry with how the lock controller already reacts to fileURL changes; an untitled document saved-as no longer keeps the cached `nil` until reopen.

- **C10-1** — `Services/ThumbnailGenerator.swift` pure-logic. `generateJPEG(for:mediaKind:size:quality:)` produces a 320×180 JPEG (~10 KB at quality 0.75). Image branch: `NSImage(contentsOf:)` + `NSBitmapImageRep`. Video branch: `AVAssetImageGenerator` at `.zero` with `requestedTimeToleranceBefore/After = .positiveInfinity` so `.zero`-rejecting clips still yield their first frame. Tests cover JPEG magic-byte prefix, source-not-readable error, and quality-propagation sanity check (4 cases).

- **C10-2** — `MediaImportContext` gains optional `thumbnailRootDirectory`; `MediaImporter.thumbnailEncoder` static-var seam writes `<dir>/<slide.id>.jpg` for every direct image/video import + every PDF/Keynote rasterized page (new `imageSlidesWithThumbnailCache` helper). Thumbnail failures silent — encoder returning nil or a write error never blocks an import. `ProjectBundleLayout.thumbnailsDirectory = "Cache/Thumbnails"`. Tests: `MediaImporterThumbnailTests` (4 cases — happy-path JPEG write, nil-directory skip, nil-encoder safe, kind passthrough).

- **C10-3** — `RootView.thumbnailRootDirectory()` (bundle-relative when saved, App Support per-session for untitled — mirrors `renderRootDirectory()` shape). `SlideGridView.thumbnailCacheDirectory` parameter; `ThumbnailLoader.thumbnail(for:bundleMediaDirectory:thumbnailCacheDirectory:)` tries the live source URL first and falls back to `<dir>/<slide.id>.jpg` synchronously. Tests: `SlideGridViewThumbnailFallbackTests` (4 cases — sidecar present, missing dir, nil dir argument, async loader fallback).

What's still deferred for Phase C: **C8 folder bookmarks**; **C11 filmstrip sprite-sheets** (background queue — pairs with C10 once a video-scrub UI exists); **C12–C15 audio**. **C16 Phase C summary + manual rehearsal steps** is the wrap-up; Phase C is at a natural boundary now and the next session can declare it closed before tackling C8 / C11 / audio in their own pickups.

### Manual verification needed (session 18 deltas)

- **Bundle for Travel cross-host** — bundle a project on machine A, copy to machine B, open. The session-17 sub-bullets still apply; session 18 additionally proves that compositor overlays render against managed assets, the palette grid lights up (live thumbnails AND offline-fallback path), and the right-click "Transcode to ProRes" stays enabled for managed video sources.
- **Save-As of untitled** — open new document, drop a clip, Save-As to a new bundle URL. The asset-library banner should not flicker between offline / online; managed playback (after Bundle for Travel) should resolve via the new bundle's Media/ on the next take.
- **Late-take detection** — record a show with intentionally slow video loads (large H.264 from a slow disk). The show log should accumulate `.lateTake` entries with `latency=Nms cue=…` for cues where the load exceeded 150 ms. Image cues will not log late takes (proxy limitation).
- **C10 thumbnails offline path** — import a clip, save the project, delete the source from disk, close-and-reopen the project. Palette tile should still render the cached poster instead of the placeholder icon.

---

**Status (session 17 — 2026-05-08)**: **C7d Bundle for Travel landed end-to-end**. Phase C is now C1–C7 + C-banner + C9 first/second slice complete; remaining is C8 (folder bookmarks), C9 persistent banner, C10/C11 (thumbnails), C12-C15 (audio). 4 commits, 599 → 625 tests (+26). The shipped pieces:

- **C7d-1** — `Services/BundleForTravelPlan.swift` pure-logic plan + apply. `plan(slides:resolve:fileSize:)` walks linked slides through the C7c resolver, classifies each as `operations` (copyable), `alreadyManagedSlideIDs` (skipped — already in `<bundle>/Media/`), or `offlineSlideIDs` (unresolvable). Filename-collision dedup via `BundleForTravelPlan.uniqueFilename(for:claimed:)` — first claimant keeps the unsuffixed name, subsequent collisions get `-1`, `-2`, … inserted before the extension. `apply(plan:to:mediaDirectoryURL:fingerprint:)` rebuilds each operation's `MediaReference` at `<mediaDirectoryURL>/<destinationFilename>`, flips `kind` to `.managed`, and refreshes the fingerprint. `ProjectBundleLayout.mediaDirectory = "Media"` per spec §3.17.
- **C7d-2** — Managed-aware `MediaResolver`. New `MediaResolutionStep.bundleMedia` rung 0; `resolve(bundleMediaDirectory:)` short-circuits to `<bundleMediaDirectory>/<basename>` for `.managed` references when the host supplies the bundle URL. Linked references ignore the hint. `AssetRelinkPlan.plan` treats `.bundleMedia` as "unchanged online".
- **C7d-3a** — `Services/BundleForTravelCoordinator.swift` `@MainActor ObservableObject` state machine: `.idle → .running(BundleForTravelProgress) → .finished(plan) | .failed(BundleForTravelError) | .cancelled`. Sequential per-operation copy on `Task @MainActor`; cancel flag checked between operations (active copy completes). Injectable `copyFile / ensureDirectory / removeItem` static seams.
- **C7d-3b** — `Views/BundleForTravelSheet.swift` (idle plan summary → progress bar with current filename → result row) plus toolbar "Bundle for Travel" button gated on a saved bundle URL. RootView's `presentBundleForTravelSheet` runs the plan synchronously against `project.slides` (passing the bundle Media/ URL so already-bundled assets register as `.bundleMedia`); confirm kicks the coordinator and on success applies the plan to `project.slides`.
- **C7d-3c** — Bundle-aware playback + pre-show. `MediaReference.resolvedURL(bundleMediaDirectory:)` overload — for `.managed`, prefers `<bundleMediaDirectory>/<basename>` before the bookmark/path waterfall. `PlaybackController.bundleMediaDirectory: URL?` published, set by RootView on appear. `AssetLibraryProbe.makeIsOnline(bundleMediaDirectory:)` + `makeResolveURL(bundleMediaDirectory:)` — host-injectable bundle-aware probes; the pre-show `media.files` row now correctly classifies a moved bundle's managed assets as online instead of offline.

What's still deferred for Phase C: **C8 folder bookmarks**; **C10/C11 thumbnails**; **C12-C15 audio**. **C16 Phase C summary + manual rehearsal steps** is the wrap-up. The C9 persistent missing-media banner above OutputStatusBar shipped in session 17 (`Views/MissingMediaBannerView.swift` + `RootView.recomputeAssetLibraryStatus` on slide changes).

### Known C7d gaps (session-17 code-review punch list)

These are P1-grade, not P0 — Bundle for Travel ships safely as v1 — but a future session should close them before promoting C7 to "done-done":

- **Read-side bundle-aware resolution gap.** `MediaReference.resolvedURL(bundleMediaDirectory:)` was wired into `PlaybackController.take` and `AssetLibraryProbe`'s pre-show closures, but several other read paths still call the bundle-unaware `resolvedURL()`: `CompositorPipeline` (overlays + cache key), `SlideGridView` (palette thumbnails), `TranscodeService.canTranscode` + the source-URL lookup, and `RootView` post-relink callsites. Same-machine bundles work fine; a *moved* bundle's managed assets play correctly but compositor-overlay text-rendered slides, palette thumbnails, and re-transcode actions break. Threading `bundleMediaDirectory` to those sites — or introducing a single `MediaSlideResolver` helper that all read paths go through — is the correct fix. Filed as a follow-up on top of C7d.
- **Save-As doesn't refresh `playback.bundleMediaDirectory`.** Set once in `RootView.onAppear`. A document saved-as from untitled keeps the cached `nil` until re-open; managed playback would still resolve via the post-apply absolute path on the same machine, so the impact is bounded, but the symmetry with `lockController.evaluate(bundleURL:)` in `SimplePlaybackProjectDocument`'s `fileURL` observer is what we want. Add the same observer hook for the playback controller's bundle dir.
- **`BundleForTravelCoordinator` copy loop blocks main actor.** Acceptable for v1 (typical show-size files copy in seconds), already documented inline in `BundleForTravelCoordinator.swift`'s class doc-comment. A future iteration should hop the per-file copy to `Task.detached`; the existing static-closure test seam needs `@Sendable`-aware refactoring to do this without regressing `BundleForTravelCoordinatorTests`.
- **`recomputeAssetLibraryStatus` runs on every slide mutation.** `AssetLibraryProbe.evaluate` is pure logic but each call does a `FileManager.fileExists` syscall per slide. A 500-slide drag-reorder triggers 500 stats per tick. The pure-logic walk is O(slides) and the syscalls are the hot path; a debounce or a "filesystem-state didn't change" memoization is the right fix. Out of scope for session 17.
- **`LateTakeDetector` clock-skew handling.** Negative-latency frames currently return nil *and leave pending*, so a subsequent same-slide frame can still close the verdict. The integration session must use the same clock source for `firedAt` and `frameAt` (both `Date()` or both `mach_absolute_time` via a single converter). Documented in the type's doc-comment.

**Status (session 16 — 2026-05-08)**: **C7 core landed + C9 first slice**. Session 16 picked off the largest remaining Phase C item — the asset-library data model that unblocks C8/C9/C10/C11 and the deferred E2 `media.resolution` Fix. 7 commits, 543 → 599 tests (+56). The shipped pieces:

- **C7a** — `Services/AssetFingerprinter.swift` (CryptoKit-backed SHA-256 streaming fingerprinter, 1 MiB chunked so multi-GB ProRes files don't load into RAM); `MediaAssetFingerprint { contentHash, size, mtime }` value type. `MediaReference` gains decode-if-present `kind: .linked | .managed` and `fingerprint: MediaAssetFingerprint?` fields; legacy projects default to linked + nil.
- **C7b** — `MediaImporter.fingerprinter` static-var test seam; every direct image/video import + every PDF/Keynote rasterized page now carries an importer-time fingerprint. Fingerprint failure is non-blocking (the slide is still imported with `fingerprint = nil`).
- **C7c** — `Services/MediaResolver.swift` pure-logic waterfall: bookmark/originalPath → contentHash search across operator-supplied roots → name+size search → offline. Every I/O dependency injected; live wrapper uses `FileManager.default.enumerator`. The first hash-match wins; size pre-filter avoids hashing wrong-sized candidates. Foundation for C9 banner UX, the C7d Bundle for Travel pass, and the just-shipped relink Fix handler.
- **AssetLibraryProbe + Pre-Show `media.files` row** — pure-logic probe that walks slides via `slide.media.resolvedURL()` + `FileManager.fileExists`, plus stale-fingerprint detection (1 s mtime tolerance to survive HFS+/SMB precision drift). Pre-show check renders offline as error, stale as warning; offline eclipses stale when both are present.
- **C9 first slice — relink-folder Fix handler** — `Services/AssetRelinkPlan.swift` pure-logic plan + apply (rebuilds `MediaReference` per relinked file, refreshes the fingerprint, preserves `.managed` vs `.linked` kind). RootView's Pre-Show `media.files` row now has a Fix button that opens NSOpenPanel and applies the plan to `project.slides`. Empty match surfaces via the existing import-status banner so the click never reads as a no-op.

What's still deferred for C7+: **C7d Bundle for Travel** (copy linked into `<bundle>/Media/`, flip kind to managed); **C8 folder bookmarks**; **C9 persistent banner above OutputStatusBar** (today the relink path is reachable only via Pre-Show); **C9 per-slide Locate context menu** for one-shot file picks; **C10/C11 thumbnails**; **C12-C15 audio**.

**Status (session 12 — 2026-05-08)**: **C5c shipped end-to-end** (Add Folder…  toolbar + folder-walk pure-logic + per-sequence frame-rate confirm sheet + encode kickoff + sibling-slide splice + unified background-jobs progress strip alongside C2 transcodes). Plus three small reconciliations: **Show-Mode gate on inline transcode button** (Option B — `CueInspectorView.showMode` parameter mirrors SlideGridView's `transcodeEnabled`), and **Apple-events deep-link button** on the import-status banner (Option E — when any failure has `kind == .keynoteImport`, the details popover renders a one-click jump to System Settings → Privacy & Security → Automation, closing the loop on the most opaque `.key` import failure mode). 5 commits; 359 tests, all green (was 341 at session start; +18). **No frame-rate default is committed at any layer** — operators pick per import via the sheet picker (preset menu 24/25/30/48/50/60 + custom integer field). Phase C feature scope is now substantially complete (C1–C6 + C-banner all in); C7+ asset library / audio / subtitles remain.

**Status (session 11 — 2026-05-08)**: C5b shipped end-to-end (`ImageSequenceEncoder` + `ImageSequenceEncodeCoordinator` — AVAssetWriter wrapping ProRes 4444). Plus three reconciliations: **C-banner-c** (modal "Keynote not installed" alert dropped — banner is the single failure surface), **inline transcode button** on the cue inspector flag chips (closes the C2/C4 chip → action gap), and **B8 logic** (`PlayoutProject.recommendsTenBitOutput` pure-logic computed property + Output inspector hint, now genuinely unblocked by C1's `tenBitYUV420` flag). 5 commits; 341 tests, all green (was 323 at session start; +18). C5c (folder-drop UX) is the next pickup, gated only on the operator-supplied frame-rate default decision.

**Status (session 10 — 2026-05-08)**: C4 shipped end-to-end (animated GIF / APNG detect + ProRes 4444 default in right-click menu), Import Status Banner shipped across PDF / Keynote / transcode failure surfaces, and C5a (ImageSequenceDetector pure-logic) shipped. 323 tests, all green (was 269 at session start; +54). 6 new commits on `development` (C4a / C4b / C4c / C-banner-a / C-banner-b / C5a). The C2c right-click action and the silent-failure plumbing across PDF / Keynote / Transcode are now reconciled — every operator-visible failure mode reaches a non-modal banner instead of disappearing.

**Status (session 9 — 2026-05-08)**: C2 shipped end-to-end (right-click ProRes 422 / 4444 transcode action with non-modal progress). 269 tests, all green (was 257 at session start; +12 from the C2a/C2b suites — C2c is UI-only and has no new test surface). 3 new commits on `development` (C2a / C2b / C2c). The C1 inspector-chip → action loop is now closed: every yellow chip the operator sees in the cue inspector points to the right-click menu that's now wired up.

**Status (session 8 — 2026-05-08)**: C6 shipped end-to-end (Keynote `.key` import via AppleScript → PDF → bitmaps). 257 tests, all green (was 243 at session start; +14 from the C6a/C6b suites — C6c is UI-only and has no new test surface). 3 new commits on `development` (C6a / C6b / C6c).

**Status (session 7 — 2026-05-08)**: C3 shipped end-to-end (PDF rasterize-on-import). 243 tests, all green (was 233 at session start). 3 new commits on `development` (C3a / C3b / C3c).

**Status (session 6 — 2026-05-08)**: C1 shipped end-to-end (codec inspector flags). 233 tests, all green (was 202 at session start). 3 commits on `development`.

Phase C is just starting. The codec inspector (C1) is the first piece because it has zero hardware dependency and unblocks B8 (10-bit YUV default once any clip is >8-bit) — the `MediaSlide.flags.tenBitYUV420` boolean is now the project-wide signal B8 will key off of.

The remaining Phase C items (C2 transcode action, C3 PDF import, C4 GIF/APNG detect-and-convert, C5 image-sequence detect-and-encode, C6 Keynote import, C7+ asset library / audio / subtitles) are all autonomy-friendly with no hardware exposure — Phase C should be the workhorse phase for autonomous-build cycles.

---

## What shipped in session 12 (C5c + Show-Mode gate + Apple-events deep-link)

### Option B — Show-Mode gate on inline transcode button

- `CueInspectorView` gained a `showMode: Bool = false` parameter; when true the inline `"Transcode to ProRes …"` button is hidden. Mirrors `SlideGridView.transcodeEnabled` so the asset library and the cue inspector behave consistently in Show Mode. `RootView.selectionInspector` passes `showController.controller?.showMode ?? false`. No new tests (visibility gate; underlying `canTranscode` + `preferredPresetOrder` behavior is already pinned by C2/C4).

### C5c — Folder-drop UX (Add Folder…  + confirm sheet + encode integration)

- **`Services/AddFolderImporter.swift`** — pure-logic `plan(folderURL:) -> Plan` that does a single-level `contentsOfDirectory` walk (no recursion into subfolders — surprising operators with nested batch behavior is worse than asking them to add nested folders separately), skips hidden files (`.DS_Store`, AppleDouble forks), normalizes by last-path-component for deterministic ordering, and runs `ImageSequenceDetector.detect(in:)` against the result. Returns `Plan(sequences, standaloneMediaURLs)`. 7 tests cover sequence grouping, multi-sequence + standalone split, hidden-file skipping, no-recursion, empty folder, missing folder error, deterministic ordering.

- **`Views/AddFolderImportSheet.swift`** — confirmation sheet rendered as a `.sheet(item:)` after the open panel returns. Shows one row per detected sequence with a checkbox (operator can opt out per sequence), a frame-rate preset picker (24/25/30/48/50/60), and a custom integer text field for any other rate. Standalone files are summarized as a count below — they pass through `MediaImporter` unchanged. The Encode button is gated on `pending.canConfirm` (every encode-checked sequence has `frameRate >= 1` AND there's at least one action to take).

- **`PendingFolderImport`** — operator-supplied configuration model. Per-sequence `SequencePlan` carries `frameRate: Int` (sentinel `0` = "operator hasn't picked yet") and `encode: Bool` (default true). `canConfirm` and `encodableSequences` are pure-logic and unit-tested (7 tests in `PendingFolderImportTests`).

- **`RootView` wiring** — new "Add Folder" toolbar button (Show-Mode-gated) opens an `NSOpenPanel` with `canChooseDirectories = true / canChooseFiles = false`. On OK, `presentFolderImport(at:)` runs the `AddFolderImporter` walk and stuffs the `PendingFolderImport` into `@State`, which `.sheet(item:)` presents. On Encode, `confirmFolderImport(_:)` imports standalone files via the existing `addMedia(_:)` path, then enqueues each sequence through `encodeCoordinator.encode(...)`. On encoder success the resulting sibling slide appends to `project.slides`. Failures route to the `ImportStatusBanner` (kind `.transcode` for encode failures, `.unsupportedMedia` for folder-walk failures). No frame-rate default is committed at any layer — the encoder takes its rate from the per-sequence operator pick.

- **`SlideGridView.BackgroundJobsStrip`** — renamed from `TranscodeProgressStrip`; now renders both `TranscodeJob` rows (C2) and `ImageSequenceEncoder` rows (C5c) in a single non-modal strip just above the palette transition controls. Each row uses a distinct icon (`arrow.triangle.2.circlepath` for transcode, `rectangle.stack` for image-sequence encode) so the operator can tell them apart at a glance. Operators see all running ProRes background work in one place; the row disappears when the coordinator removes the job after terminal state.

### Option E — Apple-events deep-link button on import-status banner

- `ImportStatusBanner.hasKeynoteFailure: Bool` returns true when any failure has `kind == .keynoteImport`. When true, `ImportStatusBannerView`'s details popover renders an extra section with a `"Open Privacy & Security → Automation"` button that calls `NSWorkspace.shared.open(AutomationPrivacySettings.url)`. The deep-link URL is exposed at module scope (`AutomationPrivacySettings.url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"`) so tests can pin its exact shape. Closes the most opaque `.key` import failure mode — operator denies the macOS automation prompt for Keynote once, every subsequent import returns `KeynoteImportError.exportFailed` whose summary lands in the banner with no indication of cause; the button takes them one click from there to the right toggle.

### Tests added (session 12)

| Test | What it covers |
|---|---|
| `AddFolderImporterTests.testPlanGroupsContiguousFramesIntoSequence` | Folder with shot01.0001-3.png + README.txt → 1 sequence + README in leftovers. |
| `AddFolderImporterTests.testPlanSeparatesMultipleSequencesAndStandaloneMedia` | Two sequences (different basenames) plus `.mov` + singleton `.png` → 2 sequences + 2 standalones. |
| `AddFolderImporterTests.testPlanSkipsHiddenFiles` | `.DS_Store` not in standaloneMediaURLs (operator should never see ".DS_Store: unsupported media" in banner). |
| `AddFolderImporterTests.testPlanDoesNotRecurseIntoSubfolders` | Subfolder contents are not read; only top-level sequence is detected. |
| `AddFolderImporterTests.testPlanReturnsEmptyForEmptyFolder` | Empty folder → `Plan.empty`. |
| `AddFolderImporterTests.testPlanThrowsForMissingFolder` | Bogus URL → throw. |
| `AddFolderImporterTests.testPlanProducesDeterministicOrdering` | `["zebra", "alpha"]` filesystem-order input → `["alpha", "zebra"]` plan order (sorted by basename). |
| `PendingFolderImportTests.testCanConfirmFalseWhenNoSequencesAndNoStandalones` | Empty plan → no Encode. |
| `PendingFolderImportTests.testCanConfirmTrueWhenStandalonesPresentAndNoSequences` | Standalones-only → Encode enabled. |
| `PendingFolderImportTests.testCanConfirmFalseWhenSequenceMarkedEncodeButRateUnset` | encode=true + rate=0 → Encode disabled. |
| `PendingFolderImportTests.testCanConfirmTrueWhenSequenceMarkedEncodeWithRate` | encode=true + rate=30 → Encode enabled. |
| `PendingFolderImportTests.testCanConfirmTrueWhenSequenceUnchecked` | Only sequence unchecked + no standalones → Encode disabled. |
| `PendingFolderImportTests.testCanConfirmTrueWhenSequenceUncheckedButStandalonePresent` | Sequence unchecked + standalone present → Encode enabled. |
| `PendingFolderImportTests.testEncodableSequencesExcludesUnchecked` | Filter drops unchecked. |
| `PendingFolderImportTests.testEncodableSequencesExcludesZeroRate` | Filter drops zero-rate. |
| `ImportStatusBannerTests.testHasKeynoteFailureFalseForNonKeynoteFailures` | PDF / transcode / unsupported don't trip. |
| `ImportStatusBannerTests.testHasKeynoteFailureTrueWhenAnyKeynoteFailurePresent` | Mixed list with one Keynote failure trips the deep-link. |
| `ImportStatusBannerTests.testAutomationPrivacySettingsURLIsValidDeepLink` | Pins the `x-apple.systempreferences` URL string. |

Total: 359 tests, all green (was 341 at session start; +18).

### Manual verification needed (session 12 deltas)

1. Add Folder…  toolbar button: pick a folder containing `shot.0001.png … shot.0030.png` plus a stray `hero.mov`. The confirm sheet appears with one sequence row + "Plus 1 standalone file will be imported as-is." Standalone files import as normal slides; the sequence encodes into `<bundle>/Transcoded/<UUID>.mov` at the rate the operator picks.
2. Pick a folder with two sequences at different basenames (`shotA.*.png` + `shotB.*.exr`). Both rows render; pick different rates per sequence; both encode in parallel and both progress rows appear in the palette strip.
3. Uncheck a sequence in the sheet and confirm. That sequence is skipped; its frames become standalone-imported `.png` slides (the singleton-as-standalone fallback already covered by the detector's leftover behavior).
4. Type a custom rate (say `27`) into the integer field. The picker shows no preset selected; the encode runs at 27 fps.
5. Set rate to `0` (or leave the field blank-cum-zero); the Encode button stays disabled. Set to `1` (minimum); button enables.
6. Drop a folder of mixed `.png` sequences plus `.psd` files plus `.DS_Store`. The `.DS_Store` does not appear; the `.psd` lands in `MediaImporter` and surfaces as `unsupportedMedia` in the banner.
7. Cancel a running encode via the strip's xmark button. Row disappears, no banner entry (cancellation is operator-initiated and silent by design — same as transcodes).
8. Inline transcode button: enter Show Mode (toolbar toggle). Open the cue inspector for a flagged clip — the button is gone. Exit Show Mode — button returns. Asset library context menu has the same gating.
9. Trigger a Keynote import failure (drop a `.key` while Keynote is not installed, or while the operator hasn't granted automation permission). Click "Show Details" on the banner; the popover shows the failure rows AND a new "Keynote import requires automation permission." section with an `Open Privacy & Security → Automation` button. Click it; System Settings opens to the right pane.

---

## What shipped in session 11 (C5b + C-banner-c + inline transcode button + B8 logic)

### C5b — `ImageSequenceEncoder` + `ImageSequenceEncodeCoordinator`

- **`Services/ImageSequenceEncoder.swift`** — `@MainActor ObservableObject` wrapping `AVAssetWriter`. Mirrors C2's `TranscodeJob` shape: `state` enum (`.idle / .running / .completed(URL) / .failed(String) / .cancelled`), `progress: Double`, `start(completion:)` / `cancel()`. Pipeline runs on `Task.detached` so synchronous CGImageSource decode + CVPixelBuffer fill don't block the main thread on long sequences. Per-frame: read via `CGImageSourceCreateWithURL` + `CGImageSourceCreateImageAtIndex(0)`; allocate from the adaptor's `pixelBufferPool`; lock + clear-to-transparent + draw via `CGContext` (premultipliedFirst, byteOrder32Little, BGRA); `adaptor.append` at `CMTime(value: index, timescale: frameRate)`. Final state requires `writer.status == .completed`.
- **Frame rate is operator-supplied.** The encoder takes it as an init parameter — no default committed. The frame-rate default question (Stage rate? operator-picked per import? 30 fps fallback?) belongs to C5c (folder-drop UX) and is filed as the C5c product blocker.
- **Pixel format choice**: `kCVPixelFormatType_32BGRA` for the buffer pool (8-bit BGRA, premultiplied alpha). Sufficient for the typical PNG / JPG / TIFF / EXR sequence content; ProRes 4444 carries the alpha through losslessly. A future enhancement could switch to 16-bit per channel (`_64ARGB`) for EXR sources to preserve >8-bit content; today the encoder is correctness-first and matches the PNG sequences operators most often produce.
- **Frame-size mismatch handling**: the canonical canvas is the first frame's `CGImage` width × height. Later frames whose dimensions differ are drawn into the canonical rect via `context.draw(image, in: rect)`, which scales them — soft landing rather than thrown error. The detector groups by basename, so cross-frame size mismatches are unlikely; if they happen, the operator gets a stretched / fit-into-canvas frame rather than a failed encode.
- **`ImageSequenceEncodeCoordinator`** — owns live `[ImageSequenceEncoder]`. Mirrors `TranscodeCoordinator`: jobs list + injectable `siblingImporter` test seam (default delegates to `MediaImporter.importSlides`, so the resulting slide carries fresh `nativeFrameRate` + `MediaFlags`). `encode(sequence:frameRate:destinationDirectory:completion:)` builds the destination URL (`<UUID>.mov`), kicks off the encoder, and on success constructs an `ImageSequenceEncodeOutcome { baseName, siblingSlide }`. The sibling slide's title is the detected sequence's `baseName` (e.g. `shot07.0001.png … shot07.0240.png` → `"shot07"`).
- **End-to-end FourCC pin**: the encoder test synthesizes a 3-frame 32×32 PNG sequence at runtime, encodes at 30 fps, asserts the output `.mov` has FourCC ∈ `{ap4h, ap4x}` (ProRes 4444 family) and duration ~3/30 = 0.1 s within tolerance.

### Tests added (session 11 — C5b)

| Test | What it covers |
|---|---|
| `ImageSequenceEncoderTests.testEncoderStartsInIdle` | `.idle` initial state, progress 0, not terminal, not running. |
| `ImageSequenceEncoderTests.testCancelBeforeStartIsNoOp` | `cancel()` before `start()` does not transition state. |
| `ImageSequenceEncoderTests.testEncoderFailsWhenFrameListEmpty` | Empty input → `.noFrames`. |
| `ImageSequenceEncoderTests.testEncoderFailsWhenFrameRateLessThanOne` | `frameRate == 0` → `.invalidFrameRate(0)`. |
| `ImageSequenceEncoderTests.testEncoderFailsWhenFrameUnreadable` | Missing source frame → `.unreadableFrame`. |
| `ImageSequenceEncoderTests.testEncodesPNGSequenceToProRes4444` | End-to-end: 3 PNG frames @ 30 fps → `.mov` with FourCC `ap4h`/`ap4x` and ~0.1 s duration. |
| `ImageSequenceEncoderTests.testCancelAfterCompletionIsNoOp` | `cancel()` after terminal state preserves `.completed`. |
| `ImageSequenceEncoderTests.testStartTwiceIsNoOpOnSecondCall` | Second `start()` while running does not fire its completion. |
| `ImageSequenceEncoderTests.testMakeCGImageReadsPNG` | `makeCGImage` happy path (16×16 PNG). |
| `ImageSequenceEncoderTests.testMakeCGImageReturnsNilForMissingFile` | Missing file → nil. |
| `ImageSequenceEncodeCoordinatorTests.testCoordinatorStartsEmpty` | `jobs == []` on init. |
| `ImageSequenceEncodeCoordinatorTests.testEncodeProducesSiblingSlideWithSequenceBaseName` | End-to-end with stubbed sibling importer: outcome carries baseName + sibling.title = baseName + sibling.mediaKind = .video. |
| `ImageSequenceEncodeCoordinatorTests.testEncodeFailsWhenSiblingImporterReturnsNil` | Importer-returns-nil → `.finishFailed`. |
| `ImageSequenceEncodeCoordinatorTests.testCancelAllCancelsRunningJobs` | After `cancelAll()`, jobs list drains; either success-or-failure outcome accepted (race window). |

### C-banner-c — Modal Keynote alert dropped

- `RootView.addMedia` no longer presents the "Keynote not installed" `NSAlert`. The banner already captures Keynote-not-installed via the existing `importKeynoteThrowing` → `KeynoteImportError.keynoteNotInstalled` → `makeFailure` chain. Removing the modal gives a single uniform non-modal failure surface across PDF / Keynote / transcode / unsupported pipelines, which is also what spec §3.5 prefers (modal-forbidden invariant). No tests changed.

### Inline transcode button on cue inspector flag chips

- `CueInspectorView` now takes an optional `requestTranscode: ((MediaSlide, TranscodePreset) -> Void)?` parameter; `RootView.selectionInspector` passes its existing `requestTranscode(slide:preset:)` implementation. When the asset is transcode-eligible (`TranscodeService.canTranscode`), the chip group renders a single inline `"Transcode to ProRes 422"` / `"Transcode to ProRes 4444"` button below the chips, using `TranscodeService.preferredPresetOrder(for: slide).first` so animated images lead with 4444 and everything else leads with 422 — same order signal the right-click menu uses, no parallel preference. Closes the C2 known gap "Inspector flag chips don't auto-route." No new tests (closure pass-through; underlying `preferredPresetOrder` + `canTranscode` behavior is already pinned by C2/C4).

### B8 logic — `recommendsTenBitOutput` + Output inspector hint

- **`PlayoutProject.recommendsTenBitOutput`** — pure-logic computed property: true iff `slides.contains { $0.mediaKind == .video && $0.flags.tenBitYUV420 }`. Phase B8 ("10-bit YUV 4:2:2 default when any clip in the project is >8-bit") is now genuinely unblocked by C1's inspector flag.
- **`OutputInspectorView`** — when `recommendsTenBitOutput` is true, renders a yellow info row: "10-bit content detected — Configure the DeckLink output as 10-bit YUV 4:2:2 to preserve quality." Informational only — no auto-toggle. The actual default-as-tenBit-true at DeckLink-binding-creation time waits for a UI surface that creates DeckLink bindings (today no such surface exists). Hardware verification of 10-bit format negotiation against a real card remains operator-driven.
- 4 tests pin the recommendation contract: empty project (false), all-8-bit (false), any-10-bit (true), `.image` slide with `tenBitYUV420 == true` (false — recommendation only fires on `.video`).

### Tests added (session 11 — B8)

| Test | What it covers |
|---|---|
| `ModelTests.testRecommendsTenBitOutputFalseOnEmptyProject` | Empty project → false. |
| `ModelTests.testRecommendsTenBitOutputFalseWhenAllVideoIs8Bit` | All slides 8-bit → false. |
| `ModelTests.testRecommendsTenBitOutputTrueWhenAnyVideoIsTenBit` | Any video 10-bit → true. |
| `ModelTests.testRecommendsTenBitOutputIgnoresNonVideoSlides` | `.image` slide with `tenBitYUV420 == true` is ignored. |

Total: 341 tests, all green (was 323 at session start; +18 across C5b encoder + C5b coordinator + B8).

---

## Manual verification needed (session 11 deltas)

These need human eyeballs — autonomous tests cover the encoder's FourCC contract end-to-end against synthesized PNGs, but real-world image-sequence variety (EXR with alpha, mixed-aspect frames, TIFF with embedded color profiles, multi-thousand-frame sequences) needs operator-supplied media.

### C5b (image-sequence encoder)

1. The encoder currently has no UI surface — C5c lands the open-panel + drop handler. Until then, the encoder + coordinator are exercised only by the test suite. A minimal smoke-test would be a one-shot harness in the tests directory (synthesize 60 frames, encode at 24 fps, verify on disk) — not part of this session.
2. Open the resulting `.mov` from a test-run in QuickTime; the alpha channel should preserve any transparency in the source PNGs (use a sequence with embedded alpha to verify).

### C-banner-c

3. Without Keynote installed, drop a `.key` file. Previously: modal alert + banner. Now: banner only. Click "Show Details" — the popover entry reads "Keynote not installed — install Keynote to import .key files".
4. Drop a mixed batch (one `.key`, one healthy `.png`) without Keynote installed. The banner shows 1 item failed; the PNG still imports.

### Inline transcode button

5. Import an H.264 .mp4. Open its cue in the cue inspector. Confirm the yellow "Long-GOP" chip appears with a "Transcode to ProRes 422" button below it. Click it — the non-modal progress strip appears (same as right-click); on completion the sibling slide is auto-selected. Inspector chips on the sibling are gone (long-GOP cleared).
6. Import an animated GIF. Open its cue. Confirm the chip says "Animated GIF / APNG …" and the button reads "Transcode to ProRes 4444" (alpha-bearing default for animated images). Click it — the sibling is a ProRes 4444 .mov and plays with full motion.
7. Import a clean ProRes file. Confirm no chips, no button.
8. Show Mode (Cmd-Shift-L) — the cue inspector still shows chips, but `requestTranscode` is plumbed through `RootView.requestTranscode` which is gated by Show Mode at the asset library level. The button itself doesn't gate on Show Mode — operators in Show Mode might still press the inline button, which would fail downstream. (Known gap; pair with a Show-Mode disable on `requestTranscode` as a future cleanup.)

### B8 hint

9. Save a project, drop in an HEVC Main 10 source (an iPhone HDR clip). Open the Output inspector tab. The bottom of the inspector should show a yellow row "10-bit content detected …".
10. Drop only ProRes 422 / 8-bit H.264 sources. The hint section is hidden.
11. The hint is informational only — no toggle to flip the DeckLink output to 10-bit. That ships with the B7 / DeckLink-binding-creation UI.

---

## What shipped in session 10 (C4 + Import Status Banner + C5a)

### C4a — `animatedImage` flag in `MediaFlags`

- **`Models/MediaFlags.swift`** — extended with `animatedImage: Bool` (orthogonal to the four codec-inspector flags — those only set on `.video`, this only on `.image`). New `WarningKind.animatedImage` with the spec-pinned copy `"Animated GIF / APNG — first frame only; transcode to ProRes 4444 for full motion."`. `activeWarnings` order extends to `[longGOP, variableFrameRate, tenBitYUV420, untaggedColor, animatedImage]` — the existing four-flag locked order is unchanged. `decodeIfPresent` defaults the new field to false, so projects saved between C1 (post-flag) and C4 (post-animatedImage) decode cleanly.
- 5 tests cover the new ordering with all five flags on, animatedImage-only ordering, hasAnyFlag, warning copy, JSON round-trip + post-C1/pre-C4 legacy decode.

### C4b — `AnimatedImageInspector` + `MediaImporter` image-branch wiring

- **`Services/AnimatedImageInspector.swift`** — `inspect(url:) -> MediaFlags` and `isAnimated(url:) -> Bool`. Detection: `CGImageSourceCreateWithURL` + `CGImageSourceGetCount > 1`, gated by a cheap `.gif`/`.png`/`.apng` extension/UTI pre-filter so static-still imports don't pay a CGImageSource-create per-file cost. Returns `false` (and `MediaFlags.none`) on any failure — better to miss the chip than false-positive on malformed media.
- **`MediaImporter.importSlides(from:context:)`** — image branch now switches: `.video` → `MediaFlagsInspector.inspect(...)`, `.image` → `AnimatedImageInspector.inspect(...)`. The two inspectors share the same `MediaFlags` return type so the slide assembly stays uniform.
- 11 tests — multi-frame GIF + APNG → flagged true; single-frame GIF / static PNG / JPEG → false; corrupt headers + missing files → false; `inspect(url:)` returns the right `MediaFlags`; the importer integration (animated GIF → flag set in resulting MediaSlide; static PNG → `MediaFlags.none`).

### C4c — `TranscodeService` widening + right-click menu reorder

- **`TranscodeService.canTranscode(slide:)`** — widened to accept `.image` slides whose `flags.animatedImage` is true. Static images still return false (the existing test contract is preserved — operators don't transcode a PNG to ProRes for fun).
- **`TranscodeService.preferredPresetOrder(for:) -> [TranscodePreset]`** — alpha-aware default. Animated images return `[.proRes4444, .proRes422]` (the alpha-bearing codec leads — animated GIFs are typically lower-thirds / logo bugs that need alpha preserved). Everything else returns `[.proRes422, .proRes4444]`.
- **`Views/SlideGridView.slideContextMenu(for:)`** — `ForEach(TranscodeService.preferredPresetOrder(for: slide), id: \.self)` builds menu items in the preferred order. Two presets, no defaults / disclosure / divider — just the order signal.
- 3 tests — `canTranscode` accepts animated-image slides; `preferredPresetOrder` returns 4444-first for animated, 422-first for video.

### C-banner-a — `MediaImportFailure` model + `importSlidesAndReport`

- **`Services/MediaImportFailure.swift`** — `struct MediaImportFailure { id, url, kind, summary }` (Identifiable, Equatable). `Kind` enum: `pdfImport / keynoteImport / transcode / unsupportedMedia`. The summary is a flat string (operator-readable) so the banner doesn't depend on each pipeline's error type being Equatable. `MediaImportReport { slides, failures }` is the new return shape.
- **`Services/MediaImporter.swift`** — new `importSlidesAndReport(from:context:) -> MediaImportReport` overload. Refactored `importPDF` / `importKeynote` from "return [] on error" to "throw on error", so the new top-level method can catch and convert via `makeFailure`. The legacy `importSlides(from:)` / `importSlides(from:context:)` delegate to the new method and discard failures — back-compat for every existing test (and any non-UI caller).
- 8 tests — empty input, happy path, unsupported `.txt` reported, corrupt PDF reported, Keynote-not-installed reported (workspace provider seam), exporter-throws reported (test-injected error → summary contains the underlying message), mixed batch separates slides from failures keyed by URL, back-compat path returns slides-only.

### C-banner-b — `ImportStatusBanner` ObservableObject + view + RootView wiring

- **`Views/ImportStatusBanner.swift`** — `@MainActor ImportStatusBanner: ObservableObject` with `failures: [MediaImportFailure]`, `record(_:)`, `recordTranscode(url:error:)`, `dismiss()`, and a `headline` computed property that handles the singular/plural split (`"1 item failed to import"` vs. `"3 items failed to import"`). Append-only until the operator dismisses — a second failed import never silently overwrites the first.
- **`ImportStatusBannerView`** — rendered above `OutputStatusBar` in `RootView`. Red-tinted strip with a triangle icon, the headline, a `Show Details` popover (per-failure summary + full path), and an `xmark.circle.fill` dismiss button. Hidden when `failures.isEmpty`.
- **`Views/RootView.swift`** — `@StateObject private var importStatus = ImportStatusBanner()`. `addMedia` now calls `importSlidesAndReport` and threads `report.failures` into the banner. `requestTranscode` failure path threads non-cancellation failures into the banner (cancellations are operator-initiated; silent is the right UX).
- 7 tests cover starts-empty, empty-batch no-op, append batch, append twice (no overwrite), record transcode failure, dismiss clears, headline pluralization.

### C5a — `ImageSequenceDetector` pure-logic

- **`Services/ImageSequenceDetector.swift`** — `detect(in: [URL]) -> Result { sequences, leftovers }`. Pure-logic, no filesystem access. Recognized extensions: `png / jpg / jpeg / tiff / tif / exr`. Counter widths: 3 or 4 digits (avoids false-positives on `v1.2.png`-style version markers and the `.12345.png` long-counter shape). Multi-dot basenames supported — the rightmost segment is treated as the counter, everything before as the basename. Gaps in the counter are allowed (operators export non-contiguous selections). Sequences split by basename, by extension, AND by pad width (a 3-digit and 4-digit counter sharing a basename are two sequences — keeps output numbering consistent).
- 20 tests cover parser branches (3-digit, 4-digit, two-digit reject, five-digit reject, unrecognized extension, recognized list, case-insensitive ext, missing counter, non-numeric counter, multi-dot basename) + detect branches (empty, single-frame leftover, simple sequence, sort-by-counter, gap tolerance, sequence/singleton separation, multiple sequences by name / extension / padWidth, unrecognized extensions become leftovers).
- The encode side (C5b — AVAssetWriter wrapping pure-logic frames-in / .mov-out) and folder-drop UX are deferred. Once C5b lands, the importer would route detected sequences through it the same way C3/C6 route PDFs and Keynote decks through PDFImporter.

---

## Tests added (session 10)

| Test | What it covers |
|---|---|
| `MediaFlagsTests.testActiveWarningsOrderIncludesAnimatedImageLast` | 5-flag ordering pin (animatedImage trails the four codec-inspector flags). |
| `MediaFlagsTests.testActiveWarningsForAnimatedImageOnlyContainsAnimatedImage` | Animated-only flag set yields exactly `[.animatedImage]`. |
| `MediaFlagsTests.testHasAnyFlagTrueWhenAnimatedImageSet` | hasAnyFlag short-circuit for the new flag. |
| `MediaFlagsTests.testWarningStringsMatchSpec` (extended) | Spec §3.10 wording for the animated-image warning is pinned. |
| `MediaFlagsTests.testMediaFlagsRoundTripsAnimatedImageFlag` | JSON round-trip. |
| `MediaFlagsTests.testMediaFlagsLegacyJSONWithFourFlagsDecodesAnimatedImageAsFalse` | Post-C1 / pre-C4 projects decode cleanly. |
| `MediaFlagsTests.testMediaFlagsPartialJSONDecodesMissingFieldsAsFalse` (extended) | Partial JSON includes new field default. |
| `AnimatedImageInspectorTests.*` (11) | GIF / APNG / static / JPEG / corrupt / missing detection + `inspect(url:)` + importer integration on animated GIF + static PNG. |
| `TranscodeServiceTests.testCanTranscodeAcceptsAnimatedImageSlide` | Animated `.image` slides light up the transcode menu. |
| `TranscodeServiceTests.testPreferredPresetOrderLeads4444ForAnimatedImages` | 4444 leads for alpha-aware sources. |
| `TranscodeServiceTests.testPreferredPresetOrderLeads422ForVideoSlides` | 422 leads for everything else. |
| `MediaImportFailureTests.*` (8) | empty / happy / unsupported / corrupt PDF / Keynote-not-installed / exporter-throws / mixed batch / back-compat slides-only. |
| `ImportStatusBannerTests.*` (7) | starts-empty / empty-noop / record / append-only / record-transcode / dismiss / headline pluralization. |
| `ImageSequenceDetectorTests.*` (20) | parser branches + detect branches (single / multi-sequence / extension split / pad-width split / unrecognized-extension leftovers / sort-by-counter / gap tolerance). |

Total: 323 tests, all green (was 269 at session start; +54).

---

## Manual verification needed (session 10 deltas)

These need human eyeballs — autonomous tests don't drive SwiftUI inspectors / context menus / popovers / drag-drop.

### C4 (animated GIF / APNG)

1. Drop an animated GIF (a typical "lower-thirds" or "spinner" asset) into a saved project. The asset library tile shows it as an image. Click into the cue inspector. The yellow `Animated GIF / APNG — first frame only; transcode to ProRes 4444 for full motion.` chip should appear.
2. Right-click the same tile. The context menu's first item should read `Transcode to ProRes 4444`, with `Transcode to ProRes 422` second. Pick 4444.
3. The non-modal progress strip appears (same as C2c). On completion, a sibling slide titled `<orig> (ProRes 4444)` appears immediately after the source. Take it — the animation should now play with full motion.
4. Drop a static GIF (no animation). The cue inspector shows no `animatedImage` chip. The right-click menu shows no transcode items (canTranscode is false for static images).
5. Drop an APNG (multi-frame `.png`). Same as step 1 — chip + 4444-first menu.
6. Drop a JPEG. Cue inspector shows no chip; menu shows no transcode items.
7. Save the project, restart, reopen. The animated-image flag persists on the slide via `MediaSlide.flags.animatedImage`.

### Import Status Banner

8. Drop a corrupt or zero-page PDF. Slides don't appear; a red banner at the top of the program panel reads `1 item failed to import`. Click `Show Details` — the popover shows the file path and the PDFKit error message. Click ✕ to dismiss.
9. Drop a `.txt` file (no UTI conformance). Banner reads `1 item failed to import`; popover shows `Unsupported media: <filename>.txt`.
10. Drop a `.key` file with Keynote not installed. The modal "Keynote not installed" alert fires (existing behavior); the banner ALSO shows the failure (since the import path returns the keynoteImport failure now). Both fire today — slated for C-banner-c reconciliation in a future session.
11. Right-click a video, kick off a transcode against media that AVFoundation can't read (renamed/corrupt mid-transcode). The progress row disappears as the export fails; the banner appears with `Transcode failed: …`.
12. Right-click a video, kick off a transcode, click ✕ on the progress row. The cancellation does NOT show in the banner — operator-initiated cancellation is silent by design.
13. Drop multiple bad files in one batch (corrupt PDF + .txt + healthy PNG). Banner reads `2 items failed to import`; the healthy PNG still imports.

### C5a (Image-sequence detector)

14. Pure logic, no UI surface yet. Manual verification waits for C5b (encoder) + the folder-drop UX.

---

## What shipped in session 9 (C2)

### C2a — `TranscodeService` + `TranscodeJob`

- **`Services/TranscodeService.swift`** — pure-logic helpers: `TranscodePreset` (`proRes422` / `proRes4444`) maps to AVFoundation preset constants (`AVAssetExportPresetAppleProRes422LPCM` / `AVAssetExportPresetAppleProRes4444LPCM`); `siblingTitle(originalTitle:preset:)` returns `"<orig> (ProRes 422)"`; `destinationFilename(preset:)` returns a UUID-keyed `<UUID>.mov` so concurrent transcodes never collide; `canTranscode(slide:)` gates the menu offer to video slides whose URL still resolves.
- **`TranscodeJob`** — `@MainActor` `ObservableObject` wrapping `AVAssetExportSession`. Modern API only: `session.export(to:as:)` (deprecated `exportAsynchronously` avoided) + `session.states(updateInterval: 0.2)` AsyncSequence emitting `.exporting(Progress)` ticks for the progress bar. `state` is a `.idle / .running / .completed(URL) / .failed(String) / .cancelled` enum (Equatable). Cancellation routes through both `exportTask?.cancel()` and `stateObserverTask?.cancel()`; the `start` completion fires with `.cancelled` (or `.success` if the export raced past the cancel — the test pins both as valid).
- **Errors** — `TranscodeError.sourceNotReadable(URL)` / `.presetIncompatible(String)` / `.exportFailed(String)` / `.cancelled`. Equatable so tests can assert on specific cases.
- 8 tests cover preset → AVFoundation constant identity for both presets, sibling-title formatting, UUID-keyed filename uniqueness, the canTranscode predicate, idle-state init, the unreadable-source failure path (the export session itself rejects), and the end-to-end H.264 → ProRes 422 transcode of a synthesized AVAssetWriter movie (verifies output file lands at destination, output FourCC ∈ ProRes 422 family `apcn/apcs/apco/apch`, terminal state is `.completed(url)`, progress reaches 1.0).

### C2b — `TranscodeCoordinator` + sibling-slide construction

- **`TranscodeCoordinator`** — `@MainActor ObservableObject` owning `[TranscodeJob]`. The single public method, `transcode(slide:preset:destinationDirectory:completion:) -> TranscodeJob?`, builds the destination URL (`destinationDirectory/<UUID>.mov`), resolves the source via `slide.media.resolvedURL()`, kicks off the job, and on success constructs a `TranscodeOutcome` (sourceSlideID + sibling MediaSlide).
- **Sibling slide** comes from `TranscodeCoordinator.siblingImporter(url)` (test-injectable static var; default delegates to `MediaImporter.importSlides(from: [url]).first`). The importer re-inspects the transcoded file with the existing C1 `MediaFlagsInspector` so the sibling carries fresh `nativeFrameRate` and cleared flags — a successful ProRes transcode by definition removes long-GOP/VFR/10-bit-4:2:0 from the inspector. The coordinator overwrites `sibling.title` to `"<original> (ProRes 422)"`.
- **`ProjectBundleLayout.transcodedDirectory = "Transcoded"`** — pinned to spec §3.17 (`<bundle>/Transcoded/`). Sibling-of-`Cache/Renders` placement matches the C3/C6 precedent.
- 4 tests cover empty initial state, the unresolvable-source defensive refusal (no job enqueued), the end-to-end H.264 → ProRes 422 → sibling-slide path (verifies sourceSlideID match, sibling title format, mediaKind = .video, nativeFrameRate threaded through the stub, fresh UUID, written file location and extension, jobs list drains on completion), and `cancelAll()` draining the jobs list (with both success and `.cancelled` accepted as valid outcomes for the race-window-friendly synthesized clip).

### C2c — `SlideGridView` context menu + non-modal progress strip + RootView wiring

- **`Views/SlideGridView.swift`** — `SlideTile.contextMenu` builds entries via `slideContextMenu(for:)` which inserts `Transcode to ProRes 422` / `Transcode to ProRes 4444` items when `transcodeEnabled && TranscodeService.canTranscode(slide:)`. Show Mode passes `transcodeEnabled = false`, hiding the menu but not aborting in-flight jobs.
- **`TranscodeProgressStrip`** — non-modal strip rendered just above the existing `PaletteTransitionControls`. One `TranscodeProgressRow` per running job: `arrow.triangle.2.circlepath` icon, `displayLabel` (truncated middle), linear `ProgressView`, percent (monospaced digit), and a borderless `xmark.circle.fill` cancel button. Strip is hidden when `transcodeJobs.isEmpty`.
- **`Views/RootView.swift`** — `@StateObject private var transcodeCoordinator = TranscodeCoordinator()`. `requestTranscode(slide:preset:)` calls the coordinator with `transcodedRootDirectory()` and on `.success(outcome)` splices the sibling slide into `project.slides` immediately after the source's index (or appends if the source was deleted mid-transcode), then auto-selects the sibling so the operator sees its inspector. `transcodedRootDirectory()` mirrors `renderRootDirectory()`: bundle-relative when `projectBundleURLProvider()` resolves, App Support fallback (`~/Library/Application Support/Simple Playback/Transcoded/<sessionUUID>/`) for untitled documents.
- No new tests (UI surface only; the underlying behaviors are pinned by C2a/C2b).

---

## Tests added (session 9)

| Test | What it covers |
|---|---|
| `TranscodeServiceTests.testProRes422PresetMapsToAVConstant` | `.proRes422` → `AVAssetExportPresetAppleProRes422LPCM`, `.mov`, `.mov` filetype. |
| `TranscodeServiceTests.testProRes4444PresetMapsToAVConstant` | `.proRes4444` → `AVAssetExportPresetAppleProRes4444LPCM`, `.mov`, `.mov` filetype. |
| `TranscodeServiceTests.testSiblingTitleAppendsPresetLabel` | `"<orig> (ProRes 422)"` / `"<orig> (ProRes 4444)"`. |
| `TranscodeServiceTests.testDestinationFilenameUsesUUIDAndPresetExtension` | `<UUID>.mov`; two consecutive calls don't collide. |
| `TranscodeServiceTests.testCanTranscodeRequiresVideoSlideWithResolvableURL` | Video + resolvable URL → true. Image → false. Missing URL → false. |
| `TranscodeServiceTests.testJobStartsInIdle` | Fresh job: `.idle`, progress 0, not terminal, not running. |
| `TranscodeServiceTests.testJobFailsOnUnreadableSource` | Non-existent source → `.failed` state + completion `.failure`. |
| `TranscodeServiceTests.testJobTranscodesH264ToProRes422` | End-to-end: synthesized H.264 → ProRes 422 file at destination URL with FourCC ∈ {apcn/apcs/apco/apch}, terminal state `.completed(url)`, progress 1.0. |
| `TranscodeCoordinatorTests.testCoordinatorStartsEmpty` | `jobs == []` on init. |
| `TranscodeCoordinatorTests.testTranscodeFailsImmediatelyWhenSourceURLDoesNotResolve` | Defensive: unresolvable slide → no job enqueued, completion `.failure`. |
| `TranscodeCoordinatorTests.testTranscodeProducesSiblingSlideWithExpectedShape` | End-to-end: synthesized H.264 source → sibling MediaSlide with sourceSlideID match, title `"<orig> (ProRes 422)"`, mediaKind .video, nativeFrameRate threaded, fresh UUID, written file at destination, jobs list drains. |
| `TranscodeCoordinatorTests.testCancelAllCancelsRunningJobs` | After `cancelAll()`, jobs list drains; completion fires `.cancelled` or `.success` (race window), no leak. |

Total: 269 tests, all green (was 257 at session start).

---

## Manual verification needed (session 9 deltas)

These need human eyeballs and real operator-supplied media — autonomous tests don't drive SwiftUI context menus.

1. Save a fresh project to disk. Drop in a typical H.264 .mp4 (a phone clip, a screen recording — anything that lights the yellow `Long-GOP` chip in C1's cue inspector). Right-click the slide tile in the asset library palette. Confirm `Transcode to ProRes 422` and `Transcode to ProRes 4444` items appear. Pick ProRes 422.
2. The non-modal progress strip should appear above the palette transition controls: `<original-title> (ProRes 422)` / linear progress bar / percent / cancel ✕. The progress should advance smoothly (the modern `states(updateInterval:)` API ticks at 0.2 s).
3. On completion, a new sibling slide titled `<original> (ProRes 422)` appears immediately after the source in the palette grid and is auto-selected. Open the cue inspector. The yellow C1 chips that fired on the H.264 source should be **gone** on the ProRes sibling (long-GOP and 10-bit-4:2:0 cleared by definition; untagged-color may persist if the source had no color tags).
4. Browse `<project.spb>/Transcoded/` in Finder. The `<UUID>.mov` should be there. Open it in QuickTime — the file plays (basic sanity). Inspect with `mediainfo` or `ffprobe` — codec is ProRes 422 family.
5. Right-click on a still image (.png, .jpg). Confirm no transcode menu items appear (canTranscode is false for images).
6. Right-click on a video whose source file you've moved to the trash. Confirm no transcode menu items appear (resolvedURL → nil).
7. Drop a long video, kick off a transcode, click ✕ on the strip row. The row disappears; no sibling slide appears. The partial output file is removed (the job clears the destination on the next start; today there's no explicit cleanup of cancelled-output files — a future cleanup pass would reconcile orphaned `Transcoded/<UUID>.mov` files against `project.slides`).
8. Toggle to Show Mode (Cmd-Shift-L). Right-click a video. The transcode menu items should not appear.
9. Drop into an *untitled* (unsaved) document. Right-click → transcode runs into `~/Library/Application Support/Simple Playback/Transcoded/<sessionUUID>/<UUID>.mov`. Save the project, restart, reopen — the sibling slide resolves via absolute path.
10. Right-click on a ProRes-already source. The menu still offers ProRes 422 / 4444 (no harm; operator may want a specific variant). Inspector flag chips should be empty for the source already; doing this is wasteful but not incorrect.

---

## What shipped in session 8 (C6)

### C6a — `KeynoteImporter`

- **`Services/KeynoteImporter.swift`** — `enum KeynoteImporter` with three entry points: `isKeynoteInstalled() -> Bool` (queries `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` for `com.apple.iWork.Keynote`), `exportToPDF(keynoteURL:destinationDirectory:) throws -> URL` (drives Keynote via `NSAppleScript`), and `exportAppleScript(keynoteURL:pdfURL:) -> String` (pure-string AppleScript text, exposed for shape tests).
- **AppleScript** — minimal: `tell application "Keynote" / activate / open POSIX file "<src>" / export theDoc to POSIX file "<pdf>" as PDF / close theDoc saving no / end tell`. Path strings escape `"` and `\` for AppleScript string literals. The `close … saving no` is critical — the operator's deck stays untouched on disk after import.
- **Errors** — `KeynoteImportError` is `.keynoteNotInstalled`, `.unreadable(URL)`, `.exportFailed(String)`. The exporter wraps `NSAppleScript.executeAndReturnError(_:)` and converts the error dictionary into `.exportFailed`.
- **Test seam** — `static var workspaceProvider: (String) -> URL?` lets tests simulate Keynote installed/absent without depending on the host machine's Keynote install. Tests `setUp`/`tearDown` save and restore the provider so test-order independence holds.
- **Why the indirection over a `protocol Workspace`** — single-test-overridable static var is simpler, has no virtual-call cost, and matches the pattern used elsewhere in the importer surface.
- 9 tests cover bundle-ID identity, install-detection branches, query-by-correct-bundle-ID, error mapping for absent-Keynote and missing-source, AppleScript shape (tell-application block, POSIX file paths, close-without-saving), and quote/backslash escaping in path interpolation.

### C6b — `MediaImporter` Keynote routing

- **`Services/MediaImporter.swift`** — new `static var keynoteExporter: (URL, URL) throws -> URL` test seam, defaults to `KeynoteImporter.exportToPDF`. The `importSlides(from:context:)` overload now branches on `isKeynote(url)` after the existing `isPDF(url)` branch and routes through `importKeynote(at:context:)`.
- **`importKeynote`** — creates a per-batch UUID subdirectory under `context.renderRootDirectory`, calls `keynoteExporter` to land an intermediate PDF inside, then calls `PDFImporter.rasterize` to fan it into PNG sidecars in the same directory. The intermediate PDF stays alongside the PNGs so a future "Re-rasterize on Stage resize" command (deferred from C3) can re-render from it without re-driving Keynote.
- **`isKeynote(_:)`** — UTType-aware (`com.apple.iwork.keynote.key`) with extension fallback (`.key` / `.KEY`). Mirrors the C3 `isPDF(_:)` predicate shape.
- **No-context fallthrough** — like C3, the no-context overload silently drops `.key` URLs (no place to write the intermediate PDF or PNGs without a context). UI callers must pass a context; legacy non-UI callers get the same back-compat behavior they did for PDFs.
- 5 tests cover `isKeynote` recognition (.key and .KEY accepted; .pdf, .png, .mov rejected), no-context-drops-.key, Keynote-not-installed-returns-empty (verified via `KeynoteImporter.workspaceProvider` swap), success path through an injected exporter that synthesizes a 5-page PDF (5 image MediaSlides with resolvable URLs and `<deck-name> — page N` titles), and exporter-throws-returns-empty.

### C6c — RootView wiring + entitlements + diagnostic

- **`Views/RootView.swift`** — open panel `allowedContentTypes` now appends the Keynote UTType when `UTType("com.apple.iwork.keynote.key")` resolves (which it does on every modern macOS). The drop handler is unchanged (already accepts any `UTType.fileURL`); routing happens in the importer.
- **Diagnostic** — `addMedia(_:)` filters incoming URLs for `.key` and, if any are present and `KeynoteImporter.isKeynoteInstalled()` is false, presents an `NSAlert` (warning style, "Keynote not installed" / "Install Keynote from the App Store to import .key files. Other dropped or selected media will still be imported."). The alert only fires from Edit Mode (the function early-exits in Show Mode), preserving the §3.5 modal-forbidden invariant. Non-key media in the same batch still imports.
- **Entitlement** — `Simple Playback/Support/SimplePlayback.entitlements` adds `com.apple.security.automation.apple-events = true`. Required because Release config has `ENABLE_HARDENED_RUNTIME: YES`; without the entitlement, `NSAppleScript` returns `errAEEventNotPermitted` to any cross-process Apple Event. macOS still presents its standard "Allow Simple Playback to control Keynote?" prompt on first send.
- **Info.plist** — adds `NSAppleEventsUsageDescription` ("Simple Playback uses Apple Events to drive Keynote so it can export .key decks to PDF for slide rasterization.") — the message inside macOS's standard automation prompt.
- No new tests (UI wiring is exercised by manual rehearsal step 7 below; the diagnostic logic itself is reachable through `MediaImporter.isKeynote` + `KeynoteImporter.isKeynoteInstalled`, both already covered).

---

## Tests added (session 8)

| Test | What it covers |
|---|---|
| `KeynoteImporterTests.testKeynoteBundleIDMatchesApplesIdentifier` | Bundle ID is `com.apple.iWork.Keynote` (renaming would break detection). |
| `KeynoteImporterTests.testIsKeynoteInstalledTrueWhenWorkspaceProviderReturnsURL` | Install detection wired correctly. |
| `KeynoteImporterTests.testIsKeynoteInstalledFalseWhenWorkspaceProviderReturnsNil` | Absence detection wired correctly. |
| `KeynoteImporterTests.testIsKeynoteInstalledQueriesTheKeynoteBundleID` | The detection actually queries Keynote's bundle ID, not some other constant. |
| `KeynoteImporterTests.testExportToPDFThrowsKeynoteNotInstalledWhenAbsent` | Absent-Keynote → `.keynoteNotInstalled`. |
| `KeynoteImporterTests.testExportToPDFThrowsUnreadableWhenSourceMissing` | Missing source → `.unreadable`. |
| `KeynoteImporterTests.testExportAppleScriptIsKeynoteTellBlock` | AppleScript text targets Keynote by name. |
| `KeynoteImporterTests.testExportAppleScriptOpensSourceAndExportsToPDF` | AppleScript shape: open source via POSIX file, export as PDF, close without saving. |
| `KeynoteImporterTests.testExportAppleScriptEscapesQuotesAndBackslashes` | Path-string escape contract for AppleScript literals. |
| `MediaImporterKeynoteTests.testIsKeynoteRecognizesByExtension` | `.key`/`.KEY` accepted; `.png`/`.pdf`/`.mov` rejected. |
| `MediaImporterKeynoteTests.testReturnsEmptyForKeynoteWhenContextIsAbsent` | No-context overload silently drops `.key` (back-compat for legacy callers). |
| `MediaImporterKeynoteTests.testReturnsEmptyForKeynoteWhenKeynoteNotInstalled` | Keynote-absent path returns empty array (UI surfaces banner). |
| `MediaImporterKeynoteTests.testRoutesKeynoteThroughExporterAndProducesImageSlides` | End-to-end: `.key` URL → injected exporter → PDFImporter → 5 image MediaSlides with resolvable URLs and zero-padded page titles. |
| `MediaImporterKeynoteTests.testReturnsEmptyWhenExporterThrows` | Any exporter error swallowed → empty array. |

Total: 257 tests, all green (was 243 at session start).

---

## Manual verification needed (session 8 deltas)

These need a real Keynote install + a `.key` file. Autonomous tests cover the routing and the Keynote-absent path; live AppleScript / Apple-events permission UX needs human eyeballs.

1. With Keynote installed, save a fresh project to disk (so it has a `fileURL`). Drag a multi-slide `.key` file into the asset library palette. macOS should present its standard "Simple Playback wants to control Keynote" prompt on first invocation; click "OK". Keynote opens, exports the deck to PDF, closes (without saving). Asset library populates with one image MediaSlide per Keynote slide. Browse `<project.spb>/Cache/Renders/<UUID>/` in Finder; the PDF + the PNG sidecars should both be there.
2. With Keynote installed, but with the Apple-events permission previously denied (`System Settings → Privacy & Security → Automation → Simple Playback → Keynote = OFF`), drop a `.key`. The import should fail silently (returns 0 slides) with no crash. To re-enable, the operator toggles the switch in System Settings.
3. Without Keynote installed (uninstall, or rename `Keynote.app` aside), drop a `.key`. The "Keynote not installed" `NSAlert` appears. Other media in the same drop should still import correctly.
4. Use **Add Media…** (toolbar) to pick a `.key` file. Same result as drop.
5. Drop a Keynote deck whose slides mix portrait and landscape orientations. Each slide is independently fit-into the raster; mixed-orientation decks browse correctly. (Inherits PDF behavior from C3.)
6. Save the project, restart Simple Playback, reopen. The Keynote-derived slides resolve from the bundle's `Cache/Renders/<UUID>/` PNG paths.
7. Drop into an *untitled* (unsaved) document. Slides appear; the intermediate PDF + PNGs land in `~/Library/Application Support/Simple Playback/Renders/<sessionUUID>/<batchUUID>/`. Save the project, restart, reopen — slides resolve via absolute path. (Same untitled-doc pattern as C3; same future "Bundle for Travel" pickup.)

---

## What shipped in session 7 (C3)

### C3a — `PDFImporter.rasterize(...)`

- **`Services/PDFImporter.swift`** — `rasterize(pdfURL:rasterSize:destinationDirectory:) throws -> [URL]`. PDFKit-backed; opens a `PDFDocument`, walks pages, scales each page's mediaBox to fit within the caller's `rasterSize` while preserving aspect, draws into a `CGContext`-backed bitmap, writes a PNG sidecar per page. The destination directory is created on demand; per-page filenames are zero-padded (`page_001.png`, `page_012.png`, ...) so lexicographic sort matches page order at any future "Asset Library" listing.
- **Pixel target convention**: the output PNG dimensions are the *scaled-to-fit* size, not literal `rasterSize`. For a Letter PDF (612×792) at 1920×1080 raster, the PNG comes out ~834×1080 — height-limited at 1080, aspect-preserved. For a 16:9 PDF (1600×900) at 3840×2160 raster, it lands at exactly 3840×2160. The compositor still applies `ScaleMode.fit/fill/stretch` on top per cue.
- **Why scale-to-fit not scale-to-fill**: PDF page aspect varies (Letter portrait, A4 portrait, 16:9 export, 4:3 export). Stretching would distort PowerPoint→PDF→PNG decks; cropping (fill) would silently lose content. The compositor downstream is the right place to express scaling intent per cue.
- **Errors**: `PDFImportError.unreadable(URL)` for a corrupt or non-existent PDF, `.noPages(URL)` for an empty PDF, `.writeFailed(URL, underlying:)` for filesystem errors. Per-page render failures (`makeImage()` returning nil) are silently skipped — better to import 11 of 12 pages than throw mid-batch.
- 8 tests cover happy path (file count, leading-zero naming, fit aspect preserved, output × 2 pixel target on a matched-aspect page, missing-directory creation) and the `.unreadable` error.

### C3b — `MediaImporter.importSlides(from:context:)`

- **`Services/MediaImporter.swift`** — new `MediaImportContext { rasterSize: CGSize, renderRootDirectory: URL }`, new `importSlides(from urls: [URL], context: MediaImportContext?) -> [MediaSlide]` overload. PDFs route through `PDFImporter.rasterize`; non-PDFs go through the existing `mediaKind` path unchanged. Each PDF batch lands in `<renderRootDirectory>/<UUID>/page_NNN.png` so concurrent imports don't collide.
- **Backwards-compat**: `importSlides(from:)` (no context) still exists and silently drops PDFs (no place to write rasters without a context). Callers that need PDF support pass the context-aware overload. This keeps existing tests immutable and gives non-UI callers (future automation, CLI) a path that works without UI plumbing.
- **Public `MediaImporter.isPDF(_:)`** — UTType-aware PDF detection (content type → extension → fallback to lowercased extension match). Used by the importer; testable in isolation.
- 4 tests pin the contract: PDF + context → N image slides with resolvable URLs, PDF without context → empty array, non-PDF inputs unchanged across both overloads, `isPDF` recognizes `.pdf` / `.PDF` and rejects `.png` / `.mov`.

### C3c — RootView wiring

- **`Views/RootView.swift`** — drop handler and Add Media open panel both call `currentMediaImportContext()`, which builds:
  - `rasterSize = (Stage.first.width, Stage.first.height) × 2` (spec §3.10's "output × 2"); falls back to `outputWidth`/`outputHeight` if no Stage is configured.
  - `renderRootDirectory = projectBundle/Cache/Renders` when the document has a `fileURL`, else `Application Support/Simple Playback/Renders/<sessionUUID>` for untitled documents (the `sessionUUID` is `@State`-stable per window so concurrent untitled windows don't collide).
- **`ProjectBundleLayout.rendersDirectory = "Cache/Renders"`** — pinned to spec §3.17 layout.
- **`SimplePlaybackProjectDocument.makeWindowControllers`** — passes a `[weak self] in self?.fileURL` closure as `projectBundleURLProvider`. RootView reads the bundle URL on every import, so the path stays current after first-save (where `fileURL` flips from nil to the saved bundle path). Existing untitled-doc imports in the app-support fallback continue to resolve via their absolute paths in `MediaSlide.media`; a future "Bundle for Travel" command (§3.17) would migrate them into the bundle.
- **Open panel** — `.allowedContentTypes` now includes `.pdf` alongside `.image` / `.movie` / `.video`.

---

## Tests added (session 7)

| Test | What it covers |
|---|---|
| `PDFImporterTests.testRasterizeWritesOnePNGPerPage` | 3-page PDF → 3 PNG files exist on disk. |
| `PDFImporterTests.testRasterizeNamesPagesInOrderWithLeadingZeros` | `page_001.png` … `page_012.png` — zero-padded so lexicographic sort matches page order. |
| `PDFImporterTests.testRasterizeFitsWithinRasterSizePreservingAspect` | Letter (612×792) at 1920×1080 raster → height-limited at 1080, aspect ≈ 612/792 within 0.005. |
| `PDFImporterTests.testRasterizeAtOutputTimesTwoProducesExpectedPixelTarget` | 16:9 page at 3840×2160 raster lands exactly 3840×2160. |
| `PDFImporterTests.testRasterizeCreatesDestinationDirectoryIfMissing` | Two-deep target directory created on demand. |
| `PDFImporterTests.testRasterizeThrowsOnUnreadablePDF` | Bogus URL → `.unreadable` error. |
| `MediaImporterPDFTests.testRoutesPDFThroughContextAndProducesImageSlides` | 4-page PDF → 4 `.image` MediaSlides whose URLs resolve to written PNGs; titles include page numbers. |
| `MediaImporterPDFTests.testReturnsEmptyForPDFWhenContextIsAbsent` | No-context overload silently drops PDFs (back-compat for legacy callers). |
| `MediaImporterPDFTests.testNonPDFInputsAreUnaffectedByContextSignature` | Stills work the same with or without a context. |
| `MediaImporterPDFTests.testIsPDFRecognizesByExtensionAndUTType` | `.pdf` / `.PDF` recognized, `.png` / `.mov` rejected. |

Total: 243 tests, all green (was 233 at session start).

---

## Manual verification needed (session 7 deltas)

1. Save a fresh project to disk (so it has a `fileURL`). Drag a multi-page PDF into the asset library palette. The asset library should show one image slide per page, titled `<filename> — page N`. Browse into `<project.spb>/Cache/Renders/<UUID>/` in Finder; the PNGs should be there.
2. Drop a PDF into an untitled (unsaved) document. Slides appear; PNGs land in `~/Library/Application Support/Simple Playback/Renders/<sessionUUID>/<batchUUID>/`. Save the project, restart the app, reopen — slides resolve via absolute path. (Future "Bundle for Travel" task would copy them into the bundle.)
3. Use **Add Media…** (toolbar) to pick a PDF. Same result as drop.
4. Drop a Letter portrait PDF and a 16:9 landscape PDF. Each renders at the largest size that fits within Stage × 2 with aspect preserved. The compositor's `ScaleMode.fit` (default) presents them centered with bars when the Stage aspect differs from the PDF page aspect.
5. Drop a corrupt or zero-page PDF. Nothing imports; the app does not crash. (Operator feedback for failed-import is deferred to a future "import status banner" task — see C2 transcode toast pattern.)
6. Drop a PDF whose pages mix orientations (some portrait, some landscape). Each page is independently fit-into the raster; mixed-orientation decks browse correctly.

---

## What shipped in session 6 (C1)

### C1a — Pure-logic flag model + evaluator

- **`Models/MediaFlags.swift`** — `MediaFlags` (Codable / Hashable) with four booleans matching spec §3.10's transcoding-posture warnings: `longGOP`, `variableFrameRate`, `tenBitYUV420`, `untaggedColor`. `MediaFlags.none` for "no flags / not inspected", `hasAnyFlag` accessor for inspector short-circuit, `activeWarnings` returns the warning kinds in stable order (long-GOP first, untagged color last — most-to-least actionable).
- **`CodecFamily`** enum — maps a CoreMedia FourCC (`avc1`, `hvc1`, `apch`, `AVdn`, …) into an explicit family. `isLongGOPCapable` is a property of the family (true only for H.264 / HEVC). Conservative — unknown codecs default to `.other` / `false`, so we miss flags rather than false-positive on intra codecs we haven't characterized.
- **`MediaFlagsEvaluator.evaluate(...)`** — pure-logic combiner that takes the structured properties (codec family, bits per component, chroma 4:2:0 hint, color-primaries-tag presence, frame-rate-inconsistent boolean) and produces a `MediaFlags`. AVFoundation is intentionally not imported here — the adapter calls in. That split makes every rule unit-testable without committing fixture media.
- **`MediaFlagsEvaluator.warning(for:)`** — operator-facing copy. Spec §3.10 wording is preserved verbatim where the spec was prescriptive ("Long-GOP — may not scrub frame-accurately." / "Variable frame rate — will not loop seamlessly." / "10-bit 4:2:0 HEVC — limited hardware decode." / "Untagged color — treating as sRGB.").
- 25 tests cover the evaluator matrix (long-GOP true/false, VFR true/false, 10-bit 4:2:0 only on HEVC at 4:2:0 + ≥10-bit, untagged true/false, missing-bits-treated-as-8-bit), CodecFamily mapping for the common FourCCs, warning-copy contracts, `hasAnyFlag`, `activeWarnings` ordering, JSON round-trip, legacy-`{}`-decodes-to-none, and partial-JSON-defaults-to-false.

### C1b — AVFoundation adapter populates flags at import

- **`Services/MediaFlagsInspector.swift`** — `inspect(url: URL) -> MediaFlags`. Synchronous on the import thread; never throws (any inspection failure returns `.none`).
  - Codec from `CMFormatDescriptionGetMediaSubType` (FourCC → `CodecFamily`).
  - Color tagging from `kCMFormatDescriptionExtension_ColorPrimaries` presence.
  - Bit depth from `kCMFormatDescriptionExtension_BitsPerComponent` first; falls back to substring search ("Main 10" / "10-bit") on `kCMFormatDescriptionExtension_FormatName`. Documented limitation: HEVC sources that expose neither extension are not flagged 10-bit. Better than false-positive.
  - 4:2:0 chroma — for HEVC, default to true (overwhelming convention for SDR HEVC) and downgrade if `FormatName` explicitly says 4:2:2 / 4:4:4. For non-HEVC, irrelevant — the evaluator only consults chroma for HEVC.
  - VFR — `nominalFrameRate <= 0` OR derived rate from `minFrameDuration` differs from declared by >0.1%. False negatives on cleanly-muxed VFR are a known v1 limitation (a real timestamp scan is out of scope for the import path).
- **`MediaSlide.flags: MediaFlags`** — new field, populated at import in `MediaImporter.importSlides(from:)`. Round-tripped via `decodeIfPresent` so legacy projects (every project saved before this commit) decode with `flags == .none`.
- 6 adapter tests using a freshly synthesized AVAssetWriter movie at test time (H.264 → flags long-GOP, ProRes → suppresses long-GOP) plus missing-file / non-video-file safe-return tests.

### C1c — Inspector chips

- **`MediaFlagWarningChip`** in `Views/RootView.swift` — single-line yellow info chip per active flag. Yellow palette (FYI — informational metadata caveat) is deliberately distinct from the orange FPS-mismatch banner above (action recommended — transcode for a Stage-rate copy). Operators reading the inspector at a glance can tell shape problems from metadata caveats by color alone.
- Chips render below the existing FPS conformance warning in `CueInspectorView`, in `MediaFlags.activeWarnings` order. Hover help text directs the operator to the eventual right-click → Transcode-to-ProRes-422 action (C2, not yet shipped).

---

## Tests added (session 6)

| Test | What it covers |
|---|---|
| `MediaFlagsTests.testCodecFamilyIdentifiesH264FourCCs` | `avc1` / `avc3` → `.h264`. |
| `MediaFlagsTests.testCodecFamilyIdentifiesHEVCFourCCs` | `hvc1` / `hev1` / `dvh1` → `.hevc`. |
| `MediaFlagsTests.testCodecFamilyIdentifiesProResVariants` | All six ProRes FourCCs (`apco`/`apcs`/`apcn`/`apch`/`ap4h`/`ap4x`) → `.proRes`. |
| `MediaFlagsTests.testCodecFamilyHandlesIntraOnlyCodecs` | DNx / Animation / MJPEG / uncompressed FourCCs. |
| `MediaFlagsTests.testCodecFamilyDefaultsToOtherForUnknown` | Unrecognized codes default to `.other` (not `.unknown` — `.unknown` is reserved for "I haven't inspected"). |
| `MediaFlagsTests.testLongGOPCapability` | Family-level long-GOP capability per spec §3.10. |
| `MediaFlagsTests.testEvaluatorFlagsH264AsLongGOP` / `…ProResAsLongGOP` | H.264 flagged; ProRes never. |
| `MediaFlagsTests.testEvaluatorFlagsVFRWhenFrameRateInconsistent` / `…WhenFrameRateConsistent` | VFR boolean threading. |
| `MediaFlagsTests.testEvaluatorFlagsHEVCMain10AsTenBit420` | HEVC + 10-bit + 4:2:0 → flagged. |
| `MediaFlagsTests.testEvaluatorDoesNotFlag8BitHEVCAsTenBit420` | 8-bit HEVC → not flagged. |
| `MediaFlagsTests.testEvaluatorDoesNotFlag10BitHEVCInOtherChromaSamplings` | 10-bit 4:2:2 HEVC → not flagged (Apple Silicon decodes those fine). |
| `MediaFlagsTests.testEvaluatorDoesNotFlag10BitProResAsTenBit420` | 10-bit ProRes → not flagged (intra, hardware-irrelevant). |
| `MediaFlagsTests.testEvaluatorTreatsMissingBitDepthAs8Bit` | `nil` bits-per-component → never trips the 10-bit flag. |
| `MediaFlagsTests.testEvaluatorFlagsUntaggedColor` / `…DoesNotFlagTaggedColor` | Untagged-color boolean threading. |
| `MediaFlagsTests.testTenBit420PixelFormatCodesIncludesBothRanges` | `x420` (video range) and `xf20` (full range) both in the constant set. |
| `MediaFlagsTests.testHasAnyFlagFalseForCleanMedia` / `…TrueWhenAnySingleFlagSet` | `hasAnyFlag` short-circuit. |
| `MediaFlagsTests.testActiveWarningsOrderIsStable` | Inspector chip order is locked. |
| `MediaFlagsTests.testWarningStringsMatchSpec` | Spec §3.10 wording is exact (treated as a contract). |
| `MediaFlagsTests.testMediaFlagsRoundTripsThroughJSON` / `…LegacyJSONDecodesToAllFalse` / `…PartialJSONDecodesMissingFieldsAsFalse` | Codable shape + legacy decode. |
| `MediaFlagsTests.testMediaSlideLegacyJSONWithoutFlagsDecodesToNoneFlags` | Pre-C1 slides decode with `flags == .none`. |
| `MediaFlagsTests.testMediaSlideRoundTripsFlags` | New slides round-trip through encode/decode. |
| `MediaFlagsTests.testInspectorFlagsLongGOPForSynthesizedH264Movie` | AVFoundation adapter, end-to-end, flags long-GOP for an H.264 movie generated by AVAssetWriter at test time. |
| `MediaFlagsTests.testInspectorDoesNotFlagLongGOPForSynthesizedProResMovie` | Adapter does not flag long-GOP / 10-bit-4:2:0 for ProRes 422. |
| `MediaFlagsTests.testInspectorReturnsNoneForMissingFile` / `…ForNonVideoFile` | Missing files / still images return `.none` rather than throwing. |

Total: 233 tests, all green (was 202 at session start).

---

## Manual verification needed (session 6 deltas)

These need human eyeballs — autonomous tests don't drive SwiftUI inspectors.

1. Import a typical H.264 .mp4 from a phone or screen capture into a project. Open the cue inspector. The yellow `Long-GOP — may not scrub frame-accurately.` chip should appear below the existing orange FPS-mismatch warning (if the rate also disagrees with the Stage). Untagged-color chip may also appear depending on whether the source has color tags.
2. Import a ProRes 422 export from Final Cut / Compressor. The cue inspector should show **no** flag chips (ProRes is intra, color-tagged, CFR).
3. Import an HEVC Main 10 source (e.g. an iPhone HDR clip or a 10-bit graded export). The inspector should show `Long-GOP` and `10-bit 4:2:0 HEVC — limited hardware decode.`. The 10-bit flag depends on the source's format-name / bits-per-component extension; some encoders don't tag it (documented limitation — chip won't appear).
4. Import a clip you know is VFR (a screen recording, a Twitch VOD). The `Variable frame rate — will not loop seamlessly.` chip should appear. Note the v1 detection is metadata-only — cleanly-muxed VFR may still not flag.
5. Save the project, reopen it. Flags persist on disk via `MediaSlide.flags`.
6. Re-open a project saved before this session. Slides decode with `flags == .none` (no chips appear) — they re-flag only on next re-import. Documented limitation; a future "Refresh inspector flags" action could re-run the inspector across the asset library.

---

## Still deferred (session 11+)

**Phase B leftovers** (mostly hardware-bound):
- **B6 (remaining)** — REF format-mismatch detection vs Stage frame rate. Needs a Blackmagic SDK spike against newer interfaces; possible blocker.
- **B7** — DeckLink format negotiation. Has product-UX questions (mid-show re-arm flow — modal? non-modal banner?) that warrant a fresh session with options surfaced to the user.
- **B8 (remaining)** — Apply the `recommendsTenBitOutput` recommendation as the actual default at DeckLink-binding-creation time. Today there's no UI surface that creates DeckLink bindings; once one exists (B7-adjacent), pre-fill `tenBit` from `project.recommendsTenBitOutput`. Hardware verification of the 10-bit format negotiation against a real card remains operator-driven.
- **B11** — NDI Full sender as a `TransportSink`. Independent of DeckLink. Needs the NDI SDK as a new dependency — confirm license + size in `decision_log.md` first.
- **B13** — Color pipeline (sits on top of B5+B12).
- **B9 / B15 / B10** — long tail.
- **B16** — final Phase B summary + DeckLink mock layer for tests.

**Phase C remaining** (autonomy-friendly):
- **C7+** — Asset library, audio engine, subtitles, etc. Larger phase items. C7 (linked-vs-managed media + security-scoped bookmarks) is the biggest of these. C12 (audio engine refactor) sits behind a hardware question — what device tier is in scope for v1.

**Phase C plumbing follow-ups** (small, ergonomics):
- **Re-rasterize on Stage resize** — PDFs / Keynote decks rasterized at 1080p stay 1080p when the operator bumps the Stage to 2160p. C6's intermediate PDF stays in `Cache/Renders/<UUID>/` exactly so this can re-use the same source without re-driving Keynote. Architectural note: today `MediaSlide` doesn't track its source PDF/Keynote URL — adding that link is the prerequisite.
- **Compact project** — `<bundle>/Transcoded/<UUID>.mov` and `<bundle>/Cache/Renders/<UUID>/` accumulate when the operator deletes the corresponding MediaSlides. A future "Compact project" action would walk the bundle and remove orphans no slide resolves to. Also the right home for cancelled-encode partial-file cleanup.
- **Cancelled transcode / encode partial-file cleanup** — known C2 + C5c gap; cancelled jobs leave a partial `<bundle>/Transcoded/<UUID>.mov` until the next start. A cleanup pass on cancellation (or "Compact project") would reconcile.
- **Image-sequence custom frame-rate validation** — the C5c sheet's custom integer field accepts any number; values < 1 are gated by the encoder, but a typo like `300` would silently encode at 300 fps. A future tightening could clamp the field range or warn at confirm-time.
- **Per-clip transcode preset hint** — today both ProRes 422 and ProRes 4444 are always offered. A smarter menu would highlight ProRes 4444 when the source has alpha and ProRes 422 otherwise. (`preferredPresetOrder` already orders correctly; the menu doesn't visually differentiate.)
- **Bulk transcode action** — operators with 50 phone clips would have to right-click each one. A future "Transcode all flagged clips…" action could iterate `project.slides.filter { $0.flags.hasAnyFlag }`.

**Recommended next pick**: **E1 (pre-show check panel)** — Phase E start, clean phase boundary, reuses `B14` (`FrameRateConformance` evaluator across every cue × Stage rate) and `B8` (`recommendsTenBitOutput`) as ready-made check rows. Spec §7. The pre-show panel is many small independently-testable rows; a session can ship a row at a time. **B11 (NDI Full sender)** is the next contained Phase B item once the NDI SDK dependency call is made — confirm license + binary size in `decision_log.md` before adding. **B7 (DeckLink format negotiation)** has UX questions worth filing as a blocker before scoping. **C7 (asset library — linked vs managed + security-scoped bookmarks)** is bigger and would consume most of a session by itself.

### Known gaps in the C6 Keynote import path

- **AppleScript timeout / hang on encrypted decks.** A password-protected `.key` file makes Keynote pop a password dialog; `NSAppleScript.executeAndReturnError` is synchronous and will block until the operator dismisses the dialog (or, on quit-Keynote, fail). A future iteration could move to `Process` + `osascript -e` with a hard timeout, plus a `.passwordProtected` error case.
- **No verification of Apple Events permission state.** If the operator denied the macOS automation prompt for Keynote, every subsequent `.key` import returns 0 slides silently. A future "Open Automation settings" affordance from a banner would close the loop.
- **AppleScript export style not pinned.** Keynote occasionally exports as a single-page "handout" PDF rather than one-slide-per-page. If a real rehearsal hits this, add `with properties {export style:IndividualSlides}` to the AppleScript and pin the new shape in `testExportAppleScriptOpensSourceAndExportsToPDF`.
- **No live-AppleScript test coverage.** Real Keynote can't run in CI — we test the routing chain via an injected exporter that synthesizes a PDF. The success of the live AppleScript exchange depends on manual rehearsal.
- **Same `Stage resize` and `import status banner` gaps as C3** — Keynote-derived slides inherit those.

### Known gaps in the C2 transcode path

- **Failures are silent.** `TranscodeError.exportFailed` makes the progress strip row disappear with no UI indication of why. Pair with the deferred import-status banner so PDF / Keynote / transcode failures surface consistently.
- **Cancelled jobs leave partial files.** Today the destination URL is cleared on the next start, but a cancelled transcode's `.mov` lingers in `<bundle>/Transcoded/` until then. A future cleanup pass on cancellation (or the "Compact project" action above) would reconcile.
- **Inspector flag chips don't auto-route.** Operators reading the inspector see `Long-GOP — may not scrub frame-accurately.` and have to know to right-click the *asset library tile*, not the cue inspector itself, to find the action. A future affordance: a "Transcode this clip" button inline with the chip.
- **No per-clip preset hint.** Today both ProRes 422 and ProRes 4444 are always offered. A smarter menu would highlight ProRes 4444 when the source has alpha (animated GIF/APNG, ProRes 4444 sources) and ProRes 422 otherwise.
- **No bulk transcode.** Operators with 50 phone clips would have to right-click each one. A future "Transcode all flagged clips…" action could iterate `project.slides.filter { $0.flags.hasAnyFlag }`.
- **No live AVFoundation verification.** End-to-end test transcodes an AVAssetWriter-synthesized H.264 source (≤4 frames, 32×32 px) to ProRes 422. Real-world variety (10-bit HEVC HDR, VFR screen captures, multi-track sources, encrypted media, sources with embedded chapters) needs human eyeballs.

### Known gaps in the C3 import path

- **No operator feedback on failed imports.** A corrupt or zero-page PDF imports zero slides silently. A future "import status banner" (see C2's transcode toast pattern) should expose `PDFImportError` and per-batch counts.
- **Untitled-document portability.** Untitled docs render PDFs to `~/Library/Application Support/Simple Playback/Renders/<sessionUUID>/`. After Save As, the slides resolve via absolute path but live outside the bundle. A future "Bundle for Travel" command (spec §3.17) is what migrates them in.
- **No re-rasterize on Stage resize.** If the operator changes the Stage from 1080p to 2160p mid-project, previously-imported PDFs stay at the old 1080p × 2 raster. A future "Re-rasterize PDF imports" action (or automatic re-render on Stage change) would close the loop.
