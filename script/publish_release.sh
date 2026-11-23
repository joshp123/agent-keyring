#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 VERSION" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/Release-$VERSION"
ZIP_PATH="$BUILD_DIR/out/Agent-Keyring-$VERSION.zip"
SOURCE_COMMIT_FILE="$BUILD_DIR/source-commit.txt"
REPO="opentrawl/agent-keyring"

/bin/test -f "$ZIP_PATH"
/bin/test -f "$SOURCE_COMMIT_FILE"

source_commit="$(<"$SOURCE_COMMIT_FILE")"
if [[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" != "$source_commit" ]]; then
  echo "HEAD no longer matches the commit used to build this release." >&2
  exit 1
fi

if [[ -n "$(git -C "$ROOT_DIR" status --short)" ]]; then
  echo "Commit and push the source changes before publishing the release." >&2
  exit 1
fi

release_notes="$BUILD_DIR/release-notes.md"
/usr/bin/tail -n +5 "$ROOT_DIR/Distribution/ReleaseNotes.md" > "$release_notes"

gh release create "v$VERSION" \
  "$ZIP_PATH" \
  --repo "$REPO" \
  --target "$source_commit" \
  --title "Agent Keyring $VERSION" \
  --notes-file "$release_notes"

release_json="$(gh release view "v$VERSION" --repo "$REPO" --json targetCommitish,assets)"
/usr/bin/jq -e --arg commit "$source_commit" --arg name "$(/usr/bin/basename "$ZIP_PATH")" \
  '.targetCommitish == $commit and any(.assets[]; .name == $name and (.state | ascii_downcase) == "uploaded")' \
  <<<"$release_json" >/dev/null

echo "Published https://github.com/$REPO/releases/tag/v$VERSION"
