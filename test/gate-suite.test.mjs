// test/gate-suite.test.mjs — fast merge gate for CFW Render.
//
//   cd test && node --test gate-suite.test.mjs
//
// Each check is one subtest. The repo root comes from this file's path, and
// every check is spawned with that directory as cwd. A non-zero exit fails
// the subtest with the last 4000 characters of its output. A timeout kills
// only that check's process, then fails the subtest even if the process
// does not exit. No skips. Imports are node:* only.
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUTPUT_TAIL = 4000;
const KILL_GRACE_MS = 2 * 1000;
const REPORT_SLACK_MS = 30 * 1000;

// macOS /bin/bash is 3.2. It brace-expands the whole <( ... ) body, so the
// harness here-doc becomes "0: ambiguous redirect" and a broken Python script.
// Bash 4+ does not. The bound suite's PATH finds that bash first. A developer
// shell often finds /bin/bash first, so put the same directories first here.
const BASH4_DIRS = ['/opt/homebrew/bin', '/usr/local/bin'];

const CHECKS = [
  { name: 'scripts/lint.sh', command: 'bash', args: ['scripts/lint.sh'], timeoutMs: 4 * 60 * 1000 },
  { name: 'python3 test/app-key-retry.py', command: 'python3', args: ['test/app-key-retry.py'], timeoutMs: 4 * 60 * 1000 },
  { name: 'python3 test/provider-keys.py', command: 'python3', args: ['test/provider-keys.py'], timeoutMs: 8 * 60 * 1000 },
  { name: 'python3 test/harness-conditions.py', command: 'python3', args: ['test/harness-conditions.py'], timeoutMs: 4 * 60 * 1000 },
  { name: 'python3 test/recipe-landing-regression.py', command: 'python3', args: ['test/recipe-landing-regression.py'], timeoutMs: 8 * 60 * 1000 },
  { name: 'node --test test/playwright-pin.test.mjs', command: 'node', args: ['--test', 'test/playwright-pin.test.mjs'], timeoutMs: 2 * 60 * 1000 },
  { name: 'bash test/engine-claude-token.test.sh', command: 'bash', args: ['test/engine-claude-token.test.sh'], timeoutMs: 2 * 60 * 1000 },
];

const owned = new Set();

function checkEnv() {
  const env = { ...process.env };
  // This runner is itself a node:test child. A nested `node --test` that inherits
  // NODE_TEST_CONTEXT skips its files and exits 0, so a failing node check would pass.
  delete env.NODE_TEST_CONTEXT;
  const parts = (env.PATH || '/usr/bin:/bin').split(':').filter(Boolean);
  const rest = parts.filter((dir) => !BASH4_DIRS.includes(dir));
  env.PATH = [...BASH4_DIRS, ...rest].join(':');
  return env;
}

function killOwn(child) {
  if (!child.pid || child.exitCode !== null || child.signalCode !== null) return;
  // Exact pid, then the process group when this child leads one. Never the runner.
  try { process.kill(child.pid, 'SIGKILL'); } catch { /* already gone */ }
  try { process.kill(-child.pid, 'SIGKILL'); } catch { /* not a group leader */ }
}

function stopOwned() {
  for (const child of owned) killOwn(child);
}
process.once('SIGTERM', () => { stopOwned(); process.exit(143); });
process.once('SIGINT', () => { stopOwned(); process.exit(130); });

function failure(name, reason, output, notes = '') {
  const tail = output.length > OUTPUT_TAIL ? output.slice(-OUTPUT_TAIL) : output;
  const head = notes ? `${notes}\n` : '';
  return new Error(`${name}: ${reason}\n${head}${tail}`);
}

function runCheck(check) {
  return new Promise((resolve, reject) => {
    const child = spawn(check.command, check.args, {
      cwd: REPO_ROOT,
      env: checkEnv(),
      stdio: ['ignore', 'pipe', 'pipe'],
      detached: true,
    });
    owned.add(child);

    let output = '';
    let noted = '';
    const take = (chunk) => {
      const text = chunk.toString();
      output += text;
      if (output.length > OUTPUT_TAIL) output = output.slice(-OUTPUT_TAIL);
      for (const line of text.split('\n')) {
        if (line.includes('FAIL') || line.includes('error:')) {
          noted += `${line}\n`;
          if (noted.length > 2000) noted = noted.slice(-2000);
        }
      }
    };
    if (child.stdout) child.stdout.on('data', take);
    if (child.stderr) child.stderr.on('data', take);

    let settled = false;
    let timedOut = false;
    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(killTimer);
      clearTimeout(giveUpTimer);
      owned.delete(child);
      if (child.stdout) child.stdout.destroy();
      if (child.stderr) child.stderr.destroy();
      child.unref();
      if (error) reject(error);
      else resolve();
    };

    const killTimer = setTimeout(() => {
      timedOut = true;
      killOwn(child);
    }, check.timeoutMs);
    // Do not wait out a process that survived SIGKILL. The subtest still fails
    // with whatever output was captured.
    const giveUpTimer = setTimeout(() => {
      if (!timedOut) return;
      finish(failure(
        check.name,
        `timed out after ${check.timeoutMs / 60000} minutes and its process was killed`,
        output,
        noted,
      ));
    }, check.timeoutMs + KILL_GRACE_MS);

    child.on('error', (error) => {
      finish(failure(check.name, `failed to start (${error.message})`, output, noted));
    });
    child.on('exit', (code, signal) => {
      if (code === 0 && signal == null && !timedOut) {
        finish();
        return;
      }
      const how = timedOut
        ? `timed out after ${check.timeoutMs / 60000} minutes and its process was killed`
        : (signal ? `signal ${signal}` : `exit ${code}`);
      finish(failure(check.name, how, output, noted));
    });
  });
}

for (const check of CHECKS) {
  test(check.name, { timeout: check.timeoutMs + KILL_GRACE_MS + REPORT_SLACK_MS }, () => runCheck(check));
}
