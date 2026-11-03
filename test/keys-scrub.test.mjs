// test/keys-scrub.test.mjs — WI2.152 / B14 + B39: provider keys, the worker key
// and signed approval links stay out of model prompts and logs.
//
//   cd test && node --test keys-scrub.test.mjs
//
// Hermetic: the real harness, engine, report and lib code run against a fake
// claim, a fake engine, a fake curl and a fake Keychain command. Every secret
// below is a made-up fixture value. No network, no process stops, no real keys.
// Imports are node:* only. No skips.
import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BIN = path.join(REPO, 'bin');

// Fake secrets, each placed exactly where a real one could appear.
const HEYGEN = 'fakekey_0123456789abcdef';
const ELEVEN = 'fakekey_fedcba9876543210';
const OAUTH = 'faketoken_aaaabbbbccccdddd';
const REFRESH = 'fakerefresh_1111222233334444';
const NAMED_A = 'fakenamed_a_5555666677778888';
const NAMED_B = 'fakenamed_b_9999000011112222';
const NESTED = 'fakenested_3333444455556666';
const WORKER = 'cfw_render_fakeworker0123456789';
const ALL_SECRETS = [HEYGEN, ELEVEN, OAUTH, REFRESH, NAMED_A, NAMED_B, NESTED, WORKER];

const APPROVAL_TOKEN = 'FAKEapprovalTok1';
const APPROVAL_REPLY = {
  ok: true,
  compositionId: 'comp-fixture-1',
  approvalUrl: `https://app.cfw.social/a/${APPROVAL_TOKEN}`,
};

const PROVIDER_ENV = ['HEYGEN_API_KEY', 'ELEVENLABS_API_KEY', 'KIE_AI_API_KEY',
  'GEMINI_API_KEY', 'FAL_KEY', 'REPLICATE_API_TOKEN'];

// macOS /bin/bash is 3.2 and breaks the harness here-docs inside <( ... ). Put
// the bash 4+ directories first, exactly as gate-suite.test.mjs does.
function cleanEnv(extra = {}) {
  const parts = (process.env.PATH || '/usr/bin:/bin').split(':').filter(Boolean);
  const first = ['/opt/homebrew/bin', '/usr/local/bin'];
  const rest = parts.filter((dir) => !first.includes(dir));
  return { PATH: [...first, ...rest].join(':'), LC_ALL: 'C', PYTHONDONTWRITEBYTECODE: '1', ...extra };
}

function tmp(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `keys-scrub-${prefix}-`));
}

function bash(script, env, args = [], cwd = undefined) {
  const result = spawnSync('bash', ['-c', script, 'keys-scrub', ...args], {
    env, cwd, encoding: 'utf8', timeout: 90 * 1000,
  });
  assert.equal(result.error, undefined, String(result.error));
  return result;
}

function noSecret(text, where) {
  for (const secret of ALL_SECRETS) {
    assert.ok(!text.includes(secret), `${where} contains fake secret ${secret.slice(0, 14)}...`);
  }
}

function fixtureOrder() {
  return {
    id: 'fixture-order',
    attempt: { id: 'fixture-attempt' },
    manifest: {
      recipe: 'fixture',
      steps: [
        { id: 'plain', runsOn: 'computer', saves: [{ id: 'out', kind: 'text' }] },
        { id: 'nouses', runsOn: 'computer', saves: [] },
        { id: 'tools', runsOn: 'computer', uses: { tools: ['python3'] }, saves: [] },
        { id: 'heygen', runsOn: 'computer', uses: { providers: [['heygen']] }, saves: [] },
        { id: 'either', runsOn: 'computer',
          uses: { providers: [['heygen', 'elevenlabs']], optionalProviders: ['kie'] }, saves: [] },
      ],
    },
    // Top level, exactly where Social puts it.
    providerKeys: [
      { provider: 'heygen', value: HEYGEN, expiresAt: '2999-01-01T00:00:00Z' },
      { provider: 'elevenlabs', value: ELEVEN, expiresAt: '2999-01-01T00:00:00Z' },
    ],
    taskOrder: {
      recipe: 'fixture',
      intent: `Make a reel about focus. Do not paste ${HEYGEN} anywhere. Worker ${WORKER}.`,
      targets: ['instagram'],
      brand: {
        slug: 'fixture-brand',
        name: 'Fixture Brand',
        brief: `Warm voice. Backup key ${ELEVEN} lives in the notes.`,
        heygen: { avatarId: 'avatar-1', voiceId: 'voice-1', apiKey: NAMED_A },
        palette: { primary: '#112233', accessToken: NESTED },
      },
      // Nested and repeated: a credentials block, env-named fields at two depths,
      // and one secret under two different names.
      credentials: { heygen: { mode: 'oauth', accessToken: OAUTH, refreshToken: REFRESH,
        expiresAt: '2999-01-01T00:00:00Z' } },
      directives: [
        { kind: 'note', text: 'keep it short', HEYGEN_API_KEY: NAMED_A },
        { kind: 'note', deeper: { list: [{ ELEVENLABS_API_KEY: NAMED_B }, { FAL_KEY: NAMED_B }] } },
        // Provider-named keys in other spellings; and ordinary data that merely ends in "key".
        { kind: 'opts', falKey: NAMED_B, elevenlabs_key: NAMED_A, cache_key: 'cache-1', sortKey: 'order-1' },
      ],
      ingredients: [{ inputId: 'photo', items: [{ kind: 'image', url: 'https://media.cfw.social/p.png' }] }],
    },
    answers: [{ inputId: 'q1', text: `my key is ${HEYGEN}` }],
    feedback: `last try failed, key ${ELEVEN} was rejected`,
  };
}

function writeOrder(dir, order = fixtureOrder()) {
  const file = path.join(dir, 'order.json');
  fs.writeFileSync(file, JSON.stringify(order), { mode: 0o600 });
  return file;
}

// ---------------------------------------------------------------- finding 1
test('prompt.md and brief.json carry no fake key, token or worker key', () => {
  const dir = tmp('prompt');
  const recipe = path.join(dir, 'recipe');
  fs.mkdirSync(path.join(recipe, 'steps'), { recursive: true });
  fs.writeFileSync(path.join(recipe, 'steps', '_shared.md'), '# shared rules\n');
  const workdir = path.join(dir, 'work');
  fs.mkdirSync(workdir);
  const order = writeOrder(dir);
  const result = bash(
    `set -euo pipefail
     source "$1/cfw-render-harness.sh"
     CR_H_RECIPE_DIR="$2"
     cr_h_build_prompt plain "$3" "$4"
     cr_h_write_brief "$3" "$4"`,
    cleanEnv({ HOME: dir, CFW_RENDER_WORKER_KEY: WORKER }),
    [BIN, recipe, workdir, order],
  );
  assert.equal(result.status, 0, result.stderr);

  const prompt = fs.readFileSync(path.join(workdir, 'prompt.md'), 'utf8');
  const brief = fs.readFileSync(path.join(workdir, 'brief.json'), 'utf8');
  noSecret(prompt, 'prompt.md');
  noSecret(brief, 'brief.json');
  noSecret(result.stdout + result.stderr, 'harness output');

  // Secret-named keys are dropped, whatever the depth and however often they repeat.
  for (const name of ['credentials', 'accessToken', 'refreshToken', 'apiKey', 'falKey', 'elevenlabs_key',
    'HEYGEN_API_KEY', 'ELEVENLABS_API_KEY', 'FAL_KEY', 'providerKeys']) {
    assert.ok(!prompt.includes(`"${name}"`), `prompt.md still has a "${name}" field`);
  }
  // A secret pasted into free text is masked, not dropped.
  assert.match(prompt, /Do not paste \[redacted\] anywhere/);
  assert.match(prompt, /my key is \[redacted\]/);
  assert.match(prompt, /key \[redacted\] was rejected/);
  // Everything the recipe needs is still there.
  for (const keep of ['fixture-brand', 'Make a reel about focus', 'avatar-1', 'voice-1',
    '#112233', 'https://media.cfw.social/p.png', 'keep it short', 'saves/out.md',
    '"cache_key": "cache-1"', '"sortKey": "order-1"']) {
    assert.ok(prompt.includes(keep), `prompt.md lost "${keep}"`);
  }
  const parsed = JSON.parse(brief);
  assert.equal(parsed.brand.slug, 'fixture-brand');
  assert.equal(parsed.brand.heygen.avatarId, 'avatar-1');
  assert.equal(parsed.brand.palette.primary, '#112233');
  assert.ok(!('accessToken' in parsed.brand.palette));
});

test('a claim with no secrets passes through the prompt unchanged', () => {
  const dir = tmp('clean');
  const recipe = path.join(dir, 'recipe');
  fs.mkdirSync(path.join(recipe, 'steps'), { recursive: true });
  const workdir = path.join(dir, 'work');
  fs.mkdirSync(workdir);
  const order = fixtureOrder();
  delete order.providerKeys;
  delete order.feedback;
  order.taskOrder = { recipe: 'fixture', intent: 'Plain intent', targets: ['instagram'],
    brand: { slug: 'fixture-brand' }, ingredients: [] };
  order.answers = [{ inputId: 'q1', text: 'plain answer' }];
  const file = writeOrder(dir, order);
  const result = bash(
    `set -euo pipefail; source "$1/cfw-render-harness.sh"; CR_H_RECIPE_DIR="$2"; cr_h_build_prompt plain "$3" "$4"`,
    cleanEnv({ HOME: dir }), [BIN, recipe, workdir, file]);
  assert.equal(result.status, 0, result.stderr);
  const prompt = fs.readFileSync(path.join(workdir, 'prompt.md'), 'utf8');
  assert.ok(prompt.includes('"intent": "Plain intent"'));
  assert.ok(prompt.includes('plain answer'));
  assert.ok(!prompt.includes('[redacted]'));
});

// ---------------------------------------------------------------- finding 3
test('a step with no `uses` receives no provider key; `uses` still scopes the rest', () => {
  const dir = tmp('stepkeys');
  const order = writeOrder(dir);
  const probe = (step) => {
    const result = bash(
      `set -euo pipefail
       source "$1/cfw-render-harness.sh"
       cr_h_export_step_keys "$2" "$3"
       for name in ${PROVIDER_ENV.join(' ')}; do
         if [[ -n "\${!name+x}" ]]; then printf '%s\\n' "$name"; fi
       done`,
      cleanEnv({ HOME: dir }), [BIN, order, step]);
    assert.equal(result.status, 0, `${step}: ${result.stderr}`);
    noSecret(result.stdout + result.stderr, `${step} output`);
    return result.stdout.split('\n').filter(Boolean);
  };
  assert.deepEqual(probe('nouses'), [], 'a step without `uses` must get no key');
  assert.deepEqual(probe('plain'), [], 'a step without `uses` must get no key');
  assert.deepEqual(probe('tools'), [], '`uses` with only tools gets no key');
  assert.deepEqual(probe('heygen'), ['HEYGEN_API_KEY']);
  // optional kie is not delivered, so only the two delivered providers appear.
  assert.deepEqual(probe('either'), ['HEYGEN_API_KEY', 'ELEVENLABS_API_KEY']);
});

test('every computer step in every recipe manifest declares `uses`', () => {
  // The rule above is only safe if no step that runs the coder relies on the
  // old "no uses = every key" default. Server steps never start a coder.
  const skills = path.join(REPO, 'skills');
  let checked = 0;
  for (const recipe of fs.readdirSync(skills)) {
    const file = path.join(skills, recipe, 'manifest.json');
    if (!fs.existsSync(file)) continue;
    const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
    for (const step of manifest.steps || []) {
      if ((step.runsOn ?? 'computer') !== 'computer') continue;
      checked += 1;
      assert.ok(step.uses && typeof step.uses === 'object',
        `${recipe}/${step.id} runs on the computer but declares no \`uses\``);
    }
  }
  assert.ok(checked > 40, `only ${checked} computer steps checked`);
});

// ---------------------------------------------------------------- finding 2
function fakeEngine(dir) {
  const file = path.join(dir, 'fake-engine.sh');
  fs.writeFileSync(file, `#!/usr/bin/env bash
cat >/dev/null
env > "$KS_REPORT"
`, { mode: 0o755 });
  return file;
}

function runEngine(engine, extraEnv = {}) {
  const dir = tmp(`engine-${engine}`);
  const work = path.join(dir, 'work');
  fs.mkdirSync(work);
  fs.mkdirSync(path.join(dir, 'logs'));
  fs.mkdirSync(path.join(dir, 'state'));
  fs.writeFileSync(path.join(work, 'prompt.md'), 'render the fixture\n');
  const security = path.join(dir, 'security.sh');
  // A fake Keychain: no item for gemini, a fake key for the API engines.
  fs.writeFileSync(security, `#!/usr/bin/env bash
case "$*" in *-a\\ gemini*) exit 1 ;; esac
case "$*" in *-w*) printf '%s' fakeapikey_77778888999900001111 ;; esac
exit 0
`, { mode: 0o755 });
  const report = path.join(dir, 'engine-env.txt');
  const result = bash(
    `set -uo pipefail
     source "$1/cfw-render-lib.sh"
     source "$1/cfw-render-engine.sh"
     export CR_ENGINE_SANDBOX_MODE=enclosing   # the unset does not depend on sandbox-exec
     cr_engine_run "$2" "$3/prompt.md" "$3" "$3/step.log"
     rc=$?
     printf 'rc=%s\\n' "$rc"
     printf 'parent_worker_key=%s\\n' "\${CFW_RENDER_WORKER_KEY:+kept}"`,
    cleanEnv({
      HOME: dir,
      CFW_RENDER_LOG_DIR: path.join(dir, 'logs'),
      CFW_RENDER_STATE_DIR: path.join(dir, 'state'),
      CFW_RENDER_ENGINE_CMD: `bash ${fakeEngine(dir)}`,
      CFW_RENDER_SECURITY_CMD: security,
      KS_REPORT: report,
      // What the worker exports at cfw-render.sh:380, plus a delivered provider key.
      CFW_RENDER_WORKER_KEY: WORKER,
      CFW_API_BASE: 'http://127.0.0.1:1',
      CFW_WORKER_ID: 'fixture-worker',
      CFW_ORDER_ID: 'fixture-order',
      HEYGEN_API_KEY: HEYGEN,
      ...extraEnv,
    }),
    [BIN, engine, work]);
  const log = fs.existsSync(path.join(work, 'step.log')) ? fs.readFileSync(path.join(work, 'step.log'), 'utf8') : '';
  assert.match(result.stdout, /rc=0/, `${engine}: ${result.stdout}${result.stderr}${log}`);
  assert.ok(fs.existsSync(report), `${engine}: the fake engine never ran`);
  return { env: fs.readFileSync(report, 'utf8'), stdout: result.stdout, stderr: result.stderr, log };
}

for (const engine of ['claude-code', 'gemini', 'zai']) {
  test(`the ${engine} model process does not inherit the worker key`, () => {
    const { env, stdout, stderr, log } = runEngine(engine);
    const names = env.split('\n').map((line) => line.split('=')[0]);
    assert.ok(!names.includes('CFW_RENDER_WORKER_KEY'), 'CFW_RENDER_WORKER_KEY is in the coder env');
    assert.ok(!env.includes(WORKER), 'the worker key value is in the coder env');
    // Only the worker's own auth is removed. The rest of the env, including the
    // provider key the step was given, is untouched (that redesign is a separate item).
    for (const kept of ['CFW_API_BASE', 'CFW_WORKER_ID', 'CFW_ORDER_ID', 'CFW_ENGINE_NAME']) {
      assert.ok(names.includes(kept), `${kept} should still reach the coder`);
    }
    assert.ok(names.includes('HEYGEN_API_KEY'), 'provider keys are out of scope for this patch');
    // The worker itself keeps its key for report/upload/heartbeat calls.
    assert.match(stdout, /parent_worker_key=kept/);
    assert.ok(!(stdout + stderr + log).includes(WORKER), 'the worker key leaked into output or the step log');
  });
}

test('every model-process subshell in cfw-render-engine.sh drops the worker auth first', () => {
  const source = fs.readFileSync(path.join(BIN, 'cfw-render-engine.sh'), 'utf8');
  const calls = source.split('\n').filter((line) => line.trim() === 'cr_engine_drop_worker_auth');
  // claude/codex (cr_engine_run), gemini, and the API-key engines.
  assert.equal(calls.length, 3);
});

// ---------------------------------------------------------------- finding 4
function reportEnv(dir, extra = {}) {
  const fakeBin = path.join(dir, 'fakebin');
  fs.mkdirSync(fakeBin, { recursive: true });
  const reply = path.join(dir, 'reply.json');
  fs.writeFileSync(reply, JSON.stringify({
    jsonrpc: '2.0', id: 1,
    result: { content: [{ type: 'text', text: JSON.stringify(APPROVAL_REPLY) }] },
  }));
  fs.writeFileSync(path.join(fakeBin, 'curl'), '#!/usr/bin/env bash\ncat "$KS_REPLY"\n', { mode: 0o755 });
  return cleanEnv({
    HOME: dir, TMPDIR: dir, KS_REPLY: reply,
    PATH: `${fakeBin}:${cleanEnv().PATH}`,
    CFW_ORDER_ID: 'fixture-order', CFW_WORKER_ID: 'fixture-worker',
    CFW_API_BASE: 'http://127.0.0.1:1', CFW_RENDER_WORKER_KEY: WORKER,
    ...extra,
  });
}

function stagedReport(dir) {
  // The report script finds its siblings next to itself; stub the uploader.
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin, { recursive: true });
  for (const name of ['cfw-render-report.sh', 'cfw-render-lib.sh', 'cfw-render-checkpoint.py']) {
    fs.copyFileSync(path.join(BIN, name), path.join(bin, name));
  }
  fs.writeFileSync(path.join(bin, 'cfw-render-upload.sh'),
    '#!/usr/bin/env bash\nprintf "https://media.cfw.social/out.mp4"\n', { mode: 0o755 });
  return path.join(bin, 'cfw-render-report.sh');
}

test('the completion reply printed by the worker has the approval token redacted', () => {
  const dir = tmp('report');
  const report = stagedReport(dir);
  const cwd = path.join(dir, 'order');
  fs.mkdirSync(path.join(cwd, 'final'), { recursive: true });
  fs.writeFileSync(path.join(cwd, 'final', 'out.mp4'), 'not really a video');
  const result = bash('bash "$1" complete final/out.mp4', reportEnv(dir), [report], cwd);
  assert.equal(result.status, 0, result.stderr);
  const printed = result.stdout + result.stderr;
  assert.ok(!printed.includes(APPROVAL_TOKEN), 'the approval token was printed');
  assert.ok(printed.includes('https://app.cfw.social/a/<token>'), `no redacted link in: ${printed}`);
  assert.ok(printed.includes('comp-fixture-1'), 'the rest of the reply should survive');
  noSecret(printed, 'report output');
});

test('stage and block replies are redacted too', () => {
  const dir = tmp('stage');
  const report = stagedReport(dir);
  const cwd = path.join(dir, 'order');
  fs.mkdirSync(cwd, { recursive: true });
  for (const verb of ['stage fetch 10 "Gathering"', 'block "stopped on purpose"']) {
    const result = bash(`bash "$1" ${verb}`, reportEnv(dir), [report], cwd);
    assert.equal(result.status, 0, `${verb}: ${result.stderr}`);
    const printed = result.stdout + result.stderr;
    assert.ok(!printed.includes(APPROVAL_TOKEN), `${verb} printed the token`);
    assert.ok(printed.includes('/a/<token>'), `${verb}: ${printed}`);
  }
});

test('redaction keeps the path, masks the token, and leaves plain text alone', () => {
  const dir = tmp('redact');
  const report = stagedReport(dir);
  const cwd = path.join(dir, 'order');
  fs.mkdirSync(cwd, { recursive: true });
  const T = APPROVAL_TOKEN;
  const reply = {
    approvalUrl: `https://app.cfw.social/a/${T}`,
    trailingSlash: `see https://app.cfw.social/a/${T}/ and https://x.test/approve/${T}?v=1`,
    query: `https://media.cfw.social/o.mp4?token=${T}&sig=${T}&w=2`,
    plain: 'https://app.cfw.social/brands/abc and nothing to hide',
  };
  const env = reportEnv(dir);
  // reportEnv() writes a default reply.json; replace it with ours.
  fs.writeFileSync(path.join(dir, 'reply.json'), JSON.stringify({
    jsonrpc: '2.0', id: 1, result: { content: [{ type: 'text', text: JSON.stringify(reply) }] },
  }));
  const result = bash('bash "$1" stage fetch 10 "Gathering"', env, [report], cwd);
  assert.equal(result.status, 0, result.stderr);
  assert.ok(!result.stdout.includes(T), 'a token was printed');
  assert.deepEqual(JSON.parse(result.stdout), {
    approvalUrl: 'https://app.cfw.social/a/<token>',
    trailingSlash: 'see https://app.cfw.social/a/<token>/ and https://x.test/approve/<token>?v=1',
    query: 'https://media.cfw.social/o.mp4?token=<token>&sig=<token>&w=2',
    plain: 'https://app.cfw.social/brands/abc and nothing to hide',
  });
});

test('provider-wait works without the worker key; stage still needs it', () => {
  const dir = tmp('wait');
  const report = stagedReport(dir);
  const cwd = path.join(dir, 'order');
  fs.mkdirSync(cwd, { recursive: true });
  const wait = path.join(cwd, 'wait.log');
  fs.writeFileSync(wait, '');
  const env = reportEnv(dir, { CFW_RENDER_WAIT_FILE: wait, CFW_RENDER_SCRATCH_DIR: cwd });
  delete env.CFW_RENDER_WORKER_KEY;
  const ok = bash('bash "$1" provider-wait-start heygen && bash "$1" provider-wait-end heygen', env, [report], cwd);
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(fs.readFileSync(wait, 'utf8').trim().split('\n').length, 2);
  const stage = bash('bash "$1" stage fetch 10 "Gathering"', env, [report], cwd);
  assert.notEqual(stage.status, 0);
  assert.match(stage.stderr, /CFW_RENDER_WORKER_KEY not set/);
});

// ------------------------------------------------------------------ logs (S8)
test('an odd-shaped claim reply is logged by shape only, never with its provider keys', () => {
  const dir = tmp('shape');
  const result = bash(
    `source "$1/cfw-render-lib.sh"
     fake_value="$2"
     cr_curl_with_key() {
       printf '%s' '{"jsonrpc":"2.0","id":1,"result":{"content":[],"providerKeys":[{"provider":"heygen","value":"'"$fake_value"'"}]}}'
     }
     cr_mcp_call claim_render_order '{}'`,
    cleanEnv({ HOME: dir, CFW_API_BASE: 'http://127.0.0.1:1', CFW_RENDER_WORKER_KEY: WORKER }), [BIN, HEYGEN]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /unexpected result shape/);
  noSecret(result.stdout + result.stderr, 'cr_mcp_call output');
});
