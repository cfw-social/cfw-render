'use strict';
/**
 * illustrations.cjs
 * Draw helpers for complex overlay element types (flowchart, org-chart,
 * stat-card, agent-grid). All draw functions receive a canvas 2D context
 * already translated/scaled to the element centre — they draw around (0,0).
 *
 * Exported: drawParallelLanes, drawOrgChart, drawStatCard, drawAgentGrid
 */

const FONT = 'sans-serif'; // caller can override via registerFont + SAFE_FONT

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

function shadow(ctx, fn, opts) {
  const { blur = 18, offsetY = 8, alpha = 0.16 } = opts || {};
  ctx.save();
  ctx.shadowColor   = `rgba(31,24,21,${alpha})`;
  ctx.shadowBlur    = blur;
  ctx.shadowOffsetX = 0;
  ctx.shadowOffsetY = offsetY;
  fn(ctx);
  ctx.restore();
}

const breathe = (t, freq, amp) => 1 + Math.sin(t * (freq || 1.2)) * (amp || 0.012);

/**
 * drawParallelLanes — mini-flowchart (horizontal lane nodes → merged result).
 * props: { lanes: string[], result: string, scale?: number }
 */
function drawParallelLanes(ctx, t, props) {
  const lanes  = props.lanes  || ['Task A', 'Task B', 'Task C'];
  const n      = lanes.length;
  const laneW  = 120, laneH = 70, gx = 28;
  const totalW = n * laneW + (n - 1) * gx;
  const ox     = -totalW / 2;
  const laneY  = -90;
  const arrowY = laneY + laneH + 10;
  const resultY = arrowY + 40;

  ctx.save();
  ctx.scale(breathe(t, 0.8) * (props.scale || 1), breathe(t, 0.8) * (props.scale || 1));

  const colors = ['rgba(37,99,235,0.7)', 'rgba(124,58,237,0.7)', 'rgba(5,150,105,0.7)'];

  for (let i = 0; i < n; i++) {
    const x = ox + i * (laneW + gx);
    shadow(ctx, (sCtx) => {
      sCtx.beginPath(); roundRect(sCtx, x, laneY, laneW, laneH, 10);
      sCtx.fillStyle = colors[i % colors.length]; sCtx.fill();
    });
    ctx.beginPath(); roundRect(ctx, x, laneY, laneW, laneH, 10);
    ctx.fillStyle = colors[i % colors.length]; ctx.fill();
    ctx.font = `600 38px ${FONT}`; ctx.fillStyle = '#FFFFFF';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText(lanes[i], x + laneW / 2, laneY + laneH / 2);

    // Arrow down
    const ax = x + laneW / 2;
    ctx.beginPath();
    ctx.moveTo(ax, arrowY);
    ctx.lineTo(ax, arrowY + 24);
    ctx.lineTo(ax - 8, arrowY + 14);
    ctx.moveTo(ax, arrowY + 24);
    ctx.lineTo(ax + 8, arrowY + 14);
    ctx.strokeStyle = 'rgba(255,255,255,0.5)'; ctx.lineWidth = 2.5; ctx.stroke();
  }

  // Result node
  const rw = 200, rh = 52, rx = -rw / 2;
  shadow(ctx, (sCtx) => {
    sCtx.beginPath(); roundRect(sCtx, rx, resultY, rw, rh, 10);
    sCtx.fillStyle = 'rgba(5,150,105,0.8)'; sCtx.fill();
  });
  ctx.beginPath(); roundRect(ctx, rx, resultY, rw, rh, 10);
  ctx.fillStyle = 'rgba(16,185,129,0.85)'; ctx.fill();
  ctx.font = `700 40px ${FONT}`; ctx.fillStyle = '#FFFFFF';
  ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  ctx.fillText(props.result || 'Result', 0, resultY + rh / 2);

  ctx.restore();
}

/**
 * drawOrgChart — root node + child nodes with bezier connectors.
 * props: { root: string, children: string[], scale?: number }
 */
function drawOrgChart(ctx, t, props) {
  const root     = props.root     || 'CEO';
  const children = props.children || ['Eng', 'Mktg', 'Sales'];
  const rw = 160, rh = 56, cr = 10;
  const cw = 120, ch = 50, gx = 24;
  const rootY  = -140;
  const childY = rootY + rh + 60;
  const totalChildW = children.length * cw + (children.length - 1) * gx;

  ctx.save();
  ctx.scale(breathe(t, 0.6) * (props.scale || 1), breathe(t, 0.6) * (props.scale || 1));

  // Root node
  shadow(ctx, s => {
    s.beginPath(); roundRect(s, -rw / 2, rootY, rw, rh, cr);
    s.fillStyle = 'rgba(37,99,235,0.85)'; s.fill();
  });
  ctx.beginPath(); roundRect(ctx, -rw / 2, rootY, rw, rh, cr);
  ctx.fillStyle = 'rgba(59,130,246,0.9)'; ctx.fill();
  ctx.font = `700 42px ${FONT}`; ctx.fillStyle = '#FFFFFF';
  ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  ctx.fillText(root, 0, rootY + rh / 2);

  // Bezier connectors
  children.forEach((child, i) => {
    const cx2 = -totalChildW / 2 + i * (cw + gx) + cw / 2;
    ctx.beginPath();
    ctx.moveTo(0, rootY + rh);
    ctx.bezierCurveTo(0, rootY + rh + 20, cx2, childY - 20, cx2, childY);
    ctx.strokeStyle = 'rgba(147,197,253,0.5)'; ctx.lineWidth = 2; ctx.stroke();
  });

  // Child nodes
  children.forEach((child, i) => {
    const cx2 = -totalChildW / 2 + i * (cw + gx);
    shadow(ctx, s => {
      s.beginPath(); roundRect(s, cx2, childY, cw, ch, 8);
      s.fillStyle = 'rgba(30,58,138,0.8)'; s.fill();
    });
    ctx.beginPath(); roundRect(ctx, cx2, childY, cw, ch, 8);
    ctx.fillStyle = 'rgba(37,99,235,0.65)'; ctx.fill();
    ctx.font = `600 38px ${FONT}`; ctx.fillStyle = '#FFFFFF';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText(child, cx2 + cw / 2, childY + ch / 2);
  });

  ctx.restore();
}

/**
 * drawStatCard — white card with large stat number + secondary label.
 * props: { stat: string, label: string, scale?: number }
 */
function drawStatCard(ctx, t, props) {
  const stat  = props.stat  || '10×';
  const label = props.label || 'faster';
  const cw    = 260, ch = 140;
  const scale = breathe(t) * (props.scale || 1);

  ctx.save();
  ctx.scale(scale, scale);

  shadow(ctx, (sCtx) => {
    sCtx.beginPath(); roundRect(sCtx, -cw / 2, -ch / 2, cw, ch, 14);
    sCtx.fillStyle = '#F8F9FA'; sCtx.fill();
  });
  ctx.beginPath(); roundRect(ctx, -cw / 2, -ch / 2, cw, ch, 14);
  ctx.fillStyle = '#F8F9FA'; ctx.fill();

  ctx.font = `800 72px ${FONT}`; ctx.fillStyle = '#111827';
  ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  ctx.fillText(stat, 0, -18);

  ctx.font = `500 40px ${FONT}`; ctx.fillStyle = '#6B7280';
  ctx.fillText(label, 0, 40);

  ctx.restore();
}

/**
 * drawAgentGrid — 3×2 grid of agent cards (for multi-agent demos).
 * props: { labels: string[], scale?: number }
 */
function drawAgentGrid(ctx, t, props) {
  const cols   = 3, rows = 2;
  const cw     = 88, ch = 60, gx = 24, gy = 20;
  const totalW = cols * cw + (cols - 1) * gx;
  const totalH = rows * ch + (rows - 1) * gy;
  const ox     = -totalW / 2, oy = -totalH / 2;
  const labels = props.labels || ['Agent 1', 'Agent 2', 'Agent 3', 'Agent 4', 'Agent 5', 'Agent 6'];
  const scale  = breathe(t) * (props.scale || 1);

  ctx.save();
  ctx.scale(scale, scale);

  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      const idx = r * cols + c;
      const x   = ox + c * (cw + gx);
      const y   = oy + r * (ch + gy);

      shadow(ctx, (sCtx) => {
        sCtx.beginPath(); roundRect(sCtx, x, y, cw, ch, 10);
        sCtx.fillStyle = 'rgba(30,58,138,0.85)'; sCtx.fill();
      });
      ctx.beginPath(); roundRect(ctx, x, y, cw, ch, 10);
      ctx.fillStyle = 'rgba(37,99,235,0.7)'; ctx.fill();
      ctx.strokeStyle = 'rgba(147,197,253,0.3)'; ctx.lineWidth = 1.5; ctx.stroke();

      ctx.font = `600 34px ${FONT}`; ctx.fillStyle = '#FFFFFF';
      ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      let txt    = labels[idx] || `A${idx + 1}`;
      const maxW = cw - 12;
      while (ctx.measureText(txt).width > maxW && txt.length > 1) {
        txt = txt.slice(0, -1) + '…';
      }
      ctx.fillText(txt, x + cw / 2, y + ch / 2);
    }
  }

  ctx.restore();
}

module.exports = { drawParallelLanes, drawOrgChart, drawStatCard, drawAgentGrid };
