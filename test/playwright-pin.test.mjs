// test/playwright-pin.test.mjs — B8 / B10 (WI2.147): ONE pin for Playwright + Chromium.
//
//   node --test test/playwright-pin.test.mjs
//
// config/playwright-pin.json names the Playwright version and the Chromium revisions
// it needs. The recipe step, the worker preflight and the installer must all follow
// that one file. A fresh Mac once ran an unpinned `npm i playwright` (1.64.1) while its
// cache held only Chromium 1194, so chromium.launch() failed and no slide rendered.
//
// Hermetic: temp dirs only, fake `npm`/`npx` on PATH, a fake browser cache. It never
// launches a browser, installs anything, or touches the real cache or worker.
// Imports are node:* only.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const LIB = path.join(REPO, 'bin', 'cfw-render-lib.sh');
const read = (rel) => fs.readFileSync(path.join(REPO, rel), 'utf8');
const pin = JSON.parse(read('config/playwright-pin.json'));
// Absolute bash, so a test may give a child a PATH that holds nothing else.
const BASH = spawnSync('bash', ['-c', 'command -v bash'], { encoding: 'utf8' }).stdout.trim();

// The lines inside ``` fences that are not comments: the commands a step really runs.
function codeLines(text) {
  const out = [];
  let inFence = false;
  for (const line of text.split('\n')) {
    if (/^\s*```/.test(line)) { inFence = !inFence; continue; }
    if (inFence && !/^\s*#/.test(line)) out.push(line);
  }
  return out;
}

function tmp(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `cfw-pin-${prefix}-`));
}

function bash(script, { env = {}, cwd = REPO } = {}) {
  const r = spawnSync(BASH, ['-c', script, '_', REPO], {
    cwd,
    env: { PATH: process.env.PATH, HOME: process.env.HOME, ...env },
    encoding: 'utf8',
  });
  return { rc: r.status, out: r.stdout, err: r.stderr };
}

// Fake browser cache holding the given folder names; `done` ones get Playwright's
// INSTALLATION_COMPLETE marker (what a finished install leaves behind).
function fakeCache(done, unfinished = []) {
  const root = tmp('cache');
  for (const name of done) {
    fs.mkdirSync(path.join(root, name));
    fs.writeFileSync(path.join(root, name, 'INSTALLATION_COMPLETE'), '');
  }
  for (const name of unfinished) fs.mkdirSync(path.join(root, name));
  return root;
}

// A directory with a fake executable that records its argv, one line per call.
function fakeBin(name) {
  const dir = tmp(`bin-${name}`);
  const log = path.join(dir, `${name}.log`);
  fs.writeFileSync(
    path.join(dir, name),
    `#!/bin/bash\nprintf '%s\\n' "$*" >> "${log}"\n`,
    { mode: 0o755 },
  );
  return { dir, log };
}

const preflightChromium = (cacheRoot, extraEnv = {}) =>
  bash('source "$1/bin/cfw-render-lib.sh"; cr_preflight_chromium', {
    env: { PLAYWRIGHT_BROWSERS_PATH: cacheRoot, ...extraEnv },
  });

test('pin file: an exact x.y.z Playwright and numeric Chromium revisions', () => {
  assert.match(pin.playwright, /^\d+\.\d+\.\d+$/);
  assert.match(pin.chromiumRevision, /^\d+$/);
  assert.match(pin.chromiumHeadlessShellRevision, /^\d+$/);
});

test('the worker exports the pinned version to recipe steps, whatever the environment says', () => {
  const home = tmp('home');
  const r = bash(
    'source "$1/bin/cfw-render-lib.sh"; cr_load_config >/dev/null 2>&1 || exit 7; printf %s "$CFW_PLAYWRIGHT_PIN"',
    {
      env: {
        HOME: home,
        CFW_RENDER_ENV: '/dev/null',
        CFW_API_BASE: 'http://127.0.0.1:1',
        CFW_RENDER_WORKER_KEY: 'cfw_render_test0000000000000000',
        CFW_RENDER_HOME: path.join(home, 'CFW Render'),
        CFW_RENDER_STATE_DIR: path.join(home, 'state'),
        CFW_RENDER_SCRATCH: path.join(home, 'scratch'),
        CFW_PLAYWRIGHT_PIN: '9.9.9', // a stale value in the environment must not win
      },
    },
  );
  assert.equal(r.rc, 0, r.err);
  assert.equal(r.out, pin.playwright);
});

test('recipe step installs exactly the pinned version, and stops when no pin is delivered', () => {
  // Every install of playwright in a bundled recipe file names a version taken from the pin.
  const files = [
    'skills/p-carousel/SKILL.md',
    'skills/p-carousel/steps/03-render-slides.md',
    'skills/p-carousel/steps/_shared.md',
    'skills/p-gfx-image/steps/03-render.md',
  ];
  for (const rel of files) {
    for (const line of codeLines(read(rel))) {
      if (/\bnpm\s+(i|install)\b/.test(line) && /\bplaywright\b/.test(line)) {
        assert.match(line, /playwright@\$PW\b/, `${rel}: unpinned install: ${line.trim()}`);
      }
      if (/\bnpx\s+(-y\s+)?"?playwright\b/.test(line)) {
        assert.match(line, /playwright@\$\{CFW_PLAYWRIGHT_PIN/, `${rel}: unpinned npx: ${line.trim()}`);
      }
    }
  }

  // Run the real install lines of the render step against a fake npm.
  const md = read('skills/p-carousel/steps/03-render-slides.md');
  const block = md.match(/PW="\$\{CFW_PLAYWRIGHT_PIN:\?[\s\S]*?did not install" >&2; false; \}/);
  assert.ok(block, 'render step has no pinned install block');
  const work = tmp('step');
  fs.mkdirSync(path.join(work, 'work'));
  const npm = fakeBin('npm');
  const run = (env) =>
    spawnSync(BASH, ['-c', block[0]], {
      cwd: work,
      env: { PATH: `${npm.dir}:${process.env.PATH}`, ...env },
      encoding: 'utf8',
    });

  const without = run({});
  assert.notEqual(without.status, 0, 'step must stop when CFW_PLAYWRIGHT_PIN is not set');
  assert.match(without.stderr, /CFW_PLAYWRIGHT_PIN/);
  assert.ok(!fs.existsSync(npm.log), 'npm must not run without a pin');

  const withPin = run({ CFW_PLAYWRIGHT_PIN: pin.playwright });
  assert.equal(withPin.status, 0, withPin.stderr);
  const args = fs.readFileSync(npm.log, 'utf8');
  assert.match(args, new RegExp(`(^|\\s)playwright@${pin.playwright.replaceAll('.', '\\.')}(\\s|$)`));
});

test('preflight passes only when the exact pinned revision folders are cached and finished', () => {
  const want = [`chromium-${pin.chromiumRevision}`, `chromium_headless_shell-${pin.chromiumHeadlessShellRevision}`];
  const exact = preflightChromium(fakeCache(want));
  assert.equal(exact.rc, 0, exact.out);
  assert.match(exact.out, new RegExp(`Playwright ${pin.playwright.replaceAll('.', '\\.')}`));
});

test('preflight refuses another cached revision (B8: only 1194 cached, 1248 pinned) and says what to fix', () => {
  const stale = String(Number(pin.chromiumRevision) - 54);
  assert.notEqual(stale, pin.chromiumRevision);
  const r = preflightChromium(fakeCache([`chromium-${stale}`, `chromium_headless_shell-${stale}`]));
  assert.equal(r.rc, 1);
  assert.ok(r.out.includes(`chromium-${pin.chromiumRevision}`), r.out);
  assert.ok(r.out.includes(`chromium_headless_shell-${pin.chromiumHeadlessShellRevision}`), r.out);
  assert.ok(r.out.includes(`found: chromium-${stale}, chromium_headless_shell-${stale}`), r.out);
});

test('preflight refuses half a pair, an unfinished install, an empty cache, and a system Chrome', () => {
  const chromiumOnly = preflightChromium(fakeCache([`chromium-${pin.chromiumRevision}`]));
  assert.equal(chromiumOnly.rc, 1);

  const unfinished = preflightChromium(
    fakeCache([], [`chromium-${pin.chromiumRevision}`, `chromium_headless_shell-${pin.chromiumHeadlessShellRevision}`]),
  );
  assert.equal(unfinished.rc, 1);
  assert.match(unfinished.out, /is incomplete/);

  const empty = preflightChromium(fakeCache([]));
  assert.equal(empty.rc, 1);
  assert.match(empty.out, /no Playwright browsers/);

  const chrome = fakeBin('google-chrome');
  const system = preflightChromium(fakeCache([]), { PATH: `${chrome.dir}:${process.env.PATH}` });
  assert.equal(system.rc, 1, 'a system Chrome must not satisfy the pinned-browser check');
});

test('a missing or malformed pin file fails the preflight with the reason, never a default', () => {
  const copy = tmp('repo');
  fs.mkdirSync(path.join(copy, 'bin'));
  fs.mkdirSync(path.join(copy, 'config'));
  fs.copyFileSync(LIB, path.join(copy, 'bin', 'cfw-render-lib.sh'));
  const run = () =>
    spawnSync(BASH, ['-c', 'source "$1/bin/cfw-render-lib.sh"; cr_preflight_chromium', '_', copy], {
      env: { PATH: process.env.PATH, HOME: process.env.HOME, PLAYWRIGHT_BROWSERS_PATH: fakeCache([]) },
      encoding: 'utf8',
    });
  const missing = run();
  assert.equal(missing.status, 1);
  assert.match(missing.stdout, /playwright-pin\.json is missing/);

  fs.writeFileSync(path.join(copy, 'config', 'playwright-pin.json'), JSON.stringify({ ...pin, playwright: 'latest' }));
  const bad = run();
  assert.equal(bad.status, 1);
  assert.match(bad.stdout, /"playwright" must match/);
});

test('the fix hint and the installer name the pinned command', () => {
  const hint = bash('source "$1/bin/cfw-render-lib.sh"; cr_preflight_hint chromium');
  assert.equal(hint.rc, 0);
  assert.ok(hint.out.includes(`playwright@${pin.playwright} install`), hint.out);
  assert.ok(!/playwright install chromium/.test(hint.out), `bare, unpinned command: ${hint.out}`);

  const npx = fakeBin('npx');
  const ran = bash('source "$1/bin/cfw-render-lib.sh"; cr_install_pinned_chromium >/dev/null', {
    env: { PATH: `${npx.dir}:${process.env.PATH}` },
  });
  assert.equal(ran.rc, 0, ran.err);
  assert.equal(fs.readFileSync(npx.log, 'utf8').trim(), `--yes playwright@${pin.playwright} install chromium`);

  // No npx on PATH: rc 2, so install.sh falls through to the preflight that names node.
  const bare = tmp('bare');
  for (const tool of ['python3', 'dirname']) { // all the lib needs to be sourced and read the pin
    const real = spawnSync(BASH, ['-c', `command -v ${tool}`], { encoding: 'utf8' }).stdout.trim();
    fs.symlinkSync(real, path.join(bare, tool));
  }
  const noNpx = bash('source "$1/bin/cfw-render-lib.sh"; cr_install_pinned_chromium >/dev/null', { env: { PATH: bare } });
  assert.equal(noNpx.rc, 2, noNpx.err);
});

test('install.sh installs the pin before the preflight and ships the pin file', () => {
  const sh = read('install/install.sh');
  const update = sh.indexOf('if (( UPDATE )); then');
  const fresh = sh.indexOf('ensure_pinned_browser || true');
  const firstPreflight = sh.search(/\bcr_preflight\b(?! *\))/);
  assert.ok(update > 0 && fresh > update, 'install.sh never installs the pinned browser on the fresh path');
  assert.ok(fresh < firstPreflight, 'the pinned browser must be installed before the preflight runs');
  assert.ok(sh.includes('cp -a "$REPO_DIR/config/playwright-pin.json" "$PREFIX/config/"'), 'pin file is not copied to the install');
});

// ensure_pinned_browser is THE pin-install block of install.sh: the fresh install and
// `--from-app --update` both call it (B8 follow-up). The update path used to copy the new
// pin file and stop, so a Mac whose cache lacked the new revision had its worker's preflight
// refuse every claim after an app update.
const installSh = read('install/install.sh');
const ensureFn = installSh.match(/^ensure_pinned_browser\(\) \{\n[\s\S]*?\n\}\n/m);
const updateBranch = installSh.match(/^if \(\( UPDATE \)\); then\n[\s\S]*?\nfi\n/m);

test('the update path installs the pinned browser through the same function as the fresh install, before it replaces any file', () => {
  assert.ok(ensureFn, 'install.sh has no ensure_pinned_browser function');
  assert.ok(updateBranch, 'install.sh has no --update branch');
  const update = updateBranch[0];

  // ONE install block: the npx command lives in the lib helper, and install.sh reaches it
  // only through the function, so the two paths cannot drift apart.
  assert.equal(installSh.split('cr_install_pinned_chromium').length - 1, 1, 'install.sh must call the lib installer in one place');
  assert.ok(ensureFn[0].includes('cr_install_pinned_chromium'));
  assert.ok(ensureFn[0].includes('cr_preflight_chromium'), 'the install must run only when the pinned folders are missing');
  const calls = installSh.split('\n').filter((l) => /^\s*(PATH=\S+ )?ensure_pinned_browser\b/.test(l) && !l.includes('() {'));
  assert.equal(calls.length, 2, `expected the fresh path and the update path to call it: ${calls}`);

  // Update branch: lib sourced, pin installed, THEN fa_update copies the new files.
  const src = update.indexOf('source "$REPO_DIR/bin/cfw-render-lib.sh"');
  const call = update.indexOf('ensure_pinned_browser');
  const copy = update.search(/^\s*fa_update$/m);
  assert.ok(src > 0 && src < call, 'the update branch must source the lib before it installs the pin');
  assert.ok(copy > 0, 'the update branch no longer calls fa_update');
  assert.ok(call > 0 && call < copy, 'the pin must be installed before fa_update replaces the worker files');
  // The app starts the update with a GUI PATH that has no node/npx: look where the worker looks.
  assert.match(update, /PATH="\$\(cr_resolve_worker_path\):\$PATH" ensure_pinned_browser/);
  // No npx: stop the update (nothing replaced), never leave a worker that cannot claim.
  assert.match(update, /ensure_pinned_browser \|\| \{[\s\S]*app_fail checking 4/);
});

test('ensure_pinned_browser installs only a missing pin, announces it, and stops on a failed install', () => {
  assert.ok(ensureFn, 'install.sh has no ensure_pinned_browser function');
  const pinFolders = (root) => [
    path.join(root, `chromium-${pin.chromiumRevision}`),
    path.join(root, `chromium_headless_shell-${pin.chromiumHeadlessShellRevision}`),
  ];
  // A fake npx: records its argv; unless told to fail it leaves the finished folders behind.
  const fakeNpx = (cacheRoot, { fail = false } = {}) => {
    const dir = tmp('npx');
    const log = path.join(dir, 'npx.log');
    const make = pinFolders(cacheRoot).map((d) => `mkdir -p "${d}" && : > "${d}/INSTALLATION_COMPLETE"`).join('\n');
    fs.writeFileSync(path.join(dir, 'npx'), `#!/bin/bash\nprintf '%s\\n' "$*" >> "${log}"\n${fail ? 'echo "npx: network down" >&2; exit 1' : make}\n`, { mode: 0o755 });
    return { dir, log };
  };
  // Run the real function from install.sh with the lib sourced and the app helpers stubbed.
  const run = (cacheRoot, { npx, fromApp = 1, twice = false } = {}) =>
    bash(
      `source "$1/bin/cfw-render-lib.sh"
       set -euo pipefail
       FROM_APP=${fromApp}
       app_step() { printf 'STEP %s|%s|%s\\n' "$1" "$2" "$3"; }
       app_fail() { printf 'FAIL %s|%s|%s\\n' "$1" "$2" "$3"; exit "$2"; }
       eval "$ENSURE_FN"
       rc=0; ensure_pinned_browser || rc=$?
       ${twice ? 'ensure_pinned_browser || rc=$?' : ''}
       echo "RC=$rc"`,
      {
        env: {
          ENSURE_FN: ensureFn[0],
          PLAYWRIGHT_BROWSERS_PATH: cacheRoot,
          PATH: npx ? `${npx.dir}:${process.env.PATH}` : process.env.PATH,
        },
      },
    );

  // Pin already cached: nothing runs, nothing is announced (no behaviour change).
  const cached = fakeCache(pinFolders('').map((p) => path.basename(p)));
  const noop = fakeNpx(cached);
  const present = run(cached, { npx: noop });
  assert.equal(present.rc, 0, present.err);
  assert.match(present.out, /RC=0/);
  assert.ok(!present.out.includes('STEP'), `app step printed with the pin cached: ${present.out}`);
  assert.ok(!fs.existsSync(noop.log), 'npx must not run when the pinned folders are cached');

  // Pin missing (stale 1194 only): installs exactly the pinned command, once, and says so.
  const stale = String(Number(pin.chromiumRevision) - 54);
  const missing = fakeCache([`chromium-${stale}`, `chromium_headless_shell-${stale}`]);
  const npx = fakeNpx(missing);
  const updated = run(missing, { npx, twice: true });
  assert.equal(updated.rc, 0, updated.err);
  assert.match(updated.out, /RC=0/);
  assert.match(updated.out, /STEP checking\|started\|Installing the browser/);
  assert.equal(fs.readFileSync(npx.log, 'utf8').trim(), `--yes playwright@${pin.playwright} install chromium`, 'one pinned install, not repeated once cached');

  // npx fails: the app step reports exit 4 and the function never returns.
  const down = fakeCache([]);
  const bad = run(down, { npx: fakeNpx(down, { fail: true }) });
  assert.equal(bad.rc, 4, bad.out + bad.err);
  assert.match(bad.out, /FAIL checking\|4\|Could not install the browser/);
  assert.ok(!bad.out.includes('RC='), 'a failed install must not fall through');

  // Same failure outside the app: exits 1 with the plain message.
  const downCli = fakeCache([]);
  const cli = run(downCli, { npx: fakeNpx(downCli, { fail: true }), fromApp: 0 });
  assert.equal(cli.rc, 1, cli.out + cli.err);
  assert.match(cli.err, /ABORTING — the pinned Playwright browser could not be installed/);

  // No npx anywhere: rc 2 back to the caller, nothing installed.
  const bare = tmp('bare');
  for (const tool of ['python3', 'dirname', 'uname']) {
    const real = spawnSync(BASH, ['-c', `command -v ${tool}`], { encoding: 'utf8' }).stdout.trim();
    fs.symlinkSync(real, path.join(bare, tool));
  }
  const none = bash(
    `source "$1/bin/cfw-render-lib.sh"; set -euo pipefail; FROM_APP=1
     app_step() { printf 'STEP %s\\n' "$1"; }; app_fail() { printf 'FAIL\\n'; exit "$2"; }
     eval "$ENSURE_FN"; rc=0; ensure_pinned_browser || rc=$?; echo "RC=$rc"`,
    { env: { ENSURE_FN: ensureFn[0], PLAYWRIGHT_BROWSERS_PATH: fakeCache([]), PATH: bare } },
  );
  assert.equal(none.rc, 0, none.err);
  assert.match(none.out, /RC=2/);
  assert.ok(!none.out.includes('FAIL'));
});

test('the bundled recipe files still match the pinned hashes in skills/index.json', () => {
  const r = spawnSync(BASH, ['scripts/verify-skills-bundle.sh', 'p-carousel', 'p-gfx-image'], {
    cwd: REPO,
    env: { PATH: process.env.PATH, HOME: process.env.HOME },
    encoding: 'utf8',
  });
  assert.equal(r.status, 0, r.stdout + r.stderr);
});
