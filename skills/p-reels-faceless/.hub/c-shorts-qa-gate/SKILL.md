---
name: c-shorts-qa-gate
description: Pre-delivery QA gate for short-form video (reels, shorts, VSL). Runs the mechanical delivery checks that block a broken render — loudness (~-14 LUFS), frame-0 brightness, resolution/fps/duration, audio presence — and emits a frame sweep + report for the perceptual checks (captions, b-roll coverage, outro, lip-sync) a human or vision pass reviews. Use as the final step of any reel/short/VSL recipe before marking a production complete.
when_to_use: Trigger on c-shorts-qa-gate, QA gate, delivery check, shorts/reel/VSL quality gate, verify final video, loudnorm check, frame-0 / black-open check, caption/coverage review, before-publish verification, "is this reel ready to deliver".
allowed-tools: Bash
kind: component
visibility: internal
requires: ffmpeg
---


# c-shorts-qa-gate — Short-Form Pre-Delivery QA Gate


> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing this skill, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as a non-negotiable rule.
> 3. Only then proceed.
> 4. After completing the task, append any correction/improvement to `LEARNINGS.md` with today's date; if it affects correctness, add it under **Active Feedback**.

The single mechanical gate that catches the short-form defects that keep shipping
(loudnorm skipped, black/avatar-only opens, wrong dimensions, missing audio bed).
It is the executable arm of the brain doctrine
`concepts/infra/video-production/short-form-qa-gate` — keep the two in sync.

## Caller Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `<final.mp4>` | yes | Path to the final rendered deliverable |
| `--format` | no | `reel`\|`portrait` (1080×1920, default), `vsl`\|`landscape` (1920×1080), `square` (1080×1080) |
| `--expect-fps` | no | Expected fps (default 30) |
| `--lufs-target` / `--lufs-tol` | no | Loudness target/tolerance (default -14 ± 1.5) |
| `--outdir` | no | Where to write the frame sweep + report (default `<video_dir>/qa/`) |

## Usage

```bash
bash scripts/qa-gate.sh path/to/final.mp4 --format reel
# from inside a built recipe:
bash .hub/c-shorts-qa-gate/scripts/qa-gate.sh output/final-portrait.mp4 --format reel
```

## What it checks

**HARD (exit 1 → DO NOT deliver):**
1. Decodable video stream present
2. Audio track present (voice bed not lost)
3. Resolution matches the format
4. fps ≈ expected
5. Duration > 0
6. Integrated loudness within target (-14 ± 1.5 LUFS) — catches skipped `loudnorm`
7. Frame-0 brightness YAVG > 0x30 — catches black / avatar-only opens (frame-0 must be b-roll)

**ADVISORY (reported + artifacts dumped, never blocks):**
- Captions present & bottom-positioned → `caption-strip-*.png` crops
- B-roll coverage ≥80% / contextual background → `sweep-*.png` (avatar must be the minority)
- Brand outro present → `sweep-last3s.png`
- Lip-sync drift → `sweep-50pct/75pct/last3s.png`
- Green-screen residual → heuristic peak (the **hard** chroma-key check lives at the
  keying step in `c-ffmpeg`, run on `avatar-on-bg.mp4` where green must be fully absent;
  on the final composite, legit green content is indistinguishable by histogram)

Exit codes: `0` all hard checks pass · `1` a hard check failed · `2` usage/IO error.

## Scope (v1)

Pragmatic v1: the cleanly-scriptable checks are hard-enforced; the perceptual ones
(captions OCR, coverage via face-detection, lip-sync) are emitted as a frame sweep for
a human or vision pass. Upgrading those to auto-enforced needs OCR (tesseract) +
face-detection (mediapipe) — deliberately deferred to keep the gate dependency-free.

## Self-Learnings

| Date | What went wrong | Fix |
|------|-----------------|-----|
| 2026-06-17 | `ffprobe csv` resolution parse returned empty → false "no video stream" | Use two `default=nk=1:nw=1` probes for width/height |
| 2026-06-17 | loudnorm JSON parse split on whitespace landed on `:` | Parse with `-F'"'` → field 4 |
| 2026-06-17 | green-residual histogram false-positived on legit green content | Demoted to ADVISORY on final composite; hard chroma check belongs at the keying step |
