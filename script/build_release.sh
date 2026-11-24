#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
  echo "usage: $0 (the version is the VERSION file; script/version.sh)" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
read -r VERSION BUILD_NUMBER < <("$ROOT_DIR/script/version.sh")
BUILD_DIR="$ROOT_DIR/.build/Release-$VERSION"
ARCHIVE_PATH="$BUILD_DIR/AgentKeyring.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
OUT_DIR="$BUILD_DIR/out"
UPDATE_DIR="$BUILD_DIR/sparkle-update"
LIVE_APPCAST="$BUILD_DIR/live-appcast.xml"
# On disk the new app is "Agent Keyring.app", beside 0.2.5's "AgentKeyring.app".
APP_PATH="$OUT_DIR/Agent Keyring.app"
ZIP_PATH="$OUT_DIR/Agent-Keyring-$VERSION.zip"
APPCAST_PATH="$OUT_DIR/appcast.xml"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
EXPECTED_URL="https://github.com/opentrawl/agent-keyring/releases/download/v$VERSION/Agent-Keyring-$VERSION.zip"

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

if [[ -n "$(git -C "$ROOT_DIR" status --short)" ]]; then
  echo "Commit all source changes before building a release." >&2
  exit 1
fi

SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
git -C "$ROOT_DIR" fetch --quiet origin main
ORIGIN_MAIN_COMMIT="$(git -C "$ROOT_DIR" rev-parse origin/main)"
if [[ "$SOURCE_COMMIT" != "$ORIGIN_MAIN_COMMIT" ]]; then
  echo "HEAD ($SOURCE_COMMIT) must match origin/main ($ORIGIN_MAIN_COMMIT) before building a release." >&2
  exit 1
fi

team_id="$(awk -F= '/^[[:space:]]*AGENT_KEYRING_TEAM_ID[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2}' "$ROOT_DIR/Config/Local.xcconfig")"
if [[ -z "$team_id" ]]; then
  echo "Config/Local.xcconfig does not contain AGENT_KEYRING_TEAM_ID." >&2
  exit 1
fi

# Verify Sparkle signing key and feed configuration before archiving.
sparkle_tools="$("$ROOT_DIR/script/fetch_sparkle_tools.sh")"
configured_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT_DIR/AgentKeyring/Info.plist")"
feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$ROOT_DIR/AgentKeyring/Info.plist")"
if [[ "$feed_url" != https://* ]]; then
  echo "SUFeedURL in AgentKeyring/Info.plist must use https:// (got: $feed_url)." >&2
  exit 1
fi
signing_public_key="$("$sparkle_tools/generate_keys" -p)"
if [[ "$configured_public_key" != "$signing_public_key" ]]; then
  echo "The Sparkle signing key does not match SUPublicEDKey in AgentKeyring/Info.plist." >&2
  exit 1
fi

if [[ -e "$BUILD_DIR" ]]; then
  /bin/rm -r "$BUILD_DIR"
fi
/bin/mkdir -p "$BUILD_DIR" "$EXPORT_DIR" "$OUT_DIR" "$UPDATE_DIR"
/bin/echo "$SOURCE_COMMIT" > "$BUILD_DIR/source-commit.txt"
/bin/echo "$BUILD_NUMBER" > "$BUILD_DIR/build-number.txt"

# Fail closed when fetching the live appcast unless bootstrap is explicitly requested.
live_http_code="$(/usr/bin/curl -sS -o "$LIVE_APPCAST" -w '%{http_code}' "$feed_url")"
if [[ "$live_http_code" == "200" ]]; then
  if [[ "${AGENT_KEYRING_ALLOW_BOOTSTRAP_APPCAST:-0}" == "1" ]]; then
    echo "AGENT_KEYRING_ALLOW_BOOTSTRAP_APPCAST=1 was set, but $feed_url already returned HTTP 200." >&2
    exit 1
  fi
  /usr/bin/xmllint --noout "$LIVE_APPCAST"
  latest_build="$(/usr/bin/python3 - "$LIVE_APPCAST" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
root = ET.parse(sys.argv[1]).getroot()
if root.tag != "rss":
    sys.exit("Live appcast root element is not <rss>")
versions = []
for item in root.findall("./channel/item"):
    v = item.findtext("sparkle:version", namespaces=ns)
    if v and v.strip().isdigit():
        versions.append(int(v.strip()))
print(max(versions) if versions else "")
PY
)"
  if [[ -n "$latest_build" && "$BUILD_NUMBER" -le "$latest_build" ]]; then
    echo "Build $BUILD_NUMBER must be newer than live appcast build $latest_build." >&2
    exit 1
  fi
  /usr/bin/shasum -a 256 "$LIVE_APPCAST" | /usr/bin/awk '{print $1}' > "$BUILD_DIR/live-appcast.sha256"
elif [[ "${AGENT_KEYRING_ALLOW_BOOTSTRAP_APPCAST:-0}" == "1" && ( "$live_http_code" == "403" || "$live_http_code" == "404" ) ]]; then
  /bin/rm "$LIVE_APPCAST"
  /bin/echo "BOOTSTRAP" > "$BUILD_DIR/live-appcast.sha256"
else
  echo "Failed to fetch existing appcast at $feed_url (HTTP $live_http_code). Set AGENT_KEYRING_ALLOW_BOOTSTRAP_APPCAST=1 only for initial feed creation." >&2
  exit 1
fi

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
# Signed with the Developer ID certificate in this Mac's keychain and the
# Developer ID profiles named here (an API key cannot use cloud signing).
prefix="$(awk -F= '/^[[:space:]]*AGENT_KEYRING_BUNDLE_ID_PREFIX[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2}' "$ROOT_DIR/Config/Local.xcconfig")"
/usr/libexec/PlistBuddy -c 'Add :signingStyle string manual' "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :signingCertificate string Developer ID Application' "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Add :teamID string $team_id" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :provisioningProfiles dict' "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$prefix.AgentKeyring.Mac string Agent Keyring Mac Developer ID" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$prefix.AgentKeyring.Mac.CredentialProvider string Agent Keyring Mac Credential Provider Developer ID" "$EXPORT_OPTIONS"

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
/bin/test -d "$APP_PATH/Contents/Frameworks/Sparkle.framework"
/usr/bin/xcrun stapler validate "$APP_PATH"
/usr/sbin/spctl --assess --type execute -vv "$APP_PATH"

app_info="$APP_PATH/Contents/Info.plist"
[[ "$(/usr/bin/plutil -extract SUFeedURL raw -o - "$app_info")" == "$feed_url" ]]
[[ "$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "$app_info")" == "$configured_public_key" ]]
[[ "$(/usr/bin/plutil -extract SUEnableAutomaticChecks raw -o - "$app_info")" == "true" ]]
[[ "$(/usr/bin/plutil -extract SUAutomaticallyUpdate raw -o - "$app_info")" == "true" ]]
[[ "$(/usr/bin/plutil -extract SUEnableInstallerLauncherService raw -o - "$app_info")" == "true" ]]
[[ "$(/usr/bin/plutil -extract SUEnableSystemProfiling raw -o - "$app_info")" == "false" ]]

entitlements="$BUILD_DIR/distribution-entitlements.plist"
/usr/bin/codesign -d --entitlements "$entitlements" --xml "$APP_PATH"
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$entitlements" >/dev/null 2>&1; then
  echo "The exported app still has get-task-allow and cannot be notarised." >&2
  exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$entitlements")" == "true" ]]
/usr/bin/grep -Fq -- "-spks" "$entitlements"
/usr/bin/grep -Fq -- "-spki" "$entitlements"

/bin/rm "$ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

# Build and cryptographically verify the signed Sparkle 2 appcast.
if [[ -f "$LIVE_APPCAST" ]]; then
  /bin/cp "$LIVE_APPCAST" "$UPDATE_DIR/appcast.xml"
fi
/bin/cp "$ZIP_PATH" "$UPDATE_DIR/Agent-Keyring-$VERSION.zip"
/usr/bin/awk '
  NR == 1 && $0 == "---" { in_frontmatter = 1; next }
  in_frontmatter && $0 == "---" { in_frontmatter = 0; stripped = 1; next }
  in_frontmatter { next }
  stripped && !started && $0 == "" { next }
  { started = 1; print }
' "$ROOT_DIR/Distribution/ReleaseNotes.md" > "$UPDATE_DIR/Agent-Keyring-$VERSION.md"
if [[ ! -s "$UPDATE_DIR/Agent-Keyring-$VERSION.md" ]]; then
  echo "Distribution/ReleaseNotes.md produced empty release notes." >&2
  exit 1
fi

"$sparkle_tools/generate_appcast" \
  --download-url-prefix "https://github.com/opentrawl/agent-keyring/releases/download/v$VERSION/" \
  --link 'https://keyring.opentrawl.sh/' \
  --embed-release-notes \
  --maximum-versions 5 \
  --maximum-deltas 0 \
  "$UPDATE_DIR"
/bin/cp "$UPDATE_DIR/appcast.xml" "$APPCAST_PATH"

/usr/bin/xmllint --noout "$APPCAST_PATH"
zip_size="$(/usr/bin/stat -f %z "$ZIP_PATH")"
ed_signature="$(/usr/bin/python3 - "$APPCAST_PATH" "$VERSION" "$BUILD_NUMBER" "$EXPECTED_URL" "$zip_size" <<'PY'
import sys, xml.etree.ElementTree as ET
appcast_path, version, build_number, expected_url, expected_size = sys.argv[1:6]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
sparkle_ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
root = ET.parse(appcast_path).getroot()
matched = None
for item in root.findall("./channel/item"):
    if (item.findtext("sparkle:version", namespaces=ns) or "").strip() == build_number:
        matched = item
        break
if matched is None:
    sys.exit(f"appcast.xml missing item for sparkle:version={build_number}")
short = (matched.findtext("sparkle:shortVersionString", namespaces=ns) or "").strip()
if short != version:
    sys.exit(f"appcast shortVersionString mismatch: got {short!r}, expected {version!r}")
enc = matched.find("enclosure")
if enc is None:
    sys.exit("appcast item missing enclosure")
if enc.attrib.get("url") != expected_url:
    sys.exit(f"appcast url mismatch: got {enc.attrib.get('url')!r}, expected {expected_url!r}")
if enc.attrib.get("length") != expected_size:
    sys.exit(f"appcast length mismatch: got {enc.attrib.get('length')!r}, expected {expected_size!r}")
sig = enc.attrib.get(sparkle_ns + "edSignature", "")
if not sig:
    sys.exit("appcast enclosure missing sparkle:edSignature")
print(sig)
PY
)"

/usr/bin/swift - "$configured_public_key" "$ed_signature" "$ZIP_PATH" <<'SWIFT'
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4,
      let keyData = Data(base64Encoded: CommandLine.arguments[1]),
      let sigData = Data(base64Encoded: CommandLine.arguments[2]) else {
    fputs("Failed to decode Sparkle public key or signature.\n", stderr)
    exit(1)
}
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
let payload = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
guard publicKey.isValidSignature(sigData, for: payload) else {
    fputs("Sparkle Ed25519 signature verification failed against ZIP payload.\n", stderr)
    exit(1)
}
SWIFT

echo "Release artefacts are ready:"
echo "  $APP_PATH"
echo "  $ZIP_PATH"
echo "  $APPCAST_PATH"
