#!/usr/bin/env bash
# scripts/sync-skills.sh — sync recipe skills directly from the private source
# repo into this repo's skills/ dir, replacing the git-subtree-of-public-
# cfw-skills pipeline (cfw-skills-pack build/publish + `git subtree pull`).
#
# Runtime-free repo: bash + python3 only. NO node, NO npm — this script must
# never introduce a node-runtime dependency into cfw-render.
#
# Behavior:
#   1. Requires $CFW_SKILLS_SRC (no fallback — see below).
#   2. Reads the recipe allowlist from cfw-render's own config/recipes.json
#      (cfw-skills-pack retired — the allowlist now lives in this repo).
#   3. For each allowlisted recipe, copies the recipe's own files AS-IS from
#      $CFW_SKILLS_SRC/<recipe>/ into <out-dir>/<recipe>/, then computes the
#      transitive closure of its `dependsOn` graph (cycle-safe) and copies
#      each dependency into <out-dir>/<recipe>/.hub/<dep>/ (flattened, not
#      nested). No body/path rewriting — the source already uses
#      `.hub/<dep>/...`-relative paths.
#   4. Regenerates <out-dir>/index.json (recipe list, per-file fileHashes,
#      version, checksum) in the shape scripts/verify-skills-bundle.sh and
#      scripts/gen-skills-manifest.sh expect.
#   5. Unless --skip-manifest or --out-dir points somewhere other than the
#      real <repo>/skills, refreshes config/skills-version.json (rollup via
#      gen-skills-manifest.sh, then provenance fields patched to point at the
#      private source instead of the retired git-subtree).
#
# Idempotent — safe to re-run; each recipe's target dir is cleared before copy.
#
# ── OPEN FUTURE ITEM — vendored progressive-loading markers ────────────────────
# The pack-build pipeline this replaces ALSO injected Hermes-assistant markers
# into each recipe's SKILL.md (a `metadata.hermes.vendored` frontmatter block, a
# dual-home `SKILL_DIR` resolver, and `→ LOAD: skill_view("<recipe>",
# ".hub/<dep>/SKILL.md")` cross-reference rewrites). This plain-copy sync
# deliberately does NOT reproduce them: the cfw-render RENDER runtime does not
# read any of them (verified — zero code hits for `skill_view` /
# `metadata.hermes.vendored` in bin/ + lib/), and the source SKILL.md already
# references every dependency via `.hub/<dep>/…`-relative paths, so a plain copy
# runs correctly. Those markers are Hermes-ASSISTANT-side progressive-loading
# metadata, and the assistant today reads a SEPARATE bundle at
# /data/shared/cfw-skills/cfw — not this one.
# ⚠ IF the Hermes assistant is ever pointed at cfw-render's skills bundle, it MAY
#   need those markers back — re-evaluate marker injection AT THAT MIGRATION,
#   NOT now.
#
# Usage:
#   CFW_SKILLS_SRC=/Users/vasanth/ecosystem/harness/skills scripts/sync-skills.sh
#   CFW_SKILLS_SRC=/Users/vasanth/ecosystem/harness/skills scripts/sync-skills.sh --out-dir /tmp/scratch-skills
#
# Options:
#   --recipes FILE       path to the recipe allowlist (default: <repo>/config/recipes.json,
#                        cfw-render's own internal allowlist — cfw-skills-pack retired).
#   --out-dir DIR        where to write the synced bundle (default: <repo>/skills).
#                        Point this at a scratch dir to dry-run without
#                        touching the committed bundle.
#   --skip-manifest      don't refresh config/skills-version.json even when
#                        --out-dir is the real skills/ dir.
#
# Env:
#   CFW_SKILLS_SRC   REQUIRED. Absolute path to the private source skills repo
#                    (e.g. /Users/vasanth/ecosystem/harness/skills). NOT defaulted —
#                    in particular this never falls back to the old, now-dead
#                    /Users/vasanth/Code/skills path that earlier tooling used.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

OUT_DIR="$REPO_DIR/skills"
RECIPES_CONFIG="$REPO_DIR/config/recipes.json"
SKIP_MANIFEST=0

while (( $# )); do
  case "$1" in
    --recipes) RECIPES_CONFIG="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --skip-manifest) SKIP_MANIFEST=1; shift ;;
    -*) echo "sync-skills.sh: unknown flag $1" >&2; exit 2 ;;
    *) echo "sync-skills.sh: unexpected arg $1" >&2; exit 2 ;;
  esac
done

# ---- CFW_SKILLS_SRC: required, fail loudly, no silent fallback ----
if [[ -z "${CFW_SKILLS_SRC:-}" ]]; then
  echo "sync-skills.sh: ERROR — CFW_SKILLS_SRC is not set." >&2
  echo "  Point it at the private source skills repo, e.g.:" >&2
  echo "    CFW_SKILLS_SRC=/Users/vasanth/ecosystem/harness/skills $0" >&2
  echo "  There is no default — this script will NOT fall back to any other path." >&2
  exit 1
fi
if [[ ! -d "$CFW_SKILLS_SRC" ]]; then
  echo "sync-skills.sh: ERROR — CFW_SKILLS_SRC='$CFW_SKILLS_SRC' does not exist." >&2
  exit 1
fi
CFW_SKILLS_SRC="$(cd "$CFW_SKILLS_SRC" && pwd)"

# ---- recipe allowlist (cfw-render's own config/recipes.json) ----
if [[ ! -f "$RECIPES_CONFIG" ]]; then
  echo "sync-skills.sh: ERROR — recipe allowlist not found at '$RECIPES_CONFIG'." >&2
  echo "  Expected cfw-render's config/recipes.json, or pass --recipes <path> explicitly." >&2
  exit 1
fi

echo "sync-skills.sh: source   = $CFW_SKILLS_SRC"
echo "sync-skills.sh: recipes  = $RECIPES_CONFIG"
echo "sync-skills.sh: out-dir  = $OUT_DIR"

mkdir -p "$OUT_DIR"

python3 "$SELF_DIR/sync-skills.py" \
  --src "$CFW_SKILLS_SRC" \
  --recipes "$RECIPES_CONFIG" \
  --out-dir "$OUT_DIR"

if (( SKIP_MANIFEST == 0 )) && [[ "$OUT_DIR" == "$REPO_DIR/skills" ]]; then
  SOURCE_COMMIT="$(git -C "$CFW_SKILLS_SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
  SOURCE_REMOTE="$(git -C "$CFW_SKILLS_SRC" remote get-url origin 2>/dev/null || echo "")"
  # Prefer the source repo's own origin slug; if it has no remote configured,
  # fall back to config/recipes.json's "source" field (default "ecosystem/harness/skills").
  SOURCE_REPO_SLUG="$(python3 -c '
import re, sys, json
url = sys.argv[1]
m = re.search(r"[:/]([^/]+/[^/]+?)(\.git)?$", url) if url else None
if m:
    print(m.group(1))
else:
    try:
        cfg = json.load(open(sys.argv[2]))
        print(cfg.get("source") or "ecosystem/harness/skills")
    except Exception:
        print("ecosystem/harness/skills")
' "$SOURCE_REMOTE" "$RECIPES_CONFIG")"

  "$SELF_DIR/gen-skills-manifest.sh" --skills-dir "$OUT_DIR" --manifest "$REPO_DIR/config/skills-version.json"

  python3 - "$REPO_DIR/config/skills-version.json" "$SOURCE_REPO_SLUG" "$SOURCE_COMMIT" <<'PY'
import json, sys
path, repo_slug, source_commit = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(path))
m["source"] = repo_slug
m.pop("sourceBranch", None)
m["sourceCommit"] = source_commit
m["sourceSha"] = source_commit
m.pop("sourceRelease", None)
m["bundleMethod"] = "scripts/sync-skills.sh (direct copy from private source repo; git-subtree retired)"
m["updateCommand"] = "CFW_SKILLS_SRC=<path-to-private-skills-repo> scripts/sync-skills.sh"
with open(path, "w") as f:
    json.dump(m, f, indent=2)
    f.write("\n")
print(f"sync-skills.sh: refreshed provenance fields in {path}")
PY
else
  echo "sync-skills.sh: skipping config/skills-version.json refresh (--skip-manifest or scratch out-dir)"
fi

echo "sync-skills.sh: done."
