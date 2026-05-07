#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <dmg-path> [notary-keychain-profile]" >&2
  exit 64
fi

dmg_path="$1"
profile_name="${2:-${NOTARY_PROFILE:-simple-playback-notary}}"

if [[ ! -f "$dmg_path" ]]; then
  echo "DMG does not exist: $dmg_path" >&2
  exit 66
fi

xcrun notarytool submit "$dmg_path" --keychain-profile "$profile_name" --wait
xcrun stapler staple "$dmg_path"
spctl -a -t open --context context:primary-signature -v "$dmg_path"
