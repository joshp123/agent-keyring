#!/usr/bin/env bash
# The one version and build number for everything built from this commit: the
# Mac app, the iPhone and Apple Watch app, and the command. The version is the
# VERSION file. The build number is the commit's time in UTC, so every product
# of one commit carries the same pair. Prints "VERSION BUILD".
# AGENT_KEYRING_BUILD_NUMBER overrides the build number, for a second TestFlight
# upload of a commit (Apple refuses a pair it already has).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
BUILD="${AGENT_KEYRING_BUILD_NUMBER:-$(TZ=UTC /usr/bin/git -C "$ROOT_DIR" show -s --format=%cd --date=format-local:%Y%m%d%H%M HEAD)}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$BUILD" =~ ^[0-9]+$ ]]; then
  echo "VERSION must be like 1.2.3 and the build number a positive integer." >&2
  exit 1
fi
echo "$VERSION $BUILD"
