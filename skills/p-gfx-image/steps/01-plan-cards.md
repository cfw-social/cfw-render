# Plan the cards

Turn the topic into one card plan per requested image: the headline, the supporting content
and the layout type that carries it. Nothing is rendered here.

## You receive

- `inputs/topic/topic.md` — what the graphic should explain.
- `inputs/count/count.md` — optional; one of `1`,`2`,`3`,`4`. Default `1`.
- `inputs/format/format.md` — optional; `square` (default), `portrait` or `banner` (note it for
  the layout choice; the next step sets the canvas).
- `brief.json` — `intent`, `targets`, `brand` (name, brief text).

No prior saves: this is the first step.

## You must produce

- `saves/plan.json`:

```json
{
  "topic": "<the topic as given>",
  "count": 1,
  "format": "square",
  "cards": [
    { "n": 1, "layout": "steps", "headline": "<≤ 8 words>", "eyebrow": "<≤ 4 words or empty>",
      "items": ["<step or point 1>", "<step or point 2>", "<step or point 3>"],
      "footer": "<one-line takeaway or empty>" }
  ]
}
```

`layout` is one of `steps` (numbered list / grid), `stat` (one big number + context), `quote`,
`before_after`, `diagram` (3–5 nodes), `banner` (wide headline + tagline — the only layout for
`format: banner`). Exactly `count` entries, `n` 1…count.

## How

`mkdir -p work saves`.

### 1. Read the inputs

```bash
TOPIC=$(cat inputs/topic/topic.md 2>/dev/null | tr -s '[:space:]' ' ')
N=$(cat inputs/count/count.md 2>/dev/null | tr -dc '0-9'); N=${N:-1}
FMT=$(cat inputs/format/format.md 2>/dev/null | tr -d '[:space:]'); FMT=${FMT:-square}
python3 -c "import json;b=json.load(open('brief.json'));print(b['brand'].get('name'),'|',b.get('intent'))"
```

If `TOPIC` is empty or carries nothing to explain (a single word, a bare URL, a question to
you), ask for it (below).

### 2. Plan each card

One point per card. Pick the layout from the content, not the other way round: a process →
`steps` (3–5 items), a number → `stat` (`items[0]` is the figure, `items[1]` the context), a
claim worth quoting → `quote`, a contrast → `before_after` (`items` = `[before, after]`), a
relationship → `diagram`. For a set of several cards, each one makes a different point from
the topic (not reworded variants of the same headline) unless the brief asks for variants.
Headline ≤ 8 words, value-front; items ≤ 12 words each; Latin script; no kitchen words.

### 3. Write the save and self-check

```bash
python3 - <<'PY'
import json
p = json.load(open('work/plan.json'))
n = int(p["count"]); cards = p["cards"]
assert n in (1,2,3,4) and len(cards) == n and [c["n"] for c in cards] == list(range(1, n+1)), "count/numbering"
assert p["format"] in ("square","portrait","banner"), "format"
L = {"steps","stat","quote","before_after","diagram","banner"}
for c in cards:
    assert c["layout"] in L, f"layout {c['layout']}"
    assert 0 < len(c["headline"].split()) <= 8, "headline ≤ 8 words"
    assert isinstance(c["items"], list) and (c["layout"] in ("quote","banner") or len(c["items"]) >= 2), "items"
if p["format"] == "banner": assert all(c["layout"] == "banner" for c in cards), "banner format uses banner layout"
json.dump(p, open('saves/plan.json', 'w'), indent=1)
print(f"[gfx] {n} card(s), format {p['format']}")
PY
```

## If you cannot proceed

This step may ask for **`topic` only**. Write `needs_input.json` and stop (no save) when the
topic is missing or has nothing to explain, e.g.
`{"inputId":"topic","reason":"Tell me the point the graphic should make, with the numbers or steps if there are any."}`.
Missing `count` / `format` are not asks — use the defaults.

## Checks the harness runs

- `plan_shape` — `saves/plan.json` parses; `cards` has `count` entries numbered 1…N, each
  with an allowed `layout`, a headline ≤ 8 words and `items`.
