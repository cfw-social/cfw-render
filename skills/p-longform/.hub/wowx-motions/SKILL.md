---
name: wowx-motions
description: Apply a cinematic camera MOTION to a B-roll video clip — push-in/focus, pull-out, pans, ken-burns, plus pseudo-3D tilt, orbit, and idle sway. Use when an agent needs to make flat/static B-roll feel alive and premium. One command, pure FFmpeg (no browser/GPU/3D), works on any aspect ratio/fps, preserves audio, fully deterministic. Trigger on "add motion to this b-roll", "ken burns this clip", "make this footage cinematic", "punch in / zoom in on this video", "pan across this clip", "tilt / orbit this clip", "animate this still/clip".
---


# wowx-motions

A unified camera-motion library an AI agent can fire on arbitrary footage. Pick a motion, get a
clip with a smooth, eased camera move. Two render backends, both pure FFmpeg:

- **ZOOM (in-frame 2D)** — animated `scale`+`crop`, sub-pixel smooth (not the juddery `zoompan`).
- **WARP (in-frame pseudo-3D)** — `perspective` corner-pinning, gap-free via a built-in base inset.
- **STAGE (the TiltIt look)** — floats the footage as a rounded, shadowed **3D card on a
  background** (green screen by default, or transparent) and orbits/swoops/pushes a virtual
  camera around it.

```bash
python3 wowx_motion.py INPUT --motion <name> [OUTPUT] [options]
python3 wowx_motion.py --list
```
If OUTPUT is omitted it writes `INPUT.<motion>.mp4`.

## Motions

| Motion | Backend | What it does | Good for |
|--------|---------|--------------|----------|
| `push-in` (alias `focus`) | zoom | slow eased zoom-in + subtle L→R drift | the default; any cutaway |
| `pull-out` | zoom | slow zoom-out reveal | openers / establishing |
| `pan-left` `pan-right` | zoom | zoomed horizontal pan | wide scenes, landscapes |
| `pan-up` `pan-down` | zoom | zoomed vertical pan | tall subjects, reveals |
| `ken-burns` | zoom | diagonal zoom + drift (the classic) | photos, screenshots |
| `tilt-back` | warp | plane leans away at the top (pseudo-3D) | tech/product, "3D" feel |
| `tilt-forward` | warp | plane leans toward you at the top | same, opposite lean |
| `orbit` | warp | gentle Y-axis rocking "orbit" of a flat plane | hero shots, logos |
| `sway` | warp | slow idle float — keeps a near-static shot alive | backgrounds, holds |
| `card-orbit` | **stage** | card floats on bg, rocks around vertical axis + parallax | the TiltIt hero look |
| `card-swoop` | **stage** | card starts tilted+small, dollies in to flatter+bigger | dramatic intros |
| `card-focus` | **stage** | clean cinematic push-in toward the floating card | talking-head B-roll |
| `card-glide` | **stage** | card slides across the frame with a constant 3D tilt | lower-thirds, motion |

### STAGE options (only apply to `card-*` motions)
| Flag | Default | Meaning |
|------|---------|---------|
| `--background`, `--bg` | `0x00FF00` | canvas bg: hex colour (green screen) or `transparent` (→ `.mov` ProRes4444 / `.webm` VP9) |
| `--canvas` | `1920x1080` | output canvas WxH |
| `--card-scale` | `0.76` | card height as a fraction of the canvas (≈76%) |
| `--corner-radius` | `0.05` | rounded-corner radius (fraction of card's short side; `0` = sharp) |
| `--shadow` / `--no-shadow` | on | drop shadow behind the card |
| `--intensity` | `1.0` | motion strength 0..1.5 |

```bash
python3 wowx_motion.py avatar.mp4 -m card-orbit                      # green screen, the default
python3 wowx_motion.py avatar.mp4 -m card-swoop --background transparent
python3 wowx_motion.py avatar.mp4 -m card-focus --bg 0x101018 --card-scale 0.8 --intensity 1.3
python3 wowx_motion.py avatar.mp4 -m card-orbit --no-shadow --corner-radius 0   # flat/sharp
```

## Options
| Flag | Applies to | Default | Meaning |
|------|-----------|---------|---------|
| `--motion, -m` | all | `push-in` | which motion (see table / `--list`) |
| `--amount` | ZOOM | per-preset (~0.14–0.20) | zoom travel fraction (0.18 = to 118%) |
| `--intensity` | WARP | `1.0` | warp strength 0..1.5 |
| `--drift-x` / `--drift-y` | ZOOM | per-preset | extra focal sweep (turn) |
| `--crf` | all | `18` | x264 quality (lower = better) |
| `--preset` | all | `medium` | x264 speed/size preset |
| `--print-filter` | all | — | print the ffmpeg filtergraph, no render |
| `--list` | — | — | list motions and exit |

## Recipes
```bash
python3 wowx_motion.py broll.mp4 -m push-in                 # default tasteful push-in
python3 wowx_motion.py broll.mp4 -m pull-out --amount 0.22  # bigger reveal
python3 wowx_motion.py broll.mp4 -m pan-right               # sweep across a wide shot
python3 wowx_motion.py broll.mp4 -m ken-burns               # classic photo motion
python3 wowx_motion.py broll.mp4 -m orbit --intensity 0.8   # subtle product-style orbit
python3 wowx_motion.py broll.mp4 -m tilt-back               # leans the frame back in 3D
python3 wowx_motion.py logo_hold.mp4 -m sway                # keep a static hold alive
```

## How an agent should choose
1. **Unsure / generic cutaway →** `push-in`. It's safe on 100% of footage.
2. **Opener / establishing →** `pull-out` (reveal) or `orbit` for a hero.
3. **Wide or tall composition →** `pan-*` toward the interesting side.
4. **Photo or screenshot →** `ken-burns`.
5. **Near-static shot that feels dead →** `sway`.
6. Keep `--amount` ≤ 0.25 and `--intensity` ≤ 1.0 unless the brief asks for drama — over-doing it
   softens the image (zoom) or looks rubbery (warp).
7. **Don't** stack motion on footage that already has strong camera movement.

## Honest scope (important)
The WARP motions (`tilt-*`, `orbit`, `sway`) are **2D perspective approximations** — they corner-pin
a flat frame to fake foreshortening. They read convincingly on flat B-roll, but they are **not** a
true volumetric orbit/tilt with real depth, parallax, lighting, and reflections.

A *true* 3D orbit/tilt (the TiltIt look: footage on a 3D plane, HDRI reflections, a real camera
circling it) requires the **Wowx 3D engine** (React Three Fiber + WebGL). That is the roadmap path,
not something pure FFmpeg can do. See `/Users/vasanth/Code/Wowx/05-implementation-plan.md`.

When the 3D engine exists, these same motion names map onto real R3F camera paths — the registry and
the eased-parameter math in `wowx_motion.py` are the spec for that port.

## Requirements
`ffmpeg` + `ffprobe` on PATH (full build recommended), `python3`. No other dependencies.
Output: H.264 yuv420p MP4 with `+faststart`; audio stream-copied untouched.
