---
name: p-ai-character
description: AI character animated short pipeline. Produces a 9:16 short using Gemini character-consistent scene images animated via Hailuo i2v. Works for any character type — human, plush toy (Labubu/Tiny Tales style), mascot, or fantasy. No dialogue — visual storytelling with music. Requires 6-attribute character lock audit before any generation.
disable-model-invocation: true
argument-hint: "[brand] [production-name] [story-concept] [--type human|plush]"
allowed-tools: Bash, Read, Write
kind: pipeline
visibility: catalog
providers: kie
produces:
  dish: AI Character Short
  format: 9:16 vertical video
  duration: 30-60s
inputs: [story_concept]
dependsOn: [c-ai-media, c-ffmpeg, c-music, c-shorts-qa-gate, c-eval-runner]
metadata:
  hermes:
    vendored:
      - { name: c-ai-media, load: ".hub/c-ai-media/SKILL.md" }
      - { name: c-eval-runner, load: ".hub/c-eval-runner/SKILL.md" }
      - { name: c-ffmpeg, load: ".hub/c-ffmpeg/SKILL.md" }
      - { name: c-kie-ai, load: ".hub/c-kie-ai/SKILL.md" }
      - { name: c-music, load: ".hub/c-music/SKILL.md" }
      - { name: c-shorts-qa-gate, load: ".hub/c-shorts-qa-gate/SKILL.md" }
    progressive: true
---


# pipeline-ai-character — AI Character Short (9:16)


> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing ANY step in this skill, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as if it were a non-negotiable rule.
> 3. Only then proceed with the skill's normal instructions.
> 4. After completing the task, ask the user: "How did this go? Any corrections or improvements for next time?"
> 5. Summarize the feedback into 1–3 bullet points and append to `LEARNINGS.md` with today's date.
> 6. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section so it applies on every future run.

> **BACKEND STALE** — Gemini image → Hailuo i2v scene-by-scene flow is superseded by multi-motion video models (e.g. Sea Dance / Wan 2.1 / Kling 2.0) that generate character-consistent multi-scene video from a single prompt. The 6-attribute character lock audit and story arc structure remain valid. Rewrite Steps 3–5 around the new model before using.

Visual storytelling: character lock → Gemini scene images → Hailuo animation → music assembly.

## Arguments

| Arg | Required | Default | Description |
|-----|----------|---------|-------------|
| brand | Yes | — | Brand slug |
| production_name | Yes | — | Folder name |
| story_concept | Yes | — | One-paragraph story concept |
| character_description | Yes | — | Visual character description (all 6 attributes) |
| audio_track | Yes | — | Background music. Library `cdnUrl` from `list_music_tracks` (preferred) or a local path. If a `media.cfw.social` URL, it is fetched to disk in Step 5a via `c-music`. |
| music_track_id | No | — | `MusicTrack.id` from `list_music_tracks` — pass to `attach_output_to_composition(musicTrackId)` so CC-BY attribution auto-appends on publish |
| type | No | `human` | `human` or `plush` — controls character audit checklist and prompt tone |
| num_scenes | No | `5` | Number of scenes |
| character_method | No | `gemini` | `gemini` or `floe` |
| crossfade | No | `0.3s` | Crossfade duration between scenes |

---

## Step 0 — Character Lock Audit ⛔ HARD GATE

Before ANY generation, verify `character_description` covers all 6 attributes.

**If `--type human`:**
1. Face shape (oval, square, angular…)
2. Hair: color, length, style
3. Eyes: color, shape, expression
4. Clothing: color, pattern, texture
5. Distinctive feature (scar, glasses, accessory…)
6. Color palette (primary + accent)

**If `--type plush` (Labubu / Tiny Tales style):**
1. Body type / plush material (soft, vinyl, fuzzy…)
2. Face: eye shape, eye color, nose/mouth style
3. Ear/head shape (rabbit ears? round head? spiky?)
4. Outfit: color, pattern, texture
5. Accessories or distinctive features
6. Color palette (primary + accent)

**All 6 must be specific and visual. Vague = fail. STOP until complete.**

Also establish **divergence protocol**: after each generated image, check character has same attributes as char-ref. Any divergence in face, outfit, or distinctive feature = regenerate immediately. Do NOT animate a diverged scene.

**Gate: Character description passes all 6 audit points.**

---

## Step 1 — Story Arc ⛔ CHECKPOINT

Write 5-act story structure (`num_scenes` scenes):

- Act 1: Establish character + world
- Act 2: Introduce tension/desire
- Act 3: Rising action / attempt + obstacle
- Act 4: Climax (emotional or comedic peak)
- Act 5: Resolution (heartwarming / funny payoff)

Each scene: visual description + emotion + camera angle + motion cue.

For `--type plush`: keep emotional register toylike and playful. Physical movements should be exaggerated and charming.

**Gate: User approves story arc.**

---

## Step 2 — Character Reference

→ LOAD: skill_view("p-ai-character", ".hub/c-ai-media/SKILL.md") — `gemini-character-ref` (`--model pro` — never flash, consistency issues)
→ Prompt: full `character_description` + "product photography, white background, full body, clean studio lighting"
→ Output: `interim/broll/gfx/char-ref.png`

This reference image MUST be passed to every scene generation call. Never skip it.

---

## Step 3 — Scene Images ⛔ CHECKPOINT

For each scene (generate in order):
→ LOAD: skill_view("p-ai-character", ".hub/c-ai-media/SKILL.md") — `gemini-character-scene`
→ Pass `char-ref.png` to EVERY call — no exceptions
→ Motion prompts: 1–2 sentences, gentle words (slow, subtle, still, drifting)
→ Output: `interim/broll/segments/scene-{N}.png`

After each image: run divergence check. Regenerate before moving on if diverged.

For `--type plush`: include "plush toy", "soft fabric texture", "photorealistic toy photography" in every prompt.

**Gate: User approves all scene images. No diverged images proceed.**

---

## Step 4 — Animation (Hailuo i2v)

For each approved scene image:
→ Submit to Hailuo image-to-video via Floe API
→ Motion prompt: match scene motion cue (short, gentle)
→ Poll for completion (5–10 min per clip)
→ Output: `interim/broll/segments/scene-{N}-anim.mp4`

---

## Step 5a — Resolve background music

If `$audio_track` is a `https://media.cfw.social/...` library URL (the normal case — the
Director picks it via `list_music_tracks`), fetch it to disk first; recipes mux a local
file, not a URL.

→ LOAD: skill_view("p-ai-character", ".hub/c-music/SKILL.md") —(with `MUSIC_CDN_URL=$audio_track`, `MUSIC_TRACK_ID=$music_track_id`)
- Set `$audio_track` to the returned `AUDIO_PATH` for the mux below.
- Carry `MUSIC_TRACK_ID` through to `attach_output_to_composition(musicTrackId)` at
  delivery so CC-BY attribution auto-appends to the caption.

If `$audio_track` is already a local path, skip this step.

---

## Step 5 — Trim + Assemble

→ LOAD: skill_view("p-ai-character", ".hub/c-ffmpeg/SKILL.md") —:
1. Trim each clip to match audio track pacing
2. Scale to 1080×1920 if not already portrait
3. Crossfade concat with `$crossfade` duration
4. Mux with `$audio_track`
5. Loudness: -14 LUFS

→ Output: `video/compositing/composite-v1.mp4`

---

## QA gate (MANDATORY — run before upload)

Run the shared eval engine (`c-eval-runner`) on the final assembled MP4 before delivery.
It reads this recipe's `acceptance.json`, delegates the mechanical gate to `c-shorts-qa-gate`,
runs geometry and luma checks, and writes a structured `scorecard.json`.
**Do NOT deliver if it exits non-zero (verdict FAIL).**

```bash
SKILL_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" /Users/vasanth/Code/skills -maxdepth 5 -type d -name p-ai-character 2>/dev/null | head -1)
bash .hub/c-eval-runner/scripts/eval-run.sh <FINAL_MP4> --recipe-dir "$SKILL_DIR" --brand "$BRAND_SLUG"
# scorecard → <video_dir>/eval/scorecard.json ; frame sweep → <video_dir>/eval/
```

Replace `<FINAL_MP4>` with the assembled output (e.g. `final/pr-aimg01-<name>.mp4`).

- **HARD** (verdict FAIL, exit 1, blocks delivery): mechanical gate (loudness ≈ -14 LUFS,
  frame-0 brightness, resolution/fps, audio present), duration 27–63s, canvas exactly 1080×1920,
  center zone (y 480–1440) not dark at 6 sampled points across the reel.
- **PERCEPTUAL** (verdict NEEDS_VISION until resolved): 6-attribute character consistency,
  no diverged frames, smooth crossfades, character fills the frame, cover money-shot check —
  emitted as PENDING with a frame sweep; resolve with a vision pass before delivery.

**Interim gate (fail-fast, recommended before Step 6):**
```bash
bash .hub/c-eval-runner/scripts/eval-run.sh video/compositing/composite-v1.mp4 --recipe-dir "$SKILL_DIR" --step composite
```

## Step 6 — Delivery ⛔ CHECKPOINT

→ LOAD: skill_view("p-ai-character", ".hub/c-ffmpeg/SKILL.md") — 12-point delivery checklist
→ Verify output: codec, resolution, audio
→ Move to: `final/pr-aimg01-{desc}.mp4`

**Gate: User reviews final animation quality.**

## Self-Improvement Feedback Loop

After completing this skill's task:
1. Ask the user: "How did this go? Any corrections or improvements for next time?"
2. Summarize feedback into 1–3 concise bullet points.
3. Append to `LEARNINGS.md` in this folder with the date.
4. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section at the top of `LEARNINGS.md`.
5. Mark critical feedback with `[ACTIVE]` prefix so it is visually distinct.

