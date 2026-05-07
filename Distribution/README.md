# Distribution

Simple Playback is set up for direct distribution outside the Mac App Store:

- Developer ID signed app export
- Developer ID signed and notarized DMG installer
- Sparkle 2 updates served from an HTTPS appcast

## One-Time Setup

1. Install a `Developer ID Application` certificate in the login keychain.
2. If the signing team is not stored in the project, pass it when packaging:

```sh
DEVELOPMENT_TEAM=YOURTEAMID Scripts/package-release.sh
```

Xcode can create or download signing assets from a signed-in developer account
when `DEVELOPMENT_TEAM` is provided and automatic provisioning updates are
allowed.

3. Store notarization credentials:

```sh
Scripts/store-notary-credentials.sh simple-playback-notary
```

4. Resolve packages so Sparkle tools are available:

```sh
xcodebuild -resolvePackageDependencies -project "Simple Playback.xcodeproj"
```

5. Generate Sparkle signing keys:

```sh
Scripts/generate-sparkle-keys.sh
```

6. Copy the printed public EdDSA key into `SPARKLE_PUBLIC_ED_KEY` in `project.yml`, then regenerate the Xcode project:

```sh
xcodegen generate
```

Check distribution readiness:

```sh
Scripts/preflight-distribution.sh
```

## Release

Create a signed app export, a zip archive for Sparkle, and a DMG:

```sh
Scripts/package-release.sh
```

Notarize and staple the DMG:

```sh
Scripts/notarize-dmg.sh "build/distribution/Simple Playback-0.1.0.dmg"
```

Generate or update the Sparkle appcast from a folder containing Sparkle update zip archives:

```sh
Scripts/generate-appcast.sh build/distribution/appcast
```

Stage the GitHub Pages release site:

```sh
Scripts/stage-pages-release.sh 0.1.0
```

The DMG is the installer you share with people. The zip in `build/distribution/appcast` is the Sparkle update archive. The `docs` folder is the GitHub Pages source and must include `appcast.xml` and the matching Sparkle zip at the site root.

The default appcast URL is:

```text
https://joshrogers117.github.io/simple-playback/appcast.xml
```

Change `SPARKLE_FEED_URL` in `project.yml` before shipping if the update feed will live elsewhere.
