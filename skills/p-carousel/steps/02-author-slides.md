# Write copy and author the HTML

Write the full copy for every outlined slide, then author ONE HTML document from the recipe's
`template.html` with one `<section class="slide">` per slide, branded through the CSS vars.

## You receive

- `prior/outline.json` — the slide outline (`slides[]` with `n`, `role`, `headline`, `angle`).
- `inputs/aspect_ratio/aspect_ratio.md` — optional; `4:5` (default) or `1:1`.
- `inputs/cta/cta.json` — optional `{"text","brandName","handle"}`; when absent, use
  `brief.json.brand.name` and no handle line.
- `brief.json` — `brand` (palette / typography when known, brief text), `intent`.
- `$SKILL_DIR/template.html` — the quality floor (component classes `.window`, `.step`,
  `.pill`, `.callout`, `.cta-key`, `.node`).

## You must produce

- `saves/slide_copy.json` — `{ "aspect_ratio": "4:5", "slides": [ { "n", "role", "headline",
  "body", "visual" } ] }` where `body` is ≤ 3 sentences and `visual` names the layout that
  supports the slide (step list, stat, before→after, window mock, node diagram — never
  "just a title").
- `saves/carousel_html.md` — the complete HTML document, verbatim (the `.md` extension is the
  harness convention for text saves; the content is HTML and the next step copies it to
  `work/carousel.html`).

## How

```bash
mkdir -p work saves
RECIPE=$(python3 -c "import json;print(json.load(open('brief.json'))['recipe'])")
SKILL_DIR="$CFW_RENDER_SKILLS_DIR/$RECIPE"
AR=$(cat inputs/aspect_ratio/aspect_ratio.md 2>/dev/null | tr -d '[:space:]'); AR=${AR:-4:5}
cp "$SKILL_DIR/template.html" work/carousel.html
```

### 1. Slide copy

Per slide from the outline: headline ≤ 8 words (keep the outlined one unless it reads badly),
body 2–3 sentences max, and a `visual` idea matched to the point (a numbered step list for a
process, a big-number callout for a stat, a window mock for anything product-like, a node
diagram for relationships). The closing slide's body is the CTA: `cta.text` when supplied,
else a one-line action in the brand's voice; add the handle ONLY when `cta.handle` exists.

### 2. Brand the template

Overwrite the `:root` CSS vars (`--accent`, `--ink`, `--bg`, `--card`, `--line`, `--muted`) and
the font-family declarations with the brand palette / typography from `brief.json.brand` (fall
back to the dark-premium default from the shared rules). Set `--w`/`--h` to `1080`/`1350` for
`4:5` or `1080`/`1080` for `1:1`. Keep `<meta charset="UTF-8">`.

### 3. One section per slide

`<section class="slide" id="sN">` for N = 1…num_slides, in order, built from the template's
component classes so each slide has real layout and depth matching its `visual`. Same fonts,
accent, card style and margin rhythm across the set. Prefer entities (`&rarr;`, `&mdash;`) to
raw symbols.

### 4. Write the saves and self-check

```bash
cp work/carousel.html saves/carousel_html.md
python3 - <<'PY'
import json, re
o = json.load(open('prior/outline.json')); c = json.load(open('work/slide_copy.json'))
html = open('saves/carousel_html.md').read()
n = int(o["num_slides"])
ids = re.findall(r'<section[^>]*class="[^"]*\bslide\b[^"]*"[^>]*id="s(\d+)"', html) or \
      re.findall(r'<section[^>]*id="s(\d+)"[^>]*class="[^"]*\bslide\b', html)
assert sorted(map(int, ids)) == list(range(1, n+1)), f"sections {ids} != 1..{n}"
assert len(c["slides"]) == n, "copy count"
assert '<meta charset="UTF-8">' in html, "charset"
for v in ("--accent", "--ink", "--bg", "--card"):
    assert re.search(v + r"\s*:\s*#[0-9a-fA-F]{6}", html), f"{v} not set to a 6-digit hex"
assert "#3b82f6" not in html.lower(), "stock blue left in template"
json.dump(c, open('saves/slide_copy.json', 'w'), indent=1)
print(f"[carousel] html: {n} sections, aspect {c['aspect_ratio']}")
PY
```

## If you cannot proceed

This step has no `canAsk` (`aspect_ratio` and `cta` have defaults).
Never write `needs_input.json`. A template that cannot be branded or an outline that no longer parses is a
failure: exit non-zero with one plain line.

## Checks the harness runs

- `html_has_slides` — `saves/carousel_html.md` contains `<section class="slide" id="sN">` for
  exactly N = 1…`num_slides` from `prior/outline.json`.
- `brand_vars_set` — the `:root` vars `--accent`, `--ink`, `--bg`, `--card` are 6-digit hexes
  and no stock colour (`#3b82f6`) remains.
