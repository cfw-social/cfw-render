# Author the HTML compositions

Write one complete, self-contained HTML document per planned card, branded through CSS vars
and sized to the exact canvas. Nothing is rendered here.

## You receive

- `prior/plan.json` — `count`, `format`, `cards[]` (`n`, `layout`, `headline`, `eyebrow`,
  `items`, `footer`).
- `inputs/logo/<file>` — optional brand logo (inline it as a base64 data URI; never link a
  path outside the document).
- `brief.json` — `brand` (name, palette / typography when known, brief text), `intent`.
- `$SKILL_DIR/.hub/c-html-gfx/SKILL.md` — the composition conventions (dark studio theme,
  component patterns) and `$SKILL_DIR/.hub/c-banner/SKILL.md` for `format: banner`.

## You must produce

- `saves/cards_html.json` — `{ "width": 1080, "height": 1080, "format": "square",
  "cards": [ { "n": 1, "html": "<the complete HTML document>" } ] }`, one entry per card.

## How

```bash
mkdir -p work saves
FMT=$(python3 -c "import json;print(json.load(open('prior/plan.json'))['format'])")
case "$FMT" in portrait) W=1080; H=1920;; banner) W=1920; H=1080;; *) W=1080; H=1080;; esac
LOGO=$(ls inputs/logo/* 2>/dev/null | head -1)
```

### 1. The document skeleton (every card)

- `<!doctype html><html><head><meta charset="UTF-8">` + one `<style>` block + `<body>` holding a
  single `.card` of exactly `W`×`H` CSS px at `0,0` (`html,body{margin:0}`;
  `.card{width:Wpx;height:Hpx;overflow:hidden;position:relative}`).
- `:root` vars `--bg`, `--card`, `--ink`, `--muted`, `--accent`, `--line` from
  `brief.json.brand` (fallback: the dark studio default in the shared rules); fonts via a
  `@import` of Google Fonts for the brand type (else Inter + Oswald) with system fallbacks.
- Margin ≥ 72 px on every side (≥ 96 px for banner); nothing touches the edge.

### 2. The layout per card

Build the card from its `layout`: `steps` — numbered cards in a grid with the accent on the
numerals; `stat` — the figure at display size with its context beneath; `quote` — large
quotation with the attribution from the brand; `before_after` — two columns with an
`&rarr;`; `diagram` — 3–5 rounded nodes with connecting lines; `banner` — wide headline left,
tagline and (if supplied) logo right. Depth through soft shadows and rounded surfaces, clear
size/weight progression (eyebrow < body < headline). The logo, when present, sits in a corner
at ≤ 10% of the width.

### 3. Write the save and self-check

Write each document to `work/card-N.html`, then:

```bash
python3 - "$W" "$H" "$FMT" <<'PY'
import json, re, sys
W, H, fmt = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
plan = json.load(open('prior/plan.json')); cards = []
for c in plan["cards"]:
    html = open(f"work/card-{c['n']}.html").read()
    assert '<meta charset="UTF-8">' in html, f"card {c['n']}: charset"
    assert re.search(rf"width:\s*{W}px", html) and re.search(rf"height:\s*{H}px", html), f"card {c['n']}: canvas"
    for v in ("--bg", "--accent", "--ink"):
        assert re.search(v + r"\s*:\s*#[0-9a-fA-F]{6}", html), f"card {c['n']}: {v} not a 6-digit hex"
    assert "#3b82f6" not in html.lower(), f"card {c['n']}: stock blue"
    assert c["headline"] in html, f"card {c['n']}: headline missing from html"
    assert not re.search(r'src="(?!data:)', html), f"card {c['n']}: external src"
    cards.append({"n": c["n"], "html": html})
json.dump({"width": W, "height": H, "format": fmt, "cards": cards}, open('saves/cards_html.json','w'))
print(f"[gfx] {len(cards)} card(s) authored at {W}x{H}")
PY
```

## If you cannot proceed

This step has no `canAsk` (`format` defaults to square; `logo` is optional).
Never write `needs_input.json`. A plan that does not parse is a failure: exit non-zero with one plain line.

## Checks the harness runs

- `html_per_card` — `saves/cards_html.json` has one `html` per card in `prior/plan.json`; each
  carries `<meta charset="UTF-8">`, the canvas size, 6-digit-hex brand vars, its headline, and
  no external `src`.
