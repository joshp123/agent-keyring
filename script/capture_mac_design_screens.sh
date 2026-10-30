#!/usr/bin/env bash
# Written by AI on 2026.10.31 by model Claude Opus 5.5.
#
# Builds the Mac design gallery, runs it on the Mac mini and saves a
# screenshot of each Mac screen to docs/design/screens/mac/. Nothing shows on
# this Mac. Needs Josh's nix-secrets and nixos-config checkouts.
#
# usage: script/capture_mac_design_screens.sh [screen ...]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT_DIR/docs/design/screens/mac"
BUILD="${TMPDIR:-/tmp}/agent-keyring-design-gallery"
APP="$BUILD/AgentKeyringDesignGallery.app"
REMOTE_DIR=/tmp/agent-keyring-design-gallery

swift build --package-path "$ROOT_DIR/AgentKeyringPackage" --product AgentKeyringDesignGallery \
  --scratch-path "$BUILD/swiftpm" -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD/swiftpm/release/AgentKeyringDesignGallery" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>AgentKeyringDesignGallery</string>
  <key>CFBundleIdentifier</key><string>com.joshpalmer.AgentKeyring.DesignGallery</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleName</key><string>Agent Keyring Design Gallery</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"

ssh mac-mini "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR"
scp -qr "$APP" "mac-mini:$REMOTE_DIR/"

mkdir -p "$OUT"
age -d -i ~/.ssh/id_ed25519 ~/code/nix/nix-secrets/mac-mini/login-password.age |
  nix shell --impure --expr '(builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem}.python3.withPackages (p: [ p.vncdotool ])' \
    -c python3 -u "$ROOT_DIR/script/capture_mac_design_screens.py" \
    "$REMOTE_DIR/AgentKeyringDesignGallery.app" "$OUT" "$@"

ssh mac-mini "rm -rf $REMOTE_DIR"
