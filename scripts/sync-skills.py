#!/usr/bin/env python3
"""
sync-skills.py — worker for scripts/sync-skills.sh.

Reads the recipe allowlist from cfw-render's own config/recipes.json, copies each
listed recipe PLUS the transitive closure of its dependsOn graph (cycle-safe)
from the private source skills repo into <out-dir>/<recipe>/ (own files) and
<out-dir>/<recipe>/.hub/<dep>/ (each dependency, flattened — not nested), then
writes <out-dir>/index.json in the shape scripts/verify-skills-bundle.sh and
scripts/gen-skills-manifest.sh expect.

Mostly a plain copy — EXCEPT for one deliberate rewrite (CFW-312):
rewrite_host_path_resolvers() patches the source's "locate my own dir / locate
a sub-skill dir" bash idiom, which does a `find` over host install locations
($HOME/.claude/skills, $HOME/.hermes/*, the source library's own absolute
path). That idiom is correct for the SOURCE library (where Hermes/Claude Code
install skills as siblings under those host roots) but wrong for cfw-render's
vendored, runtime-free bundle, where none of those host roots exist — it was
silently resolving to "" or "/.hub/<dep>" on the render box. The rewrite
anchors "my own dir" on $CFW_RENDER_SKILLS_DIR (already exported into the
Director's env by cr_load_config) and "a sub-skill dir" on the bundle's own
.hub/<dep>/, computed and baked in as literals at sync time — no runtime
`find` needed. Runs after copy_tree, before list_files/hashing, so the hashes
in index.json cover the rewritten bytes (what actually ships).

Two more sync-time transforms (CFW-318), run after rewrite_host_path_resolvers
and before list_files/hashing, same ordering guarantee:
  strip_brand_override_host_paths() nulls/drops the two host-path fields
    (outro.path, hero_portrait) that brand-overrides/<slug>/brand.json files
    can carry.
  redact_literal_host_paths() replaces any remaining bare `/Users/<user>`
    segment in any file with `/Users/<redacted>` — a generic safety net over
    prose/doc/tooling references with no structured shape to null out.
index["sourceSha"] is also stamped here, from `git rev-parse HEAD` of --src,
so index.json is self-describing independent of sync-skills.sh's separate
skills-version.json patch.

No third-party deps — stdlib only (json, re, hashlib, shutil, subprocess, pathlib).
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

IGNORE_NAMES = {".DS_Store", "__pycache__", ".git", ".hub"}


def read_frontmatter(skill_md: Path) -> dict:
    """Minimal frontmatter reader — only pulls the handful of scalar/flow-list
    keys sync-skills.py needs (dependsOn, requires, name). Not a general YAML
    parser: the source's frontmatter uses simple `key: value` / `key: [a, b]`
    lines, so a full YAML lib is unnecessary."""
    if not skill_md.is_file():
        return {}
    text = skill_md.read_text(encoding="utf-8")
    m = re.match(r"^---\n(.*?\n)---\n", text, re.DOTALL)
    if not m:
        return {}
    fm_text = m.group(1)
    data = {}
    for line in fm_text.splitlines():
        km = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$", line)
        if not km:
            continue
        key, val = km.group(1), km.group(2).strip()
        if val.startswith("[") and val.endswith("]"):
            inner = val[1:-1].strip()
            data[key] = [x.strip() for x in inner.split(",") if x.strip()] if inner else []
        elif val == "":
            data[key] = None
        else:
            data[key] = val
    return data


def ignore_junk(_dir, names):
    return [n for n in names if n in IGNORE_NAMES]


def copy_tree(src: Path, dest: Path):
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(src, dest, ignore=ignore_junk)


# ---- CFW-312: rewrite host-path sub-skill resolvers to bundle-relative ----
#
# Source shape (correct for the source library, wrong for this bundle):
#   SKILL_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" \
#     "$HOME/.hermes/profiles" /Users/<user>/ecosystem/harness/skills \
#     -maxdepth N -type d -name <literal-name> 2>/dev/null | head -1)
# optionally followed by a dead-on-arrival fallback line:
#   [ -n "$VAR" ] || VAR="$SKILL_DIR/.hub/<dep>"
_HOST_ROOT_ALT = (
    r'(?:"\$HOME/\.claude/skills"|"\$HOME/\.hermes/skills"|"\$HOME/\.hermes/profiles"'
    r'|/Users/[A-Za-z0-9_.\-]+/ecosystem/harness/skills)'
)
_FIND_ASSIGN_RE = re.compile(
    r'(?P<indent>[ \t]*)(?P<var>[A-Za-z_][A-Za-z0-9_]*)=\$\(\s*find\s+'
    r'(?P<roots>(?:' + _HOST_ROOT_ALT + r'[ \t]*(?:\\\n[ \t]*)?)+)'
    r'-maxdepth\s+\d+\s+-type\s+d\s+-name\s+"?(?P<name>[A-Za-z0-9_.\-]+)"?[ \t]+'
    r'2>/dev/null[ \t]*\|[ \t]*head[ \t]+-1[ \t]*\)'
)
_HOST_COMMENT_RE = re.compile(
    r'^[ \t]*#.*(?:\$HOME/\.claude|\$HOME/\.hermes|/Users/[A-Za-z0-9_.\-]+/ecosystem/harness/skills).*\n?',
    re.MULTILINE,
)
# The same idiom, wrapped in a parameterized helper (scripts/verify-skill.sh):
#   _find_skill() {
#     find "$HOME/.claude/skills" "$HOME/.hermes/skills" /Users/<user>/ecosystem/harness/skills \
#       -maxdepth N -type d -name "$1" 2>/dev/null | head -1
#   }
_FIND_SKILL_FN_RE = re.compile(
    r'(?P<indent>[ \t]*)_find_skill\(\) \{\n'
    r'[ \t]*find\s+"\$HOME/\.claude/skills"\s+"\$HOME/\.hermes/skills"\s+'
    r'/Users/[A-Za-z0-9_.\-]+/ecosystem/harness/skills[ \t]*\\\n'
    r'[ \t]*-maxdepth\s+\d+\s+-type\s+d\s+-name\s+"\$1"\s+2>/dev/null\s*\|\s*head\s+-1\n'
    r'(?P=indent)\}\n'
)


def rewrite_host_path_resolvers(directory: Path, own_rel_path: str, is_nested: bool) -> int:
    """Rewrite the host-path `find` sub-skill resolver idiom (CFW-312) in every
    text file under `directory` to resolve against the bundle instead of host
    skill install locations.

    `own_rel_path` is this directory's own path relative to the bundle root
    (e.g. "p-reels-pip" for a top-level recipe, "p-reels-pip-heygen/.hub/p-reels-pip"
    for a vendored dependency that is itself a recipe) — baked in as a sync-time
    literal, so no runtime `find` is needed for a file to locate itself.

    `is_nested` is True when `directory` sits inside a parent's .hub/ (i.e. this
    call is rewriting a vendored dependency, not a top-level recipe). copy_tree
    strips any nested `.hub/` out of what it copies (IGNORE_NAMES), so a
    dependency's OWN sub-skill-dir references must resolve as a flattened
    SIBLING — "$SKILL_DIR/../<dep>" — not "$SKILL_DIR/.hub/<dep>" (which would
    point at a .hub/ that was never copied). Mirrors the second-fallback
    pattern the source already uses for deeper deps (e.g. "$SKILL_DIR/../f-gsap/vendor").

    Returns the number of files changed.
    """
    own_name = own_rel_path.rsplit("/", 1)[-1]
    changed = 0
    for path in sorted(directory.rglob("*")):
        if not path.is_file() or path.name in IGNORE_NAMES:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, ValueError):
            continue  # binary file — nothing to rewrite

        rewritten_vars = {m.group("var") for m in _FIND_ASSIGN_RE.finditer(text)}
        if not rewritten_vars and not _FIND_SKILL_FN_RE.search(text) and not _HOST_COMMENT_RE.search(text):
            continue

        def _sub_find_assign(m: "re.Match[str]") -> str:
            indent, var, name = m.group("indent"), m.group("var"), m.group("name")
            if name == own_name:
                return (
                    f'{indent}{var}="${{CFW_RENDER_SKILLS_DIR:?CFW_RENDER_SKILLS_DIR not set}}'
                    f'/{own_rel_path}"'
                )
            sub_path = f"$SKILL_DIR/../{name}" if is_nested else f"$SKILL_DIR/.hub/{name}"
            return f'{indent}{var}="{sub_path}"'

        new_text = _FIND_ASSIGN_RE.sub(_sub_find_assign, text)

        if rewritten_vars:
            var_alt = "|".join(re.escape(v) for v in rewritten_vars)
            fallback_re = re.compile(
                r'[ \t]*\[ -n "\$(?:' + var_alt + r')" \] \|\| (?:' + var_alt
                + r')="\$SKILL_DIR/\.hub/[A-Za-z0-9_.\-]+"(?:[ \t]*#[^\n]*)?\n'
            )
            new_text = fallback_re.sub("", new_text)

        def _sub_find_skill_fn(m: "re.Match[str]") -> str:
            indent = m.group("indent")
            sub_path = '"$SKILL_DIR/../$1"' if is_nested else '"$SKILL_DIR/.hub/$1"'
            return f'{indent}_find_skill() {{\n{indent}  echo {sub_path}\n{indent}}}\n'

        new_text = _FIND_SKILL_FN_RE.sub(_sub_find_skill_fn, new_text)

        # Stale comments describing the now-removed host-path find — not
        # executable, but still a forbidden substring the portability gate
        # would otherwise keep tripping on forever.
        new_text = _HOST_COMMENT_RE.sub("", new_text)

        if new_text != text:
            path.write_text(new_text, encoding="utf-8")
            changed += 1
    return changed


# ---- CFW-318 Part 2: strip brand-overrides host-path fields ----
#
# brand-overrides/<slug>/brand.json is a live, documented mechanism
# (brand-overrides/README.md, CFW-128) — not dead vendored cruft. Two fields
# in it can carry an absolute, host-only, dead-at-render-time path:
#   outro.path       -> null when absolute (outro.relative is the field
#                        actually meant to travel; null is the existing,
#                        already-shipped shape for "no outro asset", see
#                        b-vasanth/brand.json)
#   hero_portrait    -> key dropped entirely when absolute (no relative
#                        counterpart exists; an absent key is the existing
#                        convention for "not available")
# Nothing else in brand.json is touched — palette/fonts/voice/captions/cta/
# cfw_brand_id are documented, intended content, not path leaks.
_ABS_HOST_PATH_RE = re.compile(r'^/Users/[^/]+/')


def strip_brand_override_host_paths(directory: Path) -> int:
    """Null/drop the two leaking host-path fields in every
    brand-overrides/<slug>/brand.json under `directory`. No-op (no write) on
    a file that doesn't need touching, so untouched recipes' files/hashes
    don't needlessly change."""
    changed = 0
    for path in sorted(directory.rglob("brand-overrides/*/brand.json")):
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, ValueError):
            continue
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            continue

        mutated = False
        outro = data.get("outro")
        if isinstance(outro, dict):
            outro_path = outro.get("path")
            if isinstance(outro_path, str) and _ABS_HOST_PATH_RE.match(outro_path):
                outro["path"] = None
                mutated = True
        hero_portrait = data.get("hero_portrait")
        if isinstance(hero_portrait, str) and _ABS_HOST_PATH_RE.match(hero_portrait):
            del data["hero_portrait"]
            mutated = True

        if mutated:
            path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            changed += 1
    return changed


# ---- CFW-318 Part 3: generic host-path redaction (the other 18 files) ----
#
# Prose/doc/tooling references with no structured shape to null out — redact
# the literal `/Users/<user>` segment, user-agnostic (same style as
# _HOST_ROOT_ALT above, so a BYOA customer's own home dir is caught too, not
# just "vasanth"), leaving the rest of the path/sentence intact so a doc read
# on a future maintainer's own machine still reads as a path.
_LITERAL_HOST_PATH_RE = re.compile(r'/Users/[A-Za-z0-9_.\-]+(?=/)')


def redact_literal_host_paths(directory: Path) -> int:
    """Replace every bare `/Users/<user>` segment under `directory` with
    `/Users/<redacted>`. Runs AFTER strip_brand_override_host_paths (Part 2
    must structurally null/drop first) as a safety net over every file,
    brand.json included — by design it should find nothing left there once
    Part 2 has run."""
    changed = 0
    for path in sorted(directory.rglob("*")):
        if not path.is_file() or path.name in IGNORE_NAMES:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, ValueError):
            continue  # binary file — nothing to redact
        new_text = _LITERAL_HOST_PATH_RE.sub("/Users/<redacted>", text)
        if new_text != text:
            path.write_text(new_text, encoding="utf-8")
            changed += 1
    return changed


def git_head_sha(repo: Path) -> str | None:
    """Best-effort `git rev-parse HEAD` of `repo`. Returns None (never
    raises) when `repo` isn't a git checkout — e.g. a test fixture dir — so
    index["sourceSha"] just stays null for fixture syncs rather than failing
    the sync."""
    try:
        out = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        )
        return out.stdout.strip()
    except Exception:
        return None


def walk_closure(src_root: Path, start_deps: list[str]) -> list[str]:
    """BFS the transitive dependsOn graph from start_deps. Cycle-safe (visited
    set). Deps may themselves be recipes (p-* depending on p-*, e.g. the HeyGen
    wrappers) as well as components (c-*/f-*) — treated uniformly."""
    visited: set[str] = set()
    queue = list(dict.fromkeys(start_deps))  # de-dupe, preserve order
    order: list[str] = []
    while queue:
        dep = queue.pop(0)
        if dep in visited:
            continue
        visited.add(dep)
        order.append(dep)
        dep_dir = src_root / dep
        dep_skill_md = dep_dir / "SKILL.md"
        if not dep_dir.is_dir():
            print(f"sync-skills.py: ERROR — dependency '{dep}' not found at {dep_dir}", file=sys.stderr)
            sys.exit(1)
        dep_fm = read_frontmatter(dep_skill_md)
        for sub in dep_fm.get("dependsOn", []) or []:
            if sub not in visited:
                queue.append(sub)
    return order


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    h.update(p.read_bytes())
    return "sha256:" + h.hexdigest()


def list_files(root: Path) -> list[str]:
    out = []
    for p in sorted(root.rglob("*")):
        if p.is_file() and p.name not in IGNORE_NAMES:
            out.append(str(p.relative_to(root)).replace("\\", "/"))
    return sorted(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="private source skills repo root")
    ap.add_argument("--recipes", required=True, help="path to cfw-render's config/recipes.json (allowlist)")
    ap.add_argument("--out-dir", required=True, help="output skills/ dir")
    args = ap.parse_args()

    src_root = Path(args.src)
    out_root = Path(args.out_dir)
    out_root.mkdir(parents=True, exist_ok=True)

    recipes_config = json.loads(Path(args.recipes).read_text(encoding="utf-8"))
    allowlist = [r["name"] for r in recipes_config.get("recipes", [])]
    if not allowlist:
        print("sync-skills.py: ERROR — no recipes found in config/recipes.json", file=sys.stderr)
        sys.exit(1)

    print(f"sync-skills.py: {len(allowlist)} enabled recipe(s): {', '.join(allowlist)}")

    index = {
        "generatedAt": None,  # filled by caller-visible timestamp below
        # release/rawBase: vestigial from the retired git-subtree/fetch-mode
        # pipeline — rawBase has no reader anywhere in this repo; release is
        # read defensively by gen-skills-manifest.sh but immediately
        # discarded again by sync-skills.sh. Intentionally left null rather
        # than removed, to avoid an index.json schema change no consumer
        # asked for (CFW-318).
        "release": None,
        "sourceSha": None,  # stamped below, from CFW_SKILLS_SRC's own HEAD (CFW-318)
        "rawBase": None,
        "recipes": {},
    }
    import datetime
    index["generatedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    index["sourceSha"] = git_head_sha(src_root)

    for recipe in allowlist:
        recipe_src = src_root / recipe
        if not recipe_src.is_dir():
            print(f"sync-skills.py: ERROR — allowlisted recipe '{recipe}' not found at {recipe_src}", file=sys.stderr)
            sys.exit(1)

        recipe_dest = out_root / recipe
        copy_tree(recipe_src, recipe_dest)
        rewrite_host_path_resolvers(recipe_dest, recipe, is_nested=False)
        strip_brand_override_host_paths(recipe_dest)
        redact_literal_host_paths(recipe_dest)

        recipe_fm = read_frontmatter(recipe_src / "SKILL.md")
        start_deps = recipe_fm.get("dependsOn", []) or []
        closure = walk_closure(src_root, start_deps)

        hub_dir = recipe_dest / ".hub"
        if hub_dir.exists():
            shutil.rmtree(hub_dir)
        if closure:
            hub_dir.mkdir(parents=True, exist_ok=True)
            for dep in closure:
                copy_tree(src_root / dep, hub_dir / dep)
                rewrite_host_path_resolvers(hub_dir / dep, f"{recipe}/.hub/{dep}", is_nested=True)
                strip_brand_override_host_paths(hub_dir / dep)
                redact_literal_host_paths(hub_dir / dep)

        files = list_files(recipe_dest)
        file_hashes = {f: sha256_file(recipe_dest / f) for f in files}
        agg_src = "\n".join(f"{f}={file_hashes[f]}" for f in sorted(files))
        checksum = "sha256:" + hashlib.sha256(agg_src.encode("utf-8")).hexdigest()

        entry = next((r for r in recipes_config["recipes"] if r["name"] == recipe), {})
        index["recipes"][recipe] = {
            "version": entry.get("version", "1.0.0"),
            "checksum": checksum,
            "files": files,
            "fileHashes": file_hashes,
            "providers": entry.get("providers", []),
            "systemRequires": [],  # not sourced in this model; see report
            "vendored": closure,
        }
        print(f"  synced {recipe} ({len(files)} files, {len(closure)} vendored dep(s): {', '.join(closure) if closure else '-'})")

    index_path = out_root / "index.json"
    index_path.write_text(json.dumps(index, indent=2) + "\n", encoding="utf-8")
    print(f"sync-skills.py: wrote {index_path}")


if __name__ == "__main__":
    main()
