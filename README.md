# Simple Playout

Simple Playout is a macOS media playout app for still images and videos with DeckLink output, software preview, palette-based media takes, video scrubbing, audio playback, and configurable crossfades.

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
xcodebuild -project SimplePlayout.xcodeproj -scheme SimplePlayout -destination 'platform=macOS' build
```

## Test

```sh
xcodebuild -project SimplePlayout.xcodeproj -scheme SimplePlayout -destination 'platform=macOS' test
```

## Notes

Projects save as `.splayout` documents. Those files store the slide list, settings, and security-scoped media bookmarks; they do not embed the original media files.
