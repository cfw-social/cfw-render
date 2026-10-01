#!/usr/bin/env bash
# fake-claude-env-dependent.sh — CFW-291 fixture. Exits 0 and prints "ok"
# ONLY when FAKE_NVM_DIR is set in its environment; otherwise exits 127 and
# prints nothing — the shape of a `claude` that resolves via `command -v` in
# a rich shell (because the shell/harness exports FAKE_NVM_DIR, mimicking an
# nvm/asdf init hook) but must fail once that init hook's env var is gone,
# which is exactly what `env -i` strips. Proves cr_probe_claude_headless
# catches the class of bug a naive `command -v` check (CFW-279) could not.
set -u
if [[ -n "${FAKE_NVM_DIR:-}" ]]; then
  echo "ok"
  exit 0
fi
exit 127
