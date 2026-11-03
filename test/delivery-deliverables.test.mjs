// test/delivery-deliverables.test.mjs — F22 (finishes WI2.51): every recipe
// delivers only its deliverables to Social.
//
//   node --test test/delivery-deliverables.test.mjs
//
// Small and self-contained. It sources bin/cfw-render-lib.sh and
// bin/cfw-render-harness.sh in a bash subprocess and calls the delivery
// functions directly: cr_h_reel_delivery_outputs, cr_h_reel_missing_delivery
// (harness) and cr_select_deliverables (lib). It starts no worker, engine,
// server or upload, and it never runs test/run-tests.sh.
//
// The incident: faceless order cmvwzdgpw001p08kznhe8sy2t uploaded voice_bed,
// body_video, assembled_video and final_video plus cover.png. Only
// final_video.mp4 and cover.png are deliverables.
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SKILLS = path.join(REPO, 'skills');
const EXT = { video: 'mp4', image: 'png', json: 'json', text: 'md', audio: 'mp3' };
const MEDIA_EXT = new Set(['mp4', 'mov', 'webm', 'm4v', 'png', 'jpg', 'jpeg', 'gif', 'webp', 'pdf', 'mp3', 'wav', 'm4a']);

const SCRIPT = `
set -u
source "$REPO/bin/cfw-render-lib.sh"
source "$REPO/bin/cfw-render-harness.sh"
case "$MODE" in
  filter)  cr_h_reel_delivery_outputs "$ORDER" "$RAW" "$RECIPE_DIR" ;;
  missing) cr_h_reel_missing_delivery "$ORDER" "$RAW" "$RECIPE_DIR" ;;
  select)  cr_select_deliverables "$ORDER_DIR" "$RAW" ;;
esac
`;

function sh(mode, env) {
  const r = spawnSync('bash', ['--noprofile', '--norc', '-c', SCRIPT], {
    env: { ...process.env, REPO, MODE: mode, ORDER: '', RECIPE_DIR: '', ORDER_DIR: '', RAW: '[]', ...env },
    encoding: 'utf8',
    timeout: 60_000,
  });
  return { rc: r.status, out: r.stdout, err: r.stderr };
}

const manifestOf = (recipe) => JSON.parse(readFileSync(path.join(SKILLS, recipe, 'manifest.json'), 'utf8'));

// What cr_harness_run collects: every computer step's saves in step order,
// a repeated id replaced by its later save. Server steps do not run here.
function stepOutputs(root, manifest) {
  let list = [];
  for (const step of manifest.steps || []) {
    if ((step.runsOn || 'computer') !== 'computer') continue;
    for (const save of step.saves || []) {
      const file = `${root}/steps/${step.id}/saves/${save.id}.${EXT[save.kind]}`;
      list = list.filter((x) => x.id !== save.id);
      list.push({ id: save.id, url: `https://media.example/${save.id}`, path: file });
    }
  }
  return list;
}

const isMedia = (item) => MEDIA_EXT.has(path.extname(item.path).slice(1).toLowerCase()) && item.role !== 'captions';

// Write order.json and return everything a case needs.
function fixture(t, manifest, extra = {}) {
  const root = mkdtempSync(path.join(tmpdir(), 'cfw-f22-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const order = path.join(root, 'order.json');
  writeFileSync(order, JSON.stringify({ id: 'order-f22', recipe: manifest.recipe, manifest, ...extra }));
  return { root, order, raw: stepOutputs(root, manifest) };
}

function filter(fx, raw = fx.raw, recipe = '') {
  const r = sh('filter', { ORDER: fx.order, RAW: JSON.stringify(raw), RECIPE_DIR: recipe ? path.join(SKILLS, recipe) : '' });
  return { ...r, items: r.rc === 0 && r.out ? JSON.parse(r.out) : null };
}

const missing = (fx, raw = fx.raw, recipe = '') =>
  sh('missing', { ORDER: fx.order, RAW: JSON.stringify(raw), RECIPE_DIR: recipe ? path.join(SKILLS, recipe) : '' });

// path<TAB>role lines from the lib selector, i.e. what the worker hands to
// cfw-render-report.sh complete (media in order, then captions).
function selected(fx, items) {
  const r = sh('select', { ORDER_DIR: fx.root, RAW: JSON.stringify(items) });
  assert.equal(r.rc, 0, r.err);
  const rows = r.out.split('\n').filter(Boolean).map((l) => l.split('\t'));
  return {
    media: rows.filter((x) => x[1] === 'media').map((x) => path.basename(x[0])),
    captions: rows.filter((x) => x[1] === 'captions').map((x) => path.basename(x[0])),
  };
}

const ids = (items) => items.map((x) => x.id);

// ---------------------------------------------------------------------------
// 1. The incident: faceless
// ---------------------------------------------------------------------------
test('faceless: 5 media saves in, only final_video and cover delivered (the F22 incident)', (t) => {
  const fx = fixture(t, manifestOf('p-reels-faceless'));
  const mediaIn = fx.raw.filter(isMedia).map((x) => path.basename(x.path));
  assert.deepEqual(
    mediaIn.sort(),
    ['assembled_video.mp4', 'body_video.mp4', 'cover.png', 'final_video.mp4', 'voice_bed.mp4'],
    'fixture mirrors the 5 media saves of the incident',
  );
  const f = filter(fx, fx.raw, 'p-reels-faceless');
  assert.equal(f.rc, 0, f.err);
  assert.deepEqual(ids(f.items), ['final_video', 'cover', 'captions']);
  const sel = selected(fx, f.items);
  assert.deepEqual(sel.media, ['final_video.mp4', 'cover.png']);
  assert.deepEqual(sel.captions, ['captions.json']);
  for (const banned of ['voice_bed', 'body_video', 'assembled_video']) {
    assert.ok(!f.out.includes(banned), `${banned} must not be delivered`);
  }
  assert.equal(missing(fx, fx.raw, 'p-reels-faceless').out, '');
});

// ---------------------------------------------------------------------------
// 2. The other video recipes: pip-heygen, spotlight-heygen, clone-reel,
//    longform, split, split-heygen, and the two that were already filtered.
// ---------------------------------------------------------------------------
const VIDEO_RECIPES = [
  'p-reels-faceless', 'p-reels-pip', 'p-reels-pip-heygen', 'p-reels-spotlight', 'p-reels-spotlight-heygen',
  'p-reels-split', 'p-reels-split-heygen', 'p-clone-reel', 'p-longform',
];

for (const recipe of VIDEO_RECIPES) {
  test(`${recipe}: delivers final_video, cover and captions only`, (t) => {
    const manifest = manifestOf(recipe);
    const finalStep = manifest.steps.find((s) => s.id === 'final_checks');
    const saved = (finalStep.saves || []).map((s) => s.id);
    assert.ok(saved.includes('final_video') && saved.includes('cover'), 'manifest saves final_video and cover');
    const fx = fixture(t, manifest);
    const hasIntermediateVideo = fx.raw.filter((x) => x.path.endsWith('.mp4') && x.id !== 'final_video').length;
    assert.ok(hasIntermediateVideo >= 1, 'fixture has at least one step video that must not ship');
    const f = filter(fx, fx.raw, recipe);
    assert.equal(f.rc, 0, f.err);
    const want = ['final_video', 'cover', ...(saved.includes('captions') ? ['captions'] : [])];
    assert.deepEqual(ids(f.items), want);
    for (const item of f.items) {
      assert.match(item.path, /\/steps\/final_checks\/saves\//, `${item.id} comes from the final step`);
    }
    const sel = selected(fx, f.items);
    assert.deepEqual(sel.media, ['final_video.mp4', 'cover.png']);
    assert.deepEqual(sel.captions, saved.includes('captions') ? ['captions.json'] : []);
    assert.equal(missing(fx, fx.raw, recipe).out, '');
  });
}

test('every manifest that declares a final_video save is covered above (no recipe slips through)', () => {
  const declared = readdirSync(SKILLS, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .filter((name) => {
      try {
        const m = manifestOf(name);
        return (m.steps || []).some((s) => (s.saves || []).some((v) => v.id === 'final_video' && v.kind === 'video'));
      } catch {
        return false;
      }
    });
  assert.deepEqual(declared.sort(), [...VIDEO_RECIPES].sort());
});

// ---------------------------------------------------------------------------
// 3. A reel that lacks a deliverable ships no media and names the gap
// ---------------------------------------------------------------------------
test('faceless without its cover: no media, only captions, and the missing id is named', (t) => {
  const fx = fixture(t, manifestOf('p-reels-faceless'));
  const raw = fx.raw.filter((x) => x.id !== 'cover');
  const f = filter(fx, raw, 'p-reels-faceless');
  assert.equal(f.rc, 0, f.err);
  assert.deepEqual(ids(f.items), ['captions']);
  assert.equal(missing(fx, raw, 'p-reels-faceless').out, 'cover');
  const none = fx.raw.filter((x) => x.id !== 'cover' && x.id !== 'final_video');
  assert.equal(missing(fx, none, 'p-reels-faceless').out, 'final_video cover');
});

test('bare manifest naming only p-reels-spotlight keeps the earlier behaviour', (t) => {
  const fx = fixture(t, { recipe: 'p-reels-spotlight' });
  const raw = [
    { id: 'voice_track', path: '/s/voice_track.mp4' },
    { id: 'final_video', path: '/s/final_video.mp4' },
    { id: 'captions', path: '/s/captions.json' },
  ];
  const f = filter(fx, raw, 'p-reels-spotlight');
  assert.equal(f.out, '[{"id":"captions","path":"/s/captions.json"}]');
  assert.equal(missing(fx, raw, 'p-reels-spotlight').out, 'cover');
});

// ---------------------------------------------------------------------------
// 4. Carousel and image recipes: unchanged
// ---------------------------------------------------------------------------
test('carousel: harness list unchanged, slides delivered in order, never cover or sheet', (t) => {
  const manifest = manifestOf('p-carousel');
  const fx = fixture(t, manifest);
  const f = filter(fx, fx.raw, 'p-carousel');
  assert.equal(f.rc, 0, f.err);
  assert.equal(f.out, JSON.stringify(fx.raw), 'carousel list passes through byte for byte');
  assert.equal(missing(fx, fx.raw, 'p-carousel').out, '');

  const saves = path.join(fx.root, 'steps', 'render_slides', 'saves');
  mkdirSync(saves, { recursive: true });
  for (const name of ['slide_1.png', 'slide_2.png', 'slide_3.png', 'cover.png', 'slide_sheet.png']) {
    writeFileSync(path.join(saves, name), 'png');
  }
  writeFileSync(
    path.join(saves, 'slides.json'),
    JSON.stringify({ count: 3, slides: [1, 2, 3].map((n) => ({ n, sha256: 'x', bytes: 3 })) }),
  );
  const sel = selected(fx, JSON.parse(f.out));
  assert.deepEqual(sel.media, ['slide_1.png', 'slide_2.png', 'slide_3.png']);
  assert.deepEqual(sel.captions, ['captions.json']);
});

test('image recipe: filter leaves the list alone and the WI2.51 preview drop still applies', (t) => {
  const fx = fixture(t, manifestOf('p-gfx-image'));
  const f = filter(fx, fx.raw, 'p-gfx-image');
  assert.equal(f.out, JSON.stringify(fx.raw));
  const sel = selected(fx, fx.raw);
  assert.deepEqual(sel.media, ['image_1.png']);
  assert.ok(!sel.media.includes('contact_sheet.png') && !sel.media.includes('final.png'));
});

test('a manifest with no final_video and no finalOutputs is returned unchanged', (t) => {
  const manifest = {
    recipe: 'p-future',
    steps: [{ id: 'a', saves: [{ id: 'one', kind: 'image' }, { id: 'two', kind: 'video' }] }],
  };
  const fx = fixture(t, manifest);
  const f = filter(fx, fx.raw);
  assert.equal(f.out, JSON.stringify(fx.raw));
  assert.equal(missing(fx).out, '');
});

// ---------------------------------------------------------------------------
// 5. finalOutputs[] wins: exactly those saves
// ---------------------------------------------------------------------------
const FINAL_OUTPUTS_MANIFEST = {
  recipe: 'p-final-outputs',
  steps: [
    { id: 'build', saves: [{ id: 'draft_video', kind: 'video' }, { id: 'scratch', kind: 'image' }] },
    {
      id: 'finish',
      saves: [
        { id: 'master', kind: 'video' },
        { id: 'poster_img', kind: 'image' },
        { id: 'final_video', kind: 'video' },
        { id: 'cover', kind: 'image' },
        { id: 'notes', kind: 'json' },
        { id: 'caption_text', kind: 'json' },
      ],
    },
  ],
  finalOutputs: [
    { stepId: 'finish', saveId: 'master', role: 'deliverable' },
    { stepId: 'finish', saveId: 'poster_img', role: 'poster' },
    { stepId: 'finish', saveId: 'caption_text', role: 'captions' },
  ],
};

test('finalOutputs: exactly the listed saves, in that order, even when final_video and cover exist', (t) => {
  const fx = fixture(t, FINAL_OUTPUTS_MANIFEST);
  const f = filter(fx);
  assert.equal(f.rc, 0, f.err);
  assert.deepEqual(ids(f.items), ['master', 'poster_img', 'caption_text']);
  assert.equal(f.items[2].role, 'captions', 'a captions ref with a custom id is typed as captions');
  const sel = selected(fx, f.items);
  assert.deepEqual(sel.media, ['master.mp4', 'poster_img.png']);
  assert.deepEqual(sel.captions, ['caption_text.json']);
  assert.equal(missing(fx).out, '');
});

test('finalOutputs: items that already carry role and kind (local checkpoint) pass through untouched', (t) => {
  const fx = fixture(t, FINAL_OUTPUTS_MANIFEST);
  const local = [
    { id: 'master', path: `${fx.root}/steps/finish/saves/master.mp4`, role: 'deliverable', kind: 'video' },
    { id: 'poster_img', path: `${fx.root}/steps/finish/saves/poster_img.png`, role: 'poster', kind: 'image' },
    { id: 'caption_text', path: `${fx.root}/steps/finish/saves/caption_text.json`, role: 'captions', kind: 'json' },
  ];
  const f = filter(fx, local);
  assert.deepEqual(f.items, local);
});

test('finalOutputs: a missing deliverable ships no media and is named by its save id', (t) => {
  const fx = fixture(t, FINAL_OUTPUTS_MANIFEST);
  const raw = fx.raw.filter((x) => x.id !== 'poster_img');
  const f = filter(fx, raw);
  assert.equal(f.rc, 0, f.err);
  assert.deepEqual(ids(f.items), ['caption_text']);
  assert.equal(missing(fx, raw).out, 'poster_img');
});

test('finalOutputs: a malformed entry fails fast and delivers nothing', (t) => {
  for (const bad of [
    [{ stepId: 'finish', saveId: 'master' }],
    [{ stepId: 'finish', saveId: '', role: 'deliverable' }],
    [{ stepId: 'finish', saveId: 'master', role: 'cover' }],
    ['master'],
  ]) {
    const fx = fixture(t, { ...FINAL_OUTPUTS_MANIFEST, finalOutputs: bad });
    const f = filter(fx);
    assert.notEqual(f.rc, 0, `entry ${JSON.stringify(bad)} must be refused`);
    assert.equal(f.out, '', 'nothing printed to deliver');
    const m = missing(fx);
    assert.notEqual(m.rc, 0);
  }
  const notList = fixture(t, { ...FINAL_OUTPUTS_MANIFEST, finalOutputs: { saveId: 'master', role: 'deliverable' } });
  assert.notEqual(filter(notList).rc, 0);
});
