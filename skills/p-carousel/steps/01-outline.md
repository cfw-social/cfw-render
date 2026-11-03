# Outline the slides

Turn the topic into a slide-by-slide outline: a hook cover, one insight per content slide, and a
closing slide that carries the call to action. Nothing is rendered here.

## You receive

- `inputs/topic/topic.md` — the carousel topic / hook from the owner.
- `inputs/num_slides/num_slides.md` — optional; one of `3`, `5`, `7`, `10`. Default `5`.
- `brief.json` — `intent`, `targets`, `brand` (name, brief text, palette when known).

No prior saves: this is the first step.

## You must produce

- `saves/outline.json`:

```json
{
  "topic": "<the topic as given>",
  "num_slides": 5,
  "aspect_ratio_hint": "4:5",
  "slides": [
    { "n": 1, "role": "cover",   "headline": "<hook, ≤ 8 words>", "angle": "<why it stops the scroll>" },
    { "n": 2, "role": "content", "headline": "<insight 1>",       "angle": "<the one point this slide makes>" },
    { "n": 5, "role": "closing", "headline": "<CTA line>",        "angle": "follow + offer" }
  ]
}
```

Exactly `num_slides` entries: `n` 1…N, the first `role: "cover"`, the last `role: "closing"`,
every other one `role: "content"`.

## How

`mkdir -p work saves`.

### 1. Read the inputs

```bash
TOPIC=$(cat inputs/topic/topic.md 2>/dev/null | tr -s '[:space:]' ' ')
N=$(cat inputs/num_slides/num_slides.md 2>/dev/null | tr -dc '0-9'); N=${N:-5}
python3 -c "import json;b=json.load(open('brief.json'));print(b['brand'].get('name'),'|',b.get('intent'))"
```

If `TOPIC` is empty or is not something a reader could learn from (a single word, a URL with no
context, a question to you), ask for it (below).

### 2. Write the outline

Headlines are short, value-front and scroll-stopping. Content slides reveal progressively — each
one makes exactly one point that the next slide builds on; no two slides make the same point.
The cover states the promise; the closing slide restates it as an action (save / follow / the
brand offer) — write the closing headline from `brief.json.brand` and the intent, never a stock
line. Latin script only, no kitchen words.

### 3. Write the save and self-check

```bash
python3 - <<'PY'
import json
o = json.load(open('work/outline.json'))
s = o["slides"]; n = int(o["num_slides"])
assert len(s) == n and [x["n"] for x in s] == list(range(1, n+1)), "slide numbering"
assert s[0]["role"] == "cover" and s[-1]["role"] == "closing", "cover/closing roles"
assert all(x["role"] == "content" for x in s[1:-1]), "middle slides are content"
assert all(0 < len(x["headline"].split()) <= 8 for x in s), "headline ≤ 8 words"
json.dump(o, open('saves/outline.json', 'w'), indent=1)
print(f"[carousel] outline: {n} slides")
PY
```

## If you cannot proceed

This step may ask for **`topic` only**. Write `needs_input.json` and stop (no save) when the
topic is missing or too thin to outline, e.g.
`{"inputId":"topic","reason":"Tell me what the carousel should teach or argue, in one or two sentences."}`.
A missing `num_slides` is not an ask — use the default.

## Checks the harness runs

- `outline_shape` — `saves/outline.json` parses; `slides` has `num_slides` entries numbered
  1…N with roles cover / content… / closing and non-empty headlines.
