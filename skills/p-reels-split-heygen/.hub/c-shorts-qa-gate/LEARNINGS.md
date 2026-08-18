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
