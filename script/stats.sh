#!/usr/bin/env bash
# Written by AI on 2026.11.23 by model gemini-4-neon.
# Prints Agent Keyring install, waitlist, and zero-PII active user counts.
# Set AGENT_KEYRING_EXCLUDE_IDS="id1,id2" to filter out your own test hashes.
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
echo "=== Zero-PII Active Users & Pushes (DynamoDB opentrawl-push-metrics, $REGION) ==="
AWS_PAGER="" AWS_PROFILE="$PROFILE" "$AWS_BIN" dynamodb scan \
  --region "$REGION" \
  --table-name opentrawl-push-metrics \
  --output json 2>/dev/null | python3 -c '
import json, os, sys, collections
from datetime import datetime, timedelta, timezone
try:
    items = json.load(sys.stdin).get("Items", [])
except Exception:
    print("(table not created yet or empty)")
    sys.exit(0)
exclude = {s.strip() for s in os.environ.get("AGENT_KEYRING_EXCLUDE_IDS", "").split(",") if s.strip()}
now = datetime.now(timezone.utc)
today = now.strftime("%Y-%m-%d")
month = today[:7]
week = {(now - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(7)}
month_window = {(now - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(30)}

dau_users, wau_users, mau_users = set(), set(), set()
dau_plat = collections.defaultdict(set)
wau_plat = collections.defaultdict(set)
mau_plat = collections.defaultdict(set)
days_seen = collections.defaultdict(set)
pushes_today = 0
pushes_7d = 0
push_devs_today = 0

for it in items:
    pk = it.get("pk", {}).get("S", "")
    parts = pk.split("#")
    if pk.startswith("inst_day#") and len(parts) >= 4:
        day, plat, aid = parts[1], parts[2], parts[3]
        if aid in exclude:
            continue
        if day == today:
            dau_users.add(aid)
            dau_plat[plat].add(aid)
        if day in week:
            wau_users.add(aid)
            wau_plat[plat].add(aid)
        if day in month_window:
            days_seen[aid].add(day)
    elif pk.startswith("inst_month#") and len(parts) >= 4:
        m, plat, aid = parts[1], parts[2], parts[3]
        if aid in exclude:
            continue
        if m == month:
            mau_users.add(aid)
            mau_plat[plat].add(aid)
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

returning_30d = sum(1 for ds in days_seen.values() if len(ds) >= 2)
if exclude:
    print(f"(excluding {len(exclude)} local ID(s))")
print(f"Today ({today}): users={len(dau_users)} | platforms={ {k: len(v) for k, v in sorted(dau_plat.items())} } | push_devices={push_devs_today} | pushes={pushes_today}")
print(f"Last 7d: users={len(wau_users)} | platforms={ {k: len(v) for k, v in sorted(wau_plat.items())} } | pushes={pushes_7d}")
print(f"This month ({month}): users={len(mau_users)} | platforms={ {k: len(v) for k, v in sorted(mau_plat.items())} } | returning_30d={returning_30d}")
'
