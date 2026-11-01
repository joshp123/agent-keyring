#!/usr/bin/env bash
set -euo pipefail

HELPERS_DIR="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
SKILL_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/AgentTools/AgentSkill"
CLI_BINARY="$SRCROOT/build/cli/macos/agent-keyring"

if [[ ! -x "$CLI_BINARY" ]]; then
  echo 'Build the Go CLI first: devenv shell -- ./script/build_cli.sh' >&2
  exit 1
fi
/bin/mkdir -p "$HELPERS_DIR" "$SKILL_DIR"
/usr/bin/ditto "$CLI_BINARY" "$HELPERS_DIR/agent-keyring"
/bin/chmod 755 "$HELPERS_DIR/agent-keyring"
if [[ -e "$SKILL_DIR/agent-keyring" || -L "$SKILL_DIR/agent-keyring" ]]; then
  /usr/bin/trash "$SKILL_DIR/agent-keyring"
fi
/usr/bin/ditto "$SRCROOT/AgentSkill/agent-keyring" "$SKILL_DIR/agent-keyring"
EXTENSION_DIR="$(dirname "$SKILL_DIR")/BrowserExtension"
if [[ -e "$EXTENSION_DIR" ]]; then
  /usr/bin/trash "$EXTENSION_DIR"
fi
/usr/bin/ditto "$SRCROOT/BrowserExtension" "$EXTENSION_DIR"
# 0.2.5 and earlier linked ~/.codex/skills/agent-keyring to CodexSkill; keep
# that path so the link still resolves after an update replaces the app.
LEGACY_SKILL_DIR="$(dirname "$SKILL_DIR")/CodexSkill"
/bin/mkdir -p "$LEGACY_SKILL_DIR"
if [[ -e "$LEGACY_SKILL_DIR/agent-keyring" || -L "$LEGACY_SKILL_DIR/agent-keyring" ]]; then
  /usr/bin/trash "$LEGACY_SKILL_DIR/agent-keyring"
fi
/bin/ln -s ../AgentSkill/agent-keyring "$LEGACY_SKILL_DIR/agent-keyring"

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --timestamp=none "$HELPERS_DIR/agent-keyring"
fi
