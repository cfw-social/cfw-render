#!/usr/bin/env bash
# cfw-render-engine.sh — [M1-08] engine adapters for the step harness.
#
# The harness runs each manifest step through whichever subscription-backed
# coding CLI the owner's computer already has signed in: OpenAI Codex
# (`codex`) or Claude Code (`claude`). This file is the ONE place that knows
# how to (a) tell which engine is usable and (b) run a prompt file through it
# non-interactively. Everything else talks to `cr_engine_detect` /
# `cr_engine_run` only.
#
# Credential rule ("no credential leaves the computer"): this file NEVER
# reads, copies or prints ~/.codex/auth.json, ~/.claude/*, the keychain, or
# any env var that looks like a key. Detection relies solely on each CLI's own
# status command EXIT CODE; its stdout (which carries the account e-mail) is
# discarded, never logged.
#
# Pinned non-interactive forms — CONFIRMED from `codex exec --help`
# (codex-cli 0.142.5) and `claude --help` / `claude auth status --help`
# (Claude Code 2.1.288) on 2026-10-11:
#
#   codex  : codex login status                     → rc 0 iff signed in
#            codex exec --skip-git-repo-check -C <workdir> \
#                  --dangerously-bypass-approvals-and-sandbox - < prompt.md
#              `-` = read the prompt from stdin (no argv size limit).
#              The bypass flag is the codex equivalent of the Director path's
#              `--dangerously-skip-permissions`: steps shell out to ffmpeg and
#              fetch inputs over the network, which the workspace-write
#              sandbox blocks.
#   claude : claude auth status                     → rc 0 iff signed in
#            claude -p --dangerously-skip-permissions --output-format text < prompt.md
#              `-p` with no positional prompt reads it from stdin.
#
# Overrides:
#   CFW_RENDER_ENGINE       codex | claude-code | none — skip detection.
#                           `none` = never send capabilities (legacy worker).
#   CFW_RENDER_ENGINE_CMD   command run INSTEAD of the real CLI (tests). It is
#                           invoked with cwd = the step workdir, the prompt on
#                           stdin and CFW_RENDER_ENGINE_PROMPT_FILE in env.
#                           Word-split on purpose, like CFW_RENDER_DIRECTOR_CMD.
#
# Sourced by cfw-render.sh (claim capabilities) and cfw-render-harness.sh.
# Depends on cfw-render-lib.sh being sourced first (cr_log).

# ---------------------------------------------------------------------------
# cr_engine_detect — echo `codex`, `claude-code` or `none`. Never fails.
# ---------------------------------------------------------------------------
cr_engine_detect() {
  local forced="${CFW_RENDER_ENGINE:-}"
  if [[ -n "$forced" ]]; then
    case "$forced" in
      codex|claude-code|none) echo "$forced"; return 0 ;;
      *) cr_log "cr_engine_detect: CFW_RENDER_ENGINE='$forced' is not codex|claude-code|none — treating as none"; echo none; return 0 ;;
    esac
  fi
  # A test/override command stands in for a real CLI: default to codex so the
  # claim advertises an engine every fixture manifest accepts.
  if [[ -n "${CFW_RENDER_ENGINE_CMD:-}" ]]; then
    echo codex
    return 0
  fi
  # Status output is discarded on purpose — it names the account.
  if command -v codex >/dev/null 2>&1 && codex login status >/dev/null 2>&1 < /dev/null; then
    echo codex
    return 0
  fi
  if command -v claude >/dev/null 2>&1 && claude auth status >/dev/null 2>&1 < /dev/null; then
    echo claude-code
    return 0
  fi
  echo none
  return 0
}

# ---------------------------------------------------------------------------
# cr_engine_os — `macos` | `linux` | lower-cased uname, for capabilities.os.
# ---------------------------------------------------------------------------
cr_engine_os() {
  local u
  u="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  case "$u" in
    darwin) echo macos ;;
    linux)  echo linux ;;
    *)      echo "${u:-unknown}" ;;
  esac
}

# ---------------------------------------------------------------------------
# cr_engine_manifests_json <skillsDir> — JSON array of {recipe, recipeVersion}
# for every <skillsDir>/*/manifest.json that parses. Unparsable files are
# skipped (they'd fail the lint gate anyway) so one bad file can't stop the
# claim from advertising the others.
# ---------------------------------------------------------------------------
cr_engine_manifests_json() {
  local skills_dir="$1"
  python3 -c '
import glob, json, os, sys
root = sys.argv[1]
out = []
for p in sorted(glob.glob(os.path.join(root, "*", "manifest.json"))):
    try:
        m = json.load(open(p))
    except Exception:
        continue
    r, v = m.get("recipe"), m.get("recipeVersion")
    if isinstance(r, str) and isinstance(v, str) and r and v:
        out.append({"recipe": r, "recipeVersion": v})
print(json.dumps(out))
' "$skills_dir" 2>/dev/null || echo "[]"
}

# ---------------------------------------------------------------------------
# cr_engine_capabilities_json <engine> <skillsDir> — the §7 `capabilities`
# object, or an empty string when <engine> is `none` (caller omits the field).
# ---------------------------------------------------------------------------
cr_engine_capabilities_json() {
  local engine="$1" skills_dir="$2"
  [[ "$engine" == "none" ]] && { echo ""; return 0; }
  local manifests
  manifests="$(cr_engine_manifests_json "$skills_dir")"
  python3 -c '
import json, sys
print(json.dumps({"engine": sys.argv[1], "os": sys.argv[2], "manifests": json.loads(sys.argv[3])}))
' "$engine" "$(cr_engine_os)" "$manifests"
}

# ---------------------------------------------------------------------------
# cr_engine_run <engine> <prompt-file> <workdir> <log> — run one step prompt.
# stdout+stderr of the engine are APPENDED to <log>; returns the engine's rc.
# ---------------------------------------------------------------------------
cr_engine_run() {
  local engine="$1" prompt_file="$2" workdir="$3" log="$4"
  [[ -f "$prompt_file" ]] || { cr_log "cr_engine_run: prompt file missing: $prompt_file"; return 2; }
  mkdir -p "$workdir" "$(dirname "$log")"
  printf '=== %s engine=%s prompt=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$engine" "$(basename "$prompt_file")" >> "$log"
  local rc=0
  if [[ -n "${CFW_RENDER_ENGINE_CMD:-}" ]]; then
    (
      cd "$workdir" || exit 1
      export CFW_RENDER_ENGINE_PROMPT_FILE="$prompt_file"
      # shellcheck disable=SC2086
      $CFW_RENDER_ENGINE_CMD < "$prompt_file" >> "$log" 2>&1
    ) || rc=$?
    return "$rc"
  fi
  case "$engine" in
    codex)
      ( cd "$workdir" && codex exec --skip-git-repo-check -C "$workdir" \
          --dangerously-bypass-approvals-and-sandbox - < "$prompt_file" >> "$log" 2>&1 ) || rc=$?
      ;;
    claude-code)
      ( cd "$workdir" && claude -p --dangerously-skip-permissions --output-format text \
          < "$prompt_file" >> "$log" 2>&1 ) || rc=$?
      ;;
    *)
      cr_log "cr_engine_run: no usable engine ('$engine')"
      return 2
      ;;
  esac
  return "$rc"
}
