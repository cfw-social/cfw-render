#!/usr/bin/env bash
# scripts/sync-skills.sh — build a bundle of recipe skills from the private source
# repo into a scratch --out-dir (for cfw-social's scripts/recipe-library/publish.mjs).
# It never writes into this repo's own skills/ (frozen, WI28; see below).
#
# Runtime-free repo: bash + python3 only. NO node, NO npm — this script must
# never introduce a node-runtime dependency into cfw-render.
#
# Behavior:
#   1. Requires $CFW_SKILLS_SRC (no fallback — see below).
#   2. Reads the recipe allowlist from the file named by --recipes (REQUIRED).
#      Name only the recipes you publish; config/recipes.json describes the
#      frozen skills/ copy.
#   3. For each allowlisted recipe, copies the recipe's own files AS-IS from
#      $CFW_SKILLS_SRC/<recipe>/ into <out-dir>/<recipe>/, then computes the
#      transitive closure of its `dependsOn` graph (cycle-safe) and copies
#      each dependency into <out-dir>/<recipe>/.hub/<dep>/ (flattened, not
#      nested). ONE body rewrite is applied per copied dir (CFW-312): the
#      source's "find my own/a sub-skill dir under a host skill-install root"
#      idiom — correct for the source library's other (agent-tool)
#      consumers, wrong for this runtime-free bundle — is rewritten to resolve
#      against $CFW_RENDER_SKILLS_DIR and the bundle's own .hub/<dep>/. See
#      scripts/sync-skills.py's rewrite_host_path_resolvers().
#   4. Regenerates <out-dir>/index.json (recipe list, per-file fileHashes,
#      version, checksum) in the shape scripts/verify-skills-bundle.sh and
#      scripts/gen-skills-manifest.sh expect — hashed AFTER the rewrite, so
#      the pinned hashes match what actually ships.
#   5. Runs scripts/check-skills-portability.sh against <out-dir> and aborts
#      (non-zero exit, offending lines printed) if any host-path resolver
#      survived the rewrite — belt-and-suspenders against a future recipe
#      whose source uses a resolver shape the rewrite doesn't yet recognize.
#   6. Runs scripts/check-no-host-paths.sh against <out-dir> and aborts if any
#      bare `/Users/<anyone>/...` string survived sync-skills.py's
#      brand-overrides strip / generic redaction (CFW-318) — the bundle must
#      never leak the author's identity/filesystem layout, `.hub/**` and
#      `brand-overrides/**` included.
#   7. Runs scripts/check-no-handle-defaults.sh against <out-dir> and aborts if
#      any skill ships a literal handle default — another brand's handle or a
#      placeholder (`${CTA_HANDLE:-@…}`, `"handle": "@…"` outside
#      brand-overrides/<slug>/brand.json, `@mr.growthguide`) — because the end
#      card must be per-brand (CFW-354).
#
# Use a fresh folder for each run: each recipe's target dir inside --out-dir is cleared before copy, so an
# --out-dir that already holds anything is refused.
#
# RETIRED AS A RECIPE SOURCE (owner decision 2026-11-10): this repo's skills/ is
# frozen and is never synced again. This script is only a bundle builder for
# cfw-social's scripts/recipe-library/publish.mjs, so --out-dir is REQUIRED and
# the script exits 2 if it is missing, or if it is not a fresh folder: it must be absent or EMPTY, and must not
# be, or lie inside, this repo (skills/, config/, test/ ...), a parent of this repo, or the source library
# (CFW_SKILLS_SRC). That is decided by file identity (device + inode), not by path text: the walk starts at
# realpath(--out-dir) and checks it and each parent, so a case variant (SKILLS on a case-insensitive disk), a
# firmlink path, a symlinked parent or a symlink plus `..` is refused too. Recipe and dependency names must be
# plain names (^[A-Za-z0-9][A-Za-z0-9._-]*$, no `..`, at most 64 characters), checked before anything is written.
# --recipes is also REQUIRED (exit 2): name only the recipes you publish;
# config/recipes.json describes the frozen skills/ copy. The refusals run before
# anything is written. skills/ and config/ are never changed by this script.
#
# Usage:
#   CFW_SKILLS_SRC=/Users/vasanth/ecosystem/harness/skills scripts/sync-skills.sh \
#     --recipes /tmp/my-recipes.json --out-dir /tmp/scratch-skills
#
# Options:
#   --recipes FILE       REQUIRED. The recipe allowlist (JSON, same shape as
#                        config/recipes.json). Name only the recipes you publish;
#                        config/recipes.json describes the frozen skills/ copy.
#   --out-dir DIR        REQUIRED. Where to write the synced bundle. Use a
#                        fresh scratch folder (absent or empty). Refused if it is,
#                        or is inside, this repo (skills/ is frozen), a parent of
#                        this repo, or the source library.
#   --skip-manifest      accepted and ignored (kept so older callers still work;
#                        this script no longer writes config/skills-version.json).
#
# Env:
#   CFW_SKILLS_SRC   REQUIRED. Absolute path to the private source skills repo
#                    (e.g. /Users/vasanth/ecosystem/harness/skills). NOT defaulted —
#                    in particular this never falls back to the old, now-dead
#                    /Users/vasanth/Code/skills path that earlier tooling used.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

OUT_DIR=""
RECIPES_CONFIG=""

while (( $# )); do
  case "$1" in
    --recipes) [[ $# -ge 2 ]] || { echo "sync-skills.sh: --recipes needs a file" >&2; exit 2; }; RECIPES_CONFIG="$2"; shift 2 ;;
    --out-dir) [[ $# -ge 2 ]] || { echo "sync-skills.sh: --out-dir needs a folder" >&2; exit 2; }; OUT_DIR="$2"; shift 2 ;;
    --skip-manifest) shift ;;   # accepted and ignored: nothing here writes config/skills-version.json
    -*) echo "sync-skills.sh: unknown flag $1" >&2; exit 2 ;;
    *) echo "sync-skills.sh: unexpected arg $1" >&2; exit 2 ;;
  esac
done

# ---- --out-dir: required, and never this repo's own (frozen) skills/ ----
if [[ -z "$OUT_DIR" ]]; then
  echo "sync-skills.sh: ERROR — --out-dir is required." >&2
  echo "  skills/ in this repo is retired as a recipe source (owner decision 2026-11-10) and is never synced." >&2
  echo "  Build a bundle into a scratch dir: CFW_SKILLS_SRC=<src> $0 --recipes <file> --out-dir <scratch>" >&2
  exit 2
fi
# The one out-dir guard lives in sync-skills.py (guard_out_dir); --check-only runs just that, before anything
# is made or written, and sync-skills.py runs it again before its first write. It refuses (exit 2) by file
# identity: this repo, anything inside it (skills/, config/, ...), a parent of it, the source library
# (CFW_SKILLS_SRC) and anything inside it, and any out-dir that exists and is not an empty folder.
python3 "$SELF_DIR/sync-skills.py" --check-only --out-dir="$OUT_DIR" --src="${CFW_SKILLS_SRC:-}" || exit $?

# ---- --recipes: required (WI28). config/recipes.json lists the frozen skills/ copy, which the
# source library no longer matches, so there is no default.
if [[ -z "$RECIPES_CONFIG" ]]; then
  echo "sync-skills.sh: ERROR — --recipes <file> is required: name only the recipes you publish; config/recipes.json describes the frozen skills/ copy." >&2
  exit 2
fi

# ---- CFW_SKILLS_SRC: required, fail loudly, no silent fallback ----
if [[ -z "${CFW_SKILLS_SRC:-}" ]]; then
  echo "sync-skills.sh: ERROR — CFW_SKILLS_SRC is not set." >&2
  echo "  Point it at the private source skills repo, e.g.:" >&2
  echo "    CFW_SKILLS_SRC=/Users/vasanth/ecosystem/harness/skills $0 --recipes <file> --out-dir <scratch>" >&2
  echo "  There is no default — this script will NOT fall back to any other path." >&2
  exit 1
fi
if [[ ! -d "$CFW_SKILLS_SRC" ]]; then
  echo "sync-skills.sh: ERROR — CFW_SKILLS_SRC='$CFW_SKILLS_SRC' does not exist." >&2
  exit 1
fi
CFW_SKILLS_SRC="$(cd "$CFW_SKILLS_SRC" && pwd)"

# ---- recipe allowlist (the file named by --recipes) ----
if [[ ! -f "$RECIPES_CONFIG" ]]; then
  echo "sync-skills.sh: ERROR — recipe allowlist not found at '$RECIPES_CONFIG'." >&2
  exit 1
fi

echo "sync-skills.sh: source   = $CFW_SKILLS_SRC"
echo "sync-skills.sh: recipes  = $RECIPES_CONFIG"
echo "sync-skills.sh: out-dir  = $OUT_DIR"

# (sync-skills.py makes --out-dir itself, after it has validated every name, so a refusal creates nothing.)

python3 "$SELF_DIR/sync-skills.py" \
  --src "$CFW_SKILLS_SRC" \
  --recipes "$RECIPES_CONFIG" \
  --out-dir="$OUT_DIR"

# CFW-312 bundle gate — abort the sync if any recipe still resolves a
# sub-skill (or itself) via a host-path `find` instead of the bundle's own
# .hub/<dep>/. sync-skills.py's rewrite pass should make this impossible, but
# a future recipe whose source SKILL.md uses some new resolver shape the
# rewrite doesn't yet recognize must fail HERE — loudly, at sync time — not
# ship a silently-broken recipe that only shows up as a render failure later.
"$SELF_DIR/check-skills-portability.sh" --skills-dir "$OUT_DIR"

# CFW-318 bundle gate — abort the sync if any bare `/Users/<anyone>/...`
# string survived sync-skills.py's brand-overrides strip (Part 2) or generic
# redaction (Part 3). The rewrite passes should make this impossible, but a
# future field/file shape they don't yet recognize must fail HERE, loudly,
# not ship a bundle that leaks the author's own filesystem layout.
"$SELF_DIR/check-no-host-paths.sh" --skills-dir "$OUT_DIR"

# WI31.10 bundle gate — abort the sync if a transform or a source edit left
# a recipe with the same step twice (R-8HZS: two copies of spotlight's 4b).
"$SELF_DIR/check-no-duplicate-steps.sh" --skills-dir "$OUT_DIR"

# CFW-354 bundle gate — abort the sync if any skill ships a literal handle
# default — another brand's handle or a placeholder — because the end card
# must be per-brand. One brand's `@mr.growthguide` once shipped on every
# brand's Spotlight reels via `CTA_HANDLE="${CTA_HANDLE:-…}"`; a future recipe
# that re-introduces that shape must fail HERE, loudly, at sync time.
"$SELF_DIR/check-no-handle-defaults.sh" --skills-dir "$OUT_DIR"

echo "sync-skills.sh: done."
