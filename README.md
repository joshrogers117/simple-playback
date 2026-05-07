# Simple Playback

Simple Playback is a macOS media playback app for still images and videos with DeckLink output, software preview, palette-based media takes, video scrubbing, audio playback, and configurable crossfades.

## Requirements

- macOS with Xcode installed
- Blackmagic Desktop Video runtime
- Blackmagic DeckLink SDK 16.0 copied into the repository root as:

```text
Blackmagic DeckLink SDK 16.0/
```

The SDK folder is intentionally not tracked in git. The project includes DeckLink headers from that local path.

## Build

```sh
xcodebuild -project "Simple Playback.xcodeproj" -scheme "Simple Playback" -destination 'platform=macOS' build
```

## Test

```sh
xcodebuild -project "Simple Playback.xcodeproj" -scheme "Simple Playback" -destination 'platform=macOS' test
```

## Notes

Projects save as `.splayback` documents. Those files store the slide list, settings, and security-scoped media bookmarks; they do not embed the original media files.

## Distribution

Release packaging, notarization, Sparkle updates, and GitHub Pages staging are documented in [Distribution/README.md](Distribution/README.md).
