---
name: c-typing-ui
description: HyperFrames scene component that renders a dark chat/terminal card which types a prompt char-by-char with a blinking cursor, plus hook title cards. Designed to replace the Remotion fmt6/rmtn-fmt5 typing UI. Use when a reel beat calls for a graphics(scene) of type "typing" (interactive prompt reveal) or "hook" (kinetic title card). Supports 9:16 full-frame and PIP-safe variants. All content is data-driven via props — nothing is hardcoded.
kind: component
visibility: internal
version: 1.0.0
dependsOn: [f-hyperframes, f-hyperframes-cli, f-gsap]
requires: node, chromium, ffmpeg
---


# c-typing-ui — HyperFrames chat/terminal typing scene

Two scene variants, both 1080×1920 (9:16):

| Scene | Template | What it renders |
|---|---|---|
| `typing` | `templates/typing-scene.html` | Dark chat card (Claude/terminal style) that types `prompt` char-by-char, with a blinking cursor. Header shows `label` ("claude.ai" / "Terminal"). |
| `hook` | `templates/hook-scene.html` | Big kinetic title: eyebrow mono label + stacked Oswald headline + accent keyword with glow. The "day13 hook" look. |

Both ship as **sub-compositions** (wrapped in `<template>`) for use from a root `index.html` via
`data-composition-src`. See templates for the standalone (full) render workflow.

## Design reference (MGG day13 canonical look)

Sourced from the Remotion `ScenePromptReveal` + `SceneHook` day13 originals:

| Token | Value | Notes |
|---|---|---|
| `--bg-navy` | `#0F172A` | Canvas background |
| `--bg-card` | `#0B1220` | Card background (darker than canvas) |
| `--bg-card-header` | `#141A2A` | Title bar background |
| `--bg-card-border` | `#334155` | Card border |
| `--bg-bubble` | `#121A2C` | Message bubble background |
| `--accent` | `#F97316` | Orange (default MGG accent) |
| `--violet` | `#8B5CF6` | Cursor + Claude logo gradient |
| `--coral` | `#F97316` | Hook line 1 color |
| `--text-white` | `#F8FAFC` | Primary text |
| `--text-muted` | `#94A3B8` | Secondary labels |
| `--text-dim` | `#64748B` | Tertiary hints |
| Heading font | Oswald 900 | Title cards |
| Mono font | JetBrains Mono | Card body + eyebrows |
| Body font | Inter | Labels |

Override any CSS var to re-brand without touching markup.

## Props/data schema

Both templates use `{{PLACEHOLDER}}` substitution (same pattern as `p-reels-hf-fmt5`'s `motion-card.html`).

### Typing scene (`templates/typing-scene.html`)

| Placeholder | Required | Default / Example | Notes |
|---|---|---|---|
| `{{DURATION}}` | Yes | `9.0` | Clip length in seconds |
| `{{LABEL}}` | Yes | `claude.ai` | Title bar label (plain text) |
| `{{PROMPT}}` | Yes | `Research this person…` | Prompt text typed out. Newlines as `\n` in JSON, literal `&#10;` in the HTML template. Use `{{PROMPT_HTML}}` for markup. |
| `{{TYPING_SPEED}}` | No | `1.0` | Multiplier (0.5 = slow, 2.0 = fast). Characters typed = `text.length × speed` per duration. |
| `{{ACCENT}}` | No | `#F97316` | 6-digit hex, no `#` prefix needed in template (template prepends `#`). |
| `{{VARIANT}}` | No | `full` | `full` = full-frame (content centred); `pip-safe` = content in top 55% only (clears the PIP zone). |
| `{{BOTTOM_TAG}}` | No | `` | Optional mono caption below the card, e.g. `"research · personalise · send"`. Leave blank to hide. |

### Hook scene (`templates/hook-scene.html`)

| Placeholder | Required | Default / Example | Notes |
|---|---|---|---|
| `{{DURATION}}` | Yes | `2.5` | Clip length in seconds |
| `{{EYEBROW}}` | Yes | `Day 13 · Prompt of the Day` | Small upper label (mono, muted) |
| `{{LINE1}}` | Yes | `PROMPT 13.` | First big title line |
| `{{LINE2}}` | No | `COLD EMAIL` | Second big title line (accent colour + glow) |
| `{{LINE3}}` | No | `OPENER.` | Third big title line (accent colour) |
| `{{SUBHEAD}}` | No | `` | Optional mid-size subheading below the stack |
| `{{ACCENT}}` | No | `#F97316` | 6-digit hex for accent/glow colour |

## Usage — standalone render (one beat)

```bash
SKILL_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" -maxdepth 4 -type d -name c-typing-ui 2>/dev/null | head -1)
BEAT_DIR="$W/beat_typing_0"
mkdir -p "$BEAT_DIR"

# Substitute placeholders and write a standalone index.html
python3 - "$SKILL_DIR/templates/typing-scene.html" "$BEAT_DIR/index.html" <<'PY'
import sys, html as h

# --- configure per beat ---
replacements = {
    "DURATION":     "9.0",
    "LABEL":        "claude.ai",
    "PROMPT":       h.escape("Research this person based on\ntheir LinkedIn bio: [paste bio].\n\nFind one real thing they did recently.\n\nWrite a two-sentence opening that references it.\n\nNo fake compliments."),
    "TYPING_SPEED": "1.0",
    "ACCENT":       "F97316",
    "VARIANT":      "pip-safe",
    "BOTTOM_TAG":   "research · personalise · send",
}
src, dst = sys.argv[1], sys.argv[2]
tmpl = open(src).read()
# standalone: strip the <template> wrapper
import re
tmpl = re.sub(r'<template[^>]*>\s*', '', tmpl)
tmpl = re.sub(r'\s*</template>', '', tmpl)
# Wrap in full HTML document
body = tmpl
for k, v in replacements.items():
    body = body.replace("{{" + k + "}}", v)
with open(dst, "w") as f:
    f.write(f"""<!DOCTYPE html>
<html><head><meta charset="utf-8">
<style>html,body{{margin:0;padding:0;width:1080px;height:1920px;overflow:hidden;background:#0F172A;}}</style>
</head><body>{body}</body></html>""")
PY

cd "$BEAT_DIR" && npx hyperframes@0.7.5 lint && npx hyperframes@0.7.5 render --output "$W/typing_beat.mp4" --fps 30 --quality high
```

## Usage — as sub-composition (in a multi-scene index.html)

Load the template directly:
```html
<div id="el-typing-0"
  data-composition-id="typing-scene"
  data-composition-src="typing-scene.html"
  data-start="0"
  data-duration="9.0"
  data-width="1080"
  data-height="1920"
  data-track-index="0">
</div>
```

Copy the FILLED template into the same dir as `index.html`; the `data-composition-src` path is relative.

## PIP safe zone

The `pip-safe` variant keeps ALL content above y=1040px (top 54% of 1920). The bottom ~46% is clear for
a composite talking-head PIP. Use `pip-safe` for `p-reels-pip`; use `full` for faceless or spotlight
layouts where no PIP sits on top.

## Gotchas (HyperFrames authoring traps — do not re-derive)

- Root composition (`index.html`) = FULL HTML document — no `<template>` wrapper.
- Sub-composition (`typing-scene.html`) = content inside `<template id="…">` wrapper.
- `data-duration` drives clip length — GSAP timeline length is irrelevant.
- Typing is driven by a **stepped GSAP counter** (not TextPlugin) for frame-stability under headless chromium.
  Counter tween on `#char-count` from `0` to `text.length`, ease `none`, then sliced in a `gsap.ticker.add`.
  A GSAP `ticker` is NOT used in final form — the count proxy is tweened and read at each GSAP scrub position.
- GSAP `repeat` is always finite: `Math.ceil(duration / blinkPeriod) - 1`.
- Never inline `Math.random()` — use a mulberry32 seeded PRNG if decorative noise is needed.
- Cursor blink uses `opacity` tween with `repeat` + `yoyo: true` — never `visibility`.
- The `window.__timelines` registration must be SYNCHRONOUS — no async wrappers.
