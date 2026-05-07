#!/bin/zsh
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <app-path> <output-dmg>" >&2
  exit 64
fi

app_path="$1"
output_dmg="$2"
volume_name="${3:-Simple Playback}"
development_team="${DEVELOPMENT_TEAM:-}"
sign_identity="${DMG_SIGN_IDENTITY:-}"

if [[ ! -d "$app_path" ]]; then
  echo "App bundle does not exist: $app_path" >&2
  exit 66
fi

staging_dir="$(mktemp -d)"
trap 'rm -rf "$staging_dir"' EXIT

ditto "$app_path" "${staging_dir}/$(basename "$app_path")"
ln -s /Applications "${staging_dir}/Applications"
mkdir -p "$(dirname "$output_dmg")"

hdiutil create \
  -volname "$volume_name" \
  -srcfolder "$staging_dir" \
  -ov \
  -format UDZO \
  "$output_dmg"

if [[ -z "$sign_identity" ]]; then
  while IFS= read -r identity_line; do
    if [[ "$identity_line" =~ '"(Developer ID Application: [^"]*)"' ]]; then
      candidate="${match[1]}"
      if [[ -z "$development_team" || "$candidate" == *"(${development_team})" ]]; then
        sign_identity="$candidate"
        break
      fi
    fi
  done < <(security find-identity -v -p codesigning)
fi

if [[ -z "$sign_identity" ]]; then
  echo "No Developer ID Application identity was found to sign the DMG." >&2
  echo "Set DMG_SIGN_IDENTITY or DEVELOPMENT_TEAM, then rebuild the release." >&2
  exit 78
fi

echo "Signing DMG with: $sign_identity"
codesign --force --timestamp --sign "$sign_identity" "$output_dmg"
codesign --verify --verbose=2 "$output_dmg"
