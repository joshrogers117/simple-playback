# Simple Playback — Media Pipeline Research

Scope: import, codecs, asset management, audio. Audience: corporate AV, broadcast, large-screen / LED-wall operators. Out of scope here: render/output pipeline, show control / automation, operator UX.

---

## 1. Codec policy

### 1.1 Landscape

- **Mitti**: ProRes is "the best choice ultimately" on Apple Silicon (M1 Pro/Max+) and AfterBurner Macs because of hardware-accelerated ProRes decode. For SDI via Blackmagic, ProRes is preferred (frames travel CPU→DeckLink, no GPU readback). For 4K+ over HDMI/DisplayPort, HAP can outperform ProRes. Mitti exposes a right-click "Transcode to ProRes/HAP" that writes to `~/Movies/Mitti/Transcoded` with audio untouched. (https://imimot.com/help/mitti/cues/, https://imimot.com/blog/mitti-1-5-released/)
- **QLab**: Hap and Hap Alpha recommended for video; ProRes for layering/effects; MP4 acceptable for plain playback. Audio: AIFF/WAV/CAF preferred; MP3 explicitly cautioned because of variable decode latency. (https://qlab.app/docs/v5/video/video-cues/, https://qlab.app/docs/v5/audio/audio-cues/)
- **Resolume**: DXV native; HAP equivalent on perf; HAP-Alpha ~2x file size of DXV-Alpha; ProRes/DXV HQ for quality. (https://resolume.com/software/codec, https://resolume.com/forum/viewtopic.php?t=26109)
- **Disguise / NotchLC**: GPU-decoded, ~10-bit, ~5:1 ratio, dozens of simultaneous 1080p30 / 4K layers. (https://notchlc.notch.one/, https://help.disguise.one/designer/content-management/video-codecs/video-codec-overview)
- **AVFoundation/VideoToolbox**: hardware decode of H.264, HEVC, ProRes, ProRes RAW, AV1 (M3+). ProRes 4444 has native Y416 path. (https://developer.apple.com/videos/play/wwdc2020/10090/, https://wiki.x266.mov/docs/encoders_hw/videotoolbox)
- **Long-GOP H.264/HEVC**: scrubs poorly because every displayed frame requires reference-frame reconstruction. Standard advice: transcode to all-I (ProRes/DNxHR/CineForm). (https://streaminglearningcenter.com/blogs/open-and-closed-gops-all-you-need-to-know.html, https://forum.blackmagicdesign.com/viewtopic.php?f=21&t=125161)

### 1.2 Recommended MVP codec policy

Apple-Silicon-first, DeckLink/SDI-first.

**Tier 1 (recommended, hardware-accelerated, deterministic):**
- Apple ProRes 422 / 422 LT / 422 Proxy — primary playout codec.
- Apple ProRes 4444 — alpha (lower thirds, animated logos).

**Tier 2 (accepted, with caveats — warn, don't transcode silently):**
- H.264 / HEVC — accept as-is. Long-GOP files flagged "may not scrub frame-accurately."
- MP4 with ProRes — common FCP/Resolve deliverable; treat as ProRes.

**Tier 3 (advanced-later):**
- HAP / HAP-Q / HAP-Alpha — for GPU-resident pipelines; parity with QLab/Resolume.
- NotchLC — for LED-volume parity.
- AV1 — accept as-is on M3+.

**Out of scope:** DNxHR/DNxHD, DPX/EXR sequences, DXV (Resolume-only), ProRes RAW.

### 1.3 Transcode-on-import vs play-as-is

Mitti's posture is correct: never silently transcode. Offer one-click "Transcode to ProRes 422" (and later HAP) per-clip or batched, write to a project-relative `Transcoded/` directory, keep a back-reference to the original. Surface in the inspector:

- Long-GOP H.264/HEVC → "May not scrub frame-accurately. Transcode to ProRes for deterministic seek."
- VFR (very common for phone exports) → "Variable frame rate detected. Will not loop seamlessly."
- 10-bit 4:2:0 HEVC → "Limited hardware decode performance for scrubbing."
- Untagged color → see §8.

### 1.4 Triage
- **Must-have**: ProRes 422/4444; H.264; HEVC; MP4; transcode-to-ProRes; codec/GOP inspector.
- **Advanced-later**: HAP family; NotchLC; AV1; batch transcode.
- **Out of scope**: DNx, DXV, ProRes RAW, DPX/EXR.

---

## 2. PowerPoint import on macOS

### 2.1 Constraints
- COM automation is Windows-only.
- Mac PowerPoint AppleScript requires Office installed — unreliable on a playout box.
- ProPresenter 21+ ships native `.pptx` import that does not require Office, preserves text, shapes, media, slide notes, simple animations. (https://support.renewedvision.com/hc/en-us/articles/45377042213011, https://support.renewedvision.com/hc/en-us/articles/34512245702035)
- FreeShow's pragmatic stance: convert to PDF and import the PDF. They explicitly converged on PDF as the highest-fidelity-without-Office path. (https://freeshow.app/docs/importing, https://github.com/ChurchApps/FreeShow/issues/491)
- `python-pptx` parses `.pptx` Open XML without Office but does not render. (https://python-pptx.readthedocs.io/)
- LibreOffice headless renders `.pptx → PDF` reliably. The direct `--convert-to jpg` path emits only the first slide; the de facto pattern is `pptx → pdf → page-images`. (https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html, https://www.systutorials.com/how-to-convert-pptx-slides-to-jpg-or-png-images-on-linux-in-command-line/)

### 2.2 Operator expectation

ProPresenter's importer sets the bar at: text editable, simple builds preserved, embedded media preserved, slide notes preserved. Custom fonts, complex animations, and live data hooks are *not* expected to round-trip.

### 2.3 Recommendation for Simple Playback

1. **Render-to-images (default, MVP)**: bundled or detected LibreOffice → PDF → PDFKit page-render at 2× output resolution. Pages become slides. No editability, perfect "what you see in PowerPoint." This matches FreeShow's converged behavior; corporate operators build elsewhere and play here.
2. **PDF passthrough**: if user has the deck as PDF (their own export), skip LibreOffice and go to §4.
3. **Native parse (advanced-later)**: OOXML parsing (Swift port of `python-pptx`-style logic, or third-party SDK) to extract text and notes for search/inspector. Augments rendered images.

Animation simulation is out of scope for MVP — corporate operators want a clean cut between deck and video.

### 2.4 Triage
- **Must-have**: PDF pass-through; LibreOffice-backed `.pptx → PDF → bitmaps`; per-slide notes capture; font-substitution warnings.
- **Advanced-later**: native OOXML parse for search/notes; build-step extraction.
- **Out of scope**: live editing of imported decks; round-trip back to `.pptx`; animations.

---

## 3. Keynote import on macOS

### 3.1 Constraints
- `.key` is an Apple bundle (IWA / protobuf, undocumented). Direct parse is brittle and unsupported.
- Keynote AppleScript `export` supports image, PDF, movie, PowerPoint, HTML — image and PDF exports are reliable per-slide. (https://iworkautomation.com/keynote/document-export.html, https://www.macscripter.net/t/keynote-movie-export-droplet-with-prores-4444-1920-x-1080/72090)
- Sandbox automation entitlement required: `NSAppleEventsUsageDescription`, `com.apple.security.automation.apple-events`, plus `com.apple.security.scripting-targets` for `com.apple.iWork.Keynote`.

### 3.2 Recommendation
1. Default: AppleScript-driven Keynote → PDF → PDFKit page render (§4). Preserves typography because text is in the PDF.
2. Fallback: Keynote → image export when the deck has video/transparency.
3. Builds: out of scope. Operators export to ProRes 4444 movie via Keynote and drop the clip in Simple Playback.

If Keynote is not installed, surface a clear "Open this on a machine with Keynote and re-export to PDF or movie" message. Do not attempt direct `.key` parse.

### 3.3 Triage
- **Must-have**: AppleScript → Keynote → PDF; required entitlements; "Keynote not installed" diagnostic.
- **Advanced-later**: Keynote → movie shortcut for build-heavy decks.
- **Out of scope**: direct `.key` parsing.

---

## 4. PDF import

### 4.1 Observations
- PDFKit (native macOS) renders pages at arbitrary scale and DPI; default is 72 dpi. Well-suited to slide-as-page. (https://developer.apple.com/documentation/pdfkit, https://developer.apple.com/videos/play/wwdc2022/10089/)
- FreeShow converged on PDF as the universal interchange and rasterize-on-import for predictability. (https://freeshow.app/docs/importing, https://github.com/ChurchApps/FreeShow/issues/3036)

### 4.2 Recommendation
- Each page = one slide.
- Render eagerly at output resolution × 2 and cache bitmaps in the project cache.
- Preserve a reference to the original PDF for re-render at higher DPI.
- Bitmap-by-default — corporate decks routinely embed Type 3 / subset fonts that misrender in non-PDF.js renderers. Keep an "open original PDF" mode for users who specifically want vector at output.
- Render at the max of all configured outputs' native resolutions, rounded up to next 1080p/2160p tier.

### 4.3 Triage
- **Must-have**: PDFKit rasterize-on-import; pre-render to project cache; per-page slides; speaker-notes if present.
- **Advanced-later**: keep-PDF-vector mode; re-render at higher DPI.
- **Out of scope**: PDF form fields / JS / multimedia annotations.

---

## 5. Image formats and color profiles

### 5.1 Observations
- PNG/JPEG/HEIF/TIFF handled by `ImageIO`; failure modes are color-profile-related, not format-related.
- Display P3 PNG vs sRGB PNG with same RGB triple `(255,0,0)` are different colors. If a P3 asset is treated as sRGB, reds shift orange (and vice-versa). (https://endavid.com/index.php?entry=80, https://developer.apple.com/forums/thread/111818)
- Untagged images are treated as sRGB by macOS; assets authored on wide-gamut displays without profiles look duller on output. (https://community.adobe.com/t5/photoshop-ecosystem-discussions/how-to-color-manage-display-p3-image-file/td-p/10377448)

### 5.2 Recommendation
- Read embedded ICC, convert at import to project working space (Rec.709 default for SDI).
- Surface "untagged image — treating as sRGB" in inspector with override.
- PNG-with-alpha: treat as straight on import, premultiply in compositor.

### 5.3 Animated GIF / APNG
GIF is 256-color, no alpha, large, not hardware-decoded; APNG is full-color but also not hardware-decoded. Recommendation: detect on import and offer one-click "Convert to ProRes 4444 (with alpha) clip." (https://www.1-converter.com/blog/gif-vs-mp4)

### 5.4 Triage
- **Must-have**: PNG/JPEG/TIFF/HEIF; ICC-aware conversion; untagged-image warning; animated-GIF detect → convert.
- **Advanced-later**: APNG decode; per-image color-space override.
- **Out of scope**: RAW.

---

## 6. Image sequences

### 6.1 Observations
- DPX/EXR are post-production interchange. EXR HD+ is "unsuitable for most production use cases" for live playback. (https://help.disguise.one/designer/content-management/image-sequences)
- Disguise (high-end LED) supports them, but it's the exception in corporate AV.
- PNG sequences occasionally appear for animated logos / lower-thirds without alpha-codec pipeline.

### 6.2 Recommendation
- **MVP**: do not play image sequences. Detect a `name.0001.png` folder and offer "Encode as ProRes 4444 clip" via AVAssetWriter.
- **Advanced-later**: PNG sequence pseudo-clip with frame-rate metadata.
- **Out of scope**: DPX/EXR.

---

## 7. Audio model

### 7.1 Observations
- ProPresenter exposes up to 16 internal channels, with a routing-matrix UI: rows are sources, columns are destinations. Each output (main, SDI, NDI, stage) has its own per-channel matrix. (https://support.renewedvision.com/hc/en-us/articles/360052696094, https://www.renewedvision.com/blog/audio-inputs-advanced-routing-in-propresenter-7-2)
- DeckLink Quad 2 carries 16 ch embedded in HD/3G; DeckLink 8K Pro G2 carries 64 ch at 4K/8K. (https://www.blackmagicdesign.com/products/decklink, https://www.bhphotovideo.com/c/product/1186263-REG/blackmagic_design_bdlkdvqd2_decklink_quad_2_8_channel.html)
- QLab cautions against MP3 because of variable decode delay; AIFF/WAV/CAF preferred. (https://qlab.app/docs/v5/audio/audio-cues/)

### 7.2 Recommended audio data model

Three cue types share one mixer:

1. **Per-clip embedded audio** — audio tracks inside the video clip.
2. **Audio-only cue** — same in/out/loop/fade semantics as a video cue, no video.
3. **Background bed** — long-form, survives slide changes; ducks under per-clip audio.

Every cue: per-output volume (dB), mute, fade-in/out, crossfade override, routing override, pitch-corrected speed flag (`AVAudioUnitTimePitch`).

Project: 8 internal channels for MVP (16 advanced-later). Output devices: CoreAudio main, CoreAudio aggregate, DeckLink-embedded SDI (up to 16 ch HD). Simple ducking rule.

### 7.3 Sample-rate conversion
Engine standardizes on 48 kHz / 32-bit float (matches SDI embed). `AVAudioConverter` at decode. Per-clip "sample rate mismatch — resampling" indicator, non-blocking.

### 7.4 Audio file formats
- **Must-have**: WAV, AIFF, CAF (PCM); AAC inside MP4/M4A.
- **Cautioned**: MP3 — accept with timing-uncertainty warning, recommend transcode to CAF.
- **Advanced-later**: FLAC, Opus.

### 7.5 Click track
A routable cue type targeting a designated channel (typically SDI ch 7/8 for FOH). MVP: an audio cue with a routing template. Advanced-later: BPM-locked click generator.

### 7.6 Triage
- **Must-have**: per-clip audio; audio-only cues; background bed; 48 kHz/32f engine; SDI embed up to 16 ch; project-level routing matrix.
- **Advanced-later**: aggregate device support; ducking engine; click track generator; per-cue EQ/limiter.
- **Out of scope**: hardware mixer surfaces; convolution / room sim.

---

## 8. Color, range, HDR — gotchas

These bite corporate operators in real shows:

1. **Tagged vs untagged.** macOS color-manages tagged content. Untagged H.264 from a phone is interpreted as sRGB; on P3 it looks washed; on SDI treated as Rec.709 it's fine. Tag exports; show input tag in inspector. (https://www.thepostprocess.com/2020/03/16/color-shift-fixes-from-davinci-resolve-to-mac-displays/)
2. **Full vs limited range.** SDI is 16–235 (8-bit) / 64–940 (10-bit). Sending full-range RGB out a DeckLink crushes blacks and clips whites. Per-output range setting; default limited for SDI, full for HDMI/DisplayPort to LED processors. (https://blog.strangerproduction.com/2026/02/16/limited-vs-full-range-video/, https://www.portrait.com/resource-center/understanding-video-range-vs-full-range-levels/)
3. **Display P3 source on Rec.709 output.** Reds and greens compress visibly. Convert at compositor input so preview matches output.
4. **HDR (HLG vs PQ) on LED walls.** Brompton Tessera detects HDR per-input, switches between SDR/HLG/PQ at up to 12 bpc. HLG is broadcast-friendly and SDR-backwards-compatible; PQ is absolute reference (1000–4000 nit). MVP: Rec.709 SDR only. Advanced-later: HDR project flag + per-clip transfer function tagging. Mixing HDR and SDR on the same output without conversion is the #1 LED-wall gotcha. (https://www.bromptontech.com/features/hdr/, https://lightillusion.com/what_is_hdr.html)
5. **NCLC tags missing.** ColorSync depends on NCLC code points + range tag. Re-encoders (Handbrake, ffmpeg without flags) routinely strip these. Detect on import and warn.
6. **iPhone HEIC.** Display P3, "Apple Wide Gamut" tagged. Convert to ProRes still on import or render through P3-aware path.

### Triage
- **Must-have**: Rec.709 working space; limited-range default for SDI, full-range for HDMI; NCLC detection/warning; per-output range and color-space override.
- **Advanced-later**: HDR project mode (HLG/PQ); P3 working space; CMS LUT slots per output.
- **Out of scope**: Dolby Vision; HDR10+ dynamic metadata.

---

## 9. Frame-accurate seeking and trimming

### 9.1 Observations
- `AVPlayer.seek(to:toleranceBefore:.zero, toleranceAfter:.zero)` gives sample-accurate seeking but blocks on decoder; do not chain calls during scrubs. Use the completion-handler form and coalesce. (https://developer.apple.com/documentation/avfoundation/avplayer/1387741-seek, https://developer.apple.com/library/archive/qa/qa1820/_index.html)
- `AVPlayerItem.step(byCount:)` is preferred over time arithmetic — real clips have jittered frame durations. (https://developer.apple.com/forums/thread/42751)
- All-I (ProRes/DNx) seeks instantly; long-GOP H.264/HEVC requires reference-frame chase.

### 9.2 Recommendation
- Cue points (in/out/jump): `seek(to:toleranceBefore:.zero, toleranceAfter:.zero)`.
- Nudge: `step(byCount:)`.
- Interactive scrub: tolerant seek (±1 frame) snapping to nearest keyframe display, then on release perform zero-tolerance seek.
- Filmstrip thumbnails via `AVAssetImageGenerator` with zero tolerances, low-res (160×90), background queue, throttled. (https://developer.apple.com/documentation/avfoundation/avassetimagegenerator)

### 9.3 Per-clip metadata
Persisted on every clip: `inPoint`, `outPoint` (CMTime); `loop` (+ optional `loopCount`); `holdLastFrame`; `fadeIn`/`fadeOut`; `crossfadeIn`/`crossfadeOut` overrides; `varispeed` rate + `pitchCorrected` flag. Mirrors QLab/Mitti vocabulary.

---

## 10. Asset library and missing-media UX

### 10.1 Observations
- FCP libraries (`.fcpbundle`) are macOS bundles; managed media + external references. Missing media → red frame + yellow alert; relink walks adjacent dirs by name + attribute. (https://support.apple.com/guide/final-cut-pro/intro-to-libraries-ver26ccfda0/mac, https://support.apple.com/guide/final-cut-pro/relink-clips-to-media-files-ver26f5c8c9/mac)
- DaVinci Resolve: chain icon turns orange when offline; "last-known volume" dialog; Change Source Folder. (https://jayaretv.com/workflow/relink-offline-media-in-davinci-resolve/)
- Both apps' relink UX is widely criticized; the *initial* media-management model matters more than the rescue UI.

### 10.2 Recommended data model

`.splayback` stays a single file by default; offer `.splaybackproj` macOS bundle for self-contained shows.

Two media modes per clip:
- **Linked** (default): security-scoped bookmark + last-resolved absolute path + content hash (lazy SHA-256, truncated) + size + mtime.
- **Managed**: media copied into bundle's `Media/` folder.

Always store all four (bookmark, path, hash, size). Resolution order:
1. Resolve bookmark.
2. Bookmark stale → try last absolute path.
3. Path missing → search project-folder + adjacent `Media/` for hash match, then name+size match.
4. Still missing → mark offline; non-modal "N media items offline — Relink…" banner opens a relink panel with last-known path and "Locate…" button.

"Relink folder" power action: pick a folder, walk recursively, match by hash then name+size.

### 10.3 Security-scoped bookmarks at scale
- Persist as `Data` blobs in project file. (https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access)
- Balance every `startAccessingSecurityScopedResource()` with `stop…` (Swift `defer`). Leaks are the #1 sandbox bug.
- Folder-level bookmarks beat per-file for large libraries; resolve children lazily by relative path. Augment current per-file approach with a folder-bookmark option.
- Bookmarks are SHA-256-keyed by ScopedBookmarkAgent; renaming the bundle is fine; volume change invalidates → fall through to path/hash search.

### 10.4 Thumbnails and proxies
- Poster frame on import (1s offset or user-pick) → 320×180 JPEG in cache.
- 16-frame filmstrip sprite-sheet PNG, background-queue generated.
- Proxy media advanced-later: 720p ProRes Proxy; global "preview proxies" toggle.

### 10.5 Triage
- **Must-have**: linked media via bookmarks; folder bookmarks for batch imports; offline-state UI; locate / change-source-folder; poster frames; filmstrip thumbnails.
- **Advanced-later**: hash-based auto-relink; managed-media `.splaybackproj` bundle; proxy generation.
- **Out of scope**: cloud-mirrored libraries; cross-project media catalog.

---

## 11. Project file structure

### 11.1 Recommended

Keep `.splayback` as the lightweight single-file default. Offer `.splaybackproj` macOS bundle for portable shows:

```
MyShow.splaybackproj/
  Show.splayback          # JSON/plist project (same schema)
  Media/                  # copied / transcoded media
  Cache/
    Thumbnails/           # poster frames
    Filmstrips/           # 16-frame sprite-sheets
    Waveforms/            # downsampled audio peaks
    Renders/              # PDF→PNG, PPT→PNG slide caches
  Transcoded/             # ProRes-converted copies
```

### 11.2 Embedded thumbnails
Even in single-file `.splayback`, embed a 320×180 poster per clip (base64 inline or sibling cache keyed by hash). Show palette loads instantly without resolving every bookmark.

### 11.3 Versioning
- `formatVersion` integer field.
- Loader supports N-1 and N-2; upgrade in-memory; never silent rewrite-on-open. Save-as creates new version. Migration log surfaces what changed.

### 11.4 Triage
- **Must-have**: `formatVersion` + N-1 reader; embedded thumbnails; sidecar cache directory.
- **Advanced-later**: `.splaybackproj` bundle; managed-media collect-and-copy.
- **Out of scope**: SQLite-backed multi-project library.

---

## 12. Subtitles / overlay captions

### 12.1 Observations
Corporate use cases: simulcast captioning (CART), pre-prepared subtitle files for international events, sponsor lower-thirds. Three paths:
- Burned-in: works but brittle.
- External SRT/WebVTT: AVFoundation supports as `AVMediaSelection` track.
- Live caption input (CART, Streamtext): out of scope here, sits with show-control.

### 12.2 Recommendation
- **MVP**: SRT/WebVTT sidecar attached per-clip; render in compositor as subtitle layer with style template (font, size, position, drop-shadow). Per-output toggle (e.g. on stream output but not on stage screen).
- **Advanced-later**: live captions via WebSocket / Streamtext / open-captions.
- **Out of scope**: ASR / live transcription.

---

## 13. Concrete summary recommendations (lift directly into spec)

### 13.1 MVP codec policy
Simple Playback's MVP plays back **ProRes 422 / 4444** (preferred), **H.264 / HEVC in MP4 / MOV** (accepted), and stills in PNG / JPEG / TIFF / HEIF. Long-GOP files get a non-blocking warning. A right-click "Transcode to ProRes 422" writes optimized copies to a project-relative `Transcoded/` folder. HAP, NotchLC, and AV1 are post-MVP. DXV, DNx, ProRes RAW, DPX/EXR are not on the roadmap.

### 13.2 MVP import paths
- **Direct media drop**: ProRes / H.264 / HEVC / images, security-scoped-bookmarked.
- **PDF**: PDFKit-rendered to bitmap pages at output × 2.
- **PowerPoint** (`.pptx`): bundled LibreOffice headless → PDF → bitmaps. Native OOXML parse augments with notes/text for search later.
- **Keynote** (`.key`): AppleScript-driven → PDF → bitmaps. Requires Keynote installed; clear diagnostic if not.
- **Animated GIF / APNG**: detect → offer convert-to-ProRes-4444.

### 13.3 Asset model
- Linked media (bookmark + path + hash + size) default; managed media via optional `.splaybackproj` bundle.
- Folder-level bookmarks for batch imports.
- Missing-media UX: non-modal offline banner; per-clip Locate; project-level Relink folder; auto-relink by content hash.
- Embedded poster-frame thumbnails so palette loads with media offline.

### 13.4 Audio model
- 48 kHz / 32-bit float mixer, 8 internal channels (16 advanced-later).
- Per-clip audio + audio-only cues + background bed.
- Per-output, per-cue volume and mute.
- Routing matrix: cue → internal channel → device channel; one matrix per output device including DeckLink SDI embed (up to 16 ch HD).
- Pitch-corrected varispeed; project-level fade-in/out/crossfade defaults with per-clip overrides.
- WAV/AIFF/CAF/AAC supported; MP3 accepted with timing warning.

### 13.5 Color and range defaults
- Working space: Rec.709, limited range, 8-bit (MVP).
- Per-output range/color-space override (limited/full; Rec.709/sRGB/Display P3).
- NCLC-tag detection on import → warn on missing.
- HDR (HLG/PQ): advanced-later, behind project flag, for LED-wall destinations.

---

## Sources

Codecs:
- https://imimot.com/help/mitti/cues/
- https://imimot.com/blog/mitti-1-5-released/
- https://qlab.app/docs/v5/video/video-cues/
- https://qlab.app/docs/v5/audio/audio-cues/
- https://resolume.com/software/codec
- https://resolume.com/forum/viewtopic.php?t=26109
- https://help.disguise.one/designer/content-management/video-codecs/video-codec-overview
- https://notchlc.notch.one/
- https://help.millumin.com/docs/general/recommendations/
- https://hap.video/benchmarks
- https://streaminglearningcenter.com/blogs/open-and-closed-gops-all-you-need-to-know.html
- https://forum.blackmagicdesign.com/viewtopic.php?f=21&t=125161

AVFoundation / VideoToolbox:
- https://developer.apple.com/videos/play/wwdc2020/10090/
- https://developer.apple.com/documentation/videotoolbox
- https://wiki.x266.mov/docs/encoders_hw/videotoolbox
- https://developer.apple.com/documentation/avfoundation/avassetimagegenerator
- https://developer.apple.com/library/archive/qa/qa1820/_index.html
- https://developer.apple.com/documentation/avfoundation/avplayer/1387741-seek
- https://developer.apple.com/forums/thread/42751

PowerPoint / Keynote / PDF:
- https://support.renewedvision.com/hc/en-us/articles/45377042213011
- https://support.renewedvision.com/hc/en-us/articles/34512245702035
- https://freeshow.app/docs/importing
- https://github.com/ChurchApps/FreeShow/issues/491
- https://github.com/ChurchApps/FreeShow/issues/3036
- https://python-pptx.readthedocs.io/
- https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html
- https://www.systutorials.com/how-to-convert-pptx-slides-to-jpg-or-png-images-on-linux-in-command-line/
- https://iworkautomation.com/keynote/document-export.html
- https://www.macscripter.net/t/keynote-movie-export-droplet-with-prores-4444-1920-x-1080/72090
- https://developer.apple.com/documentation/pdfkit
- https://developer.apple.com/videos/play/wwdc2022/10089/

Audio / routing:
- https://support.renewedvision.com/hc/en-us/articles/360052696094
- https://support.renewedvision.com/hc/en-us/articles/360052697694
- https://www.renewedvision.com/blog/audio-inputs-advanced-routing-in-propresenter-7-2
- https://www.blackmagicdesign.com/products/decklink
- https://www.bhphotovideo.com/c/product/1186263-REG/blackmagic_design_bdlkdvqd2_decklink_quad_2_8_channel.html
- https://audiokitpro.com/waveform/

Color / range / HDR:
- https://www.thepostprocess.com/2019/09/24/how-to-deal-with-levels-full-vs-video/
- https://blog.strangerproduction.com/2026/02/16/limited-vs-full-range-video/
- https://www.portrait.com/resource-center/understanding-video-range-vs-full-range-levels/
- https://www.thepostprocess.com/2020/03/16/color-shift-fixes-from-davinci-resolve-to-mac-displays/
- https://endavid.com/index.php?entry=80
- https://developer.apple.com/forums/thread/111818
- https://images.apple.com/final-cut-pro/docs/Wide_Color_Gamut.pdf
- https://www.bromptontech.com/features/hdr/
- https://lightillusion.com/what_is_hdr.html
- https://www.haivision.com/blog/broadcast-video/what-is-hdr-how-you-can-contribute-live-broadcast-content-in-hdr/

Asset management / sandbox / relink:
- https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access
- https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html
- https://www.delasign.com/blog/how-to-persist-file-access-on-macos-using-swift-and-scoped-url-bookmarks/
- https://www.mothersruin.com/software/Archaeology/reverse/bookmarks.html
- https://support.apple.com/guide/final-cut-pro/intro-to-libraries-ver26ccfda0/mac
- https://support.apple.com/guide/final-cut-pro/relink-clips-to-media-files-ver26f5c8c9/mac
- https://www.apple.com/final-cut-pro/docs/Media_Management.pdf
- https://jayaretv.com/workflow/relink-offline-media-in-davinci-resolve/

Image / sequence / LED:
- https://help.disguise.one/designer/content-management/image-sequences
- https://www.1-converter.com/blog/gif-vs-mp4
- https://resolume.com/forum/viewtopic.php?t=13937
