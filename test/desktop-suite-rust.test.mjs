// test/desktop-suite-rust.test.mjs — runner entry for the desktop Rust tests.
//
//   node --test test/desktop-suite-rust.test.mjs
//     -> cargo test --offline --color never
//          cargo resolved from PATH, crate = a writable copy of desktop/src-tauri
//          (tauri-build writes gen/schemas; the test copy is read-only)
//          one node test per Rust test (name = cargo test path)
//
// An ignored Rust test fails this file. It is never a node skip. A missing
// cargo, a non-zero cargo exit, or fewer than 71 Rust tests fails the run.
// No dependencies beyond node:* . The runner owns CARGO_TARGET_DIR, CARGO_HOME
// and the offline switch; this file does not set CARGO_* or RUSTUP_*.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SRC_TAURI = path.join(REPO_ROOT, 'desktop', 'src-tauri');
const CARGO_TIMEOUT_MS = 15 * 60 * 1000;
const KILL_GRACE_MS = 10 * 1000;
const OUTPUT_LIMIT = 8000;
const MIN_RUST_TESTS = 71;
const SUITE_TIMEOUT_MS = CARGO_TIMEOUT_MS + KILL_GRACE_MS + 60 * 1000;

const TEST_LINE = /^test (\S.*?) \.\.\. (ok|FAILED|ignored)\b/;
const RESULT_LINE = /^test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored; (\d+) measured\b/;

let summaryLine = 'desktop cargo test summary: not run';
process.on('exit', () => {
  process.stderr.write(`${summaryLine}\n`);
});

function killGroup(child, signal) {
  if (!child.pid || child.exitCode !== null || child.signalCode !== null) return;
  try {
    process.kill(-child.pid, signal);
  } catch {
    try { child.kill(signal); } catch { /* already gone */ }
  }
}

function clip(text) {
  if (text.length <= OUTPUT_LIMIT) return text;
  return `…(truncated)\n${text.slice(-OUTPUT_LIMIT)}`;
}

function oneLine(value) {
  return String(value).replace(/[\u0000-\u001F\u007F]+/g, ' ').trim();
}

function uniqueName(seen, name) {
  const clean = oneLine(name) || '(unnamed rust test)';
  const count = (seen.get(clean) ?? 0) + 1;
  seen.set(clean, count);
  return count === 1 ? clean : `${clean} (${count})`;
}

function remember(state, text) {
  state.tail += text;
  if (state.tail.length > OUTPUT_LIMIT) state.tail = state.tail.slice(-OUTPUT_LIMIT);
}

function noteLine(state, line) {
  const tested = TEST_LINE.exec(line);
  if (tested) {
    state.cases.push({ name: tested[1], status: tested[2] });
    return;
  }
  const result = RESULT_LINE.exec(line);
  if (result) {
    state.summary.passed += Number(result[2]);
    state.summary.failed += Number(result[3]);
    state.summary.ignored += Number(result[4]);
    state.summary.measured += Number(result[5]);
    state.summary.blocks += 1;
    return;
  }
  if (/^\s*Finished\b/.test(line) && state.finished.length < 30) state.finished.push(line.trim());
  if (/^\s*Compiling\b/.test(line)) state.compiling += 1;
}

function attach(stream, state) {
  let carry = '';
  const take = (chunk) => {
    const text = typeof chunk === 'string' ? chunk : chunk.toString('utf8');
    remember(state, text);
    carry += text;
    const parts = carry.split(/\r\n|\n|\r/);
    carry = parts.pop() ?? '';
    for (const line of parts) noteLine(state, line);
  };
  stream.on('data', take);
  stream.on('end', () => {
    if (!carry) return;
    const last = carry;
    carry = '';
    noteLine(state, last);
  });
}

function skipCopied(src) {
  const rel = path.relative(SRC_TAURI, src);
  if (rel === '') return true;
  const top = rel.split(path.sep)[0];
  return top !== 'target' && top !== 'gen';
}

// tauri-build writes gen/schemas into the crate directory. The test copy is
// read-only (EPERM), so cargo sees a writable copy of that same tree.
function writableCrate(parent) {
  const crateDir = path.join(parent, 'src-tauri');
  fs.cpSync(SRC_TAURI, crateDir, { recursive: true, filter: skipCopied });
  makeWritable(crateDir);
  return crateDir;
}

function makeWritable(dir) {
  const stat = fs.lstatSync(dir);
  if (stat.isSymbolicLink()) return;
  if (stat.isDirectory()) {
    fs.chmodSync(dir, 0o700);
    for (const name of fs.readdirSync(dir)) makeWritable(path.join(dir, name));
    return;
  }
  fs.chmodSync(dir, (stat.mode & 0o777) | 0o600);
}

function runCargo(cwd) {
  const started = Date.now();
  const state = {
    tail: '',
    cases: [],
    finished: [],
    compiling: 0,
    summary: { passed: 0, failed: 0, ignored: 0, measured: 0, blocks: 0 },
  };
  return new Promise((resolve) => {
    const child = spawn('cargo', ['test', '--offline', '--color', 'never'], {
      cwd,
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
      detached: true,
    });
    attach(child.stdout, state);
    attach(child.stderr, state);
    let spawnError = '';
    let missingCargo = false;
    let timedOut = false;
    let settled = false;

    const finish = (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({
        code,
        signal,
        spawnError,
        missingCargo,
        timedOut,
        wallMs: Date.now() - started,
        tail: state.tail,
        cases: state.cases,
        finished: state.finished,
        compiling: state.compiling,
        summary: state.summary,
      });
    };

    const timer = setTimeout(() => {
      timedOut = true;
      killGroup(child, 'SIGTERM');
      setTimeout(() => killGroup(child, 'SIGKILL'), KILL_GRACE_MS).unref();
    }, CARGO_TIMEOUT_MS);

    const stopOnSignal = (signal) => {
      killGroup(child, 'SIGTERM');
      process.exit(signal === 'SIGINT' ? 130 : 143);
    };
    process.once('SIGTERM', stopOnSignal);
    process.once('SIGINT', stopOnSignal);

    child.on('error', (error) => {
      missingCargo = Boolean(error && error.code === 'ENOENT');
      spawnError = missingCargo
        ? 'cargo is missing from PATH'
        : (error && error.message ? error.message : String(error));
      finish(1, null);
    });
    child.on('exit', (code, signal) => {
      Promise.race([
        Promise.all([once(child.stdout, 'close'), once(child.stderr, 'close')]).then(() => true),
        new Promise((done) => setTimeout(() => done(false), KILL_GRACE_MS).unref()),
      ]).then((drained) => {
        if (!drained) {
          try { process.kill(-child.pid, 'SIGKILL'); } catch { /* group already gone */ }
          child.stdout.destroy();
          child.stderr.destroy();
        }
        process.off('SIGTERM', stopOnSignal);
        process.off('SIGINT', stopOnSignal);
        finish(code, signal);
      });
    });
  });
}

function problemsFor(result) {
  const problems = [];
  const { cases, summary } = result;
  const ok = cases.filter((item) => item.status === 'ok').length;
  const failed = cases.filter((item) => item.status === 'FAILED').length;
  const ignored = cases.filter((item) => item.status === 'ignored').length;
  if (result.missingCargo) problems.push('cargo is missing from PATH');
  else if (result.spawnError) problems.push(result.spawnError);
  if (result.timedOut) problems.push('cargo test exceeded 15 minutes');
  if (result.signal) problems.push(`cargo test stopped by signal ${result.signal}`);
  else if (result.code !== 0) problems.push(`cargo test exited with code ${result.code}`);
  if (cases.length < MIN_RUST_TESTS) {
    problems.push(`cargo reported ${cases.length} Rust tests; need at least ${MIN_RUST_TESTS}`);
  }
  if (summary.blocks === 0) problems.push('cargo printed no test result line');
  else if (
    summary.passed + summary.failed + summary.ignored + summary.measured !== cases.length
    || summary.passed !== ok
    || summary.failed !== failed
    || summary.ignored !== ignored
  ) {
    problems.push(
      `cargo test result totals (${summary.passed} passed, ${summary.failed} failed, `
      + `${summary.ignored} ignored, ${summary.measured} measured) do not match `
      + `${cases.length} parsed tests (${ok} ok, ${failed} FAILED, ${ignored} ignored)`,
    );
  }
  if (failed + ignored > 0) problems.push(`${failed + ignored} Rust tests did not pass`);
  return problems;
}

describe('desktop cargo test', { timeout: SUITE_TIMEOUT_MS }, async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'cfw-desktop-rust-'));
  try {
    const result = await runCargo(writableCrate(tmp));
    const seen = new Map();
    const pending = [];
    for (const item of result.cases) {
      const name = uniqueName(seen, item.name);
      const status = item.status;
      pending.push(test(name, () => {
        if (status !== 'ok') assert.fail(`Rust test ${status}`);
      }));
    }
    const problems = problemsFor(result);
    summaryLine = [
      'desktop cargo test summary:',
      `rust=${result.cases.length}`,
      `exit=${result.code}`,
      `signal=${result.signal || 'none'}`,
      `wall_ms=${result.wallMs}`,
      `compiling=${result.compiling}`,
      `finished=${result.finished.join(' || ') || 'none'}`,
    ].join(' ');
    await Promise.allSettled(pending);
    if (problems.length > 0) {
      assert.fail(`${problems.join('\n')}\n\n${clip(result.tail.trim())}`);
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
