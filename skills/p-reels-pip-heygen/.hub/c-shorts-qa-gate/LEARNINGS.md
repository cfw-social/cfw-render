# c-shorts-qa-gate — Learnings

## Active Feedback
_(non-negotiable rules — apply on every run)_

- The HARD green-screen/chroma-key check belongs at the **keying step** (c-ffmpeg, on
  `avatar-on-bg.mp4` where green must be fully absent), NOT on the final composite —
  legitimate green content (foliage b-roll, brand colors) is indistinguishable from a
  key leak by histogram on the final video. On the final, green-residual is advisory only.

## Log
- **2026-06-17** — Created. v1 = mechanical hard checks (loudness, frame-0 brightness,
  resolution/fps/duration, audio) + advisory frame sweep for captions/coverage/outro/lip-sync.
  Mirrors brain doctrine `concepts/infra/video-production/short-form-qa-gate`.

- **2026-09-05 (CFW-131)** — Frame-0 floor became **perceptual**. The raw `YAVG > 0x30` mean-luma
  floor false-failed every dark-palette brand card (MGG navy cards read YAVG≈40 with a bright
  white headline on them). New rule: bright frame (YAVG > 48) **or** dark card with bright
  foreground (YAVG ≥ 8 AND luma range ≥ 128 AND ≥ 2 % of pixels ≥ 128). A flat dark frame /
  black / hook-blank still FAILs. Mirrored in `c-eval-runner` as the `contrast_floor` check type
  (`test/golden.sh` trips on a flat navy frame).
