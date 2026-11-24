#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 VERSION" >&2
  exit 2
fi

for variable in AGENT_KEYRING_APPCAST_BUCKET AGENT_KEYRING_CLOUDFRONT_DISTRIBUTION_ID AGENT_KEYRING_AWS_PROFILE; do
  if [[ -z "${!variable:-}" ]]; then
    echo "Set $variable before publishing (appcast S3 bucket, CloudFront distribution ID and AWS profile)." >&2
    exit 1
  fi
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/Release-$VERSION"
OUT_DIR="$BUILD_DIR/out"
ZIP_PATH="$OUT_DIR/Agent-Keyring-$VERSION.zip"
APPCAST_PATH="$OUT_DIR/appcast.xml"
SOURCE_COMMIT_FILE="$BUILD_DIR/source-commit.txt"
BUILD_NUMBER_FILE="$BUILD_DIR/build-number.txt"
BASE_APPCAST_SHA_FILE="$BUILD_DIR/live-appcast.sha256"
REPO="opentrawl/agent-keyring"
EXPECTED_URL="https://github.com/$REPO/releases/download/v$VERSION/Agent-Keyring-$VERSION.zip"
APPCAST_BUCKET="$AGENT_KEYRING_APPCAST_BUCKET"
APPCAST_KEY="appcast.xml"
APPCAST_URL="${AGENT_KEYRING_APPCAST_URL:-https://keyring.opentrawl.sh/appcast.xml}"
CLOUDFRONT_DISTRIBUTION_ID="$AGENT_KEYRING_CLOUDFRONT_DISTRIBUTION_ID"
AWS_PROFILE_NAME="$AGENT_KEYRING_AWS_PROFILE"

/bin/test -f "$ZIP_PATH"
/bin/test -f "$APPCAST_PATH"
/bin/test -f "$SOURCE_COMMIT_FILE"
/bin/test -f "$BUILD_NUMBER_FILE"
/bin/test -f "$BASE_APPCAST_SHA_FILE"

source_commit="$(<"$SOURCE_COMMIT_FILE")"
build_number="$(<"$BUILD_NUMBER_FILE")"
base_appcast_sha="$(<"$BASE_APPCAST_SHA_FILE")"
if [[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" != "$source_commit" ]]; then
  echo "HEAD no longer matches the commit used to build this release." >&2
  exit 1
fi

if [[ -n "$(git -C "$ROOT_DIR" status --short)" ]]; then
  echo "Commit and push the source changes before publishing the release." >&2
  exit 1
fi

git -C "$ROOT_DIR" fetch --quiet origin main
if [[ "$(git -C "$ROOT_DIR" rev-parse origin/main)" != "$source_commit" ]]; then
  echo "Release commit $source_commit does not match origin/main." >&2
  exit 1
fi

# Confirm the staged appcast matches this exact version, build number, URL and zip size.
/usr/bin/xmllint --noout "$APPCAST_PATH"
zip_size="$(/usr/bin/stat -f %z "$ZIP_PATH")"
local_zip_sha="$(/usr/bin/shasum -a 256 "$ZIP_PATH" | /usr/bin/awk '{print $1}')"
/usr/bin/python3 - "$APPCAST_PATH" "$VERSION" "$build_number" "$EXPECTED_URL" "$zip_size" <<'PY'
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
    sys.exit(f"staged appcast.xml missing sparkle:version={build_number}")
if (matched.findtext("sparkle:shortVersionString", namespaces=ns) or "").strip() != version:
    sys.exit("staged appcast.xml shortVersionString mismatch")
enc = matched.find("enclosure")
if enc is None or enc.attrib.get("url") != expected_url or enc.attrib.get("length") != expected_size:
    sys.exit("staged appcast.xml enclosure mismatch")
if not enc.attrib.get(sparkle_ns + "edSignature"):
    sys.exit("staged appcast.xml enclosure missing sparkle:edSignature")
PY

ASSETS=("$ZIP_PATH")
for bin in agent-keyring-linux-amd64 agent-keyring-linux-arm64 agent-keyring-darwin-universal; do
  src="$ROOT_DIR/build/cli/release/$bin"
  /bin/test -f "$src"
  cp "$src" "$OUT_DIR/$bin"
  ASSETS+=("$OUT_DIR/$bin")
done

SUMS_PATH="$OUT_DIR/SHA256SUMS.txt"
(cd "$OUT_DIR" && /usr/bin/shasum -a 256 "Agent-Keyring-$VERSION.zip" agent-keyring-linux-amd64 agent-keyring-linux-arm64 agent-keyring-darwin-universal > "$SUMS_PATH")
ASSETS+=("$SUMS_PATH")

release_notes="$BUILD_DIR/release-notes.md"
/usr/bin/awk '
  NR == 1 && $0 == "---" { in_frontmatter = 1; next }
  in_frontmatter && $0 == "---" { in_frontmatter = 0; stripped = 1; next }
  in_frontmatter { next }
  stripped && !started && $0 == "" { next }
  { started = 1; print }
' "$ROOT_DIR/Distribution/ReleaseNotes.md" > "$release_notes"

# Create the GitHub Release, or safely resume if it already exists for this exact commit and ZIP digest.
if existing_release="$(gh release view "v$VERSION" --repo "$REPO" --json targetCommitish,assets 2>/dev/null)"; then
  tag_commit="$(gh api "repos/$REPO/git/ref/tags/v$VERSION" --jq '.object.sha')"
  tag_type="$(gh api "repos/$REPO/git/ref/tags/v$VERSION" --jq '.object.type')"
  if [[ "$tag_type" == "tag" ]]; then
    tag_commit="$(gh api "repos/$REPO/git/tags/$tag_commit" --jq '.object.sha')"
  fi
  if [[ "$tag_commit" != "$source_commit" ]]; then
    echo "Existing tag v$VERSION points to $tag_commit, expected $source_commit." >&2
    exit 1
  fi
  remote_digest="$(/usr/bin/jq -r --arg name "$(/usr/bin/basename "$ZIP_PATH")" '.assets[] | select(.name == $name) | .digest // ""' <<<"$existing_release")"
  if [[ "$remote_digest" != "sha256:$local_zip_sha" ]]; then
    echo "Existing v$VERSION ZIP digest ($remote_digest) does not match local ZIP (sha256:$local_zip_sha)." >&2
    exit 1
  fi
  echo "Resuming publish for verified existing GitHub Release v$VERSION"
else
  gh release create "v$VERSION" \
    "${ASSETS[@]}" \
    --repo "$REPO" \
    --target "$source_commit" \
    --title "Agent Keyring $VERSION" \
    --notes-file "$release_notes"
fi

release_json="$(gh release view "v$VERSION" --repo "$REPO" --json targetCommitish,assets)"
/usr/bin/jq -e --arg name "$(/usr/bin/basename "$ZIP_PATH")" --arg digest "sha256:$local_zip_sha" \
  'any(.assets[]; .name == $name and (.state | ascii_downcase) == "uploaded" and .digest == $digest)' \
  <<<"$release_json" >/dev/null

# Verify the GitHub Release enclosure URL is live before updating appcast.xml.
live_zip_length="$(/usr/bin/curl -fsSI -L "$EXPECTED_URL" | /usr/bin/awk 'tolower($1) == "content-length:" { gsub(/\r/, "", $2); val = $2 } END { print val }')"
if [[ "$live_zip_length" != "$zip_size" ]]; then
  echo "Live GitHub release zip Content-Length ($live_zip_length) does not match local zip ($zip_size)." >&2
  exit 1
fi

run_aws() {
  if command -v aws >/dev/null 2>&1; then
    AWS_PROFILE="$AWS_PROFILE_NAME" aws "$@"
  else
    AWS_PROFILE="$AWS_PROFILE_NAME" nix shell 'github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df#awscli2' -c aws "$@"
  fi
}

# Read authoritative S3 object state and perform an ETag-conditional write so a
# delayed release can never overwrite or roll back a newer feed.
staged_appcast_sha="$(/usr/bin/shasum -a 256 "$APPCAST_PATH" | /usr/bin/awk '{print $1}')"
head_err="$BUILD_DIR/s3-head.err"
if head_json="$(run_aws s3api head-object --bucket "$APPCAST_BUCKET" --key "$APPCAST_KEY" 2>"$head_err")"; then
  existing_etag="$(/usr/bin/jq -r '.ETag' <<<"$head_json")"
  auth_s3_feed="$BUILD_DIR/authoritative-s3-appcast.xml"
  run_aws s3api get-object --bucket "$APPCAST_BUCKET" --key "$APPCAST_KEY" "$auth_s3_feed" >/dev/null
  auth_s3_sha="$(/usr/bin/shasum -a 256 "$auth_s3_feed" | /usr/bin/awk '{print $1}')"
  if [[ "$auth_s3_sha" == "$staged_appcast_sha" ]]; then
    echo "Authoritative S3 appcast already matches staged bytes; resuming CloudFront invalidation."
  else
    if [[ "$base_appcast_sha" == "BOOTSTRAP" ]]; then
      echo "Refusing bootstrap upload: s3://$APPCAST_BUCKET/$APPCAST_KEY already exists (ETag $existing_etag)." >&2
      exit 1
    fi
    if [[ "$auth_s3_sha" != "$base_appcast_sha" ]]; then
      echo "Authoritative S3 appcast changed since build ($auth_s3_sha != $base_appcast_sha). Rebuild against the current feed." >&2
      exit 1
    fi
    run_aws s3api put-object \
      --bucket "$APPCAST_BUCKET" \
      --key "$APPCAST_KEY" \
      --body "$APPCAST_PATH" \
      --content-type "application/xml; charset=utf-8" \
      --cache-control "public, max-age=300" \
      --if-match "$existing_etag" >/dev/null
  fi
elif /usr/bin/grep -Eq '(404|Not Found|NoSuchKey)' "$head_err"; then
  if [[ "$base_appcast_sha" != "BOOTSTRAP" ]]; then
    echo "Refusing publish: s3://$APPCAST_BUCKET/$APPCAST_KEY is missing, but build expected existing feed $base_appcast_sha." >&2
    exit 1
  fi
  run_aws s3api put-object \
    --bucket "$APPCAST_BUCKET" \
    --key "$APPCAST_KEY" \
    --body "$APPCAST_PATH" \
    --content-type "application/xml; charset=utf-8" \
    --cache-control "public, max-age=300" \
    --if-none-match '*' >/dev/null
else
  cat "$head_err" >&2
  exit 1
fi

invalidation_id="$(run_aws cloudfront create-invalidation \
  --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" \
  --paths "/$APPCAST_KEY" \
  --query 'Invalidation.Id' \
  --output text)"
run_aws cloudfront wait invalidation-completed \
  --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" \
  --id "$invalidation_id"

live_feed="$BUILD_DIR/published-appcast.xml"
/usr/bin/curl -fsS "$APPCAST_URL" -o "$live_feed"
/usr/bin/xmllint --noout "$live_feed"
if ! /usr/bin/cmp -s "$live_feed" "$APPCAST_PATH"; then
  echo "Live $APPCAST_URL bytes do not match staged $APPCAST_PATH." >&2
  exit 1
fi

echo "Published https://github.com/$REPO/releases/tag/v$VERSION"
echo "Published $APPCAST_URL"
