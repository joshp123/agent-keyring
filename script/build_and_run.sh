#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="AgentKeyring"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
BUILD_APP="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
BUILD_EXTENSION="$BUILD_APP/Contents/PlugIns/AgentKeyringCredentialProvider.appex"
INSTALL_APP="${AGENT_KEYRING_INSTALL_PATH:-/Applications/$APP_NAME.app}"
CLI_SCRATCH="$ROOT_DIR/.build/CLI"
CLI_BINARY="$CLI_SCRATCH/release/agent-keyring"
CLI_INSTALL="${AGENT_KEYRING_CLI_PATH:-$HOME/.local/bin/agent-keyring}"
SKILL_SOURCE="$ROOT_DIR/CodexSkill/agent-keyring"
SKILL_INSTALL="${CODEX_HOME:-$HOME/.codex}/skills/agent-keyring"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ ! -f "$ROOT_DIR/Config/Local.xcconfig" ]]; then
  echo "Copy Config/Local.xcconfig.example to Config/Local.xcconfig and add your Apple Developer team." >&2
  exit 1
fi

/usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true

/usr/bin/xcodebuild \
  -quiet \
  -workspace "$ROOT_DIR/AgentKeyring.xcworkspace" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  build

/usr/bin/codesign --verify --deep --strict "$BUILD_APP"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILD_APP/Contents/Info.plist")"
/bin/test -f "$BUILD_APP/Contents/embedded.provisionprofile"
/bin/test -f "$BUILD_EXTENSION/Contents/embedded.provisionprofile"
/usr/bin/xcrun swift build \
  --package-path "$ROOT_DIR/AgentKeyringPackage" \
  --configuration release \
  --product agent-keyring \
  --scratch-path "$CLI_SCRATCH"
/bin/rm -rf "$INSTALL_APP"
/usr/bin/ditto "$BUILD_APP" "$INSTALL_APP"
/usr/bin/install -d -m 700 "$(dirname "$CLI_INSTALL")"
/usr/bin/install -m 755 "$CLI_BINARY" "$CLI_INSTALL"
/bin/rm -rf "$SKILL_INSTALL"
/usr/bin/ditto "$SKILL_SOURCE" "$SKILL_INSTALL"
"$LSREGISTER" -u "$BUILD_APP" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$INSTALL_APP"

open_app() {
  /usr/bin/open "$INSTALL_APP"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$INSTALL_APP/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    /bin/sleep 1
    /usr/bin/pgrep -x "$APP_NAME" >/dev/null
    "$CLI_INSTALL" help >/dev/null
    echo "$APP_NAME is running from $INSTALL_APP"
    echo "agent-keyring is installed at $CLI_INSTALL"
    echo "The Agent Keyring Codex skill is installed at $SKILL_INSTALL"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
