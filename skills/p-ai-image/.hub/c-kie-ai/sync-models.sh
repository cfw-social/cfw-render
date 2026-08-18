#!/bin/bash
# Sync kie.ai model list from Floe registry
# Called automatically by SKILL.md — refreshes if cache is > 4 days old

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
MODELS_FILE="$SKILL_DIR/models.jsonl"
FLOE_REGISTRY="/Users/vasanth/Code/video-apps/floe/src/integrations/ai/kie-ai/models/index.ts"

# Check freshness — skip if < 4 days old
if [ -f "$MODELS_FILE" ]; then
  AGE=$(python3 -c "
import json, datetime
with open('$MODELS_FILE') as f:
    header = json.loads(f.readline())
synced = header.get('synced_at', '')
if synced:
    delta = (datetime.datetime.utcnow() - datetime.datetime.fromisoformat(synced)).days
    print(delta)
else:
    print(999)
" 2>/dev/null || echo "999")
  if [ "$AGE" -lt 4 ]; then
    exit 0
  fi
fi

echo "[kie-ai] Syncing model list from Floe registry..." >&2

python3 - <<'PYEOF'
import json, re, datetime, sys

registry_path = "/Users/vasanth/Code/video-apps/floe/src/integrations/ai/kie-ai/models/index.ts"
try:
    with open(registry_path) as f:
        content = f.read()
except FileNotFoundError:
    print(f"ERROR: Floe registry not found at {registry_path}", file=sys.stderr)
    sys.exit(1)

# Match: 'provider:operation': { apiModel: '...', endpoint: '...' }
pattern = r"'([^']+)':\s*\{([^}]+)\}"
models = []
for match in re.finditer(pattern, content, re.DOTALL):
    key, body = match.groups()
    if ':' not in key:
        continue
    provider, operation = key.split(':', 1)

    api_model_m  = re.search(r"apiModel:\s*'([^']+)'", body)
    endpoint_m   = re.search(r"endpoint:\s*'([^']+)'", body)
    api_op_m     = re.search(r"apiOperation:\s*'([^']+)'", body)
    deprecated_m = re.search(r"DISCONTINUED", body)
    if not api_model_m:
        continue

    models.append({
        "key":           key,
        "provider":      provider,
        "operation":     operation,
        "api_model":     api_model_m.group(1),
        "endpoint":      endpoint_m.group(1) if endpoint_m else "standard",
        "api_operation": api_op_m.group(1) if api_op_m else None,
        "deprecated":    bool(deprecated_m),
    })

out_file = "/Users/vasanth/Code/skills/kie-ai/models.jsonl"
with open(out_file, 'w') as f:
    f.write(json.dumps({
        "synced_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "count":     len(models),
        "source":    "floe-registry",
        "registry":  registry_path,
    }) + '\n')
    for m in models:
        f.write(json.dumps(m) + '\n')

print(f"[kie-ai] Synced {len(models)} models → models.jsonl")
PYEOF
