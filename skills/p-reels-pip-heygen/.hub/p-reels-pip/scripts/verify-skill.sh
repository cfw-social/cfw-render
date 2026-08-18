#!/usr/bin/env bash
# p-reels-pip/scripts/verify-skill.sh
# Runs static checks on the skill's own files (no real cook needed).
# Usage: bash scripts/verify-skill.sh
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

check() {
  # check "label" command [args...]
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label"
  fi
}

check_absent() {
  # check_absent "label" pattern file — PASSES if pattern NOT found in file
  local label="$1" pattern="$2" file="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    fail "$label"
  else
    pass "$label"
  fi
}

echo "=== p-reels-pip static checks ==="

# SKILL.md frontmatter presence
check "SKILL.md exists"                   test -f "$SKILL_DIR/SKILL.md"
check "SKILL.md has name field"           grep -q "^name: p-reels-pip" "$SKILL_DIR/SKILL.md"
check "SKILL.md has kind: pipeline"       grep -q "^kind: pipeline" "$SKILL_DIR/SKILL.md"
check "SKILL.md has visibility: catalog"  grep -q "^visibility: catalog" "$SKILL_DIR/SKILL.md"
check "SKILL.md lists c-broll-sync dep"   grep -q "c-broll-sync" "$SKILL_DIR/SKILL.md"
check "SKILL.md lists c-reel-premium dep" grep -q "c-reel-premium" "$SKILL_DIR/SKILL.md"
check "SKILL.md lists c-typing-ui dep"    grep -q "c-typing-ui" "$SKILL_DIR/SKILL.md"
check "SKILL.md has hermes.vendored"      grep -q "vendored:" "$SKILL_DIR/SKILL.md"

# Template
check "templates/motion-card.html exists"  test -f "$SKILL_DIR/templates/motion-card.html"
check "motion-card has --pip-band"         grep -q "pip-band" "$SKILL_DIR/templates/motion-card.html"
check "motion-card reserves pip-band CSS"  grep -q "bottom: var(--pip-band)" "$SKILL_DIR/templates/motion-card.html"
check "motion-card uses TITLE_HTML"        grep -q "{{TITLE_HTML}}" "$SKILL_DIR/templates/motion-card.html"
# Script section must not use window.getComputedStyle (comment lines mention it as a gotcha — check <script> block only)
SCRIPT_SECTION=$(sed -n '/<script>/,/<\/script>/p' "$SKILL_DIR/templates/motion-card.html" 2>/dev/null)
if echo "$SCRIPT_SECTION" | grep -q "window.getComputedStyle"; then
  fail "motion-card script uses window.getComputedStyle (must use bare getComputedStyle)"
else
  pass "motion-card script does not call window.getComputedStyle"
fi
if echo "$SCRIPT_SECTION" | grep -q "Math.random()"; then
  fail "motion-card script uses Math.random() (must use seeded PRNG)"
else
  pass "motion-card script does not call Math.random()"
fi

# SKILL.md guard rails
# "pad=1080:1920" should only appear in 'never use' notes (after "|" or "-") — check it's not in an ffmpeg code block
PAD_CODE=$(grep "pad=1080:1920" "$SKILL_DIR/SKILL.md" 2>/dev/null | grep -v "^\s*[-|#*\`]" || true)
if [ -n "$PAD_CODE" ]; then
  fail "SKILL.md has pad=1080:1920 outside comment/note context: $PAD_CODE"
else
  pass "SKILL.md pad=1080 only in notes, not code"
fi
check "SKILL.md cover rule present"        grep -q "cover-freeze" "$SKILL_DIR/SKILL.md"
check "SKILL.md CAP_TOP=1020"             grep -q "CAP_TOP=1020" "$SKILL_DIR/SKILL.md"
check "SKILL.md pip-safe variant"         grep -q "pip-safe" "$SKILL_DIR/SKILL.md"
check "SKILL.md force_original=increase"  grep -q "force_original_aspect_ratio=increase" "$SKILL_DIR/SKILL.md"
check "SKILL.md force_original=decrease"  grep -q "force_original_aspect_ratio=decrease" "$SKILL_DIR/SKILL.md"
check "SKILL.md loudnorm ONCE"            grep -q "loudnorm" "$SKILL_DIR/SKILL.md"
check "SKILL.md amix normalize=0"         grep -q "normalize=0" "$SKILL_DIR/SKILL.md"
check "SKILL.md shortest=1"               grep -q "shortest=1" "$SKILL_DIR/SKILL.md"
check "SKILL.md COVER_AT extraction"      grep -q "COVER_AT" "$SKILL_DIR/SKILL.md"
check "SKILL.md fmt1 mapping documented"  grep -q "p-reels-fmt1" "$SKILL_DIR/SKILL.md"
check "SKILL.md hf-fmt5 mapping documented" grep -q "hf-fmt5" "$SKILL_DIR/SKILL.md"

# Component skill directories — search all known skill locations
_find_skill() {
  find "$HOME/.claude/skills" "$HOME/.hermes/skills" /Users/vasanth/Code/skills \
    -maxdepth 4 -type d -name "$1" 2>/dev/null | head -1
}
BROLL_SYNC=$(_find_skill c-broll-sync)
PREMIUM=$(_find_skill c-reel-premium)
TYPING_UI=$(_find_skill c-typing-ui)

check "c-broll-sync found on disk"       test -n "$BROLL_SYNC"
check "c-broll-sync/scripts/plan.js"     test -f "${BROLL_SYNC:-/dev/null}/scripts/plan.js"
check "c-reel-premium found on disk"     test -n "$PREMIUM"
check "c-reel-premium templates/"        test -d "${PREMIUM:-/dev/null}/templates"
check "c-typing-ui found on disk"        test -n "$TYPING_UI"
check "c-typing-ui typing-scene.html"    test -f "${TYPING_UI:-/dev/null}/templates/typing-scene.html"
check "c-typing-ui hook-scene.html"      test -f "${TYPING_UI:-/dev/null}/templates/hook-scene.html"

echo ""
echo "Results: ${PASS} pass, ${FAIL} fail"
[ "$FAIL" -eq 0 ] && echo "All checks passed." || { echo "Some checks failed — fix before bake-off."; exit 1; }
