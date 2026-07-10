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
UPDATE_DIR="$BUILD_DIR/update"
APP_PATH="$EXPORT_DIR/AgentKeyring.app"
ZIP_PATH="$UPDATE_DIR/Agent-Keyring-$VERSION.zip"
UPLOAD_OPTIONS="$BUILD_DIR/UploadOptions.plist"

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

latest_build=""
if [[ -f "$ROOT_DIR/docs/appcast.xml" ]]; then
  latest_build="$(/usr/bin/grep -o 'sparkle:version="[0-9]*"' "$ROOT_DIR/docs/appcast.xml" \
    | /usr/bin/head -n 1 | /usr/bin/tr -cd '0-9' || true)"
fi
if [[ -n "$latest_build" && "$BUILD_NUMBER" -le "$latest_build" ]]; then
  echo "Build $BUILD_NUMBER must be newer than appcast build $latest_build." >&2
  exit 1
fi

team_id="$(awk -F= '/^[[:space:]]*AGENT_KEYRING_TEAM_ID[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2}' "$ROOT_DIR/Config/Local.xcconfig")"
if [[ -z "$team_id" ]]; then
  echo "Config/Local.xcconfig does not contain AGENT_KEYRING_TEAM_ID." >&2
  exit 1
fi

/bin/rm -rf "$BUILD_DIR"
/bin/mkdir -p "$BUILD_DIR" "$EXPORT_DIR" "$UPDATE_DIR"
/bin/echo "$SOURCE_COMMIT" > "$BUILD_DIR/source-commit.txt"
/bin/echo "$BUILD_NUMBER" > "$BUILD_DIR/build-number.txt"

/usr/bin/xcodebuild \
  -workspace "$ROOT_DIR/AgentKeyring.xcworkspace" \
  -scheme AgentKeyring \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive

/usr/bin/plutil -create xml1 "$UPLOAD_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :method string developer-id' "$UPLOAD_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :destination string upload' "$UPLOAD_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :signingStyle string automatic' "$UPLOAD_OPTIONS"
/usr/libexec/PlistBuddy -c "Add :teamID string $team_id" "$UPLOAD_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :stripSwiftSymbols bool true' "$UPLOAD_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :manageAppVersionAndBuildNumber bool false' "$UPLOAD_OPTIONS"

/usr/bin/xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$UPLOAD_OPTIONS" \
  -allowProvisioningUpdates

# Xcode uses the signed-in developer account for cloud signing and notarisation.
# Poll until Apple finishes processing, then export the stapled app.
for _ in {1..60}; do
  /bin/rm -rf "$EXPORT_DIR"
  if /usr/bin/xcodebuild \
    -quiet \
    -exportNotarizedApp \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR"; then
    break
  fi
  /bin/sleep 30
done

if [[ ! -d "$APP_PATH" ]]; then
  echo "Apple did not finish notarising AgentKeyring.app within 30 minutes." >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
/usr/bin/file "$APP_PATH/Contents/Helpers/agent-keyring" | /usr/bin/grep -q 'universal binary'
/bin/test -f "$APP_PATH/Contents/Resources/AgentTools/CodexSkill/agent-keyring/SKILL.md"
/usr/bin/xcrun stapler validate "$APP_PATH"
/usr/sbin/spctl --assess --type execute -vv "$APP_PATH"

entitlements="$BUILD_DIR/distribution-entitlements.plist"
/usr/bin/codesign -d --entitlements "$entitlements" "$APP_PATH"
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$entitlements" >/dev/null 2>&1; then
  echo "The exported app still has get-task-allow and cannot be notarised." >&2
  exit 1
fi

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

sparkle_tools="$($ROOT_DIR/script/fetch_sparkle_tools.sh)"
configured_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT_DIR/AgentKeyring/Info.plist")"
signing_public_key="$("$sparkle_tools/generate_keys" -p)"
if [[ "$configured_public_key" != "$signing_public_key" ]]; then
  echo "The Sparkle signing key does not match SUPublicEDKey." >&2
  exit 1
fi
if [[ -f "$ROOT_DIR/docs/appcast.xml" ]]; then
  /bin/cp "$ROOT_DIR/docs/appcast.xml" "$UPDATE_DIR/appcast.xml"
fi
/usr/bin/tail -n +5 "$ROOT_DIR/Distribution/ReleaseNotes.md" > "$UPDATE_DIR/Agent-Keyring-$VERSION.md"
"$sparkle_tools/generate_appcast" \
  --download-url-prefix "https://github.com/joshp123/agent-keyring/releases/download/v$VERSION/" \
  --link 'https://github.com/joshp123/agent-keyring' \
  --maximum-versions 5 \
  --maximum-deltas 0 \
  -o "$ROOT_DIR/docs/appcast.xml" \
  "$UPDATE_DIR"

expected_url="https://github.com/joshp123/agent-keyring/releases/download/v$VERSION/Agent-Keyring-$VERSION.zip"
zip_size="$(/usr/bin/stat -f %z "$ZIP_PATH")"
/usr/bin/grep -Fq "sparkle:shortVersionString=\"$VERSION\"" "$ROOT_DIR/docs/appcast.xml"
/usr/bin/grep -Fq "sparkle:version=\"$BUILD_NUMBER\"" "$ROOT_DIR/docs/appcast.xml"
/usr/bin/grep -Fq "url=\"$expected_url\"" "$ROOT_DIR/docs/appcast.xml"
/usr/bin/grep -Fq "length=\"$zip_size\"" "$ROOT_DIR/docs/appcast.xml"
/usr/bin/grep -Eq 'sparkle:edSignature="[A-Za-z0-9+/=]+"' "$ROOT_DIR/docs/appcast.xml"

echo "Release artefacts are ready:"
echo "  $ZIP_PATH"
echo "  $ROOT_DIR/docs/appcast.xml"
