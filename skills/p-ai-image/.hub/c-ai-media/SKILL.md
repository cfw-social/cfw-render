---
name: c-ai-media
description: AI image and video generation for the creative studio. Use for generating AI images (kie.ai GPT-4o image, z-image, Imagen 4), cinematic video scenes (kie.ai Seedance/Kling/WAN), and talking-head animation (kie.ai InfiniTalk).
when_to_use: Trigger on AI image, generate image, create photo, photo post, GPT-4o image, z-image, cinematic scene, Seedance video, Kling video, WAN video, InfiniTalk, talking head animation, character scene, AI b-roll generation.
allowed-tools: Bash
kind: component
visibility: internal
providers: kie
dependsOn: [c-kie-ai]
requires: python3
---


# AI Media Generation

> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing ANY step in this skill, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as if it were a non-negotiable rule.
> 3. Only then proceed with the skill's normal instructions.
> 4. After completing the task, ask the user: "How did this go? Any corrections or improvements for next time?"
> 5. Summarize the feedback into 1–3 bullet points and append to `LEARNINGS.md` with today's date.
> 6. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section so it applies on every future run.

## ⚠️ CRITICAL — Return contract

**You MUST output exactly one line at the end of your response in this format:**

```
IMAGE_URL: <https url>
```

If image generation fails for ANY reason (API error, timeout, no URL returned), you MUST output:

```
IMAGE_FAILED: <reason>
```

Never exit silently with no output. The caller reads the last line to determine success or failure.

---

## Mandatory Pre-Generation Check

**Before generating ANY image for a brand:**
1. Check `brands/{brand-slug}/brand-ref.md` if available — use style guide / prompt template
2. Use brand's prompt template as BASE prompt if found
3. Output → `brolls/images/` (NOT interim/)

---

## Image Generation — kie.ai (Primary Provider)

Use direct HTTP calls to the kie.ai API. **Do NOT use `mcp__mcp-image__generate_image` or any Nanobanana MCP** — those MCPs are not available in the production container.

**Auth:** `KIE_AI_API_KEY` is already in the environment.

### Step 1 — Create the task

```bash
PROMPT="your image prompt here"
MODEL="z-image"          # default: fast, cheap, reliable text-to-image
ASPECT="1:1"             # "1:1" | "16:9" | "9:16"

RESULT=$(curl -s --max-time 30 -X POST "https://api.kie.ai/api/v1/jobs/createTask" \
  -H "Authorization: Bearer $KIE_AI_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"$MODEL\", \"input\": {\"prompt\": \"$PROMPT\", \"aspect_ratio\": \"$ASPECT\"}}")

TASK_ID=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['taskId'])" 2>/dev/null)
echo "Task ID: $TASK_ID"
```

Check for errors before polling:
```bash
# Abort if no task ID
if [ -z "$TASK_ID" ]; then
  echo "IMAGE_FAILED: createTask returned no taskId — response: $RESULT"
  exit 1
fi

# Check for credit error (code 402)
CODE=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('code',''))" 2>/dev/null)
if [ "$CODE" = "402" ]; then
  echo "IMAGE_FAILED: insufficient kie.ai credits"
  exit 1
fi
```

### Step 2 — Poll until complete (max 2.5 minutes)

```bash
MAX_POLLS=30    # 30 × 5s = 150s max
INTERVAL=5      # seconds between polls
IMAGE_URL=""

for i in $(seq 1 $MAX_POLLS); do
  sleep $INTERVAL
  RESP=$(curl -s --max-time 15 "https://api.kie.ai/api/v1/jobs/recordInfo?taskId=$TASK_ID" \
    -H "Authorization: Bearer $KIE_AI_API_KEY")
  STATE=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('state','unknown'))" 2>/dev/null)

  echo "Poll $i/$MAX_POLLS — state: $STATE"

  case "$STATE" in
    success|completed|done)
      IMAGE_URL=$(echo "$RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
rj = d.get('data', {}).get('resultJson', '')
if rj:
    urls = json.loads(rj).get('resultUrls', [])
    print(urls[0] if urls else '')
" 2>/dev/null)
      break
      ;;
    fail|failed|error)
      ERR=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('error','unknown error'))" 2>/dev/null)
      echo "IMAGE_FAILED: kie.ai task failed — $ERR"
      exit 1
      ;;
  esac
done

# Check if we got a URL
if [ -z "$IMAGE_URL" ]; then
  if [ "$STATE" = "success" ] || [ "$STATE" = "completed" ] || [ "$STATE" = "done" ]; then
    echo "IMAGE_FAILED: task completed but resultUrls was empty — response: $RESP"
  else
    echo "IMAGE_FAILED: polling timed out after ${MAX_POLLS} attempts (last state: $STATE)"
  fi
  exit 1
fi

echo "Got image URL: $IMAGE_URL"
```

### Step 3 — Upload to R2 and return the URL

```bash
# Download the image
TS=$(date +%s)
TMP_FILE="/tmp/ai-image-${TS}.png"
curl -fsSL --max-time 60 -o "$TMP_FILE" "$IMAGE_URL"

if [ ! -f "$TMP_FILE" ] || [ ! -s "$TMP_FILE" ]; then
  echo "IMAGE_FAILED: could not download image from $IMAGE_URL"
  exit 1
fi

# Upload to R2
R2_URL=$(r2-upload "$TMP_FILE" "$BRAND_ID/brolls/images/ai-${TS}.png" "image/png")

if [ -z "$R2_URL" ]; then
  echo "IMAGE_FAILED: r2-upload returned empty URL"
  exit 1
fi

# ✅ SUCCESS — output the final URL (REQUIRED — last line of output)
echo "IMAGE_URL: $R2_URL"
```

---

## Model Reference (kie.ai text-to-image)

| Model key | Quality | Speed | Credits | Best for |
|-----------|---------|-------|---------|----------|
| `z-image` | Good | ~15-30s | ~0.8 | Default — reliable, fast |
| `google/imagen4-fast` | High | ~20-40s | ~1.5 | Brand photos, product shots |
| `seedream/4.5-text-to-image` | High | ~30-50s | ~1.5 | Artistic, cinematic |
| `gpt-image/1.5-text-to-image` | Excellent | ~60-120s | ~2.5 | Complex scenes, photorealism |

**Default to `z-image` unless the user requests high quality or has a specific model preference.**

### Image-to-image (editing an existing image)

For i2i, the image URL MUST be a base64 data URI — kie.ai cannot fetch external URLs:

```bash
IMG_B64=$(python3 -c "import base64; print('data:image/png;base64,' + base64.b64encode(open('$IMG_PATH','rb').read()).decode())")

RESULT=$(curl -s -X POST "https://api.kie.ai/api/v1/jobs/createTask" \
  -H "Authorization: Bearer $KIE_AI_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"gpt-image/1.5-image-to-image\", \"input\": {\"prompt\": \"$PROMPT\", \"input_urls\": [\"$IMG_B64\"], \"aspect_ratio\": \"$ASPECT\"}}")
```

---

## Video Generation — kie.ai (use `c-kie-ai` skill for full video pipelines)

For quick video generation, use the standard createTask pattern with:
- Hailuo i2v: `hailuo/02-image-to-video-pro` — `prompt` + `image_url` (base64)
- Seedance: `bytedance/seedance-1.5-pro` — `prompt` + `image_url` + `aspect_ratio`
- Kling: `kling/v2-5-turbo-image-to-video-pro` — `prompt` + `image_url` + `duration` + `aspect_ratio`

**Note:** Video generation takes 3-5+ minutes. Use `enqueue_production` (off-turn) for video, NOT inline `run_skill`.

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
