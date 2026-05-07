#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <sparkle-tool-name>" >&2
  exit 64
fi

tool_name="$1"

if [[ -n "${SPARKLE_BIN:-}" && -x "${SPARKLE_BIN}/${tool_name}" ]]; then
  echo "${SPARKLE_BIN}/${tool_name}"
  exit 0
fi

candidate_roots=(
  "${PWD}/.build/artifacts/sparkle/Sparkle/bin"
  "${PWD}/SourcePackages/artifacts/sparkle/Sparkle/bin"
  "${HOME}/Library/Developer/Xcode/DerivedData"
)

for root in "${candidate_roots[@]}"; do
  if [[ ! -e "$root" ]]; then
    continue
  fi

  if [[ -x "${root}/${tool_name}" ]]; then
    echo "${root}/${tool_name}"
    exit 0
  fi

  match="$(
    find "$root" -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/${tool_name}" -type f 2>/dev/null | while IFS= read -r path; do
      if [[ -x "$path" ]]; then
        echo "$path"
        break
      fi
    done
  )"
  if [[ -n "$match" ]]; then
    echo "$match"
    exit 0
  fi
done

cat >&2 <<EOF
Could not find Sparkle tool '${tool_name}'.

Run package resolution first:

  xcodebuild -resolvePackageDependencies -project "Simple Playback.xcodeproj"

Or set SPARKLE_BIN to the directory that contains Sparkle's command-line tools.
EOF
exit 69
