// test/node-suite.test.mjs — runner entry for the CFW Render bash suite.
//
//   node --test test/node-suite.test.mjs
//     -> bash test/run-tests.sh (repo root, own process group)
//     -> every "  PASS  <name>" / "  FAIL  <name> — <why>" line becomes one
//        node subtest; a FAIL line is a failing subtest carrying its message.
//
// The file fails when run-tests.sh exits non-zero, when any FAIL line appears,
// when zero cases ran, or when the suite outlives SUITE_TIMEOUT_MS (then only
// the suite's own process group is killed). No dependencies beyond node:*.
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import path from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SUITE_SCRIPT = path.join('test', 'run-tests.sh');
// The bound suite takes 50-60+ minutes under load, so a 60-minute cap
// stops it before the later cases run. The cap is 100 minutes unless
// CFW_SUITE_TIMEOUT_MIN is a positive whole number of minutes. Any other
// value, including one setTimeout cannot schedule, stays at 100. The
// failure text below names that cap.
const DEFAULT_SUITE_TIMEOUT_MIN = 100;
const SUITE_TIMEOUT_MAX_MS = 2147483647;

function suiteTimeoutMsFrom(raw) {
  const fallback = DEFAULT_SUITE_TIMEOUT_MIN * 60 * 1000;
  if (typeof raw !== 'string' || !/^[1-9][0-9]*$/.test(raw)) return fallback;
  const minutes = Number(raw);
  const ms = minutes * 60 * 1000;
  if (!Number.isSafeInteger(ms) || ms <= 0 || ms > SUITE_TIMEOUT_MAX_MS) return fallback;
  return ms;
}

const SUITE_TIMEOUT_MS = suiteTimeoutMsFrom(process.env.CFW_SUITE_TIMEOUT_MIN);
const KILL_GRACE_MS = 10 * 1000;

const timeoutChecks = [
  [undefined, 100],
  ['', 100],
  ['0', 100],
  ['-4', 100],
  ['1.5', 100],
  ['60min', 100],
  [' 60', 100],
  ['08', 100],
  ['999999999', 100],
  ['1', 1],
  ['60', 60],
  ['90', 90],
  ['100', 100],
];
for (const [raw, minutes] of timeoutChecks) {
  const got = suiteTimeoutMsFrom(raw);
  if (got !== minutes * 60 * 1000) {
    throw new Error(`CFW_SUITE_TIMEOUT_MIN ${JSON.stringify(raw)} resolved to ${got} ms, want ${minutes} minutes`);
  }
}

// "  PASS  name" and "  FAIL  name — why" (test/run-tests.sh pass()/fail(),
// plus the same shape printed by its python blocks). The final
// "PASS: n   FAIL: m" summary line is a different shape on purpose.
const CASE_LINE = /^\s*(PASS|FAIL)  (.*\S)\s*$/;
const SUMMARY_LINE = /^PASS: (\d+)\s+FAIL: (\d+)\s*$/;
// cr_preflight's own rows ("  PASS  ffmpeg                 7.1") share the
// shape but are a label padded to 22 columns, then a detail. They are the
// worker's output that a case captured, not a case verdict; the case that
// runs the worker reports its own PASS/FAIL. Suite names never carry two
// spaces in a row.
const PREFLIGHT_ROW = /^\s*(PASS|FAIL)  \S+\s{2,}\S/;

function killGroup(child, signal) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  try {
    // Negative pid: the whole process group the suite was started in, which
    // is its own (detached), never the runner's.
    process.kill(-child.pid, signal);
  } catch {
    try { child.kill(signal); } catch { /* already gone */ }
  }
}

function uniqueName(seen, name) {
  const n = (seen.get(name) ?? 0) + 1;
  seen.set(name, n);
  return n === 1 ? name : `${name} (${n})`;
}

test(`bash ${SUITE_SCRIPT}`, { timeout: SUITE_TIMEOUT_MS + KILL_GRACE_MS + 60 * 1000 }, async (t) => {
  const child = spawn('bash', [SUITE_SCRIPT], {
    cwd: REPO_ROOT,
    env: process.env,
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: true,
  });

  // If the runner stops this process, take the suite's process group with it.
  const stopOnSignal = (signal) => { killGroup(child, 'SIGTERM'); process.exit(signal === 'SIGINT' ? 130 : 143); };
  process.once('SIGTERM', stopOnSignal);
  process.once('SIGINT', stopOnSignal);

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    killGroup(child, 'SIGTERM');
    setTimeout(() => killGroup(child, 'SIGKILL'), KILL_GRACE_MS).unref();
  }, SUITE_TIMEOUT_MS);

  const subtests = [];
  const seen = new Map();
  const failures = [];
  let summary = null;
  let passLines = 0;

  const onLine = (line) => {
    process.stderr.write(line + '\n');           // stream the suite's own output
    const summaryMatch = SUMMARY_LINE.exec(line);
    if (summaryMatch) {
      summary = { pass: Number(summaryMatch[1]), fail: Number(summaryMatch[2]) };
      return;
    }
    if (PREFLIGHT_ROW.test(line)) return;
    const caseMatch = CASE_LINE.exec(line);
    if (!caseMatch) return;
    const [, verdict, rest] = caseMatch;
    const name = uniqueName(seen, rest);
    if (verdict === 'PASS') {
      passLines += 1;
      subtests.push(t.test(name, () => {}));
    } else {
      failures.push(rest);
      subtests.push(t.test(name, () => { assert.fail(`run-tests.sh: FAIL ${rest}`); }));
    }
  };

  const stdout = createInterface({ input: child.stdout, crlfDelay: Infinity });
  stdout.on('line', onLine);
  // stderr carries no verdicts; forward it so a failure's context is visible.
  const stderr = createInterface({ input: child.stderr, crlfDelay: Infinity });
  stderr.on('line', (line) => { process.stderr.write(line + '\n'); });

  let exit;
  try {
    const [code, signal] = await once(child, 'exit');
    exit = { code, signal };
    // Drain what the suite wrote. A stray background child of the suite could
    // hold the pipes open after bash exits: bound that wait, then clear the
    // suite's own process group rather than hang here.
    const drained = await Promise.race([
      Promise.all([once(stdout, 'close'), once(stderr, 'close')]).then(() => true),
      new Promise((resolve) => setTimeout(() => resolve(false), KILL_GRACE_MS).unref()),
    ]);
    if (!drained) {
      try { process.kill(-child.pid, 'SIGKILL'); } catch { /* group already gone */ }
      child.stdout.destroy();
      child.stderr.destroy();
    }
  } finally {
    clearTimeout(timer);
    process.off('SIGTERM', stopOnSignal);
    process.off('SIGINT', stopOnSignal);
  }
  await Promise.all(subtests);

  const cases = passLines + failures.length;
  assert.ok(!timedOut, `run-tests.sh did not finish within ${SUITE_TIMEOUT_MS / 60000} minutes; its process group was killed`);
  assert.equal(failures.length, 0, `run-tests.sh reported ${failures.length} FAIL line(s):\n  ${failures.join('\n  ')}`);
  assert.ok(cases > 0, 'run-tests.sh reported zero PASS/FAIL cases');
  assert.ok(summary !== null, 'run-tests.sh printed no "PASS: n   FAIL: m" summary (stopped early?)');
  assert.equal(summary.fail, 0, `run-tests.sh summary counts ${summary.fail} failure(s)`);
  assert.ok(summary.pass > 0 && summary.pass <= passLines,
    `run-tests.sh summary (${summary.pass} passed) does not match the ${passLines} PASS line(s) seen`);
  assert.deepEqual(exit, { code: 0, signal: null },
    `run-tests.sh exited with code ${exit.code}${exit.signal ? ` (signal ${exit.signal})` : ''}`);
});
