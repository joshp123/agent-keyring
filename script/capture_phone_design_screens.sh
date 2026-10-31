#!/usr/bin/env bash
# Written by AI on 2026.10.31 by model Claude Opus 5.5.
#
# Builds the iPhone app for the simulator, opens it in every design scenario
# and saves a screenshot of each to docs/design/screens/phone/. The simulator
# runs headless; Simulator.app never opens.
#
# usage: script/capture_phone_design_screens.sh [scenario ...]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="${TMPDIR:-/tmp}/agent-keyring-phone-design"
OUT="$ROOT_DIR/docs/design/screens/phone"
BUNDLE_ID="com.joshpalmer.AgentKeyring.Phone"
DEVICE_NAME="${AGENT_KEYRING_SIMULATOR:-Agent Keyring iPhone}"

SIM="$(xcrun simctl list devices available | sed -n "s/^ *$DEVICE_NAME (\([0-9A-F-]*\)).*/\1/p" | head -1)"
if [[ -z "$SIM" ]]; then
  echo "No simulator named \"$DEVICE_NAME\". Create one or set AGENT_KEYRING_SIMULATOR." >&2
  exit 1
fi

SCENARIOS=("$@")
if [[ ${#SCENARIOS[@]} -eq 0 ]]; then
  SCENARIOS=(request requestForProgram requestForAgentProcess reply sending waitingForMac approved denied unanswered
    pairing pairingConnecting pairingComparing pairingPaired pairingFailed homeNotPaired settingsNotPaired
    home nothingWaiting notificationsOn inUseDetail historyDetail unreachable settings real)
fi

xcodebuild -project "$ROOT_DIR/AgentKeyringPhone.xcodeproj" -scheme AgentKeyringPhone \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES -quiet build

xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null
xcrun simctl install "$SIM" "$DERIVED/Build/Products/Debug-iphonesimulator/AgentKeyringPhone.app"
xcrun simctl status_bar "$SIM" override --time "$(date +%H:%M)" --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3

mkdir -p "$OUT"
for appearance in light dark; do
  xcrun simctl ui "$SIM" appearance "$appearance"
  for scenario in "${SCENARIOS[@]}"; do
    xcrun simctl terminate "$SIM" "$BUNDLE_ID" 2>/dev/null || true
    if [[ "$scenario" == real ]]; then
      # The app as installed: the real phone backend, nothing paired.
      xcrun simctl launch "$SIM" "$BUNDLE_ID" >/dev/null
    else
      xcrun simctl launch "$SIM" "$BUNDLE_ID" -designScenario "$scenario" >/dev/null
    fi
    sleep 2.5
    xcrun simctl io "$SIM" screenshot "$OUT/$scenario-$appearance.png" >/dev/null 2>&1
    echo "$OUT/$scenario-$appearance.png"
  done
done
xcrun simctl ui "$SIM" appearance light
