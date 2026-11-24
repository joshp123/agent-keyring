#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Pin the CLI tools to 2.9.4 so generate_keys / generate_appcast match the
# login Keychain ACL created for the existing Ed25519 Sparkle signing key
# (Sparkle's prebuilt CLI binaries are ad-hoc signed per release). Ed25519
# appcasts produced by 2.9.4 are fully compatible with Sparkle 2.10.x in the app.
SPARKLE_VERSION="2.9.4"
SPARKLE_SHA256="ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9"
TOOLS_DIR="$ROOT_DIR/.build/Sparkle-$SPARKLE_VERSION"

if [[ ! -x "$TOOLS_DIR/bin/generate_appcast" || ! -x "$TOOLS_DIR/bin/generate_keys" ]]; then
  archive="$ROOT_DIR/.build/Sparkle-$SPARKLE_VERSION.tar.xz"
  staging="$ROOT_DIR/.build/Sparkle-$SPARKLE_VERSION.tmp"
  /bin/mkdir -p "$ROOT_DIR/.build"
  if [[ -e "$staging" ]]; then
    /bin/rm -r "$staging"
  fi
  /bin/mkdir -p "$staging"
  gh release download "$SPARKLE_VERSION" \
    --repo sparkle-project/Sparkle \
    --pattern "Sparkle-$SPARKLE_VERSION.tar.xz" \
    --output "$archive" \
    --clobber
  actual_sha256="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
  if [[ "$actual_sha256" != "$SPARKLE_SHA256" ]]; then
    echo "Sparkle-$SPARKLE_VERSION.tar.xz SHA-256 mismatch: got $actual_sha256, expected $SPARKLE_SHA256" >&2
    /bin/rm "$archive"
    exit 1
  fi
  /usr/bin/tar -xf "$archive" -C "$staging"
  if [[ -e "$TOOLS_DIR" ]]; then
    /bin/rm -r "$TOOLS_DIR"
  fi
  /bin/mv "$staging" "$TOOLS_DIR"
fi

echo "$TOOLS_DIR/bin"
