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

WI2.64 apply_p_reels_pip_tail() re-applies the pip tail hold and the CTA
caption clamp onto p-reels-pip and p-reels-pip-heygen after every copy,
including the heygen .hub copy of p-reels-pip. Upstream still overlays the
CTA card with itsoffset and burns captions across that window.

WI2.68 apply_whisper_small_mlx() rewrites the missing HF model id
mlx-community/whisper-small to mlx-community/whisper-small-mlx in every
p-reels-* recipe after every copy, including .hub copies. Idempotent: an
already-correct id is left alone.

WI2.71 apply_reel_fill_frame() crops a matched pair of flat bars baked into
the face clip (top+bottom or left+right, same size and colour, leaving ~16:9 or
~9:16; anything else is not cropped) and makes the pip card scale-to-fill + a
top-biased crop instead of scale-to-fit + pad, on the top-level spotlight/pip
steps and SKILL.md (not .hub copies).

WI2.72 apply_reel_script_align() passes the known script to mlx_whisper as
--initial-prompt and corrects mis-heard transcript words against it (difflib
alignment, timings kept) in the top-level transcribe step of the four reel
recipes. No script -> the transcript is left unchanged. WI2.77: the prompt is passed
through an explicit if branch (two arguments in bash, sh and zsh), and a script phrase
shorter than what was heard becomes one caption over the whole heard time. The
transform upgrades the WI2.72 text in place.

WI2.76 apply_reel_caption_phrases() writes work/caption_phrases.py into the
top-level caption-planning step of the four reel recipes (spotlight 03-plan-edit,
pip 05-composite): it regroups caption_groups so no group ends on a preposition,
article, conjunction or auxiliary and no 1-2 word mid-clause fragment is left
(timings kept), and the plan guard fails on a split phrase.

WI2.78 (same transform): repair mode always fixes adjacent equal styles, a
group overlap and a second emphasis word, also on a plan that was already
whole; "her"/"his" join the next word; a group with no words is a clear error;
the pip step runs the repair as a command between P1 and P2 and skips the
repair and the check when CAPTIONS=off; and the pip c-reel-premium P1 prompt
states the same grouping rule.

WI2.79 (same transform): both helper modes refuse a group whose end is not
after its start or whose start is not after the previous start (the overlap
clamp no longer hides an out-of-order plan); a missing plan, bad JSON or a group
without start/end is a clear message, not a traceback; and the pip P1 note
replaces the WI2.64 "run P1 → P4 here" line (its inverse gives that line back).

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


# WI2.64: exact slices of skills/p-reels-pip/steps/05-composite.md. Raw strings
# so ffmpeg continuations and the embedded Python `\n` escapes stay literal.
_PIP_TAIL_PROSE_OLD = """`shortest=1` on the head overlay only — the static frame overlay keeps `eof_action=repeat`.

```bash
"""
_PIP_TAIL_PROSE_NEW = """`shortest=1` on the head overlay only — the static frame overlay keeps `eof_action=repeat`.
That shortest cut can end the picture before the bed audio; the hold below clones the last
real frame across the gap so the tail is not black. A CTA mov that runs past the bed does
the same if it is not trimmed — the overlay cap below stops at the bed.

```bash
"""
_PIP_TAIL_COMPOSE_OLD = "work/composed.mp4\nfi\n"
_PIP_TAIL_COMPOSE_NEW = r"""work/composed.mp4
fi
# WI2.64: hold the last real frame out to the bed, and stop captions at the CTA window.
cat > work/hold_tail.py <<'PY'
import json, os, re, subprocess, sys

FLOOR = 16.0
OUT_FPS = 30.0

def run(args):
    return subprocess.run(args, capture_output=True, text=True)

def probe(path):
    p = run(["ffprobe", "-v", "error", "-show_entries",
             "format=duration:stream=codec_type,duration,nb_frames,r_frame_rate",
             "-of", "json", path])
    if p.returncode != 0:
        sys.stderr.write("hold_tail: ffprobe failed\n")
        return None
    data = json.loads(p.stdout or "{}")
    fmt = float((data.get("format") or {}).get("duration") or 0)
    vid = None
    fps = OUT_FPS
    for st in data.get("streams") or []:
        if st.get("codec_type") != "video":
            continue
        rate = str(st.get("r_frame_rate") or "30/1")
        if "/" in rate:
            n, d = rate.split("/", 1)
            df = float(d) if d else 0.0
            fps = (float(n) / df) if df else OUT_FPS
        else:
            fps = float(rate or OUT_FPS)
        if fps <= 0:
            fps = OUT_FPS
        dur = st.get("duration")
        nb = st.get("nb_frames")
        if dur not in (None, "N/A", ""):
            vid = float(dur)
        elif nb not in (None, "N/A", ""):
            vid = float(nb) / fps
        break
    if vid is None:
        c = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_packets",
                 "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", path])
        n = (c.stdout or "").strip()
        vid = (int(n) / fps) if n.isdigit() else fmt
    return fmt, vid, fps

def yavgs(path, start):
    cmd = ["ffmpeg", "-hide_banner", "-nostats"]
    if start is not None and start > 0:
        cmd += ["-ss", "%.3f" % start]
    cmd += ["-i", path, "-vf", "signalstats,metadata=print:key=lavfi.signalstats.YAVG",
            "-an", "-f", "null", "-"]
    p = run(cmd)
    blob = (p.stderr or "") + "\n" + (p.stdout or "")
    return [float(v) for v in re.findall(r"lavfi\.signalstats\.YAVG=([0-9.]+)", blob)]

def trailing(samples):
    n = 0
    for v in reversed(samples):
        if v <= FLOOR:
            n += 1
        else:
            break
    return n

def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: hold_tail.py VIDEO [TARGET_SECONDS]\n")
        return 2
    path = sys.argv[1]
    if not os.path.isfile(path):
        sys.stderr.write("hold_tail: missing %s\n" % path)
        return 1
    target = None
    if len(sys.argv) > 2 and sys.argv[2] not in ("", "none"):
        target = float(sys.argv[2])
    probed = probe(path)
    if not probed:
        return 1
    fmt, vid, fps = probed
    if target is None:
        target = fmt
    if target <= 0 or vid <= 0:
        sys.stderr.write("hold_tail: bad duration\n")
        return 1
    samples = yavgs(path, max(0.0, vid - 3.0))
    if not samples:
        samples = yavgs(path, None)
    if not samples:
        sys.stderr.write("hold_tail: no YAVG samples\n")
        return 1
    trail = trailing(samples)
    if trail == len(samples):
        full = yavgs(path, None)
        if not full or trailing(full) == len(full):
            sys.stderr.write("hold_tail: entire video is black\n")
            return 1
        samples = full
        trail = trailing(samples)
    picture_end = vid - (trail / fps)
    if trail > 0:
        picture_end -= 0.5 / fps
    frame = 1.0 / fps
    # A short video stream must not no-op just because the container matches the bed.
    if trail == 0 and abs(vid - target) <= frame + 1e-3 and abs(fmt - target) <= frame + 1e-3:
        print("hold_tail: no-op %s picture=%.3f target=%.3f" % (path, picture_end, target))
        return 0
    out_frames = max(1, int(round(target * OUT_FPS)))
    keep = int(picture_end * OUT_FPS)
    if keep < 1:
        keep = 1
    if keep > out_frames:
        keep = out_frames
    good_end = keep / OUT_FPS
    gap = (out_frames - keep) / OUT_FPS
    out = path + ".hold.mp4"
    fc = (
        "[0:v]trim=start=0:end=%.6f,setpts=PTS-STARTPTS,fps=30,"
        "tpad=stop_mode=clone:stop_duration=%.6f,format=yuv420p[v]"
        % (good_end, gap)
    )
    # Copy the bed audio. Re-encoding it would move the sealed -14 LUFS level.
    p = run([
        "ffmpeg", "-y", "-i", path, "-filter_complex", fc,
        "-map", "[v]", "-map", "0:a",
        "-c:v", "libx264", "-preset", "medium", "-crf", "19", "-pix_fmt", "yuv420p",
        "-c:a", "copy", "-t", "%.6f" % (out_frames / OUT_FPS), "-movflags", "+faststart", out,
    ])
    if p.returncode != 0 or not os.path.isfile(out):
        err = ((p.stderr or "")[-400:]).replace("\n", " | ")
        sys.stderr.write("hold_tail: encode failed: %s\n" % err)
        if os.path.isfile(out):
            os.remove(out)
        return 1
    last = yavgs(out, max(0.0, (out_frames / OUT_FPS) - 0.5))
    if not last or last[-1] <= FLOOR:
        got = last[-1] if last else None
        sys.stderr.write("hold_tail: last frame still black (%s)\n" % got)
        os.remove(out)
        return 1
    os.replace(out, path)
    print("hold_tail: held %s to %.3fs (keep %.3f gap %.3f)" % (path, out_frames / OUT_FPS, good_end, gap))
    return 0

if __name__ == "__main__":
    sys.exit(main())
PY
cat > work/clamp_captions.py <<'PY'
import json, os, sys

EPS = 1e-3

def limit_of():
    path = os.environ.get("CTA_WINDOW") or "work/cta-window.json"
    if not os.path.exists(path):
        return None
    data = json.load(open(path))
    if not isinstance(data, dict):
        return None
    start = data.get("cta_start")
    if start is None:
        return None
    return float(start)

def start_of(row):
    if isinstance(row, dict) and "start" in row:
        return float(row["start"])
    if isinstance(row, dict) and "s" in row:
        return float(row["s"])
    return None

def end_of(row):
    if isinstance(row, dict) and "end" in row:
        return float(row["end"])
    if isinstance(row, dict) and "e" in row:
        return float(row["e"])
    return None

def clamp_row(row, limit):
    s = start_of(row)
    if s is not None and s >= limit - EPS:
        return None
    e = end_of(row)
    if e is not None and e > limit:
        if "end" in row:
            row["end"] = limit
        if "e" in row:
            row["e"] = limit
    return row

def overlaps(row, limit):
    s = start_of(row)
    e = end_of(row)
    if s is not None and s >= limit - EPS:
        return True
    if e is not None and e > limit + 1e-6:
        return True
    return False

def dump(path, obj):
    with open(path, "w") as fh:
        json.dump(obj, fh)
        fh.write("\n")

def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: clamp_captions.py words SRC DEST | plan PLAN\n")
        return 2
    mode = sys.argv[1]
    limit = limit_of()
    if mode == "words":
        if len(sys.argv) != 4:
            sys.stderr.write("usage: clamp_captions.py words SRC DEST\n")
            return 2
        src, dest = sys.argv[2], sys.argv[3]
        data = json.load(open(src))
        words = data["words"] if isinstance(data, dict) and "words" in data else data
        if not isinstance(words, list):
            sys.stderr.write("clamp_captions: words payload is not a list\n")
            return 1
        out = []
        for w in words:
            if limit is None or not isinstance(w, dict):
                out.append(w)
                continue
            c = clamp_row(dict(w), limit)
            if c is not None:
                out.append(c)
        if limit is not None:
            for w in out:
                if isinstance(w, dict) and overlaps(w, limit):
                    sys.stderr.write("clamp_captions: word still overlaps the CTA window\n")
                    return 1
        dump(dest, out)
        return 0
    if mode == "plan":
        plan_path = sys.argv[2]
        if not os.path.exists(plan_path):
            return 0
        plan = json.load(open(plan_path))
        if limit is not None and isinstance(plan, dict) and isinstance(plan.get("caption_groups"), list):
            kept = []
            for g in plan["caption_groups"]:
                if not isinstance(g, dict):
                    kept.append(g)
                    continue
                gs = start_of(g)
                if gs is not None and gs >= limit - EPS:
                    continue
                g = dict(g)
                words = g.get("words")
                if isinstance(words, list):
                    nw = []
                    for w in words:
                        if not isinstance(w, dict):
                            nw.append(w)
                            continue
                        c = clamp_row(dict(w), limit)
                        if c is not None:
                            nw.append(c)
                    g["words"] = nw
                    if not nw:
                        continue
                ge = end_of(g)
                if ge is not None and ge > limit:
                    if "end" in g:
                        g["end"] = limit
                    if "e" in g:
                        g["e"] = limit
                kept.append(g)
            plan["caption_groups"] = kept
            for g in kept:
                if not isinstance(g, dict):
                    continue
                if overlaps(g, limit):
                    sys.stderr.write("clamp_captions: caption group still overlaps the CTA window\n")
                    return 1
                for w in g.get("words") or []:
                    if isinstance(w, dict) and overlaps(w, limit):
                        sys.stderr.write("clamp_captions: plan word still overlaps the CTA window\n")
                        return 1
        if isinstance(plan, (dict, list)):
            dump(plan_path, plan)
        return 0
    sys.stderr.write("clamp_captions: unknown mode %s\n" % mode)
    return 2

if __name__ == "__main__":
    sys.exit(main())
PY
python3 work/hold_tail.py work/composed.mp4 "$BED_DUR" || exit 1
"""
_PIP_TAIL_CTA_OLD = r"""  CTA_START=$(python3 -c "print(round(${BED_DUR} - ${CTA_DURATION}, 3))")
  ffmpeg -y -i work/composed.mp4 -itsoffset "$CTA_START" -i work/cta-card.mov \
    -filter_complex "[0:v][1:v]overlay=enable='between(t,${CTA_START},${BED_DUR})':eof_action=pass[v]" \
    -map "[v]" -map 0:a -c:v libx264 -pix_fmt yuv420p -c:a copy -movflags +faststart work/with-cta.mp4
  # Scrim proof: the bottom 55 % of the last frame must be more than one flat colour.
  ffmpeg -y -v error -ss "$(python3 -c "print(max(0.0, ${BED_DUR} - 0.5))")" -i work/with-cta.mp4 -frames:v 1 work/cta-proof.png
  N=$(ffmpeg -v error -i work/cta-proof.png -vf "crop=iw:ih*0.55:0:ih*0.45" -f rawvideo -pix_fmt rgb24 - | python3 -c "import sys; b=sys.stdin.buffer.read(); print(len({b[i:i+3] for i in range(0,len(b),3)}))")
  [ "${N:-0}" -gt 1 ] || { echo "CTA scrim shipped opaque"; exit 1; }
else
  cp work/composed.mp4 work/with-cta.mp4
fi
"""
_PIP_TAIL_CTA_NEW = r"""  BED_DUR=${BED_DUR:-$(ffprobe -v error -show_entries format=duration -of csv=p=0 prior/voice_track.mp4)}
  python3 work/hold_tail.py work/composed.mp4 "$BED_DUR" || exit 1
  CTA_START=$(python3 -c "print(max(0.0, round(${BED_DUR} - ${CTA_DURATION}, 3)))")
  python3 -c 'import json,sys; json.dump({"cta_start": float(sys.argv[1]), "bed_dur": float(sys.argv[2])}, open("work/cta-window.json","w"))' "$CTA_START" "$BED_DUR"
  # WI2.64 CTA overlay: trim the card to the window, delay it, stop at the bed.
  ffmpeg -y -i work/composed.mp4 -i work/cta-card.mov \
    -filter_complex "[1:v]trim=duration=${CTA_DURATION},setpts=PTS-STARTPTS+${CTA_START}/TB[cta];[0:v][cta]overlay=enable='between(t,${CTA_START},${BED_DUR})':eof_action=pass[v]" \
    -map "[v]" -map 0:a -c:v libx264 -pix_fmt yuv420p -c:a copy -t "$BED_DUR" -movflags +faststart work/with-cta.mp4
  python3 work/hold_tail.py work/with-cta.mp4 "$BED_DUR" || exit 1
  # Scrim proof: the bottom 55 % of the last frame must be more than one flat colour.
  ffmpeg -y -v error -ss "$(python3 -c "print(max(0.0, ${BED_DUR} - 0.5))")" -i work/with-cta.mp4 -frames:v 1 work/cta-proof.png
  N=$(ffmpeg -v error -i work/cta-proof.png -vf "crop=iw:ih*0.55:0:ih*0.45" -f rawvideo -pix_fmt rgb24 - | python3 -c "import sys; b=sys.stdin.buffer.read(); print(len({b[i:i+3] for i in range(0,len(b),3)}))")
  [ "${N:-0}" -gt 1 ] || { echo "CTA scrim shipped opaque"; exit 1; }
else
  BED_DUR=${BED_DUR:-$(ffprobe -v error -show_entries format=duration -of csv=p=0 prior/voice_track.mp4)}
  python3 work/hold_tail.py work/composed.mp4 "$BED_DUR" || exit 1
  python3 -c 'import json,sys; json.dump({"cta_start": None, "bed_dur": float(sys.argv[1])}, open("work/cta-window.json","w"))' "$BED_DUR"
  cp work/composed.mp4 work/with-cta.mp4
fi
"""
_PIP_TAIL_OUTRO_OLD = "  cp work/with-cta.mp4 work/pre-premium.mp4\nfi\n"
_PIP_TAIL_OUTRO_NEW = "  cp work/with-cta.mp4 work/pre-premium.mp4\nfi\npython3 work/hold_tail.py work/pre-premium.mp4 || exit 1\n"
_PIP_TAIL_WORDS_OLD = "python3 -c \"import json; json.dump(json.load(open('prior/transcripts.json'))['words'], open('work/words.json','w'))\"\n"
_PIP_TAIL_WORDS_NEW = "# WI2.64: drop caption cues that would sit on the CTA card. Card off leaves the words unchanged.\npython3 work/clamp_captions.py words prior/transcripts.json work/words.json || exit 1\n"
_PIP_TAIL_PLAN_OLD = """# run P1 → P4 here; GSAP for the premium comp: cp \"$GSAP\" \"$PW/comp/gsap.min.js\" \"$PW/comp/compositions/\"
python3 - <<'PY'
import os
assert os.path.getsize(\"work/polished.mp4\") > 100_000, \"premium output missing/empty — the pass did not run\"
PY
"""
_PIP_TAIL_PLAN_NEW = """# run P1 → P4 here; GSAP for the premium comp: cp \"$GSAP\" \"$PW/comp/gsap.min.js\" \"$PW/comp/compositions/\"
python3 work/clamp_captions.py plan work/premium/plan.json || exit 1
python3 - <<'PY'
import os
assert os.path.getsize(\"work/polished.mp4\") > 100_000, \"premium output missing/empty — the pass did not run\"
PY
"""
_PIP_TAIL_SAVE_OLD = r"""cp work/polished.mp4 saves/assembled_video.mp4
python3 - <<'PY'
import os, subprocess
d = lambda f: float(subprocess.run(['ffprobe','-v','error','-show_entries','format=duration','-of','csv=p=0',f],capture_output=True,text=True).stdout)
a, b = d('saves/assembled_video.mp4'), d('prior/voice_track.mp4')
if os.path.exists('work/outro-norm.mp4'): b += d('work/outro-norm.mp4')
assert abs(a-b) < 0.15, f'duration drifted {a:.2f} vs expected {b:.2f}'; print(f'assembled OK {a:.2f}s')
PY
"""
_PIP_TAIL_SAVE_NEW = r"""python3 work/clamp_captions.py plan work/premium/plan.json || exit 1
python3 work/hold_tail.py work/polished.mp4 || exit 1
cp work/polished.mp4 saves/assembled_video.mp4
python3 - <<'PY'
import json, os, subprocess
d = lambda f: float(subprocess.run(['ffprobe','-v','error','-show_entries','format=duration','-of','csv=p=0',f],capture_output=True,text=True).stdout)
a, b = d('saves/assembled_video.mp4'), d('prior/voice_track.mp4')
if os.path.exists('work/outro-norm.mp4'): b += d('work/outro-norm.mp4')
assert abs(a-b) < 0.15, f'duration drifted {a:.2f} vs expected {b:.2f}'
win = json.load(open('work/cta-window.json')) if os.path.exists('work/cta-window.json') else {}
limit = win.get('cta_start')
if limit is not None:
    limit = float(limit)
    bad = []
    def cue_bad(row):
        if not isinstance(row, dict):
            return
        s = row.get('start', row.get('s'))
        e = row.get('end', row.get('e'))
        if s is not None and float(s) >= limit - 1e-3:
            bad.append('start %s' % s)
        if e is not None and float(e) > limit + 1e-6:
            bad.append('end %s' % e)
    words = []
    if os.path.exists('work/words.json'):
        words = json.load(open('work/words.json'))
        if isinstance(words, dict):
            words = words.get('words') or []
    for w in words or []:
        cue_bad(w)
    plan_path = 'work/premium/plan.json'
    if os.path.exists(plan_path):
        plan = json.load(open(plan_path))
        groups = plan.get('caption_groups') if isinstance(plan, dict) else []
        for g in groups or []:
            cue_bad(g)
            if isinstance(g, dict):
                for w in g.get('words') or []:
                    cue_bad(w)
    assert not bad, 'caption cue overlaps CTA window: ' + ', '.join(bad)
print(f'assembled OK {a:.2f}s')
PY
"""

P_REELS_PIP_TAIL_PAIRS = (
    (_PIP_TAIL_PROSE_OLD, _PIP_TAIL_PROSE_NEW),
    (_PIP_TAIL_COMPOSE_OLD, _PIP_TAIL_COMPOSE_NEW),
    (_PIP_TAIL_CTA_OLD, _PIP_TAIL_CTA_NEW),
    (_PIP_TAIL_OUTRO_OLD, _PIP_TAIL_OUTRO_NEW),
    (_PIP_TAIL_WORDS_OLD, _PIP_TAIL_WORDS_NEW),
    (_PIP_TAIL_PLAN_OLD, _PIP_TAIL_PLAN_NEW),
    (_PIP_TAIL_SAVE_OLD, _PIP_TAIL_SAVE_NEW),
)

P_REELS_PIP_TAIL_FILES = (
    "steps/05-composite.md",
    ".hub/p-reels-pip/steps/05-composite.md",
)


def apply_p_reels_pip_tail(directory: Path) -> int:
    """Re-apply the WI2.64 pip tail hold and CTA caption clamp. Idempotent.
    Returns the number of files changed. A heygen hub copy is updated when present."""
    changed = 0
    for rel in P_REELS_PIP_TAIL_FILES:
        path = directory / rel
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, ValueError):
            continue
        new = text
        for old, repl in P_REELS_PIP_TAIL_PAIRS:
            if old in new and repl not in new:
                new = new.replace(old, repl, 1)
        if new != text:
            path.write_text(new, encoding="utf-8")
            changed += 1
    return changed


# WI2.68: HF repo mlx-community/whisper-small does not exist (401). The
# published MLX build is mlx-community/whisper-small-mlx. Negative lookbehind
# keeps an already-correct id untouched (idempotent).
WHISPER_SMALL_BAD = "mlx-community/whisper-small"
WHISPER_SMALL_GOOD = "mlx-community/whisper-small-mlx"
_WHISPER_SMALL_RE = re.compile(r"mlx-community/whisper-small(?!-mlx)")


def rewrite_whisper_small_mlx(text: str) -> str:
    """Rewrite the missing whisper-small model id. Idempotent on already-good text."""
    return _WHISPER_SMALL_RE.sub(WHISPER_SMALL_GOOD, text)


def apply_whisper_small_mlx(directory: Path) -> int:
    """Rewrite mlx-community/whisper-small -> whisper-small-mlx under directory.
    Walks every text file (including .hub/). Idempotent. Returns files changed."""
    changed = 0
    if not directory.is_dir():
        return 0
    for path in sorted(directory.rglob("*")):
        if not path.is_file() or path.name in IGNORE_NAMES:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, ValueError):
            continue
        new = rewrite_whisper_small_mlx(text)
        if new != text:
            path.write_text(new, encoding="utf-8")
            changed += 1
    return changed


# WI2.71: reel face clips (HeyGen renders) arrive as 1080x1920 with a 16:9 picture
# baked between flat light/mint bars. The old side-band check never looked at the
# top/bottom, and the pip card used scale-to-fit + pad, so the bars stayed on screen.
# These transforms crop a MATCHED bar pair only (top+bottom or left+right, same size,
# same flat colour, leaving ~16:9 or ~9:16), then fill the frame / pip card. A speaker
# on a plain backdrop is never cropped, and the pip card crop keeps the top (the head).
_REEL_BARS_PY = r"""# WI2.71: find a matched pair of flat bars baked into the clip and print an ffmpeg crop.
# Crops only top+bottom (or left+right) bars of about the same size and the same flat
# colour, and only when what is left is within 5% of 16:9 or 9:16. Anything else: no crop.
import subprocess, sys
SRC, TOL, MIN_BAR, ASPECT_TOL, SEAM, SEAM_TOL = sys.argv[1], 12, 8, 0.05, 6, 32
def grab(t):
    # One frame as PPM. Its header gives the size ffmpeg shows after autorotation, so a
    # rotated phone clip is measured on the same axes the later -vf crop sees.
    out = subprocess.run(["ffmpeg", "-v", "error", "-ss", "%.2f" % t, "-i", SRC, "-frames:v", "1",
        "-f", "image2pipe", "-c:v", "ppm", "-"], capture_output=True, check=True).stdout
    if not out.startswith(b"P6"):
        return None
    head, pos = [], 2
    while len(head) < 3:
        while out[pos:pos + 1].isspace():
            pos += 1
        end = pos
        while out[end:end + 1] and not out[end:end + 1].isspace():
            end += 1
        head.append(int(out[pos:end])); pos = end
    w, h, data = head[0], head[1], out[pos + 1:]
    return (w, h, data) if len(data) >= w * h * 3 else None
def duration():
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", SRC],
        capture_output=True, text=True, check=True).stdout.strip()
    try:
        return float(r)
    except ValueError:
        return 1.0
def close(a, b, tol=TOL):
    return max(abs(a[k] - b[k]) for k in range(3)) <= tol
def run(fr, w, lines, pts, tol=TOL):
    # how many lines from this edge inwards are one flat colour -> (count, colour)
    ref, n = None, 0
    for ln in lines:
        row = [fr[(y * w + x) * 3:(y * w + x) * 3 + 3] for x, y in pts(ln)]
        ref = ref or sorted(row)[len(row) // 2]    # median pixel: robust to a noisy first pixel
        if not all(close(c, ref, tol) for c in row):
            break
        n += 1
    return n, ref
def bar(fr, w, lines, pts):
    # WI2.75: a bar run also swallows ONE short flat seam (SEAM rows or fewer, another flat
    # colour, within SEAM_TOL because video compression speckles it) right next to its inner edge, so no flat seam row stays at the picture's edge.
    lines = list(lines)
    n, ref = run(fr, w, lines, pts)
    if n >= MIN_BAR:
        m, _ = run(fr, w, lines[n:], pts, SEAM_TOL)   # a compressed seam is a bit noisy
        if 1 <= m <= SEAM and n + m < len(lines):
            n += m
    return n, ref
D = duration()
frames = [f for f in (grab(D * p) for p in (0.2, 0.5, 0.8)) if f]
if not frames or len({(f[0], f[1]) for f in frames}) != 1:
    print(""); sys.exit(0)
W, H = frames[0][0], frames[0][1]
sides = [(bar(fr, W, range(H // 2), lambda y: [(x, y) for x in range(0, W, 4)]),
          bar(fr, W, range(H - 1, H // 2, -1), lambda y: [(x, y) for x in range(0, W, 4)]),
          bar(fr, W, range(W // 2), lambda x: [(x, y) for y in range(0, H, 4)]),
          bar(fr, W, range(W - 1, W // 2, -1), lambda x: [(x, y) for y in range(0, H, 4)]))
         for _, _, fr in frames]
def edge(i):
    # bar size = the smallest run over the sampled frames; its colour must hold in every frame
    n, cols = min(s[i][0] for s in sides), [s[i][1] for s in sides]
    if n < MIN_BAR or not all(close(c, cols[0]) for c in cols):
        return 0, None
    return n, cols[0]
(top, ct), (bot, cb), (left, cl), (right, cr) = (edge(i) for i in range(4))
def pair(a, ca, b, cb_, side):
    # a matched pair: both bars present, the same flat colour, sizes within 2% of the side
    return bool(a and b and close(ca, cb_) and abs(a - b) <= max(4, side * 0.02))
def aspect_ok(w, h):
    return any(abs((w / h) / r - 1) <= ASPECT_TOL for r in (16 / 9, 9 / 16))
tb, lr = pair(top, ct, bot, cb, H), pair(left, cl, right, cr, W)
cands = ([(top, bot, left, right)] if tb and lr else []) + ([(top, bot, 0, 0)] if tb else []) \
    + ([(0, 0, left, right)] if lr else [])
for t, b, l, r in cands:
    t, l = t + t % 2, l + l % 2          # even x/y (yuv420p); never keeps a bar row
    cw, ch = W - l - r, H - t - b
    cw, ch = cw - cw % 2, ch - ch % 2    # even w/h
    if cw >= W // 4 and ch >= H // 4 and aspect_ok(cw, ch):
        print("crop=%d:%d:%d:%d," % (cw, ch, l, t)); sys.exit(0)
print("")
"""
_REEL_BARS_WRITE = "cat > work/bars.py <<'PY'\n" + _REEL_BARS_PY + "PY\n"
_REEL_BARS_WRITE_W = "cat > \"$W/bars.py\" <<'PY'\n" + _REEL_BARS_PY + "PY\n"
_REEL_BARS_PROSE = (
    "Reused HeyGen / studio renders often carry a 16:9 picture baked between two flat bars (white,\n"
    "cream or mint) at the top and bottom, or a 9:16 picture between two side bars. WI2.71: the\n"
    "`bars.py` helper samples three frames and prints `crop=W:H:X:Y,` only for a **matched pair** —\n"
    "top+bottom (or left+right) bars of about the same size and the same flat colour that leave a\n"
    "picture within 5 % of 16:9 or 9:16. Anything else (a speaker on a plain backdrop, a one-sided\n"
    "margin) prints nothing and nothing is cropped, so the head is never cut. It measures frames the\n"
    "way ffmpeg shows them (rotation applied), so a rotated phone clip is read on the right axes.\n"
    "WI2.75: a flat seam of 6 rows or fewer (another flat colour) right beside a bar counts as part\n"
    "of that bar, so no grey line is left at the picture's edge; a band of 7 rows or more is kept.\n"
)
_SPOT_BARS_NEW = (
    "### 2. Detect & crop a baked-in bar pair (BEFORE anything else)\n\n" + _REEL_BARS_PROSE + "\n"
    "```bash\n" + _REEL_BARS_WRITE +
    "CROP=$(python3 work/bars.py \"$AVATAR\") || exit 1\n"
    "echo \"[spotlight] bar crop: '${CROP:-none}'\"\n"
    "AVATAR_CLEAN=\"$AVATAR\"\n"
    "```\n"
)
_SPOT_BARS_RE = re.compile(
    r"### 2\. Detect & crop white side bands \(BEFORE anything else\)\n.*?  AVATAR_CLEAN=\"\$AVATAR\"\nfi\n```\n",
    re.S)
_SPOT_FILL_PAIRS = (
    ('  -vf "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30" \\\n',
     '  -vf "${CROP}scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1,fps=30" \\\n'),
    ("`avatar_layout: letterbox` → replace the `-vf` with\n`scale=1080:-2,",
     "`avatar_layout: letterbox` → replace the `-vf` with\n`${CROP}scale=1080:-2,"),
)
_SPOT_SKILL_BARS_NEW = (
    "### Step 1.5 — Detect & crop a baked-in bar pair (BEFORE anything else)\n\n" + _REEL_BARS_PROSE + "\n"
    "```bash\n" + _REEL_BARS_WRITE_W +
    "CROP=$(python3 \"$W/bars.py\" \"$AVATAR\") || exit 1\n"
    "echo \"[p-reels-spotlight] bar crop: '${CROP:-none}'\"\n"
    "if [ -n \"$CROP\" ]; then\n"
    "  ffmpeg -y -i \"$AVATAR\" -vf \"${CROP}setsar=1\" \\\n"
    "    -c:v libx264 -pix_fmt yuv420p -c:a copy \"$W/avatar-clean.mp4\"\n"
    "  AVATAR_CLEAN=\"$W/avatar-clean.mp4\"\n"
    "else\n"
    "  AVATAR_CLEAN=\"$AVATAR\"\n"
    "fi\n"
    "```\n\n"
    "The bed in Step 2 then fills 1080×1920 (`increase,crop`) — no bars reach the frame.\n"
)
_SPOT_SKILL_BARS_RE = re.compile(
    r"### Step 1\.5 — Detect & crop white side bands \(BEFORE anything else\)\n.*?"
    r"`crop=W:H:X:0` — y-offset `0` guarantees the top edge \(and head\) is preserved\.\n",
    re.S)
_SPOT_SKILL_PAIRS = (
    ("Reused 16:9 studio renders often carry white side bands — Step 1.5 crops them (left/right only, never the top).",
     "Reused HeyGen / studio renders often carry a picture baked between two flat bars — Step 1.5 crops a matched "
     "top+bottom or left+right bar pair only (never a plain backdrop, so the head is never cut)."),
)
_PIP_BARS_NEW = (
    "### 2. Detect + crop a baked-in bar pair (BEFORE anything else)\n\n" + _REEL_BARS_PROSE + "\n"
    "```bash\n" + _REEL_BARS_WRITE +
    "CROP=$(python3 work/bars.py \"$TH\") || exit 1\n"
    "echo \"[pip] bar crop: '${CROP:-none}'\"\n"
    "```\n"
)
_PIP_BARS_RE = re.compile(
    r"### 2\. Detect \+ crop white side-bands \(BEFORE anything else\)\n.*?echo \"\[pip\] side-band crop: '\$\{CROP:-none\}'\"\n```\n",
    re.S)
_PIP_PREP_PAIRS = (
    ("dimensions (white side-bands\n  cropped away)",
     "dimensions (a matched pair of\n  baked-in bars cropped away — step 2)"),
)
_PIP_CARD_CROP = "crop=${CARD_W}:${CARD_H}:(iw-ow)/2:0"
_PIP_FILL_PAIRS = (
    ("### 2. Composite — scale-to-FIT (face never cropped), bottom-centre, audio = the bed",
     "### 2. Composite — scale-to-FILL (top-biased crop, no bars), bottom-centre, audio = the bed"),
    ("identical dims, hence the `pad`.",
     "identical dims, hence the `crop`. WI2.71: fill + crop, never fit + pad — padding showed bars in the card.\n"
     "The crop is top-biased (`y=0`): the head is always kept; only the body below the card is lost."),
    ("force_original_aspect_ratio=decrease,pad=${CARD_W}:${CARD_H}:(ow-iw)/2:0,setsar=1",
     "force_original_aspect_ratio=increase," + _PIP_CARD_CROP + ",setsar=1"),
    ("[1:v]scale=${CARD_W}:${CARD_H}:force_original_aspect_ratio=decrease,setsar=1[thfit]",
     "[1:v]scale=${CARD_W}:${CARD_H}:force_original_aspect_ratio=increase," + _PIP_CARD_CROP + ",setsar=1[thfit]"),
)
_PIP_SHARED_PAIRS = (
    ("110 px bottom margin, face whole —\nnever cropped), and a",
     "110 px bottom margin, face whole —\nthe card is filled with a top-biased crop, no bars), and a"),
)
_PIP_AVATAR_PAIRS = (
    ("(the PIP card is scale-to-fit)", "(the PIP card is filled with a top-biased crop, no bars)"),
    ("(the PIP card scales to fit)", "(the PIP card fills with a top-biased crop)"),
)
_PIP_SKILL_BARS_NEW = (
    "### Step 1.5 — Detect + crop a baked-in bar pair (BEFORE anything else)\n\n" + _REEL_BARS_PROSE + "\n"
    "```bash\n" + _REEL_BARS_WRITE_W +
    "CROP=$(python3 \"$W/bars.py\" \"$TH\") || exit 1\n"
    "echo \"[p-reels-pip] bar crop: '${CROP:-none}'\"\n"
    "if [ -n \"$CROP\" ]; then\n"
    "  $FF -y -i \"$TH\" -vf \"${CROP}setsar=1\" \\\n"
    "    -c:v libx264 -pix_fmt yuv420p -c:a copy \"$W/th-clean.mp4\"\n"
    "  TH_CLEAN=\"$W/th-clean.mp4\"\n"
    "else\n"
    "  TH_CLEAN=\"$TH\"\n"
    "fi\n"
)
_PIP_SKILL_BARS_RE = re.compile(
    r"### Step 1\.5 — Detect \+ crop white side-bands \(BEFORE anything else\)\n.*?  TH_CLEAN=\"\$TH\"\nfi\n",
    re.S)
_PIP_SKILL_PAIRS = _PIP_FILL_PAIRS[2:] + (
    ("| PIP fit | scale-to-FIT (face never cropped) | `scale=CARD_W:CARD_H:force_original_aspect_ratio=decrease` "
     "— whole face shows, scaled to fit. Never crop the face. |",
     "| PIP fit | scale-to-FILL, top-biased crop (no bars) | `scale=CARD_W:CARD_H:force_original_aspect_ratio=increase,"
     "crop=CARD_W:CARD_H:(iw-ow)/2:0` — the card is filled edge to edge; the crop keeps the top, so the head is "
     "never cut. WI2.71: fit + pad showed bars in the card. |"),
    ("The talking head is scale-to-FIT (whole face preserved — never cropped). Positioned bottom-center",
     "The talking head is scale-to-FILL with a top-biased crop (no bars; the head is never cut). Positioned bottom-center"),
    ("#   [TH] scale→FIT → format=yuva444p → [thfit]",
     "#   [TH] scale→FILL + top-biased crop → format=yuva444p → [thfit]"),
    ("  # pad=...:(ow-iw)/2:0 letterbox-centers the scale-to-FIT result to exactly the\n"
     "  # card dims so alphamerge dimensions match (bake-off #2 fix preserved).",
     "  # increase + crop=...:(iw-ow)/2:0 fills the card to exactly the card dims so\n"
     "  # alphamerge dimensions match (bake-off #2 fix preserved) — no pad bars (WI2.71)."),
    ("  # A 9:16 talking head scales to FIT inside the card leaving a horizontal gap.\n"
     "  # alphamerge requires both inputs (scaled TH and the mask) to have IDENTICAL\n"
     "  # dimensions. Fix: pad=${CARD_W}:${CARD_H}:(ow-iw)/2:0 letterbox-centers to the\n"
     "  # card dims before the format conversion.",
     "  # alphamerge requires both inputs (scaled TH and the mask) to have IDENTICAL\n"
     "  # dimensions. WI2.71: scale-to-FILL then crop=${CARD_W}:${CARD_H}:(iw-ow)/2:0\n"
     "  # gives exactly the card dims with no pad bars; y=0 keeps the head."),
    ("- `force_original_aspect_ratio=decrease` → whole face visible, never cropped (fmt5 v1 bug fix)",
     "- `force_original_aspect_ratio=increase,crop=…:(iw-ow)/2:0` → card filled, no bars, the top (head) kept "
     "(WI2.71; fit + pad showed bars)"),
    ("not stretched. Cropped face = scale-to-FIT failed → fix Step 7.",
     "not stretched. Cut head = the card crop is not top-biased → fix Step 7."),
    ("- **Scale-to-FIT (PIP), never crop the face.**\n"
     "  `scale=CARD_W:CARD_H:force_original_aspect_ratio=decrease` → whole face visible.\n"
     "  fmt5 v1 cut the chin with a square crop — this is the explicit fix.",
     "- **Scale-to-FILL (PIP), top-biased crop — never cut the head.**\n"
     "  `scale=CARD_W:CARD_H:force_original_aspect_ratio=increase,crop=CARD_W:CARD_H:(iw-ow)/2:0` → no bars.\n"
     "  fmt5 v1 cut the chin with a centred square crop; WI2.71 replaced fit + pad, which showed bars."),
)
REEL_FILL_FRAME_FILES = {
    "p-reels-spotlight": "spotlight", "p-reels-spotlight-heygen": "spotlight",
    "p-reels-pip": "pip", "p-reels-pip-heygen": "pip",
}


def _apply_pairs(text, pairs):
    """Replace each pair's old text wherever it still appears outside that pair's
    new text. Idempotent even when the new text contains the old text, and a pair
    is never skipped just because its new text already appears elsewhere."""
    for old, new in pairs:
        if old in text:
            text = new.join(part.replace(old, new) for part in text.split(new))
    return text


def apply_reel_fill_frame(directory: Path, recipe: str) -> int:
    """WI2.71: crop a matched baked-in bar pair and fill the frame / pip card.
    Top-level recipe files only (the .hub copies are left as synced). Idempotent.
    Returns files changed."""
    kind = REEL_FILL_FRAME_FILES.get(recipe)
    if not kind:
        return 0
    if kind == "spotlight":
        jobs = (("steps/01-prepare-footage.md", _SPOT_BARS_RE, _SPOT_BARS_NEW, _SPOT_FILL_PAIRS),
                ("SKILL.md", _SPOT_SKILL_BARS_RE, _SPOT_SKILL_BARS_NEW, _SPOT_SKILL_PAIRS))
    else:
        jobs = (("steps/01-prepare-footage.md", _PIP_BARS_RE, _PIP_BARS_NEW, _PIP_PREP_PAIRS),
                ("steps/05-composite.md", None, None, _PIP_FILL_PAIRS),
                ("steps/_shared.md", None, None, _PIP_SHARED_PAIRS),
                ("steps/00-generate-avatar.md", None, None, _PIP_AVATAR_PAIRS),
                ("SKILL.md", _PIP_SKILL_BARS_RE, _PIP_SKILL_BARS_NEW, _PIP_SKILL_PAIRS))
    changed = 0
    for rel, rx, new_block, pairs in jobs:
        path = directory / rel
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        new = text
        if rx is not None:
            new, hits = rx.subn(lambda _m: new_block, new, count=1)
            if not hits and new_block not in new and "BEFORE anything else" in new:
                # WI2.75: fail fast, never a silent no-op when a bar-detect section is
                # present but its anchor text drifted. A file with no such section at all
                # (a heygen wrapper's SKILL.md that delegates, a minimal fixture) is left alone.
                raise SystemExit(f"sync-skills.py: ERROR - bar-detect anchor text not found in {path} ({recipe}); "
                                 "the WI2.71/WI2.75 transform cannot apply")
        new = _apply_pairs(new, pairs)
        if new != text:
            path.write_text(new, encoding="utf-8")
            changed += 1
    return changed


# WI2.72: reel captions come from the Whisper transcript of the voice bed, and
# nothing checked those words against the script the voice was made from. These
# transforms (top-level 02-transcribe.md of the four reel recipes) write
# work/script_align.py, pass the script as the mlx_whisper --initial-prompt, and
# after normalising align the recognised words to the script with difflib: a
# mis-heard word becomes the script word, a word not in the script is dropped,
# timings are kept. No script (an uploaded clip) -> words left unchanged.
_SCRIPT_ALIGN_PY = r"""# WI2.72: check recognised words against the known script and fix mis-heard ones.
# usage: python3 work/script_align.py words.json   (fix words.json in place)
#        python3 work/script_align.py --prompt     (print the script text, or nothing)
# The script is the first of: inputs/script/* (script.json {"text"} or .txt/.md),
# prior/approved_script.md, prior/script.md. No script -> the words are left unchanged.
import difflib, glob, json, os, re, sys

def script_text():
    for p in sorted(glob.glob('inputs/script/*')) + ['prior/approved_script.md', 'prior/script.md']:
        if not os.path.isfile(p):
            continue
        raw = open(p, encoding='utf-8').read()
        if p.endswith('.json'):
            try:
                raw = str((json.loads(raw) or {}).get('text') or '')
            except (ValueError, AttributeError):
                raw = ''
        raw = raw.strip()
        if raw:
            return raw
    return ''

def norm(t):
    return re.sub(r"[^0-9a-z]", "", t.lower())

def dress(rec, scr):
    # the script's word, wearing the recognised token's leading/trailing punctuation
    core = re.sub(r"^\W+|\W+$", "", scr) or scr
    lead = re.match(r"^\W*", rec).group(0)
    tail = re.search(r"\W*$", rec).group(0)
    return lead + core + tail

def align(words, script, max_block=4, min_ratio=0.6):
    toks = []  # (entry index, token)
    for i, w in enumerate(words):
        for t in str(w['text']).split():
            if norm(t):
                toks.append([i, t])
    scr = [t for t in script.split() if norm(t)]
    a, b = [norm(t) for _, t in toks], [norm(t) for t in scr]
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    ratio = sum(m.size for m in sm.get_matching_blocks()) / max(len(a), 1)
    report = {"script_words": len(scr), "recognised_words": len(a), "match": round(ratio, 3),
              "fixed": [], "dropped": [], "left": []}
    spans = []  # (first, last) entry of each fewer-words fix
    if not scr or ratio < min_ratio:
        report["note"] = "the script does not match this voice; words left as recognised"
        return words, report
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == 'equal' or op == 'insert':
            continue
        n, m = i2 - i1, j2 - j1
        if max(n, m) > max_block:
            report["left"].append(" ".join(t for _, t in toks[i1:i2]))
            continue
        if op == 'delete':
            for k in range(i1, i2):
                report["dropped"].append(toks[k][1]); toks[k][1] = None
            continue
        if n > m:  # WI2.77: fewer script words than heard ('New York' -> 'NYC'): one caption
            joined = " ".join(scr[j1:j2])  # from the start of the first heard word to the end of the last
            core = re.sub(r"^\W+|\W+$", "", joined) or joined
            new = re.match(r"^\W*", toks[i1][1]).group(0) + core + re.search(r"\W*$", toks[i2 - 1][1]).group(0)
            report["fixed"].append([" ".join(t for _, t in toks[i1:i2]), new])
            toks[i1][1] = new
            for k in range(i1 + 1, i2):
                toks[k][1] = None
            spans.append((toks[i1][0], toks[i2 - 1][0]))
            continue
        for k in range(n):  # replace: spread the script words over the recognised slots
            s0, s1 = round(k * m / n), round((k + 1) * m / n)
            new = " ".join(dress(toks[i1 + k][1], t) for t in scr[j1 + s0:j1 + s1]) or None
            report["fixed"].append([toks[i1 + k][1], new])
            toks[i1 + k][1] = new
    texts = {}
    for i, t in toks:
        texts.setdefault(i, [])
        if t:
            texts[i].append(t)
    head = list(range(len(words)))  # WI2.77: entries a fewer-words fix spans fold into their first
    for first, last in spans:
        for i in range(first + 1, last + 1):
            head[i] = head[first]
    out, kept = [], {}
    for i, w in enumerate(words):
        if head[i] != i and head[i] in kept:
            o = kept[head[i]]
            more = " ".join(texts[i]) if i in texts else str(w.get('text', '')).strip()
            if more:
                o['text'] = (str(o.get('text', '')).strip() + " " + more).strip()
            if 'end' in w:
                o['end'] = w['end']
            continue
        if i in texts and not texts[i]:
            continue  # every token of this entry was not in the script
        new = dict(w)
        if i in texts:
            new['text'] = " ".join(texts[i])
        out.append(new)
        kept[i] = new
    return out, report

if __name__ == '__main__':
    if sys.argv[1:] == ['--prompt']:
        print(script_text()); sys.exit(0)
    path = sys.argv[1]
    text = script_text()
    if not text:
        print("[transcribe] no script text: words left as recognised (an uploaded clip has no script)")
        sys.exit(0)
    words = json.load(open(path))
    out, rep = align(words, text)
    assert out, "script check removed every word"
    json.dump(out, open(path, 'w'))
    json.dump(rep, open(os.path.join(os.path.dirname(path) or '.', 'script_align.json'), 'w'), indent=1)
    print("[transcribe] script check: match %.2f, fixed %d, dropped %d, left %d%s" % (
        rep["match"], len(rep["fixed"]), len(rep["dropped"]), len(rep["left"]),
        (" - " + rep["note"]) if rep.get("note") else ""))
"""
_SCRIPT_ALIGN_SECTION = (
    "### 0. Known script (WI2.72)\n\n"
    "Captions come from these words, so a mis-heard word would be burned into the reel. When the\n"
    "order carries the script the voice was made from — `inputs/script/*` (`script.json` `{\"text\"}`\n"
    "or a `.txt`/`.md`), else `prior/approved_script.md`, else `prior/script.md` — the helper below\n"
    "passes it to `mlx_whisper` as `--initial-prompt` and, in step 2b, corrects the recognised\n"
    "words against it. With no script (an uploaded talking-head clip) the words are left exactly as\n"
    "recognised and the helper says so.\n\n"
    "```bash\nmkdir -p work saves\ncat > work/script_align.py <<'PY'\n" + _SCRIPT_ALIGN_PY + "PY\n```\n\n"
)
_SCRIPT_ALIGN_CHECK = (
    "### 2b. Check the words against the script (WI2.72)\n\n"
    "Align the cleaned words to the script (difflib on lower-cased letters and digits). A short\n"
    "mismatch (4 words or fewer) is fixed: a mis-heard word takes the script word, a recognised word\n"
    "that is not in the script is dropped. Timings are never edited. When under 60 % of the words\n"
    "match, the script is not what was spoken and the words are left as recognised. What changed is\n"
    "in `work/script_align.json`.\n\n"
    "```bash\npython3 work/script_align.py work/words.json || exit 1\n```\n\n"
)
_SCRIPT_ALIGN_CHECK_WI272 = _SCRIPT_ALIGN_CHECK
_SCRIPT_ALIGN_CHECK = _SCRIPT_ALIGN_CHECK_WI272.replace(
    "that is not in the script is dropped. Timings are never edited. When under 60 % of the words\n",
    "that is not in the script is dropped. No time is left without a caption: when the script says it\n"
    "in fewer words than were heard (heard \"New York\", script \"NYC\"), those script words become one\n"
    "caption from the start of the first heard word to the end of the last (WI2.77); otherwise\n"
    "timings are not edited. When under 60 % of the words\n")
_SCRIPT_ALIGN_MLX_OLD = ("  mlx_whisper prior/voice_track.mp4 --model mlx-community/whisper-small-mlx "
                         "--output-dir work --output-format json\n")
# WI2.72 wrote ${SCRIPT_PROMPT:+--initial-prompt "$SCRIPT_PROMPT"}: zsh (the engine's shell) keeps
# that as ONE argument, mlx_whisper takes it for a second audio file, skips it and exits 0, so
# the prompt was dropped silently. WI2.77: an explicit if branch (not an array: arrays differ
# between sh and zsh) gives two arguments in bash, sh and zsh alike.
_SCRIPT_ALIGN_MLX_WI272 = ("  SCRIPT_PROMPT=$(python3 work/script_align.py --prompt)\n"
                           "  mlx_whisper prior/voice_track.mp4 --model mlx-community/whisper-small-mlx "
                           "--output-dir work --output-format json ${SCRIPT_PROMPT:+--initial-prompt \"$SCRIPT_PROMPT\"}\n")
_SCRIPT_ALIGN_MLX_NEW = ("  SCRIPT_PROMPT=$(python3 work/script_align.py --prompt)\n"
                         "  # WI2.77: an explicit branch, so the prompt is two arguments in bash, sh and zsh\n"
                         "  if [ -n \"$SCRIPT_PROMPT\" ]; then\n"
                         "    mlx_whisper prior/voice_track.mp4 --model mlx-community/whisper-small-mlx "
                         "--output-dir work --output-format json --initial-prompt \"$SCRIPT_PROMPT\"\n"
                         "  else\n"
                         "    mlx_whisper prior/voice_track.mp4 --model mlx-community/whisper-small-mlx "
                         "--output-dir work --output-format json\n"
                         "  fi\n")
_SCRIPT_ALIGN_PIP_OLD = ("entries and canonicalise the key (`word` → `text`). When `prior/script.md` exists, align the\n"
                         "recognised words to the script text (same count → replace texts in order; otherwise fix obvious\n"
                         "misrecognitions only). Timings are never edited.\n")
_SCRIPT_ALIGN_PIP_NEW = ("entries and canonicalise the key (`word` → `text`). Step 2b then checks the words against the\n"
                         "script. Timings are never edited.\n")
_SCRIPT_ALIGN_OPEN = "cat > work/script_align.py <<'PY'\n"
_SCRIPT_ALIGN_H1 = "### 1. Transcribe the bed with word timestamps\n"
_SCRIPT_ALIGN_H3 = "### 3. B-roll cue transcripts (only when `inputs/broll/` exists)\n"
REEL_SCRIPT_ALIGN_RECIPES = ("p-reels-spotlight", "p-reels-spotlight-heygen", "p-reels-pip", "p-reels-pip-heygen")


def apply_reel_script_align(directory: Path, recipe: str) -> int:
    """WI2.72: correct mis-heard caption words against the known script.
    Top-level steps/02-transcribe.md only. Idempotent; fails fast when an anchor
    drifted instead of silently skipping. Returns files changed."""
    if recipe not in REEL_SCRIPT_ALIGN_RECIPES:
        return 0
    path = directory / "steps" / "02-transcribe.md"
    if not path.is_file():
        return 0
    text = path.read_text(encoding="utf-8")
    if "### 2. Quality check" not in text:
        # Not a full transcribe step (a minimal fixture): left alone. A real step that
        # has this section but lost another anchor fails fast below.
        return 0
    new = text
    if _SCRIPT_ALIGN_SECTION not in new and _SCRIPT_ALIGN_OPEN in new:
        # WI2.77: an older helper (WI2.72) is in place: swap in the current one.
        head, rest = new.split(_SCRIPT_ALIGN_OPEN, 1)
        if "\nPY\n" not in rest:
            raise SystemExit(f"sync-skills.py: ERROR - script_align.py heredoc not closed in {path} ({recipe}); "
                             "the WI2.77 transform cannot apply")
        new = head + _SCRIPT_ALIGN_OPEN + _SCRIPT_ALIGN_PY + "PY\n" + rest.split("\nPY\n", 1)[1]
        if _SCRIPT_ALIGN_SECTION not in new:
            raise SystemExit(f"sync-skills.py: ERROR - script-align section text drifted in {path} ({recipe}); "
                             "the WI2.77 transform cannot apply")
    new = new.replace(_SCRIPT_ALIGN_CHECK_WI272, _SCRIPT_ALIGN_CHECK)
    new = new.replace(_SCRIPT_ALIGN_MLX_WI272, _SCRIPT_ALIGN_MLX_NEW)
    if _SCRIPT_ALIGN_SECTION not in new:
        if _SCRIPT_ALIGN_H1 not in new:
            raise SystemExit(f"sync-skills.py: ERROR - transcribe heading not found in {path} ({recipe}); "
                             "the WI2.72 transform cannot apply")
        new = new.replace(_SCRIPT_ALIGN_H1, _SCRIPT_ALIGN_SECTION + _SCRIPT_ALIGN_H1, 1)
    if _SCRIPT_ALIGN_CHECK not in new:
        if _SCRIPT_ALIGN_H3 not in new:
            raise SystemExit(f"sync-skills.py: ERROR - b-roll heading not found in {path} ({recipe}); "
                             "the WI2.72 transform cannot apply")
        new = new.replace(_SCRIPT_ALIGN_H3, _SCRIPT_ALIGN_CHECK + _SCRIPT_ALIGN_H3, 1)
    if _SCRIPT_ALIGN_MLX_NEW not in new:
        if _SCRIPT_ALIGN_MLX_OLD not in new:
            raise SystemExit(f"sync-skills.py: ERROR - mlx_whisper line not found in {path} ({recipe}); "
                             "the WI2.72 transform cannot apply")
        new = new.replace(_SCRIPT_ALIGN_MLX_OLD, _SCRIPT_ALIGN_MLX_NEW, 1)
    new = new.replace(_SCRIPT_ALIGN_PIP_OLD, _SCRIPT_ALIGN_PIP_NEW)
    if new != text:
        path.write_text(new, encoding="utf-8")
        return 1
    return 0


# WI2.76: smoke 21b showed a lone "FLOUR STILL" caption: the planner split "She approved
# them with flour still on her hands" into three groups. Caption groups were only checked by
# prose. These transforms write work/caption_phrases.py, which regroups the plan's
# caption_groups so no group ends on a preposition/article/conjunction/auxiliary and no 1-2 word
# group is a mid-clause fragment (word timings kept, styles and emphasis re-checked), then the
# guard fails on a split phrase. Spotlight: top-level steps/03-plan-edit.md (saves/edit_plan.json).
# Pip: top-level steps/05-composite.md (c-reel-premium P1 writes work/premium/plan.json there).
_CAPTION_PHRASES_PY = r"""# WI2.76: keep caption phrases whole - never split a group mid-clause.
# usage: python3 work/caption_phrases.py PLAN.json           (repair caption_groups in place)
#        python3 work/caption_phrases.py --check PLAN.json   (exit 1 when a group splits a phrase)
# A break never follows a preposition, article, conjunction or auxiliary (the trailing word
# moves to the next group). A 1-2 word group from mid-clause (no punctuation before it or after
# it) merges into a neighbour. Groups stay 2-4 words where they were; up to 6 to keep a phrase
# whole (a longer one is split at punctuation or a clause start). Word timings never change.
# WI2.78: repair mode also fixes adjacent equal styles, a group overlap and a second emphasis
# word on a plan that is already whole; a possessive ("her", "his") joins the next word.
# WI2.79: both modes refuse a group whose end is not after its start, or whose start is not
# after the previous group's start - an overlap is clamped only when the groups are in order.
import json, os, re, sys

MAX_WORDS = 6
JOINERS = set((
    "a an the my your our their its his her every each "
    "and but or nor so yet if than because while "
    "with of to in on at for from by into onto about as like through over under after before "
    "between among during without within until upon via toward towards near against across "
    "is am are was were be been being will would can could shall should may might must").split())
CLOSERS = ".,!?;:—–…"
CONTRACTION = re.compile(r"[a-z]('s|'re|'ve|'ll|'d|'m)$")

def text(w):
    return str(w.get("w", w.get("text", "")))

def bare(w):
    t = text(w).strip().lower().replace("’", "'")
    return re.sub(r"^[^a-z0-9']+|[^a-z0-9']+$", "", t)

def closes(w):
    # the word ends a clause: trailing punctuation (quotes/brackets ignored)
    t = re.sub(r"[\"'”’)\]]+$", "", text(w).strip())
    return bool(t) and t[-1] in CLOSERS

def joiner(w):
    if closes(w):
        return False
    b = bare(w)
    return b in JOINERS or bool(CONTRACTION.search(b))

def empty_groups(groups):
    # WI2.78: a group without words cannot be checked or repaired - say so plainly
    return ["group %d has no words - every caption group needs at least one word" % i
            for i, g in enumerate(groups) if not g.get("words")]

def num(v):
    try:
        return None if isinstance(v, bool) else float(v)
    except (TypeError, ValueError):
        return None

def timing_problems(groups):
    # WI2.79: clamping an overlap is only safe when every group runs forward in time and
    # the groups are in order; otherwise say so plainly (no clamp to end <= start)
    out, prev = [], None
    for i, g in enumerate(groups):
        s, e = num(g.get("start")), num(g.get("end"))
        if s is None or e is None:
            out.append("group %d has no start/end time (start=%r, end=%r) - every caption group "
                       "needs numeric start and end" % (i, g.get("start"), g.get("end")))
            prev = None
            continue
        if e <= s:
            out.append("group %d ends at %s, not after its start %s - a group must end after it starts"
                       % (i, g.get("end"), g.get("start")))
        if prev is not None and s <= prev:
            out.append("group %d starts at %s, not after group %d (starts at %s) - caption groups "
                       "must be in time order" % (i, g.get("start"), i - 1, groups[i - 1].get("start")))
        prev = s
    return out

def structure_problems(groups):
    # a plan these cannot be checked or repaired safely: no words, no/bad timings
    if not isinstance(groups, list) or not all(isinstance(g, dict) for g in groups):
        return ["caption_groups is not a list of groups"]
    return empty_groups(groups) or timing_problems(groups)

def fragment(groups, i):
    # a 1-2 word group with no clause break before it and none after it
    g = groups[i]["words"]
    if not (0 < i < len(groups) - 1) or len(g) > 2:
        return False
    return not closes(groups[i - 1]["words"][-1]) and not closes(g[-1])

def bad_break(groups, i):
    # the break after group i falls inside a phrase
    return i < len(groups) - 1 and joiner(groups[i]["words"][-1])

def problems(groups):
    out = structure_problems(groups)
    if out:
        return out
    for i, g in enumerate(groups):
        ws = g.get("words") or []
        say = " ".join(text(w) for w in ws)
        if len(ws) > MAX_WORDS + 1:
            out.append("group %d has %d words: %r" % (i, len(ws), say))
        if fragment(groups, i):
            out.append("group %d is a mid-clause fragment: %r" % (i, say))
        if bad_break(groups, i):
            out.append("group %d ends inside a phrase: %r | %r" % (
                i, say, " ".join(text(w) for w in groups[i + 1]["words"])))
        if sum(1 for w in ws if w.get("em")) > 1:
            out.append("group %d has more than one emphasis word" % i)
        if i and g.get("style") == groups[i - 1].get("style"):
            out.append("groups %d and %d share style %s" % (i - 1, i, g.get("style")))
        if i and float(g["start"]) < float(groups[i - 1]["end"]) - 1e-6:
            out.append("group %d overlaps group %d" % (i, i - 1))
    return out

def split_long(ws):
    # best cut of an over-long group: after punctuation, else before a clause start,
    # never leaving a phrase-ending word on the left, both sides >= 3 words
    best = None
    for k in range(3, len(ws) - 2):
        left = ws[k - 1]
        if joiner(left):
            continue
        score = (0 if closes(left) else 1 if bare(ws[k]) in JOINERS else 2, abs(len(ws) - 2 * k))
        if best is None or score < best[0]:
            best = (score, k)
    return None if best is None else best[1]

def repair(groups):
    groups = [dict(g, words=[dict(w) for w in (g.get("words") or [])]) for g in groups]
    changed = False
    for _ in range(200):
        moved = False
        # fragments first, then phrase-ending breaks, then over-long groups
        frag = [i for i in range(len(groups)) if fragment(groups, i)]
        brk = [i for i in range(len(groups)) if bad_break(groups, i)]
        order = frag[:1] or brk[:1] or range(len(groups))
        for i in order:
            if fragment(groups, i):
                prev_n, next_n = len(groups[i - 1]["words"]), len(groups[i + 1]["words"])
                j = i - 1 if prev_n < next_n else i + 1
                lo, hi = min(i, j), max(i, j)
                groups[lo]["words"] += groups[hi]["words"]
                groups[lo]["_new"] = changed = True; del groups[hi]
                moved = True; break
            if bad_break(groups, i):
                a, b = groups[i], groups[i + 1]
                while a["words"] and joiner(a["words"][-1]):
                    b["words"].insert(0, a["words"].pop())
                a["_new"] = b["_new"] = changed = True
                if not a["words"]:
                    del groups[i]
                moved = True; break
            if len(groups[i]["words"]) > MAX_WORDS:
                k = split_long(groups[i]["words"])
                if k is None:
                    continue
                g = groups[i]
                tail = dict(g, words=g["words"][k:]); g["words"] = g["words"][:k]
                groups.insert(i + 1, tail); g["_new"] = tail["_new"] = changed = True
                moved = True; break
        if not moved:
            break
    for g in groups:
        if g.pop("_new", False):
            g["start"], g["end"] = g["words"][0]["s"], g["words"][-1]["e"]
    return groups, changed

def restyle(groups):
    for i, g in enumerate(groups):
        prev = groups[i - 1].get("style") if i else None
        if g.get("style") == prev:
            nxt = groups[i + 1].get("style") if i + 1 < len(groups) else None
            g["style"] = next(s for s in (0, 1, 2) if s not in (prev, nxt))

def tidy(groups):
    # WI2.78: run on every plan, regrouped or not - at most one emphasis word per group,
    # no group overlaps the next (its end moves back, word timings never move), no two
    # neighbours share a style
    for g in groups:
        seen = False
        for w in g["words"]:
            if w.get("em"):
                if seen:
                    w["em"] = False
                seen = True
    for a, b in zip(groups, groups[1:]):
        if float(a["end"]) > float(b["start"]):
            a["end"] = b["start"]
    restyle(groups)

def run(plan):
    orig = plan.get("caption_groups") or []
    if not orig:
        return plan, False
    bad = structure_problems(orig)
    if bad:
        raise ValueError("; ".join(bad))
    first_start, last_end = orig[0]["start"], orig[-1]["end"]
    groups, regrouped = repair(orig)
    if regrouped:
        groups[0]["start"] = min(float(groups[0]["start"]), float(first_start))
        groups[-1]["end"] = max(float(groups[-1]["end"]), float(last_end))
    tidy(groups)
    if not regrouped and groups == orig:
        return plan, False
    plan = dict(plan, caption_groups=groups)
    return plan, True

def stop(msg):
    print("caption phrase check: " + msg, file=sys.stderr)
    sys.exit(1)

if __name__ == "__main__":
    args = sys.argv[1:]
    check = args[:1] == ["--check"]
    if len(args) != (2 if check else 1):
        stop("usage: caption_phrases.py [--check] PLAN.json (WI2.79)")
    path = args[-1]
    if not os.path.isfile(path):
        stop("plan not found: %s - write the plan before this step (WI2.79)" % path)
    try:
        plan = json.load(open(path))
    except ValueError as exc:
        stop("plan is not valid JSON: %s (%s) (WI2.79)" % (path, exc))
    if not isinstance(plan, dict):
        stop("plan is not a JSON object: %s (WI2.79)" % path)
    structural = structure_problems(plan.get("caption_groups") or [])
    if structural:
        for b in structural:
            print("caption phrase check: " + b, file=sys.stderr)
        sys.exit(1)
    if not check:
        before = [" ".join(text(w) for w in g.get("words") or []) for g in plan.get("caption_groups") or []]
        plan, changed = run(plan)
        if changed:
            json.dump(plan, open(path, "w"), indent=1)
            after = [" ".join(text(w) for w in g["words"]) for g in plan["caption_groups"]]
            if after == before:
                print("[plan] caption phrases: groups kept, styles/overlaps/emphasis fixed")
            else:
                print("[plan] caption phrases: regrouped %d -> %d groups" % (len(before), len(after)))
            for line in sorted(set(after) - set(before), key=after.index):
                print("  [%s]" % line)
        else:
            print("[plan] caption phrases: already whole, plan unchanged")
    bad = problems(plan.get("caption_groups") or [])
    for b in bad:
        print("caption phrase check: " + b, file=sys.stderr)
    sys.exit(1 if bad else 0)
"""
_CAPTION_PHRASES_WRITE = (
    "```bash\nmkdir -p work saves\ncat > work/caption_phrases.py <<'PY'\n" + _CAPTION_PHRASES_PY + "PY\n```\n\n"
)
_CAPTION_PHRASES_SPOT_SECTION = (
    "Keep caption phrases whole (WI2.76). Write the helper, then run it on the plan: it moves a\n"
    "group-ending preposition, article, conjunction or auxiliary into the next group, merges a\n"
    "1–2 word mid-clause fragment into a neighbour (up to 6 words to keep a phrase whole), keeps\n"
    "every word timing, and re-checks styles and emphasis. A plan that is already whole keeps its\n"
    "groups; equal neighbouring styles, an overlap or a second emphasis word are still fixed (WI2.78).\n\n"
    + _CAPTION_PHRASES_WRITE +
    "```bash\npython3 work/caption_phrases.py saves/edit_plan.json || exit 1\n```\n\n"
)
_CAPTION_PHRASES_SPOT_GUARD_ANCHOR = "Then run the mechanical guard — fix the plan and rerun until it prints `plan OK`:\n"
_CAPTION_PHRASES_RULE_OLD = (
    "1. `caption_groups` cover the FULL duration, 2–4 words each, non-overlapping, breaking on sentence\n"
    "   boundaries or pauses ≥ 150 ms. Words VERBATIM from the transcript.\n"
)
_CAPTION_PHRASES_RULE_NEW = (
    "1. `caption_groups` cover the FULL duration, 2–4 words each (up to 6 to keep a phrase whole),\n"
    "   non-overlapping, breaking at punctuation, clause starts or pauses ≥ 150 ms. Never break after a\n"
    "   preposition, article, possessive, conjunction or auxiliary (`with`, `of`, `the`, `her`, `and`,\n"
    "   `is`, …), and never\n"
    "   leave a lone 1–2 word fragment from mid-clause (`She approved them` / `with flour still on her\n"
    "   hands,` — not `She approved them with` / `FLOUR STILL` / `on her hands,`). Words VERBATIM from\n"
    "   the transcript.\n"
)
_CAPTION_PHRASES_GUARD_OLD = "print(f\"plan OK: {len(p['caption_groups'])} groups, {len(tks)} takeovers"
_CAPTION_PHRASES_GUARD_NEW = (
    "import subprocess\n"
    "assert subprocess.run([sys.executable, \"work/caption_phrases.py\", \"--check\", sys.argv[1]]).returncode == 0, \\\n"
    "    \"a caption group splits a phrase mid-clause (WI2.76) — run python3 work/caption_phrases.py saves/edit_plan.json\"\n"
)
_CAPTION_PHRASES_HARNESS_OLD = ("  groups cover the bed to within 3 s, Latin script only, 6-digit brand hexes, every takeover\n"
                                "  2.5–7 s, `cover_at ≥ 2 s`.\n")
_CAPTION_PHRASES_HARNESS_NEW = ("  groups cover the bed to within 3 s and keep phrases whole, Latin script only, 6-digit brand\n"
                                "  hexes, every takeover 2.5–7 s, `cover_at ≥ 2 s`.\n")
_CAPTION_PHRASES_PIP_ANCHOR = "`drawtext` is a defect.\n\n"
_CAPTION_PHRASES_PIP_SECTION = (
    "Keep caption phrases whole (WI2.76). P1's plan may split a phrase (`She approved them with` /\n"
    "`FLOUR STILL` / `on her hands,`). Write the helper below first. The block after it runs P1, then\n"
    "the repair `python3 work/caption_phrases.py \"$PW/plan.json\" || exit 1` as a command, then P2 → P4\n"
    "(WI2.78). The repair moves a group-ending preposition, article, possessive, conjunction or\n"
    "auxiliary into the next group, merges a 1–2 word mid-clause fragment into a neighbour, keeps every\n"
    "word timing and fixes styles, overlaps and emphasis. The `--check` after P4 fails the step when a\n"
    "split phrase was rendered. `CAPTIONS=off` renders no captions, so both are skipped.\n\n"
    + _CAPTION_PHRASES_WRITE
)
# The P1 anchor is the first line of the WI2.64 hunk (_PIP_TAIL_PLAN_NEW). WI2.79: the note
# REPLACES that line, so no "run P1" line follows the repair (an engine re-running P1 would
# overwrite the repaired plan). Inverse: _CAPTION_PHRASES_PIP_P1_NOTE -> _CAPTION_PHRASES_PIP_P1_ANCHOR
# gives back the WI2.64 hunk, so that transform still inverts cleanly (test Case WI2.64).
_CAPTION_PHRASES_PIP_P1_ANCHOR = "# run P1 → P4 here; GSAP for the premium comp: cp \"$GSAP\" \"$PW/comp/gsap.min.js\" \"$PW/comp/compositions/\"\n"
_CAPTION_PHRASES_PIP_P1_NOTE_WI278 = (
    "# 1) run P1 (plan) here: it writes \"$PW/plan.json\"\n"
    "# 2) WI2.76/WI2.78: keep caption phrases whole before P2 renders them (captions off: nothing to render)\n"
    "if [ \"$CAPTIONS\" != off ]; then python3 work/caption_phrases.py \"$PW/plan.json\" || exit 1; fi\n"
    "# 3) then P2 → P4 (P1 is done above; do not plan again):\n"
)
_CAPTION_PHRASES_PIP_P1_NOTE = (
    "# 1) run P1 (plan) here: it writes \"$PW/plan.json\"\n"
    "# 2) WI2.76/WI2.78: keep caption phrases whole before P2 renders them (captions off: nothing to render)\n"
    "if [ \"$CAPTIONS\" != off ]; then python3 work/caption_phrases.py \"$PW/plan.json\" || exit 1; fi\n"
    "# 3) now run P2 → P4 only (P1 is done above; planning again would undo the repair); GSAP for the\n"
    "#    premium comp: cp \"$GSAP\" \"$PW/comp/gsap.min.js\" \"$PW/comp/compositions/\"\n"
)
# The rest of the WI2.64 hunk after its first line: the --check goes after it.
_CAPTION_PHRASES_PIP_TAIL_ANCHOR = _PIP_TAIL_PLAN_NEW[len(_CAPTION_PHRASES_PIP_P1_ANCHOR):]
assert _PIP_TAIL_PLAN_NEW.startswith(_CAPTION_PHRASES_PIP_P1_ANCHOR)
_CAPTION_PHRASES_PIP_CHECK = ("# WI2.76: the rendered premium plan kept phrases whole (captions off: no caption groups rendered)\n"
                              "if [ \"$CAPTIONS\" != off ]; then python3 work/caption_phrases.py --check \"$PW/plan.json\" || exit 1; fi\n")
# WI2.78: the pip P1 prompt (vendored c-reel-premium) states the helper's grouping rule. Plain
# ASCII, no quotes/backticks/dollars: the rule sits inside the double-quoted PLAN_PROMPT string.
_CAPTION_PHRASES_P1_RULE_FILE = ".hub/c-reel-premium/SKILL.md"
_CAPTION_PHRASES_P1_RULE_OLD = (
    "1. caption_groups cover the FULL duration, 2-4 words each, non-overlapping, break on sentence\n"
    "   boundaries or pauses >=150ms. Words VERBATIM from the transcript.\n"
)
_CAPTION_PHRASES_P1_RULE_NEW = (
    "1. caption_groups cover the FULL duration, 2-4 words each (up to 6 to keep a phrase whole),\n"
    "   non-overlapping, break at punctuation, clause starts or pauses >=150ms. Never end a group on a\n"
    "   preposition, article, possessive, conjunction or auxiliary (with, of, the, her, his, and, is),\n"
    "   and never leave a lone 1-2 word fragment from mid-clause (She approved them / with flour still\n"
    "   on her hands, - not She approved them with / FLOUR STILL / on her hands,). Words VERBATIM from\n"
    "   the transcript.\n"
)
_CAPTION_PHRASES_PIP_PROSE_OLD = "`.words` (2–4 words per group, Latin script only, ≤ 1 emphasis word, no SFX in the first second;\n"
_CAPTION_PHRASES_PIP_PROSE_NEW = ("`.words` (2–4 words per group, phrases kept whole, Latin script only, ≤ 1 emphasis word, no\n"
                                  "SFX in the first second;\n")
REEL_CAPTION_PHRASES_FILES = {
    "p-reels-spotlight": "steps/03-plan-edit.md",
    "p-reels-spotlight-heygen": "steps/03-plan-edit.md",
    "p-reels-pip": "steps/05-composite.md",
    "p-reels-pip-heygen": "steps/05-composite.md",
}


def _caption_phrases_insert(new: str, path: Path, recipe: str, anchor: str, add: str, after: bool,
                            wi: str = "WI2.76") -> str:
    if add in new:
        return new
    if anchor not in new:
        raise SystemExit(f"sync-skills.py: ERROR - anchor {anchor[:40]!r} not found in {path} ({recipe}); "
                         f"the {wi} transform cannot apply")
    return new.replace(anchor, (anchor + add) if after else (add + anchor), 1)


_CAPTION_PHRASES_HELPER_RE = re.compile(r"cat > work/caption_phrases\.py <<'PY'\n.*?\nPY\n", re.S)


def _caption_phrases_refresh_helper(text: str, path: Path, recipe: str) -> str:
    """An earlier helper body already in the step is replaced by the current one (WI2.79),
    so the section insert below stays idempotent across helper changes."""
    found = _CAPTION_PHRASES_HELPER_RE.findall(text)
    if not found:
        return text
    if len(found) != 1:
        raise SystemExit(f"sync-skills.py: ERROR - {len(found)} caption_phrases.py helpers in {path} ({recipe}); "
                         "the WI2.79 transform cannot apply")
    current = "cat > work/caption_phrases.py <<'PY'\n" + _CAPTION_PHRASES_PY + "PY\n"
    return text.replace(found[0], current, 1)


def apply_reel_caption_phrases(directory: Path, recipe: str) -> int:
    """WI2.76: keep caption phrases whole (no lone mid-clause fragment).
    Top-level spotlight 03-plan-edit.md / pip 05-composite.md only (not .hub copies), plus the
    pip .hub/c-reel-premium P1 caption rule (WI2.78). WI2.79: the pip P1 note replaces the
    WI2.64 "run P1 → P4" line, so nothing after the repair invites a second P1.
    Idempotent; fails fast when an anchor drifted. Returns files changed."""
    rel = REEL_CAPTION_PHRASES_FILES.get(recipe)
    if rel is None:
        return 0
    path = directory / rel
    if not path.is_file():
        return 0
    text = path.read_text(encoding="utf-8")
    new = _caption_phrases_refresh_helper(text, path, recipe)
    if rel.endswith("03-plan-edit.md"):
        if "Then run the mechanical guard" not in text:
            return 0  # a minimal fixture, not the real plan step
        new = _caption_phrases_insert(new, path, recipe, _CAPTION_PHRASES_SPOT_GUARD_ANCHOR,
                                      _CAPTION_PHRASES_SPOT_SECTION, after=False)
        new = _caption_phrases_insert(new, path, recipe, _CAPTION_PHRASES_GUARD_OLD,
                                      _CAPTION_PHRASES_GUARD_NEW, after=False)
        if _CAPTION_PHRASES_RULE_NEW not in new:
            if _CAPTION_PHRASES_RULE_OLD not in new:
                raise SystemExit(f"sync-skills.py: ERROR - caption rule 1 not found in {path} ({recipe}); "
                                 "the WI2.76 transform cannot apply")
            new = new.replace(_CAPTION_PHRASES_RULE_OLD, _CAPTION_PHRASES_RULE_NEW, 1)
        new = new.replace(_CAPTION_PHRASES_HARNESS_OLD, _CAPTION_PHRASES_HARNESS_NEW, 1)
    else:
        if "### 5. Kinetic captions" not in text:
            return 0  # a minimal fixture, not the real composite step
        new = _caption_phrases_insert(new, path, recipe, _CAPTION_PHRASES_PIP_ANCHOR,
                                      _CAPTION_PHRASES_PIP_SECTION, after=True)
        # the --check first, while the WI2.64 hunk is still whole (WI2.78)
        if _CAPTION_PHRASES_PIP_CHECK not in new:
            new = _caption_phrases_insert(new, path, recipe, _PIP_TAIL_PLAN_NEW,
                                          _CAPTION_PHRASES_PIP_CHECK, after=True, wi="WI2.78")
        # WI2.79: the note replaces the "run P1 → P4" line (also over a WI2.78 note + that line)
        if _CAPTION_PHRASES_PIP_P1_NOTE not in new:
            old = _CAPTION_PHRASES_PIP_P1_NOTE_WI278 + _CAPTION_PHRASES_PIP_P1_ANCHOR
            if old not in new:
                old = _CAPTION_PHRASES_PIP_P1_ANCHOR
            if new.count(old) != 1 or (old + _CAPTION_PHRASES_PIP_TAIL_ANCHOR) not in new:
                raise SystemExit(f"sync-skills.py: ERROR - P1 line {old[:40]!r} not found once before the "
                                 f"WI2.64 plan clamp in {path} ({recipe}); the WI2.79 transform cannot apply")
            new = new.replace(old, _CAPTION_PHRASES_PIP_P1_NOTE, 1)
        if _CAPTION_PHRASES_PIP_PROSE_NEW not in new:
            new = new.replace(_CAPTION_PHRASES_PIP_PROSE_OLD, _CAPTION_PHRASES_PIP_PROSE_NEW, 1)
    changed = 0
    if new != text:
        path.write_text(new, encoding="utf-8")
        changed = 1
    if rel.endswith("05-composite.md"):
        changed += _caption_phrases_p1_rule(directory, recipe)
    return changed


def _caption_phrases_p1_rule(directory: Path, recipe: str) -> int:
    """WI2.78: the pip P1 caption prompt agrees with work/caption_phrases.py. Idempotent."""
    path = directory / _CAPTION_PHRASES_P1_RULE_FILE
    if not path.is_file():
        return 0
    text = path.read_text(encoding="utf-8")
    if _CAPTION_PHRASES_P1_RULE_NEW in text:
        return 0
    if _CAPTION_PHRASES_P1_RULE_OLD not in text:
        raise SystemExit(f"sync-skills.py: ERROR - P1 caption rule 1 not found in {path} ({recipe}); "
                         "the WI2.78 transform cannot apply")
    path.write_text(text.replace(_CAPTION_PHRASES_P1_RULE_OLD, _CAPTION_PHRASES_P1_RULE_NEW, 1), encoding="utf-8")
    return 1


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

        # WI2.64: after the hub copy so the heygen .hub/p-reels-pip composite
        # gets the same tail hold and CTA caption clamp as the top-level step.
        if recipe in ("p-reels-pip", "p-reels-pip-heygen"):
            apply_p_reels_pip_tail(recipe_dest)

        # WI2.68: after the hub copy so every reel recipe (pip/spotlight/split/
        # faceless and heygen wrappers) plus .hub copies get the real MLX model id.
        if recipe.startswith("p-reels-"):
            apply_whisper_small_mlx(recipe_dest)

        # WI2.71: reel face clips fill the frame and the pip card (no bars).
        apply_reel_fill_frame(recipe_dest, recipe)

        # WI2.72: captions are checked against the known script (top-level transcribe step).
        apply_reel_script_align(recipe_dest, recipe)

        # WI2.76: caption groups keep phrases whole (top-level plan/composite step).
        apply_reel_caption_phrases(recipe_dest, recipe)

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
