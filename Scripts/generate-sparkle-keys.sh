#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

generate_keys="$(Scripts/find-sparkle-tool.sh generate_keys)"

cat <<EOF
This creates a private Sparkle EdDSA signing key in your keychain.
Keep the private key backed up securely. Releases cannot be updated if it is lost.

EOF

"$generate_keys"
