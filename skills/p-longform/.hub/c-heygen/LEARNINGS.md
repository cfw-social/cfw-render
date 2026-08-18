# c-heygen Learnings

> This file is the self-learning loop for `c-heygen`. Before executing this skill, the agent reads this file and applies all accumulated `Active Feedback`. After execution, the agent asks the user for feedback and appends it here.

---

## Active Feedback (apply on every run)

- **[ACTIVE] Emotion = INLINE bracketed tags in the script text, NOT the API `voice.emotion` field.** The v2 API `voice.emotion` param (`"Friendly"/"Serious"/…`) is **silently ignored on cloned/instant voices** — a probe on voice `6a9a4d08…` came out flat (scene loudness −18.7 vs −19.1 dB, no delivery difference). The method HeyGen actually honors is inline direction tags embedded in the spoken text: `[curious]`, `[serious]`, `[thoughtful]`, `[excited]`, etc., placed before the phrase they modify (same tags the HeyGen UI's "Auto-enhance" inserts). So put the tags **inside `input_text`**, e.g. `"Two coaches… [curious] One has a full calendar. [serious] Here's the part that should scare you…"` — works in both UI and the v2 API.
- **[ACTIVE] 1080p needs the REST API, not the MCP.** `mcp__heygen__generate_avatar_video` outputs **720p** (no dimension param). For golden-standard 1080p use `POST v2/video/generate` with `"dimension":{"width":1920,"height":1080}` (key: `~/.gsai/secrets.env` `HEYGEN_API_KEY`, header `X-Api-Key`).
- **[ACTIVE] Scene-splitting = multiple `video_inputs`.** Each array entry is a scene (own text/emotion), rendered into one concatenated video. Use for a per-scene emotional arc (hook→agitate→offer→guarantee→CTA).
- **[ACTIVE] The CFW golden studio avatar `9273e994f1ed484d9031afa3725676c5` (voice `6a9a4d08391e4321a48d019e192fa6fe`) bakes its own studio background** — the `background` param is **ignored** (studio blue/orange look always renders). This is correct for the **framed-inset PIP default** (keeps the studio bg, no chroma-key). Do NOT set a `background` for this avatar; do NOT expect green-screen from it.

---

## Feedback Log

### 2026-05-08 — Initial template
- Skill created. No feedback yet.

### 2026-07-06 — VSL emotion + 1080p (CFW DFY VSLs)
- Owner (Vasanth) caught that the probe was flat: emotion must be **inline `[curious]/[serious]/[thoughtful]` tags in the script**, not the API `voice.emotion` field (inert on the cloned voice). He placed the tags manually in the HeyGen UI and resubmitted.
- Confirmed MCP=720p, REST API `dimension`=1080p; scene-split via multiple `video_inputs`; the `9273e994…` avatar ignores `background` (studio bg baked in). All promoted to Active Feedback above.

