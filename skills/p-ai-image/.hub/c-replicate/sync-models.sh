#!/bin/bash
# Sync Replicate model list from live API
# Called automatically by SKILL.md — refreshes if cache is > 4 days old

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
MODELS_FILE="$SKILL_DIR/models.jsonl"

# Load API key
source ~/.gsai/secrets.env 2>/dev/null || true

if [ -z "${REPLICATE_API_TOKEN:-}" ]; then
  echo "[replicate] REPLICATE_API_TOKEN not set — skipping model sync. Add key to ~/.gsai/secrets.env" >&2
  exit 0
fi

# Check freshness — skip if < 4 days old
if [ -f "$MODELS_FILE" ]; then
  AGE=$(python3 -c "
import json, datetime
with open('$MODELS_FILE') as f:
    header = json.loads(f.readline())
synced = header.get('synced_at', '')
if synced:
    delta = (datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(synced)).days
    print(delta)
else:
    print(999)
" 2>/dev/null || echo "999")
  if [ "$AGE" -lt 4 ]; then
    exit 0
  fi
fi

echo "[replicate] Syncing model list from API (first 3 pages)..." >&2

# Fetch up to 3 pages using curl, parse with python
python3 - "$REPLICATE_API_TOKEN" "$MODELS_FILE" <<'PYEOF'
import json, sys, subprocess, datetime

token    = sys.argv[1]
out_file = sys.argv[2]
base_url = "https://api.replicate.com/v1/models"
max_pages = 3

models = []
url = base_url
page = 0

while url and page < max_pages:
    result = subprocess.run(
        ["curl", "-sf", url,
         "-H", f"Authorization: Token {token}",
         "-H", "User-Agent: gsai-skills/1.0"],
        capture_output=True, text=True, timeout=20
    )
    if result.returncode != 0:
        print(f"[replicate] curl failed on page {page+1}: {result.stderr}", file=sys.stderr)
        sys.exit(1)

    data = json.loads(result.stdout)
    for m in data.get("results", []):
        latest = m.get("latest_version") or {}
        models.append({
            "key":            f"{m.get('owner','?')}/{m.get('name','?')}",
            "owner":          m.get("owner"),
            "name":           m.get("name"),
            "description":    (m.get("description") or "")[:120],
            "visibility":     m.get("visibility"),
            "url":            m.get("url"),
            "latest_version": latest.get("id"),
        })

    url = data.get("next")
    page += 1

with open(out_file, 'w') as f:
    f.write(json.dumps({
        "synced_at":    datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "count":        len(models),
        "source":       "replicate-api",
        "pages_fetched": page,
        "note":         "First 3 pages (~300 models). Use replicate.com/explore for full search.",
    }) + '\n')
    for m in models:
        f.write(json.dumps(m) + '\n')

print(f"[replicate] Synced {len(models)} models → models.jsonl")
PYEOF
