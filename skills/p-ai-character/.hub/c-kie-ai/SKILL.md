---
name: c-kie-ai
description: "⚠ DEPRECATED (2026-07-03) for kie.ai work — superseded by kie-studio (~/Code/video-hub/kie-studio): use the kie-studio MCP server (mcp__kie-studio__* tools) or its skills (kie-image / kie-motion / kie-product / kie-ugc-ad / kie-cinematic-broll). kie-studio adds wire-contract validation (no silent field drops), live schema drift checks, and the human-approved video gate — raw curl calls here have NONE of those rails. This skill remains ONLY for fal.ai flows (FLUX via fal, fal queue) and for kie.ai models kie-studio has no contract for yet (add the contract instead when possible)."
when_to_use: fal.ai, FAL_KEY, FLUX via fal, fal queue. For kie.ai / KIE_AI_API_KEY / Seedance / Veo / GPT Image / nano-banana etc. use kie-studio instead (MCP mcp__kie-studio__* or its skills).
allowed-tools: Bash
kind: component
visibility: internal
providers: fal, kie
deprecated: kie.ai flows superseded by kie-studio 2026-07-03
---


# AI Media Generation — kie.ai + fal.ai

> **⚠ DEPRECATED for kie.ai (2026-07-03).** kie-studio is the successor for ALL
> kie.ai generation: MCP server `kie-studio` (tools `kie_lookbook_search`,
> `kie_compose`, `kie_plan_create/approve`, `kie_generate`, …) or the kie-* skills.
> It enforces the rails raw curl cannot: per-model wire contracts ("no contract,
> no spend"), live drift checks against kie.ai, and the video approval gate.
> Use THIS skill only for **fal.ai** — or, exceptionally, a kie.ai model that has
> no kie-studio contract yet (prefer adding the contract to
> `~/Code/video-hub/kie-studio/data/model-contracts.yaml` over calling raw).


> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing ANY step in this skill, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as if it were a non-negotiable rule.
> 3. Only then proceed with the skill's normal instructions.
> 4. After completing the task, ask the user: "How did this go? Any corrections or improvements for next time?"
> 5. Summarize the feedback into 1–3 bullet points and append to `LEARNINGS.md` with today's date.
> 6. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section so it applies on every future run.

> **🚦 SPEND-SAFETY RULES (2026-07-03 — apply to EVERY paid call, both providers):**
> 1. **Prefer kie-studio when it covers the model** (`~/Code/video-hub/kie-studio`,
>    `node bin/kie-studio.mjs`): it validates every input against per-model wire
>    contracts (`data/model-contracts.yaml` — wrong key = hard error, because Kie
>    SILENTLY IGNORES unknown input keys) and gates video behind user approval.
> 2. **Raw API calls: never trust field names from memory.** The reference-image key
>    differs per model (`input_urls` vs `image_urls` vs `image_url` vs `image_input`).
>    Check `models.jsonl` / the contract for the EXACT key — the wrong one silently
>    degrades i2i/i2v to pure text generation (this cost 50+ renders on 2026-07-03).
>    After createTask, verify `recordInfo.param` echoes your reference URLs.
> 3. **VIDEO = GATED, no exceptions.** Before ANY video createTask (Seedance, Veo,
>    Sora, Kling, Hailuo, WAN…): show the user the exact start-frame image(s) and the
>    estimated credit cost, and get an explicit yes ("approve" / "approve all").
>    Never spend video credits on an unconfirmed start frame — a wrong frame burned
>    600 credits once. Images (~6 credits) don't need the gate; video always does.

Two providers, one skill. Use kie.ai as primary (largest model catalog). Use fal.ai for FLUX image gen and queue-based video when needed.

## Step 0 — Always run first (model cache auto-sync)

```bash
bash ${SKILLS_DIR:-$HOME/.claude/skills}/c-kie-ai/sync-models.sh
```

Refreshes `models.jsonl` if > 4 days old. Query available models:

```bash
# List all active models
tail -n +2 ${SKILLS_DIR:-$HOME/.claude/skills}/c-kie-ai/models.jsonl | python3 -c "
import sys,json
for line in sys.stdin:
    m=json.loads(line)
    if not m.get('deprecated'):
        print(f\"{m['key']:<45} {m['api_model']}\")
"

# Filter by operation (e.g. image-to-video)
tail -n +2 ${SKILLS_DIR:-$HOME/.claude/skills}/c-kie-ai/models.jsonl | python3 -c "
import sys,json
for line in sys.stdin:
    m=json.loads(line)
    if 'image-to-video' in m['operation'] and not m.get('deprecated'):
        print(m['api_model'])
"
```

---

## Provider A: kie.ai (Primary)

**Base:** `https://api.kie.ai/api/v1`
**Auth:** `Authorization: Bearer $KIE_AI_API_KEY`
**Key source:** `~/.gsai/secrets.env` → `KIE_AI_API_KEY`

```bash
source ~/.gsai/secrets.env
```

⚠️ **kie.ai cannot fetch external URLs.** All `image_url` fields must be base64 data URIs:
```bash
IMAGE_B64=$(python3 -c "import base64; print('data:image/png;base64,' + base64.b64encode(open('$IMG','rb').read()).decode())")
```

### Create Task (standard endpoint)

```bash
RESULT=$(curl -s -X POST "https://api.kie.ai/api/v1/jobs/createTask" \
  -H "Authorization: Bearer $KIE_AI_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"$MODEL\", \"input\": $INPUT_JSON}")
TASK_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['taskId'])")
```

### Poll Status

```bash
while true; do
  RESP=$(curl -s "https://api.kie.ai/api/v1/jobs/recordInfo?taskId=$TASK_ID" \
    -H "Authorization: Bearer $KIE_AI_API_KEY")
  STATE=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['state'])")
  case "$STATE" in
    success|completed|done) break ;;
    fail|failed|error) echo "FAILED: $STATE" && exit 1 ;;
  esac
  sleep 5
done
VIDEO_URL=$(echo "$RESP" | python3 -c "
import sys,json
d=json.load(sys.stdin)['data']
import json as j2
print(j2.loads(d['resultJson'])['resultUrls'][0])
")
```

### Model Reference (kie.ai)

| Key | `model` value | Use for | Required input fields |
|-----|--------------|---------|----------------------|
| Hailuo t2v | `hailuo/02-text-to-video-pro` | MiniMax text→video | `prompt` |
| Hailuo i2v | `hailuo/02-image-to-video-pro` | MiniMax image→video | `prompt`, `image_url` (base64) |
| Sora-2 t2v | `sora-2-text-to-video` | Sora 2 text→video | `prompt`, `aspect_ratio`, `n_frames` |
| Sora-2 i2v | `sora-2-image-to-video` | Sora 2 image→video | `prompt`, `image_urls` (array, base64), `aspect_ratio` |
| Kling i2v | `kling/v2-5-turbo-image-to-video-pro` | Kling 2.5 i2v | `prompt`, `image_url`, `duration`, `aspect_ratio` |
| Kling avatar | `kling/ai-avatar-v1-pro` | Kling AI avatar | `prompt`, `image_url` |
| WAN t2v | `wan/2-6-text-to-video` | WAN 2.6 | `prompt`, `aspect_ratio` |
| WAN i2v | `wan/2-6-image-to-video` | WAN 2.6 i2v | `prompt`, `image_url`, `aspect_ratio` |
| Seedance | `bytedance/seedance-1.5-pro` | Seedance 1.5 | `prompt`, `image_url`, `aspect_ratio` |
| GPT Image | `gpt-image/1.5-text-to-image` | GPT image gen | `prompt`, `aspect_ratio` |
| GPT Image i2i | `gpt-image/1.5-image-to-image` | GPT image edit | `prompt`, `input_urls` (array, base64) |
| Imagen 4 | `google/imagen4` | Imagen 4 | `prompt`, `aspect_ratio` |
| Imagen 4 fast | `google/imagen4-fast` | Imagen 4 fast | `prompt`, `aspect_ratio`, `num_images` |
| Z-Image | `z-image` | Z-Image gen | `prompt`, `aspect_ratio` |
| Grok i2v | `grok-imagine/image-to-video` | Grok i2v | `prompt`, `image_url` |
| InfiniTalk | `infinitalk/from-audio` | Talking head from audio | `image_url`, `audio_url` |
| Seedream 4.5 | `seedream/4.5-text-to-image` | Seedream image | `prompt`, `aspect_ratio` |
| MiniMax music | `music-01` | Text→music | `prompt` |

### Hailuo i2v — Full Example (labubu-shorts pipeline)

```bash
IMG_B64=$(python3 -c "import base64; print('data:image/png;base64,' + base64.b64encode(open('$PNG','rb').read()).decode())")

RESULT=$(curl -s -X POST "https://api.kie.ai/api/v1/jobs/createTask" \
  -H "Authorization: Bearer $KIE_AI_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"hailuo/02-image-to-video-pro\", \"input\": {\"prompt\": \"$PROMPT\", \"image_url\": \"$IMG_B64\"}}")

TASK_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['taskId'])")
echo "Task: $TASK_ID"
```

### Sora-2 aspect_ratio mapping

| UI aspect | Sora-2 value |
|-----------|-------------|
| 16:9 | `landscape` |
| 9:16 | `portrait` |

### n_frames (Sora-2 duration)

| Duration | n_frames |
|----------|---------|
| ~5s | `"10"` |
| ~10s | `"15"` |

---

## Provider B: fal.ai (FLUX + Async Queue)

**Use when:** you need FLUX image gen, or prefer queue-based async for video.
**Base:** `https://fal.run` (sync image) / `https://queue.fal.run` (async video)
**Auth:** `Authorization: Key $FAL_KEY`
**Key source:** `~/.gsai/secrets.env` → `FAL_KEY`

```bash
source ~/.gsai/secrets.env
```

### Image Generation (synchronous)

```bash
curl -s -X POST "https://fal.run/c-fal-ai/flux/dev" \
  -H "Authorization: Key $FAL_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "your prompt here",
    "image_size": "landscape_16_9",
    "num_images": 1,
    "output_format": "png"
  }' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['images'][0]['url'])"
```

**Aspect ratio enum** (`image_size`): `square_hd` | `landscape_16_9` | `portrait_16_9` | `landscape_4_3` | `portrait_4_3`

**Image models:** `c-fal-ai/flux/dev` (quality) · `c-fal-ai/flux/schnell` (fast)

### Video Generation (async queue)

**Pattern: submit → poll status_url → fetch response_url**

#### Step 1 — Submit

```bash
RESULT=$(curl -s -X POST "https://queue.fal.run/$MODEL" \
  -H "Authorization: Key $FAL_KEY" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")
STATUS_URL=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['status_url'])")
RESPONSE_URL=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['response_url'])")
```

#### Step 2 — Poll (every 5s until COMPLETED)

```bash
while true; do
  STATUS=$(curl -s "$STATUS_URL" -H "Authorization: Key $FAL_KEY" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))")
  [ "$STATUS" = "COMPLETED" ] && break
  [ "$STATUS" = "FAILED" ] && echo "FAILED" && exit 1
  sleep 5
done
```

#### Step 3 — Get output URL

```bash
VIDEO_URL=$(curl -s "$RESPONSE_URL" -H "Authorization: Key $FAL_KEY" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print((d.get('video') or d.get('videos',[{}])[0]).get('url',''))")
```

### fal.ai Model Reference

| Key | fal endpoint | Use for |
|-----|-------------|---------|
| Image | `c-fal-ai/flux/dev` | Quality image gen |
| Image | `c-fal-ai/flux/schnell` | Fast image gen |
| Video t2v | `c-fal-ai/kling-video/v3/pro/text-to-video` | Kling 3 |
| Video i2v | `c-fal-ai/kling-video/v3/pro/image-to-video` | Kling 3 i2v |
| Video t2v | `c-fal-ai/veo3` | Veo 3 |
| Video t2v | `c-fal-ai/veo3.1` | Veo 3.1 |
| Video i2v | `c-fal-ai/veo3.1/image-to-video` | Veo 3.1 i2v |
| Video t2v | `bytedance/seedance-2.0/text-to-video` | Seedance 2 |
| Video i2v | `bytedance/seedance-2.0/image-to-video` | Seedance 2 i2v |
| Video t2v | `c-fal-ai/wan/v2.2-a14b/text-to-video` | WAN 2.2 |
| Video i2v | `c-fal-ai/wan/v2.2-a14b/image-to-video` | WAN 2.2 i2v |
| Video t2v | `c-fal-ai/minimax/video-01-live` | MiniMax (Hailuo) |

### Common Payload Fields (video)

```json
{
  "prompt": "...",
  "image_url": "https://... or data:image/png;base64,...",
  "aspect_ratio": "16:9",
  "duration": 5,
  "resolution": "720p"
}
```

Seedance duration range: 4–15s. Veo/Kling duration: 5 or 10s.

---

## Veo 3 (kie.ai — different endpoint)

Veo 3 uses `/veo/generate` and `/veo/record-info`:

```bash
# Create
curl -s -X POST "https://api.kie.ai/api/v1/veo/generate" \
  -H "Authorization: Bearer $KIE_AI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"veo3_fast","prompt":"...","generationType":"TEXT_2_VIDEO","aspectRatio":"16:9"}'

# Poll
curl -s "https://api.kie.ai/api/v1/veo/record-info?taskId=$TASK_ID" \
  -H "Authorization: Bearer $KIE_AI_API_KEY"
# successFlag: 0=generating, 1=success, 2/3=failed
# output: data.response.resultUrls[0]
```

---

## Gotchas

**kie.ai:**
- `image_url` must be base64 data URI — kie.ai **cannot** fetch external URLs
- `sora-2-*` model names use hyphens, NOT slashes (unlike other models)
- Polling state: `success`/`completed`/`done` → done; `fail`/`failed`/`error` → failed
- Error code `402` = insufficient credits; `401` = bad API key
- Full model registry: see `models.jsonl` in this skill directory
- DISCONTINUED: `google/nano-banana-pro` returns 422 since 2026-02-20

**fal.ai:**
- `status_url` and `response_url` use `queue.fal.run` domain — same `Authorization: Key` header required
- Seedance 2.0 duration must be passed as a **string** (`"5"` not `5`)
- MiniMax Live model only accepts `prompt` + optional `image_url` — no `aspect_ratio`/`duration` overrides
- Full model registry: see `models.jsonl` in this skill directory

---

## Zoom Presets

| Asset type | Zoom |
|-----------|------|
| AI whiteboard | `1.1x` |
| AI cinematic/photo | `1.15x` |
| App/screen/mobile | `none` |
| Static graphics | `1.15x` |
| Motion graphics | `none` |

## Output Paths

- AI images: `{brand_path}/creatives/brolls/images/{id}-{desc}.png`
- AI clips: `{brand_path}/creatives/brolls/ai/{id}-{desc}.mp4`

## Self-Improvement Feedback Loop

After completing this skill's task:
1. Ask the user: "How did this go? Any corrections or improvements for next time?"
2. Summarize feedback into 1–3 concise bullet points.
3. Append to `LEARNINGS.md` in this folder with the date.
4. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section at the top of `LEARNINGS.md`.
5. Mark critical feedback with `[ACTIVE]` prefix so it is visually distinct.

