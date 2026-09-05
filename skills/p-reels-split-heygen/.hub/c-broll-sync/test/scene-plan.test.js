#!/usr/bin/env node
// c-broll-sync/test/scene-plan.test.js — unit tests for the scene_plan directive
// contract (CFW-131). node:test + node:assert only, no deps.
//   node --test c-broll-sync/test/scene-plan.test.js
'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const SCRIPTS = path.resolve(__dirname, '..', 'scripts');
const { validateScenePlan, resolveAnchors, headlineText, hasDisallowedTag } = require(path.join(SCRIPTS, 'validate-scene-plan.js'));

// 20 s synthetic word transcript: one word per 0.5 s
const WORDS = [];
const TEXT = 'nobody talks about this feature it is called mcp it connects claude to real tools your files your calendar the setup takes fifteen minutes comment mcp and i will dm you the config plus three tools that matter most today'.split(' ');
TEXT.forEach((w, i) => WORDS.push({ text: w, start: i * 0.5, end: i * 0.5 + 0.45 }));
const BED = TEXT.length * 0.5; // 20.0

function goodPlan() {
  return {
    version: 1,
    scenes: [
      { id: 'hook',  kind: 'graphic', start: 0,  end: 4,  type: 'hook', eyebrow: 'NOBODY TALKS ABOUT THIS', ghost: '?', headline: 'THE FEATURE THAT <span class="accent">CHANGED</span> HOW I WORK' },
      { id: 'mcp',   kind: 'graphic', start: 4,  end: 9,  type: 'terminal', ghost: 'MCP', headline: 'IT IS CALLED <span class="accent">MCP</span>' },
      { id: 'tools', kind: 'graphic', start: 9,  end: 14, ghost: '04', headline: 'CLAUDE + YOUR <span class="accent">REAL</span> TOOLS' },
      { id: 'cta',   kind: 'graphic', start: 14, end: 20, type: 'cta', ghost: 'DM', headline: 'COMMENT <span class="accent">MCP</span>', sub: 'I will DM you the config' },
    ],
  };
}

test('valid plan passes', () => {
  const v = validateScenePlan(goodPlan(), { bedDuration: BED });
  assert.equal(v.ok, true, v.errors.join('; '));
});

test('empty headline on a graphic scene is a HARD error', () => {
  const p = goodPlan(); p.scenes[1].headline = '  <span class="accent"></span> ';
  const v = validateScenePlan(p, { bedDuration: BED });
  assert.equal(v.ok, false);
  assert.match(v.errors.join('\n'), /EMPTY headline copy/);
});

test('missing headline is a HARD error', () => {
  const p = goodPlan(); delete p.scenes[2].headline;
  assert.equal(validateScenePlan(p, { bedDuration: BED }).ok, false);
});

test('overlapping scenes fail', () => {
  const p = goodPlan(); p.scenes[1].start = 3.0;
  const v = validateScenePlan(p, { bedDuration: BED });
  assert.equal(v.ok, false); assert.match(v.errors.join('\n'), /overlap/);
});

test('gap between scenes fails', () => {
  const p = goodPlan(); p.scenes[2].start = 10.0;
  const v = validateScenePlan(p, { bedDuration: BED });
  assert.equal(v.ok, false); assert.match(v.errors.join('\n'), /gap of/);
});

test('plan must cover the whole bed', () => {
  const p = goodPlan(); p.scenes[3].end = 17;
  const v = validateScenePlan(p, { bedDuration: BED });
  assert.equal(v.ok, false); assert.match(v.errors.join('\n'), /cover the whole bed/);
});

test('disallowed markup in headline fails', () => {
  const p = goodPlan(); p.scenes[0].headline = 'HELLO <script>x</script>';
  const v = validateScenePlan(p, { bedDuration: BED });
  assert.equal(v.ok, false); assert.match(v.errors.join('\n'), /may only contain/);
  assert.equal(hasDisallowedTag('A <span class="accent">B</span><br>C'), false);
  assert.equal(headlineText('A <span class="accent">B</span><br>C'), 'A BC');
});

test('graphic scene longer than 12 s fails; 8–12 s warns', () => {
  const p = goodPlan();
  p.scenes = [ { id: 'x', kind: 'graphic', start: 0, end: 13, headline: 'LONG' }, { id: 'y', kind: 'graphic', start: 13, end: 20, headline: 'OK' } ];
  const v = validateScenePlan(p, { bedDuration: BED });
  assert.equal(v.ok, false); assert.match(v.errors.join('\n'), /max 12 s/);
  p.scenes = [ { id: 'x', kind: 'graphic', start: 0, end: 10, headline: 'LONG' }, { id: 'y', kind: 'graphic', start: 10, end: 20, headline: 'OK' } ];
  const w = validateScenePlan(p, { bedDuration: BED });
  assert.equal(w.ok, true); assert.equal(w.warnings.length, 2);
});

test('broll scene requires an asset; avatar scene needs no copy', () => {
  const p = goodPlan();
  p.scenes[1] = { id: 'b', kind: 'broll', start: 4, end: 9 };
  assert.equal(validateScenePlan(p, { bedDuration: BED }).ok, false);
  p.scenes[1] = { id: 'b', kind: 'broll', start: 4, end: 9, asset: 'clip-a.mp4' };
  p.scenes[2] = { id: 'a', kind: 'avatar', start: 9, end: 14 };
  assert.equal(validateScenePlan(p, { bedDuration: BED }).ok, true);
});

test('bad kind / version / shape fail', () => {
  const p = goodPlan(); p.scenes[0].kind = 'graphics';
  assert.equal(validateScenePlan(p, { bedDuration: BED }).ok, false);
  assert.equal(validateScenePlan({ version: 2, scenes: goodPlan().scenes }).ok, false);
  assert.equal(validateScenePlan([]).ok, false);
  assert.equal(validateScenePlan({ version: 1, scenes: [] }).ok, false);
});

test('phrase anchors resolve against the transcript and chain', () => {
  const p = { version: 1, bed_duration: BED, scenes: [
    { id: 'hook', kind: 'graphic', start: 0, end_phrase: 'it is called', headline: 'HOOK' },
    { id: 'mcp',  kind: 'graphic', start_phrase: 'it is called', end_phrase: 'the setup', headline: 'MCP' },
    { id: 'rest', kind: 'graphic', start_phrase: 'the setup', headline: 'REST' },
  ] };
  const r = resolveAnchors(p, WORDS);
  assert.deepEqual(r.errors, []);
  assert.equal(r.plan.scenes[0].end, 2.5);
  assert.equal(r.plan.scenes[1].start, 2.5);
  assert.equal(r.plan.scenes[2].end, BED);
  assert.equal(validateScenePlan(r.plan).ok, true);
  const bad = resolveAnchors({ version: 1, scenes: [ { kind: 'graphic', start: 0, end_phrase: 'not in script', headline: 'X' } ] }, WORDS);
  assert.match(bad.errors.join('\n'), /not found in transcript/);
});

// ─── plan.js integration (mechanical paths only — no LLM) ───────────────────
function runPlan(args, tmp) {
  return spawnSync('node', [path.join(SCRIPTS, 'plan.js'), ...args], { encoding: 'utf8', cwd: tmp });
}
function fixture() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'broll-sync-'));
  fs.writeFileSync(path.join(tmp, 'words.json'), JSON.stringify(WORDS));
  fs.writeFileSync(path.join(tmp, 'broll.json'), JSON.stringify([ { clip: '/nowhere/clip-a.mp4', duration: 8, cues: [] } ]));
  fs.writeFileSync(path.join(tmp, 'brand.json'), JSON.stringify({ bg: '#0F172A', accent: '#F97316' }));
  return tmp;
}

test('plan.js WITHOUT --scene-plan hard-fails on empty graphics copy', () => {
  const tmp = fixture();
  const r = runPlan(['--transcript', 'words.json', '--order', 'even', '--bed-dur', String(BED), '--out', 'beats.json'], tmp);
  assert.equal(r.status, 1, r.stdout + r.stderr);
  assert.match(r.stderr, /have no copy — supply --scene-plan/);
  assert.equal(fs.existsSync(path.join(tmp, 'beats.json')), false);
});

test('plan.js --allow-empty-copy restores the legacy blank-card output', () => {
  const tmp = fixture();
  const r = runPlan(['--transcript', 'words.json', '--order', 'even', '--bed-dur', String(BED), '--out', 'beats.json', '--allow-empty-copy'], tmp);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  const bl = JSON.parse(fs.readFileSync(path.join(tmp, 'beats.json'), 'utf8'));
  assert.ok(bl.beats.every(b => b.kind === 'graphics' && b.scene.title_html === ''));
});

test('plan.js --scene-plan (graphics only) emits non-empty copy on every graphics beat', () => {
  const tmp = fixture();
  fs.writeFileSync(path.join(tmp, 'scene_plan.json'), JSON.stringify(goodPlan()));
  const r = runPlan(['--transcript', 'words.json', '--bed-dur', String(BED), '--brand', 'brand.json', '--scene-plan', 'scene_plan.json', '--out', 'beats.json'], tmp);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  const bl = JSON.parse(fs.readFileSync(path.join(tmp, 'beats.json'), 'utf8'));
  assert.equal(bl.beats.length, 4);
  assert.ok(bl.beats.every(b => b.kind === 'graphics' && b.scene.title_html.length > 0 && b.scene.source === 'scene_plan' && b.slug.startsWith('beat')));
  assert.equal(bl.beats[1].scene.type, 'terminal');
  assert.equal(bl.beats[1].scene.brand.accent, '#F97316');
  assert.equal(bl.beats[1].slug, 'beat1-mcp');
  assert.equal(bl.params.scene_plan, 'scene_plan.json');
});

test('plan.js --scene-plan splits graphics windows around planner-placed b-roll', () => {
  const tmp = fixture();
  fs.writeFileSync(path.join(tmp, 'scene_plan.json'), JSON.stringify(goodPlan()));
  // even placement of ONE clip: 1 window of 5 s centred at 10 s → 7.5–12.5 s
  const r = runPlan(['--transcript', 'words.json', '--broll', 'broll.json', '--coverage', '25', '--clip-secs', '5', '--min-secs', '4', '--max-secs', '6', '--order', 'even', '--bed-dur', String(BED), '--scene-plan', 'scene_plan.json', '--out', 'beats.json'], tmp);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  const bl = JSON.parse(fs.readFileSync(path.join(tmp, 'beats.json'), 'utf8'));
  const broll = bl.beats.filter(b => b.kind === 'broll');
  assert.equal(broll.length, 1);
  for (const b of bl.beats.filter(b => b.kind === 'graphics')) assert.ok(b.scene.title_html.length > 0, `beat ${b.index} blank`);
  // gapless
  let t = 0; for (const b of bl.beats) { assert.ok(Math.abs(b.start - t) < 0.02, `gap at ${b.start}`); t = b.end; }
  assert.ok(Math.abs(t - BED) < 0.02);
});

test('plan.js --scene-plan with broll scenes uses them as the placements and honours cover flag', () => {
  const tmp = fixture();
  const p = goodPlan();
  p.scenes[1] = { id: 'b1', kind: 'broll', start: 4, end: 9, asset: 'clip-a.mp4', cover: true };
  fs.writeFileSync(path.join(tmp, 'scene_plan.json'), JSON.stringify(p));
  const r = runPlan(['--transcript', 'words.json', '--broll', 'broll.json', '--order', 'transcript-match', '--bed-dur', String(BED), '--scene-plan', 'scene_plan.json', '--out', 'beats.json'], tmp);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  const bl = JSON.parse(fs.readFileSync(path.join(tmp, 'beats.json'), 'utf8'));
  const broll = bl.beats.filter(b => b.kind === 'broll');
  assert.equal(broll.length, 1);
  assert.equal(broll[0].start, 4); assert.equal(broll[0].end, 9);
  assert.equal(broll[0].broll.clip, '/nowhere/clip-a.mp4');
  assert.equal(bl.cover_at, 6);
  assert.match(r.stdout, /using them as the placements/);
});

test('plan.js --scene-plan with an unknown broll asset fails fast', () => {
  const tmp = fixture();
  const p = goodPlan(); p.scenes[1] = { id: 'b1', kind: 'broll', start: 4, end: 9, asset: 'missing.mp4' };
  fs.writeFileSync(path.join(tmp, 'scene_plan.json'), JSON.stringify(p));
  const r = runPlan(['--transcript', 'words.json', '--broll', 'broll.json', '--bed-dur', String(BED), '--scene-plan', 'scene_plan.json', '--out', 'beats.json'], tmp);
  assert.equal(r.status, 1); assert.match(r.stderr, /matches no clip/);
});

test('plan.js --scene-plan with an invalid plan fails fast with the validator message', () => {
  const tmp = fixture();
  const p = goodPlan(); p.scenes[0].headline = '';
  fs.writeFileSync(path.join(tmp, 'scene_plan.json'), JSON.stringify(p));
  const r = runPlan(['--transcript', 'words.json', '--bed-dur', String(BED), '--scene-plan', 'scene_plan.json', '--out', 'beats.json'], tmp);
  assert.equal(r.status, 1); assert.match(r.stderr, /EMPTY headline copy/);
});

test('validate-scene-plan CLI exits 1 on invalid, 0 on valid', () => {
  const tmp = fixture();
  fs.writeFileSync(path.join(tmp, 'ok.json'), JSON.stringify(goodPlan()));
  const p = goodPlan(); p.scenes[3].headline = '';
  fs.writeFileSync(path.join(tmp, 'bad.json'), JSON.stringify(p));
  assert.equal(spawnSync('node', [path.join(SCRIPTS, 'validate-scene-plan.js'), 'ok.json', '--bed-dur', String(BED)], { cwd: tmp, encoding: 'utf8' }).status, 0);
  const bad = spawnSync('node', [path.join(SCRIPTS, 'validate-scene-plan.js'), 'bad.json', '--bed-dur', String(BED)], { cwd: tmp, encoding: 'utf8' });
  assert.equal(bad.status, 1); assert.match(bad.stderr, /INVALID/);
});
