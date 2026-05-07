#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

project="Simple Playback.xcodeproj"
scheme="Simple Playback"
failures=0
warnings=0

ok() {
  printf "OK   %s\n" "$1"
}

warn() {
  printf "WARN %s\n" "$1" >&2
  warnings=$((warnings + 1))
}

fail() {
  printf "FAIL %s\n" "$1" >&2
  failures=$((failures + 1))
}

if command -v xcodegen >/dev/null 2>&1; then
  ok "xcodegen is installed"
else
  fail "xcodegen is not installed"
fi

if xcodebuild -version >/dev/null 2>&1; then
  ok "xcodebuild is available"
else
  fail "xcodebuild is not available"
fi

if xcrun --find notarytool >/dev/null 2>&1; then
  ok "notarytool is available"
else
  fail "notarytool is not available"
fi

if Scripts/find-sparkle-tool.sh generate_keys >/dev/null 2>&1; then
  ok "Sparkle generate_keys is available"
else
  fail "Sparkle generate_keys was not found; resolve packages first"
fi

if Scripts/find-sparkle-tool.sh generate_appcast >/dev/null 2>&1; then
  ok "Sparkle generate_appcast is available"
else
  fail "Sparkle generate_appcast was not found; resolve packages first"
fi

build_settings="$(xcodebuild -project "$project" -scheme "$scheme" -configuration Release -showBuildSettings 2>/dev/null || true)"
if [[ -n "$build_settings" ]]; then
  ok "Release build settings can be read"
else
  fail "Release build settings could not be read"
fi

sparkle_public_key="$(printf "%s\n" "$build_settings" | sed -n 's/^[[:space:]]*SPARKLE_PUBLIC_ED_KEY = //p' | tail -n 1)"
if [[ -n "$sparkle_public_key" && "$sparkle_public_key" != "\"\"" ]]; then
  ok "Sparkle public EdDSA key is configured"
else
  fail "Sparkle public EdDSA key is blank"
fi

configured_team="$(printf "%s\n" "$build_settings" | sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = //p' | tail -n 1)"
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  ok "DEVELOPMENT_TEAM is provided in the environment"
elif [[ -n "$configured_team" ]]; then
  ok "DEVELOPMENT_TEAM is configured in the project"
else
  warn "DEVELOPMENT_TEAM is not configured; pass DEVELOPMENT_TEAM=YOURTEAMID when packaging"
fi

developer_id_count="$(security find-identity -v -p codesigning | grep -c "Developer ID Application" || true)"
if [[ "$developer_id_count" -gt 0 ]]; then
  ok "Developer ID Application signing identity is installed"
else
  fail "Developer ID Application signing identity was not found in Keychain"
fi

if [[ "$failures" -gt 0 ]]; then
  printf "\n%d preflight check(s) failed, %d warning(s).\n" "$failures" "$warnings" >&2
  exit 78
fi

printf "\nDistribution preflight passed with %d warning(s).\n" "$warnings"
