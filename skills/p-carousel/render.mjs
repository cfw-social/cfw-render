// render.mjs — render every <section class="slide" id="..."> in carousel.html to a PNG.
// Engine-agnostic: pure static HTML loaded over file://, screenshotted by headless Chromium.
// This is the proven hand-quality path (no web server, no AI image gen).
//
//   WIDTH=1080 HEIGHT=1350 SCALE=2 node render.mjs [carousel.html]
//
// Env: WIDTH/HEIGHT = slide size in CSS px (default 1080x1350, 4:5). SCALE = deviceScaleFactor
//      (default 2 = retina/sharp capture).
//
// CFW-131 — EXACT DIMS CONTRACT: the deliverable in slides/ is ALWAYS exactly WIDTH×HEIGHT px
// (the acceptance.json `dims` gate and the platform specs are exact — 1080×1350 for 4:5). The
// 2× capture is kept for sharpness but lands in slides-2x/; each PNG is then lanczos-downscaled
// with ffmpeg into slides/ and the output dims are ffprobe-verified. SCALE=1 skips the downscale.
// ffmpeg/ffprobe are required when SCALE>1 (fail fast, no silent 2160×2700 deliverable).
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import path from 'node:path';
import { mkdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';

// Playwright is installed in the step work folder (the process cwd). A static
// import resolves from this file's folder, which has no node_modules.
async function loadPlaywrightChromium() {
  const cwd = process.cwd();
  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  const workPlace = path.join(cwd, 'node_modules', 'playwright');
  const scriptPlace = path.join(scriptDir, 'node_modules', 'playwright');

  const pick = (mod) => {
    if (mod && mod.chromium) return mod.chromium;
    if (mod && mod.default && mod.default.chromium) return mod.default.chromium;
    return null;
  };

  let resolved = '';
  try {
    resolved = createRequire(cwd + '/').resolve('playwright', { paths: [cwd] });
  } catch {
    resolved = '';
  }
  if (resolved) {
    const workRoot = path.resolve(cwd) + path.sep;
    if (path.resolve(resolved).startsWith(workRoot)) {
      try {
        const picked = pick(await import(pathToFileURL(path.resolve(resolved)).href));
        if (picked) return picked;
      } catch {
        // The copy under the work folder did not load.
      }
    }
  }
  try {
    const picked = pick(await import('playwright'));
    if (picked) return picked;
  } catch {
    // Not installed beside this file either.
  }
  console.error(`render.mjs: Cannot find package 'playwright' in ${workPlace} or ${scriptPlace}`);
  process.exit(1);
}

const chromium = await loadPlaywrightChromium();

const HTML  = process.argv[2] || 'carousel.html';
const WIDTH = parseInt(process.env.WIDTH  || '1080', 10);
const HEIGHT= parseInt(process.env.HEIGHT || '1350', 10);
const SCALE = parseInt(process.env.SCALE  || '2', 10);

await mkdir('slides', { recursive: true });
const CAPTURE_DIR = SCALE > 1 ? 'slides-2x' : 'slides';
if (SCALE > 1) {
  await mkdir(CAPTURE_DIR, { recursive: true });
  for (const bin of ['ffmpeg', 'ffprobe']) {
    try { execFileSync(bin, ['-version'], { stdio: 'ignore' }); }
    catch { console.error(`render.mjs: ${bin} is required to downscale the ${SCALE}x capture to exactly ${WIDTH}x${HEIGHT} (install it or run with SCALE=1)`); process.exit(2); }
  }
}
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: WIDTH, height: HEIGHT }, deviceScaleFactor: SCALE });
await page.goto('file://' + process.cwd() + '/' + HTML, { waitUntil: 'networkidle' });
await page.evaluate(() => document.fonts.ready);   // wait for webfonts so text isn't FOUT
await page.waitForTimeout(600);

// Auto-discover slides by id — works for any number of slides.
const ids = await page.$$eval('section.slide[id]', els => els.map(e => e.id));
if (ids.length === 0) { console.error('render.mjs: no <section class="slide" id="..."> found'); process.exit(2); }

function probeDims(png) {
  const out = execFileSync('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'csv=p=0', png]).toString().trim();
  const [w, h] = out.split(',').map(Number);
  return { w, h };
}

for (const id of ids) {
  const el = await page.$('#' + id);
  const name = `slide-${id.replace(/^s/, '')}.png`;
  await el.screenshot({ path: `${CAPTURE_DIR}/${name}` });
  if (SCALE > 1) {
    // lanczos downscale → EXACT deliverable dims; keep the 2x capture next to it.
    execFileSync('ffmpeg', ['-v', 'error', '-y', '-i', `${CAPTURE_DIR}/${name}`,
      '-vf', `scale=${WIDTH}:${HEIGHT}:flags=lanczos`, `slides/${name}`], { stdio: 'inherit' });
  }
  const { w, h } = probeDims(`slides/${name}`);
  if (w !== WIDTH || h !== HEIGHT) { console.error(`render.mjs: slides/${name} is ${w}x${h}, expected ${WIDTH}x${HEIGHT}`); process.exit(1); }
  console.log('rendered', id, `${w}x${h}${SCALE > 1 ? ` (from ${SCALE}x capture in ${CAPTURE_DIR}/)` : ''}`);
}
await browser.close();
console.log(`done — ${ids.length} slide(s) at exactly ${WIDTH}x${HEIGHT}${SCALE > 1 ? ` (captured @${SCALE}x → ${CAPTURE_DIR}/, downscaled → slides/)` : ''}`);
