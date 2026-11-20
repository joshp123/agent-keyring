#!/usr/bin/env bash
# Written by AI on 2026.11.20 by model claude opus 5.5.
#
# Builds the iPhone app, with its Apple Watch app inside, in one of two ways:
#
#   script/build_iphone.sh device       a Release build signed for development, to install over a cable
#   script/build_iphone.sh testflight   an App Store build, uploaded to App Store Connect for TestFlight
#
# docs/signing.md says how signing is arranged and where each piece lives.
#
# Needs, as for script/build_release.sh:
#   AGENT_KEYRING_ASC_KEY_PATH, AGENT_KEYRING_ASC_KEY_ID, AGENT_KEYRING_ASC_ISSUER_ID
# and for testflight, the team's Apple Distribution identity and `asc` signed in with the same key:
#   AGENT_KEYRING_DISTRIBUTION_P12, AGENT_KEYRING_DISTRIBUTION_P12_PASSWORD
# AGENT_KEYRING_BUILD_NUMBER defaults to the UTC time, so each upload's number is new.
# AGENT_KEYRING_UPLOAD=0 makes the App Store build without uploading it.
set -euo pipefail

MODE="${1:-}"
if [[ "$MODE" != device && "$MODE" != testflight ]]; then
  echo "usage: $0 device|testflight" >&2
  exit 2
fi
for variable in AGENT_KEYRING_ASC_KEY_PATH AGENT_KEYRING_ASC_KEY_ID AGENT_KEYRING_ASC_ISSUER_ID; do
  if [[ -z "${!variable:-}" ]]; then echo "$variable is not set." >&2; exit 2; fi
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_NUMBER="${AGENT_KEYRING_BUILD_NUMBER:-$(/bin/date -u +%Y%m%d%H%M)}"
BUILD_DIR="$ROOT_DIR/.build/iPhone-$MODE-$BUILD_NUMBER"
AUTH=(-authenticationKeyPath "$AGENT_KEYRING_ASC_KEY_PATH" -authenticationKeyID "$AGENT_KEYRING_ASC_KEY_ID"
  -authenticationKeyIssuerID "$AGENT_KEYRING_ASC_ISSUER_ID")
COMMON=(-project "$ROOT_DIR/AgentKeyringPhone.xcodeproj" -scheme AgentKeyringPhone -configuration Release
  -destination 'generic/platform=iOS' -derivedDataPath "$BUILD_DIR/derived"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates "${AUTH[@]}")
mkdir -p "$BUILD_DIR"

if [[ "$MODE" == device ]]; then
  xcodebuild "${COMMON[@]}" build
  ditto "$BUILD_DIR/derived/Build/Products/Release-iphoneos/AgentKeyringPhone.app" "$BUILD_DIR/AgentKeyringPhone.app"
  echo "Built $BUILD_DIR/AgentKeyringPhone.app (build $BUILD_NUMBER)."
  exit 0
fi

for variable in AGENT_KEYRING_DISTRIBUTION_P12 AGENT_KEYRING_DISTRIBUTION_P12_PASSWORD; do
  if [[ -z "${!variable:-}" ]]; then echo "$variable is not set." >&2; exit 2; fi
done

# The distribution identity goes into a keychain of its own for this run, never the login keychain,
# and the keychain search list is put back as it was however the run ends.
KEYCHAIN="$BUILD_DIR/signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
ORIGINAL_KEYCHAINS=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
  [[ -n "$line" ]] && ORIGINAL_KEYCHAINS+=("$line")
done < <(security list-keychains -d user)
restore() {
  security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
}
trap restore EXIT
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$AGENT_KEYRING_DISTRIBUTION_P12" -k "$KEYCHAIN" -P "$AGENT_KEYRING_DISTRIBUTION_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security > /dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" > /dev/null
security list-keychains -d user -s "$KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"

xcodebuild "${COMMON[@]}" -archivePath "$BUILD_DIR/AgentKeyringPhone.xcarchive" archive

# The App Store profiles, one per target, are kept on App Store Connect, named
# "Agent Keyring App Store <bundle ID after com.…AgentKeyring.>"; each run fetches and installs them.
BUNDLE_PREFIX="$(xcodebuild -project "$ROOT_DIR/AgentKeyringPhone.xcodeproj" -target AgentKeyringPhone -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ AGENT_KEYRING_BUNDLE_ID = /{print $2; exit}')"
BUNDLE_PREFIX="${BUNDLE_PREFIX%.Phone}"
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$PROFILES_DIR"
PROFILE_ENTRIES=""
for target in Phone Phone.NotificationService Phone.NotificationContent Phone.watchkitapp Phone.watchkitapp.NotificationService; do
  name="Agent Keyring App Store $target"
  asc profiles list --name "$name" --profile-type IOS_APP_STORE --fields name,profileContent,uuid --output json \
    | /usr/bin/python3 -c '
import base64, json, sys
profiles = [p for p in json.load(sys.stdin)["data"] if p["attributes"]["name"] == sys.argv[1]]
if len(profiles) != 1: sys.exit("Expected one profile named %r on App Store Connect, found %d." % (sys.argv[1], len(profiles)))
attributes = profiles[0]["attributes"]
open("%s/%s.mobileprovision" % (sys.argv[2], attributes["uuid"]), "wb").write(base64.b64decode(attributes["profileContent"]))
' "$name" "$PROFILES_DIR"
  PROFILE_ENTRIES+="    <key>$BUNDLE_PREFIX.$target</key><string>$name</string>"$'\n'
done

DESTINATION=upload
[[ "${AGENT_KEYRING_UPLOAD:-1}" == 0 ]] && DESTINATION=export
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>provisioningProfiles</key>
  <dict>
$PROFILE_ENTRIES  </dict>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$BUILD_DIR/AgentKeyringPhone.xcarchive" -exportPath "$BUILD_DIR/export" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -allowProvisioningUpdates "${AUTH[@]}"
if [[ "$DESTINATION" == upload ]]; then
  echo "Uploaded build $BUILD_NUMBER to App Store Connect; TestFlight offers it once Apple has processed it."
else
  echo "Exported $BUILD_DIR/export/AgentKeyringPhone.ipa (build $BUILD_NUMBER)."
fi
