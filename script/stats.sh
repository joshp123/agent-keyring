#!/usr/bin/env bash
# Written by AI on 2026.11.23 by model gemini-4-neon.
# Prints Agent Keyring install, waitlist, and zero-PII active usage counts.
set -euo pipefail

REPO="opentrawl/agent-keyring"
REGION="eu-west-1"
PROFILE="${AWS_PROFILE:-homelab-admin}"
AWS_BIN="$(command -v aws 2>/dev/null || ls -1 /nix/store/*-awscli2-*/bin/aws 2>/dev/null | head -n 1 || true)"

echo "=== GitHub Releases ($REPO) ==="
GH_PAGER=cat gh api "repos/$REPO/releases" --jq '
  .[] | "\(.tag_name) (\(.published_at[:10])): " +
  ([.assets[] | "\(.name)=\(.download_count)"] | join(", "))
'

if [[ -z "$AWS_BIN" ]]; then
  echo "aws CLI not found; skipping DynamoDB metrics." >&2
  exit 0
fi

echo ""
echo "=== Beta Waitlist (DynamoDB agent-keyring-waitlist, $REGION) ==="
AWS_PAGER="" AWS_PROFILE="$PROFILE" "$AWS_BIN" dynamodb scan \
  --region "$REGION" \
  --table-name agent-keyring-waitlist \
  --select COUNT \
  --query 'Count' --output text 2>/dev/null || echo "(unavailable)"

echo ""
echo "=== Zero-PII Active Installs & Pushes (DynamoDB opentrawl-push-metrics, $REGION) ==="
AWS_PAGER="" AWS_PROFILE="$PROFILE" "$AWS_BIN" dynamodb scan \
  --region "$REGION" \
  --table-name opentrawl-push-metrics \
  --output json 2>/dev/null | python3 -c '
import json, sys, collections
from datetime import datetime, timedelta, timezone
try:
    items = json.load(sys.stdin).get("Items", [])
except Exception:
    print("(table not created yet or empty)")
    sys.exit(0)
today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
month = today[:7]
week = {(datetime.now(timezone.utc) - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(7)}
dau = collections.Counter()
wau = collections.defaultdict(set)
mau = collections.Counter()
pushes_today = 0
pushes_7d = 0
push_devs_today = 0
for it in items:
    pk = it.get("pk", {}).get("S", "")
    parts = pk.split("#")
    if pk.startswith("inst_day#") and len(parts) >= 4:
        day, plat, aid = parts[1], parts[2], parts[3]
        if day == today:
            dau[plat] += 1
        if day in week:
            wau[plat].add(aid)
    elif pk.startswith("inst_month#") and len(parts) >= 4:
        m, plat = parts[1], parts[2]
        if m == month:
            mau[plat] += 1
    elif pk.startswith("pushes#") and len(parts) >= 3:
        day = parts[1]
        n = int(it.get("count", {}).get("N", "0"))
        if day == today:
            pushes_today += n
        if day in week:
            pushes_7d += n
    elif pk.startswith("push_dev#") and len(parts) >= 3:
        if parts[1] == today:
            push_devs_today += 1
print(f"Today ({today}): DAU={dict(dau)} | push_devices={push_devs_today} | pushes={pushes_today}")
print(f"Last 7d: WAU={ {k: len(v) for k, v in wau.items()} } | pushes={pushes_7d}")
print(f"This month ({month}): MAU={dict(mau)}")
'
