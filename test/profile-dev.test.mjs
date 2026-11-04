// test/profile-dev.test.mjs — WI27: CFW_RENDER_PROFILE=dev, a local-only worker.
//
//   node --test test/profile-dev.test.mjs
//
// The dev profile runs a second worker next to the installed one: its own
// settings file and folders (all under the hidden ~/.cfw-render-dev), the
// server http://localhost:3005, the launchd label com.cfw.render.dev. It must
// refuse a server that is not on this computer and every folder of the
// production install, and the installer must refuse to run under it. The
// production profile keeps every default exactly as before.
//
// Hermetic: a temp HOME only. It never touches the real ~/.cfw-render, the
// installed app or launchd, and makes no network call. Imports are node:* only.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BASH = spawnSync('bash', ['-c', 'command -v bash'], { encoding: 'utf8' }).stdout.trim();
const KEY = 'cfw_render_test0000000000000000';

function tmp(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `cfw-profile-${prefix}-`));
}

function bash(script, env = {}) {
  const r = spawnSync(BASH, ['-c', script, '_', REPO], {
    cwd: REPO,
    env: { PATH: process.env.PATH, ...env },
    encoding: 'utf8',
  });
  return { rc: r.status, out: r.stdout, err: r.stderr };
}

// Load the config in a fresh HOME and print the resolved values, one per line.
const SHOW = `source "$1/bin/cfw-render-lib.sh"
  cr_load_config >/dev/null 2>"$HOME/err" || { cat "$HOME/err" >&2; exit 7; }
  printf 'profile=%s\\nbase=%s\\nstate=%s\\nscratch=%s\\nhome=%s\\nlabel=%s\\nenvfile=%s\\n' \\
    "$CFW_RENDER_PROFILE" "$CFW_API_BASE" "$CFW_RENDER_STATE_DIR" "$CFW_RENDER_SCRATCH" \\
    "$CFW_RENDER_HOME" "$(cr_launchd_label)" "\${CFW_RENDER_ENV:-$(cr_default_env_file)}"`;

function fields(out) {
  return Object.fromEntries(out.trim().split('\n').map((l) => l.split(/=(.*)/s).slice(0, 2)));
}

test('production profile (unset) keeps every default exactly as before', () => {
  const home = tmp('prod');
  const r = bash(SHOW, { HOME: home, CFW_API_BASE: 'https://app.cfw.social', CFW_RENDER_WORKER_KEY: KEY });
  assert.equal(r.rc, 0, r.err);
  const f = fields(r.out);
  assert.equal(f.profile, 'prod');
  assert.equal(f.base, 'https://app.cfw.social');
  assert.equal(f.state, path.join(home, '.cfw-render'));
  assert.equal(f.scratch, path.join(home, '.cfw-render', 'scratch'));
  assert.equal(f.home, path.join(home, 'CFW Render'));
  assert.equal(f.label, 'com.cfw.render');
  assert.equal(f.envfile, path.join(home, '.cfw-render', 'cfw-render.env'));
});

test('dev profile: its own folders, localhost:3005 and the .dev launchd label', () => {
  const home = tmp('dev');
  const r = bash(SHOW, { HOME: home, CFW_RENDER_PROFILE: 'dev', CFW_RENDER_WORKER_KEY: KEY });
  assert.equal(r.rc, 0, r.err);
  const f = fields(r.out);
  assert.equal(f.profile, 'dev');
  assert.equal(f.base, 'http://localhost:3005');
  // The same layout the cfw-social seed writes (and the desktop app reads).
  assert.equal(f.state, path.join(home, '.cfw-render-dev', 'render-state'));
  assert.equal(f.scratch, path.join(home, '.cfw-render-dev', 'render-state', 'scratch'));
  assert.equal(f.home, path.join(home, '.cfw-render-dev', 'render-home'));
  assert.equal(f.label, 'com.cfw.render.dev');
  assert.equal(f.envfile, path.join(home, '.cfw-render-dev', 'cfw-render.env'));
  // Nothing of the production install was created.
  assert.equal(fs.existsSync(path.join(home, '.cfw-render')), false);
  assert.equal(fs.existsSync(path.join(home, 'CFW Render')), false);
});

test('dev profile reads its own settings file, and the file may set the profile', () => {
  const home = tmp('devfile');
  fs.mkdirSync(path.join(home, '.cfw-render-dev'));
  fs.writeFileSync(
    path.join(home, '.cfw-render-dev', 'cfw-render.env'),
    `CFW_API_BASE=http://127.0.0.1:3015\nCFW_RENDER_WORKER_KEY=${KEY}\n`,
    { mode: 0o600 },
  );
  const r = bash(SHOW, { HOME: home, CFW_RENDER_PROFILE: 'dev' });
  assert.equal(r.rc, 0, r.err);
  assert.equal(fields(r.out).base, 'http://127.0.0.1:3015');

  // A file named by CFW_RENDER_ENV can carry CFW_RENDER_PROFILE=dev itself.
  const other = path.join(home, 'local.env');
  fs.writeFileSync(other, `CFW_RENDER_PROFILE=dev\nCFW_RENDER_WORKER_KEY=${KEY}\n`, { mode: 0o600 });
  const r2 = bash(SHOW, { HOME: home, CFW_RENDER_ENV: other });
  assert.equal(r2.rc, 0, r2.err);
  assert.equal(fields(r2.out).profile, 'dev');
  assert.equal(fields(r2.out).state, path.join(home, '.cfw-render-dev', 'render-state'));
});

test('dev profile refuses a server that is not on this computer', () => {
  for (const base of ['https://app.cfw.social', 'https://v2.cfw.social', 'http://10.0.0.5:3005', 'http://localhost.evil.com']) {
    const home = tmp('devbase');
    const r = bash(SHOW, { HOME: home, CFW_RENDER_PROFILE: 'dev', CFW_API_BASE: base, CFW_RENDER_WORKER_KEY: KEY });
    assert.equal(r.rc, 7, `${base} should be refused`);
    assert.match(r.err, /only talks to CFW on this computer/);
    assert.doesNotMatch(r.err + r.out, new RegExp(KEY));
  }
});

test('dev profile refuses every production install folder and settings file', () => {
  const home = tmp('devpaths');
  const cases = {
    CFW_RENDER_STATE_DIR: path.join(home, '.cfw-render'),
    CFW_RENDER_SCRATCH: path.join(home, '.cfw-render', 'scratch'),
    CFW_RENDER_HOME: path.join(home, 'CFW Render'),
    CFW_RENDER_LOG_DIR: path.join(home, 'CFW Render', 'logs'),
    CFW_RENDER_OUTPUTS: path.join(home, 'CFW Render', 'outputs'),
    CFW_RENDER_WORKER_ID_FILE: path.join(home, '.cfw-render', 'worker-id'),
  };
  for (const [name, value] of Object.entries(cases)) {
    const r = bash(SHOW, { HOME: home, CFW_RENDER_PROFILE: 'dev', CFW_RENDER_WORKER_KEY: KEY, [name]: value });
    assert.equal(r.rc, 7, `${name} under the production install should be refused`);
    assert.match(r.err, new RegExp(`refusing ${name}`));
  }
  // The production settings file, named explicitly.
  fs.mkdirSync(path.join(home, '.cfw-render'), { recursive: true });
  const prodEnv = path.join(home, '.cfw-render', 'cfw-render.env');
  fs.writeFileSync(prodEnv, `CFW_RENDER_WORKER_KEY=${KEY}\n`, { mode: 0o600 });
  const r = bash(SHOW, { HOME: home, CFW_RENDER_PROFILE: 'dev', CFW_RENDER_ENV: prodEnv });
  assert.equal(r.rc, 7);
  assert.match(r.err, /never reads the production settings file/);
  // [review] Case, '..', '//', relative paths and symlinks name the same folders on APFS.
  fs.mkdirSync(path.join(home, 'CFW Render'), { recursive: true });
  fs.symlinkSync(path.join(home, '.cfw-render'), path.join(home, 'sneaky-link'));
  const tricks = [
    path.join(home, '.CFW-render'),
    `${home}//.cfw-render/state`,
    path.join(home, '.cfw-render-dev') + '/../.cfw-render',
    '.cfw-render',
    path.join(home, 'cfw render', 'logs'),
    path.join(home, 'sneaky-link', 'state'),
  ];
  for (const value of tricks) {
    const t = bash(SHOW, { HOME: home, CFW_RENDER_PROFILE: 'dev', CFW_RENDER_WORKER_KEY: KEY, CFW_RENDER_STATE_DIR: value });
    assert.equal(t.rc, 7, `${value} should be refused`);
    assert.match(t.err, /refusing CFW_RENDER_STATE_DIR/);
  }
  // A sibling folder that only shares the prefix is fine.
  const ok = bash(SHOW, {
    HOME: home, CFW_RENDER_PROFILE: 'dev', CFW_RENDER_WORKER_KEY: KEY,
    CFW_RENDER_STATE_DIR: path.join(home, '.cfw-render-devbox'),
  });
  assert.equal(ok.rc, 0, ok.err);
});

test('an unknown profile is refused', () => {
  const home = tmp('bad');
  const r = bash(SHOW, { HOME: home, CFW_RENDER_PROFILE: 'staging', CFW_RENDER_WORKER_KEY: KEY, CFW_API_BASE: 'http://localhost:3005' });
  assert.equal(r.rc, 7);
  assert.match(r.err, /CFW_RENDER_PROFILE must be prod or dev/);
});

test('install.sh refuses to run under the dev profile and creates nothing', () => {
  for (const args of [['--mode', 'byoa'], ['--uninstall', '--yes']]) {
    const home = tmp('install');
    const r = spawnSync(BASH, [path.join(REPO, 'install', 'install.sh'), ...args], {
      cwd: REPO,
      env: { PATH: process.env.PATH, HOME: home, CFW_RENDER_PROFILE: 'dev' },
      encoding: 'utf8',
    });
    assert.equal(r.status, 2, `${args.join(' ')}: ${r.stderr}`);
    assert.match(r.stderr, /only manage the production install/);
    assert.deepEqual(fs.readdirSync(home), []);
  }
});

test('restore: the dev profile trusts only its own dev object store', () => {
  const py = (env, url) => spawnSync('python3', ['-c', `
import importlib.util, sys
spec = importlib.util.spec_from_file_location("stage", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.approved_url(sys.argv[2], "", "", m.dev_base_from_env()))
`, path.join(REPO, 'bin', 'cfw-render-stage.py'), url], { env: { PATH: process.env.PATH, ...env }, encoding: 'utf8' }).stdout.trim();
  const dev = { CFW_RENDER_PROFILE: 'dev', CFW_API_BASE: 'http://localhost:3005' };
  const store = 'http://localhost:3005/api/v1/render/dev-object/brands/b/renders/o/x.png?token=t&exp=1';
  assert.equal(py(dev, store), 'True');
  assert.equal(py(dev, 'http://localhost:3005/api/v1/render/dev-object/brands/b/my%20clip.mp4?token=t'), 'True'); // encoded space ok
  assert.equal(py(dev, 'http://localhost:3005/api/v1/render/dev-object/../../mcp'), 'False');
  assert.equal(py(dev, 'http://localhost:3005/api/v1/render/dev-object/%2e%2e/%2e%2e/mcp'), 'False');
  assert.equal(py(dev, 'http://localhost:3005/api/v1/render/dev-object/a/%2E%2E%5Cmcp'), 'False');
  assert.equal(py(dev, 'http://localhost:3005/api/v1/mcp'), 'False');           // not the store
  assert.equal(py(dev, 'http://localhost:3006/api/v1/render/dev-object/x'), 'False'); // other port
  assert.equal(py(dev, 'https://media.cfw.social/brands/b/x.png'), 'True');     // production media still fine
  assert.equal(py({ CFW_API_BASE: 'http://localhost:3005' }, store), 'False');  // production profile: no
  assert.equal(py({ CFW_RENDER_PROFILE: 'dev', CFW_API_BASE: 'https://app.cfw.social' }, 'https://app.cfw.social/api/v1/render/dev-object/x'), 'False');
});

test('ctl clear-limit under the dev profile writes only the dev state folder', () => {
  const home = tmp('ctl');
  const r = spawnSync(BASH, [path.join(REPO, 'bin', 'cfw-render-ctl.sh'), 'clear-limit', 'gemini'], {
    cwd: REPO,
    env: { PATH: process.env.PATH, HOME: home, CFW_RENDER_PROFILE: 'dev' },
    encoding: 'utf8',
  });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(fs.existsSync(path.join(home, '.cfw-render')), false, 'never the production state folder');
  const bad = spawnSync(BASH, [path.join(REPO, 'bin', 'cfw-render-ctl.sh'), 'clear-limit', 'gemini'], {
    cwd: REPO,
    env: { PATH: process.env.PATH, HOME: home, CFW_RENDER_PROFILE: 'dev', CFW_RENDER_STATE_DIR: path.join(home, '.cfw-render') },
    encoding: 'utf8',
  });
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /never uses the production install folders/);
  assert.equal(fs.existsSync(path.join(home, '.cfw-render')), false);
});

test('ctl send-logs under the dev profile refuses a server that is not on this computer', () => {
  const home = tmp('ctlsend');
  const dev = path.join(home, '.cfw-render-dev');
  fs.mkdirSync(dev, { recursive: true });
  fs.writeFileSync(path.join(dev, 'cfw-render.env'), `CFW_RENDER_WORKER_KEY=${KEY}\n`, { mode: 0o600 });
  const r = spawnSync(BASH, [path.join(REPO, 'bin', 'cfw-render-ctl.sh'), 'send-logs', '--yes'], {
    cwd: REPO,
    // .invalid never resolves, so a missed guard could not reach any server.
    env: { PATH: process.env.PATH, HOME: home, CFW_RENDER_PROFILE: 'dev', CFW_RENDER_API_BASE: 'https://example.invalid' },
    encoding: 'utf8',
    timeout: 60_000,
  });
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /only sends logs to CFW on this computer|only talks to CFW on this computer/);
  assert.doesNotMatch(r.stdout + r.stderr, new RegExp(KEY));
});
