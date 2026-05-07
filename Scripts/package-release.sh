#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

project="Simple Playback.xcodeproj"
scheme="Simple Playback"
build_root="${BUILD_ROOT:-build/distribution}"
archive_path="${build_root}/archives/Simple Playback.xcarchive"
export_path="${build_root}/export"
export_options="${EXPORT_OPTIONS_PLIST:-Distribution/ExportOptions-DeveloperID.plist}"
app_path="${export_path}/Simple Playback.app"
development_team="${DEVELOPMENT_TEAM:-}"
allow_provisioning_updates="${ALLOW_PROVISIONING_UPDATES:-1}"

mkdir -p "$build_root"
rm -rf "$archive_path" "$export_path"

if [[ -z "$development_team" ]]; then
  development_team="$(xcodebuild -project "$project" -scheme "$scheme" -configuration Release -showBuildSettings 2>/dev/null | sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = //p' | tail -n 1)"
fi

sparkle_public_key="$(xcodebuild -project "$project" -scheme "$scheme" -configuration Release -showBuildSettings 2>/dev/null | sed -n 's/^[[:space:]]*SPARKLE_PUBLIC_ED_KEY = //p' | tail -n 1)"
if [[ -z "$sparkle_public_key" || "$sparkle_public_key" == "\"\"" ]]; then
  cat >&2 <<EOF
Sparkle public key is not configured.

Run:
  Scripts/generate-sparkle-keys.sh

Then copy the printed public EdDSA key into SPARKLE_PUBLIC_ED_KEY in project.yml and run:
  xcodegen generate
EOF
  exit 78
fi

developer_id_count="$(security find-identity -v -p codesigning | grep -c "Developer ID Application" || true)"
if [[ "$developer_id_count" -eq 0 && -z "$development_team" ]]; then
  cat >&2 <<EOF
No Developer ID Application signing identity was found, and no DEVELOPMENT_TEAM is configured.

Xcode can often create or download the right signing assets when your Apple
Developer account is signed in, but command-line packaging needs a Team ID.

Run this once you know your Team ID:
  DEVELOPMENT_TEAM=YOURTEAMID Scripts/package-release.sh

Or add DEVELOPMENT_TEAM to project.yml and regenerate the Xcode project.
EOF
  exit 78
fi

archive_extra_args=()
export_extra_args=()
if [[ -n "$development_team" ]]; then
  archive_extra_args+=("DEVELOPMENT_TEAM=${development_team}")
  export_options_with_team="${build_root}/ExportOptions-DeveloperID-with-team.plist"
  cp "$export_options" "$export_options_with_team"
  /usr/libexec/PlistBuddy -c "Delete :teamID" "$export_options_with_team" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :teamID string ${development_team}" "$export_options_with_team"
  export_options="$export_options_with_team"
fi

if [[ "$allow_provisioning_updates" != "0" ]]; then
  archive_extra_args+=("-allowProvisioningUpdates")
  export_extra_args+=("-allowProvisioningUpdates")
fi

xcodebuild archive \
  -project "$project" \
  -scheme "$scheme" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$archive_path" \
  "${archive_extra_args[@]}"

xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options" \
  "${export_extra_args[@]}"

if [[ ! -d "$app_path" ]]; then
  echo "Exported app was not found: $app_path" >&2
  exit 70
fi

version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${app_path}/Contents/Info.plist")"
zip_path="${build_root}/Simple Playback-${version}.zip"
dmg_path="${build_root}/Simple Playback-${version}.dmg"
appcast_path="${build_root}/appcast"

rm -f "$zip_path" "$dmg_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
mkdir -p "$appcast_path"
rm -f "${appcast_path}/$(basename "$zip_path")"
cp "$zip_path" "$appcast_path/"
DEVELOPMENT_TEAM="$development_team" Scripts/create-dmg.sh "$app_path" "$dmg_path"

cat <<EOF
Release artifacts:
  App: $app_path
  Zip: $zip_path
  DMG: $dmg_path
  Appcast folder: $appcast_path

Next:
  Scripts/notarize-dmg.sh "$dmg_path"
  Scripts/generate-appcast.sh "$appcast_path"
EOF
