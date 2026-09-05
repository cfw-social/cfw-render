#!/usr/bin/env node
/**
 * c-broll-sync/scripts/plan.js
 *
 * Transcript-matched b-roll beat planner.
 *
 * Outputs beat_list.json — an ordered array of beats tagged
 *   { kind: "broll", broll: { clip, in, out, match_score, match_reason } }
 *   { kind: "graphics", scene: { eyebrow, ghost, title_html, brand } }
 *
 * The coverage budget is computed mechanically here.
 * For transcript-match order, an OPUS sub-call decides WHICH moments get b-roll
 * (but never the budget number).
 * For as-given / even order, placement is fully mechanical — no LLM call.
 *
 * Usage:
 *   node plan.js \
 *     --transcript path/to/words.json \
 *     --broll      path/to/broll_cues.json \
 *     --coverage   30 \
 *     --clip-secs  4 \
 *     --min-secs   2 \
 *     --max-secs   6 \
 *     --order      transcript-match \
 *     --reuse      false \
 *     --bed-dur    42.3 \
 *     --brand      path/to/brand.json \
 *     --scene-plan path/to/scene_plan.json   # CFW-131: Director-authored card copy (SCENE-PLAN.md)
 *     --out        path/to/beat_list.json
 *
 * CFW-131 — card copy is nobody's job unless it is the Director's:
 *   --scene-plan <file>   apply the scene_plan directive (SCENE-PLAN.md). Graphics
 *                         windows are split into the plan's `graphic` scenes and
 *                         every graphics beat carries the scene's copy. If the plan
 *                         has `broll` scenes they ARE the b-roll placements.
 *   --allow-empty-copy    legacy escape hatch: emit graphics beats with empty copy
 *                         (the calling core MUST author copy before rendering).
 *                         Without it, any graphics beat left without a headline is
 *                         a HARD error (exit 1) — blank cards never reach a render.
 */

'use strict';

const fs   = require('fs');
const path = require('path');
const { execSync, spawnSync } = require('child_process');
const { validateScenePlan, resolveAnchors } = require('./validate-scene-plan');

// ─── CLI arg parsing ──────────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i];
    if (key.startsWith('--')) {
      args[key.slice(2)] = argv[i + 1];
      i++;
    }
  }
  return args;
}

const raw = parseArgs(process.argv.slice(2));

const TRANSCRIPT_PATH = raw['transcript'] || null;
const BROLL_PATH      = raw['broll']      || null;
const COVERAGE_PCT    = parseFloat(raw['coverage']  ?? '30');
const CLIP_SECS       = parseFloat(raw['clip-secs'] ?? '5');   // default 5 (4-6 range); 4 read too short for screen-rec b-roll (user, 2026-06-13)
const MIN_SECS        = parseFloat(raw['min-secs']  ?? '4');   // 4s floor — screen-rec b-roll needs >=4s to read
const MAX_SECS        = parseFloat(raw['max-secs']  ?? '6');
const ORDER           = raw['order']  || 'transcript-match';   // transcript-match | as-given | even
const REUSE           = (raw['reuse'] || 'false') === 'true';
const BED_DUR_ARG     = raw['bed-dur'] ? parseFloat(raw['bed-dur']) : null;
const BRAND_PATH      = raw['brand']  || null;
const OUT_PATH        = raw['out']    || 'beat_list.json';
const SCENE_PLAN_PATH = raw['scene-plan'] || null;
const ALLOW_EMPTY_COPY = process.argv.includes('--allow-empty-copy');
const MIN_CARD_SECS   = parseFloat(raw['min-card-secs'] ?? '1.0');  // fragments shorter than this merge into a neighbour

// ─── Load inputs ─────────────────────────────────────────────────────────────

if (!TRANSCRIPT_PATH || !fs.existsSync(TRANSCRIPT_PATH)) {
  console.error('[c-broll-sync] ERROR: --transcript is required and must exist');
  process.exit(1);
}

const transcript = JSON.parse(fs.readFileSync(TRANSCRIPT_PATH, 'utf8'));
// Normalise: accept [{text,start,end}] or [{word,start,end}]
const words = transcript.map(w => ({
  text:  w.text || w.word || '',
  start: parseFloat(w.start),
  end:   parseFloat(w.end),
}));

if (words.length === 0) {
  console.error('[c-broll-sync] ERROR: transcript is empty');
  process.exit(1);
}

const brollClips = (BROLL_PATH && fs.existsSync(BROLL_PATH))
  ? JSON.parse(fs.readFileSync(BROLL_PATH, 'utf8'))
  : [];

const brand = (BRAND_PATH && fs.existsSync(BRAND_PATH))
  ? JSON.parse(fs.readFileSync(BRAND_PATH, 'utf8'))
  : {};

// Derive bed_duration
const bedDuration = BED_DUR_ARG || words[words.length - 1].end;

// ─── CFW-131: scene_plan directive (SCENE-PLAN.md) ───────────────────────────
let scenePlan = null;
if (SCENE_PLAN_PATH) {
  if (!fs.existsSync(SCENE_PLAN_PATH)) {
    console.error(`[c-broll-sync] ERROR: --scene-plan ${SCENE_PLAN_PATH} does not exist`);
    process.exit(1);
  }
  let rawPlan;
  try { rawPlan = JSON.parse(fs.readFileSync(SCENE_PLAN_PATH, 'utf8')); }
  catch (e) { console.error(`[c-broll-sync] ERROR: scene_plan is not valid JSON: ${e.message}`); process.exit(1); }
  if (rawPlan && typeof rawPlan === 'object' && !Array.isArray(rawPlan) && !isFinite(rawPlan.bed_duration)) rawPlan.bed_duration = bedDuration;
  const resolved = resolveAnchors(rawPlan, words);
  const verdict  = validateScenePlan(resolved.plan, { bedDuration });
  const errs = [...resolved.errors, ...verdict.errors];
  for (const w of verdict.warnings) console.warn(`[c-broll-sync] scene_plan WARN: ${w}`);
  if (errs.length) {
    for (const e of errs) console.error(`[c-broll-sync] scene_plan ERROR: ${e}`);
    console.error(`[c-broll-sync] ERROR: scene_plan invalid (${errs.length} error(s)) — fix ${SCENE_PLAN_PATH}; never emit blank cards`);
    process.exit(1);
  }
  scenePlan = resolved.plan;
  console.log(`[c-broll-sync] scene_plan: ${scenePlan.scenes.length} scenes loaded from ${SCENE_PLAN_PATH}`);
}

// ─── Budget calculation (mechanical — never left to LLM) ──────────────────────

const budgetSeconds  = (COVERAGE_PCT / 100) * bedDuration;
const windowSeconds  = Math.min(Math.max(CLIP_SECS, MIN_SECS), MAX_SECS);
const maxWindows     = Math.floor(budgetSeconds / windowSeconds);

const effectiveClips = REUSE ? brollClips : brollClips;  // reuse handled in allocation below
const availableSlots = REUSE ? maxWindows : Math.min(maxWindows, brollClips.length);

// Shortfall detection
let shortfallNote = null;
if (!REUSE && brollClips.length < maxWindows && brollClips.length > 0) {
  const achievedPct = ((brollClips.length * windowSeconds) / bedDuration * 100).toFixed(1);
  shortfallNote = `requested ${COVERAGE_PCT}%, achieved ${achievedPct}% — only ${brollClips.length} clip${brollClips.length !== 1 ? 's' : ''}, no reuse`;
  console.warn(`[c-broll-sync] shortfall: ${shortfallNote}`);
}
if (brollClips.length === 0) {
  console.log('[c-broll-sync] no b-roll supplied → 100% graphics (valid, not degraded)');
}

// ─── Placement strategies ─────────────────────────────────────────────────────

/**
 * Returns an array of { clipIndex, beatStart, beatEnd, in: number, out: number }
 * describing each b-roll window placement.
 */
function placeAsGiven() {
  const placements = [];
  for (let i = 0; i < availableSlots; i++) {
    const clip     = effectiveClips[i % effectiveClips.length];
    const clipDur  = clip.duration || (windowSeconds + 1);  // fallback if not probed
    const inPt     = 0;
    const outPt    = Math.min(Math.max(windowSeconds, MIN_SECS), Math.min(MAX_SECS, clipDur));
    // Place evenly across reel for as-given (even spacing is simpler / predictable)
    const spacing  = bedDuration / (availableSlots + 1);
    const beatStart = spacing * (i + 1) - windowSeconds / 2;
    const beatEnd   = beatStart + (outPt - inPt);
    placements.push({ clipIndex: i % effectiveClips.length, beatStart, beatEnd, in: inPt, out: outPt });
  }
  return placements;
}

function placeEven() {
  const placements = [];
  if (effectiveClips.length === 0) return placements;
  const spacing = bedDuration / (availableSlots + 1);
  for (let i = 0; i < availableSlots; i++) {
    const clip     = effectiveClips[i % effectiveClips.length];
    const clipDur  = clip.duration || (windowSeconds + 1);
    const inPt     = 0;
    const outPt    = Math.min(Math.max(windowSeconds, MIN_SECS), Math.min(MAX_SECS, clipDur));
    const beatStart = Math.max(0, spacing * (i + 1) - (outPt - inPt) / 2);
    const beatEnd   = Math.min(bedDuration, beatStart + (outPt - inPt));
    placements.push({ clipIndex: i % effectiveClips.length, beatStart, beatEnd, in: inPt, out: outPt });
  }
  return placements;
}

/**
 * For transcript-match: builds the OPUS prompt, spawns claude --print (env-unset),
 * falls back to kimi. Returns parsed beat specs from the LLM.
 */
function placeTranscriptMatch() {
  if (brollClips.length === 0 || availableSlots === 0) return [];

  const prompt = buildOpusPrompt();

  // Try OPUS (env-unset to bypass Ollama/kimi routing)
  let rawPlan = callOpus(prompt);
  if (!rawPlan) {
    console.warn('[c-broll-sync] Opus unavailable — falling back to kimi for placement');
    rawPlan = callKimi(prompt);
  }
  if (!rawPlan) {
    console.warn('[c-broll-sync] kimi planning also failed — falling back to even placement');
    return placeEven();
  }

  // Parse the LLM response — extract the JSON array
  const match = rawPlan.match(/\[[\s\S]*\]/);
  if (!match) {
    console.warn('[c-broll-sync] LLM returned no JSON array — falling back to even placement');
    return placeEven();
  }
  let llmBeats;
  try {
    llmBeats = JSON.parse(match[0]);
  } catch (e) {
    console.warn('[c-broll-sync] LLM JSON parse error — falling back to even placement:', e.message);
    return placeEven();
  }

  // Enforce budget: keep only the first availableSlots broll beats
  const brollBeats = llmBeats.filter(b => b.kind === 'broll').slice(0, availableSlots);

  // Validate + clamp each broll window
  return brollBeats.map((b, i) => {
    const clip = brollClips.find(c => c.clip === b.broll?.clip) || brollClips[i % brollClips.length];
    const clipDur = clip.duration || MAX_SECS + 1;
    const rawIn   = parseFloat(b.broll?.in ?? 0);
    const rawOut  = parseFloat(b.broll?.out ?? (rawIn + windowSeconds));
    const winDur  = Math.min(Math.max(rawOut - rawIn, MIN_SECS), Math.min(MAX_SECS, clipDur - rawIn));
    const inPt    = Math.min(rawIn, Math.max(0, clipDur - winDur));
    const outPt   = inPt + winDur;
    return {
      clipIndex: brollClips.indexOf(clip),
      beatStart: parseFloat(b.start),
      beatEnd:   parseFloat(b.end),
      in:        inPt,
      out:       outPt,
      matchScore:  b.broll?.match_score  ?? 1.0,
      matchReason: b.broll?.match_reason ?? '',
    };
  }).filter(p => p.beatStart >= 0 && p.beatEnd <= bedDuration + 0.5);
}

function buildOpusPrompt() {
  const transcriptText = words.map(w => `[${w.start.toFixed(2)}-${w.end.toFixed(2)}] ${w.text}`).join('\n');
  const clipsText = brollClips.map((c, i) => {
    const cueText = (c.cues || []).map(cu => `  [${cu.start.toFixed(2)}-${cu.end.toFixed(2)}] ${cu.text}`).join('\n');
    return `clip[${i}] "${c.clip}" (duration: ${c.duration ?? 'unknown'}s):\n${cueText || '  (no audio cues — match by filename)'}`;
  }).join('\n\n');

  return `You are planning the b-roll beat layout for a 9:16 vertical reel.
Output STRICT JSON ONLY — an array, no prose, no markdown fences.

Talking-head transcript (word timestamps):
${transcriptText}

Available b-roll clips and their own cue timestamps:
${clipsText}

Coverage constraints (ENFORCE these — do NOT exceed):
  bed_duration:      ${bedDuration.toFixed(2)}s
  budget_seconds:    ${budgetSeconds.toFixed(2)}s  (= ${COVERAGE_PCT}% of bed)
  window_seconds:    ${windowSeconds}s per b-roll window (clamped to [${MIN_SECS}, ${MAX_SECS}])
  max_broll_windows: ${availableSlots}  (= floor(budget / window), capped at ${brollClips.length} available clips)
  reuse:             ${REUSE}

Output an array of ALL beats covering the FULL ${bedDuration.toFixed(2)}s (no gaps).
Every second must belong to exactly one beat.
At most ${availableSlots} beats may be kind="broll". The rest are kind="graphics".

Beat schema:
For a b-roll beat:
{
  "index": <int>,
  "start": <float>,
  "end":   <float>,
  "kind":  "broll",
  "broll": {
    "clip":         "<filename from the clips list above>",
    "in":           <float — trim start in the source clip>,
    "out":          <float — trim end; out-in must be between ${MIN_SECS} and ${MAX_SECS}>,
    "match_score":  <0.0–1.0>,
    "match_reason": "<one line: why this clip matches this transcript moment>"
  }
}

For a graphics beat:
{
  "index": <int>,
  "start": <float>,
  "end":   <float>,
  "kind":  "graphics",
  "scene": {
    "eyebrow":    "<SHORT UPPERCASE mono label>",
    "ghost":      "<ONE huge faint background word>",
    "title_html": "<punchy UPPERCASE headline; wrap the KEY word in <span class=\\"accent\\">WORD</span>>",
    "brand":      {}
  }
}

RULES:
1. Cover exactly ${bedDuration.toFixed(2)}s with gapless, non-overlapping beats.
2. No more than ${availableSlots} b-roll beats total.
3. Choose clip windows where the clip's own cues best match the transcript words at that moment.
4. Clamp every b-roll window: out - in must be in [${MIN_SECS}, ${MAX_SECS}].
5. All words in beats must be VERBATIM from the transcript (eyebrow/ghost/title may paraphrase).
6. MOST beats are graphics — b-roll is the accent, not the bed.`;
}

function callOpus(prompt) {
  const unsetVars = [
    'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY',
    'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL',
    'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'CLAUDE_CODE_SUBAGENT_MODEL',
  ];
  const env = Object.assign({}, process.env);
  for (const v of unsetVars) delete env[v];

  try {
    const result = spawnSync('claude', ['--print', prompt, '--dangerously-skip-permissions'], {
      env,
      timeout: 180_000,
      maxBuffer: 4 * 1024 * 1024,
      encoding: 'utf8',
    });
    const out = (result.stdout || '').trim();
    return out.length > 10 ? out : null;
  } catch (e) {
    return null;
  }
}

function callKimi(prompt) {
  try {
    const result = spawnSync('claude', ['--print', prompt, '--dangerously-skip-permissions'], {
      env: process.env,
      timeout: 180_000,
      maxBuffer: 4 * 1024 * 1024,
      encoding: 'utf8',
    });
    const out = (result.stdout || '').trim();
    return out.length > 10 ? out : null;
  } catch (e) {
    return null;
  }
}

/**
 * Resolve a scene_plan `asset` reference to an index in brollClips: exact clip
 * path, basename match, or `label`. A bare readable file path not in BROLL_JSON
 * is appended as a new clip (duration unknown → window clamps to the scene).
 */
function resolveClipIndex(asset) {
  const a = String(asset).trim();
  let i = brollClips.findIndex(c => c.clip === a || c.label === a);
  if (i >= 0) return i;
  i = brollClips.findIndex(c => path.basename(String(c.clip)) === path.basename(a));
  if (i >= 0) return i;
  if (fs.existsSync(a)) { brollClips.push({ clip: a, cues: [] }); return brollClips.length - 1; }
  return -1;
}

// ─── Run the selected placement strategy ──────────────────────────────────────

let rawPlacements = [];
const planBroll = scenePlan ? scenePlan.scenes.filter(sc => sc.kind === 'broll') : [];
if (planBroll.length > 0) {
  // The Director placed the b-roll explicitly — the coverage strategies are bypassed.
  console.log(`[c-broll-sync] scene_plan carries ${planBroll.length} broll scene(s) — using them as the placements (order=${ORDER} ignored)`);
  rawPlacements = planBroll.map(sc => {
    const idx = resolveClipIndex(sc.asset);
    if (idx < 0) {
      console.error(`[c-broll-sync] ERROR: scene_plan broll scene "${sc.id || sc.asset}" asset "${sc.asset}" matches no clip in --broll (by path, basename or label) and is not a readable file`);
      process.exit(1);
    }
    const clip = brollClips[idx];
    const clipDur = clip.duration || Infinity;
    const want = sc.end - sc.start;
    const inPt = Math.max(0, parseFloat(sc.in ?? 0));
    const outPt = Math.min(inPt + want, clipDur);
    return { clipIndex: idx, beatStart: sc.start, beatEnd: sc.start + (outPt - inPt), in: inPt, out: outPt,
             matchScore: 1.0, matchReason: 'placed by scene_plan' };
  });
} else switch (ORDER) {
  case 'as-given':
    rawPlacements = placeAsGiven();
    break;
  case 'even':
    rawPlacements = placeEven();
    break;
  case 'transcript-match':
  default:
    rawPlacements = placeTranscriptMatch();
    break;
}

// ─── Build the gapless beat list ──────────────────────────────────────────────

/**
 * Given raw b-roll placements (may be empty), fill the remaining time with
 * graphics beats and return a gapless, sorted beat list.
 */
function buildBeatList(placements) {
  // Sort placements by beatStart
  placements.sort((a, b) => a.beatStart - b.beatStart);

  // Remove overlapping placements (keep earlier one)
  const deduped = [];
  let cursor = 0;
  for (const p of placements) {
    if (p.beatStart >= cursor - 0.01) {
      deduped.push(p);
      cursor = p.beatEnd;
    }
  }

  const beats = [];
  let idx = 0;
  let t = 0;

  for (const p of deduped) {
    // Fill gap before this b-roll window with graphics
    if (p.beatStart > t + 0.05) {
      beats.push({
        index: idx++,
        start: parseFloat(t.toFixed(3)),
        end:   parseFloat(p.beatStart.toFixed(3)),
        kind:  'graphics',
        scene: {
          eyebrow:    '',
          ghost:      '',
          title_html: '',
          brand,
        },
      });
    }
    // The b-roll beat
    const clip = brollClips[p.clipIndex] || { clip: 'unknown.mp4' };
    beats.push({
      index: idx++,
      start: parseFloat(p.beatStart.toFixed(3)),
      end:   parseFloat(p.beatEnd.toFixed(3)),
      kind:  'broll',
      broll: {
        clip:         clip.clip,
        in:           parseFloat(p.in.toFixed(3)),
        out:          parseFloat(p.out.toFixed(3)),
        match_score:  p.matchScore  ?? 1.0,
        match_reason: p.matchReason ?? '',
      },
    });
    t = p.beatEnd;
  }

  // Fill trailing gap with graphics
  if (t < bedDuration - 0.05) {
    beats.push({
      index: idx++,
      start: parseFloat(t.toFixed(3)),
      end:   parseFloat(bedDuration.toFixed(3)),
      kind:  'graphics',
      scene: {
        eyebrow:    '',
        ghost:      '',
        title_html: '',
        brand,
      },
    });
  }

  return beats;
}

// For transcript-match, the LLM already returned full beat specs including graphics.
// For as-given/even we only get b-roll placements and need to fill graphics.
let beats;
if (ORDER === 'transcript-match' && rawPlacements.length > 0 && rawPlacements[0]._fullBeatList) {
  // Full beat list returned (future extension)
  beats = rawPlacements[0]._fullBeatList;
} else {
  beats = buildBeatList(rawPlacements);
}

// ─── CFW-131: split graphics windows by the scene_plan and attach copy ───────

const TIMING_KEYS = new Set(['start', 'end', 'start_phrase', 'end_phrase', 'kind', 'headline', 'asset', 'in', 'cover']);

function sceneToGraphics(sc, start, end) {
  const extra = {};
  for (const [k, v] of Object.entries(sc)) if (!TIMING_KEYS.has(k)) extra[k] = v;
  return {
    start: parseFloat(start.toFixed(3)),
    end:   parseFloat(end.toFixed(3)),
    kind:  'graphics',
    scene: {
      ...extra,
      eyebrow:    sc.eyebrow ?? '',
      ghost:      sc.ghost ?? '',
      title_html: sc.headline,
      sub:        sc.sub ?? '',
      type:       sc.type ?? 'standard',
      scene_id:   sc.id ?? null,
      source:     'scene_plan',
      brand,
    },
  };
}

function applyScenePlan(bs, plan) {
  const gfxScenes = plan.scenes.filter(sc => sc.kind === 'graphic');
  const avScenes  = plan.scenes.filter(sc => sc.kind === 'avatar');
  const out = [];
  for (const b of bs) {
    if (b.kind !== 'graphics') { out.push(b); continue; }
    // Window [b.start, b.end] → the graphic/avatar scenes that overlap it, clipped.
    const frags = [];
    for (const sc of [...gfxScenes, ...avScenes].sort((x, y) => x.start - y.start)) {
      const s = Math.max(sc.start, b.start), e = Math.min(sc.end, b.end);
      if (e - s > 0.01) frags.push({ sc, s, e });
    }
    if (frags.length === 0) {
      console.error(`[c-broll-sync] ERROR: no graphic scene in scene_plan covers the window ${b.start.toFixed(2)}–${b.end.toFixed(2)} s — add a card for it`);
      process.exit(1);
    }
    // Merge fragments shorter than MIN_CARD_SECS into a neighbour (prefer the previous one).
    for (let i = 0; i < frags.length; i++) {
      if (frags[i].e - frags[i].s >= MIN_CARD_SECS || frags.length === 1) continue;
      if (i > 0) { frags[i - 1].e = frags[i].e; frags.splice(i, 1); i--; }
      else { frags[i + 1].s = frags[i].s; frags.splice(i, 1); i--; }
    }
    // Fill any slack at the window edges (from timing tolerance) into the edge fragments.
    frags[0].s = b.start; frags[frags.length - 1].e = b.end;
    for (const f of frags) {
      if (f.sc.kind === 'avatar') {
        out.push({ start: parseFloat(f.s.toFixed(3)), end: parseFloat(f.e.toFixed(3)), kind: 'avatar',
                   avatar: { asset: f.sc.asset ?? null, scene_id: f.sc.id ?? null, source: 'scene_plan' } });
      } else {
        out.push(sceneToGraphics(f.sc, f.s, f.e));
      }
    }
  }
  return out;
}

if (scenePlan) beats = applyScenePlan(beats, scenePlan);

// ─── Reindex + verify ─────────────────────────────────────────────────────────

beats.forEach((b, i) => {
  b.index = i;
  if (b.kind === 'graphics' && !b.slug) {
    const id = (b.scene && b.scene.scene_id) ? String(b.scene.scene_id) : '';
    const safe = id.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
    b.slug = safe ? `beat${i}-${safe}` : `beat${i}`;
  }
});

// HARD RULE (CFW-131): never emit a graphics beat without copy.
const blank = beats.filter(b => b.kind === 'graphics' && !String((b.scene || {}).title_html || '').replace(/<[^>]*>/g, '').trim());
if (blank.length > 0 && !ALLOW_EMPTY_COPY) {
  for (const b of blank) console.error(`[c-broll-sync] ERROR: graphics beat ${b.index} (${b.start.toFixed(2)}–${b.end.toFixed(2)} s) has EMPTY card copy`);
  console.error(`[c-broll-sync] ERROR: ${blank.length} graphics beat(s) have no copy — supply --scene-plan <scene_plan.json> (see SCENE-PLAN.md) so every card is authored; never render blank cards. (--allow-empty-copy restores the legacy behaviour for cores that author copy themselves.)`);
  process.exit(1);
}
if (blank.length > 0) console.warn(`[c-broll-sync] WARN: ${blank.length} graphics beat(s) emitted with EMPTY copy (--allow-empty-copy) — the calling core MUST author copy before rendering`);

// Verify gapless coverage
let prevEnd = 0;
for (const b of beats) {
  if (Math.abs(b.start - prevEnd) > 0.11) {
    console.warn(`[c-broll-sync] gap detected: beat ${b.index} starts at ${b.start} but previous ended at ${prevEnd.toFixed(3)}`);
  }
  prevEnd = b.end;
}
if (Math.abs(prevEnd - bedDuration) > 0.2) {
  console.warn(`[c-broll-sync] beats end at ${prevEnd.toFixed(3)} but bed_duration is ${bedDuration} — check inputs`);
}

// Compute achieved b-roll %
const brollSeconds = beats.filter(b => b.kind === 'broll').reduce((s, b) => s + (b.end - b.start), 0);
const achievedBrollPct = parseFloat(((brollSeconds / bedDuration) * 100).toFixed(1));

// cover_at: a deterministic money-shot timestamp PAST the hook (beat 0), used by the
// consuming core for the first-frame cover rule (§2d of the consolidation plan). Prefer the
// first real b-roll beat (footage reads best as a feed thumbnail); else the midpoint of the
// first content beat after the hook; clamp to >= 2.0s and inside the bed.
function pickCoverAt(bs, dur) {
  // Prefer a GRAPHICS (content-card) beat past the hook — the strongest universal poster.
  // AVOID b-roll beats: generic footage (UI screen-recs, stock) makes a weak feed thumbnail.
  // Cores with a visible speaker (spotlight/pip) may override this to a face frame.
  const firstGfx = bs.find((b, i) => b.kind === 'graphics' && i > 0 && b.start >= 1.5);
  let t;
  if (firstGfx) {
    t = firstGfx.start + (firstGfx.end - firstGfx.start) / 2;
  } else if (bs.length > 1) {
    t = bs[1].start + (bs[1].end - bs[1].start) / 2;
  } else {
    t = dur * 0.35;
  }
  // Never sit inside a b-roll window; nudge to the nearest graphics beat's start if we landed in one.
  const inBroll = bs.find(b => b.kind === 'broll' && t >= b.start && t < b.end);
  if (inBroll) {
    const after = bs.find(b => b.kind === 'graphics' && b.start >= inBroll.end);
    if (after) t = after.start + Math.min(1.0, (after.end - after.start) / 2);
  }
  return parseFloat(Math.min(Math.max(t, 2.0), Math.max(0, dur - 0.1)).toFixed(3));
}
let coverAt = pickCoverAt(beats, bedDuration);
if (scenePlan) {
  const flagged = scenePlan.scenes.find(sc => sc.cover === true);
  if (flagged) {
    coverAt = parseFloat((flagged.start + Math.min((flagged.end - flagged.start) / 2, 2.0)).toFixed(3));
    console.log(`[c-broll-sync] cover_at=${coverAt} from scene_plan cover flag (${flagged.id || flagged.kind})`);
  }
}

// ─── Write output ────────────────────────────────────────────────────────────

const output = {
  bed_duration:       parseFloat(bedDuration.toFixed(3)),
  achieved_broll_pct: achievedBrollPct,
  cover_at:           coverAt,
  shortfall_note:     shortfallNote,
  params: {
    broll_coverage_pct: COVERAGE_PCT,
    broll_clip_seconds: CLIP_SECS,
    broll_min_seconds:  MIN_SECS,
    broll_max_seconds:  MAX_SECS,
    broll_order:        ORDER,
    broll_reuse:        REUSE,
    scene_plan:         SCENE_PLAN_PATH ? path.basename(SCENE_PLAN_PATH) : null,
  },
  beats,
};

fs.writeFileSync(OUT_PATH, JSON.stringify(output, null, 2));
console.log(`[c-broll-sync] done: ${beats.length} beats, ${achievedBrollPct}% b-roll (${brollSeconds.toFixed(1)}s / ${bedDuration}s), wrote ${OUT_PATH}`);
