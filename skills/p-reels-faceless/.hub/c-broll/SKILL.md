---
name: c-broll
description: B-roll system — library management, script matching, placement planning, alignment verification, website-scroll capture (Playwright), clip extraction from video, R2 upload, and embedding b-roll into CFW content variants. The single building block for everything b-roll.
when_to_use: Trigger on b-roll, c-broll, b-roll library, clip match, placement plan, c-broll plan, SRT alignment, c-broll archive, c-broll preview, c-broll log, c-broll timecards, script to clips, b-roll coverage, c-broll library update, c-broll image rationale, web capture, website scroll, Playwright capture, website b-roll, scroll recording, URL discovery, extract clip from video, b-roll upload, R2 upload broll, embed b-roll, CFW variant b-roll.
allowed-tools: Bash, Read, Write, Edit
kind: component
visibility: internal
dependsOn: [c-ffmpeg, c-cloud-media]
requires: ffmpeg, node, chromium
---


# B-Roll — Library, Capture, Placement & Embed System

> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing ANY step in this skill, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as if it were a non-negotiable rule.
> 3. Only then proceed with the skill's normal instructions.
> 4. After completing the task, ask the user: "How did this go? Any corrections or improvements for next time?"
> 5. Summarize the feedback into 1–3 bullet points and append to `LEARNINGS.md` with today's date.
> 6. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section so it applies on every future run.

This skill is the complete b-roll toolkit. It covers everything from sourcing clips (capture / extract) through organising them (library management), matching and placing them against a script, verifying alignment, uploading to R2, and embedding b-roll markers into a CFW content variant.

## Caller Variables

| Variable | Required | Source | Description |
|----------|----------|--------|-------------|
| `{brand_local_path}` | Yes | Caller / ecosystem.yaml | Absolute path to brand folder |
| `{production}` | Yes | Caller | Absolute path to production folder |
| `$SRT_FILE` | Conditional | Caller | Transcription SRT for placement planning |
| `$LAYOUT` | Conditional | Caller | `portrait` or `landscape` |

---

## Library management

All reusable b-roll lives at `{brand_local_path}/creatives/brolls/`:

```
brolls/
├── ai-broll-library.md       # AI clips + Ken Burns (id prefix: aimg, ai)
├── app-broll-library.md      # App screen recordings (id prefix: app, disc, lnkd)
├── recordings-broll-library.md  # Screen/mobile/website (id prefix: wbst, scrn, mobi)
├── gfx-broll-library.md      # Graphics + overlays (id prefix: gfx, bnr)
├── ai/                       # AI-generated video clips
├── app/                      # App screen recordings
├── recordings/               # Screen, mobile, website clips
├── gfx/                      # Graphics, banners, overlays
└── images/                   # Source images (PNG/JPG) — input for AI clips
```

**Always check brolls/ before generating new assets.** After delivery, archive reusable clips into brolls/.

### Library Table Schema (DB-ready)

`ID | File | Dur | Zoom | Description | Use When... | Cloud | Status | Source`

App/recordings libraries also include `POI` (points of interest) column.

| Status | Meaning |
|--------|---------|
| `Pending` | Clip exists locally, not uploaded |
| `Created` | Created this session, ready to use |
| `Uploaded` | In R2 CDN, has Cloud URL |
| `Deleted` | Removed, skip |

### Zoom Presets

| Asset type | Zoom |
|-----------|------|
| AI whiteboard | `1.1x` |
| AI cinematic/photo | `1.15x` |
| App / screen / mobile recordings | `none` |
| Static graphics | `1.15x` |
| Motion graphics | `none` |

### use_case Parameter

- `local` — accept `Created` + `Uploaded` status, use local file path
- `cfw` — accept `Uploaded` only, use Cloud CDN URL

### Archiving from production

After delivery, archive reusable clips into brolls/ (MANDATORY on every delivery):

```bash
# Archive AI clips
cp {production}/interim/broll/gfx/*.mp4 {brand_path}/creatives/brolls/gfx/
cp {production}/interim/broll/gfx/*.png {brand_path}/creatives/brolls/gfx/
# Update gfx-broll-library.md with new entries — Status: Pending (not yet uploaded to R2)
```

### Upload pending clips to R2

Batch-upload all `Status == Created` clips to Cloudflare R2 and update the library rows.

→ Skill: `c-cloud-media` → R2 upload per clip. Upload priority: `ai/` → `gfx/` → `recordings/` → `app/`.
After each successful upload set `Cloud`: CDN URL and `Status`: `Created` → `Uploaded`.
Optionally register each CDN URL as a brand asset in CFW (if CFW MCP available).
Supports a dry-run mode: read library, filter `Status == Created`, print the pending list and stop.

---

## Capture (website scroll)

Playwright-based smooth-scroll capture of a web page into a b-roll clip.

### Presets

| Flag | Resolution | Target Duration | Use For |
|------|------------|-----------------|---------|
| `--short-form` | 1080×1080 (square) | 6.0s hard cap | PIP inside 9:16 Shorts/Reels/TikTok |
| `--long-form` | 1920×1080 (landscape) | 12.0s hard cap | YouTube long-form, VSL, landscape overlays |

Both presets: default 1.2x playback speed, auto-compute scroll speed so the full page fits the window, trim 2s of leading load frames, hard-cap final MP4 via ffmpeg `-t`. Override any preset value by also passing the underlying flag (e.g. `--short-form --target-duration 8`).

### Capture script: `_scripts/capture-website-broll.mjs`

```bash
# Short-form (square, 6s)
node _scripts/capture-website-broll.mjs \
  --url "https://example.com" \
  --output "$PROD/interim/broll/segments/wbst01-homepage.mp4" \
  --short-form

# Long-form (landscape, 12s)
node _scripts/capture-website-broll.mjs \
  --url "https://example.com" \
  --output "$PROD/interim/broll/segments/wbst01-homepage.mp4" \
  --long-form

# Custom duration override
node _scripts/capture-website-broll.mjs \
  --url "https://example.com/pricing" \
  --output "$PROD/interim/broll/segments/wbst02-pricing.mp4" \
  --short-form --target-duration 8
```

### URL discovery

When capture targets are unknown, discover pages first:

```bash
node _scripts/discover-broll-urls.mjs \
  --topic "brand homepage features pricing" \
  --domain "https://example.com" \
  --output "$PROD/interim/broll-plan/pages.json"
```

`pages.json` format:
```json
[
  {"url": "https://example.com", "label": "homepage", "priority": 1},
  {"url": "https://example.com/pricing", "label": "pricing", "priority": 2}
]
```

### Auth handling

For pages behind login, save auth state first, then reuse it:

```bash
# Interactive auth save (run once)
node _scripts/capture-playwright-auth-save.mjs \
  --url "https://app.example.com/login" \
  --storage-state "$HOME/.playwright/example-auth.json"

# Use saved auth for capture
node _scripts/capture-website-broll.mjs \
  --url "https://app.example.com/dashboard" \
  --storage-state "$HOME/.playwright/example-auth.json" \
  --short-form \
  --output "$PROD/interim/broll/segments/app01-dashboard.mp4"
```

### Visual quality check

```bash
# Check duration and resolution
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,duration \
  -of default=noprint_wrappers=1 "$OUTPUT"

# Preview first frame
ffmpeg -i "$OUTPUT" -vframes 1 -y /tmp/preview.jpg && open /tmp/preview.jpg
```

Reject and recapture if: black frames at start (page didn't load), scroll movement not visible (speed too fast), or content cut off at bottom (scroll didn't reach end).

Capture output paths:
- Short-form: `{production}/interim/broll/segments/sq-wbst{NN}-{desc}.mp4`
- Long-form: `{production}/interim/broll/segments/ls-wbst{NN}-{desc}.mp4`
- After delivery, archive to `{brand_path}/creatives/brolls/recordings/{id}-{desc}.mp4` and update `recordings-broll-library.md`.

---

## Match & place

Match available clips to script scenes using:
1. **`[B-ROLL: keyword]` markers** in script — exact match attempt first
2. **Category prefix** — `app`, `wbst`, `aimg`, `gfx` match to scene context
3. **Description keyword match** — fuzzy match against "Use When..." column
4. **Fallback** — log as unmatched, flag for generation

### Coverage targets
- VSL (landscape): 70% coverage default
- Shorts (portrait): 80% minimum coverage
- AI image allocation: 20% of b-roll slots

### Placement plan rules

**SRT-First Workflow (MANDATORY):**
1. Transcribe audio with MLX Whisper — get SRT file
2. Use SRT timecodes as ground truth (NEVER use script section estimates)
3. Every plan row must have a "Speaker Says" column with exact SRT text
4. Run alignment verification after every plan

**Portrait plan (9:16 Shorts):** output `{production}/interim/broll-plan/placement-plan-short-{NN}.md`. 6-column table: `Seg | Timecode | Duration | Layout | Asset | Speaker Says`. Layout options: `bottom-avatar`, `split-equal`, `split-broll`, `pip-broll`, `popout`. Coverage ≥ 80%. Speed-factor-adjusted timestamps when atempo applied.

**Landscape plan (16:9 VSL):** output `{production}/interim/broll-plan/placement-plan.md`. Coverage ≥ 70%. PIP overlay with full-screen b-roll transitions.

### Segment gap rules
- **Segment shorter than window** → let avatar show naturally (not a bug)
- **FULLSCREEN runs out** → switch to AVATAR FULL (not loop/freeze)
- **Static GFX** → freeze is natural for text cards
- **NEVER loop video** to fill gaps — prefer avatar transitions
- **Gap-free windows** → extend each segment's enable time to the START of the next segment

### B-roll plan guards (MANDATORY)
- Min 4 unique assets per short
- No PIP segment > 6s
- Create 3-5 unique GFX cards per short from script content
- Screen recordings are supplementary, not primary
- Side-by-side image GFX must have symmetrical placement with sufficient padding

### Alignment verification

Cross-check every b-roll segment's timecode against the SRT transcript.

| Level | Definition | Action |
|-------|-----------|--------|
| OK | Timecode matches speech within ±0.5s | None |
| WARNING | Offset 0.5–2.0s or minor content mismatch | Flag, log |
| SEVERE | >2s offset or major content mismatch | Auto-fix timecodes from SRT |

**auto_fix=true (default):** When SEVERE issues found, rewrite plan with corrected timecodes + "Speaker Says" column. Backup original as `{plan}-backup.md`. Output: `{production}/interim/broll-plan/alignment-audit.md`.

---

## Extract clips from video

Pull a frame-accurate clip out of an existing source video and register it in the library.

**Required:** `source`, `start`, `end`, `name`, `description`. Optional: `use_when` (matching keywords), `category` (`ai`|`app`|`recordings`|`gfx`, default `recordings`), `zoom` (default `none`).

```bash
# 1 — Extract (c-ffmpeg, frame-accurate trim)
ffmpeg -i "$SOURCE" -ss $START -to $END \
  -c:v libx264 -c:a aac -y "$BRAND_BROLLS/{category}/{name}.mp4"
```
2. **Verify** → ffprobe → confirm duration = (end − start) ± 0.1s, codec, dimensions.
3. **Update library** → add a row to `{category}-broll-library.md` with `Status: Created`, `File: {category}/{name}.mp4`.
4. **Report** → clip path, duration, library row added.

---

## Embed into a content variant

Embed b-roll into a CFW content variant: fetch the variant, rewrite the script to target duration, match clips from the library, log missing assets, and update the variant in CFW.

**Args:** one of `content_id` (fetches default variant) or `variant_id` (used directly). `rewrite` = `auto` (rewrite if needed) or `show-first` (show script before rewriting).

1. **Fetch content** → CFW API → fetch the content variant; extract script text, brand, target duration. If no target duration set, calculate from word count (2.5 wps).
2. **Duration check ⛔ CHECKPOINT (if `rewrite: show-first`)** → show script + estimated duration. Gate: user decides whether to rewrite or proceed.
3. **Script rewrite (if needed)** → Skill: `c-script` → rewrite to duration (target 40–60s), preserving hook, CTA, core message. Gate: user approves rewritten script.
4. **Match b-roll** → read brand library (all 4 libraries), match clips to script segments by "Use When..." keywords, format matches inline:
   ```
   ...script text here [[5,s,https://cdn.example.com/brolls/ai/aimg01.mp4]] more text...
   ```
5. **Log missing** → for segments with no matching clip, log segment text + suggested clip type to `missing-broll.md`.
6. **Present plan ⛔ CHECKPOINT** → show script with markers, coverage (X of Y segments), missing segments. Gate: user approves placement.
7. **Update CFW variant** → CFW API → update variant script with embedded b-roll markers; confirm success.
8. **Report** → total segments, covered (X%), missing → `missing-broll.md`.

---

## Output Paths

- Placement plans: `{production}/interim/broll-plan/placement-plan*.md`
- Alignment audit: `{production}/interim/broll-plan/alignment-audit.md`
- B-roll clips: `{production}/interim/broll/segments/{id}-{desc}.mp4`
- GFX clips: `{production}/interim/broll/gfx/{id}-{desc}.mp4`
- Archived to library: `{brand_path}/creatives/brolls/{type}/{id}-{desc}.mp4`

## Self-Improvement Feedback Loop

After completing this skill's task:
1. Ask the user: "How did this go? Any corrections or improvements for next time?"
2. Summarize feedback into 1–3 concise bullet points.
3. Append to `LEARNINGS.md` in this folder with the date.
4. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section at the top of `LEARNINGS.md`.
5. Mark critical feedback with `[ACTIVE]` prefix so it is visually distinct.
