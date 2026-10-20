#!/usr/bin/env python3
"""
sync-skills.py — worker for scripts/sync-skills.sh.

Reads the recipe allowlist from cfw-render's own config/recipes.json, copies each
listed recipe PLUS the transitive closure of its dependsOn graph (cycle-safe)
from the private source skills repo into <out-dir>/<recipe>/ (own files) and
<out-dir>/<recipe>/.hub/<dep>/ (each dependency, flattened — not nested), then
writes <out-dir>/index.json in the shape scripts/verify-skills-bundle.sh and
scripts/gen-skills-manifest.sh expect.

Mostly a plain copy — EXCEPT for deliberate rewrites after copy_tree (before
list_files/hashing, so index.json hashes cover the rewritten bytes):

CFW-312 rewrite_host_path_resolvers() patches the source's "locate my own dir /
locate a sub-skill dir" bash idiom, which does a `find` over host install
locations ($HOME/.claude/skills or any other $HOME/.<tool>/ install root, the
source library's own absolute path). That idiom is correct for the SOURCE
library (where agent tools install skills as siblings under those host roots)
but wrong for cfw-render's vendored, runtime-free bundle, where none of those
host roots exist — it was silently resolving to "" or "/.hub/<dep>" on the
render box. The rewrite anchors "my own dir" on $CFW_RENDER_SKILLS_DIR (already
exported into the Director's env by cr_load_config) and "a sub-skill dir" on
the bundle's own .hub/<dep>/, computed and baked in as literals at sync time —
no runtime `find` needed.

WI2.38 rewrite_playwright_work_resolvers() keeps the carousel render.mjs
work-folder Playwright loader across sync.

WI2.45 apply_p_carousel_contract() re-applies slide_1..slide_10 saves,
recipeVersion 2026.10.3, and the render/captions delivery wording onto
p-carousel after every copy (upstream still ships cover/slide_sheet only).

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
#   SKILL_DIR=$(find "$HOME/.claude/skills" "$HOME/.<tool>/skills" \
#     "$HOME/.<tool>/profiles" /Users/<user>/ecosystem/harness/skills \
#     -maxdepth N -type d -name <literal-name> 2>/dev/null | head -1)
# optionally followed by a dead-on-arrival fallback line:
#   [ -n "$VAR" ] || VAR="$SKILL_DIR/.hub/<dep>"
_HOST_ROOT_ALT = (
    r'(?:"\$HOME/\.[A-Za-z0-9_-]+/(?:skills|profiles)"'
    r'|/Users/[A-Za-z0-9_.\-]+/ecosystem/harness/skills)'
)
_FIND_ASSIGN_RE = re.compile(
    r'(?P<indent>[ \t]*)(?P<var>[A-Za-z_][A-Za-z0-9_]*)=\$\(\s*find\s+'
    r'(?P<roots>(?:' + _HOST_ROOT_ALT + r'[ \t]*(?:\\\n[ \t]*)?)+)'
    r'-maxdepth\s+\d+\s+-type\s+d\s+-name\s+"?(?P<name>[A-Za-z0-9_.\-]+)"?[ \t]+'
    r'2>/dev/null[ \t]*\|[ \t]*head[ \t]+-1[ \t]*\)'
)
_HOST_COMMENT_RE = re.compile(
    r'^[ \t]*#.*(?:\$HOME/\.claude|\$HOME/\.[A-Za-z0-9_-]+/(?:skills|profiles)|/Users/[A-Za-z0-9_.\-]+/ecosystem/harness/skills).*\n?',
    re.MULTILINE,
)
# The same idiom, wrapped in a parameterized helper (scripts/verify-skill.sh):
#   _find_skill() {
#     find "$HOME/.claude/skills" "$HOME/.<tool>/skills" /Users/<user>/ecosystem/harness/skills \
#       -maxdepth N -type d -name "$1" 2>/dev/null | head -1
#   }
_FIND_SKILL_FN_RE = re.compile(
    r'(?P<indent>[ \t]*)_find_skill\(\) \{\n'
    r'[ \t]*find\s+"\$HOME/\.claude/skills"\s+"\$HOME/\.[A-Za-z0-9_-]+/skills"\s+'
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


# ---- WI2.38: load Playwright from the step work folder ----
#
# The carousel step installs Playwright into work/node_modules and runs
# `node "$SKILL_DIR/render.mjs"` from that work folder. Node resolves a static
# `import { chromium } from 'playwright'` from the script's folder, not cwd,
# so the install is invisible. The private source still has the static import;
# this rewrite keeps the work-folder loader in the bundle. No-op when the
# import block is absent (fixture recipes, and a source that already loads
# Playwright itself).
_PLAYWRIGHT_STATIC_IMPORT_RE = re.compile(
    r"import \{ chromium \} from 'playwright';\n"
    r"import \{ mkdir \} from 'node:fs/promises';\n"
    r"import \{ execFileSync \} from 'node:child_process';\n"
)
_PLAYWRIGHT_WORK_LOADER = """import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import path from 'node:path';
import { mkdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';

// Playwright is installed in the step work folder (the process cwd). A static
// import resolves from this file's folder, which has no node_modules.
async function loadPlaywrightChromium() {
  const cwd = process.cwd();
  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  const workPlace = path.join(cwd, 'node_modules', 'playwright');
  const scriptPlace = path.join(scriptDir, 'node_modules', 'playwright');

  const pick = (mod) => {
    if (mod && mod.chromium) return mod.chromium;
    if (mod && mod.default && mod.default.chromium) return mod.default.chromium;
    return null;
  };

  let resolved = '';
  try {
    resolved = createRequire(cwd + '/').resolve('playwright', { paths: [cwd] });
  } catch {
    resolved = '';
  }
  if (resolved) {
    const workRoot = path.resolve(cwd) + path.sep;
    if (path.resolve(resolved).startsWith(workRoot)) {
      try {
        const picked = pick(await import(pathToFileURL(path.resolve(resolved)).href));
        if (picked) return picked;
      } catch {
        // The copy under the work folder did not load.
      }
    }
  }
  try {
    const picked = pick(await import('playwright'));
    if (picked) return picked;
  } catch {
    // Not installed beside this file either.
  }
  console.error(`render.mjs: Cannot find package 'playwright' in ${workPlace} or ${scriptPlace}`);
  process.exit(1);
}

const chromium = await loadPlaywrightChromium();
"""


def rewrite_playwright_work_resolvers(directory: Path) -> int:
    """Replace the static Playwright import in render.mjs with the work-folder
    loader. Returns the number of files changed. Leaves every other file,
    and a render.mjs that does not have this exact import block, untouched."""
    changed = 0
    for path in sorted(directory.rglob("render.mjs")):
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, ValueError):
            continue
        new_text, n = _PLAYWRIGHT_STATIC_IMPORT_RE.subn(_PLAYWRIGHT_WORK_LOADER, text, count=1)
        if n and new_text != text:
            path.write_text(new_text, encoding="utf-8")
            changed += 1
    return changed


# ---- WI2.45: re-apply p-carousel slide-save / delivery contract after copy ----
#
# copy_tree deletes and recopies skills/<recipe>/ from the private source. The
# upstream p-carousel still declares only cover/slide_sheet image saves and
# older step wording. After every copy of p-carousel, re-apply the Render-side
# contract so slide_1..slide_10 saves, recipeVersion, and the render/captions
# delivery wording survive sync (same pattern as rewrite_playwright_work_resolvers).
P_CAROUSEL_RECIPE_VERSION = "2026.10.3"

_P_CAROUSEL_MUST_PRODUCE = """## You must produce

- `saves/slide_1.png`, `saves/slide_2.png`, `saves/slide_3.png`, `saves/slide_4.png`,
  `saves/slide_5.png`, `saves/slide_6.png`, `saves/slide_7.png`, `saves/slide_8.png`,
  `saves/slide_9.png`, `saves/slide_10.png` — the manifest declares all ten. Write the
  real slides for N = `slides.json.count` at the exact canvas in order; pad any unused
  slot (`slide_{N+1}`…`slide_10`) with a copy of the last real slide so harness
  upload/resume has every declared save. Delivery still uses only `slides.json.count`.
- `saves/cover.png` — slide 1 at the exact canvas (**preview only**; not a deliverable).
- `saves/slide_sheet.png` — every slide stacked vertically in order (canvas width × N·height),
  the owner's preview of the whole set (**preview only**; not a deliverable).
- `saves/slides.json` — `{ "width", "height", "count", "slides": [ { "n", "sha256", "bytes" } ] }`
  describing the final slide PNGs in order (the captions step and the delivery read it).
- `saves/qa_report.json` — `{ "rounds": 2, "slides": [ { "n", "verdict": "PASS", "notes": [] } ] }`;
  every verdict `PASS`.
"""

_P_CAROUSEL_WRITE_SAVES = """### 4. Write the saves

```bash
python3 - "$W" "$H" <<'PY'
import glob, hashlib, json, os, re, shutil, sys
W, H = int(sys.argv[1]), int(sys.argv[2])
MAX_SLIDES = 10  # manifest declares slide_1..slide_10 (num_slides choices max)
files = sorted(glob.glob('work/slides/slide-*.png'), key=lambda p: int(re.search(r'(\\d+)\\.png$', p).group(1)))
assert files, "no slides rendered"
assert 1 <= len(files) <= MAX_SLIDES, f"slide count {len(files)} outside 1..{MAX_SLIDES}"
os.makedirs('saves', exist_ok=True)
slides = []
for i, src in enumerate(files):
    n = i + 1
    dest = f'saves/slide_{n}.png'
    shutil.copy2(src, dest)
    slides.append({"n": n, "sha256": hashlib.sha256(open(dest,'rb').read()).hexdigest(), "bytes": os.path.getsize(dest)})
# Pad unused declared saves so the harness can upload/restore every slide_K.
last = files[-1]
for n in range(len(files) + 1, MAX_SLIDES + 1):
    shutil.copy2(last, f'saves/slide_{n}.png')
shutil.copy2(files[0], 'saves/cover.png')
json.dump({"width": W, "height": H, "count": len(files), "slides": slides}, open('saves/slides.json','w'), indent=1)
qa = json.load(open('work/qa_report.json'))
assert all(s["verdict"] == "PASS" for s in qa["slides"]) and len(qa["slides"]) == len(files), "a slide did not pass"
json.dump(qa, open('saves/qa_report.json','w'), indent=1)
print(f"[carousel] {len(files)} slides {W}x{H}, QA rounds={qa['rounds']}")
PY
convert $(ls -v work/slides/slide-*.png) -append saves/slide_sheet.png
```

`saves/slide_1.png` … `saves/slide_N.png` are the deliverables (slide order; N from
`slides.json.count`). Unused `slide_{N+1}`…`slide_10` pads exist only so the declared
manifest saves upload and restore. `cover.png` and `slide_sheet.png` are previews only —
the worker must not send them as the carousel.
"""

_P_CAROUSEL_CAPTIONS_BOUNDARY = """## Delivery boundary

This terminal stage saves captions, not the carousel images. The worker delivers
the ordered individual slides from `render_slides` (`saves/slide_1.png` …
`saves/slide_N.png` in `prior/slides.json` order) plus these captions. Do not
select the first preview, `cover.png` or `slide_sheet.png` as the carousel —
those stay previews only. Standalone delivery keeps the same rule: every passing
slide in order, then captions and the per-slide QA evidence.

"""

_P_CAROUSEL_SKILL_DELIVER = """### Step 8 — Deliver ⛔ CHECKPOINT

Deliver: individual slide PNGs in slide order (`slide_1.png` … `slide_N.png`,
cover first as slide 1) + PDF last (standalone) + `final/captions.json`. Never
send `cover.png` or `slide_sheet.png` as a deliverable — those are previews
only. Managed runs: the worker selects `steps/render_slides/saves/slide_N.png`
from `slides.json` and passes them to `cfw-render-report.sh complete` with the
captions file. Standalone:
`cfw-render-report.sh complete final/slide-1.png … final/carousel-<slug>.pdf`
(captions picked up automatically).
**Gate: User approves caption before scheduling.**
"""


def apply_p_carousel_contract(directory: Path) -> int:
    """Re-apply the p-carousel WI2.43/WI2.45 contract onto a just-copied recipe
    tree. Idempotent. Returns the number of files changed."""
    changed = 0

    man_path = directory / "manifest.json"
    if man_path.is_file():
        try:
            data = json.loads(man_path.read_text(encoding="utf-8"))
        except (UnicodeDecodeError, ValueError, json.JSONDecodeError):
            data = None
        if isinstance(data, dict):
            mutated = False
            if data.get("recipeVersion") != P_CAROUSEL_RECIPE_VERSION:
                data["recipeVersion"] = P_CAROUSEL_RECIPE_VERSION
                mutated = True
            for step in data.get("steps") or []:
                if not isinstance(step, dict) or step.get("id") != "render_slides":
                    continue
                saves = list(step.get("saves") or [])
                ids = [s.get("id") for s in saves if isinstance(s, dict)]
                want = [f"slide_{n}" for n in range(1, 11)]
                if ids[:10] != want:
                    rest = [
                        s for s in saves
                        if isinstance(s, dict) and not re.fullmatch(r"slide_\d+", str(s.get("id") or ""))
                    ]
                    step["saves"] = [
                        {"id": f"slide_{n}", "kind": "image", "preview": False}
                        for n in range(1, 11)
                    ] + rest
                    have = {s["id"] for s in step["saves"] if isinstance(s, dict)}
                    for sid, kind, preview in (
                        ("cover", "image", True),
                        ("slide_sheet", "image", True),
                        ("slides", "json", False),
                        ("qa_report", "json", False),
                    ):
                        if sid not in have:
                            step["saves"].append({"id": sid, "kind": kind, "preview": preview})
                    mutated = True
                break
            if mutated:
                man_path.write_text(
                    json.dumps(data, indent=2, ensure_ascii=False) + "\n",
                    encoding="utf-8",
                )
                changed += 1

    render_md = directory / "steps" / "03-render-slides.md"
    if render_md.is_file():
        try:
            text = render_md.read_text(encoding="utf-8")
        except (UnicodeDecodeError, ValueError):
            text = ""
        if text:
            new_text = text
            if "saves/slide_1.png" not in new_text or "pad any unused" not in new_text.lower():
                new_text, n = re.subn(
                    r"## You must produce\n.*?(?=\n## How\n)",
                    lambda _m: _P_CAROUSEL_MUST_PRODUCE,
                    new_text,
                    count=1,
                    flags=re.DOTALL,
                )
                if not n:
                    new_text = new_text.replace(
                        "## How\n",
                        _P_CAROUSEL_MUST_PRODUCE + "\n## How\n",
                        1,
                    )
            if "MAX_SLIDES = 10" not in new_text or "Pad unused declared saves" not in new_text:
                # Use a callable replacement: the write-saves body contains
                # Python regex literals (\d) that re.sub would mis-parse as
                # template escapes if passed as a plain string.
                new_text, n = re.subn(
                    r"### 4\. Write the saves\n.*?(?=\nKeep `work/qa_report\.json`|\n## If you cannot proceed\n)",
                    lambda _m: _P_CAROUSEL_WRITE_SAVES + "\n",
                    new_text,
                    count=1,
                    flags=re.DOTALL,
                )
                if not n and "### 4. Write the saves" not in new_text:
                    anchor = "\n## If you cannot proceed\n"
                    if anchor in new_text:
                        new_text = new_text.replace(
                            anchor,
                            "\n" + _P_CAROUSEL_WRITE_SAVES + "\n" + anchor,
                            1,
                        )
            if new_text != text:
                render_md.write_text(new_text, encoding="utf-8")
                changed += 1

    captions_md = directory / "steps" / "04-captions.md"
    if captions_md.is_file():
        try:
            text = captions_md.read_text(encoding="utf-8")
        except (UnicodeDecodeError, ValueError):
            text = ""
        if text and ("## Delivery boundary" not in text or "saves/slide_1.png" not in text):
            new_text = text
            if "## Delivery boundary" in new_text:
                new_text, _ = re.subn(
                    r"## Delivery boundary\n.*?(?=\n## You receive\n)",
                    lambda _m: _P_CAROUSEL_CAPTIONS_BOUNDARY,
                    new_text,
                    count=1,
                    flags=re.DOTALL,
                )
            elif "## You receive\n" in new_text:
                new_text = new_text.replace(
                    "## You receive\n",
                    _P_CAROUSEL_CAPTIONS_BOUNDARY + "## You receive\n",
                    1,
                )
            else:
                # Insert after the opening paragraphs.
                parts = new_text.split("\n\n", 1)
                if len(parts) == 2:
                    new_text = parts[0] + "\n\n" + _P_CAROUSEL_CAPTIONS_BOUNDARY + parts[1]
                else:
                    new_text = new_text.rstrip() + "\n\n" + _P_CAROUSEL_CAPTIONS_BOUNDARY
            if new_text != text:
                captions_md.write_text(new_text, encoding="utf-8")
                changed += 1

    skill_md = directory / "SKILL.md"
    if skill_md.is_file():
        try:
            text = skill_md.read_text(encoding="utf-8")
        except (UnicodeDecodeError, ValueError):
            text = ""
        if text and (
            "Never\nsend `cover.png`" not in text
            and "Never send `cover.png`" not in text
        ):
            new_text, n = re.subn(
                r"### Step 8 — Deliver ⛔ CHECKPOINT\n.*?(?=\n## Self-Improvement Feedback Loop\n)",
                lambda _m: _P_CAROUSEL_SKILL_DELIVER + "\n",
                text,
                count=1,
                flags=re.DOTALL,
            )
            if n and new_text != text:
                skill_md.write_text(new_text, encoding="utf-8")
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
        rewrite_playwright_work_resolvers(recipe_dest)
        strip_brand_override_host_paths(recipe_dest)
        redact_literal_host_paths(recipe_dest)
        # WI2.45: p-carousel contract must survive the delete+recopy. Apply after
        # the generic rewrites so hashes cover the contracted bytes.
        if recipe == "p-carousel":
            apply_p_carousel_contract(recipe_dest)

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
                rewrite_playwright_work_resolvers(hub_dir / dep)
                strip_brand_override_host_paths(hub_dir / dep)
                redact_literal_host_paths(hub_dir / dep)

        files = list_files(recipe_dest)
        file_hashes = {f: sha256_file(recipe_dest / f) for f in files}
        agg_src = "\n".join(f"{f}={file_hashes[f]}" for f in sorted(files))
        checksum = "sha256:" + hashlib.sha256(agg_src.encode("utf-8")).hexdigest()

        entry = next((r for r in recipes_config["recipes"] if r["name"] == recipe), {})
        # Keep the bundled p-carousel pin at the contracted recipeVersion so a
        # full sync does not drop WI2.45's 2026.10.3 back to recipes.json 1.0.0.
        version = (
            P_CAROUSEL_RECIPE_VERSION
            if recipe == "p-carousel"
            else entry.get("version", "1.0.0")
        )
        index["recipes"][recipe] = {
            "version": version,
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
