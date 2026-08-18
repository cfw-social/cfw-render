---
name: c-overlay-fx
kind: component
visibility: internal
version: 1.0.0
description: >
  Renders small ANIMATED, TRANSPARENT overlay graphics (pill / sticker-badge /
  mini-flowchart / stat-card) as alpha-channel PNG sequences that reel cores
  composite on top of a finished reel via ffmpeg overlay filter.
  Proven motion envelope: slide-in → wiggle → hold → slide-out.
  All output is true alpha (clearRect, no drawBackground) — RGBA PNGs ready
  for `ffmpeg [reel][overlay]overlay=x:y:format=auto`.
requires:
  - node >= 18
  - canvas ^3.2.3   # canvas 2.x has a black-frame fillRect bug — must be 3.x
---


# c-overlay-fx

Animated transparent overlay graphics for HyperFrames reel cores. Renders
element sequences as alpha-channel PNG files the caller composites on a
finished reel with ffmpeg.

## Quick start

```bash
# Install
cd /path/to/c-overlay-fx
npm install

# Render a transparent element sequence
node render-overlay.cjs element-spec.json /tmp/my-overlay/

# Composite with ffmpeg (example)
ffmpeg -i reel.mp4 \
  -framerate 30 -i "/tmp/my-overlay/frame-%04d.png" \
  -filter_complex "[0:v][1:v]overlay=x=800:y=1750:format=auto" \
  -c:a copy out.mp4
```

## Element library

| Type | Description | Default safe position |
|---|---|---|
| `pill` | White rounded-rect pill with accent left-bar + CTA text. Slides in from RIGHT edge. | cx=960, cy=1800 (lower-right, beside face, x>860) |
| `sticker` | Coloured badge (bold "$0 FREE" or custom icon+text). Slides in from RIGHT. | cx=920, cy=680 (top-right, below title ~460) |
| `flowchart` | Horizontal 3-node mini-flowchart (Record→Edit→Post or custom). Slides DOWN from above. | cx=540, cy=750 (top-half centre) |
| `stat-card` | White card with large stat number + label. Slides in from LEFT. | cx=160, cy=750 (top-left, clear of title) |

## Motion envelope (all element types)

```
  slide-in (0.375s, easeOutBack + overshoot)
  → wiggle  (0.500s, 6°·e^(−8τ)·sin(18τ) + −10px bounceY)
  → hold    (1.250s, 1.5% scale breathe at 1.2 Hz)
  → slide-out (0.375s, easeInBack + fade)
  ─────────────────────────────────────────
  Total: 2.5 s  ·  75 frames at 30fps
```

The slide direction per element type (right/left/down) is chosen to
enter from the nearest canvas edge for naturalness.

## Transparent alpha output contract

- Canvas is cleared with `ctx.clearRect(0, 0, W, H)` every frame — no
  background drawn. Pixels outside the element are fully transparent.
- Output: `frame-0000.png … frame-0074.png` (RGBA PNGs, 1080×1920).
- Caller composites with ffmpeg `overlay=x:y:format=auto` — the `format=auto`
  flag is required to honour the alpha channel.

## CLI usage

```
node render-overlay.cjs <element-spec.json> <out-dir>
```

`element-spec.json` — the element specification (see schema below).
`out-dir` — output directory for PNG frames (created if absent).

The script prints `PNGDIR=<out-dir>` on stdout when complete and progress
on stderr. Exit 0 on success, 1 on error.

## Element-spec schema

```jsonc
{
  // REQUIRED
  "type":     "pill" | "sticker" | "flowchart" | "stat-card",

  // OPTIONAL: canvas position (centre of element at rest, pixels).
  // If omitted, the type-default safe position is used.
  // The CALLER must choose a position that avoids faces and title text
  // (see safe-zone contract below).
  "position": { "x": 960, "y": 1800 },

  // OPTIONAL: brand palette — hex strings.
  // Defaults: accent=#6366F1, bg=rgba(255,255,255,0.93), fg=#1a1a2e
  "brand": {
    "accent": "#6366F1",
    "bg":     "rgba(255,255,255,0.93)",
    "fg":     "#1a1a2e"
  },

  // REQUIRED for pill / sticker:
  "text":  "See this →",   // pill CTA label   (pill)
  "icon":  "$0",           // large icon text  (sticker, default "$0")
  "label": "FREE",         // sub-label        (sticker, default "FREE")

  // OPTIONAL for flowchart:
  "nodes": ["Record", "Edit", "Post"],   // exactly 3 strings
  "caption": "your content workflow",

  // OPTIONAL for stat-card:
  "stat":   "10×",
  "stat_label": "faster"
}
```

### Minimal examples

```json
{ "type": "pill", "text": "Watch now" }
```

```json
{ "type": "sticker", "icon": "🔥", "label": "VIRAL" }
```

```json
{
  "type": "flowchart",
  "nodes": ["Capture", "Cook", "Post"],
  "caption": "your system"
}
```

```json
{
  "type": "stat-card",
  "stat": "2h",
  "stat_label": "saved per week",
  "brand": { "accent": "#10B981", "bg": "#F8F9FA", "fg": "#111827" }
}
```

## Safe-zone placement contract

The CALLER (reel core) is responsible for choosing a `position` that avoids:

1. **The avatar/face** — for HyperFrames split-reel (1080×1920): face is
   roughly x:220-860, y:1000-1700 (bottom half). Keep x>860 OR y<960 to be safe.
2. **The title text** — title occupies roughly y:120-460 of the top half.
   Keep cy > 500 when placing in the top half.
3. **The subtitle/seam** — keep cy < 900 when in the top half.

The component's DEFAULT positions (used when `position` is omitted) are
pre-validated for the standard HyperFrames split-reel layout:

| Element | Default cx | Default cy | Why safe |
|---|---|---|---|
| pill | 960 | 1800 | right of face (x>860), below face bottom (y>1700) |
| sticker | 920 | 680 | top-right, below title (y>500), above seam (y<960) |
| flowchart | 540 | 750 | centred top-half, below title, above seam |
| stat-card | 160 | 750 | top-left, below title, above seam |

For non-standard layouts, pass explicit `position` and verify against the
frame's safe-zone map before rendering at scale.

## ffmpeg composite recipe

```bash
# Basic composite (overlay appears at element's default anchor):
ffmpeg -i reel.mp4 \
  -framerate 30 -start_number 0 \
  -i "/tmp/overlay-frames/frame-%04d.png" \
  -filter_complex \
    "[0:v][1:v]overlay=0:0:format=auto:enable='between(t,START,END)'" \
  -c:a copy out-composite.mp4

# The overlay PNG sequence is already full-canvas (1080×1920) — use x=0,y=0.
# To start the overlay at t=5s: replace START/END above.
```
