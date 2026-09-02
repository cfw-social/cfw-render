#!/usr/bin/env python3
"""
sync-skills.py — worker for scripts/sync-skills.sh.

Reads the recipe allowlist from cfw-render's own config/recipes.json, copies each
listed recipe PLUS the transitive closure of its dependsOn graph (cycle-safe)
from the private source skills repo into <out-dir>/<recipe>/ (own files) and
<out-dir>/<recipe>/.hub/<dep>/ (each dependency, flattened — not nested), then
writes <out-dir>/index.json in the shape scripts/verify-skills-bundle.sh and
scripts/gen-skills-manifest.sh expect.

Plain copy — no body rewriting, no path rewriting. The source SKILL.md/script
bodies already reference `.hub/<dep>/...`-relative paths directly.

No third-party deps — stdlib only (json, re, hashlib, shutil, pathlib).
"""
import argparse
import hashlib
import json
import re
import shutil
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
        "release": None,
        "sourceSha": None,
        "rawBase": None,
        "recipes": {},
    }
    import datetime
    index["generatedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    for recipe in allowlist:
        recipe_src = src_root / recipe
        if not recipe_src.is_dir():
            print(f"sync-skills.py: ERROR — allowlisted recipe '{recipe}' not found at {recipe_src}", file=sys.stderr)
            sys.exit(1)

        recipe_dest = out_root / recipe
        copy_tree(recipe_src, recipe_dest)

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
