// render.mjs — render every <section class="slide" id="..."> in carousel.html to a PNG.
// Engine-agnostic: pure static HTML loaded over file://, screenshotted by headless Chromium.
// This is the proven hand-quality path (no web server, no AI image gen).
//
//   WIDTH=1080 HEIGHT=1350 SCALE=2 node render.mjs [carousel.html]
//
// Env: WIDTH/HEIGHT = slide size in CSS px (default 1080x1350, 4:5). SCALE = deviceScaleFactor
//      (default 2 = retina/sharp). Outputs slides/slide-<id>.png.
import { chromium } from 'playwright';
import { mkdir } from 'node:fs/promises';

const HTML  = process.argv[2] || 'carousel.html';
const WIDTH = parseInt(process.env.WIDTH  || '1080', 10);
const HEIGHT= parseInt(process.env.HEIGHT || '1350', 10);
const SCALE = parseInt(process.env.SCALE  || '2', 10);

await mkdir('slides', { recursive: true });
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: WIDTH, height: HEIGHT }, deviceScaleFactor: SCALE });
await page.goto('file://' + process.cwd() + '/' + HTML, { waitUntil: 'networkidle' });
await page.evaluate(() => document.fonts.ready);   // wait for webfonts so text isn't FOUT
await page.waitForTimeout(600);

// Auto-discover slides by id — works for any number of slides.
const ids = await page.$$eval('section.slide[id]', els => els.map(e => e.id));
if (ids.length === 0) { console.error('render.mjs: no <section class="slide" id="..."> found'); process.exit(2); }

for (const id of ids) {
  const el = await page.$('#' + id);
  await el.screenshot({ path: `slides/slide-${id.replace(/^s/, '')}.png` });
  console.log('rendered', id);
}
await browser.close();
console.log(`done — ${ids.length} slide(s) at ${WIDTH}x${HEIGHT} @${SCALE}x`);
