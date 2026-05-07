#!/bin/zsh
set -euo pipefail

profile_name="${1:-simple-playback-notary}"

xcrun notarytool store-credentials "$profile_name"
