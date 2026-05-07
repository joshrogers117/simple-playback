#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

updates_dir="${1:-build/distribution/appcast}"
generate_appcast="$(Scripts/find-sparkle-tool.sh generate_appcast)"

if [[ ! -d "$updates_dir" ]]; then
  echo "Updates directory does not exist: $updates_dir" >&2
  exit 66
fi

"$generate_appcast" "$updates_dir"
