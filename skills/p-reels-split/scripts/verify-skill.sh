#!/usr/bin/env bash
# p-reels-split/scripts/verify-skill.sh
# Runs static checks on the skill's own files (no real cook needed).
# Usage: bash scripts/verify-skill.sh
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label"
  fi
}

check_absent() {
  local label="$1" pattern="$2" file="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    fail "$label"
  else
    pass "$label"
  fi
}

echo "=== p-reels-split static checks ==="

# SKILL.md frontmatter
check "SKILL.md exists"                   test -f "$SKILL_DIR/SKILL.md"
check "SKILL.md has name field"           grep -q "^name: p-reels-split" "$SKILL_DIR/SKILL.md"
check "SKILL.md has kind: pipeline"       grep -q "^kind: pipeline" "$SKILL_DIR/SKILL.md"
check "SKILL.md has visibility: catalog"  grep -q "^visibility: catalog" "$SKILL_DIR/SKILL.md"
check "SKILL.md lists c-broll-sync dep"   grep -q "c-broll-sync" "$SKILL_DIR/SKILL.md"
check "SKILL.md lists c-reel-premium dep" grep -q "c-reel-premium" "$SKILL_DIR/SKILL.md"
check "SKILL.md lists c-typing-ui dep"    grep -q "c-typing-ui" "$SKILL_DIR/SKILL.md"
check "SKILL.md has hermes.vendored"      grep -q "vendored:" "$SKILL_DIR/SKILL.md"

# Split geometry enforcement
check "SKILL.md uses vstack"              grep -q "vstack" "$SKILL_DIR/SKILL.md"
check "SKILL.md SPLIT_H=960"             grep -q "SPLIT_H=960" "$SKILL_DIR/SKILL.md"
check "SKILL.md top zone 1080x960"        grep -q "1080.960" "$SKILL_DIR/SKILL.md"
check "SKILL.md bottom zone 1080x960"     grep -q "bottom.*1080.960\|1080.960.*bottom" "$SKILL_DIR/SKILL.md"
check "SKILL.md 50/50 documented"         grep -q "50/50" "$SKILL_DIR/SKILL.md"

# Template
check "templates/split-motion-card.html exists"  test -f "$SKILL_DIR/templates/split-motion-card.html"
check "split-motion-card height 960px"            grep -q "height: 960px" "$SKILL_DIR/templates/split-motion-card.html"
check "split-motion-card data-height 960"         grep -q "data-height=\"960\"" "$SKILL_DIR/templates/split-motion-card.html"
check_absent "split-motion-card NO pip-band CSS var" "var(--pip-band)" "$SKILL_DIR/templates/split-motion-card.html"
check "split-motion-card uses TITLE_HTML"         grep -q "{{TITLE_HTML}}" "$SKILL_DIR/templates/split-motion-card.html"
check "split-motion-card uses sc-root class"      grep -q "sc-root" "$SKILL_DIR/templates/split-motion-card.html"

SCRIPT_SECTION=$(sed -n '/<script>/,/<\/script>/p' "$SKILL_DIR/templates/split-motion-card.html" 2>/dev/null)
if echo "$SCRIPT_SECTION" | grep -q "window.getComputedStyle"; then
  fail "split-motion-card script uses window.getComputedStyle (must use bare getComputedStyle)"
else
  pass "split-motion-card script does not call window.getComputedStyle"
fi
if echo "$SCRIPT_SECTION" | grep -q "Math.random()"; then
  fail "split-motion-card script uses Math.random() (must use seeded PRNG)"
else
  pass "split-motion-card script does not call Math.random()"
fi
if echo "$SCRIPT_SECTION" | grep -q "__timelines\[\"root\"\]"; then
  pass "split-motion-card uses dict-form timeline registration"
else
  fail "split-motion-card missing window.__timelines[\"root\"] = tl"
fi
if echo "$SCRIPT_SECTION" | grep -q "__timelines.push"; then
  fail "split-motion-card uses old .push() timeline API"
else
  pass "split-motion-card does not use .push() timeline API"
fi

# Guard rails
check "SKILL.md cover rule present"         grep -q "cover-freeze\|cover_concat" "$SKILL_DIR/SKILL.md"
check "SKILL.md CAP_TOP=860"               grep -q "CAP_TOP=860" "$SKILL_DIR/SKILL.md"
check "SKILL.md loudnorm ONCE"             grep -q "loudnorm" "$SKILL_DIR/SKILL.md"
check "SKILL.md amix normalize=0"          grep -q "normalize=0" "$SKILL_DIR/SKILL.md"
check "SKILL.md shortest=1"               grep -q "shortest" "$SKILL_DIR/SKILL.md"
check "SKILL.md COVER_AT extraction"       grep -q "COVER_AT\|cover_at" "$SKILL_DIR/SKILL.md"
check "SKILL.md BLURRED-FILL documented"   grep -q "BLURRED-FILL" "$SKILL_DIR/SKILL.md"
check "SKILL.md force_original=increase"   grep -q "force_original_aspect_ratio=increase" "$SKILL_DIR/SKILL.md"
check "SKILL.md force_original=decrease"   grep -q "force_original_aspect_ratio=decrease" "$SKILL_DIR/SKILL.md"
check "SKILL.md top/bottom trim step"      grep -q "top-trimmed\|Step 7.5" "$SKILL_DIR/SKILL.md"
check "SKILL.md vstack inputs=2"           grep -q "vstack=inputs=2" "$SKILL_DIR/SKILL.md"

# Component skill directories
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
