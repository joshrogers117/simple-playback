# Output and Render Pipeline — Research Report

Scope: how Simple Playback should model outputs, route frames to physical destinations, handle color/sync/genlock, integrate DeckLink and IP transports, and present preview to the operator. Adjacent topics (show control, media import, operator UX) are covered in sibling reports.

Audience: professional corporate AV / broadcast playout. Worship workflows are intentionally excluded.

---

## 1. Reference apps, by output-pipeline shape

Three different design philosophies dominate:

### 1a. ProPresenter — typed-screen compositor
ProPresenter models a fixed 8-layer compositor (Audio, Messages, Props, Announcements, Slide, Media, Background, Live Video) that renders into named **Screens**, where a Screen is an abstraction *above* a physical monitor or capture device. Screens are typed as **Audience** or **Stage**, and either type can be backed by a system display, a virtual NDI output, an SDI output via DeckLink/UltraStudio, a Syphon output, or a placeholder. A second abstraction, **Looks**, snapshots which layers are visible on which screens, and Looks can be switched live or triggered from a slide action or macro. ProPresenter also distinguishes "graphics outputs" (the OS's HDMI/DisplayPort displays) from "video outputs" (DeckLink/UltraStudio devices that do not appear as OS displays); this distinction has real implications for alpha and color, covered below. Sources: https://support.renewedvision.com/hc/en-us/articles/13634000690323-ProPresenter-Output-Layers, https://support.renewedvision.com/hc/en-us/articles/360041879173-Screen-Configuration-in-ProPresenter, https://support.renewedvision.com/hc/en-us/articles/360041407174-Using-Looks-to-Show-Different-Screen-Content-in-ProPresenter, https://support.renewedvision.com/hc/en-us/articles/360053271833-Graphics-vs-Video-Outputs.

### 1b. PlaybackPro Plus — deliberately flat, GPU-driven
DT Videolabs' PlaybackPro Plus X is the corporate-event playback **standard** and takes the opposite approach: program/preview clip players on a single large GPU output, no compositor, no layers. Crucially, DT Videolabs explicitly does **not** support DeckLink / UltraStudio / Kona / T-Tap, calling them "video output devices and therefore very limited because they have no GPU and require that video be formatted for the device." Their recommended path is Mac HDMI/DisplayPort → broadcast converter → switcher. Program (red) is on air; Preview (blue) holds the next clip and pre-rolls so a take is instantaneous. A clip's in/out points, geometry, and levels travel with it through the take. Sources: https://www.dtvideolabs.com/playbackpro-plus-3/, https://www.dtvideolabs.com/faq/, https://onestopav.com/wp-content/uploads/2023/08/PlaybackProPlusUserGuide-x.pdf.

### 1c. Mitti — cue list with first-class DeckLink and per-output warp
Mitti supports fullscreen output to multiple OS displays, Blackmagic DeckLink/UltraStudio, NDI, and Syphon, and treats all of these as "screens" with the same operations: span across them, 4-corner warp per output, edge blend, color matte, timecode overlay, subtitle/caption overlay, and audio-via-SDI/NDI options. When the DeckLink hardware supports keying, Mitti exposes Key & Fill as an output mode. This is the closest single reference for Simple Playback's likely shape: a cue list, but with output topology that is unified across transport types. Sources: https://imimot.com/help/mitti/outputs/, https://imimot.com/mitti/.

### 1d. QLab — stages → regions → routes
QLab 5 separates the *render target* (Stage — a virtual raster) from the *physical destination* (Route — a screen, NDI, Syphon). Between them sit **Regions**, sub-rectangles of the stage that get warped and assigned to a route. Multiple regions can point at the same route; a single stage can be shredded across many routes. This is the cleanest published abstraction for "one composition, many destinations, each warped." Source: https://qlab.app/docs/v5/video/video-output/.

### 1e. Resolume Arena — Advanced Output canvas
Resolume Arena's **Advanced Output** is a separate window where the composition is sliced and each slice is mapped to an output device with its own transform, perspective warp, and edge-blend feathering. Multiple Advanced Output presets can be saved and switched per venue. Sources: https://www.resolume.com/support/en/advanced-output, https://resolume.com/support/en/edge-blending, https://resolume.com/support/en/output-transformation.

### 1f. Disguise / Watchout — corporate-tier multi-machine
Disguise models a 3D stage and uses **Feed mapping** to slice rectangles out of a "mapping canvas" and route them pixel-accurately to physical outputs, often distributed across multiple "actor" machines synced via d3net plus an external genlock. **Parallel mapping** treats the cluster as one unified canvas. Watchout uses a similar production-master / display-cluster model with frame-accurate sync over the network, optionally hardened by genlock. Sources: https://help.disguise.one/designer/mapping/mapping-types/feed-mapping, https://help.disguise.one/designer/mapping/mapping-types/parallel-mapping, https://www.dataton.com/watchout.

### 1g. ProVideoPlayer (PVP) — multi-screen mid-tier
PVP supports HDMI, SDI, NDI, Syphon "and more" as destinations and lets the operator design output canvases as rectangles, polygons, circles, or beziers, then slice/tile a video across them. It sits between Mitti and Resolume in feature density. Source: https://renewedvision.com/provideoplayer.

### 1h. vMix — IP-first broadcast routing
vMix exposes up to 4 independent NDI outputs configurable as Preview, Output, Input, or MultiView; SRT in/out for low-latency contribution; and is the canonical reference for IP-output flexibility on a playout-adjacent product. It does not natively support ST 2110 in the published outputs config. Source: https://www.vmix.com/help28/SettingsOutputs.html.

---

## 2. Output topology — modeling "screens" above raw monitors

The recurring pattern across ProPresenter, Mitti, QLab, PVP, and Resolume: there is an **abstraction between content and physical port**, and it is *typed*. The corporate operator's vocabulary for these types is:

- **Audience / Program** — what the room sees. Typically the LED wall or main projection blend. One-and-only "on air" surface.
- **Confidence / Stage / Foldback / DSM** — what speakers and crew on stage see. Often shows program full-bleed, but increasingly also countdown timers, presenter notes, "next slide" preview, IMAG.
- **IMAG / Side-screen** — image-magnification feed to room screens flanking the stage; usually fed *from* the switcher, not the playback machine, but operators occasionally want a dedicated mirror.
- **Delegate / Translation / Backstage monitor** — break-room, green-room, lobby, multi-language overlay variants.
- **Multiviewer / Director** — operator-side composite showing program + preview + countdowns + tally; not a destination an audience ever sees.

Above these primary types, three sub-topology constructs recur:

- **Grouped / Spanned** — one logical screen drives multiple physical outputs treated as a single raster (LED wall fed by N receivers, projector blend, video processor with multiple inputs). QLab regions, Disguise parallel mapping, Resolume slice transform, and ProPresenter's Edge Blend all instantiate this.
- **Mirror** — same content to multiple physical outputs, no per-output transform. Cheap and common; do not let operators accidentally mirror by treating displays as a flat list.
- **Edge Blend** — soft-edge overlap between two adjacent slices of a spanned screen, with width, gamma, and power curves. ProPresenter, Resolume, Mitti, and QLab all expose width-of-overlap + per-edge gamma/power as the parameter set.

### Recommendation for Simple Playback
Model **Screen** as a typed, named, persistable object distinct from both (a) the compositor input layers and (b) the physical transport. A Screen has:

- a **role** (Program, Confidence, Multiviewer, Mirror, Auxiliary)
- a **canvas** (resolution, frame rate, color space, range)
- a **transport binding** (one or more: OS display, DeckLink device + connector, NDI sender name, Syphon publish, file-record sink)
- an optional **geometry** (corner pin, edge blend region) per binding
- an optional **mirror group** (this Screen mirrors another)

Project files (`.splayback`) should serialize Screens as named entities so a show file moves between venues without re-binding by display index. Show file holds *intent* (Program @ 1920x1080@59.94, SDI fill+key, Rec.709 limited); the per-machine local config maps that intent to actual hardware (DeckLink Duo 2, port 1+2). Same shape as ProPresenter's "Screen + binding" split and QLab's Stage-vs-Route split.

---

## 3. DeckLink / UltraStudio integration patterns

Simple Playback already uses DeckLink. Concrete things the strong references do, and gotchas:

### 3a. Device → connector mapping is non-obvious
Multi-port DeckLinks (Duo 2, Quad 2, 8K Pro) require explicit input-vs-output assignment in Blackmagic Desktop Video Setup *and* in the host app. ProPresenter's docs call this out: on an 8K Pro, set "SDI 1 & 2 In, SDI 3 & 4 Output" for fill+key. On a Duo 2, pair SDI 1 + SDI 2 for fill/key. Source: https://support.renewedvision.com/hc/en-us/articles/360041408314-Setting-up-an-Alpha-Key-output-from-ProPresenter. Simple Playback should surface device sub-port assignments in its output config, not assume "device" == single port.

### 3b. Fill + Key (alpha output) is two physical SDI cables
The fill is the RGB content; the key is a black-and-white matte where white = opaque, black = transparent. A downstream switcher (ATEM, Kahuna, Carbonite) keys fill over its program using key as alpha. Hardware-supported keying lights up automatically on Duo 2, Quad 2, 4K Extreme/12G, 8K Pro, UltraStudio 4K family — i.e., dual-link or multi-channel devices. Source: https://support.renewedvision.com/hc/en-us/articles/360011598133-ProPresenter-Supported-Blackmagic-devices. For Simple Playback this is high-leverage: a corporate operator running lower-thirds, bugs, or speaker name supers wants fill+key into a switcher more than they want a composited program-out.

### 3c. Genlock / reference is required for any LED wall or switcher chain
DeckLink devices accept tri-level sync on the REF input and lock the output clock to it. Without genlock, a frame drift accumulates between the DeckLink and the LED processor / switcher; tearing or rolling black bars appear on camera. Brompton Tessera and Megapixel HELIOS both expose "lock to active video input" as the default, so if Simple Playback's SDI output is genlocked to house reference, the wall is implicitly in lock with the rest of the show. Sources: https://www.bromptontech.com/features/genlock/, https://support.megapixelvr.com/support/solutions/articles/103000325884-sync-mismatch. Simple Playback should: (1) detect when REF is connected and surface lock state to the operator, (2) refuse to silently fall back to free-run when REF is expected, (3) display REF-vs-output format mismatch as a hard warning (REF 59.94i with output 50p will fail to lock).

### 3d. Format negotiation — frame rate is sacred
Corporate jobs commonly mix 23.976, 24, 25, 29.97, 30, 50, 59.94, 60. Conform vs convert is the difference between flawless playback and constant micro-stutter. The DeckLink driver does **not** do frame-rate conversion; it only outputs the requested mode. If clip is 23.976 and Screen is 59.94, the host application is responsible (and most playback tools either 3:2 pulldown or speed-conform with a warning). Source: https://forum.videohelp.com/threads/247550-23-976-frames-second-29-97-frames-second-stuttering-playback. Simple Playback should: pick the Screen frame rate at config time, refuse to silently re-time a clip to a non-matching Screen, and surface mismatched clips with a clear "this clip will be conformed at speed X / pulled-down via 3:2 / decimated" indicator before the operator hits take.

### 3e. 10-bit and 12G-SDI
DeckLink supports 8/10/12-bit RGB 4:4:4 up to UHD30 and 8/10-bit YUV 4:2:2 above that on 12G-class cards. Source: https://www.blackmagicdesign.com/products/decklink/techspecs. For corporate playout, 10-bit YUV 4:2:2 at 1080p59.94 / UHDp59.94 covers 95% of jobs. Offer 10-bit as the default once any clip is >8-bit; 8-bit-only is a footgun on banded gradients, lower-third gradients, and HDR-graded content downconverted to SDR.

### 3f. "Output in use" — the device is a singleton
DeckLink outputs are exclusive: only one process can hold a given sub-channel at a time. Symptoms include silent failure to start output, "output in use," or zombie locks after a crash. Simple Playback should: detect the lock condition on take, surface which app/process holds it (best-effort via lsof), offer a "force release on next launch" path, and never silently degrade to software-only output without telling the operator.

### 3g. Graphics-output vs video-output is a real distinction
Per ProPresenter's docs, graphics outputs (HDMI/DisplayPort on the Mac itself) go through macOS color management (ICC profile, P3 default on modern Macs) and are subject to compositor effects. Video outputs (DeckLink) bypass all of that and go straight to SDI. The same RGB pixel will *look different* on a Mac HDMI output vs a DeckLink HDMI output. Source: https://support.renewedvision.com/hc/en-us/articles/360053271833-Graphics-vs-Video-Outputs. Simple Playback should label this distinction in the UI and document the implication: trust the SDI output for color decisions, not the Mac preview.

---

## 4. NDI, SRT, ST 2110 — IP outputs

### 4a. NDI Full vs NDI HX
- **Full NDI** (SpeedHQ, MPEG-2-derived): ~125–150 Mbps for 1080p59.94, latency in single-digit-frames range, near-visually-lossless. Designed for a dedicated 1 GbE/10 GbE production LAN.
- **NDI HX / HX2 / HX3** (H.264/HEVC): 8–20 Mbps typical, 80–200 ms latency, runs over Wi-Fi. Designed for resource-constrained or wireless paths.

Sources: https://birddog.tv/fullndi-vs-ndihx3/, https://www.magewell.com/blog/30/detail, https://avonic.com/whats-the-difference-between-ndi-and-ndihx/.

For corporate playout *output*: Full NDI is the right default whenever the destination LAN can carry it (multi-viewers, ATEM as NDI-in, Tricaster, OBS contribution, redundant feeds to a backup machine). HX is a contribution / monitoring choice, not a primary program path.

### 4b. SRT
SRT is a contribution / distribution transport over the open internet, not a LAN production format. Useful as an output for streaming the program out of the venue (encoder-replacement) and rarely as the main playout route. Defer to "later" unless a paying customer asks.

### 4c. ST 2110
ST 2110 is *the* broadcast-tier IP standard (separate essence flows for video, audio, ancillary, on a 10/25/100 GbE PTP-disciplined fabric). 2024 SMPTE data: ~60% of major broadcast facilities, 37% of broader pros use it. Source: https://www.haivision.com/blog/all/smpte-st-2110-haivision-live-production-workflows/. Disguise has explicit corporate-event positioning around it. Source: https://www.disguise.one/en/insights/blog/six-reasons-use-st-2110-your-next-live-event-broadcast-or-immersive-experience.

For Simple Playback: **out of scope** for the foreseeable future. ST 2110 implies PTP timing, NMOS IS-04/IS-05 discovery, dedicated NIC, and broadcast-grade QA — none of which is "simple." The right answer for a Simple Playback customer who needs ST 2110 is to put a Bridge box (Macnica, AJA, Matrox) between Simple Playback's SDI output and the 2110 fabric.

---

## 5. Edge blending, warp, and projection mapping

The shared parameter set across ProPresenter, Mitti, QLab, Resolume:

- **Overlap width** in pixels per edge (top/bottom/left/right)
- **Gamma** per channel (R/G/B) — corrects for projector nonlinearity in the blend region
- **Power / curve** — controls how aggressively the blend ramps from 0 to 1 across the overlap

Plus geometry:

- **4-corner / perspective warp** — fixes off-axis projection keystoning
- **Per-region warp** (QLab) — for non-flat surfaces or multi-surface from one projector
- **Mesh warp** — for curved screens; Resolume Arena has it, Mitti does not, ProPresenter has limited support

Sources: https://support.renewedvision.com/hc/en-us/articles/360041820053-Edge-Blending-in-ProPresenter, https://resolume.com/support/en/edge-blending, https://qlab.app/cookbook/mapping-complexity/.

### Recommendation
For LED-wall jobs (which dominate corporate today), **edge blending and warp are not needed** — the LED processor handles seams and the wall is geometrically flat. For projection blends, soft-edge with width + gamma + power per edge covers the common case. Mesh warp and per-region warp are clearly "advanced/later." Simple Playback should ship soft-edge blend + 4-corner warp for projection jobs and not chase Resolume's mapping engine.

---

## 6. Layer compositor primitives

ProPresenter's 8 layers are a corporate maximum, not a corporate minimum. Most playout tools use 2–4 layers:

- **Background** (color or media loop, runs continuously)
- **Media / Program** (the cued clip or still)
- **Overlay / Logo / Bug** (persistent corner graphic)
- **Text overlay / Lower-third / Message** (timer, name super, bulletin)

PlaybackPro Plus has *no* compositor — that is the point. Mitti has clip-with-color-matte, edge blend, timecode overlay, subtitle overlay — i.e., per-clip overlays, not a full layer stack.

### Recommendation
Simple Playback should resist becoming ProPresenter. Concretely:

- **Ship**: a single program "media" layer with crossfade (already done) plus a persistent **logo/bug** layer that survives takes and a **timer/message** layer for countdowns and name-supers. Three layers, not eight.
- **Defer**: a stage-display-style multi-layout compositor, props library, multi-cue-stack timelines.
- **Skip**: live-video input layer, mask layer. These pull the app into "switcher-lite" territory and explode the test matrix. If the customer needs a switcher, they have an ATEM downstream.

The ProPresenter "Looks" idea is **valuable** — a saved, named state of "which layers go to which screens" — *if* and only if the project has more than one screen role. For corporate playout where 90% of jobs are one Program out, a Looks system is dead weight. Defer until a Confidence/Stage screen ships.

---

## 7. Output profiles / "Looks" / Scenes

Every reference app at scale ships some form of saved-and-recallable output state:

- ProPresenter: **Looks** — per-screen layer visibility, switchable from a slide action, macro, or menu.
- Resolume: **Advanced Output presets** — per-venue slice/transform sets, switched from a dropdown.
- Disguise: **mapping configurations** — switched per show.

The unifying concept: the **output topology + per-output transform set** is a named, switchable thing, separate from the cue list.

### Recommendation
When Simple Playback ships its second screen role, ship **Output Profile** as a named object — a snapshot of (Screens, transport bindings, geometry, edge blend). Operator can switch profiles at venue load and recall venue-A vs venue-B without editing the show. Bind a profile to a project for default, but let it be loaded from a separate file. This is the single highest-leverage abstraction borrowed from the references.

---

## 8. Color pipeline

The hard truth: Mac graphics-output color and SDI-output color are different worlds, and a "WYSIWYG" Mac preview is impossible without an SDI-fed reference monitor. Source: https://jonnyelwyn.co.uk/film-and-video-editing/colour-management-for-video-editors/.

### What corporate playout actually needs
- **Rec.709, limited range (16–235), BT.1886 EOTF** — the canonical broadcast SDR target. 95% of jobs.
- **Rec.709, full range (0–255)** — when feeding a computer-input switcher port that expects PC-range. The wrong choice here causes either crushed blacks or milky highlights.
- **DCI-P3 D65, full range** — only when explicitly delivering for a digital-cinema room or wide-gamut display chain. Rare in corporate.
- **HDR (Rec.2020 / PQ or HLG)** — out of scope for v1; LED walls that accept HDR are still uncommon in corporate; broadcast switchers passing HDR are a 2026+ minority.

Source: https://studio-supplies.com/blogs/guides/color-spaces-explained-rec709-dci-p3-rec2020.

### What to do in the pipeline
- **Decode**: respect the clip's tagged color space + range. Tagging is unreliable on customer media, so allow the operator to override per clip.
- **Composite**: linear-light internally (or at minimum, gamma-aware blending so crossfades don't darken).
- **Output**: convert to the Screen's declared color space + range. The Screen is the source of truth, not the clip.
- **Preview**: render the Mac preview through the Mac's ICC profile so it *approximates* what an operator would see if their Mac display were a Rec.709 monitor. Tell the operator clearly that the preview is approximate — never "WYSIWYG."

The operator UX rule: SDI output is the ground truth, Mac preview is the proxy. Documentation, not engineering, is where this rule is enforced.

### Anti-pattern
Doing "smart" automatic color-space conversion based on clip tags without operator visibility. A mistagged clip silently routed through a wrong conversion will look wrong at showtime, and the operator will not know why. Always show the chain (Clip P3 full → Composite linear → Output Rec.709 limited) in the UI.

---

## 9. Frame-accurate sync and genlock — what corporate operators expect

Whenever a Simple Playback machine feeds an LED processor (Brompton Tessera, Megapixel HELIOS, ROE, INFiLED) or a broadcast switcher, two timing chains must agree:

1. **Output frame rate** = LED processor's expected input rate. The processor will display the input but *will not* drop or double frames if it is itself genlocked to that input — Tessera "genlocked from the video input all the way down to the LED refresh cycle." Source: https://www.bromptontech.com/features/genlock/.
2. **Output frame phase** = REF generator's frame phase. If house REF is present and the DeckLink output is genlocked to it, the playback machine's frame n leaves the SDI port at a deterministic time relative to camera shutter and LED scan. This is what enables clean ICVFX and avoids "Sync Mismatch" warnings. Source: https://support.megapixelvr.com/support/solutions/articles/103000325884-sync-mismatch.

Operator expectation: when REF is plugged in, the green-light-good icon shows up in the playback app *before* the show starts. When REF is missing or wrong format, the warning is loud.

### Recommendation
- Surface DeckLink REF lock state in the output panel (Locked / Free-run / REF mismatch).
- Refuse to start a show with REF mismatch unless explicitly overridden.
- Default to "match REF format" if a single REF is present and an output format has not been chosen.

---

## 10. Multi-output and multi-machine redundancy

### 10a. Multi-output on one machine
Already implicitly supported by the Screen abstraction in §2. Two SDI outs on a Duo 2 = two screens with independent canvases. Mac HDMI + DeckLink = mixed topology in one project.

### 10b. Multi-machine redundancy — the corporate pattern
The pro standard, borrowed from audio playback rigs: two identical machines running identical shows, both fed the same timecode (LTC or MTC) or the same trigger bus, both producing identical SDI outputs into a hardware change-over device (Glensound, Sonifex) that auto-switches on signal loss. Source: https://www.iconnectivity.com/blog/creating-a-redundant-playback-rig-with-playaudio1u. Watchout's display-cluster model is the same idea on a larger scale, with frame-accurate network sync. Source: https://www.dataton.com/watchout.

### Recommendation
For Simple Playback v1, redundancy is **out of scope at the network layer** — but the *show file* must be redundancy-friendly:
- Show file is a single document, not a per-machine config blob; a second machine can open the same `.splayback` and produce the same outputs.
- Triggers (timecode, OSC, MIDI) drive the cue list deterministically — no GUI-only-actionable cues.
- Output topology is venue-bindable — see §2 — so the backup machine's display indices can differ from the primary.

This unlocks the standard "two machines + change-over" pattern without Simple Playback shipping any networking code.

---

## 11. Software preview, program/preview semantics, and multiviewers

### 11a. Program-only vs Program/Preview
- **Program-only** (PlaybackPro single-window mode, Mitti default): one playhead, one output. Take-on-click, no pre-roll.
- **Program/Preview** (PlaybackPro Plus, broadcast switchers): two playheads. Selected clip is loaded into Preview, pre-rolls in the background, and a take cuts/crossfades it to Program. This is the corporate-event default and is what operators expect.

PlaybackPro's color convention: Program red, Preview blue. Worth borrowing — color-coding the preview state prevents the single most common live mistake (operator triggers a clip thinking it's preview when it's already program).

### 11b. Multiviewer / operator-only composite
ProPresenter ships an operator-side multiviewer (program + all stage screens + preview thumbnails) as a designable screen. Source: https://support.renewedvision.com/hc/en-us/articles/360051396653-Create-a-Multiviewer-Output-in-ProPresenter. For Simple Playback this maps cleanly onto the existing software preview — extend it, don't replace it.

### 11c. Hardware preview displays
Operators commonly want a separate Mac monitor *or* a dedicated SDI feed to a confidence rack with the operator-side multiviewer on it. Treat this as just another Screen (role = Multiviewer) with its own transport binding.

### Recommendation
- Ship Program/Preview as the default mode; a "single output" mode is a preference, not the default.
- The software preview on the operator's Mac is a Multiviewer-role Screen with content = (Program thumbnail, Preview thumbnail, cue list, time-remaining). It is *not* a separate code path — it is the same compositor rendering to a window instead of a transport.
- Generate scrub/thumbnail strips on media import so cue-list previews are instant. The cost is one offline pass at import; the benefit is the operator never waits for a thumbnail at showtime.

---

## 12. ProPresenter-style "audience screen" assignment

The pattern: when the user adds an output, they pick a *type* (Audience / Stage), then pick a *binding* (Display 2 / DeckLink Duo 2 SDI 1+2 / NDI sender "PROGRAM"). The output then appears in the cue UI by *role*, not by binding ("send to Audience," not "send to Display 2"). This is what makes show files portable.

### Recommendation
Adopt this naming convention literally. Simple Playback's output config is two columns:

| Screen (role-named) | Binding (machine-local) |
|---------------------|-------------------------|
| Program             | DeckLink Duo 2, SDI 1+2 (Fill+Key), 1080p59.94, Rec.709 limited, REF locked |
| Confidence          | HDMI-1, 1920×1080@60, Rec.709 full |
| Multiviewer         | Window on operator Mac, 1280×720 |
| Stream-Out          | NDI sender "SP-Program"   |

The cue list references **Program** and **Confidence** by name. The same `.splayback` opens on a different machine and the operator only re-edits the right column.

---

## 13. Anti-patterns and complexity traps

Patterns that pull a tool away from "simple" and that Simple Playback should explicitly *not* adopt:

- **Eight-layer compositor with mask, props, announcements, messages, slide, media, background, live-video.** Justifiable for ProPresenter's church-tech audience, overkill for corporate playout. Stops at three layers.
- **Built-in switcher / live-camera input.** Massive scope expansion (capture, deinterlace, frame-sync, sync-to-program). The downstream switcher does this.
- **Per-layer color grading / FX rack / shader chains.** Resolume territory. The clip should already be graded; per-clip simple level/gamma is the cap.
- **Mesh warp / projection mapping engine.** Beyond corner pin and soft-edge, the operator should be using Resolume Arena, MapMap, or HeavyM.
- **NMOS / ST 2110 native.** Defer to bridge hardware.
- **Per-machine output configuration baked into the show file.** Always separate venue-binding from show content.
- **Silent format / color / range conversions.** Every conversion should be visible in the chain UI and overridable.
- **"Auto-detect best output" magic.** Operators distrust magic. Make the choice, surface the choice, explain the choice.
- **Mirror by checkbox on each display.** Mirror is a Screen relationship, not a per-display flag — otherwise operators end up with three displays mirrored "by accident" because the checkbox state surfaced through a project save.

---

## 14. DeckLink-specific gotchas (consolidated checklist)

For Simple Playback's DeckLink output code path:

- **Sub-channel allocation** — Duo 2/Quad 2/8K Pro have configurable in/out per port; mirror Desktop Video Setup state, do not assume.
- **Fill+Key requires paired ports** — must reserve two channels, output identically clocked. Document which models support it.
- **REF input handling** — surface lock state, refuse silent free-run when REF expected, warn on REF format mismatch.
- **Output format negotiation** — set the mode at start, do not allow mid-show format change without re-arming. Format change is a "stop and restart output" operation.
- **10-bit pixel format default** — auto-bump to 10-bit YUV 4:2:2 if any clip in the show is >8-bit. Allow override.
- **Range** — explicit limited (16–235) vs full (0–255) flag per Screen, default limited for SDI, default full for graphics-output HDMI to a computer-input switcher port.
- **"Output in use" recovery** — detect on take, surface holding process, offer release-on-relaunch path.
- **Audio embedding** — embed audio over SDI matches Mitti's "NDI & SDI" audio-output option and is operator-expected. Default on, with channel-pair routing.
- **HDMI on DeckLink** — HDMI ports on DeckLink cards are *not* OS displays, they are video outputs. Do not present them as "Display N" alongside Mac HDMI; they live in the DeckLink section of the binding UI.
- **Disconnect / hot-unplug** — UltraStudio devices are Thunderbolt; surprise unplug must not crash, must not silently move output to graphics, must surface a clear "transport lost" state.
- **macOS Desktop Video version drift** — pin a known-tested driver version in release notes; corporate IT will lock drivers and operators ask "which version is supported."

Sources: https://www.blackmagicdesign.com/products/decklink/techspecs, https://support.renewedvision.com/hc/en-us/articles/360011598133-ProPresenter-Supported-Blackmagic-devices, https://support.renewedvision.com/hc/en-us/articles/360041408314-Setting-up-an-Alpha-Key-output-from-ProPresenter, https://casparcgforum.org/t/decklink-8k-pro-reference-genlock-problems/5443.

---

## 15. Tiered recommendations for Simple Playback

### Must-have (v1 / very-near-term) — the "professional corporate playout" floor
- **Typed Screen abstraction** (role + canvas + transport binding), serialized in `.splayback`.
- **Program / Preview model** with red/blue color convention, pre-roll on Preview load, configurable take transition (cut / crossfade).
- **DeckLink output** with: explicit format selection, 10-bit YUV 4:2:2, REF lock surfacing, fill+key on supported devices, audio embed.
- **Color pipeline** with explicit per-Screen Rec.709 limited vs full range, gamma-aware crossfade, clip-tag-respecting decode with operator override, visible color chain.
- **Software preview / multiviewer** as a Multiviewer-role Screen sharing the compositor.
- **Frame-rate conformance warnings** at clip-into-show time and pre-show.
- **Venue-portable show files** — Screen-by-name, binding-by-machine.
- **NDI Full output** from any Screen as a transport binding.
- **Logo/bug overlay layer** that survives takes.

### Advanced / later — when a customer pulls
- **Output Profile / Looks** — saved venue topology snapshots.
- **Confidence / Stage screen role** with independent content (program clean vs program with timer/notes).
- **Edge blend + 4-corner warp** for projection blends.
- **Fill+Key via dedicated paired output** as a UI-first-class option, not a hidden mode.
- **Timer / countdown / message overlay layer**.
- **Multiviewer as SDI/NDI output** (not just operator-Mac window).
- **HDR pipeline** (Rec.2020 / PQ) — only when LED-wall vendor support is mainstream.

### Out of scope to keep simple
- **Eight-layer ProPresenter-style compositor.**
- **Live camera / switcher inputs.**
- **Mesh warp, projection mapping engine, 3D stage model.**
- **ST 2110 native** (use bridge boxes).
- **Network-clustered display engine** (Watchout/Disguise multi-machine).
- **Built-in streaming encoder / SRT egress** (use OBS or hardware encoder downstream).
- **Audio routing matrix beyond per-clip channel pair selection.**

---

## 16. Architectural shape for Simple Playback's output pipeline

Pulling the recommendations together into one model:

```
Cue List
   │
   ▼
Compositor (≤3 layers: bug, media, message)
   │  renders to N named Stages
   ▼
Stages (1..N)              ← QLab-style virtual rasters, not displays
   │  each has color space, range, frame rate, resolution
   ▼
Screens (1..N)             ← ProPresenter-style typed roles
   │  binds to one or more transports, each with optional warp/blend
   ▼
Transports                 ← DeckLink, OS Display, NDI, Syphon, Multiviewer-window
   │  per-transport: format, REF lock, fill+key, range, audio embed
   ▼
Physical wires
```

Three insights from the references that shape this:

1. **Stage ≠ Screen** (QLab). The composition surface and the destination are different objects. This lets one cue go to multiple destinations with different transforms without duplicating cues.
2. **Screen has a role, not a port** (ProPresenter). Cue references "Program," not "Display 2." Show files survive venue moves.
3. **Transport is just-a-binding** (Mitti). DeckLink, NDI, OS-display all sit in the same slot. Operators do not learn three different output paradigms.

Below the Screen layer, the transport implementation handles all the messy hardware-specific work — DeckLink format negotiation, NDI sender lifecycle, OS display fullscreen — without leaking that mess into the cue model.

---

## Source list (consolidated)

- ProPresenter Output Layers — https://support.renewedvision.com/hc/en-us/articles/13634000690323-ProPresenter-Output-Layers
- ProPresenter Screen Configuration — https://support.renewedvision.com/hc/en-us/articles/360041879173-Screen-Configuration-in-ProPresenter
- ProPresenter Looks — https://support.renewedvision.com/hc/en-us/articles/360041407174-Using-Looks-to-Show-Different-Screen-Content-in-ProPresenter
- ProPresenter Edge Blending — https://support.renewedvision.com/hc/en-us/articles/360041820053-Edge-Blending-in-ProPresenter
- ProPresenter Graphics vs Video Outputs — https://support.renewedvision.com/hc/en-us/articles/360053271833-Graphics-vs-Video-Outputs
- ProPresenter Alpha Key Setup — https://support.renewedvision.com/hc/en-us/articles/360041408314-Setting-up-an-Alpha-Key-output-from-ProPresenter
- ProPresenter Supported Blackmagic Devices — https://support.renewedvision.com/hc/en-us/articles/360011598133-ProPresenter-Supported-Blackmagic-devices
- ProPresenter Multiviewer — https://support.renewedvision.com/hc/en-us/articles/360051396653-Create-a-Multiviewer-Output-in-ProPresenter
- ProVideoPlayer (PVP) — https://renewedvision.com/provideoplayer
- DT Videolabs PlaybackPro Plus — https://www.dtvideolabs.com/playbackpro-plus-3/
- DT Videolabs FAQ — https://www.dtvideolabs.com/faq/
- PlaybackPro Plus X User Guide — https://onestopav.com/wp-content/uploads/2023/08/PlaybackProPlusUserGuide-x.pdf
- Mitti — https://imimot.com/mitti/
- Mitti Outputs — https://imimot.com/help/mitti/outputs/
- QLab 5 Video Output — https://qlab.app/docs/v5/video/video-output/
- QLab Mapping Cookbook — https://qlab.app/cookbook/mapping-complexity/
- Resolume Advanced Output — https://www.resolume.com/support/en/advanced-output
- Resolume Edge Blending — https://resolume.com/support/en/edge-blending
- Resolume Output Transformation — https://resolume.com/support/en/output-transformation
- Disguise Feed Mapping — https://help.disguise.one/designer/mapping/mapping-types/feed-mapping
- Disguise Parallel Mapping — https://help.disguise.one/designer/mapping/mapping-types/parallel-mapping
- Disguise on ST 2110 — https://www.disguise.one/en/insights/blog/six-reasons-use-st-2110-your-next-live-event-broadcast-or-immersive-experience
- Dataton Watchout — https://www.dataton.com/watchout
- vMix Outputs / NDI / SRT — https://www.vmix.com/help28/SettingsOutputs.html
- Brompton Tessera Genlock — https://www.bromptontech.com/features/genlock/
- Megapixel HELIOS Sync Mismatch — https://support.megapixelvr.com/support/solutions/articles/103000325884-sync-mismatch
- Blackmagic DeckLink Tech Specs — https://www.blackmagicdesign.com/products/decklink/techspecs
- BirdDog Full NDI vs HX3 — https://birddog.tv/fullndi-vs-ndihx3/
- Magewell NDI Bandwidth — https://www.magewell.com/blog/30/detail
- Avonic NDI vs HX — https://avonic.com/whats-the-difference-between-ndi-and-ndihx/
- Haivision SMPTE 2110 — https://www.haivision.com/blog/all/smpte-st-2110-haivision-live-production-workflows/
- Studio Supplies Color Spaces — https://studio-supplies.com/blogs/guides/color-spaces-explained-rec709-dci-p3-rec2020
- Color Management for Video Editors — https://jonnyelwyn.co.uk/film-and-video-editing/colour-management-for-video-editors/
- Frame-rate conformance forum — https://forum.videohelp.com/threads/247550-23-976-frames-second-29-97-frames-second-stuttering-playback
- iConnectivity redundant playback rigs — https://www.iconnectivity.com/blog/creating-a-redundant-playback-rig-with-playaudio1u
- DeckLink 8K Pro Genlock thread — https://casparcgforum.org/t/decklink-8k-pro-reference-genlock-problems/5443
