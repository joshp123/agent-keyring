#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_BROWSER="${AGENT_BROWSER:-$HOME/.local/state/nix/profiles/ai/bin/agent-browser}"

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [agent-keyring-executable]" >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  CLI_PATH="$1"
else
  CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-cache" /usr/bin/xcrun swift build \
    --package-path "$ROOT_DIR/AgentKeyringPackage" --cache-path "$ROOT_DIR/.build/swiftpm-cache" \
    --scratch-path "$ROOT_DIR/.build/scratch" --product agent-keyring
  CLI_PATH="$ROOT_DIR/.build/scratch/debug/agent-keyring"
fi

# This server accepts only the app's public example login. No imported login is requested.
exec python3 "$ROOT_DIR/script/prove_browser_plugin.py" "$AGENT_BROWSER" "$CLI_PATH"
