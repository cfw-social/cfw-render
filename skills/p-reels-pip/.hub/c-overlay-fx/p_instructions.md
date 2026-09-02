# c-overlay-fx — authoring overlay beats

> Plain-language guide for choosing and placing overlay elements in a reel.
> The renderer (`render-overlay.cjs`) takes an element-spec JSON; this file
> is how you *think* your way to that spec.

## The method

1. **Describe the moment, then the element.** Say what's on screen at that
   beat (avatar talking, title visible, stat point just made), then decide
   what overlay *reinforces* that moment.
2. **One element per beat.** Each spec renders a single element. Stack two
   composites if you want two overlays at different times.
3. **Choose the element type by function:**
   - **pill** — CTA / "watch now" / "link in bio" prompt (lower-right margin)
   - **sticker** — price badge / "free" / bold claim (top-right corner)
   - **flowchart** — 3-step system / process / workflow (top-half centre)
   - **stat-card** — a number that proves the point (top-left)
4. **Trust the motion** — all types use the same slide-in→wiggle→hold→slide-out
   envelope. The physics (6°·e^(−8τ)·sin(18τ)) is baked in. Don't fight it
   with weird timing — just pick the right type.
5. **Brand it or leave defaults.** Pass `brand.accent` to match the brand
   colour. The default palette (indigo #6366F1) is safe for any dark reel.

## Worked examples

### A "link in bio" CTA after a key stat

> "At 12s, after the avatar says 'that saved me 2 hours', slide in a pill
> that says 'See how →' in the lower-right. Brand accent = emerald."

```json
{
  "type": "pill",
  "text": "See how →",
  "brand": { "accent": "#10B981" }
}
```

Then `ffmpeg … -enable='between(t,12,14.5)'`.

### A "free" sticker for a tool reveal

> "While the avatar names the free tool, badge the top-right with a $0 FREE
> sticker. Brand accent = orange."

```json
{
  "type": "sticker",
  "icon": "$0",
  "label": "FREE",
  "brand": { "accent": "#FF6B00" }
}
```

### A 3-step workflow flowchart

> "At the 'here's the system' moment, drop a mini-flowchart across the
> top half showing the 3 steps."

```json
{
  "type": "flowchart",
  "nodes": ["Capture", "Cook", "Post"],
  "caption": "your content system"
}
```

### A stat card proving ROI

> "Cut to the stat — '2h saved per week' — and underline it with a card."

```json
{
  "type": "stat-card",
  "stat": "2h",
  "stat_label": "saved per week",
  "brand": { "accent": "#10B981", "bg": "#F8F9FA", "fg": "#111827" }
}
```

## Safe-zone map for HyperFrames split-reel (1080×1920)

```
┌─────────────────── 1080 ───────────────────────┐
│  Title text zone (y: 120–460)                  │  ← AVOID placing here
│                                                │
│  SAFE BAND (y: 500–920) ← flowchart / stat    │
│     sticker cx=920,cy=680  ┐                  │
│     flowchart cx=540,cy=750├ top-half options  │
│     stat-card cx=160,cy=750┘                  │
│─────────────────── SEAM (y:960) ───────────────│
│  Avatar face: x:220-860, y:1000-1700           │  ← AVOID
│                                             px:│
│              pill cx=960,cy=1800   ────────►   │  ← SAFE (x>860)
└────────────────────────────────────────────────┘
```

**Rule of thumb:** sticker/flowchart/stat-card → top half (y<900).
Pill → right margin beside face (x>860, y>1750). Default positions are
pre-validated for this layout — pass explicit `position` only when your
reel has a non-standard layout.

## Motion timing reference

```
0.000 ─ slide-in starts (easeOutBack, 280px travel)
0.375 ─ wiggle starts (6° rotation, −10px bounce, damps at e^−8)
0.875 ─ hold starts (1.5% scale breathe @ 1.2 Hz)
2.125 ─ slide-out starts (easeInBack, fades out)
2.500 ─ done
```

Total = 2.5 s / 75 frames. Composite duration = 2.5 s at the beat's
`start` time. The ffmpeg `enable='between(t,START,START+2.5)'` gate is
the caller's responsibility.
