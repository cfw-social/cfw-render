# Write the generation prompts

Turn the owner's description into one concrete, brand-based generation prompt per requested
image, plus a negative list and the model choice. Nothing is generated here.

## You receive

- `inputs/prompt/prompt.md` — the owner's image description.
- `inputs/count/count.md` — optional; one of `1`,`2`,`3`,`4`,`6`. Default `1`.
- `inputs/aspect_ratio/aspect_ratio.md` — optional; `1:1` (default), `9:16` or `16:9`.
- `inputs/reference_image/` — optional reference (note its presence; the next step uses it).
- `brief.json` — `intent`, `brand` (name, brief text, `imageStyle` when present), `targets`.

No prior saves: this is the first step.

## You must produce

- `saves/prompts.json`:

```json
{
  "count": 1,
  "aspect_ratio": "1:1",
  "model": "z-image",
  "has_reference": false,
  "negative": "watermark, text artifacts, extra limbs, blurry, low contrast",
  "images": [
    { "n": 1, "prompt": "<full prompt: brand style base + subject + setting + light + palette>", "variant": "<what makes this one different from the others>" }
  ]
}
```

Exactly `count` entries, `n` 1…count.

## How

`mkdir -p work saves`.

### 1. Read the inputs

```bash
DESC=$(cat inputs/prompt/prompt.md 2>/dev/null | tr -s '[:space:]' ' ')
N=$(cat inputs/count/count.md 2>/dev/null | tr -dc '0-9'); N=${N:-1}
AR=$(cat inputs/aspect_ratio/aspect_ratio.md 2>/dev/null | tr -d '[:space:]'); AR=${AR:-1:1}
ls inputs/reference_image/ 2>/dev/null
python3 -c "import json;b=json.load(open('brief.json'));print(b['brand'].get('name'),'|',b.get('intent'),'|',b['brand'].get('imageStyle',''))"
```

If `DESC` is empty or does not name a subject (a single adjective, a URL, a question to you),
ask for it (below).

### 2. Write the prompts

For each of the `count` images: start from the brand's style base (`imageStyle` / brand brief),
then the owner's subject, then setting, light, lens/medium and palette, in one paragraph of
plain descriptive sentences — no prompt-weight syntax. Batches vary ONE thing per image
(angle, time of day, composition) and keep the subject and style constant; say what varies in
`variant`. Text the owner asked to appear is quoted verbatim and kept ≤ 4 words; otherwise add
"no text" to the prompt. Pick the model: `z-image` by default, `google/imagen4-fast` when the
brief asks for product/brand photography, `gpt-image/1.5-text-to-image` for complex photoreal
scenes.

### 3. Write the save and self-check

```bash
python3 - <<'PY'
import json
p = json.load(open('work/prompts.json'))
n = int(p["count"]); imgs = p["images"]
assert n in (1,2,3,4,6) and len(imgs) == n and [i["n"] for i in imgs] == list(range(1, n+1)), "count/numbering"
assert p["aspect_ratio"] in ("1:1","9:16","16:9"), "aspect"
assert p["model"] in ("z-image","google/imagen4-fast","seedream/4.5-text-to-image","gpt-image/1.5-text-to-image"), "model"
assert all(len(i["prompt"].split()) >= 12 for i in imgs), "prompt too thin"
json.dump(p, open('saves/prompts.json', 'w'), indent=1)
print(f"[ai-image] {n} prompt(s), {p['aspect_ratio']}, model {p['model']}")
PY
```

## If you cannot proceed

This step may ask for **`prompt` only**. Write `needs_input.json` and stop (no save) when the
description is missing or too thin to picture, e.g.
`{"inputId":"prompt","reason":"Describe the image: what is in it, where, and the mood you want."}`.
Missing `count` / `aspect_ratio` are not asks — use the defaults.

## Checks the harness runs

- `prompts_shape` — `saves/prompts.json` parses; `images` has `count` entries numbered 1…N,
  each with a prompt of ≥ 12 words; `aspect_ratio` and `model` are from the allowed sets.
