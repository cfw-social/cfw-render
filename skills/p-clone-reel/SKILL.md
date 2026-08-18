---
name: p-clone-reel
description: Clone-a-viral pipeline — adapt a winning viral video into your brand voice on your topic. Downloads a viral source video, transcribes it, adapts the script to brand voice, and delivers a 9:16 short in the viral format using an avatar PIP (HeyGen green-screen).
disable-model-invocation: true
argument-hint: "[brand] [production-name] [source-url]"
allowed-tools: Bash, Read, Write
kind: pipeline
visibility: catalog
providers: heygen, elevenlabs
produces:
  dish: Viral Reel Recreation
  format: 9:16 vertical video
  duration: 30-60s
inputs: [source_url]
dependsOn: [c-script, c-heygen, c-html-gfx, c-audio, c-production, c-ffmpeg, c-shorts-qa-gate, c-eval-runner]
metadata:
  hermes:
    vendored:
      - { name: c-audio, load: ".hub/c-audio/SKILL.md" }
      - { name: c-broll, load: ".hub/c-broll/SKILL.md" }
      - { name: c-cloud-media, load: ".hub/c-cloud-media/SKILL.md" }
      - { name: c-eval-runner, load: ".hub/c-eval-runner/SKILL.md" }
      - { name: c-ffmpeg, load: ".hub/c-ffmpeg/SKILL.md" }
      - { name: c-heygen, load: ".hub/c-heygen/SKILL.md" }
      - { name: c-html-gfx, load: ".hub/c-html-gfx/SKILL.md" }
      - { name: c-production, load: ".hub/c-production/SKILL.md" }
      - { name: c-script, load: ".hub/c-script/SKILL.md" }
      - { name: c-shorts-qa-gate, load: ".hub/c-shorts-qa-gate/SKILL.md" }
      - { name: f-remotion, load: ".hub/f-remotion/SKILL.md" }
    progressive: true
---


# p-clone-reel — Viral Reel Recreation


> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing ANY step in this skill, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as if it were a non-negotiable rule.
> 3. Only then proceed with the skill's normal instructions.
> 4. After completing the task, ask the user: "How did this go? Any corrections or improvements for next time?"
> 5. Summarize the feedback into 1–3 bullet points and append to `LEARNINGS.md` with today's date.
> 6. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section so it applies on every future run.

Take a viral format → adapt to brand → deliver 9:16 short (avatar PIP).

## Arguments

| Arg | Required | Default | Description |
|-----|----------|---------|-------------|
| brand | Yes | — | Brand slug |
| production_name | Yes | — | Folder name |
| source_url | Yes | — | YouTube/social URL of viral video |
| section | No | `middle` | `opening`, `middle`, or `full` — which section to adapt |
| cover_style | No | `card-holding` | `card-holding` or `faceless-card` |
| cta | No | — | Custom CTA for the end |

---

## Step 1 — Download + Transcribe

```bash
yt-dlp -f "bestvideo[height<=1080]+bestaudio/best" \
  --merge-output-format mp4 -o "source.mp4" "$SOURCE_URL"
```
→ LOAD: skill_view("p-clone-reel", ".hub/c-audio/SKILL.md") — MLX Whisper → `interim/audio/source.srt`

Identify viral format type: hook structure, pacing, visual rhythm.

---

## Step 2 — Script Adaptation ⛔ CHECKPOINT

→ LOAD: skill_view("p-clone-reel", ".hub/c-script/SKILL.md") — voice adaptation
→ Match word count ±10% to preserve timing (150 wpm baseline)
→ Apply brand vocabulary, CTA swap, phonetic readiness
→ Output: `interim/scripts/{name}-adapted.txt`

**Gate: User approves adapted script.**

---

## Step 3 — Footage Generation

→ LOAD: skill_view("p-clone-reel", ".hub/c-heygen/SKILL.md") — browser render or human delegation
→ Script: adapted `.txt`, background: `#00FF00` solid

→ LOAD: skill_view("p-clone-reel", ".hub/c-production/SKILL.md") — circle PIP detection
→ Identify PIP position in source video (size, center, overlay_diameter at 115%)

→ Cover frame: `c-html-gfx` → brand card at 1080×1920 (`$cover_style`)

---

## Step 4 — TTS Voiceover (if no HeyGen)

→ LOAD: skill_view("p-clone-reel", ".hub/c-audio/SKILL.md") — ElevenLabs TTS
→ `interim/audio/{name}-vo.mp3`

---

## Step 5 — Assembly

→ LOAD: skill_view("p-clone-reel", ".hub/c-ffmpeg/SKILL.md") — composite-split-screen (source top + avatar bottom, or PIP at detected position)
→ Two-pass colorkey: `0x00FF00:0.25:0.05,colorkey=0x00FF00:0.40:0.01`

→ Output: `video/compositing/composite-v1.mp4`

---

## QA gate (MANDATORY — run before upload)

Run the shared eval engine (`c-eval-runner`) on the final assembled MP4 before delivery.
It reads this recipe's `acceptance.json`, delegates the mechanical gate to `c-shorts-qa-gate`,
runs geometry checks, and writes a structured `scorecard.json`.
**Do NOT deliver if it exits non-zero (verdict FAIL).**

```bash
SKILL_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" /Users/vasanth/Code/skills -maxdepth 5 -type d -name p-clone-reel 2>/dev/null | head -1)
bash .hub/c-eval-runner/scripts/eval-run.sh <FINAL_MP4> --recipe-dir "$SKILL_DIR" --brand "$BRAND_SLUG"
# scorecard → <video_dir>/eval/scorecard.json ; frame sweep → <video_dir>/eval/
```

Replace `<FINAL_MP4>` with the path to the assembled output (e.g. `final/pr-viral01-<name>.mp4`).

- **HARD** (verdict FAIL, exit 1, blocks delivery): mechanical gate (loudness ≈ -14 LUFS,
  frame-0 brightness, resolution/fps, audio present), duration 27–63s, canvas exactly 1080×1920.
- **PERCEPTUAL** (verdict NEEDS_VISION until resolved): avatar PIP visibility, greenscreen
  cleanliness, source content visible in background, cover money-shot check — emitted as PENDING
  with a frame sweep; resolve with a vision pass before delivery.

**Interim gate (fail-fast, recommended before Step 6):**
```bash
bash .hub/c-eval-runner/scripts/eval-run.sh video/compositing/composite-v1.mp4 --recipe-dir "$SKILL_DIR" --step composite
```

## Step 6 — Outro + Delivery ⛔ CHECKPOINT

→ Append brand outro
→ LOAD: skill_view("p-clone-reel", ".hub/c-ffmpeg/SKILL.md") — 12-point delivery checklist
→ Output: `final/pr-viral01-{desc}.mp4`

**Gate: All delivery checks pass.**

## Self-Improvement Feedback Loop

After completing this skill's task:
1. Ask the user: "How did this go? Any corrections or improvements for next time?"
2. Summarize feedback into 1–3 concise bullet points.
3. Append to `LEARNINGS.md` in this folder with the date.
4. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section at the top of `LEARNINGS.md`.
5. Mark critical feedback with `[ACTIVE]` prefix so it is visually distinct.
