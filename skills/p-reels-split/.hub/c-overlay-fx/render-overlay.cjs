#!/usr/bin/env node
/**
 * render-overlay.cjs — c-overlay-fx main CLI
 *
 * Renders a single animated overlay element as a transparent alpha PNG
 * sequence (RGBA, 1080×1920, 30fps, 2.5s = 75 frames).
 *
 * Usage:
 *   node render-overlay.cjs <element-spec.json> <out-dir>
 *
 * element-spec.json schema (see SKILL.md for full docs):
 * {
 *   "type":     "pill" | "sticker" | "flowchart" | "stat-card",
 *   "position": { "x": 960, "y": 1800 },           // optional, defaults by type
 *   "brand":    { "accent": "#6366F1", "bg": "rgba(255,255,255,0.93)", "fg": "#1a1a2e" },
 *   "text":     "Watch now",                         // pill: CTA label
 *   "icon":     "$0",                                // sticker: large icon
 *   "label":    "FREE",                              // sticker: sub-label
 *   "nodes":    ["Record","Edit","Post"],             // flowchart: 3 nodes
 *   "caption":  "your content workflow",             // flowchart: caption
 *   "stat":     "10×",                               // stat-card: number
 *   "stat_label": "faster"                           // stat-card: label
 * }
 *
 * Output:
 *   <out-dir>/frame-0000.png … frame-0074.png  (RGBA PNGs, true alpha)
 *   Prints PNGDIR=<out-dir> on stdout when complete.
 *
 * ffmpeg composite (caller):
 *   ffmpeg -i reel.mp4 \
 *     -framerate 30 -start_number 0 -i "<out-dir>/frame-%04d.png" \
 *     -filter_complex "[0:v][1:v]overlay=0:0:format=auto" \
 *     -c:a copy out.mp4
 *
 * Safe-zone placement contract:
 *   The CALLER must pass a position that avoids faces and title text.
 *   When position is omitted, default safe positions for the HyperFrames
 *   split-reel (1080×1920) are used (see SKILL.md for coordinates).
 */
'use strict';

const fs   = require('fs');
const path = require('path');
const { createCanvas } = require('canvas');
const illustrations    = require('./illustrations.cjs');

// ─── CLI args ─────────────────────────────────────────────────────────────────
const [,, specPath, outDir] = process.argv;
if (!specPath || !outDir) {
  process.stderr.write(
    'Usage: node render-overlay.cjs <element-spec.json> <out-dir>\n'
  );
  process.exit(1);
}

if (!fs.existsSync(specPath)) {
  process.stderr.write(`element-spec not found: ${specPath}\n`);
  process.exit(1);
}

let spec;
try {
  spec = JSON.parse(fs.readFileSync(specPath, 'utf8'));
} catch (e) {
  process.stderr.write(`Failed to parse element-spec: ${e.message}\n`);
  process.exit(1);
}

const VALID_TYPES = ['pill', 'sticker', 'flowchart', 'stat-card'];
if (!VALID_TYPES.includes(spec.type)) {
  process.stderr.write(
    `Unknown element type "${spec.type}". Valid: ${VALID_TYPES.join(', ')}\n`
  );
  process.exit(1);
}

fs.mkdirSync(outDir, { recursive: true });

// ─── Canvas constants ─────────────────────────────────────────────────────────
const W            = 1080;
const H            = 1920;
const FPS          = 30;
const DURATION     = 2.5;                        // seconds
const TOTAL_FRAMES = Math.ceil(DURATION * FPS);  // 75

// ─── Motion timing ────────────────────────────────────────────────────────────
const SLIDE_IN_DUR  = 0.375;
const WIGGLE_DUR    = 0.500;
const HOLD_DUR      = 1.250;
const SLIDE_OUT_DUR = 0.375;

// ─── Easing ──────────────────────────────────────────────────────────────────
function easeOutBack(t) {
  const c1 = 1.70158, c3 = c1 + 1;
  const tt = Math.max(0, Math.min(1, t));
  return 1 + c3 * Math.pow(tt - 1, 3) + c1 * Math.pow(tt - 1, 2);
}
function easeInBack(t) {
  const c1 = 1.70158, c3 = c1 + 1;
  const tt = Math.max(0, Math.min(1, t));
  return c3 * tt * tt * tt - c1 * tt * tt;
}

/**
 * Returns animation state at local time tLocal (0 … DURATION).
 * direction: 'left'|'right'|'up'|'down'  — the slide entry/exit edge.
 * slideAmount: px to travel.
 */
function motionState(tLocal, direction, slideAmount) {
  const slide    = slideAmount || 220;
  const SLIDE_END  = SLIDE_IN_DUR;
  const WIGGLE_END = SLIDE_END + WIGGLE_DUR;
  const HOLD_END   = WIGGLE_END + HOLD_DUR;

  if (tLocal < 0 || tLocal >= DURATION) return null;

  let offsetX = 0, offsetY = 0, rotation = 0, scale = 1.0, alpha = 1.0;

  if (tLocal < SLIDE_END) {
    const progress = tLocal / SLIDE_IN_DUR;
    const tNorm    = easeOutBack(progress);
    const raw      = (1 - Math.max(0, Math.min(1.05, tNorm))) * slide;
    switch (direction) {
      case 'left':  offsetX = -raw; break;
      case 'right': offsetX =  raw; break;
      case 'up':    offsetY =  raw; break;
      case 'down':  offsetY = -raw; break;
    }
    alpha = Math.min(1, progress * 2.5);

  } else if (tLocal < WIGGLE_END) {
    const τ     = tLocal - SLIDE_END;
    const decay = Math.exp(-8 * τ);
    const osc   = Math.sin(18 * τ);
    rotation    = 6.0 * decay * osc;    // 6°·e^(−8τ)·sin(18τ)
    offsetY     = -10 * decay * osc;   // bounceY

  } else if (tLocal < HOLD_END) {
    const holdT = tLocal - WIGGLE_END;
    scale       = 1.0 + 0.015 * Math.sin(2 * Math.PI * 1.2 * holdT);

  } else {
    const progress = (tLocal - HOLD_END) / SLIDE_OUT_DUR;
    const tNorm    = easeInBack(Math.min(progress, 1));
    const raw      = Math.max(0, tNorm) * slide;
    switch (direction) {
      case 'left':  offsetX = -raw; break;
      case 'right': offsetX =  raw; break;
      case 'up':    offsetY =  raw; break;
      case 'down':  offsetY = -raw; break;
    }
    alpha    = Math.max(0, 1 - progress * 1.3);
    rotation = 0;
  }

  return { offsetX, offsetY, rotation, scale, alpha };
}

// ─── Helper ──────────────────────────────────────────────────────────────────
function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.lineTo(x + w - r, y);
  ctx.quadraticCurveTo(x + w, y, x + w, y + r);
  ctx.lineTo(x + w, y + h - r);
  ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  ctx.lineTo(x + r, y + h);
  ctx.quadraticCurveTo(x, y + h, x, y + h - r);
  ctx.lineTo(x, y + r);
  ctx.quadraticCurveTo(x, y, x + r, y);
  ctx.closePath();
}

// ─── Brand palette ────────────────────────────────────────────────────────────
const brand = {
  accent: (spec.brand && spec.brand.accent) || '#6366F1',
  bg:     (spec.brand && spec.brand.bg)     || 'rgba(255,255,255,0.93)',
  fg:     (spec.brand && spec.brand.fg)     || '#1a1a2e',
};

// ─── Element draw functions ───────────────────────────────────────────────────

/**
 * PILL — white rounded-rect pill with accent left-bar + CTA text.
 * Default safe position: cx=960, cy=1800 (lower-right, beside face, x>860).
 * Slides in from RIGHT edge.
 */
function drawPill(ctx, tLocal, restX, restY) {
  const state = motionState(tLocal, 'right', 280);
  if (!state) return;
  const { offsetX, offsetY, rotation, scale, alpha } = state;

  const label     = spec.text    || 'See this →';
  const fontSize  = 34;
  const paddingH  = 36;
  const pillH     = 80;
  const cornerR   = 40;

  ctx.save();
  ctx.globalAlpha = Math.max(0, Math.min(1, alpha));
  ctx.translate(restX + offsetX, restY + offsetY);
  ctx.rotate((rotation * Math.PI) / 180);
  ctx.scale(scale, scale);

  ctx.font = `700 ${fontSize}px sans-serif`;
  const textW = ctx.measureText(label).width;
  const pillW = textW + paddingH * 2;
  const pillX = -pillW / 2;
  const pillY = -pillH / 2;

  // Drop shadow
  ctx.save();
  ctx.shadowColor = 'rgba(0,0,0,0.35)'; ctx.shadowBlur = 16; ctx.shadowOffsetY = 6;
  ctx.fillStyle = brand.bg;
  roundRect(ctx, pillX, pillY, pillW, pillH, cornerR);
  ctx.fill();
  ctx.restore();

  // Pill body
  ctx.fillStyle = brand.bg;
  roundRect(ctx, pillX, pillY, pillW, pillH, cornerR);
  ctx.fill();

  // Accent left-bar
  ctx.save();
  ctx.fillStyle = brand.accent;
  roundRect(ctx, pillX, pillY, 8, pillH, 4);
  ctx.fill();
  ctx.restore();

  // Border
  ctx.strokeStyle = `${brand.accent}40`; ctx.lineWidth = 1.5;
  roundRect(ctx, pillX, pillY, pillW, pillH, cornerR);
  ctx.stroke();

  // Label
  ctx.font = `700 ${fontSize}px sans-serif`;
  ctx.fillStyle = brand.fg;
  ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  ctx.fillText(label, 0, 0);

  ctx.restore();
}

/**
 * STICKER — coloured badge with large icon + sub-label.
 * Default safe position: cx=920, cy=680 (top-right, below title ~y:460).
 * Slides in from RIGHT edge.
 */
function drawSticker(ctx, tLocal, restX, restY) {
  const state = motionState(tLocal, 'right', 280);
  if (!state) return;
  const { offsetX, offsetY, rotation, scale, alpha } = state;

  const icon      = spec.icon  || '$0';
  const subLabel  = spec.label || 'FREE';

  ctx.save();
  ctx.globalAlpha = Math.max(0, Math.min(1, alpha));
  ctx.translate(restX + offsetX, restY + offsetY);
  ctx.rotate((rotation * Math.PI) / 180);
  ctx.scale(scale, scale);

  const bW = 160, bH = 160, bR = 28;
  const bX = -bW / 2, bY = -bH / 2;

  // Shadow
  ctx.save();
  ctx.shadowColor = 'rgba(0,0,0,0.40)'; ctx.shadowBlur = 20; ctx.shadowOffsetY = 8;
  ctx.fillStyle = brand.accent;
  roundRect(ctx, bX, bY, bW, bH, bR);
  ctx.fill();
  ctx.restore();

  // Gradient body (accent → darker)
  const grad = ctx.createLinearGradient(bX, bY, bX, bY + bH);
  grad.addColorStop(0, brand.accent);
  grad.addColorStop(1, brand.accent + 'CC');
  ctx.fillStyle = grad;
  roundRect(ctx, bX, bY, bW, bH, bR);
  ctx.fill();

  // Inner highlight ring
  ctx.strokeStyle = 'rgba(255,255,255,0.35)'; ctx.lineWidth = 2.5;
  roundRect(ctx, bX + 5, bY + 5, bW - 10, bH - 10, bR - 2);
  ctx.stroke();

  // Icon text
  ctx.font = '800 58px sans-serif'; ctx.fillStyle = '#FFFFFF';
  ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  ctx.fillText(icon, 0, -20);

  // Sub-label
  ctx.font = '700 28px sans-serif'; ctx.fillStyle = 'rgba(255,255,220,0.95)';
  ctx.fillText(subLabel, 0, 26);

  // Decorative stars
  ctx.font = '18px sans-serif'; ctx.fillStyle = 'rgba(255,255,255,0.7)';
  ctx.fillText('★', bX + 12, bY + 16);
  ctx.fillText('★', bX + bW - 28, bY + bH - 18);

  ctx.restore();
}

/**
 * FLOWCHART — horizontal 3-node mini-flowchart with arrows.
 * Default safe position: cx=540, cy=750 (top-half centre, below title y:460).
 * Slides DOWN from above.
 */
function drawFlowchart(ctx, tLocal, restX, restY) {
  const state = motionState(tLocal, 'down', 200);
  if (!state) return;
  const { offsetX, offsetY, rotation, scale, alpha } = state;

  const nodes   = (spec.nodes && spec.nodes.length === 3)
    ? spec.nodes
    : ['Record', 'Edit', 'Post'];
  const caption = spec.caption || 'your content workflow';
  const colors  = ['#6366F1', '#8B5CF6', '#10B981'];

  ctx.save();
  ctx.globalAlpha = Math.max(0, Math.min(1, alpha));
  ctx.translate(restX + offsetX, restY + offsetY);
  ctx.rotate((rotation * Math.PI) / 180);
  ctx.scale(scale, scale);

  const nodeW  = 130, nodeH = 60, nodeR = 14, gap = 28;
  const totalW = nodes.length * nodeW + (nodes.length - 1) * gap;
  const startX = -totalW / 2;
  const nodeY  = -nodeH / 2;
  const padX   = 20, padY = 16;

  // Background panel
  ctx.save();
  ctx.shadowColor = 'rgba(0,0,0,0.30)'; ctx.shadowBlur = 22; ctx.shadowOffsetY = 8;
  ctx.fillStyle = 'rgba(15,15,30,0.82)';
  roundRect(ctx, startX - padX, nodeY - padY, totalW + padX * 2, nodeH + padY * 2, 24);
  ctx.fill();
  ctx.restore();

  // Nodes
  for (let i = 0; i < nodes.length; i++) {
    const nx = startX + i * (nodeW + gap);

    ctx.save();
    ctx.shadowColor = 'rgba(0,0,0,0.25)'; ctx.shadowBlur = 10; ctx.shadowOffsetY = 4;
    ctx.fillStyle = colors[i];
    roundRect(ctx, nx, nodeY, nodeW, nodeH, nodeR);
    ctx.fill();
    ctx.restore();

    ctx.fillStyle = colors[i];
    roundRect(ctx, nx, nodeY, nodeW, nodeH, nodeR);
    ctx.fill();

    ctx.save();
    ctx.strokeStyle = 'rgba(255,255,255,0.3)'; ctx.lineWidth = 1.5;
    roundRect(ctx, nx + 2, nodeY + 2, nodeW - 4, nodeH - 4, nodeR - 1);
    ctx.stroke();
    ctx.restore();

    ctx.font = '700 28px sans-serif'; ctx.fillStyle = '#FFFFFF';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText(nodes[i], nx + nodeW / 2, 0);

    // Arrow to next node
    if (i < nodes.length - 1) {
      const arrowStartX = nx + nodeW + 4;
      const arrowEndX   = nx + nodeW + gap - 4;

      ctx.save();
      ctx.strokeStyle = 'rgba(255,255,255,0.65)'; ctx.lineWidth = 2.5; ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.moveTo(arrowStartX, 0);
      ctx.lineTo(arrowEndX - 8, 0);
      ctx.stroke();

      ctx.fillStyle = 'rgba(255,255,255,0.65)';
      ctx.beginPath();
      ctx.moveTo(arrowEndX, 0);
      ctx.lineTo(arrowEndX - 10, -5);
      ctx.lineTo(arrowEndX - 10,  5);
      ctx.closePath();
      ctx.fill();
      ctx.restore();
    }
  }

  // Caption
  ctx.font = '600 22px sans-serif'; ctx.fillStyle = 'rgba(255,255,255,0.55)';
  ctx.textAlign = 'center'; ctx.textBaseline = 'top';
  ctx.fillText(caption, 0, nodeH / 2 + 10);

  ctx.restore();
}

/**
 * STAT-CARD — white rounded card with large stat number + sub-label.
 * Default safe position: cx=160, cy=750 (top-left, below title, above seam).
 * Slides in from LEFT edge.
 */
function drawStatCard(ctx, tLocal, restX, restY) {
  const state = motionState(tLocal, 'left', 280);
  if (!state) return;
  const { offsetX, offsetY, rotation, scale, alpha } = state;

  const stat     = spec.stat       || '10×';
  const subLabel = spec.stat_label || 'faster';
  const cW       = 260, cH = 140;

  ctx.save();
  ctx.globalAlpha = Math.max(0, Math.min(1, alpha));
  ctx.translate(restX + offsetX, restY + offsetY);
  ctx.rotate((rotation * Math.PI) / 180);
  ctx.scale(scale, scale);

  // Shadow
  ctx.save();
  ctx.shadowColor = 'rgba(0,0,0,0.30)'; ctx.shadowBlur = 18; ctx.shadowOffsetY = 8;
  ctx.fillStyle = brand.bg;
  roundRect(ctx, -cW / 2, -cH / 2, cW, cH, 14);
  ctx.fill();
  ctx.restore();

  // Card body
  ctx.fillStyle = brand.bg;
  roundRect(ctx, -cW / 2, -cH / 2, cW, cH, 14);
  ctx.fill();

  // Accent top-bar
  ctx.fillStyle = brand.accent;
  roundRect(ctx, -cW / 2, -cH / 2, cW, 6, 3);
  ctx.fill();

  // Stat number
  ctx.font = '800 72px sans-serif'; ctx.fillStyle = brand.fg;
  ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  ctx.fillText(stat, 0, -18);

  // Sub-label
  ctx.font = '500 36px sans-serif'; ctx.fillStyle = '#6B7280';
  ctx.fillText(subLabel, 0, 40);

  ctx.restore();
}

// ─── Default safe positions ───────────────────────────────────────────────────
// Pre-validated for HyperFrames split-reel (1080×1920):
//   face region: x:220-860, y:1000-1700 (bottom half)
//   title region: y:120-460 (top half)
const DEFAULT_POSITIONS = {
  'pill':      { x: 960, y: 1800 },  // right of face, below face bottom
  'sticker':   { x: 920, y:  680 },  // top-right, below title
  'flowchart': { x: 540, y:  750 },  // top-half centre, below title
  'stat-card': { x: 160, y:  750 },  // top-left, below title
};

const pos    = spec.position || DEFAULT_POSITIONS[spec.type];
const restX  = pos.x;
const restY  = pos.y;

// ─── Element dispatch ─────────────────────────────────────────────────────────
const DRAW_FNS = {
  'pill':      drawPill,
  'sticker':   drawSticker,
  'flowchart': drawFlowchart,
  'stat-card': drawStatCard,
};
const drawFn = DRAW_FNS[spec.type];

// ─── Render loop ──────────────────────────────────────────────────────────────
const canvas = createCanvas(W, H);
const ctx    = canvas.getContext('2d');

process.stderr.write(
  `[c-overlay-fx] type=${spec.type} position=(${restX},${restY}) → ${TOTAL_FRAMES} frames @ ${FPS}fps → ${outDir}\n`
);
const t0 = Date.now();

for (let frame = 0; frame < TOTAL_FRAMES; frame++) {
  const tLocal = frame / FPS;

  // TRUE ALPHA: clearRect only — no drawBackground, no fillRect
  ctx.clearRect(0, 0, W, H);

  drawFn(ctx, tLocal, restX, restY);

  const buf       = canvas.toBuffer('image/png');
  const framePath = path.join(outDir, `frame-${String(frame).padStart(4, '0')}.png`);
  fs.writeFileSync(framePath, buf);

  if (frame % 15 === 0) {
    process.stderr.write(
      `  frame ${frame}/${TOTAL_FRAMES} (${((Date.now() - t0) / 1000).toFixed(1)}s)\n`
    );
  }
}

process.stderr.write(
  `[c-overlay-fx] Done — ${TOTAL_FRAMES} frames in ${((Date.now() - t0) / 1000).toFixed(1)}s\n`
);
process.stdout.write(`PNGDIR=${outDir}\n`);
