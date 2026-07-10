#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_VERSION="2.9.4"
TOOLS_DIR="$ROOT_DIR/.build/Sparkle-$SPARKLE_VERSION"

if [[ ! -x "$TOOLS_DIR/bin/generate_appcast" ]]; then
  archive="$ROOT_DIR/.build/Sparkle-$SPARKLE_VERSION.tar.xz"
  /bin/mkdir -p "$ROOT_DIR/.build" "$TOOLS_DIR"
  gh release download "$SPARKLE_VERSION" \
    --repo sparkle-project/Sparkle \
    --pattern "Sparkle-$SPARKLE_VERSION.tar.xz" \
    --output "$archive" \
    --clobber
  /usr/bin/tar -xf "$archive" -C "$TOOLS_DIR" --strip-components 1
fi

echo "$TOOLS_DIR/bin"
