---
name: c-html-gfx
description: HTML graphics and screenshot generation for video overlays, banners, explainer slides, and Remotion-based motion graphics. Use when creating 1920x1080 GFX cards, YouTube/LinkedIn banners, animated explainer slides, or rendering React/TSX compositions with Remotion.
when_to_use: Trigger on HTML GFX, GFX card, overlay graphic, video graphic, banner, YouTube banner, LinkedIn banner, explainer slide, HTML screenshot, headless Chrome screenshot, Remotion render, React video.
allowed-tools: Bash
kind: component
visibility: internal
dependsOn: [f-remotion]
requires: ffmpeg, chromium
---


# HTML GFX — Graphics for Video


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
| `{production}` | Conditional | Caller | Production folder — for GFX cards going into b-roll |
| `{brand_path}` | Conditional | Caller / ecosystem.yaml | Brand folder — for standalone banners |
| `$GFX_TYPE` | Yes | Caller | One of the GFX type slugs below |
| `$GFX_DATA` | Yes | Caller | JSON or inline data for the GFX |
| `$OUTPUT_FILE` | Yes | Caller | Target PNG/MP4 path |

## GFX Types (1920x1080 Dark Studio Theme)

`pipeline-diagram` | `cost-table` | `prompt-template` | `scene-progression` | `comparison-table` | `linking-diagram` | `callout-card` | `hero-stat` | `terminal-sim` | `category-grid` | `custom`

### Color Palette
```css
--purple:#a78bfa; --green:#22c55e; --yellow:#fcd34d; --red:#f87171;
--blue:#60a5fa; --orange:#f59e0b; --bg:#0f172a; --surface:#1e293b;
--border:#334155; --text:#f1f5f9; --muted:#94a3b8;
```

## Mandatory Post-Render Check

After EVERY render:
1. Check Unicode: emojis/em-dashes/arrows break if charset missing
2. `<meta charset="UTF-8">` in every HTML head
3. Visually inspect PNG before video conversion
4. Prefer `&rarr;` `&mdash;` over raw Unicode

## Headless Chrome Screenshot

**CRITICAL:** `--window-size` sets outer window — Chrome reserves ~140px on macOS.

| Target | Window size |
|--------|-------------|
| 1920x1080 | `1920x1220` → crop |
| 1080x1080 | `1080x1220` → crop |

```bash
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --headless --screenshot="$PNG" --window-size=1920,1220 --hide-scrollbars --no-sandbox "file://$HTML"
ffmpeg -i "$PNG" -vf "crop=1920:1080:0:0" -y "$FINAL.png"
```

## Explainer Slides

Font: Poppins (Google Fonts CDN). One idea per slide. Animation: fade-in from below, 0.5s ease-out, staggered 0.2s/0.6s/1.0s/1.4s.

## Platform Banners

| Platform | Dimensions | Safe Zone |
|----------|-----------|-----------|
| YouTube | 2560x1440 | 1546x423 centered |
| LinkedIn | 1584x396 | Full |
| Facebook | 820x312 | Full |

## Image → Video Clip

```bash
ffmpeg -loop 1 -i "$PNG" \
  -vf "scale=1920:1080,zoompan=z='min(zoom+0.001,1.3)':d=375:s=1920x1080" \
  -t 15 -r 25 -c:v libx264 -pix_fmt yuv420p -y "$OUT.mp4"
```

## Remotion Rendering

**MANDATORY:** Use shared Chromium — NEVER download per-production (175MB):
```bash
export REMOTION_BROWSER_EXECUTABLE="${REMOTION_BROWSER_EXECUTABLE:-$(which chromium-browser 2>/dev/null || which chromium 2>/dev/null || which google-chrome 2>/dev/null)}"
npm ci --omit=optional
npx remotion render "$COMP_ID" "$OUT.mp4" --props='$JSON'
```

## Output Paths

- GFX PNGs: `{production}/interim/broll/gfx/{id}-{desc}.png`
- GFX clips: `{production}/interim/broll/gfx/{id}-{desc}.mp4`
- Banners: `{brand_path}/creatives/brolls/gfx/{id}-{desc}.png`

## Self-Improvement Feedback Loop

After completing this skill's task:
1. Ask the user: "How did this go? Any corrections or improvements for next time?"
2. Summarize feedback into 1–3 concise bullet points.
3. Append to `LEARNINGS.md` in this folder with the date.
4. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section at the top of `LEARNINGS.md`.
5. Mark critical feedback with `[ACTIVE]` prefix so it is visually distinct.

