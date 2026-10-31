#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Use the same nixpkgs revision as protobuf generation and devenv.
if [[ "${AGENT_KEYRING_PINNED_GO:-}" != 1 ]]; then
  exec nix shell 'github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df#go' \
    -c env AGENT_KEYRING_PINNED_GO=1 bash script/build_cli.sh "$@"
fi
mkdir -p build/cli/macos
for architecture in arm64 amd64; do
  CGO_ENABLED=0 GOOS=darwin GOARCH="$architecture" go build -trimpath -ldflags='-s -w' \
    -o "build/cli/macos/agent-keyring-$architecture" ./cmd/agent-keyring
done
/usr/bin/lipo -create build/cli/macos/agent-keyring-arm64 build/cli/macos/agent-keyring-amd64 \
  -output build/cli/macos/agent-keyring
printf '%s\n' "$PWD/build/cli/macos/agent-keyring"
