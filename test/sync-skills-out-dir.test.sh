#!/usr/bin/env bash
# test/sync-skills-out-dir.test.sh — standalone check that scripts/sync-skills.sh
# refuses to write into this repo's frozen skills/ (WI28, owner decision 2026-11-10).
# Safe to run alone: no server, no engine, no network, no process stops. It writes
# only to its own temp folder and never to the source library.
#
#   CFW_SKILLS_SRC=<path to the harness skills source> bash test/sync-skills-out-dir.test.sh
#
# Case 3 (a real build into a temp dir) needs CFW_SKILLS_SRC; without it the case is
# reported as a FAIL, not skipped.
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"
SYNC="$REPO_DIR/scripts/sync-skills.sh"

PASS_COUNT=0
FAILURES=0
pass() { printf '  PASS  %s\n' "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { printf '  FAIL  %s — %s\n' "$1" "$2"; FAILURES=$((FAILURES+1)); }

WORK="$(mktemp -d)" || { echo "sync-skills-out-dir.test.sh: cannot make a temp folder" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

skills_state() { git -C "$REPO_DIR" status --porcelain --untracked-files=all -- skills config; }
before="$(skills_state)"

# 1. no --out-dir
out="$("$SYNC" 2>&1)"; rc=$?
if [[ "$rc" != "0" && "$out" == *"--out-dir is required"* ]]; then pass "no --out-dir: refused (rc=$rc)"; else fail "no --out-dir" "rc=$rc out=${out:0:200}"; fi
if [[ "$(skills_state)" == "$before" ]]; then pass "no --out-dir: skills/ and config/ unchanged"; else fail "no --out-dir" "skills/ or config/ changed"; fi

# 2. --out-dir at skills/ — direct, relative, symlink, inside it
ln -s "$REPO_DIR/skills" "$WORK/skills-link"
for label in direct relative symlink inside; do
  case "$label" in
    direct)   target="$REPO_DIR/skills"; run_dir="$WORK" ;;
    relative) target="skills";           run_dir="$REPO_DIR" ;;
    symlink)  target="$WORK/skills-link"; run_dir="$WORK" ;;
    inside)   target="$REPO_DIR/skills/p-carousel"; run_dir="$WORK" ;;
  esac
  out="$(cd "$run_dir" && CFW_SKILLS_SRC="${CFW_SKILLS_SRC:-/nonexistent}" "$SYNC" --out-dir "$target" 2>&1)"; rc=$?
  if [[ "$rc" != "0" && "$out" == *"inside this repo's skills/"* ]]; then pass "--out-dir $label: refused (rc=$rc)"; else fail "--out-dir $label" "rc=$rc out=${out:0:200}"; fi
done
if [[ "$(skills_state)" == "$before" ]]; then pass "--out-dir at skills/: skills/ and config/ unchanged"; else fail "--out-dir at skills/" "skills/ or config/ changed"; fi

# 3. temp dir succeeds
if [[ -z "${CFW_SKILLS_SRC:-}" ]]; then
  fail "--out-dir temp dir" "CFW_SKILLS_SRC is not set"
else
  # The source library may have dropped recipes that config/recipes.json still lists (the sync
  # fails loudly on those), so build from the allowlist entries the source actually has.
  python3 - "$REPO_DIR/config/recipes.json" "$CFW_SKILLS_SRC" "$WORK/recipes.json" <<'PY'
import json, os, sys
cfg = json.load(open(sys.argv[1]))
cfg["recipes"] = [r for r in cfg["recipes"] if os.path.isdir(os.path.join(sys.argv[2], r["name"]))]
json.dump(cfg, open(sys.argv[3], "w"))
PY
  out="$("$SYNC" --recipes "$WORK/recipes.json" --out-dir "$WORK/bundle" 2>&1)"; rc=$?
  if [[ "$rc" == "0" && -f "$WORK/bundle/index.json" ]]; then pass "--out-dir temp dir: bundle built (rc=0, index.json present)"; else fail "--out-dir temp dir" "rc=$rc out=${out: -300}"; fi
  if [[ "$(skills_state)" == "$before" ]]; then pass "temp-dir build: skills/ and config/ unchanged"; else fail "temp-dir build" "skills/ or config/ changed"; fi
fi

echo "sync-skills-out-dir.test.sh: $PASS_COUNT passed, $FAILURES failed"
(( FAILURES == 0 ))
