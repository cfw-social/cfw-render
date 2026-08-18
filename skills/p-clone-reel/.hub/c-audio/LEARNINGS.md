# c-studio-audio Learnings

> This file is the self-learning loop for `c-studio-audio`. Before executing this skill, the agent reads this file and applies all accumulated `Active Feedback`. After execution, the agent asks the user for feedback and appends it here.

---

## Active Feedback (apply on every run)

- [ACTIVE] ELEVENLABS_API_KEY lives in `~/.gsai/secrets.env` — always `source ~/.gsai/secrets.env` before checking if the key is missing. FLOE_API_KEY may not be set; fall back to direct ElevenLabs immediately.
- [ACTIVE] Single-pass `loudnorm` undershoots target by ~1.5 LUFS on speech. Use two-pass approach: first pass with `print_format=json` to get measured values, second pass with `linear=true` + measured values, then apply a `volume=+Xdb` trim if still short. ±0.5 LUFS from target is acceptable.

---

## Feedback Log

### 2026-05-22 — COM-40 PAL v3 Module 1 batch TTS run
- ELEVENLABS_API_KEY was available in `~/.gsai/secrets.env` the whole time — agents blocked for 11 days unnecessarily. Always source secrets.env before declaring a key missing.
- FLOE_API_KEY was not set; direct ElevenLabs API worked fine as fallback (eleven_turbo_v2_5).
- Single-pass loudnorm undershot -14 LUFS target by ~1.5 LUFS on TTS speech. Two-pass + volume trim got within 0.4–0.5 LUFS — acceptable.
- Five lessons produced: 1.1 (285s), 1.2 (348s), 1.3 (335s), 1.4 (290s), 1.5 (332s). All in productions/pal-v3-module-1/interim/audio/.

### 2026-05-08 — Initial template
- Skill created. No feedback yet.

