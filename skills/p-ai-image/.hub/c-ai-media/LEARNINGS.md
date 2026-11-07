# c-ai-media Learnings

> This file is the self-learning loop for `c-ai-media`. Before executing this skill, the agent reads this file and applies all accumulated `Active Feedback`. After execution, the agent asks the user for feedback and appends it here.

---

## Active Feedback (apply on every run)

**[ACTIVE] Use kie.ai API directly — NEVER use `mcp__mcp-image__generate_image`**
The `mcp__mcp-image__generate_image` (Nanobanana/Gemini) MCP is a local-dev-only tool and is NOT available in the production container (`/home/node/.claude` has no MCPs configured). Calling it silently fails/times out, producing an empty output — which is the root cause of "photo posts with no photo" (18/19 empty URLs). Always use `KIE_AI_API_KEY` + `curl` to call `https://api.kie.ai/api/v1/jobs/createTask` directly. Default model: `z-image`.

**[ACTIVE] Always emit `IMAGE_URL:` or `IMAGE_FAILED:` on the last line**
The caller (`run_skill` in the agent loop) reads the last line of stdout to extract the URL. If you exit without printing `IMAGE_URL: <url>`, the caller sees an empty URL and `propose_composition` will create a photo post with no photo. If generation fails, print `IMAGE_FAILED: <reason>` so the caller knows to NOT call `propose_composition`.

**[ACTIVE] Poll with a 150s budget (30 × 5s) — NOT 240s+**
The `run_skill` subprocess has a 3-minute (180s) hard timeout from `skill-runner.ts`. The full pipeline (create + poll + download + r2-upload) must fit within ~170s to leave a buffer. Use `MAX_POLLS=30` and `INTERVAL=5` (150s max poll budget). If `z-image` times out, fail cleanly with `IMAGE_FAILED:` — do NOT hang. (This budget is for the `run_skill` path. A CFW render harness step uses the `--timeout` its step file sets.)

**[ACTIVE] Image-to-image references are hosted URLs, never base64 data URIs**
Kie's i2i models read `input_urls` as "File URL after upload, not file content". A request with a `data:image/png;base64,…` URI there (and, on `gpt-image/1.5-image-to-image`, a 9:16 aspect and no `quality`, which that model's doc does not allow) got createTask code 500 on every try (cfw order TSW3, p-ai-character scenes, 2026-11-05). Upload the file with Kie's File Upload API and pass its `downloadUrl` — `scripts/generate.py --ref FILE` does this. Use `gpt-image-2-image-to-image` for a 9:16 frame: `gpt-image/1.5-image-to-image` only takes 1:1, 2:3 or 3:2.

---

## Feedback Log

### 2026-11-05 — i2i references must be uploaded (WI31.7)
- **Root cause:** p-ai-character step 03 sent the character reference to `gpt-image/1.5-image-to-image` as a 307 KB base64 data URI in `input_urls`, with `aspect_ratio: "9:16"` and no `quality`. Kie's doc for that model says `input_urls` is "File URL after upload, not file content", `aspect_ratio` is one of 1:1/2:3/3:2, and `quality` is required. createTask returned code 500 three times.
- **Fix:** `generate.py --ref` uploads to `POST https://kieai.redpandaai.co/api/file-stream-upload` (free, kept 24 h) and sends `data.downloadUrl` in `input_urls` of `gpt-image-2-image-to-image` (`9:16`, `resolution` 2K, 10 credits). It refuses `--ref` for models that would ignore it, and refuses an image whose recorded task lost `input_urls`.

### 2026-05-27 — Root cause diagnosis + full rewrite
- **Root cause:** `c-ai-media` called `mcp__mcp-image__generate_image` (Nanobanana MCP). This MCP is configured only on the developer's local machine; the production container has no MCPs for the `node` user's `claude --print` subprocess. Result: the subprocess either errored silently or timed out (at 3 min), returning empty stdout — hence `ok:true` with no URL in the output.
- **Fix:** Rewrote skill to use `KIE_AI_API_KEY` + direct `curl` calls to kie.ai API (same pattern as `cfw-broll-source` which works reliably). Default model changed to `z-image` (~15-30s, reliable).
- **Fail-fast contract:** Added mandatory `IMAGE_URL:` / `IMAGE_FAILED:` output contract so the caller can detect failure and refuse to create a media-required composition with no media.

### 2026-05-08 — Initial template
- Skill created. No feedback yet.
