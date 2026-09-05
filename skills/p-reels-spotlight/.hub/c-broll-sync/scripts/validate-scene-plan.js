#!/usr/bin/env node
/**
 * c-broll-sync/scripts/validate-scene-plan.js
 *
 * Validator for the `scene_plan` directive contract (SCENE-PLAN.md, v1).
 * Zero dependencies — node only. Used two ways:
 *
 *   as a module   const { validateScenePlan, resolveAnchors } = require('./validate-scene-plan');
 *   as a CLI      node validate-scene-plan.js <scene_plan.json> [--bed-dur S] [--transcript words.json]
 *                 exit 0 = valid (warnings printed), exit 1 = invalid (errors printed), exit 2 = usage/IO
 *
 * The contract exists because a headless Director must author every card's copy
 * BEFORE any card is rendered — nothing else in the chain writes card text
 * (CFW-128 gap #1). A graphic scene with empty headline copy is therefore a
 * HARD error, never a warning: blank cards must never reach a render.
 */

'use strict';

const fs = require('fs');

const KINDS = new Set(['graphic', 'broll', 'avatar']);

// Tolerances (seconds)
const OVERLAP_TOL = 0.05;   // scenes may touch; > this = overlap
const GAP_TOL     = 0.25;   // uncovered time larger than this = gap
const END_TOL     = 0.25;   // last scene may miss/exceed bed_duration by this much

// Copy limits — a 1080×1920 card at the doctrine's ≥60 px type cannot hold more.
const MAX_HEADLINE_CHARS = 90;
const MAX_EYEBROW_CHARS  = 40;
const MAX_GHOST_CHARS    = 4;
const MIN_GRAPHIC_SECS   = 1.0;
const WARN_GRAPHIC_SECS  = 8.0;
const MAX_GRAPHIC_SECS   = 12.0;

// Only these tags may appear inside `headline` — anything else is rejected so a
// scene plan can never inject markup into the rendered card.
const ALLOWED_TAG_RE = /<\/?span(\s+class="accent")?\s*>|<br\s*\/?>/gi;

/** Plain-text length of a headline after stripping the allowed tags. */
function headlineText(h) {
  return String(h ?? '').replace(ALLOWED_TAG_RE, '').replace(/\s+/g, ' ').trim();
}

/** True if the headline contains any tag that is not in the allow-list. */
function hasDisallowedTag(h) {
  const stripped = String(h ?? '').replace(ALLOWED_TAG_RE, '');
  return /<[^>]*>/.test(stripped) || /[<>]/.test(stripped);
}

function isNum(v) { return typeof v === 'number' && Number.isFinite(v); }

/**
 * Find the start time of the first word-sequence in `words` that matches
 * `phrase` (case-insensitive, punctuation-insensitive, prefix match per word).
 * Returns { start, end } of the matched span, or null.
 */
function findPhrase(words, phrase) {
  const norm = (s) => String(s).toLowerCase().replace(/[^a-z0-9']+/g, '');
  const ph = String(phrase).trim().split(/\s+/).map(norm).filter(Boolean);
  if (ph.length === 0) return null;
  for (let i = 0; i + ph.length <= words.length; i++) {
    let ok = true;
    for (let j = 0; j < ph.length; j++) {
      const w = norm(words[i + j].text ?? words[i + j].word ?? '');
      if (!w.startsWith(ph[j])) { ok = false; break; }
    }
    if (ok) {
      return {
        start: parseFloat(words[i].start),
        end:   parseFloat(words[i + ph.length - 1].end),
      };
    }
  }
  return null;
}

/**
 * Resolve `start_phrase` / `end_phrase` anchors into numeric `start` / `end`
 * using a word-level transcript. Numeric fields already present win. Returns
 * a NEW plan object (input is not mutated) plus a list of resolution errors.
 */
function resolveAnchors(plan, words) {
  const errors = [];
  const out = JSON.parse(JSON.stringify(plan));
  const scenes = Array.isArray(out.scenes) ? out.scenes : [];
  scenes.forEach((s, i) => {
    const label = `scene ${i}${s.id ? ` (${s.id})` : ''}`;
    if (!isNum(s.start) && typeof s.start_phrase === 'string') {
      if (!Array.isArray(words)) { errors.push(`${label}: start_phrase needs a transcript to resolve`); return; }
      const m = findPhrase(words, s.start_phrase);
      if (!m) errors.push(`${label}: start_phrase "${s.start_phrase}" not found in transcript`);
      else s.start = m.start;
    }
    if (!isNum(s.end) && typeof s.end_phrase === 'string') {
      if (!Array.isArray(words)) { errors.push(`${label}: end_phrase needs a transcript to resolve`); return; }
      const m = findPhrase(words, s.end_phrase);
      if (!m) errors.push(`${label}: end_phrase "${s.end_phrase}" not found in transcript`);
      // end_phrase marks the FIRST word of the NEXT scene → this scene ends where it starts
      else s.end = m.start;
    }
  });
  // Chain: a scene without `end` ends where the next scene starts; the last one at bed_duration.
  for (let i = 0; i < scenes.length; i++) {
    const s = scenes[i];
    if (!isNum(s.end)) {
      if (i + 1 < scenes.length && isNum(scenes[i + 1].start)) s.end = scenes[i + 1].start;
      else if (isNum(out.bed_duration)) s.end = out.bed_duration;
    }
    if (!isNum(s.start) && i > 0 && isNum(scenes[i - 1].end)) s.start = scenes[i - 1].end;
    if (!isNum(s.start) && i === 0) s.start = 0;
  }
  return { plan: out, errors };
}

/**
 * Validate a resolved scene plan. Returns { ok, errors[], warnings[] }.
 * `opts.bedDuration` (seconds) enables the coverage check.
 */
function validateScenePlan(plan, opts = {}) {
  const errors = [];
  const warnings = [];
  const bed = isNum(opts.bedDuration) ? opts.bedDuration
            : (plan && isNum(plan.bed_duration) ? plan.bed_duration : null);

  if (!plan || typeof plan !== 'object' || Array.isArray(plan)) {
    return { ok: false, errors: ['scene_plan must be a JSON object { version: 1, scenes: [...] }'], warnings };
  }
  if (plan.version !== 1) errors.push(`version must be 1 (got ${JSON.stringify(plan.version)})`);
  if (!Array.isArray(plan.scenes) || plan.scenes.length === 0) {
    errors.push('scenes must be a non-empty array');
    return { ok: false, errors, warnings };
  }

  const scenes = plan.scenes;
  scenes.forEach((s, i) => {
    const label = `scene ${i}${s && s.id ? ` (${s.id})` : ''}`;
    if (!s || typeof s !== 'object') { errors.push(`${label}: not an object`); return; }
    if (!KINDS.has(s.kind)) errors.push(`${label}: kind must be one of graphic|broll|avatar (got ${JSON.stringify(s.kind)})`);
    if (!isNum(s.start)) errors.push(`${label}: start must be a number (or a resolvable start_phrase)`);
    if (!isNum(s.end))   errors.push(`${label}: end must be a number (or a resolvable end_phrase)`);
    if (isNum(s.start) && isNum(s.end)) {
      if (s.start < 0) errors.push(`${label}: start < 0`);
      if (s.end <= s.start) errors.push(`${label}: end (${s.end}) must be > start (${s.start})`);
    }
    if (s.kind === 'graphic') {
      const text = headlineText(s.headline);
      if (!text) {
        errors.push(`${label} [${fmt(s.start)}–${fmt(s.end)}]: graphic scene has EMPTY headline copy — every card needs copy; never emit blank cards`);
      } else {
        if (hasDisallowedTag(s.headline)) errors.push(`${label}: headline may only contain <span class="accent">…</span> and <br> tags`);
        if (text.length > MAX_HEADLINE_CHARS) errors.push(`${label}: headline is ${text.length} chars (max ${MAX_HEADLINE_CHARS}) — split the beat or shorten`);
      }
      if (s.eyebrow != null && String(s.eyebrow).length > MAX_EYEBROW_CHARS) errors.push(`${label}: eyebrow > ${MAX_EYEBROW_CHARS} chars`);
      if (s.ghost != null && String(s.ghost).length > MAX_GHOST_CHARS) errors.push(`${label}: ghost > ${MAX_GHOST_CHARS} chars (use a number or a single letter/word-mark)`);
      if (isNum(s.start) && isNum(s.end)) {
        const d = s.end - s.start;
        if (d < MIN_GRAPHIC_SECS) errors.push(`${label}: graphic scene is ${d.toFixed(2)} s (min ${MIN_GRAPHIC_SECS} s)`);
        else if (d > MAX_GRAPHIC_SECS) errors.push(`${label}: graphic scene is ${d.toFixed(1)} s (max ${MAX_GRAPHIC_SECS} s) — one card cannot hold that window; split it`);
        else if (d > WARN_GRAPHIC_SECS) warnings.push(`${label}: graphic scene is ${d.toFixed(1)} s (> ${WARN_GRAPHIC_SECS} s reads long — consider splitting)`);
      }
    } else if (s.kind === 'broll') {
      if (typeof s.asset !== 'string' || !s.asset.trim()) errors.push(`${label}: broll scene needs a non-empty asset (clip filename/label from BROLL_JSON or a local path)`);
      if (s.in != null && (!isNum(s.in) || s.in < 0)) errors.push(`${label}: in must be a number >= 0`);
    }
  });

  // Ordering / overlap / gaps / coverage — only meaningful if timings are numeric
  const timed = scenes.filter(s => s && isNum(s.start) && isNum(s.end));
  for (let i = 1; i < timed.length; i++) {
    const a = timed[i - 1], b = timed[i];
    if (b.start < a.start) { errors.push(`scenes must be sorted by start (scene ${scenes.indexOf(b)} starts before scene ${scenes.indexOf(a)})`); continue; }
    if (b.start < a.end - OVERLAP_TOL) errors.push(`scene ${scenes.indexOf(a)} and scene ${scenes.indexOf(b)} overlap (${fmt(b.start)} < ${fmt(a.end)})`);
    else if (b.start > a.end + GAP_TOL) errors.push(`gap of ${(b.start - a.end).toFixed(2)} s between scene ${scenes.indexOf(a)} (ends ${fmt(a.end)}) and scene ${scenes.indexOf(b)} (starts ${fmt(b.start)}) — coverage must be gapless`);
  }
  if (timed.length > 0) {
    if (timed[0].start > GAP_TOL) errors.push(`first scene starts at ${fmt(timed[0].start)} — the plan must start at 0`);
    if (bed != null) {
      const last = timed[timed.length - 1];
      if (last.end < bed - END_TOL) errors.push(`last scene ends at ${fmt(last.end)} but bed_duration is ${fmt(bed)} — the plan must cover the whole bed`);
      if (last.end > bed + END_TOL) errors.push(`last scene ends at ${fmt(last.end)}, past bed_duration ${fmt(bed)}`);
    }
  }
  if (bed == null) warnings.push('bed_duration unknown — coverage of the full bed not checked');

  return { ok: errors.length === 0, errors, warnings };
}

function fmt(n) { return isNum(n) ? n.toFixed(2) : String(n); }

module.exports = { validateScenePlan, resolveAnchors, findPhrase, headlineText, hasDisallowedTag,
  LIMITS: { MAX_HEADLINE_CHARS, MAX_EYEBROW_CHARS, MAX_GHOST_CHARS, MIN_GRAPHIC_SECS, WARN_GRAPHIC_SECS, MAX_GRAPHIC_SECS, GAP_TOL, OVERLAP_TOL, END_TOL } };

// ─── CLI ─────────────────────────────────────────────────────────────────────
if (require.main === module) {
  const argv = process.argv.slice(2);
  let file = null, bedDur = null, transcriptPath = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--bed-dur') bedDur = parseFloat(argv[++i]);
    else if (argv[i] === '--transcript') transcriptPath = argv[++i];
    else if (argv[i] === '-h' || argv[i] === '--help') { console.log('usage: validate-scene-plan.js <scene_plan.json> [--bed-dur S] [--transcript words.json]'); process.exit(0); }
    else file = argv[i];
  }
  if (!file) { console.error('usage: validate-scene-plan.js <scene_plan.json> [--bed-dur S] [--transcript words.json]'); process.exit(2); }
  let plan;
  try { plan = JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (e) { console.error(`[scene_plan] cannot read ${file}: ${e.message}`); process.exit(2); }
  let words = null;
  if (transcriptPath) {
    try { words = JSON.parse(fs.readFileSync(transcriptPath, 'utf8')); }
    catch (e) { console.error(`[scene_plan] cannot read transcript ${transcriptPath}: ${e.message}`); process.exit(2); }
  }
  const r = resolveAnchors(plan, words);
  const v = validateScenePlan(r.plan, { bedDuration: bedDur });
  const errors = [...r.errors, ...v.errors];
  for (const w of v.warnings) console.warn(`[scene_plan] WARN: ${w}`);
  if (errors.length) {
    for (const e of errors) console.error(`[scene_plan] ERROR: ${e}`);
    console.error(`[scene_plan] INVALID — ${errors.length} error(s). Fix the plan; do NOT render blank cards.`);
    process.exit(1);
  }
  console.log(`[scene_plan] OK — ${r.plan.scenes.length} scenes${bedDur ? ` covering ${bedDur}s` : ''}`);
}
