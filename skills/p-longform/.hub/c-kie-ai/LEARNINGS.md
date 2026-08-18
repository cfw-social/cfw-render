# c-kie-ai Learnings

> This file is the self-learning loop for `c-kie-ai`. Before executing this skill, the agent reads this file and applies all accumulated `Active Feedback`. After execution, the agent asks the user for feedback and appends it here.

---

## Active Feedback (apply on every run)

- **VIDEO GATE — user approval before any video spend (2026-07-03).** Video costs
  300–1300 credits vs ~6 per image. Before ANY video createTask: show the user the
  exact start-frame image(s) + estimated credits and get an explicit yes. Through
  kie-studio this is enforced (`plan create` → user approves → `plan approve` →
  `generate --plan <id>`); on raw API calls YOU are the gate — never skip it.

- **Never trust reference-field names from memory (2026-07-03).** The ref key
  differs per model (`input_urls` / `image_urls` / `image_url` / `image_input`) and
  KIE silently ignores unknown keys — the wrong key silently degrades i2i/i2v to
  pure text-to-image. Check `models.jsonl` or kie-studio's
  `data/model-contracts.yaml` for the exact key; after createTask, confirm
  `recordInfo.param` echoes your reference URLs. kie-studio validates this
  automatically ("no contract, no spend") — prefer it when it covers the model.

- **`gpt-image-2-image-to-image` requires `input_urls`, NOT `image_urls`.**
  The KIE API silently ignores `image_urls` for this model and falls back to text-to-image,
  producing a generic/whitened face with weak identity. The correct field name is
  `input_urls` (array of public URLs). Confirmed 2026-07-03 by inspecting `recordInfo.param`
  for both a working task (used `input_urls`) and a failing task (used `image_urls`).
  The correct call:
  ```bash
  node bin/kie-studio.mjs generate --model gpt-image-2-image-to-image \
    --input '{"prompt":"...","input_urls":["<url1>","<url2>"],"size":"1024x1536","quality":"high"}'
  ```

---

## Feedback Log

### 2026-05-16 — Image editing via c-kie-ai
- **kie.ai credit depletion**: Multiple models (qwen/image-edit, qwen/image-to-image, google/nano-banana) returned 402 "Credits insufficient" — account may need top-up before next run.
- **flux-2/flex-image-to-image resolution**: API accepted "hd" as a valid resolution value once (hit 429 rate-limit), then inconsistently rejected it as "not within range". Flux-2 is not reliable for precise editing.
- **fal.ai fallback works for image-to-image**: `fal.run/fal-ai/flux/dev/image-to-image` successfully processed a hand-removal + floating-object edit with public URL input. Use fal.ai when kie.ai is out of credits or when precise image-to-image is needed.
- **Model input format notes**:
  - flux-2/flex-image-to-image: accepts `input_urls` with public HTTP URLs (not base64)
  - gpt-image/1.5-image-to-image: accepts `input_urls` with data URIs, but returned "File type not supported" for both JPEG and PNG base64 on 2026-05-16 — model may be temporarily broken or requires a different prefix format
  - qwen/image-edit and qwen/image-to-image: accept `image_url` with public URL, but require credits

### 2026-05-08 — Initial template
- Skill created. No feedback yet.

