#!/usr/bin/env bash
set -euo pipefail

PACKAGE_PATH="$SRCROOT/AgentKeyringPackage"
SCRATCH_PATH="$DERIVED_FILE_DIR/AgentKeyringCLI"
HELPERS_DIR="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
SKILL_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/AgentTools/AgentSkill"

case "$CONFIGURATION" in
  Release)
    swift_configuration="release"
    architectures=(--arch arm64 --arch x86_64)
    ;;
  *)
    swift_configuration="debug"
    build_architecture="${CURRENT_ARCH:-}"
    if [[ -z "$build_architecture" || "$build_architecture" == "undefined_arch" ]]; then
      build_architecture="${NATIVE_ARCH_ACTUAL:-arm64}"
    fi
    architectures=(--arch "$build_architecture")
    ;;
esac

build_arguments=(
  --package-path "$PACKAGE_PATH"
  --configuration "$swift_configuration"
  --product agent-keyring
  --scratch-path "$SCRATCH_PATH"
  "${architectures[@]}"
)

/usr/bin/xcrun swift build "${build_arguments[@]}"
binary_directory="$(/usr/bin/xcrun swift build "${build_arguments[@]}" --show-bin-path)"

/bin/mkdir -p "$HELPERS_DIR" "$SKILL_DIR"
/usr/bin/ditto "$binary_directory/agent-keyring" "$HELPERS_DIR/agent-keyring"
/bin/chmod 755 "$HELPERS_DIR/agent-keyring"
if [[ -e "$SKILL_DIR/agent-keyring" || -L "$SKILL_DIR/agent-keyring" ]]; then
  /usr/bin/trash "$SKILL_DIR/agent-keyring"
fi
/usr/bin/ditto "$SRCROOT/AgentSkill/agent-keyring" "$SKILL_DIR/agent-keyring"

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign \
    --force \
    --options runtime \
    --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --timestamp=none \
    "$HELPERS_DIR/agent-keyring"
fi
