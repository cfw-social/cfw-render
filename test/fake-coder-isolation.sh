#!/usr/bin/env bash
# WI2.109 stand-in for claude and codex. No network. Records the config
# directories it was given and tries writes inside and outside the work folder.
# The engine invokes this with the prompt on stdin.
set -u
cat >/dev/null || true

report="${CFW_WI2109_REPORT:-}"
inside="${CFW_WI2109_INSIDE:-}"
outside="${CFW_WI2109_OUTSIDE:-}"
escape="${CFW_WI2109_ESCAPE:-}"

planted=no
if [[ -z "${CLAUDE_CONFIG_DIR:-}" || -z "${CODEX_HOME:-}" ]]; then
  planted=yes
fi
if [[ -n "${CLAUDE_CONFIG_DIR:-}" && -f "$CLAUDE_CONFIG_DIR/settings.json" ]]; then
  planted=yes
fi
if [[ -n "${CLAUDE_CONFIG_DIR:-}" && -e "$CLAUDE_CONFIG_DIR/output-styles/personal.md" ]]; then
  planted=yes
fi
if [[ -n "${CODEX_HOME:-}" && -f "$CODEX_HOME/config.toml" ]]; then
  planted=yes
fi
if [[ "${CLAUDE_CONFIG_DIR:-}" == "${HOME:-}/.claude" || "${CODEX_HOME:-}" == "${HOME:-}/.codex" ]]; then
  planted=yes
fi
if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
  printf 'probe\n' > "$CLAUDE_CONFIG_DIR/write-probe" || planted=yes
fi
if [[ -n "${CODEX_HOME:-}" ]]; then
  printf 'probe\n' > "$CODEX_HOME/write-probe" || planted=yes
fi

inside_result=fail
if [[ -n "$inside" ]] && printf 'inside\n' > "$inside"; then
  inside_result=ok
fi
outside_result=fail
if [[ -n "$outside" ]] && printf 'outside\n' > "$outside" 2>/dev/null; then
  outside_result=ok
fi
escape_result=fail
if [[ -n "$escape" ]] && printf 'escape\n' > "$escape" 2>/dev/null; then
  escape_result=ok
fi

if [[ -n "$report" ]]; then
  {
    printf 'SANDBOX=%s\n' "${CFW_RENDER_CODER_SANDBOX:-}"
    printf 'CLAUDE_CONFIG_DIR=%s\n' "${CLAUDE_CONFIG_DIR:-}"
    printf 'CODEX_HOME=%s\n' "${CODEX_HOME:-}"
    printf 'TMPDIR=%s\n' "${TMPDIR:-}"
    printf 'PLANTED=%s\n' "$planted"
    printf 'INSIDE=%s\n' "$inside_result"
    printf 'OUTSIDE=%s\n' "$outside_result"
    printf 'ESCAPE=%s\n' "$escape_result"
  } > "$report"
fi
exit 0
