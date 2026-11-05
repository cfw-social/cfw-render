// test/desktop-suite.test.mjs — runner entry for the CFW Render desktop app.
//
//   node --test test/desktop-suite.test.mjs
//     -> node desktop/node_modules/vitest/vitest.mjs run --reporter=json
//          one node subtest per vitest test (name = file > full title)
//     -> node desktop/node_modules/typescript/bin/tsc --noEmit -p desktop
//
// The test copy is read-only, so vitest's JSON report, config bundle and Vite
// cache stay in a temp directory. No dependencies beyond node:* . Rust tests
// run in test/desktop-suite-rust.test.mjs.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DESKTOP_DIR = path.join(REPO_ROOT, 'desktop');
const VITEST_BIN = path.join(DESKTOP_DIR, 'node_modules', 'vitest', 'vitest.mjs');
const TSC_BIN = path.join(DESKTOP_DIR, 'node_modules', 'typescript', 'bin', 'tsc');
const VITEST_TIMEOUT_MS = 20 * 60 * 1000;
const TSC_TIMEOUT_MS = 5 * 60 * 1000;
const KILL_GRACE_MS = 10 * 1000;
const OUTPUT_LIMIT = 8000;
// /bin/ps is setuid. The runner sandbox refuses it (spawn EPERM), so this file
// does not list processes. Vitest files run one at a time so the desktop test
// that re-enters run-tests.sh is not beside other vitest workers.
const SUITE_TIMEOUT_MS = VITEST_TIMEOUT_MS + TSC_TIMEOUT_MS + 60 * 1000;

let releaseVitest = () => {};
const vitestFinished = new Promise((resolve) => { releaseVitest = resolve; });

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

function runProcess(args, { cwd, timeoutMs }) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, args, {
      cwd,
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
      detached: true,
    });
    const out = [];
    const err = [];
    let spawnError = '';
    let settled = false;

    const finish = (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      const stderr = Buffer.concat(err).toString('utf8') + (spawnError ? `\n${spawnError}` : '');
      resolve({
        code,
        signal,
        stdout: Buffer.concat(out).toString('utf8'),
        stderr,
      });
    };

    child.stdout.on('data', (chunk) => {
      out.push(chunk);
      process.stderr.write(chunk);
    });
    child.stderr.on('data', (chunk) => {
      err.push(chunk);
      process.stderr.write(chunk);
    });

    const timer = setTimeout(() => {
      killGroup(child, 'SIGTERM');
      setTimeout(() => killGroup(child, 'SIGKILL'), KILL_GRACE_MS).unref();
    }, timeoutMs);

    const stopOnSignal = (signal) => {
      killGroup(child, 'SIGTERM');
      process.exit(signal === 'SIGINT' ? 130 : 143);
    };
    process.once('SIGTERM', stopOnSignal);
    process.once('SIGINT', stopOnSignal);

    child.on('error', (error) => {
      spawnError = error && error.stack ? error.stack : String(error);
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

function fileLabel(filepath) {
  if (typeof filepath !== 'string' || filepath.length === 0) return '(unknown file)';
  const relative = path.relative(DESKTOP_DIR, filepath);
  if (relative && !relative.startsWith('..') && !path.isAbsolute(relative)) {
    return relative.split(path.sep).join('/');
  }
  return filepath;
}

function oneLine(value) {
  return String(value).replace(/[\u0000-\u001F\u007F]+/g, ' ').trim();
}

function uniqueName(seen, name) {
  const clean = oneLine(name) || '(unnamed vitest test)';
  const count = (seen.get(clean) ?? 0) + 1;
  seen.set(clean, count);
  return count === 1 ? clean : `${clean} (${count})`;
}

function failureText(stderr, stdout, reason) {
  const err = stderr.trim();
  const out = stdout.trim();
  const parts = [reason];
  if (err) parts.push(`stderr:\n${clip(err)}`);
  else if (out) parts.push(`stdout:\n${clip(out)}`);
  return parts.join('\n\n');
}

function casesFromReport(report) {
  if (!report || typeof report !== 'object' || !Array.isArray(report.testResults)) return null;
  const cases = [];
  const seen = new Map();
  for (const file of report.testResults) {
    const label = fileLabel(file && file.name);
    const assertions = file && Array.isArray(file.assertionResults) ? file.assertionResults : [];
    if (assertions.length === 0) {
      const passed = file && file.status === 'passed';
      cases.push({
        name: uniqueName(seen, label),
        passed,
        message: passed ? '' : (file && file.message) || `vitest file status: ${file && file.status ? file.status : 'unknown'}`,
      });
      continue;
    }
    for (const assertion of assertions) {
      const title = assertion.fullName || assertion.title || '(untitled)';
      const messages = Array.isArray(assertion.failureMessages)
        ? assertion.failureMessages.filter((item) => typeof item === 'string' && item.trim())
        : [];
      cases.push({
        name: uniqueName(seen, `${label} > ${title}`),
        passed: assertion.status === 'passed',
        message: messages.join('\n\n') || `vitest status: ${assertion.status || 'unknown'}`,
      });
    }
    const fileFailed = file.status === 'failed';
    const testsPassed = assertions.every((assertion) => assertion.status === 'passed');
    if (fileFailed && testsPassed && file.message) {
      cases.push({
        name: uniqueName(seen, `${label} > (file)`),
        passed: false,
        message: file.message,
      });
    }
  }
  return cases;
}

function readReport(reportFile) {
  let text;
  try {
    text = fs.readFileSync(reportFile, 'utf8');
  } catch (error) {
    return { cases: null, reason: `vitest JSON report is missing (${error.code || error.message})` };
  }
  let report;
  try {
    report = JSON.parse(text);
  } catch (error) {
    return { cases: null, reason: `vitest JSON report is not valid JSON (${error.message})` };
  }
  const cases = casesFromReport(report);
  if (!cases) return { cases: null, reason: 'vitest JSON report has no testResults array' };
  return { cases, reason: '' };
}

function writeVitestConfig(tmp) {
  const configFile = path.join(tmp, 'vitest.config.mjs');
  const cacheDir = path.join(tmp, 'vite-cache');
  const vitestConfig = path.join(DESKTOP_DIR, 'node_modules', 'vitest', 'dist', 'config.js');
  const baseConfig = path.join(DESKTOP_DIR, 'vitest.config.ts');
  const source = [
    `import { defineConfig, mergeConfig } from ${JSON.stringify(vitestConfig)};`,
    `import base from ${JSON.stringify(baseConfig)};`,
    'if (!base || typeof base !== "object") throw new Error("desktop vitest config did not export an object");',
    'const desktopRoot = ' + JSON.stringify(DESKTOP_DIR) + ';',
    'const cacheDir = ' + JSON.stringify(cacheDir) + ';',
    'export default mergeConfig(base, defineConfig({',
    '  root: desktopRoot,',
    '  cacheDir,',
    '  test: { root: desktopRoot, cache: false, watch: false, fileParallelism: false },',
    '}));',
    '',
  ].join('\n');
  fs.mkdirSync(cacheDir, { recursive: true });
  fs.mkdirSync(path.join(tmp, 'attachments'), { recursive: true });
  fs.writeFileSync(configFile, source);
  return { configFile, cacheDir };
}

test('desktop vitest', { timeout: SUITE_TIMEOUT_MS }, async (t) => {
  let tmp = '';
  try {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'cfw-desktop-suite-'));
    const reportFile = path.join(tmp, 'vitest.json');
    const { configFile } = writeVitestConfig(tmp);
    const result = await runProcess([
      VITEST_BIN,
      'run',
      '--config', configFile,
      '--root', DESKTOP_DIR,
      '--cache=false',
      '--reporter=json',
      `--outputFile=${reportFile}`,
      `--attachmentsDir=${path.join(tmp, 'attachments')}`,
    ], { cwd: DESKTOP_DIR, timeoutMs: VITEST_TIMEOUT_MS });

    const { cases, reason } = readReport(reportFile);
    const pending = [];
    if (!cases) {
      pending.push(t.test('vitest json report', () => {
        assert.fail(failureText(result.stderr, result.stdout, reason));
      }));
    } else if (cases.length === 0) {
      pending.push(t.test('vitest json report', () => {
        assert.fail(failureText(result.stderr, result.stdout, 'vitest reported no tests'));
      }));
    } else {
      let anyFailed = false;
      for (const item of cases) {
        if (!item.passed) anyFailed = true;
        pending.push(t.test(item.name, () => {
          if (!item.passed) assert.fail(item.message);
        }));
      }
      if (result.code !== 0 && !anyFailed) {
        const exit = result.signal ? `signal ${result.signal}` : `code ${result.code}`;
        pending.push(t.test('vitest process', () => {
          assert.fail(failureText(result.stderr, result.stdout, `vitest exited with ${exit}`));
        }));
      }
    }
    await Promise.allSettled(pending);
  } finally {
    if (tmp) fs.rmSync(tmp, { recursive: true, force: true });
    releaseVitest();
  }
});

test('desktop tsc --noEmit', { timeout: SUITE_TIMEOUT_MS }, async () => {
  await vitestFinished;
  const result = await runProcess([
    TSC_BIN,
    '--noEmit',
    '-p',
    'desktop',
  ], { cwd: REPO_ROOT, timeoutMs: TSC_TIMEOUT_MS });
  if (result.code !== 0 || result.signal) {
    const exit = result.signal ? `signal ${result.signal}` : `code ${result.code}`;
    const output = [result.stdout.trim(), result.stderr.trim()].filter(Boolean).join('\n');
    assert.fail(`tsc --noEmit exited with ${exit}\n${clip(output)}`);
  }
});
