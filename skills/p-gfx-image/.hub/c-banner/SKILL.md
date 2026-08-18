---
name: c-banner
description: Render a pixel-perfect social/platform banner (YouTube channel art, LinkedIn/Facebook cover) from brand style — HTML through headless Chrome, cropped to exact platform dimensions, compressed under the platform size limit. Reusable component invoked by image recipes; not an owner-facing pipeline.
when_to_use: Trigger on c-banner, render banner, YouTube banner, channel art, LinkedIn banner, Facebook cover, platform banner, header image, cover image.
allowed-tools: Bash, Read, Write
kind: component
visibility: internal
requires: ffmpeg, chromium
dependsOn: [c-html-gfx, c-ffmpeg]
---


# c-banner — Platform Banner Rendering

HTML → headless Chrome screenshot → crop to exact spec → compress. The single
building block for any platform banner. Recipes call this with a brand + platform
and (optionally) a primary message; this component owns the render mechanics.

## Inputs

| Input | Required | Default | Notes |
|-------|----------|---------|-------|
| platform | Yes | — | `youtube`, `linkedin`, or `facebook` |
| message | No | brand tagline | Primary banner copy (1–5 words) |
| style | No | brand-ref.md | Colors, fonts, background treatment |

## Platform Specs

| Platform | Full Size | Safe Zone | Max File |
|----------|-----------|-----------|----------|
| YouTube  | 2560x1440 | 1546x423 centered | 6 MB |
| LinkedIn | 1584x396  | full (no safe zone) | 4 MB |
| Facebook | 820x312   | full | 2 MB |

## Steps

### 1 — Plan layout
Read `brand-ref.md` for colors, fonts, and any existing banner style. Decide the
primary message (1–5 words), logo position, and background (gradient / solid /
image). For YouTube, keep ALL key content inside the 1546x423 centered safe zone.

### 2 — Render HTML → screenshot
→ LOAD: `c-html-gfx` — author the banner HTML (`<meta charset="UTF-8">` required;
  system font stack or Google Fonts CDN) at the platform's full size, then
  screenshot via headless Chrome with `--window-size={width}x{height+140}` and
  crop to the exact target dimensions. Run a Unicode check post-render.

### 3 — Verify dimensions
→ `ffprobe` (or `identify`) must report the EXACT platform pixel dimensions before
  proceeding. A wrong-size banner is a hard fail, not a warning.

### 4 — Compress
→ LOAD: `c-ffmpeg` — JPEG encode at `-q:v 2`; verify the output is under the
  platform's max file size. Re-encode at a higher q if over.

### 5 — Output
Deliver as `final/ls-bnr01-{platform}-{desc}.jpg`. Return the path.
