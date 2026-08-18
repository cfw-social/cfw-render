---
name: c-heygen
description: HeyGen avatar video rendering for the creative studio. Use for avatar green-screen renders, submitting via MCP or API, browser-based UI rendering, delegating to human via Discord, polling render status, downloading completed MP4s, and verifying green-screen quality.
when_to_use: Trigger on HeyGen, avatar render, green screen render, talking head, avatar video, HeyGen API, HeyGen MCP, poll render, download avatar, verify green screen, avatar MP4.
allowed-tools: Bash
kind: component
visibility: internal
providers: heygen
requires: python3
---


# HeyGen — Avatar Render System


> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing ANY step in this skill, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as if it were a non-negotiable rule.
> 3. Only then proceed with the skill's normal instructions.
> 4. After completing the task, ask the user: "How did this go? Any corrections or improvements for next time?"
> 5. Summarize the feedback into 1–3 bullet points and append to `LEARNINGS.md` with today's date.
> 6. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section so it applies on every future run.

## Caller Variables

| Variable | Required | Source | Description |
|----------|----------|--------|-------------|
| `$AVATAR_ID` | Yes | Caller / brand config | HeyGen avatar ID |
| `$VOICE_ID` | Yes | Caller / brand config | HeyGen voice ID |
| `$SCRIPT` | Yes | Caller | TTS-clean script text |
| `{production}` | Yes | Caller | Absolute path to production folder |
| `$HEYGEN_API_KEY` | Yes | `~/.gsai/secrets.env` | HeyGen API key |
| `$FLOE_API_KEY` | Conditional | `~/.gsai/secrets.env` | Required for Floe poll/download path |

## Render Path Priority

| Path | When | Cost |
|------|------|------|
| 1. MCP Tool (**DEFAULT**) | Agent-driveable from a Paperclip subprocess; no interactive session, no manual paste. Proven end-to-end on VAS-564 (7 Week-1 videos, 2026-05-30). | api / plan_credit |
| 2. REST API | When the MCP tier is unavailable and direct REST is preferred | api_credits |
| 3. Browser UI | Fallback when MCP/API degrade (credit-pool exhaustion). **INTERACTIVE session only** — claude-in-chrome binds one Chrome profile to one interactive session; a subprocess runs only `--dry-run`/`--plan` and hands the live submit to an interactive session. | none (drives the live HeyGen UI) |
| 4. Human (Discord) | Last resort when neither MCP nor an interactive browser session is available | none |

**Tier order: MCP → API → Browser → Human. MCP is the default** as of 2026-05-30 (VAS-564
direction change). On `MOVIO_PAYMENT_INSUFFICIENT_CREDIT` from MCP/API → fall through to the
next tier. Never retry on a credit error.

## Green Screen Standard (Non-Negotiable)

**Always use `#00FF00` (0x00FF00).** Never sample from video. Never trust b-roll plan color values.

Two-pass colorkey: `colorkey=0x00FF00:0.25:0.05,colorkey=0x00FF00:0.40:0.01`

`chromakey` filter NOT available — always use `colorkey`.

## Path 1: Human Delegation (Discord)

Full script as ONE request (hook through CTA). TTS-clean only.

Channel routing (`~/.gsai/openclaw-routing.json`): VAS→`#personal`, CFW→`#cfw`, GRO→`#gsai`

## Path 2: HeyGen MCP

Use `mcp__heygen__generate_avatar_video`. Only send segment-specific text per render.

Credit pool: OAuth MCP → `premium_credits`, Stdio MCP + API key → `api_credits`. Check before submitting — pool mismatch is #1 failure mode.

## Path 3: Browser UI

See **[references/browser-render.md](references/browser-render.md)** for Chrome automation steps.

Critical order: avatar/look/motion/background FIRST → script LAST (Script Writer AI rewrites typed text — always use `ClipboardEvent('paste')`).

## Path 4: REST API

```bash
curl -s -X POST "https://api.heygen.com/v2/video/generate" \
  -H "X-Api-Key: $HEYGEN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "video_inputs": [{"character": {"type": "avatar", "avatar_id": "$AVATAR_ID"},
      "voice": {"type": "text", "input_text": "$SCRIPT", "voice_id": "$VOICE_ID"},
      "background": {"type": "color", "value": "#00FF00"}}],
    "dimension": {"width": 1280, "height": 720}}'
```
Auth: `X-Api-Key` header (NOT Bearer).

## Polling via Floe API

Poll every 60s. Short clips: 3–5 min. Long VSLs (6 min+): 15–20 min.

```bash
RESULT=$(curl -s -X POST "https://floe-production.up.railway.app/api/v1/id-to-c-heygen-url" \
  -H "Content-Type: application/json" -H "X-API-Key: $FLOE_API_KEY" \
  -d "{\"execution_id\": \"poll-$(date +%s)\", \"input_fields\": {\"video_id\": \"$VIDEO_ID\"}}")
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))")
```
Check `status: "success"` at top level (NOT `"completed"`). Unique `execution_id` per poll.

## Output Paths

- Green-screen: `{production}/interim/video/base/{name}-green-screen.mp4`
- On background: `{production}/interim/video/base/{name}-avatar-on-bg.mp4`
- Pre-render with `-g 25` (keyframe/1s) for seek accuracy

## References

- **[references/browser-render.md](references/browser-render.md)** — Chrome automation, script paste method, gotchas.

## Self-Improvement Feedback Loop

After completing this skill's task:
1. Ask the user: "How did this go? Any corrections or improvements for next time?"
2. Summarize feedback into 1–3 concise bullet points.
3. Append to `LEARNINGS.md` in this folder with the date.
4. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section at the top of `LEARNINGS.md`.
5. Mark critical feedback with `[ACTIVE]` prefix so it is visually distinct.

