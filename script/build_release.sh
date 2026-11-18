#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 VERSION" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_NUMBER="${AGENT_KEYRING_BUILD_NUMBER:-$(/bin/date -u +%Y%m%d%H%M)}"
BUILD_DIR="$ROOT_DIR/.build/Release-$VERSION"
ARCHIVE_PATH="$BUILD_DIR/AgentKeyring.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
OUT_DIR="$BUILD_DIR/out"
# On disk the new app is "Agent Keyring.app", beside 0.2.5's "AgentKeyring.app".
APP_PATH="$OUT_DIR/Agent Keyring.app"
ZIP_PATH="$OUT_DIR/Agent-Keyring-$VERSION.zip"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"

# Signing, profiles and notarisation use an App Store Connect API key, so no
# Apple account has to be signed in to Xcode.
for variable in AGENT_KEYRING_ASC_KEY_PATH AGENT_KEYRING_ASC_KEY_ID AGENT_KEYRING_ASC_ISSUER_ID; do
  if [[ -z "${!variable:-}" ]]; then
    echo "Set $variable (the App Store Connect API key's file, ID and issuer)." >&2
    exit 1
  fi
done
AUTH=(-authenticationKeyPath "$AGENT_KEYRING_ASC_KEY_PATH" -authenticationKeyID "$AGENT_KEYRING_ASC_KEY_ID"
  -authenticationKeyIssuerID "$AGENT_KEYRING_ASC_ISSUER_ID")

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "AGENT_KEYRING_BUILD_NUMBER must be a positive integer." >&2
  exit 1
fi
if [[ -n "$(git -C "$ROOT_DIR" status --short)" ]]; then
  echo "Commit all source changes before building a release." >&2
  exit 1
fi

SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
UPSTREAM_COMMIT="$(git -C "$ROOT_DIR" rev-parse '@{upstream}')"
if [[ "$SOURCE_COMMIT" != "$UPSTREAM_COMMIT" ]]; then
  echo "Push the exact source commit before building a release." >&2
  exit 1
fi

team_id="$(awk -F= '/^[[:space:]]*AGENT_KEYRING_TEAM_ID[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2}' "$ROOT_DIR/Config/Local.xcconfig")"
if [[ -z "$team_id" ]]; then
  echo "Config/Local.xcconfig does not contain AGENT_KEYRING_TEAM_ID." >&2
  exit 1
fi

/bin/rm -rf "$BUILD_DIR"
/bin/mkdir -p "$BUILD_DIR" "$EXPORT_DIR" "$OUT_DIR"
/bin/echo "$SOURCE_COMMIT" > "$BUILD_DIR/source-commit.txt"
/bin/echo "$BUILD_NUMBER" > "$BUILD_DIR/build-number.txt"

"$ROOT_DIR/script/build_cli.sh"

/usr/bin/xcodebuild \
  -workspace "$ROOT_DIR/AgentKeyring.xcworkspace" \
  -scheme AgentKeyring \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates "${AUTH[@]}" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive

/usr/bin/plutil -create xml1 "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :method string developer-id' "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :destination string export' "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :signingStyle string automatic' "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Add :teamID string $team_id" "$EXPORT_OPTIONS"

/usr/bin/xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates "${AUTH[@]}"
/bin/mv "$EXPORT_DIR/AgentKeyring.app" "$APP_PATH"

# Apple notarises the zip; the ticket is then stapled to the app itself.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
/usr/bin/xcrun notarytool submit "$ZIP_PATH" --key "$AGENT_KEYRING_ASC_KEY_PATH" --key-id "$AGENT_KEYRING_ASC_KEY_ID" \
  --issuer "$AGENT_KEYRING_ASC_ISSUER_ID" --wait
/usr/bin/xcrun stapler staple "$APP_PATH"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
/usr/bin/file "$APP_PATH/Contents/Helpers/agent-keyring" | /usr/bin/grep -q 'universal binary'
/bin/test -f "$APP_PATH/Contents/Resources/AgentTools/AgentSkill/agent-keyring/SKILL.md"
/usr/bin/xcrun stapler validate "$APP_PATH"
/usr/sbin/spctl --assess --type execute -vv "$APP_PATH"

entitlements="$BUILD_DIR/distribution-entitlements.plist"
/usr/bin/codesign -d --entitlements "$entitlements" "$APP_PATH"
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$entitlements" >/dev/null 2>&1; then
  echo "The exported app still has get-task-allow and cannot be notarised." >&2
  exit 1
fi

/bin/rm "$ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Release artefacts are ready:"
echo "  $APP_PATH"
echo "  $ZIP_PATH"
