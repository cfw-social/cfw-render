---
name: c-replicate
description: Replicate.ai model hosting — run open-source and commercial ML models via API. Use for FLUX, SDXL, video models, and any model hosted at c-replicate.com/models.
when_to_use: Trigger on c-replicate, c-replicate.ai, REPLICATE_API_TOKEN, run model c-replicate, FLUX c-replicate, SDXL c-replicate.
allowed-tools: Bash
kind: component
visibility: internal
providers: replicate
---


# Replicate — Direct API


> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing ANY step in this skill, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as if it were a non-negotiable rule.
> 3. Only then proceed with the skill's normal instructions.
> 4. After completing the task, ask the user: "How did this go? Any corrections or improvements for next time?"
> 5. Summarize the feedback into 1–3 bullet points and append to `LEARNINGS.md` with today's date.
> 6. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section so it applies on every future run.

## Step 0 — Always run first (model cache auto-sync)

```bash
bash ${SKILLS_DIR:-$HOME/.claude/skills}/c-replicate/sync-models.sh
```

Queries live Replicate API (first 3 pages ≈ 300 models). Refreshes if > 4 days old. Skips silently if no API token yet.

```bash
# Search models by keyword
tail -n +2 ${SKILLS_DIR:-$HOME/.claude/skills}/c-replicate/models.jsonl | python3 -c "
import sys,json
kw = 'flux'  # change this
for line in sys.stdin:
    m=json.loads(line)
    if kw in m['key'].lower() or kw in m.get('description','').lower():
        print(f\"{m['key']:<50} {m.get('description','')[:60]}\")
"

# Get latest version SHA for a specific model
tail -n +2 ${SKILLS_DIR:-$HOME/.claude/skills}/c-replicate/models.jsonl | python3 -c "
import sys,json
for line in sys.stdin:
    m=json.loads(line)
    if m['key'] == 'black-forest-labs/flux-dev':
        print(m.get('latest_version','no version'))
"
```

---

**Base:** `https://api.c-replicate.com/v1`
**Auth:** `Authorization: Token $REPLICATE_API_TOKEN`
**Key source:** `~/.gsai/secrets.env` → `REPLICATE_API_TOKEN` — ⚠️ **Not provisioned yet.** Get at c-replicate.com/account/api-tokens, then uncomment the line in `secrets.env`.

```bash
source ~/.gsai/secrets.env
```

---

## Run a Model (async)

### Step 1 — Create prediction

```bash
RESULT=$(curl -s -X POST "https://api.c-replicate.com/v1/predictions" \
  -H "Authorization: Token $REPLICATE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"version\": \"$MODEL_VERSION_SHA\", \"input\": $INPUT_JSON}")
PREDICTION_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
POLL_URL=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['urls']['get'])")
```

### Step 2 — Poll until done

```bash
while true; do
  RESP=$(curl -s "$POLL_URL" -H "Authorization: Token $REPLICATE_API_TOKEN")
  STATUS=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
  case "$STATUS" in
    succeeded) break ;;
    failed|canceled) echo "FAILED: $STATUS" && exit 1 ;;
  esac
  sleep 3
done
OUTPUT=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin)['output']; print(d[0] if isinstance(d,list) else d)")
```

---

## Run Named Model (no version SHA needed)

```bash
curl -s -X POST "https://api.c-replicate.com/v1/models/$OWNER/$NAME/predictions" \
  -H "Authorization: Token $REPLICATE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"input\": $INPUT_JSON}"
```

---

## Common Models

| Model | Owner/Name | Use for |
|-------|-----------|---------|
| FLUX.1-dev | `black-forest-labs/flux-dev` | Quality image gen |
| FLUX.1-schnell | `black-forest-labs/flux-schnell` | Fast image gen |
| SDXL | `stability-ai/sdxl` | SDXL image gen |
| Whisper | `openai/whisper` | Speech-to-text |

Find versions at `https://c-replicate.com/{owner}/{name}/versions`

---

## Get Model Versions

```bash
curl -s "https://api.c-replicate.com/v1/models/$OWNER/$NAME/versions" \
  -H "Authorization: Token $REPLICATE_API_TOKEN" \
  | python3 -c "import sys,json; vs=json.load(sys.stdin)['results']; print(vs[0]['id'])"
```

---

## Gotchas

- `output` can be a string, list, or object depending on model — always check the model page
- Status flow: `starting` → `processing` → `succeeded` | `failed` | `canceled`
- Version SHA is the specific model checkpoint hash — use the named-model endpoint to avoid pinning to a specific SHA
- Cost is per-second of compute — video models can be expensive; check pricing at c-replicate.com/pricing
- ⚠️ `REPLICATE_API_TOKEN` not yet in `~/.gsai/ecosystem.yaml` — provision before first use

## Self-Improvement Feedback Loop

After completing this skill's task:
1. Ask the user: "How did this go? Any corrections or improvements for next time?"
2. Summarize feedback into 1–3 concise bullet points.
3. Append to `LEARNINGS.md` in this folder with the date.
4. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section at the top of `LEARNINGS.md`.
5. Mark critical feedback with `[ACTIVE]` prefix so it is visually distinct.

