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
replaces the WI2.64 "run P1 → P4 here" line on the top-level step and the
vendored .hub copy (its inverse gives that line back).

WI2.73 apply_typing_hold() rewrites the typing window in every vendored
c-typing-ui typing-scene.html (all recipes, .hub copies included): typing ends
0.6 s before the clip ends at any duration or speed, so the full prompt is on
screen before the cut; its SKILL.md gotchas say so.

WI2.80 apply_typing_render_usage() rewrites pip/split step 04 (all copies) to the real
c-typing-ui render (fill the template, copy gsap.min.js, hyperframes lint + render) in place
of a scripts/render.sh that never shipped, and makes every c-typing-ui SKILL.md describe the
shipped typingWindow() timing and proxy counter (no #char-count element).

WI2.83 apply_spotlight_stat_fit() makes every p-reels-spotlight tk-stat.html copy (top-level
and .hub) keep the stat on one line and fit it to the safe width: the page measures the stat
and scales its font size down from the 340 px design size until it is no wider than 900 px
(900 = (1080 - 2x72) / 1.03 rounded down, so the 1.03 breathe stays inside the 72 px side
padding); it refits once fonts load. WI2.85 (same transform) caps the slam-in start scale at
min(2.4, 936 / fitted width), so a wide stat no longer starts at 2.4x and clips both edges.

WI2.86 apply_spotlight_end_card() makes every p-reels-spotlight steps/06-assemble.md copy
(top-level, the heygen wrapper's own step and .hub) start the end card at
max(bed - cta_duration, last spoken word end), so the closing line keeps the face and captions.
Nothing is appended; under 1.0 s of bed after the last word, the card is skipped with a log line.

WI2.89 apply_spotlight_bed_tail() makes step 01 of every p-reels-spotlight copy (and SKILL.md
Step 2) hold the last frame with silence so cta_duration + 0.5 s (tail <= 3.5 s) follows the
speech, so the WI2.86 end card always fits; transcript/caption tolerances 4.5 s, reel window 65 s.

WI2.87 apply_spotlight_typing_takeover() makes step 05 of every p-reels-spotlight copy (and
SKILL.md Step 5) slot the c-typing-ui scene as a real sub-composition: <template> kept, composition
id = the slot id (tk<i>), ts-* ids/classes and its script scoped to the slot. Stripped, HyperFrames
never got ready and every takeover fell back to a still card with no entry motion.

WI2.93 apply_spotlight_end_card_render() makes step 06 of every p-reels-spotlight copy (and
SKILL.md Step 8 and scripts/cta-card.py) render the end card with hyperframes from a project directory
(cta-card.py writes index.html + gsap.min.js), never the .json spec ("Not a directory"); there is no
still ffmpeg fallback card, so a failed render fails the step.

WI2.92 apply_spotlight_takeover_render_fail_loud() makes step 05 of every p-reels-spotlight copy
(and SKILL.md Step 5, the Step 10.6 gate and the old Fallback assembly section) fail with the
hyperframes error when the takeover render fails; the still-card (PNG / ffmpeg overlay) fallback is gone.

WI2.94 apply_spotlight_takeover_line_fit() makes every p-reels-spotlight takeover template copy
(tk-stat eyebrow/label, tk-list title/items, tk-keyword word/support, tk-quote attribution) keep each
line on one line: white-space: nowrap, and the page shrinks the font from its design size until the
line fits its safe width (>= 80 px from both frame edges); it refits once fonts load. Never truncated.

WI2.90 apply_spotlight_end_card_room() makes step 06 of every p-reels-spotlight copy fail (exit 1) with
the reason when under 1.0 s of bed is left after the last word, instead of silently dropping the end
card, and makes SKILL.md (both full copies) read the order's cta_card into CTA_CARD (default on), so
cta_card: off adds no Step 2 tail and Step 8 renders no card.

WI2.88 apply_spotlight_caption_pop() makes every caption-overlay.html copy in a p-reels-spotlight
bundle (the vendored c-reel-premium one that step 06 renders, and the recipe's own template) show the
emphasis word as a plain word (same size, FG colour, same dim) until it is spoken, then pop it by
growing its font size (--pop) instead of a transform scale, so the line reflows and the space before
it is never closed. The WI2.72 script check (apply_reel_script_align) also takes the order brief's
intent as the script when no script file exists, strictly: 80 % must match and only a look-alike
word is swapped one-for-one (never a number); no word is added or dropped.

WI2.96 apply_spotlight_end_card_fit() makes scripts/cta-card.py of every full p-reels-spotlight copy keep
the brand name on one line in the end-card headline (one nowrap unit, non-breaking spaces), lay the
headline out on the fewest lines (max 3) whose most balanced split fits 920 px, and shrink the font when
none does (a brand name still too wide at 60 px shrinks on its own); the kicker stays on one line inside
960 px. It refits once fonts load and upgrades the WI2.93 write_project text in place.

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


# Render-owned feedback is a transform, not a hand edit to the generated bundle.
# Keep upstream feedback and log entries; add these sections once on every sync.
_P_CAROUSEL_FEEDBACK = """- **[ACTIVE] WI2.45 — ordered slides are the deliverables, never cover/sheet.** After
  `render_slides`, write `saves/slide_1.png`…`saves/slide_N.png` (N = outline count) plus
  pad `saves/slide_{N+1}.png`…`saves/slide_10.png` as copies of the last real slide so the
  manifest's fixed `slide_1`…`slide_10` saves all exist for harness upload/resume. Write
  `saves/slides.json` with `count` = N only (real slides). `cover.png` and `slide_sheet.png`
  are previews only — never deliver them. The worker selects `slide_1`…`slide_N` from
  `slides.json` for `complete_render_order`.
"""
_P_CAROUSEL_HISTORY = """## Upstream source port (WI2.45 / WI2.45 review rework)

`scripts/sync-skills.py` rewrites `skills/` from the private source skills repo (`--src`,
outside this repository). Bundled hand-edits are overwritten on the next sync. **Mechanism
(WI2.45 review):** `apply_p_carousel_contract()` in `scripts/sync-skills.py` re-applies the
contract below after every `p-carousel` copy (same pattern as the Playwright work-folder
loader rewrite). LEARNINGS keeps the contract text as history; sync-skills is what keeps it.

### `manifest.json` (render_slides.saves + recipeVersion)

- `recipeVersion`: `2026.10.3` (bumped from `2026.10.2` when slide saves landed).
- `render_slides.saves` must declare, in order:
  - `slide_1` … `slide_10` (`kind: image`, `preview: false`) — max matches `num_slides` choices
  - `cover` (`kind: image`, `preview: true`)
  - `slide_sheet` (`kind: image`, `preview: true`)
  - `slides` (`kind: json`, `preview: false`)
  - `qa_report` (`kind: json`, `preview: false`)

### `steps/03-render-slides.md` — required wording

- You must produce `saves/slide_1.png` … `saves/slide_N.png` as the carousel deliverables
  (N = `slides.json.count`).
- Pad `saves/slide_{N+1}.png` … `saves/slide_10.png` as copies of the last real slide so
  every declared manifest save exists for upload/resume; delivery still uses only
  `slides.json.count`.
- `cover.png` / `slide_sheet.png` are **preview only**; not deliverables.
- Save-writing Python must copy real slides, pad to 10, write `slides.json` with
  `count: len(real)`, then write cover + qa_report + contact sheet.

### `SKILL.md` — Step 8 Deliver

Must say: deliver individual slide PNGs in slide order (`slide_1.png` … `slide_N.png`);
never send `cover.png` or `slide_sheet.png` as a deliverable; managed runs select
`steps/render_slides/saves/slide_N.png` from `slides.json`.

### `steps/04-captions.md` — Delivery boundary

Must say: the worker delivers ordered `saves/slide_1.png` … `saves/slide_N.png` from
`render_slides` (via `prior/slides.json` order) plus captions; do not select `cover.png` or
`slide_sheet.png`.

---

"""
_P_CAROUSEL_LOG = """### 2026-10-20 — WI2.45 resume + sync survival (review rework)
- Manifest declares `slide_1`…`slide_10` so per-slide PNGs are checked, uploaded and
  restored on resume. Recipe pads unused slots; selector still uses `slides.json.count`.
- `scripts/sync-skills.py` `apply_p_carousel_contract()` re-applies those saves and the
  render/captions delivery wording after every sync copy, so the contract survives.

"""


def apply_p_carousel_contract(directory: Path) -> int:
    """Re-apply the p-carousel WI2.43/WI2.45 contract onto a just-copied recipe
    tree. Idempotent. Returns the number of files changed."""
    changed = 0

    learnings = directory / "LEARNINGS.md"
    if learnings.is_file():
        text = learnings.read_text(encoding="utf-8")
        new = text
        for anchor, addition, marker in (
            ("## Active Feedback (apply on every run)\n\n", _P_CAROUSEL_FEEDBACK + "\n",
             "- **[ACTIVE] WI2.45"),
            ("## Feedback Log\n\n", _P_CAROUSEL_LOG, "### 2026-10-20 — WI2.45"),
        ):
            if marker not in new:
                if new.count(anchor) != 1:
                    raise SystemExit(f"sync-skills.py: ERROR - feedback anchor missing in {learnings}")
                new = new.replace(anchor, anchor + addition, 1)
        placeholder = "*None yet — add feedback below and it becomes part of this skill's behavior.*\n\n"
        new = new.replace(placeholder, "", 1)
        if "## Upstream source port (WI2.45" not in new:
            new = new.replace("## Feedback Log\n", _P_CAROUSEL_HISTORY + "## Feedback Log\n", 1)
        if new != text:
            learnings.write_text(new, encoding="utf-8")
            changed += 1

    man_path = directory / "manifest.json"
    if man_path.is_file():
        try:
            data = json.loads(man_path.read_text(encoding="utf-8"))
        except (UnicodeDecodeError, ValueError, json.JSONDecodeError):
            data = None
        if isinstance(data, dict):
            if data.get("recipeVersion") != P_CAROUSEL_RECIPE_VERSION:
                data["recipeVersion"] = P_CAROUSEL_RECIPE_VERSION
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
                break
            # Canonical bytes even when the contract was already present (the shipped
            # manifest once mixed compact slide entries with indented objects).
            canonical = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
            if man_path.read_text(encoding="utf-8") != canonical:
                man_path.write_text(canonical, encoding="utf-8")
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
_PIP_TAIL_WORDS_CLAMP = "# WI2.64: drop caption cues that would sit on the CTA card. Card off leaves the words unchanged.\npython3 work/clamp_captions.py words prior/transcripts.json work/words.json || exit 1\n"
_PIP_TAIL_WORDS_NEW = (
    "# P1 needs the FULL normalized transcript for its ending-gap validation (<3 s).\n"
    "# Clamp only after P1 validates, before P2 renders; never caption the CTA (WI2.64).\n"
    + _PIP_TAIL_WORDS_OLD
)
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
        # Upgrade the old pre-P1 clamp only, not the same command now used after P1.
        new = text.replace(_PIP_TAIL_WORDS_CLAMP + "export PREMIUM_DIR",
                           _PIP_TAIL_WORDS_NEW + "export PREMIUM_DIR", 1)
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
# prior/approved_script.md, prior/script.md. WI2.88: with no script file (an uploaded clip) the
# order brief's intent (brief.json) is checked instead, more strictly: 80 % must match, and only a
# look-alike word is swapped one-for-one (never a number); nothing is inserted or dropped.
# Neither -> the words are left unchanged.
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

def brief_script():
    # WI2.88: an uploaded clip's order has no script file; the owner may have pasted the script
    # as the brief. It is only a candidate: align() leaves the words alone unless 60 % match.
    try:
        brief = json.load(open('brief.json', encoding='utf-8'))
    except (OSError, ValueError):
        return ''
    intent = brief.get('intent') if isinstance(brief, dict) else None
    return intent.strip() if isinstance(intent, str) else ''

def norm(t):
    return re.sub(r"[^0-9a-z]", "", t.lower())

def dress(rec, scr):
    # the script's word, wearing the recognised token's leading/trailing punctuation
    core = re.sub(r"^\W+|\W+$", "", scr) or scr
    lead = re.match(r"^\W*", rec).group(0)
    tail = re.search(r"\W*$", rec).group(0)
    return lead + core + tail

NUMBER_WORDS = set(("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
                    "fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy "
                    "eighty ninety hundred thousand million billion half once twice first second third").split())

def near_miss(heard, want):
    # WI2.88: a look-alike of the script word (flowers -> flour); never a number or number word
    if heard == want or not heard or not want:
        return False
    if any(re.search(r"\d", t) or t in NUMBER_WORDS for t in (heard, want)):
        return False
    return difflib.SequenceMatcher(None, heard, want, autojunk=False).ratio() >= 0.6

def align(words, script, max_block=4, min_ratio=0.6, near_only=False):
    # near_only (WI2.88, a brief rather than a script file): only swap a heard word for a look-alike
    # script word one-for-one; never insert, drop, merge or split words.
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
    for op, i1, i2, j1, j2 in (sm.get_opcodes() if near_only else []):
        if op == 'replace' and i2 - i1 == j2 - j1:
            for k in range(i2 - i1):
                rec, want = toks[i1 + k][1], scr[j1 + k]
                if near_miss(norm(rec), norm(want)):
                    new = dress(rec, want)
                    report["fixed"].append([rec, new])
                    toks[i1 + k][1] = new
                else:
                    report["left"].append(rec)
        elif op != 'equal' and op != 'insert':
            report["left"].append(" ".join(t for _, t in toks[i1:i2]))
    for op, i1, i2, j1, j2 in ([] if near_only else sm.get_opcodes()):
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
    text, source = script_text(), "script"
    if not text:  # WI2.88: no script file -> the brief, when it is the spoken script
        text, source = brief_script(), "brief"
    if not text:
        print("[transcribe] no script text: words left as recognised (an uploaded clip has no script)")
        sys.exit(0)
    words = json.load(open(path))
    if source == "brief":  # a brief is not a script: 80 % must match, look-alike swaps only
        out, rep = align(words, text, min_ratio=0.8, near_only=True)
    else:
        out, rep = align(words, text)
    rep["source"] = source
    if source == "brief" and rep.get("note"):
        rep["note"] = "the brief is not the spoken script; words left as recognised"
    assert out, "script check removed every word"
    json.dump(out, open(path, 'w'))
    json.dump(rep, open(os.path.join(os.path.dirname(path) or '.', 'script_align.json'), 'w'), indent=1)
    print("[transcribe] script check (%s): match %.2f, fixed %d, dropped %d, left %d%s" % (
        source, rep["match"], len(rep["fixed"]), len(rep["dropped"]), len(rep["left"]),
        (" - " + rep["note"]) if rep.get("note") else ""))
"""
# WI2.88: smoke 2026-10-21 (an uploaded clip, no script file) burned "with flowers still" where the
# voice said "with flour still": nothing reached the check. The brief's intent is now the fallback.
_SCRIPT_ALIGN_NOSCRIPT_WI277 = (
    "words against it. With no script (an uploaded talking-head clip) the words are left exactly as\n"
    "recognised and the helper says so.\n")
# The first WI2.88 text (b8c3ff6) applied every script fix to a brief; review found it inserted and
# dropped spoken words. It upgrades in place like the WI2.77 text.
_SCRIPT_ALIGN_NOSCRIPT_B8C = (
    "words against it. An uploaded talking-head clip has no script file, so step 2b checks the words\n"
    "against the order brief's `intent` instead (WI2.88): when the owner pasted the script there, a\n"
    "mis-heard word is fixed the same way; a brief that is only a topic matches under 60 % and\n"
    "changes nothing. With neither, the words are left exactly as recognised and the helper says so.\n")
_SCRIPT_ALIGN_NOSCRIPT = (
    "words against it. An uploaded talking-head clip has no script file, so step 2b checks the words\n"
    "against the order brief's `intent` instead (WI2.88), more strictly: 80 % of the heard words must\n"
    "match, and only a heard word that looks like the brief's word (`flowers` -> `flour`) is swapped,\n"
    "one for one, never a number; no word is added or dropped. With neither, the words are left\n"
    "exactly as recognised and the helper says so.\n")
_SCRIPT_ALIGN_SECTION = (
    "### 0. Known script (WI2.72)\n\n"
    "Captions come from these words, so a mis-heard word would be burned into the reel. When the\n"
    "order carries the script the voice was made from — `inputs/script/*` (`script.json` `{\"text\"}`\n"
    "or a `.txt`/`.md`), else `prior/approved_script.md`, else `prior/script.md` — the helper below\n"
    "passes it to `mlx_whisper` as `--initial-prompt` and, in step 2b, corrects the recognised\n"
    + _SCRIPT_ALIGN_NOSCRIPT + "\n"
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
    new = text.replace(_SCRIPT_ALIGN_NOSCRIPT_WI277, _SCRIPT_ALIGN_NOSCRIPT)  # WI2.88 prose
    new = new.replace(_SCRIPT_ALIGN_NOSCRIPT_B8C, _SCRIPT_ALIGN_NOSCRIPT)
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
_CAPTION_PHRASES_PIP_P1_NOTE_WI279 = (
    "# 1) run P1 (plan) here: it writes \"$PW/plan.json\"\n"
    "# 2) WI2.76/WI2.78: keep caption phrases whole before P2 renders them (captions off: nothing to render)\n"
    "if [ \"$CAPTIONS\" != off ]; then python3 work/caption_phrases.py \"$PW/plan.json\" || exit 1; fi\n"
    "# 3) now run P2 → P4 only (P1 is done above; planning again would undo the repair); GSAP for the\n"
    "#    premium comp: cp \"$GSAP\" \"$PW/comp/gsap.min.js\" \"$PW/comp/compositions/\"\n"
)
# P1 validates full coverage; only then remove CTA cues, repair the remaining
# phrases, and render. Keep the later clamps and final guards as defence in depth.
_CAPTION_PHRASES_PIP_P1_NOTE = _CAPTION_PHRASES_PIP_P1_NOTE_WI279.replace(
    '# 2) WI2.76/WI2.78:',
    _PIP_TAIL_WORDS_CLAMP
    + 'python3 work/clamp_captions.py plan work/premium/plan.json || exit 1\n'
    + '# 2) WI2.76/WI2.78:',
    1,
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
    Spotlight 03-plan-edit.md / pip 05-composite.md, plus the pip .hub/c-reel-premium
    P1 caption rule (WI2.78). WI2.79: the pip P1 note replaces the WI2.64
    "run P1 → P4" line, so nothing after the repair invites a second P1.
    The vendored .hub/p-reels-pip copy uses that same note, whether or not the
    caption-phrase section was already in the file.
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
        # WI2.79: the hub copy uses the same P1 note as the top-level step.
        new = new.replace(_CAPTION_PHRASES_PIP_P1_NOTE_WI279,
                          _CAPTION_PHRASES_PIP_P1_NOTE, 1)
        # The note replaces the "run P1 → P4" line (also over a WI2.78 note + that line).
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
        hub = directory / ".hub" / "p-reels-pip"
        if hub.is_dir():
            changed += apply_reel_caption_phrases(hub, "p-reels-pip")
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


# WI2.73: the c-typing-ui chat mock-up ended typing at DURATION*0.88/TYPING_SPEED, clamped only to
# DURATION-0.4. A short scene (under ~4.2 s) or a slow TYPING_SPEED left the finished line on
# screen for 0.4 s or less, so the cut came right after (or, with a rounded clip, before) the last
# characters. The window is now one function: typing ends TYPING_HOLD (0.6 s, so at least 0.5 s
# of rendered frames) before the clip ends, and a clip too short to type in shows the whole line.
TYPING_SCENE_FILE = Path("templates") / "typing-scene.html"
TYPING_SKILL_FILE = Path("SKILL.md")
_TYPING_WINDOW_OLD = (
    "    // Typing: starts at 0.5s, finishes at DURATION * 0.88 (settled before clip ends)\n"
    "    var typeStart = 0.5;\n"
    "    var typeEnd   = Math.max(typeStart + 0.5, DURATION * 0.88 / TYPING_SPEED);\n"
    "    // Clamp typeEnd so it doesn't exceed clip duration\n"
    "    typeEnd = Math.min(typeEnd, DURATION - 0.4);\n"
)
TYPING_WINDOW_JS = (
    "    // Typing window (WI2.73): typing starts at 0.5 s and the whole prompt stays on screen for\n"
    "    // TYPING_HOLD seconds before the clip ends, whatever the duration or TYPING_SPEED. A clip too\n"
    "    // short to type in shows the whole prompt at once (never a half-typed line at the cut).\n"
    "    var TYPING_HOLD = 0.6;\n"
    "    function typingWindow(duration, speed) {\n"
    "      if (!(speed > 0)) speed = 1.0;\n"
    "      if (!(duration > 0)) return { start: 0, end: 0 };\n"
    "      var latest = Math.max(0, duration - TYPING_HOLD);\n"
    "      var start = Math.min(0.5, latest / 2);\n"
    "      var end = Math.max(start + 0.5, duration * 0.88 / speed);\n"
    "      end = Math.min(end, latest);\n"
    "      if (end < start) end = start;\n"
    "      return { start: start, end: end };\n"
    "    }\n"
    "    var typeWin   = typingWindow(DURATION, TYPING_SPEED);\n"
    "    var typeStart = typeWin.start;\n"
    "    var typeEnd   = typeWin.end;\n"
)
_TYPING_SKILL_ANCHOR = "- `data-duration` drives clip length — GSAP timeline length is irrelevant.\n"
_TYPING_SKILL_NOTE = (
    "- Typing always finishes 0.6 s before the clip ends (`typingWindow()`, WI2.73), so the full prompt\n"
    "  is on screen before the cut at any `DURATION` / `TYPING_SPEED`; a clip too short to type in shows\n"
    "  the whole prompt. Keep `{{DURATION}}` equal to the clip's `data-duration`.\n"
)


def apply_typing_hold(directory: Path, recipe: str) -> int:
    """WI2.73: every c-typing-ui copy under `directory` (.hub/c-typing-ui, at any depth) holds the
    finished prompt before the cut. Idempotent; fails fast when a copy lost its anchor."""
    changed = 0
    if not directory.is_dir():
        return 0
    for comp in sorted(p for p in directory.rglob("c-typing-ui") if p.is_dir() and p.parent.name == ".hub"):
        tpl = comp / TYPING_SCENE_FILE
        if tpl.is_file():
            text = tpl.read_text(encoding="utf-8")
            if TYPING_WINDOW_JS not in text:
                if _TYPING_WINDOW_OLD not in text:
                    raise SystemExit(f"sync-skills.py: ERROR - typing window not found in {tpl} ({recipe}); "
                                     "the WI2.73 transform cannot apply")
                tpl.write_text(text.replace(_TYPING_WINDOW_OLD, TYPING_WINDOW_JS, 1), encoding="utf-8")
                changed += 1
        doc = comp / TYPING_SKILL_FILE
        if doc.is_file():
            text = doc.read_text(encoding="utf-8")
            if _TYPING_SKILL_NOTE not in text:
                if _TYPING_SKILL_ANCHOR not in text:
                    raise SystemExit(f"sync-skills.py: ERROR - data-duration gotcha not found in {doc} ({recipe}); "
                                     "the WI2.73 transform cannot apply")
                doc.write_text(text.replace(_TYPING_SKILL_ANCHOR, _TYPING_SKILL_ANCHOR + _TYPING_SKILL_NOTE, 1),
                               encoding="utf-8")
                changed += 1
    return changed


# WI2.80: step 04 of the pip (and split) recipes told the agent to run
# `$TYPING_UI_DIR/scripts/render.sh --text ... --duration ...`. No c-typing-ui copy ships that
# script (only scripts/render-sample.sh, which renders a fixed demo and takes just an output dir),
# so every agent had to work the render out by hand. c-typing-ui is a template component: the real
# usage is "fill templates/typing-scene.html (or hook-scene.html), copy gsap.min.js beside it, then
# hyperframes lint + render", which is what its SKILL.md "standalone render" block shows. The step
# files now say exactly that, and the c-typing-ui SKILL.md describes the shipped timing
# (typingWindow(duration, speed), WI2.73) and the proxy counter instead of a #char-count element the
# template never had. Its usage block also writes newlines as &#10; (a raw newline inside the
# template's JS string literal is a syntax error), fills BOTTOM_TAG_DISPLAY and copies gsap.min.js.
_STEP_TYPING_RENDER_EDITS = {
    "04-build-background.md": (
        "- **`graphics`, typing / hook scene** — `VARIANT=pip-safe` with `c-typing-ui`:\n"
        "  `bash \"$TYPING_UI_DIR/scripts/render.sh\" --text \"<copy>\" --duration \"$DUR\" --brand work/brand.json"
        " --variant pip-safe --out work/bg_beats/bg_beat$i.mp4` (see `$TYPING_UI_DIR/SKILL.md` for the exact flags).\n",
        "- **`graphics`, typing / hook scene** — `c-typing-ui` ships templates, not a render script (its\n"
        "  `scripts/render-sample.sh` only renders a fixed demo). Fill the template the way\n"
        "  `$TYPING_UI_DIR/SKILL.md` \"Usage — standalone render (one beat)\" does: take\n"
        "  `$TYPING_UI_DIR/templates/typing-scene.html` (typing) or `hook-scene.html` (hook), strip the\n"
        "  `<template>` wrapper, fill every `{{FIELD}}` in it, wrap it in a full 1080×1920 document and\n"
        "  write `work/gfx_$i/index.html`. Typing: `DURATION=$DUR`, `PROMPT` = the copy HTML-escaped with\n"
        "  `&#10;` for each newline, `VARIANT=pip-safe`, `ACCENT` = `work/brand.json` accent without `#`,\n"
        "  `LABEL`, `TYPING_SPEED` (`1.0`), `BOTTOM_TAG` and `BOTTOM_TAG_DISPLAY` (`display:none` when the\n"
        "  tag is blank, else empty). Hook: `DURATION`, `EYEBROW`, `LINE1`–`LINE3`, `SUBHEAD`, `ACCENT` (the\n"
        "  hook template has no `VARIANT`). Copy `$GSAP` in as `gsap.min.js`; then\n"
        "  `( cd work/gfx_$i && npx hyperframes@0.7.5 lint && npx hyperframes@0.7.5 render --output"
        " ../bg_beats/bg_beat$i.mp4 --quality high --fps 30 )`.\n",
    ),
    "04-build-top.md": (
        "- **`graphics`, typing / hook scene** — `bash \"$TYPING_UI_DIR/scripts/render.sh\" --text \"<copy>\""
        " --duration \"$DUR\" --brand work/brand.json --variant top-half --out work/top_beats/top_beat$i.mp4`"
        " (see `$TYPING_UI_DIR/SKILL.md`); if `top-half` is unsupported, render `pip-safe` and crop:"
        " `-vf crop=1080:960:0:0`.\n",
        "- **`graphics`, typing / hook scene** — `c-typing-ui` ships templates, not a render script (its\n"
        "  `scripts/render-sample.sh` only renders a fixed demo), and it has no `top-half` variant. Fill\n"
        "  `$TYPING_UI_DIR/templates/typing-scene.html` (typing: `VARIANT=pip-safe`, `BOTTOM_TAG` blank —\n"
        "  the pip-safe tag sits at y=980, below the crop) or `hook-scene.html` (hook) into\n"
        "  `work/gfx_$i/index.html` exactly as `$TYPING_UI_DIR/SKILL.md` \"Usage — standalone render (one\n"
        "  beat)\" shows, copy `$GSAP` in as `gsap.min.js`, render it at 1080×1920 with\n"
        "  `( cd work/gfx_$i && npx hyperframes@0.7.5 lint && npx hyperframes@0.7.5 render --output"
        " ../top_beats/_full$i.mp4 --quality high --fps 30 )`, then keep the top half:\n"
        "  `ffmpeg -y -i work/top_beats/_full$i.mp4 -vf crop=1080:960:0:0,format=yuv420p -an -c:v libx264"
        " -preset medium -crf 20 work/top_beats/top_beat$i.mp4`.\n",
    ),
}
# (old, new) pairs for every c-typing-ui SKILL.md copy. Each pair is applied once: a copy that
# already has `new` is left alone, a copy with neither fails fast.
_TYPING_SKILL_RENDER_EDITS = (
    (
        "| `{{TYPING_SPEED}}` | No | `1.0` | Multiplier (0.5 = slow, 2.0 = fast). Characters typed ="
        " `text.length × speed` per duration. |\n",
        "| `{{TYPING_SPEED}}` | No | `1.0` | Multiplier (0.5 = slow, 2.0 = fast). The whole prompt is"
        " always typed: `typingWindow(duration, speed)` starts at 0.5 s and ends at"
        " `duration × 0.88 / speed`, never later than 0.6 s before the clip ends. |\n",
    ),
    (
        "## Usage — standalone render (one beat)\n\n",
        "## Usage — standalone render (one beat)\n\n"
        "There is no per-beat render script: `scripts/render-sample.sh` renders a fixed demo only (it takes\n"
        "just an output folder). To render a beat, fill the template, put `gsap.min.js` beside it, then lint\n"
        "and render with HyperFrames:\n\n",
    ),
    (
        "No fake compliments.\"),\n",
        "No fake compliments.\").replace(\"\\n\", \"&#10;\"),  # newlines as &#10; (JS string literal)\n",
    ),
    (
        "    \"BOTTOM_TAG\":   \"research · personalise · send\",\n",
        "    \"BOTTOM_TAG\":   \"research · personalise · send\",\n"
        "    \"BOTTOM_TAG_DISPLAY\": \"\",  # \"display:none\" when BOTTOM_TAG is blank\n",
    ),
    (
        "cd \"$BEAT_DIR\" && npx hyperframes@0.7.5 lint",
        "cp \"$SKILL_DIR/../f-gsap/vendor/gsap.min.js\" \"$BEAT_DIR/\"  # the template loads gsap.min.js from its folder\n"
        "cd \"$BEAT_DIR\" && npx hyperframes@0.7.5 lint",
    ),
    (
        "- Typing is driven by a **stepped GSAP counter** (not TextPlugin) for frame-stability under headless"
        " chromium.\n"
        "  Counter tween on `#char-count` from `0` to `text.length`, ease `none`, then sliced in a"
        " `gsap.ticker.add`.\n"
        "  A GSAP `ticker` is NOT used in final form — the count proxy is tweened and read at each GSAP scrub"
        " position.\n",
        "- Typing is driven by a **stepped GSAP counter** (not TextPlugin) for frame-stability under headless"
        " chromium.\n"
        "  A plain `proxy = { n: 0 }` object is tweened from `0` to the prompt length (ease `none`) over\n"
        "  `typingWindow()`; its `onUpdate` writes `PROMPT_TEXT.slice(0, Math.round(n))` into `#ts-typed`.\n"
        "  No `gsap.ticker` and no counter element are used.\n",
    ),
)


def _apply_text_edits(path: Path, edits, recipe: str, what: str) -> bool:
    text = path.read_text(encoding="utf-8")
    new_text = text
    for old, new in edits:
        if new in new_text:
            continue
        if new_text.count(old) != 1:
            raise SystemExit(f"sync-skills.py: ERROR - {what} anchor {old.splitlines()[0][:70]!r} found "
                             f"{new_text.count(old)} time(s) in {path} ({recipe}); the WI2.80 transform cannot apply")
        new_text = new_text.replace(old, new, 1)
    if new_text != text:
        path.write_text(new_text, encoding="utf-8")
        return True
    return False


def apply_typing_render_usage(directory: Path, recipe: str) -> int:
    """WI2.80: pip/split step 04 copies (top-level and .hub) describe the real c-typing-ui render
    (fill the template + hyperframes render), and every c-typing-ui SKILL.md copy describes the
    shipped timing. Idempotent; fails fast when a copy lost its anchor."""
    changed = 0
    if not directory.is_dir():
        return 0
    for name, (old, new) in _STEP_TYPING_RENDER_EDITS.items():
        for step in sorted(p for p in directory.rglob(name) if p.is_file() and p.parent.name == "steps"):
            if _apply_text_edits(step, [(old, new)], recipe, "typing render step"):
                changed += 1
    for comp in sorted(p for p in directory.rglob("c-typing-ui") if p.is_dir() and p.parent.name == ".hub"):
        doc = comp / TYPING_SKILL_FILE
        if doc.is_file() and _apply_text_edits(doc, _TYPING_SKILL_RENDER_EDITS, recipe, "c-typing-ui SKILL.md"):
            changed += 1
    return changed


# WI2.83: the spotlight takeover "big stat" card set the stat at a fixed 340 px. A stat such as
# "100,000" is ~1200 px wide at that size, so it ran past both frame edges (smoke 23b, 2026-10-21).
# The stat now stays on one line and the page fits it: it measures the rendered width and scales the
# font size down from the 340 px design size until the stat is no wider than STAT_MAX_W. 900 px =
# (1080 - 2x72) / 1.03 rounded down: the 936 px padded width, less room for the 1.03 breathe.
# A stat that already fits keeps the design size. It refits once web fonts finish loading, because
# the first measurement can run on a fallback font.
SPOTLIGHT_STAT_FILE = Path("templates") / "tk-stat.html"
SPOTLIGHT_STAT_MAX_W = 900
_SPOTLIGHT_STAT_CSS_OLD = (
    "      #{{ID}} .stat {\n"
    "        font-weight: 700; font-size: 340px; line-height: 0.9;\n"
)
SPOTLIGHT_STAT_CSS = (
    "      #{{ID}} .stat {\n"
    "        font-weight: 700; font-size: 340px; line-height: 0.9;\n"
    "        white-space: nowrap;  /* WI2.83: one line; the script fits it to the safe width */\n"
)
_SPOTLIGHT_STAT_JS_OLD = (
    "        var tl = gsap.timeline({ paused: true });\n"
    "\n"
    "        // Ambient — glow breathes; ring expands and fades out once. Nothing static.\n"
)
SPOTLIGHT_STAT_FIT_JS = (
    "        // WI2.83: fit the stat to the safe width. 340px is the design size; a long stat\n"
    "        // (\"100,000\") is scaled down until it is no wider than STAT_MAX_W (1080 minus the\n"
    "        // 72px side padding, with room for the 1.03 breathe). Refit once fonts load.\n"
    "        var STAT_SIZE = 340, STAT_MAX_W = " + str(SPOTLIGHT_STAT_MAX_W) + ";\n"
    "        function fitStat(el, base, maxW) {\n"
    "          el.style.fontSize = base + \"px\";\n"
    "          var w = el.scrollWidth;\n"
    "          if (w <= maxW) return base;\n"
    "          var size = Math.floor(base * maxW / w);\n"
    "          el.style.fontSize = size + \"px\";\n"
    "          while (size > 8 && el.scrollWidth > maxW) { size -= 2; el.style.fontSize = size + \"px\"; }\n"
    "          return size;\n"
    "        }\n"
    "        var statEl = document.querySelector(scope + \".js-stat\");\n"
    "        fitStat(statEl, STAT_SIZE, STAT_MAX_W);\n"
    "        if (document.fonts && document.fonts.ready) {\n"
    "          document.fonts.ready.then(function () { fitStat(statEl, STAT_SIZE, STAT_MAX_W); });\n"
    "        }\n"
    "\n"
)
# WI2.85: the fitted stat still slammed in from a fixed scale 2.4, so a fitted "100,000" (~900 px)
# started ~2160 px wide and clipped both frame edges in the first frames (final_checks refusal,
# 2026-10-21). The slam now starts at min(2.4, 936 / fitted width): 936 px = 1080 - 2x72 side padding.
# A short stat ("3X") keeps the full 2.4 slam. The start scale is a function value: GSAP reads it once
# when the tween records its start (at build, after the WI2.83 fit). The WI2.83 fonts refit can change
# the width, so a second fonts.ready handler (it runs after the refit) re-measures once and invalidates
# the timeline, so the next seek re-records the slam from the final measurement. Seek-safe: no
# per-frame layout read. These edits leave the WI2.83 text intact, so both stay idempotent.
SPOTLIGHT_SLAM_SCALE = 2.4
SPOTLIGHT_SLAM_MAX_W = 936
_SPOTLIGHT_SLAM_OLD = (
    "        // The slam: stat punches in oversized then settles with a soft breathe.\n"
    "        tl.fromTo(scope + \".js-stat\", { scale: 2.4, opacity: 0 },\n"
)
SPOTLIGHT_SLAM_JS = (
    "        // The slam: stat punches in oversized then settles with a soft breathe.\n"
    "        // WI2.85: start at 2.4x, capped so the slam's first frame is no wider than SLAM_MAX_W\n"
    "        // (1080 minus 2x72px side padding). A short stat (\"3X\") keeps the full 2.4x slam.\n"
    "        var SLAM_SCALE = " + str(SPOTLIGHT_SLAM_SCALE) + ", SLAM_MAX_W = " + str(SPOTLIGHT_SLAM_MAX_W) + ";\n"
    "        function slamCap() { return Math.min(SLAM_SCALE, SLAM_MAX_W / Math.max(1, statEl.scrollWidth)); }\n"
    "        var slamFrom = slamCap();\n"
    "        tl.fromTo(scope + \".js-stat\", { scale: function () { return slamFrom; }, opacity: 0 },\n"
)
_SPOTLIGHT_SLAM_REG_OLD = "        window.__timelines[\"{{ID}}\"] = tl;\n"
SPOTLIGHT_SLAM_REFIT_JS = (
    "        // WI2.85: after the fonts refit above, re-measure the fitted stat once and re-record the slam.\n"
    "        if (document.fonts && document.fonts.ready) {\n"
    "          document.fonts.ready.then(function () { slamFrom = slamCap(); tl.invalidate(); });\n"
    "        }\n"
    "\n"
)
_SPOTLIGHT_SLAM_EDITS = (
    (_SPOTLIGHT_SLAM_OLD, SPOTLIGHT_SLAM_JS),
    (_SPOTLIGHT_SLAM_REG_OLD, SPOTLIGHT_SLAM_REFIT_JS + _SPOTLIGHT_SLAM_REG_OLD),
)
_SPOTLIGHT_STAT_EDITS = (
    (_SPOTLIGHT_STAT_CSS_OLD, SPOTLIGHT_STAT_CSS),
    (_SPOTLIGHT_STAT_JS_OLD, SPOTLIGHT_STAT_FIT_JS + _SPOTLIGHT_STAT_JS_OLD),
) + _SPOTLIGHT_SLAM_EDITS


def apply_spotlight_stat_fit(directory: Path, recipe: str) -> int:
    """WI2.83: every p-reels-spotlight tk-stat.html copy under `directory` (top-level or
    .hub/p-reels-spotlight) fits the stat to the safe width, and (WI2.85) caps the slam-in start
    scale so the slam stays inside it too. Idempotent; fails fast when a copy lost its anchor, or
    when a spotlight recipe ships no tk-stat.html at all."""
    changed = 0
    if not directory.is_dir():
        return 0
    roots = [directory] if directory.name == "p-reels-spotlight" else []
    roots += sorted(p for p in directory.rglob("p-reels-spotlight") if p.is_dir() and p.parent.name == ".hub")
    tpls = [r / SPOTLIGHT_STAT_FILE for r in roots if (r / SPOTLIGHT_STAT_FILE).is_file()]
    if recipe.startswith("p-reels-spotlight") and not tpls:
        raise SystemExit(f"sync-skills.py: ERROR - no p-reels-spotlight {SPOTLIGHT_STAT_FILE} under {directory} "
                         f"({recipe}); the WI2.83 transform cannot apply")
    for tpl in tpls:
        text = tpl.read_text(encoding="utf-8")
        new_text = text
        for old, new in _SPOTLIGHT_STAT_EDITS:
            if new in new_text:
                continue
            if new_text.count(old) != 1:
                raise SystemExit(f"sync-skills.py: ERROR - tk-stat anchor {old.strip().splitlines()[0][:60]!r} "
                                 f"found {new_text.count(old)} time(s) in {tpl} ({recipe}); "
                                 "the WI2.83/WI2.85 transform cannot apply")
            new_text = new_text.replace(old, new, 1)
        if new_text != text:
            tpl.write_text(new_text, encoding="utf-8")
            changed += 1
    return changed


# WI2.86: the spotlight end card started at bed - cta_duration, a fixed time that ignores the words.
# The closing line ("...this was built for you.", 38.50-41.60 s) kept playing over the card with no
# face and no captions from ~39.0 s (re-smoke 24, 2026-10-21). The card now starts at
# max(bed - cta_duration, last spoken word end), from the transcript words and the plan's caption
# words, and covers the rest of the bed. The card is rendered at that shorter length. The bed is
# sealed and the assembled reel must equal it, so nothing is appended: when less than
# SPOTLIGHT_CTA_MIN_S of bed is left after the last word, the card is skipped with a log line.
SPOTLIGHT_ASSEMBLE_FILE = Path("steps") / "06-assemble.md"
SPOTLIGHT_CTA_MIN_S = 1.0
_SPOTLIGHT_CTA_PRODUCE_OLD = """  duration: graded picture, captions burned, SFX under the voice, end card over the last
  `cta_duration` seconds. No cover frame yet — that is the final step.
"""
SPOTLIGHT_CTA_PRODUCE = """  duration: graded picture, captions burned, SFX under the voice, end card over the last
  `cta_duration` seconds, but never before the last spoken word ends (WI2.86). No cover frame
  yet — that is the final step.
"""
_SPOTLIGHT_CTA_DOC_OLD = """Resolve the copy: `inputs/cta/cta.json` wins; otherwise `brief.json.brand`. **No handle → no
handle line.** Never invent a handle or reuse another brand's.
"""
SPOTLIGHT_CTA_DOC = _SPOTLIGHT_CTA_DOC_OLD + """
**The card never covers speech (WI2.86).** It starts at `max(bed − cta_duration, last word end)`,
where the last word end is the latest `end` in `work/words.json` or `e` in the plan's
`caption_groups`, so the closing line keeps the face and its captions. The card covers the rest
of the bed and is rendered at that length. Nothing is appended: when less than
""" + str(SPOTLIGHT_CTA_MIN_S) + """ s of bed is left after the last word, the card is skipped with one log line.
"""
_SPOTLIGHT_CTA_IF_OLD = """if [ "$CTA_CARD" = "on" ]; then
  CTA_DURATION="$CTA_DURATION" CTA_TEXT="$CTA_TEXT" """
SPOTLIGHT_CTA_START = """# WI2.86: start the card only after the last spoken word ends; it covers the rest of the bed.
CTA_START=""
if [ "$CTA_CARD" = "on" ]; then
  CTA_START=$(python3 - "$BED_DUR" "$CTA_DURATION" <<'PY'
import json, sys
bed, want = float(sys.argv[1]), float(sys.argv[2])
ends = [float(w["end"]) for w in json.load(open("work/words.json")) if isinstance(w, dict) and "end" in w]
for g in json.load(open("work/plan.json")).get("caption_groups") or []:
    ends += [float(w["e"]) for w in g.get("words") or [] if isinstance(w, dict) and "e" in w]
if not ends:
    sys.exit("end card: no word timings in work/words.json or the plan caption groups")
print("%.3f" % max(bed - want, max(ends)))
PY
  ) || exit 1
  CTA_DURATION=$(python3 -c "print('%.3f' % max(0.0, ${BED_DUR} - ${CTA_START}))")
  if python3 -c "import sys; sys.exit(0 if ${CTA_DURATION} < """ + str(SPOTLIGHT_CTA_MIN_S) + """ else 1)"; then
    echo "[spotlight] end card skipped: only ${CTA_DURATION}s of bed after the last spoken word (needs """ + str(SPOTLIGHT_CTA_MIN_S) + """s)"
    CTA_CARD=off
  fi
fi
"""
_SPOTLIGHT_CTA_START_OLD = """  CTA_START=$(python3 -c "print(${BED_DUR} - ${CTA_DURATION})")
"""
SPOTLIGHT_CTA_START_SET = """  # CTA_START and CTA_DURATION were set above (WI2.86): the card starts after the last word.
"""
_SPOTLIGHT_CTA_CHECK_OLD = """  present) plus the end-card window, `volumedetect` on `saves/assembled_video.mp4` reports a real
"""
SPOTLIGHT_CTA_CHECK = """  present), `volumedetect` on `saves/assembled_video.mp4` reports a real
"""
_SPOTLIGHT_CTA_EDITS = (
    (_SPOTLIGHT_CTA_PRODUCE_OLD, SPOTLIGHT_CTA_PRODUCE),
    (_SPOTLIGHT_CTA_DOC_OLD, SPOTLIGHT_CTA_DOC),
    (_SPOTLIGHT_CTA_IF_OLD, SPOTLIGHT_CTA_START + _SPOTLIGHT_CTA_IF_OLD),
    (_SPOTLIGHT_CTA_START_OLD, SPOTLIGHT_CTA_START_SET),
    (_SPOTLIGHT_CTA_CHECK_OLD, SPOTLIGHT_CTA_CHECK),
)


def apply_spotlight_end_card(directory: Path, recipe: str) -> int:
    """WI2.86: every p-reels-spotlight steps/06-assemble.md copy under `directory` (the top-level
    step of p-reels-spotlight / p-reels-spotlight-heygen, and .hub/p-reels-spotlight) starts the end
    card only after the last spoken word ends. Idempotent; fails fast when a copy lost its anchor,
    or when a spotlight recipe ships no assemble step at all."""
    changed = 0
    if not directory.is_dir():
        return 0
    roots = [directory] if directory.name.startswith("p-reels-spotlight") else []
    roots += sorted(p for p in directory.rglob("p-reels-spotlight") if p.is_dir() and p.parent.name == ".hub")
    steps = [r / SPOTLIGHT_ASSEMBLE_FILE for r in roots if (r / SPOTLIGHT_ASSEMBLE_FILE).is_file()]
    if recipe.startswith("p-reels-spotlight") and not steps:
        raise SystemExit(f"sync-skills.py: ERROR - no p-reels-spotlight {SPOTLIGHT_ASSEMBLE_FILE} under {directory} "
                         f"({recipe}); the WI2.86 transform cannot apply")
    for step in steps:
        text = step.read_text(encoding="utf-8")
        new_text = text
        for old, new in _SPOTLIGHT_CTA_EDITS:
            if new in new_text:
                continue
            if new_text.count(old) != 1:
                raise SystemExit(f"sync-skills.py: ERROR - assemble anchor {old.strip().splitlines()[0][:60]!r} "
                                 f"found {new_text.count(old)} time(s) in {step} ({recipe}); "
                                 "the WI2.86 transform cannot apply")
            new_text = new_text.replace(old, new, 1)
        if new_text != text:
            step.write_text(new_text, encoding="utf-8")
            changed += 1
    return changed


# WI2.89: after WI2.86 the end card starts only after the last spoken word, but the bed was the bare
# clip. When the speech runs to the end (re-smoke clip: bed 41.67 s, last word 41.60 s), step 06 had
# no room and skipped the card: the reel shipped with no CTA. Step 01 (and SKILL.md Step 2) now hold
# the last frame with silence so cta_duration + SPOTLIGHT_TAIL_MARGIN_S follows the speech end
# (tail at most SPOTLIGHT_TAIL_MAX_S). The tail is part of the sealed bed, so step 06 shows the full
# card right after the last word. The transcript/caption tail tolerances become 4.5 s (3.5 s tail
# plus timing slack) and the reel window 65 s (60 s of speech + 3.5 s tail + 0.4 s cover).
SPOTLIGHT_TAIL_MARGIN_S = 0.5
SPOTLIGHT_TAIL_MAX_S = 3.5
SPOTLIGHT_TAIL_PY = """# WI2.89: hold the last frame with silence so the end card fits after the last spoken word.
import math, os, re, subprocess, sys
src, card, want = sys.argv[1], sys.argv[2], float(sys.argv[3])
MARGIN, MAX_TAIL = """ + str(SPOTLIGHT_TAIL_MARGIN_S) + ", " + str(SPOTLIGHT_TAIL_MAX_S) + """   # speech end + cta_duration + MARGIN, tail at most MAX_TAIL
def dur(p):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", p],
                         capture_output=True, text=True, check=True).stdout.strip()
    return float(out)
if card != "on":
    print("[spotlight] end-card tail: cta_card off, no tail"); sys.exit(0)
d = dur(src)
log = subprocess.run(["ffmpeg", "-hide_banner", "-i", src, "-af", "silencedetect=noise=-40dB:d=0.3", "-f", "null", "-"],
                     capture_output=True, text=True).stderr
starts = [float(x) for x in re.findall(r"silence_start: (-?[0-9.]+)", log)]
ends = [float(x) for x in re.findall(r"silence_end: (-?[0-9.]+)", log)]
speech_end = d                       # no silence runs to the end: the speech fills the clip
if starts and (len(ends) < len(starts) or ends[-1] >= d - 0.05):
    speech_end = max(0.0, starts[-1])
tail = math.ceil(max(0.0, min(want + MARGIN, MAX_TAIL) - (d - speech_end)) * 30) / 30
if tail <= 0:
    print("[spotlight] end-card tail: %.2fs of silence already follows the speech, no tail" % (d - speech_end)); sys.exit(0)
tmp = src[:-4] + "-tail.mp4"
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-vf", "tpad=stop_mode=clone:stop_duration=%.3f" % tail,
                "-af", "apad=pad_dur=%.3f" % tail, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", "30",
                "-c:a", "aac", "-ar", "48000", "-ac", "2", tmp], check=True)
got = dur(tmp)
if abs(got - (d + tail)) > 0.1:
    sys.exit("end-card tail: bed is %.3fs, expected %.3fs" % (got, d + tail))
os.replace(tmp, src)
print("[spotlight] end-card tail: speech ends %.2fs, held the last frame + silence for %.2fs (bed %.2fs)" % (speech_end, tail, got))
"""
SPOTLIGHT_TAIL_PROSE = """The end card never covers speech (WI2.86), so the bed needs room after the last spoken word.
When the speech runs to the end of the clip (or nearly), hold the last frame with silence until
`cta_duration` + """ + str(SPOTLIGHT_TAIL_MARGIN_S) + """ s follows the speech end (a tail of at most """ + str(SPOTLIGHT_TAIL_MAX_S) + """ s). The speech end is
where the final silence starts (`silencedetect` −40 dB, 0.3 s); with no trailing silence it is
the clip end. `cta_card: off` adds no tail, and a clip that already ends in enough silence is
left as it is. The tail is part of the sealed bed: captions, takeovers, checks and the reel all
time against it, and the end card then shows in full right after the last word.
"""
_SPOTLIGHT_SEAL_OLD = "### 5. Seal and save\n"
SPOTLIGHT_TAIL_STEP = ("### 4b. Give the end card a silent tail (WI2.89)\n\n" + SPOTLIGHT_TAIL_PROSE + """
```bash
opt () { python3 -c "import json; print(json.load(open('brief.json')).get('options',{}).get('$1','$2'))"; }
python3 - work/base.mp4 "$(opt cta_card on)" "$(opt cta_duration 3.0)" <<'PY' || exit 1
""" + SPOTLIGHT_TAIL_PY + """PY
```

""")
_SPOTLIGHT_BED_DUR_OLD = "csv=p=0 saves/voice_track.mp4                             # 20–60 s\n"
SPOTLIGHT_BED_DUR = "csv=p=0 saves/voice_track.mp4                             # 20–64 s (with the WI2.89 tail)\n"
_SPOTLIGHT_TRANSCRIBE_OLD = "the last `end` within ~3 s of the\n  bed duration.\n"
SPOTLIGHT_TRANSCRIBE = ("the last `end` within ~4.5 s of the\n  bed duration (the bed ends in a silent end-card tail of up to "
                        + str(SPOTLIGHT_TAIL_MAX_S) + " s, WI2.89).\n")
_SPOTLIGHT_PLAN_ASSERT_OLD = 'assert abs(p["caption_groups"][-1]["end"] - dur) < 3.0, "captions do not cover the bed"\n'
SPOTLIGHT_PLAN_ASSERT = ('# WI2.89: the bed ends in a silent end-card tail (at most ' + str(SPOTLIGHT_TAIL_MAX_S) + ' s), so allow 4.5 s.\n'
                         'assert abs(p["caption_groups"][-1]["end"] - dur) < 4.5, "captions do not cover the bed"\n')
_SPOTLIGHT_PLAN_DOC_OLD = "groups cover the bed to within 3 s"
SPOTLIGHT_PLAN_DOC = "groups cover the bed to within 4.5 s (its silent end-card tail, WI2.89)"
_SPOTLIGHT_SHARED_EDITS = (
    ("ends on a branded CTA end card that overlays the last seconds of the bed (nothing is appended).\n",
     "ends on a branded CTA end card right after the last spoken word, over the bed's silent tail\n"
     "(step 01 holds the last frame with silence so the full card fits, WI2.89; nothing is appended\n"
     "after the bed).\n"),
    ("| `cta_card` | `on` | End-card takeover over the final `cta_duration` seconds. `off` skips it. |\n",
     "| `cta_card` | `on` | End-card takeover after the last spoken word, over the bed's silent tail (WI2.89). `off` skips it and the tail. |\n"),
    ("| `cta_duration` | `3` | Seconds of bed the end card covers. |\n",
     "| `cta_duration` | `3` | Seconds the end card covers. Step 01 makes sure this much + " + str(SPOTLIGHT_TAIL_MARGIN_S)
     + " s follows the speech (a tail of at most " + str(SPOTLIGHT_TAIL_MAX_S) + " s). |\n"),
)
_SPOTLIGHT_FINAL_EDITS = (
    ("- `prior/assembled_video.mp4` — the finished reel at bed length (graded, captioned, end card).\n",
     "- `prior/assembled_video.mp4` — the finished reel at bed length (graded, captioned; with `cta_card`\n"
     "  on, the full end card right after the last spoken word, over the bed's silent tail — WI2.89).\n"),
)
_SPOTLIGHT_SKILL_TRIM_OLD = ("  echo \"[spotlight] trimmed ${TRIM_START}s of leading silence\"\nfi\n```\n\n"
                             "### Step 3 — Transcribe with WORD timestamps\n")
SPOTLIGHT_SKILL_TAIL = ("  echo \"[spotlight] trimmed ${TRIM_START}s of leading silence\"\nfi\n```\n\n"
                        "**End-card tail (WI2.89, mandatory):** " + SPOTLIGHT_TAIL_PROSE + """
```bash
python3 - "$W/base.mp4" "${CTA_CARD:-on}" "${CTA_DURATION:-3}" <<'PY' || exit 1
""" + SPOTLIGHT_TAIL_PY + """PY
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$W/base.mp4")
```

### Step 3 — Transcribe with WORD timestamps
""")
_SPOTLIGHT_SKILL_CTA_ROW_OLD = ("| `cta_card` | No | brand default | Auto-generated end-card takeover (2.5–3s) overlaying the final "
                                "2.5–3s of the bed — does NOT extend the reel. Pass `off` to skip. |\n")
SPOTLIGHT_SKILL_CTA_ROW = ("| `cta_card` | No | brand default | Auto-generated end-card takeover (`CTA_DURATION`, 3 s) right after "
                           "the last spoken word, never over speech. Step 2 holds the last frame with silence so the full card "
                           "fits (WI2.89); nothing is appended after the bed. Pass `off` to skip (no tail). |\n")
_SPOTLIGHT_SKILL_RULE_OLD = ("**Hard rule:** the CTA end-card is the **last graphics takeover** of the bed, covering the picture\n"
                             "during the speaker's spoken CTA line. Total reel duration = bed duration. Nothing is appended.\n")
SPOTLIGHT_SKILL_RULE = ("**Hard rule:** the CTA end-card is the **last graphics takeover** of the bed. It never covers\n"
                        "speech (WI2.86): it starts at `max(bed − CTA_DURATION, last word end)` and covers the rest of the\n"
                        "bed. Step 2's silent tail (WI2.89) leaves `CTA_DURATION` + " + str(SPOTLIGHT_TAIL_MARGIN_S)
                        + " s after the last word, so the full\n"
                        "card shows right after the speech. Total reel duration = bed duration. Nothing is appended.\n")
_SPOTLIGHT_SKILL_CTA_DUR_OLD = 'CTA_DURATION="${CTA_DURATION:-3.0}"\n'
SPOTLIGHT_SKILL_CTA_DUR = _SPOTLIGHT_SKILL_CTA_DUR_OLD + """BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$W/polished.mp4")
# WI2.86/WI2.89: the card starts only after the last spoken word ends and covers the rest of the bed.
CTA_START=$(python3 - "$BED_DUR" "$CTA_DURATION" "$W" <<'PY'
import json, os, sys
bed, want, w = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
ends = [float(x["end"]) for x in json.load(open(os.path.join(w, "words.json"))) if isinstance(x, dict) and "end" in x]
for g in json.load(open(os.path.join(w, "plan.json"))).get("caption_groups") or []:
    ends += [float(x["e"]) for x in g.get("words") or [] if isinstance(x, dict) and "e" in x]
if not ends:
    sys.exit("end card: no word timings in words.json or the plan caption groups")
print("%.3f" % max(bed - want, max(ends)))
PY
) || exit 1
CTA_DURATION=$(python3 -c "print('%.3f' % max(0.0, ${BED_DUR} - ${CTA_START}))")
python3 -c "import sys; sys.exit(0 if ${CTA_DURATION} >= 1.0 else 'end card: only ${CTA_DURATION}s of bed after the last spoken word; the Step 2 end-card tail (WI2.89) is missing')" || exit 1
"""
_SPOTLIGHT_SKILL_CTA_START_OLD = ('BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$W/polished.mp4")\n'
                                  'CTA_START=$(python3 -c "print(${BED_DUR} - ${CTA_DURATION})")\n')
SPOTLIGHT_SKILL_CTA_START = "# BED_DUR, CTA_START and CTA_DURATION were set above (WI2.86/WI2.89): the card follows the last word.\n"
_SPOTLIGHT_SKILL_ASSERT_OLD = 'assert abs(p["caption_groups"][-1]["end"]-dur) < 3.0, "captions do not cover the bed"\n'
SPOTLIGHT_SKILL_ASSERT = ('# WI2.89: the bed ends in a silent end-card tail (at most ' + str(SPOTLIGHT_TAIL_MAX_S) + ' s), so allow 4.5 s.\n'
                          'assert abs(p["caption_groups"][-1]["end"]-dur) < 4.5, "captions do not cover the bed"\n')
_SPOTLIGHT_ACCEPT_EDITS = (
    ('"type": "duration_window", "min_s": 20, "max_s": 62 }', '"type": "duration_window", "min_s": 20, "max_s": 65 }'),
    ('"tail_tolerance_s": 3,', '"tail_tolerance_s": 4.5,'),
    ("last end within 3 s of the bed duration.\"",
     "last end within 4.5 s of the bed duration (the bed ends in a silent end-card tail of up to "
     + str(SPOTLIGHT_TAIL_MAX_S) + " s, WI2.89).\""),
    ('"caption_tail_tolerance_s": 3,', '"caption_tail_tolerance_s": 4.5,'),
    ("caption_groups cover the bed to within 3 s;", "caption_groups cover the bed to within 4.5 s (end-card tail, WI2.89);"),
)
# File -> edits. SKILL.md and acceptance.json only in a full p-reels-spotlight copy (the heygen wrapper's
# own SKILL.md delegates and it ships no acceptance.json); the steps in every copy.
_SPOTLIGHT_TAIL_FILES = (
    (Path("steps") / "01-prepare-footage.md", False, ((_SPOTLIGHT_SEAL_OLD, SPOTLIGHT_TAIL_STEP + _SPOTLIGHT_SEAL_OLD),
                                                      (_SPOTLIGHT_BED_DUR_OLD, SPOTLIGHT_BED_DUR))),
    (Path("steps") / "02-transcribe.md", False, ((_SPOTLIGHT_TRANSCRIBE_OLD, SPOTLIGHT_TRANSCRIBE),)),
    (Path("steps") / "03-plan-edit.md", False, ((_SPOTLIGHT_PLAN_ASSERT_OLD, SPOTLIGHT_PLAN_ASSERT),
                                                (_SPOTLIGHT_PLAN_DOC_OLD, SPOTLIGHT_PLAN_DOC))),
    (Path("steps") / "_shared.md", False, _SPOTLIGHT_SHARED_EDITS),
    (Path("steps") / "07-final-checks.md", False, _SPOTLIGHT_FINAL_EDITS),
    (Path("SKILL.md"), True, ((_SPOTLIGHT_SKILL_CTA_ROW_OLD, SPOTLIGHT_SKILL_CTA_ROW),
                              (_SPOTLIGHT_SKILL_TRIM_OLD, SPOTLIGHT_SKILL_TAIL),
                              (_SPOTLIGHT_SKILL_ASSERT_OLD, SPOTLIGHT_SKILL_ASSERT),
                              (_SPOTLIGHT_SKILL_RULE_OLD, SPOTLIGHT_SKILL_RULE),
                              (_SPOTLIGHT_SKILL_CTA_DUR_OLD, SPOTLIGHT_SKILL_CTA_DUR),
                              (_SPOTLIGHT_SKILL_CTA_START_OLD, SPOTLIGHT_SKILL_CTA_START))),
    (Path("acceptance.json"), True, _SPOTLIGHT_ACCEPT_EDITS),
)


def apply_spotlight_bed_tail(directory: Path, recipe: str) -> int:
    """WI2.89: every p-reels-spotlight copy under `directory` (the top-level p-reels-spotlight /
    p-reels-spotlight-heygen steps, and .hub/p-reels-spotlight) gives the voice bed a silent
    end-card tail in step 01, so the WI2.86 end card always fits after the last spoken word; the
    docs and the transcript/caption/reel-length tolerances follow. Idempotent; fails fast when a
    copy lost an anchor or a file, or when a spotlight recipe ships no prepare-footage step."""
    changed = 0
    if not directory.is_dir():
        return 0
    roots = [directory] if directory.name.startswith("p-reels-spotlight") else []
    roots += sorted(p for p in directory.rglob("p-reels-spotlight") if p.is_dir() and p.parent.name == ".hub")
    roots = [r for r in roots if (r / "steps" / "01-prepare-footage.md").is_file()]
    if recipe.startswith("p-reels-spotlight") and not roots:
        raise SystemExit(f"sync-skills.py: ERROR - no p-reels-spotlight steps/01-prepare-footage.md under {directory} "
                         f"({recipe}); the WI2.89 transform cannot apply")
    for root in roots:
        for rel, full_only, edits in _SPOTLIGHT_TAIL_FILES:
            if full_only and root.name != "p-reels-spotlight":
                continue
            path = root / rel
            if not path.is_file():
                raise SystemExit(f"sync-skills.py: ERROR - {path} is missing ({recipe}); the WI2.89 transform cannot apply")
            text = path.read_text(encoding="utf-8")
            new_text = text
            for old, new in edits:
                if new in new_text:
                    continue
                if new_text.count(old) != 1:
                    raise SystemExit(f"sync-skills.py: ERROR - end-card tail anchor {old.strip().splitlines()[0][:60]!r} "
                                     f"found {new_text.count(old)} time(s) in {path} ({recipe}); "
                                     "the WI2.89 transform cannot apply")
                new_text = new_text.replace(old, new, 1)
            if new_text != text:
                path.write_text(new_text, encoding="utf-8")
                changed += 1
    return changed


# WI2.87: spotlight tk-typing-ui takeover. Step 05 (and SKILL.md Step 5) stripped the <template>
# wrapper from c-typing-ui's typing-scene.html and kept its own composition id "typing-scene", while
# the root slot loads it as data-composition-src with data-composition-id="tk<i>". HyperFrames 0.7.5
# then never gets ready ("Composition has zero duration. Runtime ready: false"), the render fails,
# and the step's still-card fallback composites every takeover as a static PNG: each one hard-cuts
# straight to its final layout, with no slam-in and no typing (re-smoke 24, R-VW59, 2026-10-21).
# Each copy now keeps the wrapper, renames the scene to the slot id, scopes its ts-* ids/classes and
# its script to that slot, and fills every key the scene reads (ACCENT without '#', the prompt
# HTML-escaped as the scene expects).
SPOTLIGHT_RENDER_FILE = Path("steps") / "05-render-scenes.md"
_SPOTLIGHT_TYPING_STEP_OLD = """        src = open(f"{TYPING}/templates/typing-scene.html").read()
        src = re.sub(r'<template[^>]*>\\s*', '', src); src = re.sub(r'\\s*</template>', '', src)
"""
SPOTLIGHT_TYPING_STEP = """        # WI2.87: a data-composition-src file must stay a <template> whose composition id is the slot's.
        # Stripped and left as "typing-scene", HyperFrames never gets ready, the render fails and every
        # takeover falls back to a still card (no slam-in, no typing). Keep the wrapper, give the scene
        # this slot's id, scope its ts-* ids/classes and script to the slot, fill every key it reads.
        m["ACCENT"] = str(brand["accent"]).lstrip("#")   # the scene writes #{{ACCENT}}
        m["PROMPT"] = html.escape(str(tk["fill"].get("PROMPT", ""))).replace("\\n", "&#10;")  # decoded in-page
        for k, v in (("TYPING_SPEED", "1.0"), ("BOTTOM_TAG", ""), ("VARIANT", "full"), ("BOTTOM_TAG_DISPLAY", "")):
            m.setdefault(k, v)
        src = open(f"{TYPING}/templates/typing-scene.html").read()
        src = src[src.index('<template id="typing-scene-template">'):]   # drop the usage comment
        src = re.sub(r'(?<=[.#"])ts-', f"tk{i}-ts-", src.replace("typing-scene", f"tk{i}"))
        src = src.replace("<script>\\n", "<script>\\n(function () {\\n", 1)
        src = src.replace("\\n  </script>\\n</div>\\n</template>", "\\n})();\\n  </script>\\n</div>\\n</template>")
        assert f'<template id="tk{i}-template">' in src and f'__timelines["tk{i}"]' in src and "})();" in src, \\
            "FATAL: c-typing-ui typing-scene.html changed shape; cannot slot it as a takeover"
"""
_SPOTLIGHT_TYPING_SKILL_OLD = """        # c-typing-ui template (sub-composition form, strip <template> wrapper)
        import re as re_mod
        tpl_src = open(f"{TYPING}/templates/typing-scene.html").read()
        tpl_src = re_mod.sub(r'<template[^>]*>\\s*', '', tpl_src)
        tpl_src = re_mod.sub(r'\\s*</template>', '', tpl_src)
        # Wrap in full sub-composition structure
        tpl_content = fill(tpl_src, m)
"""
SPOTLIGHT_TYPING_SKILL = """        # WI2.87: c-typing-ui as a sub-composition KEEPS its <template> wrapper and takes this slot's
        # composition id (stripped and left as "typing-scene", HyperFrames never gets ready, the render
        # fails and every takeover falls back to a still card). Its ts-* ids/classes and script are
        # scoped to the slot, and every key it reads is filled.
        import re as re_mod
        m["ACCENT"] = str(brand["accent"]).lstrip("#")   # the scene writes #{{ACCENT}}
        m["PROMPT"] = html.escape(str(tk["fill"].get("PROMPT", ""))).replace("\\n", "&#10;")  # decoded in-page
        for k, v in (("TYPING_SPEED", "1.0"), ("BOTTOM_TAG", ""), ("VARIANT", "full"), ("BOTTOM_TAG_DISPLAY", "")):
            m.setdefault(k, v)
        tpl_src = open(f"{TYPING}/templates/typing-scene.html").read()
        tpl_src = tpl_src[tpl_src.index('<template id="typing-scene-template">'):]   # drop the usage comment
        tpl_src = re_mod.sub(r'(?<=[.#"])ts-', f"tk{i}-ts-", tpl_src.replace("typing-scene", f"tk{i}"))
        tpl_src = tpl_src.replace("<script>\\n", "<script>\\n(function () {\\n", 1)
        tpl_src = tpl_src.replace("\\n  </script>\\n</div>\\n</template>", "\\n})();\\n  </script>\\n</div>\\n</template>")
        assert f'<template id="tk{i}-template">' in tpl_src and f'__timelines["tk{i}"]' in tpl_src and "})();" in tpl_src, \\
            "FATAL: c-typing-ui typing-scene.html changed shape; cannot slot it as a takeover"
        tpl_content = fill(tpl_src, m)
"""
_SPOTLIGHT_TYPING_EDITS_STEP = ((_SPOTLIGHT_TYPING_STEP_OLD, SPOTLIGHT_TYPING_STEP),)
_SPOTLIGHT_TYPING_EDITS_SKILL = ((_SPOTLIGHT_TYPING_SKILL_OLD, SPOTLIGHT_TYPING_SKILL),)
# (file under a spotlight root, only in a full p-reels-spotlight copy (not the heygen wrapper), edits)
_SPOTLIGHT_TYPING_FILES = (
    (SPOTLIGHT_RENDER_FILE, False, _SPOTLIGHT_TYPING_EDITS_STEP),
    (Path("SKILL.md"), True, _SPOTLIGHT_TYPING_EDITS_SKILL),
)


def apply_spotlight_typing_takeover(directory: Path, recipe: str) -> int:
    """WI2.87: every p-reels-spotlight copy under `directory` (the top-level p-reels-spotlight /
    p-reels-spotlight-heygen step 05, .hub/p-reels-spotlight, and SKILL.md Step 5 of each full copy)
    slots the c-typing-ui scene as a real HyperFrames sub-composition: <template> kept, composition
    id = the slot id, ids/classes/script scoped to the slot. Idempotent; fails fast when a copy lost
    its anchor or file, or when a spotlight recipe ships no render-scenes step."""
    changed = 0
    if not directory.is_dir():
        return 0
    roots = [directory] if directory.name.startswith("p-reels-spotlight") else []
    roots += sorted(p for p in directory.rglob("p-reels-spotlight") if p.is_dir() and p.parent.name == ".hub")
    roots = [r for r in roots if (r / SPOTLIGHT_RENDER_FILE).is_file()]
    if recipe.startswith("p-reels-spotlight") and not roots:
        raise SystemExit(f"sync-skills.py: ERROR - no p-reels-spotlight {SPOTLIGHT_RENDER_FILE} under {directory} "
                         f"({recipe}); the WI2.87 transform cannot apply")
    for root in roots:
        for rel, full_only, edits in _SPOTLIGHT_TYPING_FILES:
            if full_only and root.name != "p-reels-spotlight":
                continue
            path = root / rel
            if not path.is_file():
                raise SystemExit(f"sync-skills.py: ERROR - {path} is missing ({recipe}); the WI2.87 transform cannot apply")
            text = path.read_text(encoding="utf-8")
            new_text = text
            for old, new in edits:
                if new in new_text:
                    continue
                if new_text.count(old) != 1:
                    raise SystemExit(f"sync-skills.py: ERROR - typing takeover anchor {old.strip().splitlines()[0][:60]!r} "
                                     f"found {new_text.count(old)} time(s) in {path} ({recipe}); "
                                     "the WI2.87 transform cannot apply")
                new_text = new_text.replace(old, new, 1)
            if new_text != text:
                path.write_text(new_text, encoding="utf-8")
                changed += 1
    return changed


# WI2.93: spotlight end card. Step 06 (and SKILL.md Step 8) ran `hyperframes render work/cta-card.json`,
# but hyperframes 0.7.5 `render` takes a project DIRECTORY with an index.html; it stopped with "Not a
# directory" and the step's ffmpeg drawtext fallback put in a completely still card (smoke 25, Render
# 69bc5ce, 2026-10-21: the end card 42.6-45.6 s never moved). scripts/cta-card.py now also writes the
# card as a HyperFrames project (index.html + vendored gsap.min.js; scale-pop entry, staggered words,
# arrow draw and bob, drifting glow), step 06 renders that directory, and the still fallback is gone:
# a failed render exits non-zero with the reason.
_SPOTLIGHT_CTA_HF_STEP_RENDER_OLD = r"""    python3 "$SKILL_DIR/scripts/cta-card.py" work/plan.json work/cta-card.json   # omits the handle layer when empty
  npx hyperframes@0.7.5 render work/cta-card.json --output work/cta-card.mp4 || {
    BG_HEX=$(python3 -c "import json; print(json.load(open('work/plan.json'))['brand']['bg'].lstrip('#'))")
    ACCENT_HEX=$(python3 -c "import json; print(json.load(open('work/plan.json'))['brand']['accent'].lstrip('#'))")
    FG_HEX=$(python3 -c "import json; print(json.load(open('work/plan.json'))['brand']['fg'].lstrip('#'))")
    CTA_VF="drawtext=text='${CTA_TEXT}':fontcolor=#${FG_HEX}:fontsize=64:x=(w-text_w)/2:y=760:font=Oswald"
    [ -n "$CTA_HANDLE" ] && CTA_VF="${CTA_VF},drawtext=text='${CTA_HANDLE}':fontcolor=#${ACCENT_HEX}:fontsize=48:x=(w-text_w)/2:y=900:font=Inter"
    ffmpeg -y -f lavfi -i "color=c=#${BG_HEX}:s=1080x1920:r=30:d=${CTA_DURATION}" -vf "$CTA_VF" \
      -c:v libx264 -pix_fmt yuv420p -r 30 work/cta-card.mp4
  }
"""
SPOTLIGHT_CTA_HF_STEP_RENDER = r"""    python3 "$SKILL_DIR/scripts/cta-card.py" work/plan.json work/cta-card.json \
      work/cta-card "$SKILL_DIR/.hub/f-gsap/vendor/gsap.min.js" || exit 1   # omits the handle layer when empty
  # WI2.93: hyperframes 0.7.5 renders a project DIRECTORY (work/cta-card/index.html), never the .json
  # spec ("Not a directory"). The card must animate, so there is no still FFmpeg card: a failed
  # render stops the step with the reason.
  npx hyperframes@0.7.5 render work/cta-card --fps 30 --quality high --output work/cta-card.mp4 && [ -f work/cta-card.mp4 ] \
    || { echo "end card: hyperframes render of work/cta-card failed; no still fallback card (WI2.93)" >&2; exit 1; }
"""
_SPOTLIGHT_CTA_HF_STEP_FAIL_OLD = r"""SFX file, a failed premium pass or a card render that fails even on the drawtext fallback is a
failure: exit non-zero with one plain line.
"""
SPOTLIGHT_CTA_HF_STEP_FAIL = r"""SFX file, a failed premium pass or a failed HyperFrames end-card render is a failure: exit
non-zero with one plain line. There is no still FFmpeg end card to fall back to (WI2.93).
"""
_SPOTLIGHT_CTA_HF_SKILL_RENDER_OLD = r"""  python3 "$SKILL_DIR/scripts/cta-card.py" "$W/plan.json" "$W/cta-card.json"

hyperframes render "$W/cta-card.json" "$W/cta-card.mp4" 2>/dev/null || {
  # Fallback: ffmpeg drawtext CTA card.
  # BUG FIX (bake-off #2 2026-06-12): drawtext fontsize=80 clips text at the left edge
  # on a 1080px canvas. Fix: fontsize=64 with x=(w-text_w)/2 centering.
  # NOTE: a proper HTML CTA composition is the long-term fix; this drawtext path is
  # the emergency fallback only (used when hyperframes render fails after doctor check).
  CTA_VF="drawtext=text='${CTA_TEXT}':fontcolor=#${FG_HEX}:fontsize=64:x=(w-text_w)/2:y=760:font=Oswald:fontweight=800"
  if [[ -n "${CTA_HANDLE:-}" ]]; then
    CTA_VF="${CTA_VF},drawtext=text='${CTA_HANDLE}':fontcolor=#${ACCENT_HEX}:fontsize=48:x=(w-text_w)/2:y=900:font=Inter"
  fi
  ffmpeg -y -f lavfi \
    -i "color=c=#${BG_HEX}:s=1080x1920:r=30:d=${CTA_DURATION}" \
    -vf "$CTA_VF" \
    -c:v libx264 -pix_fmt yuv420p -r 30 \
    "$W/cta-card.mp4"
}
"""
SPOTLIGHT_CTA_HF_SKILL_RENDER = r"""  python3 "$SKILL_DIR/scripts/cta-card.py" "$W/plan.json" "$W/cta-card.json" \
    "$W/cta-card" "$SKILL_DIR/.hub/f-gsap/vendor/gsap.min.js" || exit 1

# WI2.93: hyperframes 0.7.5 renders a project DIRECTORY ($W/cta-card/index.html, written by
# cta-card.py), never the .json spec ("Not a directory"). The card must animate, so there is no
# still ffmpeg drawtext card: a failed render stops the step with the reason.
npx hyperframes@0.7.5 render "$W/cta-card" --fps 30 --quality high --output "$W/cta-card.mp4" && [ -f "$W/cta-card.mp4" ] \
  || { echo "end card: hyperframes render of $W/cta-card failed; no still fallback card (WI2.93)" >&2; exit 1; }
"""
_SPOTLIGHT_CTA_HF_SKILL_NA_OLD = r"""- **(CTA fallback N/A here.)** The Step 8 CTA fallback is an ffmpeg `drawtext` card, not a HyperFrames
  composition — so the "proper HyperFrames standalone" CTA patch does not apply to this core.
"""
SPOTLIGHT_CTA_HF_SKILL_NA = r"""- **(CTA end card is a HyperFrames project, WI2.93.)** Step 8 renders `$W/cta-card/` (index.html +
  gsap.min.js written by `scripts/cta-card.py`) with `hyperframes render <dir>`; there is no ffmpeg
  `drawtext` fallback card, so a failed render fails the step.
"""
_SPOTLIGHT_CTA_HF_CTA_USAGE_OLD = r"""  python3 cta-card.py <plan.json> <out cta-card.json>
"""
SPOTLIGHT_CTA_HF_CTA_USAGE = r"""  python3 cta-card.py <plan.json> <out cta-card.json> [<project dir> <gsap.min.js>]
  With a project dir, also writes <dir>/index.html + gsap.min.js: an animated HyperFrames
  composition of the card that `hyperframes render <dir>` renders (WI2.93).
"""
_SPOTLIGHT_CTA_HF_CTA_ARGS_OLD = r"""    if len(argv) != 3:
        print("usage: cta-card.py <plan.json> <out cta-card.json>", file=sys.stderr)
        return 2
    plan_path, out_path = argv[1], argv[2]
"""
SPOTLIGHT_CTA_HF_CTA_ARGS = r"""    if len(argv) not in (3, 5):
        print("usage: cta-card.py <plan.json> <out cta-card.json> [<project dir> <gsap.min.js>]", file=sys.stderr)
        return 2
    plan_path, out_path = argv[1], argv[2]
"""
_SPOTLIGHT_CTA_HF_CTA_TAIL_OLD = r"""    for layer in layers:
        print(f"[spotlight] cta-card layer: {layer['type']}")
    return 0
"""
SPOTLIGHT_CTA_HF_CTA_TAIL = r"""    if len(argv) == 5:
        write_project(card, argv[3], argv[4])
        print(f"[spotlight] cta-card project: {argv[3]}/index.html ({card['duration']:.3f}s)")
    for layer in layers:
        print(f"[spotlight] cta-card layer: {layer['type']}")
    return 0
"""
_SPOTLIGHT_CTA_HF_CTA_FN_OLD = r"""

def main(argv: list[str]) -> int:
"""
SPOTLIGHT_CTA_HF_CTA_FN = r"""

# WI2.93: hyperframes 0.7.5 `render` takes a project DIRECTORY holding index.html; handed
# cta-card.json it stops with "Not a directory" and the step used to fall back to a still FFmpeg
# card. The spec above is now also written out as a real HyperFrames project: one full-frame
# composition whose GSAP timeline plays the scale-pop entry, staggers the kicker, hero words and
# handle in, draws the arrow at appearAt and keeps the glow and arrow moving to the last frame.
def write_project(card: dict, project_dir: str, gsap_src: str) -> None:
    import html
    import shutil
    if not os.path.isfile(gsap_src):
        raise SystemExit(f"cta-card.py: vendored gsap.min.js not found at {gsap_src}; never fall back to a CDN")
    os.makedirs(project_dir, exist_ok=True)
    shutil.copy(gsap_src, os.path.join(project_dir, "gsap.min.js"))
    dur = round(float(card["duration"]), 3)
    w, h = card["size"]
    entry = card.get("entry") or {}
    pop_from, pop_dur = float(entry.get("from", 0.92)), float(entry.get("duration", 0.35))
    parts, css = [], []
    for n, layer in enumerate(card["layers"]):
        kind, cls = layer["type"], f"l{n}"
        if kind == "arrow":
            (x0, y0), (x1, y1) = layer["from"], layer["to"]
            css.append(f"#cta-card .{cls}{{left:{x0 - 40}px;top:{y0}px;width:80px;height:{y1 - y0 + 40}px;}}"
                       f"#cta-card .{cls} .shaft{{left:36px;top:0;width:8px;height:{y1 - y0}px;background:{layer['color']};"
                       f"border-radius:4px;transform-origin:50% 0;}}"
                       f"#cta-card .{cls} .head{{left:12px;top:{y1 - y0 - 24}px;width:56px;height:56px;"
                       f"border-right:8px solid {layer['color']};border-bottom:8px solid {layer['color']};"
                       f"border-radius:4px;transform:rotate(45deg);}}")
            parts.append(f'<div class="layer arrow {cls}"><div class="shaft"></div><div class="head"></div></div>')
            continue
        size = int(layer.get("fontSize", 52 if kind == "kicker" else 80))
        font = "'Oswald', sans-serif" if kind in ("hero", "kicker") else "'Inter', sans-serif"
        weight = int(layer.get("weight", 700))
        css.append(f"#cta-card .{cls}{{top:{int(layer['y'])}px;color:{layer['color']};font-family:{font};font-size:{size}px;"
                   f"font-weight:{weight};opacity:{float(layer.get('opacity', 1.0))};"
                   + ("letter-spacing:0.18em;" if kind == "kicker" else "")
                   + ("text-transform:uppercase;line-height:1.0;" if kind == "hero" else "") + "}")
        if kind == "hero":
            words = " ".join(f'<span class="word">{html.escape(t)}</span>' for t in layer["text"].split())
            parts.append(f'<div class="layer hero {cls}">{words}</div>')
        else:
            parts.append(f'<div class="layer {kind} {cls}">{html.escape(layer["text"])}</div>')
    accent = next((l["color"] for l in card["layers"] if l["type"] == "arrow"), "#ffffff")
    arrow_at = next((float(l.get("appearAt", 0.5)) for l in card["layers"] if l["type"] == "arrow"), 0.5)
    bobs = max(0, int((dur - arrow_at - 0.6) / 0.5) * 2 - 1)
    css_text, body_text = "".join(css), "\n        ".join(parts)
    doc = f'''<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width={w}, height={h}" />
    <script src="gsap.min.js"></script>
    <style>
      * {{ margin: 0; padding: 0; box-sizing: border-box; }}
      html, body {{ width: {w}px; height: {h}px; overflow: hidden; background: {card['background']}; }}
      #cta-card {{ position: relative; width: {w}px; height: {h}px; overflow: hidden; background: {card['background']}; }}
      #cta-card .glow {{ position: absolute; left: -260px; top: 260px; width: 1100px; height: 1100px;
        background: radial-gradient(circle, {accent}33 0%, transparent 62%); }}
      #cta-card .card {{ position: absolute; inset: 0; transform-origin: 50% 45%; }}
      #cta-card .layer {{ position: absolute; left: 60px; right: 60px; text-align: center; }}
      #cta-card .hero {{ display: flex; flex-wrap: wrap; justify-content: center; gap: 0 0.28em; }}
      #cta-card .word {{ display: inline-block; }}
      #cta-card .arrow, #cta-card .arrow div {{ position: absolute; right: auto; }}
      {css_text}
    </style>
  </head>
  <body>
    <div id="cta-card" data-composition-id="cta-card" data-start="0" data-duration="{dur}"
         data-width="{w}" data-height="{h}">
      <div class="glow"></div>
      <div class="card">
        {body_text}
      </div>
    </div>
    <script>
      window.__timelines = window.__timelines || {{}};
      (function () {{
        var DUR = {dur};
        var tl = gsap.timeline({{ paused: true }});
        tl.fromTo("#cta-card .glow", {{ x: -120, y: 80, opacity: 0.4 }},
          {{ x: 360, y: -140, opacity: 1, duration: DUR, ease: "sine.inOut" }}, 0);
        tl.fromTo("#cta-card .card", {{ scale: {pop_from}, opacity: 0 }},
          {{ scale: 1, opacity: 1, duration: {pop_dur}, ease: "back.out(2)" }}, 0);
        tl.from("#cta-card .kicker", {{ y: -40, opacity: 0, duration: 0.4, ease: "power3.out" }}, 0.08);
        tl.from("#cta-card .word", {{ y: 90, opacity: 0, duration: 0.45, ease: "power4.out", stagger: 0.07 }}, 0.14);
        tl.to("#cta-card .hero", {{ scale: 1.04, duration: Math.max(0.5, DUR - 0.9), ease: "sine.inOut" }}, 0.8);
        tl.from("#cta-card .handle", {{ y: 40, opacity: 0, duration: 0.4, ease: "power3.out" }}, 0.42);
        tl.from("#cta-card .arrow .shaft", {{ scaleY: 0, duration: 0.3, ease: "power2.out" }}, {arrow_at});
        tl.from("#cta-card .arrow .head", {{ opacity: 0, y: -30, duration: 0.25, ease: "back.out(3)" }}, {arrow_at + 0.2});
        tl.to("#cta-card .arrow", {{ y: 24, duration: 0.25, ease: "sine.inOut", yoyo: true, repeat: {bobs} }}, {arrow_at + 0.5});
        window.__timelines["cta-card"] = tl;
      }})();
    </script>
  </body>
</html>
'''
    with open(os.path.join(project_dir, "index.html"), "w", encoding="utf-8") as fh:
        fh.write(doc)


def main(argv: list[str]) -> int:
"""
SPOTLIGHT_CTA_HF_WRITE_PROJECT_DEF = "\ndef write_project(card: dict, project_dir: str, gsap_src: str) -> None:\n"
_SPOTLIGHT_CTA_HF_FILES = (
    # (file under a spotlight root, only in a full p-reels-spotlight copy (not the heygen wrapper), edits)
    (SPOTLIGHT_ASSEMBLE_FILE, False, ((_SPOTLIGHT_CTA_HF_STEP_RENDER_OLD, SPOTLIGHT_CTA_HF_STEP_RENDER),
                                      (_SPOTLIGHT_CTA_HF_STEP_FAIL_OLD, SPOTLIGHT_CTA_HF_STEP_FAIL))),
    (Path("SKILL.md"), True, ((_SPOTLIGHT_CTA_HF_SKILL_RENDER_OLD, SPOTLIGHT_CTA_HF_SKILL_RENDER),
                              (_SPOTLIGHT_CTA_HF_SKILL_NA_OLD, SPOTLIGHT_CTA_HF_SKILL_NA))),
    (Path("scripts") / "cta-card.py", True, ((_SPOTLIGHT_CTA_HF_CTA_USAGE_OLD, SPOTLIGHT_CTA_HF_CTA_USAGE),
                                             (_SPOTLIGHT_CTA_HF_CTA_ARGS_OLD, SPOTLIGHT_CTA_HF_CTA_ARGS),
                                             (_SPOTLIGHT_CTA_HF_CTA_TAIL_OLD, SPOTLIGHT_CTA_HF_CTA_TAIL),
                                             (_SPOTLIGHT_CTA_HF_CTA_FN_OLD, SPOTLIGHT_CTA_HF_CTA_FN))),
)


def apply_spotlight_end_card_render(directory: Path, recipe: str) -> int:
    """WI2.93: every p-reels-spotlight copy under `directory` (the top-level p-reels-spotlight /
    p-reels-spotlight-heygen step 06, .hub/p-reels-spotlight, SKILL.md Step 8 and scripts/cta-card.py
    of each full copy) renders the end card through HyperFrames from a real project directory, with
    no still ffmpeg fallback card. Idempotent; fails fast when a copy lost its anchor or file, or when
    a spotlight recipe ships no assemble step."""
    changed = 0
    if not directory.is_dir():
        return 0
    roots = [directory] if directory.name.startswith("p-reels-spotlight") else []
    roots += sorted(p for p in directory.rglob("p-reels-spotlight") if p.is_dir() and p.parent.name == ".hub")
    roots = [r for r in roots if (r / SPOTLIGHT_ASSEMBLE_FILE).is_file()]
    if recipe.startswith("p-reels-spotlight") and not roots:
        raise SystemExit(f"sync-skills.py: ERROR - no p-reels-spotlight {SPOTLIGHT_ASSEMBLE_FILE} under {directory} "
                         f"({recipe}); the WI2.93 transform cannot apply")
    for root in roots:
        for rel, full_only, edits in _SPOTLIGHT_CTA_HF_FILES:
            if full_only and root.name != "p-reels-spotlight":
                continue
            path = root / rel
            if not path.is_file():
                raise SystemExit(f"sync-skills.py: ERROR - {path} is missing ({recipe}); the WI2.93 transform cannot apply")
            text = path.read_text(encoding="utf-8")
            new_text = text
            for old, new in edits:
                if new in new_text:
                    continue
                # WI2.96 upgrades the hero / fit code inside write_project, so a later transform can leave this
                # function's text changed; an existing write_project means the WI2.93 insert already happened.
                if new is SPOTLIGHT_CTA_HF_CTA_FN and SPOTLIGHT_CTA_HF_WRITE_PROJECT_DEF in new_text:
                    continue
                if new_text.count(old) != 1:
                    raise SystemExit(f"sync-skills.py: ERROR - end-card render anchor {old.strip().splitlines()[0][:60]!r} "
                                     f"found {new_text.count(old)} time(s) in {path} ({recipe}); "
                                     "the WI2.93 transform cannot apply")
                new_text = new_text.replace(old, new, 1)
            if new_text != text:
                path.write_text(new_text, encoding="utf-8")
                changed += 1
    return changed


# WI2.92: spotlight takeovers. Step 05 (and SKILL.md Step 5 / Fallback assembly) let a failed HyperFrames
# takeover render fall back to static PNG / ffmpeg-overlay cards and the step still passed. On 2026-10-21
# (WI2.87) that hid a total render failure ("Composition has zero duration. Runtime ready: false") and
# the reel still reached Reviews. Step 05 now runs the render itself and a failed render exits non-zero
# with the hyperframes error; the still-card path, the fallback section and the gate's fallback pass are gone.
_SPOTLIGHT_TK_STEP_RENDER_OLD = r"""Run `cd work/comp && npx hyperframes@0.7.5 render --output ../visuals.mp4 --fps 30 --quality high`
as a background process and wait for it — a foreground call can be killed at the runtime ceiling.
Then verify the render really happened (this is the proof the real HyperFrames pipeline ran — the
`scenes_not_blank` check re-derives it from the saved video, so a skipped render cannot pass):

```bash
"""
SPOTLIGHT_TK_STEP_RENDER = r"""Run the block below as a background process and wait for it — a foreground call can be killed at
the runtime ceiling. Its exit code is the step's: a failed render stops the step with the
hyperframes error in the reason (WI2.92). It then verifies the render really happened (this is the
proof the real HyperFrames pipeline ran — the `scenes_not_blank` check re-derives it from the saved
video, so a skipped render cannot pass):

```bash
# WI2.92: no still fallback. A failed takeover render exits non-zero with the hyperframes error.
( cd work/comp && npx hyperframes@0.7.5 render --output ../visuals.mp4 --fps 30 --quality high ) > work/render.log 2>&1 \
  && [ -s work/visuals.mp4 ] \
  || { echo "takeovers: hyperframes render of work/comp failed; no still fallback (WI2.92): $(tail -n 5 work/render.log 2>/dev/null | tr '\n' ' ')" >&2; exit 1; }
"""
_SPOTLIGHT_TK_STEP_FALLBACK_OLD = r"""Fallback (ONLY if the HyperFrames render genuinely fails after a `npx hyperframes@0.7.5 doctor`
check): compose the takeover cards with ffmpeg `overlay` from PNG renders of the filled templates,
and say so in your final message with the real error — a silent skip is a defect.
"""
SPOTLIGHT_TK_STEP_FALLBACK = r"""No fallback (WI2.92). Never compose the takeovers from PNG renders of the filled templates or any
other still stand-in: on 2026-10-21 that path hid a total render failure ("Composition has zero
duration. Runtime ready: false") and the reel still reached Reviews. A failed render fails the step;
`npx hyperframes@0.7.5 doctor` output may go in the reason, but it never unlocks a fallback.
"""
_SPOTLIGHT_TK_STEP_FAIL_OLD = r"""GSAP, or a render that fails even after the fallback is a failure: exit non-zero with one plain
line.
"""
SPOTLIGHT_TK_STEP_FAIL = r"""GSAP, or a failed HyperFrames takeover render is a failure: exit non-zero with one plain line that
carries the hyperframes error. There is no still-card fallback (WI2.92).
"""
_SPOTLIGHT_TK_SKILL_WAIT_OLD = r"""- `process(action="wait", session_id=<id>)` to block until done (or `poll` to check progress)
"""
SPOTLIGHT_TK_SKILL_WAIT = r"""- `process(action="wait", session_id=<id>)` to block until done (or `poll` to check progress)
- WI2.92: if the render exits non-zero or leaves no `$W/visuals.mp4`, STOP and exit non-zero with
  `takeovers: hyperframes render of $W/comp failed; no still fallback (WI2.92): <the hyperframes error>`.
  There is no still-card, PNG or ffmpeg-overlay takeover fallback.
"""
_SPOTLIGHT_TK_SKILL_INTRO_OLD = r"""The three
proof-stamps come from Step 5 (`hyperframes.json`), Step 7 (`premium.json`), and — if the render
truly failed — the Fallback section's stamp."""
SPOTLIGHT_TK_SKILL_INTRO = r"""The
proof-stamps come from Step 5 (`hyperframes.json`) and Step 7 (`premium.json`). A fallback stamp
always fails the gate: there is no takeover fallback (WI2.92)."""
_SPOTLIGHT_TK_SKILL_GATE_OLD = r"""# 1) HyperFrames graphics takeovers actually rendered (or a LEGITIMATE logged fallback).
hf_path = f"{W}/.gate/hyperframes.json"
if not os.path.exists(hf_path):
    fail.append("Step 5 HyperFrames stamp missing — the graphics render never ran (or was skipped).")
else:
    hf = json.load(open(hf_path))
    if hf.get("fallback"):
        if len(hf.get("reason", "")) <= 25:
            fail.append("HyperFrames fallback used without a real reason — looks like a skip, not a fault.")
"""
SPOTLIGHT_TK_SKILL_GATE = r"""# 1) HyperFrames graphics takeovers actually rendered (no fallback, WI2.92).
hf_path = f"{W}/.gate/hyperframes.json"
if not os.path.exists(hf_path):
    fail.append("Step 5 HyperFrames stamp missing — the graphics render never ran (or was skipped).")
else:
    hf = json.load(open(hf_path))
    if hf.get("fallback"):
        fail.append("HyperFrames fallback stamp found — there is no takeover fallback (WI2.92); fix the render.")
"""
_SPOTLIGHT_TK_SKILL_FALLBACK_OLD = r"""## Fallback assembly (v0.4 ffmpeg overlay — ONLY if HyperFrames render genuinely fails)

**This is NOT the easy path. It is permitted ONLY after `npx hyperframes@0.7.5 render` has actually
failed and `hyperframes doctor` confirms an environment fault (chromium/memory).** Never skip the
HyperFrames render to "save time" — a title-only or caption-only reel is a defect. If (and only if)
the render truly fails, fall back to the proven v0.4 ffmpeg technique: render each takeover as a
standalone HyperFrames composition, overlay on the bed with `overlay=enable='between(t,a,b)'` +
`setpts=PTS-STARTPTS+start/TB`, `-map 0:a` for the unbroken audio. B-roll beats are handled the same
way as Step 6b. The cover rule (Step 10) still runs.

**Two hard rules for the fallback path:**
1. **Step 7 (c-reel-premium) still runs** — the fallback replaces only the graphics render, never
   the kinetic-caption/SFX/grade pass. Do NOT "burn plain SRT captions" as a substitute for premium.
2. **Stamp the fallback with a reason** so the Step 10.6 gate can tell a real fault from a skip:
   ```bash
   mkdir -p "$W/.gate"
   REASON="${1:-hyperframes render failed — doctor confirmed environment fault}"
   # Paste the actual doctor/render error into REASON. An empty or generic reason FAILS the gate.
   python3 - "$W" "$REASON" <<'PY'
   import json, sys
   W, reason = sys.argv[1], sys.argv[2]
   assert len(reason) > 25, "fallback reason too short — paste the real render/doctor error"
   json.dump({"rendered": 0, "engine": "ffmpeg-v0.4-fallback", "fallback": True,
              "reason": reason}, open(f"{W}/.gate/hyperframes.json", "w"))
   print("[gate-stamp] hyperframes: FALLBACK path — reason logged")
   PY
   ```
"""
SPOTLIGHT_TK_SKILL_FALLBACK = r"""## No fallback assembly (WI2.92)

There is no still-card, PNG or ffmpeg-overlay stand-in for the graphics takeovers. On 2026-10-21
that fallback hid a total render failure ("Composition has zero duration. Runtime ready: false")
and the reel still reached Reviews. If `npx hyperframes@0.7.5 render` fails, Step 5 fails with the
hyperframes error; `hyperframes doctor` output may go in that reason, but it never unlocks a fallback.
"""
_SPOTLIGHT_TK_FILES = (
    # (file under a spotlight root, only in a full p-reels-spotlight copy (not the heygen wrapper), edits)
    (SPOTLIGHT_RENDER_FILE, False, ((_SPOTLIGHT_TK_STEP_RENDER_OLD, SPOTLIGHT_TK_STEP_RENDER),
                                    (_SPOTLIGHT_TK_STEP_FALLBACK_OLD, SPOTLIGHT_TK_STEP_FALLBACK),
                                    (_SPOTLIGHT_TK_STEP_FAIL_OLD, SPOTLIGHT_TK_STEP_FAIL))),
    (Path("SKILL.md"), True, ((_SPOTLIGHT_TK_SKILL_WAIT_OLD, SPOTLIGHT_TK_SKILL_WAIT),
                              (_SPOTLIGHT_TK_SKILL_INTRO_OLD, SPOTLIGHT_TK_SKILL_INTRO),
                              (_SPOTLIGHT_TK_SKILL_GATE_OLD, SPOTLIGHT_TK_SKILL_GATE),
                              (_SPOTLIGHT_TK_SKILL_FALLBACK_OLD, SPOTLIGHT_TK_SKILL_FALLBACK))),
)


def apply_spotlight_takeover_render_fail_loud(directory: Path, recipe: str) -> int:
    """WI2.92: every p-reels-spotlight copy under `directory` (the top-level p-reels-spotlight /
    p-reels-spotlight-heygen step 05, .hub/p-reels-spotlight, and SKILL.md Step 5 / Step 10.6 /
    Fallback assembly of each full copy) renders the graphics takeovers through HyperFrames with no
    still-card fallback: a failed render exits non-zero with the hyperframes error. Idempotent; fails
    fast when a copy lost its anchor or file, or when a spotlight recipe ships no render step."""
    changed = 0
    if not directory.is_dir():
        return 0
    roots = [directory] if directory.name.startswith("p-reels-spotlight") else []
    roots += sorted(p for p in directory.rglob("p-reels-spotlight") if p.is_dir() and p.parent.name == ".hub")
    roots = [r for r in roots if (r / SPOTLIGHT_RENDER_FILE).is_file()]
    if recipe.startswith("p-reels-spotlight") and not roots:
        raise SystemExit(f"sync-skills.py: ERROR - no p-reels-spotlight {SPOTLIGHT_RENDER_FILE} under {directory} "
                         f"({recipe}); the WI2.92 transform cannot apply")
    for root in roots:
        for rel, full_only, edits in _SPOTLIGHT_TK_FILES:
            if full_only and root.name != "p-reels-spotlight":
                continue
            path = root / rel
            if not path.is_file():
                raise SystemExit(f"sync-skills.py: ERROR - {path} is missing ({recipe}); the WI2.92 transform cannot apply")
            text = path.read_text(encoding="utf-8")
            new_text = text
            for old, new in edits:
                if new in new_text:
                    continue
                if new_text.count(old) != 1:
                    raise SystemExit(f"sync-skills.py: ERROR - takeover render anchor {old.strip().splitlines()[0][:60]!r} "
                                     f"found {new_text.count(old)} time(s) in {path} ({recipe}); "
                                     "the WI2.92 transform cannot apply")
                new_text = new_text.replace(old, new, 1)
            if new_text != text:
                path.write_text(new_text, encoding="utf-8")
                changed += 1
    return changed


# WI2.94: smoke 25 (Render 69bc5ce) showed spotlight takeover text breaking the one-line rule: the
# tk-stat label "POSTS · SPECIALS · MOMENTS" wrapped to two lines, and the tk-list title "CFW WRITES THE
# MONTH" and item 3 "FORMATTED FOR EVERY PLATFORM" wrapped too. WI2.83/WI2.85 fit only the big stat.
# Every single-line takeover text (tk-stat eyebrow + label, tk-list title + three items, tk-keyword word +
# support line, tk-quote attribution) is now kept on one line (white-space: nowrap, its box capped at its
# safe width) and the page fits it: it measures the line and scales the font down from the design size
# until the line is no wider than its safe width; text is never truncated. It refits once fonts load.
# Safe widths keep every line >= 80 px from both frame edges (1080 px):
#   900 px  tk-stat eyebrow/label (centred: >= 90 px margins), tk-list title (left 84: right margin 96),
#           tk-quote attribution (left 90: right margin 90).
#   786 px  tk-list item text = 900 - 84 px number box - 30 px gap (right edge 984, margin 96).
#   880 px  tk-keyword word (its 1.04 breathe: 915 px, margins 82) and support line (centred, margins 100).
# The tk-quote QUOTE stays a wrapping multi-line quote by design. The fit runs after the timeline is
# registered, so the WI2.83/WI2.85 tk-stat edits (and their timing) are untouched; scrollWidth ignores
# GSAP transforms, so the measurement is the settled layout width.
SPOTLIGHT_LINE_MAX_W = 900
SPOTLIGHT_LIST_ITEM_MAX_W = SPOTLIGHT_LINE_MAX_W - 84 - 30
SPOTLIGHT_KEYWORD_MAX_W = 880


def _line_css(selector: str, max_w: int | None) -> tuple:
    old = "      #{{ID}} " + selector + " {\n"
    cap = f" max-width: {max_w}px;" if max_w else ""
    return (old, old + f"        white-space: nowrap;{cap}  /* WI2.94: one line; the script fits it to the safe width */\n")


def _line_fit_js(targets: str) -> str:
    return (
        "\n"
        "        // WI2.94: keep each takeover text line on ONE line. A line starts at its design size and,\n"
        "        // when wider than its safe width (>= 80px from both frame edges), its font is scaled down\n"
        "        // until it fits; the text is never cut. Refit once fonts load.\n"
        "        function fitLine(el, base, maxW) {\n"
        "          if (!el) return base;\n"
        "          el.style.fontSize = base + \"px\";\n"
        "          var w = el.scrollWidth;\n"
        "          if (w <= maxW) return base;\n"
        "          var size = Math.floor(base * maxW / w);\n"
        "          el.style.fontSize = size + \"px\";\n"
        "          while (size > 8 && el.scrollWidth > maxW) { size -= 1; el.style.fontSize = size + \"px\"; }\n"
        "          return size;\n"
        "        }\n"
        "        var LINE_FITS = " + targets + ";\n"
        "        function fitLines() { LINE_FITS.forEach(function (f) { fitLine(f[0], f[1], f[2]); }); }\n"
        "        fitLines();\n"
        "        if (document.fonts && document.fonts.ready) { document.fonts.ready.then(fitLines); }\n"
    )


_SPOTLIGHT_LINE_REG_OLD = "        window.__timelines[\"{{ID}}\"] = tl;\n"
_SPOTLIGHT_LINE_EDITS = {
    "tk-stat.html": (
        _line_css(".eyebrow", SPOTLIGHT_LINE_MAX_W),
        _line_css(".label", None),  # already max-width: 900px
        (_SPOTLIGHT_LINE_REG_OLD, _SPOTLIGHT_LINE_REG_OLD + _line_fit_js(
            "[\n"
            f"          [document.querySelector(scope + \".js-eyebrow\"), 30, {SPOTLIGHT_LINE_MAX_W}],\n"
            f"          [document.querySelector(scope + \".js-label\"), 84, {SPOTLIGHT_LINE_MAX_W}]\n"
            "        ]")),
    ),
    "tk-list.html": (
        _line_css(".title", SPOTLIGHT_LINE_MAX_W),
        _line_css(".item-text", SPOTLIGHT_LIST_ITEM_MAX_W),
        (_SPOTLIGHT_LINE_REG_OLD, _SPOTLIGHT_LINE_REG_OLD + _line_fit_js(
            f"[[document.querySelector(scope + \".js-title\"), 96, {SPOTLIGHT_LINE_MAX_W}]].concat(\n"
            "          Array.prototype.map.call(document.querySelectorAll(scope + \".item-text\"),\n"
            f"            function (el) {{ return [el, 52, {SPOTLIGHT_LIST_ITEM_MAX_W}]; }}))")),
    ),
    "tk-keyword.html": (
        _line_css(".word", SPOTLIGHT_KEYWORD_MAX_W),
        _line_css(".support", None),  # already max-width: 880px
        (_SPOTLIGHT_LINE_REG_OLD, _SPOTLIGHT_LINE_REG_OLD + _line_fit_js(
            "[\n"
            f"          [wordEl, fit.fontSize, {SPOTLIGHT_KEYWORD_MAX_W}],\n"
            f"          [document.querySelector(scope + \".js-support\"), 52, {SPOTLIGHT_KEYWORD_MAX_W}]\n"
            "        ]")),
    ),
    "tk-quote.html": (
        _line_css(".attr", SPOTLIGHT_LINE_MAX_W),
        (_SPOTLIGHT_LINE_REG_OLD, _SPOTLIGHT_LINE_REG_OLD + _line_fit_js(
            f"[[document.querySelector(scope + \".js-attr\"), 34, {SPOTLIGHT_LINE_MAX_W}]]")),
    ),
}


def apply_spotlight_takeover_line_fit(directory: Path, recipe: str) -> int:
    """WI2.94: every p-reels-spotlight takeover template copy under `directory` (top-level or
    .hub/p-reels-spotlight: tk-stat, tk-list, tk-keyword, tk-quote) keeps each single-line text on one
    line and fits its font to the line's safe width. Idempotent; fails fast when a copy lost a template
    or an anchor, or when a spotlight recipe ships no takeover templates at all."""
    changed = 0
    if not directory.is_dir():
        return 0
    roots = [directory] if directory.name == "p-reels-spotlight" else []
    roots += sorted(p for p in directory.rglob("p-reels-spotlight") if p.is_dir() and p.parent.name == ".hub")
    roots = [r for r in roots if (r / "templates").is_dir()]
    if recipe.startswith("p-reels-spotlight") and not roots:
        raise SystemExit(f"sync-skills.py: ERROR - no p-reels-spotlight templates/ under {directory} "
                         f"({recipe}); the WI2.94 transform cannot apply")
    for root in roots:
        for name, edits in _SPOTLIGHT_LINE_EDITS.items():
            tpl = root / "templates" / name
            if not tpl.is_file():
                raise SystemExit(f"sync-skills.py: ERROR - {tpl} is missing ({recipe}); the WI2.94 transform cannot apply")
            text = tpl.read_text(encoding="utf-8")
            new_text = text
            for old, new in edits:
                if new in new_text:
                    continue
                if new_text.count(old) != 1:
                    raise SystemExit(f"sync-skills.py: ERROR - {name} anchor {old.strip().splitlines()[0][:60]!r} "
                                     f"found {new_text.count(old)} time(s) in {tpl} ({recipe}); "
                                     "the WI2.94 transform cannot apply")
                new_text = new_text.replace(old, new, 1)
            if new_text != text:
                tpl.write_text(new_text, encoding="utf-8")
                changed += 1
    return changed


# WI2.90: independent review on WI2.89 (Render 32549b7, 2026-10-21). (1) Step 06 still skipped the end card
# with one log line when under SPOTLIGHT_CTA_MIN_S of bed was left after the last word. Since WI2.89 step 01
# always leaves a silent tail, that only happens through a bug, and the reel shipped with no CTA while no
# check failed. Step 06 now fails (exit 1) with the reason, like SKILL.md Step 8. (2) SKILL.md never set
# CTA_CARD, so Step 2's "${CTA_CARD:-on}" was always on: an order with cta_card: off still got a ~3.5 s frozen
# silent tail. SKILL.md now reads the order's cta_card into CTA_CARD (default on) next to CTA_TEXT /
# CTA_HANDLE / CTA_DURATION, and Step 8 renders no card when it is off. Runs after WI2.86/WI2.89/WI2.93.
_SPOTLIGHT_CTA_ROOM_STEP_DOC_OLD = """of the bed and is rendered at that length. Nothing is appended: when less than
""" + str(SPOTLIGHT_CTA_MIN_S) + """ s of bed is left after the last word, the card is skipped with one log line.
"""
SPOTLIGHT_CTA_ROOM_STEP_DOC = """of the bed and is rendered at that length. Nothing is appended. Step 01's silent tail (WI2.89)
always leaves room, so when less than """ + str(SPOTLIGHT_CTA_MIN_S) + """ s of bed is left after the last word the step
fails (exit 1) with the reason instead of shipping a reel with no end card (WI2.90).
"""
_SPOTLIGHT_CTA_ROOM_STEP_SKIP_OLD = """  if python3 -c "import sys; sys.exit(0 if ${CTA_DURATION} < """ + str(SPOTLIGHT_CTA_MIN_S) + """ else 1)"; then
    echo "[spotlight] end card skipped: only ${CTA_DURATION}s of bed after the last spoken word (needs """ + str(SPOTLIGHT_CTA_MIN_S) + """s)"
    CTA_CARD=off
  fi
"""
SPOTLIGHT_CTA_ROOM_STEP_FAIL = """  # WI2.90: the step 01 tail (WI2.89) always leaves room; under """ + str(SPOTLIGHT_CTA_MIN_S) + """ s is a bug, so fail loudly
  # (like SKILL.md Step 8) instead of shipping a reel with no end card.
  python3 -c "import sys; sys.exit(0 if ${CTA_DURATION} >= """ + str(SPOTLIGHT_CTA_MIN_S) + """ else 'end card: only ${CTA_DURATION}s of bed after the last spoken word (needs """ + str(SPOTLIGHT_CTA_MIN_S) + """s); the step 01 end-card tail (WI2.89) is missing')" || exit 1
"""
_SPOTLIGHT_CTA_CARD_SKILL_NOTE_OLD = """> handle line**. Never reuse another brand's copy or handle, and never invent a handle.
"""
SPOTLIGHT_CTA_CARD_SKILL_NOTE = _SPOTLIGHT_CTA_CARD_SKILL_NOTE_OLD + """>
> **`cta_card` comes from the order too (WI2.90).** Set `CTA_CARD` to the order's `cta_card` (`on` unless
> the order says `off`) and export it with the copy above. `off` means Step 2 adds no silent tail and
> Step 8 renders no end card; anything other than `on` counts as `off`, as in the steps path.
"""
_SPOTLIGHT_CTA_CARD_SKILL_VAR_OLD = """CTA_DURATION="${CTA_DURATION:-3}"
W="{production}/interim/spotlight" ; mkdir -p "$W"
"""
SPOTLIGHT_CTA_CARD_SKILL_VAR = """CTA_CARD="${CTA_CARD:-on}"      # the order's cta_card (WI2.90): off = no Step 2 tail and no Step 8 end card
""" + _SPOTLIGHT_CTA_CARD_SKILL_VAR_OLD
_SPOTLIGHT_CTA_CARD_SKILL_S8_OLD = """```bash
BG_HEX=$(python3 -c "import json; print(json.load(open('$W/plan.json'))['brand']['bg'].lstrip('#'))")
"""
SPOTLIGHT_CTA_CARD_SKILL_S8 = """```bash
# WI2.90: cta_card off (CTA_CARD, from the order) renders no end card; Step 2 added no tail either.
if [ "${CTA_CARD:-on}" != "on" ]; then
BED_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$W/polished.mp4")
echo "[spotlight] end card: cta_card off, no end card"
cp "$W/polished.mp4" "$OUT_RAW"
else
BG_HEX=$(python3 -c "import json; print(json.load(open('$W/plan.json'))['brand']['bg'].lstrip('#'))")
"""
_SPOTLIGHT_CTA_CARD_SKILL_S8_END_OLD = """  -movflags +faststart "$OUT_RAW"

if [ -n "${MUSIC:-}" ]; then
"""
SPOTLIGHT_CTA_CARD_SKILL_S8_END = """  -movflags +faststart "$OUT_RAW"
fi   # WI2.90: end of the cta_card on branch

if [ -n "${MUSIC:-}" ]; then
"""
_SPOTLIGHT_CTA_ROOM_FILES = (
    # (file under a spotlight root, only in a full p-reels-spotlight copy (not the heygen wrapper), edits)
    (SPOTLIGHT_ASSEMBLE_FILE, False, ((_SPOTLIGHT_CTA_ROOM_STEP_DOC_OLD, SPOTLIGHT_CTA_ROOM_STEP_DOC),
                                      (_SPOTLIGHT_CTA_ROOM_STEP_SKIP_OLD, SPOTLIGHT_CTA_ROOM_STEP_FAIL))),
    (Path("SKILL.md"), True, ((_SPOTLIGHT_CTA_CARD_SKILL_NOTE_OLD, SPOTLIGHT_CTA_CARD_SKILL_NOTE),
                              (_SPOTLIGHT_CTA_CARD_SKILL_VAR_OLD, SPOTLIGHT_CTA_CARD_SKILL_VAR),
                              (_SPOTLIGHT_CTA_CARD_SKILL_S8_OLD, SPOTLIGHT_CTA_CARD_SKILL_S8),
                              (_SPOTLIGHT_CTA_CARD_SKILL_S8_END_OLD, SPOTLIGHT_CTA_CARD_SKILL_S8_END))),
)


def apply_spotlight_end_card_room(directory: Path, recipe: str) -> int:
    """WI2.90: every p-reels-spotlight copy under `directory` (the top-level p-reels-spotlight /
    p-reels-spotlight-heygen step 06, .hub/p-reels-spotlight, and SKILL.md of each full copy) fails step 06
    loudly when the end card has under SPOTLIGHT_CTA_MIN_S of room, and the SKILL.md path reads the order's
    cta_card into CTA_CARD (default on) so cta_card: off adds no tail and renders no card. Idempotent; fails
    fast when a copy lost its anchor or file, or when a spotlight recipe ships no assemble step."""
    changed = 0
    if not directory.is_dir():
        return 0
    roots = [directory] if directory.name.startswith("p-reels-spotlight") else []
    roots += sorted(p for p in directory.rglob("p-reels-spotlight") if p.is_dir() and p.parent.name == ".hub")
    roots = [r for r in roots if (r / SPOTLIGHT_ASSEMBLE_FILE).is_file()]
    if recipe.startswith("p-reels-spotlight") and not roots:
        raise SystemExit(f"sync-skills.py: ERROR - no p-reels-spotlight {SPOTLIGHT_ASSEMBLE_FILE} under {directory} "
                         f"({recipe}); the WI2.90 transform cannot apply")
    for root in roots:
        for rel, full_only, edits in _SPOTLIGHT_CTA_ROOM_FILES:
            if full_only and root.name != "p-reels-spotlight":
                continue
            path = root / rel
            if not path.is_file():
                raise SystemExit(f"sync-skills.py: ERROR - {path} is missing ({recipe}); the WI2.90 transform cannot apply")
            text = path.read_text(encoding="utf-8")
            new_text = text
            for old, new in edits:
                if new in new_text:
                    continue
                if new_text.count(old) != 1:
                    raise SystemExit(f"sync-skills.py: ERROR - end-card room anchor {old.strip().splitlines()[0][:60]!r} "
                                     f"found {new_text.count(old)} time(s) in {path} ({recipe}); "
                                     "the WI2.90 transform cannot apply")
                new_text = new_text.replace(old, new, 1)
            if new_text != text:
                path.write_text(new_text, encoding="utf-8")
                changed += 1
    return changed


# WI2.91: spotlight typing takeover prompt. Step 05 (and SKILL.md Step 5) filled the scene's
# `var PROMPT_TEXT = "{{PROMPT}}"` JS literal with html.escape(PROMPT): a backslash changed the typed
# text and a carriage return (CRLF text) broke the script, so the HyperFrames render failed (independent
# review 01a15e05-5322 of 69bc5ce). CR/CRLF now become one line break and the HTML-escaped prompt is
# JSON-encoded (ASCII) as the literal's body, with < > { } as \u escapes, so no backslash, quote,
# control character, U+2028/2029, </script> or {{KEY}} can change or break the scene. The other keys
# the scene reads in JS literals drop line breaks and carry a backslash as &#92;. Also: c-typing-ui's
# hard-coded card label "The prompt · paste this" is replaced, for spotlight only, by a CARD_LABEL fill
# key with the neutral default "The prompt" (the other c-typing-ui users keep their label).
_SPOTLIGHT_PROMPT_LINE_OLD = r"""        m["PROMPT"] = html.escape(str(tk["fill"].get("PROMPT", ""))).replace("\n", "&#10;")  # decoded in-page
"""
_SPOTLIGHT_PROMPT_BLOCK = r"""        # WI2.91: the scene reads PROMPT inside a JS "..." literal and decodes its entities in-page. html.escape
        # alone let a backslash change the typed text and a carriage return break the script (the render
        # failed). CR/CRLF become one line break; the HTML-escaped text is JSON-encoded (ASCII) as the
        # literal's body, so backslash, quote, control characters and U+2028/2029 are escaped, and < > { }
        # become \u escapes: no </script> break-out, no {{KEY}} in a prompt is ever filled. The other keys
        # the scene reads in JS literals drop line breaks and carry a backslash as &#92;.
        prompt = str(tk["fill"].get("PROMPT", "")).replace("\r\n", "\n").replace("\r", "\n")
        m["PROMPT"] = json.dumps(html.escape(prompt).replace("\n", "&#10;"), ensure_ascii=True)[1:-1].translate(
            {ord("<"): "\\u003c", ord(">"): "\\u003e", ord("{"): "\\u007b", ord("}"): "\\u007d"})
        for k in ("TYPING_SPEED", "VARIANT", "BOTTOM_TAG"):
            if k in m:
                m[k] = %(re)s.sub(r"[\r\n\u2028\u2029]+", " ", str(m[k])).replace("\\", "&#92;")
        m.setdefault("CARD_LABEL", "The prompt")   # the label above the card (neutral; no "paste this")
"""
SPOTLIGHT_PROMPT_STEP = _SPOTLIGHT_PROMPT_BLOCK % {"re": "re"}
SPOTLIGHT_PROMPT_SKILL = _SPOTLIGHT_PROMPT_BLOCK % {"re": "re_mod"}
_SPOTLIGHT_LABEL_STEP_OLD = r"""        src = src[src.index('<template id="typing-scene-template">'):]   # drop the usage comment
"""
SPOTLIGHT_LABEL_STEP = _SPOTLIGHT_LABEL_STEP_OLD + r"""        assert src.count('id="ts-label">The prompt · paste this</div>') == 1, \
            "FATAL: c-typing-ui typing-scene.html card label changed shape; cannot fill CARD_LABEL (WI2.91)"
        src = src.replace('id="ts-label">The prompt · paste this</div>', 'id="ts-label">{{CARD_LABEL}}</div>')
"""
_SPOTLIGHT_LABEL_SKILL_OLD = r"""        tpl_src = tpl_src[tpl_src.index('<template id="typing-scene-template">'):]   # drop the usage comment
"""
SPOTLIGHT_LABEL_SKILL = _SPOTLIGHT_LABEL_SKILL_OLD + r"""        assert tpl_src.count('id="ts-label">The prompt · paste this</div>') == 1, \
            "FATAL: c-typing-ui typing-scene.html card label changed shape; cannot fill CARD_LABEL (WI2.91)"
        tpl_src = tpl_src.replace('id="ts-label">The prompt · paste this</div>', 'id="ts-label">{{CARD_LABEL}}</div>')
"""
_SPOTLIGHT_PROMPT_PLAN_STEP_OLD = """LABEL (e.g. `claude.ai`), PROMPT (the typed text), TYPING_SPEED (0.5–1.5), BOTTOM_TAG.
"""
SPOTLIGHT_PROMPT_PLAN_STEP = """LABEL (e.g. `claude.ai`), PROMPT (the typed text), TYPING_SPEED (0.5–1.5), BOTTOM_TAG, and
optionally CARD_LABEL (the line above the card; default `The prompt`).
"""
_SPOTLIGHT_PROMPT_PLAN_SKILL_OLD = """tk-typing-ui: LABEL (e.g. 'claude.ai'), PROMPT (the typed text), TYPING_SPEED (0.5-1.5), BOTTOM_TAG.
"""
SPOTLIGHT_PROMPT_PLAN_SKILL = """tk-typing-ui: LABEL (e.g. 'claude.ai'), PROMPT (the typed text), TYPING_SPEED (0.5-1.5), BOTTOM_TAG,
and optionally CARD_LABEL (the line above the card; default 'The prompt').
"""
SPOTLIGHT_PLAN_FILE = Path("steps") / "03-plan-edit.md"
# (file under a spotlight root, only in a full p-reels-spotlight copy (not the heygen wrapper), edits)
_SPOTLIGHT_PROMPT_FILES = (
    (SPOTLIGHT_RENDER_FILE, False, ((_SPOTLIGHT_PROMPT_LINE_OLD, SPOTLIGHT_PROMPT_STEP),
                                    (_SPOTLIGHT_LABEL_STEP_OLD, SPOTLIGHT_LABEL_STEP))),
    (SPOTLIGHT_PLAN_FILE, False, ((_SPOTLIGHT_PROMPT_PLAN_STEP_OLD, SPOTLIGHT_PROMPT_PLAN_STEP),)),
    (Path("SKILL.md"), True, ((_SPOTLIGHT_PROMPT_LINE_OLD, SPOTLIGHT_PROMPT_SKILL),
                              (_SPOTLIGHT_LABEL_SKILL_OLD, SPOTLIGHT_LABEL_SKILL),
                              (_SPOTLIGHT_PROMPT_PLAN_SKILL_OLD, SPOTLIGHT_PROMPT_PLAN_SKILL))),
)


def apply_spotlight_typing_prompt(directory: Path, recipe: str) -> int:
    """WI2.91: every p-reels-spotlight copy under `directory` (the top-level p-reels-spotlight /
    p-reels-spotlight-heygen steps 03 and 05, .hub/p-reels-spotlight, and SKILL.md of each full copy) fills
    the typing takeover's JS prompt literal JSON-encoded (backslash, CR/CRLF, quotes, </script>, U+2028/2029
    and {{KEY}} cannot change or break it) and fills the card label from CARD_LABEL (default "The prompt").
    Runs after WI2.87. Idempotent; fails fast when a copy lost its anchor or file, or when a spotlight
    recipe ships no render-scenes step."""
    changed = 0
    if not directory.is_dir():
        return 0
    roots = [directory] if directory.name.startswith("p-reels-spotlight") else []
    roots += sorted(p for p in directory.rglob("p-reels-spotlight") if p.is_dir() and p.parent.name == ".hub")
    roots = [r for r in roots if (r / SPOTLIGHT_RENDER_FILE).is_file()]
    if recipe.startswith("p-reels-spotlight") and not roots:
        raise SystemExit(f"sync-skills.py: ERROR - no p-reels-spotlight {SPOTLIGHT_RENDER_FILE} under {directory} "
                         f"({recipe}); the WI2.91 transform cannot apply")
    for root in roots:
        for rel, full_only, edits in _SPOTLIGHT_PROMPT_FILES:
            if full_only and root.name != "p-reels-spotlight":
                continue
            path = root / rel
            if not path.is_file():
                raise SystemExit(f"sync-skills.py: ERROR - {path} is missing ({recipe}); the WI2.91 transform cannot apply")
            text = path.read_text(encoding="utf-8")
            new_text = text
            for old, new in edits:
                if new in new_text:
                    continue
                if new_text.count(old) != 1:
                    raise SystemExit(f"sync-skills.py: ERROR - typing prompt anchor {old.strip().splitlines()[0][:60]!r} "
                                     f"found {new_text.count(old)} time(s) in {path} ({recipe}); "
                                     "the WI2.91 transform cannot apply")
                new_text = new_text.replace(old, new, 1)
            if new_text != text:
                path.write_text(new_text, encoding="utf-8")
                changed += 1
    return changed


# WI2.88: spotlight caption emphasis word. Smoke 2026-10-21: before it was spoken the emphasis word
# showed small (scale 0.72, the fromTo's immediate render) and dim in the accent colour after a wide
# gap ("VOICE," ~29.8-31.2 s, "MONTH" ~33 s, "MOMENTS" ~5 s); on its pop the transform scale (1.16 plus
# the back.out overshoot) grew past its 0.06em margin and the column gap, so "EVERY PLATFORM." read
# "EVERYPLATFORM." (~35.8 s). A transform never moves the neighbours. Now the word is a plain word
# (scale 1, FG colour, the same 0.42 dim) until its timestamp, then turns the accent colour and pops by
# tweening --pop, its font size: the line reflows, so the space on both sides of it is always kept.
_SPOTLIGHT_CAP_CSS_OLD = """      #caption-overlay .cap-word.em {
        font-weight: 700;
        color: {{ACCENT}};
        /* breathing room — the scale pop must not eat the neighbor gaps */
        margin: 0 0.06em;
      }
"""
SPOTLIGHT_CAP_CSS = """      #caption-overlay .cap-word.em {
        font-weight: 700;
        /* WI2.88: until it is spoken the emphasis word is a plain word (same size, colour and dim as
           its neighbours). Its pop grows its font size (--pop), never a transform scale, so the line
           reflows and the space on both sides of it is kept: no tiny word, no wide or closed gap. */
        font-size: calc(1em * var(--pop, 1));
      }
"""
_SPOTLIGHT_CAP_JS_OLD = """            // Emphasis word: accent pop + glow — clearly breaks the pattern.
            tl.fromTo(wsel, { scale: 0.72, opacity: 0.42 },
              { scale: 1.16, opacity: 1, duration: 0.26, ease: "back.out(2.2)" }, at);
"""
SPOTLIGHT_CAP_JS = """            // Emphasis word: accent pop + glow — clearly breaks the pattern. WI2.88: until its
            // timestamp it is a plain dim word (scale 1, FG, like its neighbours); the pop tweens
            // --pop (its font size), so the words beside it make room instead of being overlapped.
            tl.fromTo(wsel, { "--pop": 1, opacity: 0.42, color: FG },
              { "--pop": POP_TO, opacity: 1, color: ACCENT, duration: 0.26, ease: POP_EASE }, at);
"""
_SPOTLIGHT_CAP_SETTLE_OLD = """            tl.to(wsel, { scale: 1.08, duration: 0.18, ease: "power2.inOut" }, at + 0.26);
"""
SPOTLIGHT_CAP_SETTLE = """            tl.to(wsel, { "--pop": POP_SETTLE, duration: 0.18, ease: "power2.inOut" }, at + 0.26);
"""
# Independent review of b8c3ff6: the fit measured the words with plain spaces against 760 px, but the
# line has 0.42em column gaps and the pop's back.out overshoot, so a line near the limit could wrap
# mid-pop; and the pop (1.16) shifted the centred line by about half its growth. The line is now fitted
# for its real gaps and the pop's peak (shrunk, never grown, to the 900 px safe width; refit when fonts
# load) and the pop is smaller (1.12, back.out(1.7), settling at 1.06).
_SPOTLIGHT_CAP_HEAD_OLD = """    planner-flagged emphasis word gets the accent treatment (color + scale pop
    + glow). Entrance style cycles per group (planner sets style 0/1/2).
"""
SPOTLIGHT_CAP_HEAD = """    planner-flagged emphasis word gets the accent treatment (color + font-size
    pop + glow; WI2.88: a plain word until spoken, its line fitted so the pop
    never wraps it). Entrance style cycles per group (planner sets style 0/1/2).
"""
_SPOTLIGHT_CAP_FIT_OLD = """        root.appendChild(g);
      });

      var tl = gsap.timeline({ paused: true });
"""
SPOTLIGHT_CAP_FIT = """        root.appendChild(g);
      });

      // WI2.88: the fit above measures the words with plain spaces against 760 px, but the line has
      // 0.42em gaps (the .cap-group column-gap) and its emphasis word grows to POP_PEAK on its pop
      // (back.out overshoot included). Shrink a group (never grow it) until the whole line at the
      // peak fits the 900 px safe width, so it never wraps mid-pop; refit once fonts load. The pop
      // is small (1.12, settling at 1.06), so the centred line shifts only a few px to make room.
      var POP_TO = 1.12, POP_SETTLE = 1.06, POP_BACK = 1.7, POP_EASE = "back.out(" + POP_BACK + ")";
      var POP_PEAK = (function () {
        var most = 1;
        for (var i = 0; i <= 400; i++) {
          var q = i / 400 - 1;
          most = Math.max(most, 1 + (POP_BACK + 1) * q * q * q + POP_BACK * q * q);
        }
        return 1 + (POP_TO - 1) * most;
      })();
      var GAP_EM = 0.42, SAFE_W = 900, BASE_SIZES = [];
      function fitLines() {
        GROUPS.forEach(function (group, gi) {
          var g = document.getElementById("cg-" + gi);
          if (!g) return;
          if (BASE_SIZES[gi] === undefined) BASE_SIZES[gi] = parseFloat(g.style.fontSize) || 72;
          var size = BASE_SIZES[gi];
          g.style.fontSize = size + "px";
          var need = Math.max(0, group.words.length - 1) * GAP_EM * size;
          group.words.forEach(function (w, wi) {
            var s = document.getElementById("cw-" + gi + "-" + wi);
            var pop = parseFloat(s.style.getPropertyValue("--pop")) || 1;
            need += (s.offsetWidth / pop) * (w.em ? POP_PEAK : 1);
          });
          if (need > SAFE_W) g.style.fontSize = Math.max(24, Math.floor(size * SAFE_W / need)) + "px";
        });
      }
      fitLines();
      if (document.fonts && document.fonts.ready) { document.fonts.ready.then(fitLines); }

      var tl = gsap.timeline({ paused: true });
"""
_SPOTLIGHT_CAP_EDITS = ((_SPOTLIGHT_CAP_HEAD_OLD, SPOTLIGHT_CAP_HEAD), (_SPOTLIGHT_CAP_CSS_OLD, SPOTLIGHT_CAP_CSS),
                        (_SPOTLIGHT_CAP_FIT_OLD, SPOTLIGHT_CAP_FIT), (_SPOTLIGHT_CAP_JS_OLD, SPOTLIGHT_CAP_JS),
                        (_SPOTLIGHT_CAP_SETTLE_OLD, SPOTLIGHT_CAP_SETTLE))
SPOTLIGHT_CAP_TEMPLATE = Path("templates") / "caption-overlay.html"


def spotlight_caption_files(directory: Path, recipe: str) -> list:
    """WI2.88: the caption-overlay.html copies in a p-reels-spotlight bundle: the vendored c-reel-premium
    template (step 06 renders the p-reels-spotlight one), the recipe's own template, and the heygen
    .hub/p-reels-spotlight copy. [] for any other recipe."""
    if not recipe.startswith("p-reels-spotlight"):
        return []
    files = [directory / ".hub" / "c-reel-premium" / SPOTLIGHT_CAP_TEMPLATE]
    if (directory / "templates").is_dir() or recipe == "p-reels-spotlight":
        files.append(directory / SPOTLIGHT_CAP_TEMPLATE)
    hub = directory / ".hub" / "p-reels-spotlight"
    if hub.is_dir():
        files.append(hub / SPOTLIGHT_CAP_TEMPLATE)
    return files


def apply_spotlight_caption_pop(directory: Path, recipe: str) -> int:
    """WI2.88: every caption-overlay.html copy in a p-reels-spotlight bundle shows the emphasis word at
    full size, FG colour and the common dim until it is spoken, then pops it by growing its font size
    (--pop) so the space before it is never closed. Idempotent; fails fast when a copy is missing or
    lost its anchor."""
    changed = 0
    if not directory.is_dir():
        return 0
    for path in spotlight_caption_files(directory, recipe):
        if not path.is_file():
            raise SystemExit(f"sync-skills.py: ERROR - {path} is missing ({recipe}); the WI2.88 transform cannot apply")
        text = path.read_text(encoding="utf-8")
        new_text = text
        for old, new in _SPOTLIGHT_CAP_EDITS:
            if new in new_text:
                continue
            if new_text.count(old) != 1:
                raise SystemExit(f"sync-skills.py: ERROR - caption pop anchor {old.strip().splitlines()[0][:60]!r} "
                                 f"found {new_text.count(old)} time(s) in {path} ({recipe}); "
                                 "the WI2.88 transform cannot apply")
            new_text = new_text.replace(old, new, 1)
        if new_text != text:
            path.write_text(new_text, encoding="utf-8")
            changed += 1
    return changed


# WI2.96: re-smoke 26 (Render 48ef94d) showed the end-card headline "Follow Test Brand for more" as
# "FOLLOW TEST / BRAND FOR / MORE": the WI2.93 hero is a flex-wrap row of single words, so the brand name
# broke across lines and the lines were unbalanced. cta-card.py now makes the brand name (the kicker text,
# matched in the hero case-insensitively) one nowrap unit with non-breaking spaces, and the page lays the
# units out on the fewest lines (max 3) whose most balanced split fits the safe width, shrinking the font
# when none does; a unit still too wide at the floor size (a very long brand name) shrinks on its own. The
# kicker (the brand name again) stays on one line and shrinks to fit. It refits once fonts load. Every word
# is still html-escaped. Runs after WI2.93 (it upgrades the WI2.93 write_project text in place).
SPOTLIGHT_CTA_FIT_HERO_W = 920  # (1080 - 2 x 60) / 1.04 breathe, rounded down to 920
SPOTLIGHT_CTA_FIT_KICKER_W = 960  # 1080 - 2 x 60
_SPOTLIGHT_CTA_FIT_HERO_OLD = r"""        if kind == "hero":
            words = " ".join(f'<span class="word">{html.escape(t)}</span>' for t in layer["text"].split())
            parts.append(f'<div class="layer hero {cls}">{words}</div>')
        else:
            parts.append(f'<div class="layer {kind} {cls}">{html.escape(layer["text"])}</div>')
"""
SPOTLIGHT_CTA_FIT_HERO = r"""        if kind == "hero":
            # WI2.96: the brand name (the kicker text) is ONE unit: a nowrap span whose words are joined by
            # non-breaking spaces, so the headline never splits it ("FOLLOW TEST / BRAND FOR / MORE").
            norm = lambda t: t.strip(".,!?:;'\"()").upper()
            keep = [norm(t) for t in next((l["text"] for l in card["layers"] if l["type"] == "kicker"), "").split()]
            toks, units, i = layer["text"].split(), [], 0
            while i < len(toks):
                if keep and [norm(t) for t in toks[i:i + len(keep)]] == keep:
                    units.append('<span class="word brand">'
                                 + "&#160;".join(html.escape(t) for t in toks[i:i + len(keep)]) + "</span>")
                    i += len(keep)
                else:
                    units.append(f'<span class="word">{html.escape(toks[i])}</span>')
                    i += 1
            words = " ".join(units)
            parts.append(f'<div class="layer hero {cls}" data-size="{size}">{words}</div>')
        else:
            parts.append(f'<div class="layer {kind} {cls}" data-size="{size}">{html.escape(layer["text"])}</div>')
"""
_SPOTLIGHT_CTA_FIT_CSS_OLD = r"""      #cta-card .word {{ display: inline-block; }}
"""
SPOTLIGHT_CTA_FIT_CSS = r"""      #cta-card .word {{ display: inline-block; }}
      #cta-card .hero .line {{ flex: 0 0 100%; display: flex; justify-content: center; gap: 0 0.28em; }}
      #cta-card .hero .word {{ flex: none; }}
      #cta-card .word.brand, #cta-card .kicker {{ white-space: nowrap; }}
"""
_SPOTLIGHT_CTA_FIT_JS_OLD = r"""    css_text, body_text = "".join(css), "\n        ".join(parts)
"""
SPOTLIGHT_CTA_FIT_JS = _SPOTLIGHT_CTA_FIT_JS_OLD + r"""    # WI2.96: fit the headline and the kicker before the timeline is built, and again once fonts load.
    fit_js = r'''        // WI2.96: the brand name is one hero unit (.word.brand, nowrap) and never breaks. The units go on
        // the fewest lines (max 3) whose most balanced split fits HERO_MAX_W ((1080 - 2 x 60) / 1.04 breathe),
        // at the design size when possible, else the font shrinks; at HERO_MIN a unit still wider than the
        // safe width (a very long brand name) shrinks on its own. The kicker stays on one line inside
        // KICKER_MAX_W. Refit once fonts load. The text is never cut.
        var HERO_MAX_W = __HERO_W__, HERO_MAX_LINES = 3, HERO_MIN = 60, KICKER_MAX_W = __KICKER_W__;
        function fitOne(el, base, maxW) {
          el.style.fontSize = base + "px";
          var w = el.scrollWidth;
          if (w <= maxW) return;
          var size = Math.floor(base * maxW / w);
          el.style.fontSize = size + "px";
          while (size > 8 && el.scrollWidth > maxW) { size -= 1; el.style.fontSize = size + "px"; }
        }
        function splitLines(ws, gap) {
          var n = ws.length;
          function span(a, b) { var s = gap * (b - a - 1); for (var i = a; i < b; i++) s += ws[i]; return s; }
          for (var k = 1; k <= Math.min(HERO_MAX_LINES, n); k++) {
            var cuts = [], best = null, bestW = Infinity;
            if (k === 1) cuts.push([]);
            if (k === 2) for (var a = 1; a < n; a++) cuts.push([a]);
            if (k === 3) for (var b = 1; b < n - 1; b++) for (var c = b + 1; c < n; c++) cuts.push([b, c]);
            cuts.forEach(function (cut) {
              var edges = [0].concat(cut, [n]), widest = 0;
              for (var j = 0; j < k; j++) widest = Math.max(widest, span(edges[j], edges[j + 1]));
              if (widest < bestW) { bestW = widest; best = edges; }
            });
            if (bestW <= HERO_MAX_W) return best;
          }
          return null;
        }
        function fitHero() {
          var hero = document.querySelector("#cta-card .hero");
          if (!hero) return;
          var units = Array.prototype.slice.call(hero.querySelectorAll(".word"));
          if (!units.length) return;
          var size = parseFloat(hero.getAttribute("data-size")) || 110, edges = null;
          for (;;) {
            hero.style.fontSize = size + "px";
            units.forEach(function (u) {
              u.style.fontSize = "";
              if (size <= HERO_MIN && u.scrollWidth > HERO_MAX_W) fitOne(u, size, HERO_MAX_W);
            });
            edges = splitLines(units.map(function (u) { return u.scrollWidth; }), size * 0.28);
            if (edges || size <= 8) break;
            size = size > HERO_MIN ? Math.max(HERO_MIN, Math.floor(size * 0.94)) : size - 2;
          }
          if (!edges) edges = [0, units.length];
          var old = Array.prototype.slice.call(hero.querySelectorAll(".line"));
          for (var j = 0; j + 1 < edges.length; j++) {
            var row = document.createElement("div");
            row.className = "line";
            for (var i = edges[j]; i < edges[j + 1]; i++) row.appendChild(units[i]);
            hero.appendChild(row);
          }
          old.forEach(function (r) { hero.removeChild(r); });
        }
        function fitCard() {
          var kicker = document.querySelector("#cta-card .kicker");
          if (kicker) fitOne(kicker, parseFloat(kicker.getAttribute("data-size")) || 52, KICKER_MAX_W);
          fitHero();
        }
        fitCard();
        if (document.fonts && document.fonts.ready) { document.fonts.ready.then(fitCard); }
'''
""".replace("__HERO_W__", str(SPOTLIGHT_CTA_FIT_HERO_W)).replace("__KICKER_W__", str(SPOTLIGHT_CTA_FIT_KICKER_W))
_SPOTLIGHT_CTA_FIT_DOC_OLD = r"""        var DUR = {dur};
"""
SPOTLIGHT_CTA_FIT_DOC = r"""        var DUR = {dur};
{fit_js}"""
_SPOTLIGHT_CTA_FIT_EDITS = (
    (_SPOTLIGHT_CTA_FIT_HERO_OLD, SPOTLIGHT_CTA_FIT_HERO),
    (_SPOTLIGHT_CTA_FIT_CSS_OLD, SPOTLIGHT_CTA_FIT_CSS),
    (_SPOTLIGHT_CTA_FIT_JS_OLD, SPOTLIGHT_CTA_FIT_JS),
    (_SPOTLIGHT_CTA_FIT_DOC_OLD, SPOTLIGHT_CTA_FIT_DOC),
)
SPOTLIGHT_CTA_SCRIPT = Path("scripts") / "cta-card.py"


def apply_spotlight_end_card_fit(directory: Path, recipe: str) -> int:
    """WI2.96: every full p-reels-spotlight copy under `directory` (top-level or .hub/p-reels-spotlight)
    has a scripts/cta-card.py whose end-card headline keeps the brand name on one line, balances its lines
    and shrinks to fit the safe width (the kicker too), refitting once fonts load. Upgrades the WI2.93
    write_project text in place. Idempotent; fails fast when a copy lost cta-card.py or an anchor, or when
    a spotlight recipe ships no full p-reels-spotlight copy."""
    changed = 0
    if not directory.is_dir():
        return 0
    roots = [directory] if directory.name == "p-reels-spotlight" else []
    roots += sorted(p for p in directory.rglob("p-reels-spotlight") if p.is_dir() and p.parent.name == ".hub")
    roots = [r for r in roots if (r / "SKILL.md").is_file()]
    if recipe.startswith("p-reels-spotlight") and not roots:
        raise SystemExit(f"sync-skills.py: ERROR - no full p-reels-spotlight copy under {directory} "
                         f"({recipe}); the WI2.96 transform cannot apply")
    for root in roots:
        path = root / SPOTLIGHT_CTA_SCRIPT
        if not path.is_file():
            raise SystemExit(f"sync-skills.py: ERROR - {path} is missing ({recipe}); the WI2.96 transform cannot apply")
        text = path.read_text(encoding="utf-8")
        new_text = text
        for old, new in _SPOTLIGHT_CTA_FIT_EDITS:
            if new in new_text:
                continue
            if new_text.count(old) != 1:
                raise SystemExit(f"sync-skills.py: ERROR - end-card fit anchor {old.strip().splitlines()[0][:60]!r} "
                                 f"found {new_text.count(old)} time(s) in {path} ({recipe}); "
                                 "the WI2.96 transform cannot apply")
            new_text = new_text.replace(old, new, 1)
        if new_text != text:
            path.write_text(new_text, encoding="utf-8")
            changed += 1
    return changed


# WI2.95: spotlight takeover text names a different brand. Smoke 25 (p-reels-spotlight, order brand
# "Test Brand", a CFW promo talking-head) showed the tk-list title "CFW WRITES THE MONTH"; re-smoke 26
# (Render 48ef94d) showed "CFW knows her voice" at 30.5-36.5 s while the clip says "CFW already learned
# her voice". The plan_edit step writes that text: it reworded the speech and kept the clip's brand.
# Step 03 (and SKILL.md Step 4) now write work/takeover_brand.py and run it on the plan: a takeover line
# that is an exact run of transcript words is a quote and stays; any other line that carries a spoken
# acronym / CamelCase name (or a CamelCase word) the order does not own gets the order's brand
# (inputs/cta/cta.json brandName, else brief.json brand.name, as on the end card) or, with no order
# brand, loses the name. The plan guard runs its --check, and rule 5 states the rule to the planner.
# Review rework of 68e13f0: a quote needs 3+ transcript words and may not be mostly the foreign name;
# generic acronyms (CAC, MLS, HOA, NYC, PhD, ...), lower-case-first words (iPhone, iOS), Mc/Mac/O'/De
# names, all-caps emphasis runs and common words said in capitals (NO) are never swapped; a spelled-out acronym ("C F W") counts; the HTML
# text is tokenised unescaped (CFW&nbsp;writes); the guard has no second import; rule 5 also forbids
# competitor / comparison lines that name another brand. Earlier WI2.95 text is upgraded in place.
SPOTLIGHT_TK_BRAND_PY = r'''# WI2.95: takeover text names only the order's brand, unless it quotes the speech word for word.
# usage: python3 work/takeover_brand.py PLAN.json WORDS.json [BRAND]          (repair takeovers in place)
#        python3 work/takeover_brand.py --check PLAN.json WORDS.json [BRAND]  (exit 1 on a foreign name)
# BRAND is the order's brand name ("" = the order has none). Without it the brand comes from the
# step workdir: inputs/cta/cta.json brandName, else brief.json brand.name (as the end card does).
# A foreign name is a brand-like word the speech says that the order does not own: an acronym (CFW,
# also spelled out "C F W") or a CamelCase word (HubSpot). It is never a generic acronym (AI, CAC,
# MLS, HOA, NYC, PhD, ...), a channel or tool (Instagram, iPhone, ...), a word that starts lower case
# (iOS, eBay) or a Mc/Mac/O'/De/Le name (McKenzie). A line of 3+ words that is an exact run of
# transcript words (case and punctuation aside) is a quote and keeps its words, unless the foreign
# name is most of it. Otherwise the name becomes the order's brand; with no order brand it is dropped.
# A brand is never invented. When in doubt a word is left alone: rule 5 asks the planner for the rest.
import html, json, os, re, sys

TOKEN = re.compile(r"[A-Za-z0-9]+(?:['’.&-][A-Za-z0-9]+)*")
TAG = re.compile(r"(<[^>]*>)")
POSS = re.compile(r"['’]s$", re.I)
NAME_PREFIX = re.compile(r"^(?:Mc|Mac|O['’]|D['’]|De|Di|Da|Du|Le|La|Van|Von|St)[A-Z]")
SKIP = {"tk-typing-ui": {"LABEL", "TYPING_SPEED"}}
HTML_KEYS = {"TITLE", "QUOTE"}
MIN_QUOTE = 3
# Never a competing brand: generic business, marketing, finance, real-estate, place and tech
# acronyms, and the channels / tools a reel talks about.
GENERIC = set("""
i ok ai api apis ceo ceos cto cfo coo cmo cro vp svp evp md phd mba cpa cfa jd rn pa hr pr it qa
diy faq faqs pdf url sms dm dms fyi asap eta tbh imo lol omg vip am pm est pst cst mst utc
q1 q2 q3 q4 ytd mtd yoy qoq mom b2b b2c d2c dtc smb smbs saas crm cms erp kpi kpis okr okrs roi
roas aov ltv cac cpc cpm cpa cpl ctr cvr ppc sem seo ugc cta ctas mrr arr gmv nps sop sops mvp
llc inc ltd co corp plc nda llp gst vat irs ira etf ipo sba fico heloc dti pmi apr apy arm emi gdp
usd eur gbp cad aud inr jpy cny
mls hoa fha va usda adu adus hvac reo nar cma hud fsbo noi reit reits sqft sf bd ba ac gc hoas
usa us uk eu uae nyc la sf dc nj ny ca tx fl wa nc ga az co il ma pa oh mi uk gta bc on nsw
tv hd uhd 4k 8k pc ios os wifi usb gps app apps vr ar xr iot gpu cpu ram ssd llm llms gpt ml nft nfts
btc eth qr id ip sdk ui ux js css html sql aws gcp
instagram ig tiktok youtube yt linkedin facebook fb threads pinterest reddit x twitter whatsapp
snapchat google gmail chatgpt claude gemini openai anthropic iphone ipad android macbook mac zoom
slack excel outlook zillow
""".split())
# Common words a transcript may put in capitals for emphasis ("NO", "STOP"): never a brand name.
COMMON = set("""
no so go do we me my he be by us or an at on in to up of if is it as yes now new top big best free win
wow stop look this that what when why how who you your our all one two ten get got see the and but not
just more most less real true easy fast huge done love hate need want must never ever only
""".split())


def norm(t):
    return re.sub(r"[^a-z0-9']", "", t.lower().replace("’", "'"))


def base(t):
    return norm(POSS.sub("", t))


def shaped(t):
    """an acronym (2-6 capitals, no lower case) or CamelCase word (HubSpot), by its own spelling;
    never a lower-case-first word (iPhone, iOS) or a Mc/Mac/O'/De/Le name (McKenzie)"""
    b = POSS.sub("", t)
    if not b[:1].isupper() or NAME_PREFIX.match(b):
        return False
    letters = re.sub(r"[^A-Za-z]", "", b)
    if 2 <= len(letters) <= 6 and letters.isupper():
        return True
    return bool(re.fullmatch(r"[A-Z][a-z]+(?:[A-Z][a-z0-9]*)+", b))


def plain(v):
    return html.unescape(TAG.sub(" ", v))


def stop(msg):
    print("takeover brand check: " + msg, file=sys.stderr)
    sys.exit(1)


def order_brand():
    cta = {}
    if os.path.isfile("inputs/cta/cta.json"):
        cta = json.load(open("inputs/cta/cta.json"))
    if not os.path.isfile("brief.json") and not cta:
        stop("no order brand: pass BRAND, or run in the step workdir with brief.json (WI2.95)")
    brief = json.load(open("brief.json")) if os.path.isfile("brief.json") else {}
    b = (brief.get("brand") or {}) if isinstance(brief, dict) else {}
    return str((cta.get("brandName") if isinstance(cta, dict) else "") or b.get("name") or "").strip()


def transcript(words):
    """the transcript's plain tokens, the brand-like names it speaks, and its spelled-out letter runs"""
    toks, raw, stops, names, letters = [], [], [], set(), []
    for w in words:
        t = str(w.get("text", w.get("w", w.get("word", "")))) if isinstance(w, dict) else str(w)
        for m in TOKEN.finditer(t):
            toks.append(norm(m.group(0)))
            raw.append(m.group(0))
            stops.append(bool(re.match(r"\s*[.!?,;:…]", t[m.end():])))   # punctuation ends a run
    caps = [bool(re.search(r"[A-Z]", r)) and not re.search(r"[a-z]", r) and len(r) > 1 for r in raw]
    plainly = {b for r, b in zip(raw, toks) if not r.isupper()}
    for k, r in enumerate(raw):
        if not shaped(r):
            continue
        # an all-caps run of 2+ words ("NYC TEAM", "SO GOOD") is emphasis, and a word also said in
        # lower case is an ordinary word: neither is a name
        if caps[k] and ((k and caps[k - 1] and not stops[k - 1]) or (k + 1 < len(raw) and caps[k + 1] and not stops[k])
                        or base(r) in plainly):
            continue
        if base(r) not in COMMON:
            names.add(base(r))
    run = []
    for t in toks + [""]:   # "C F W" spoken letter by letter: every 3+ letter run is a name
        if len(t) == 1 and t.isalpha() and t not in ("a", "i"):
            run.append(t)
            continue
        for i in range(len(run)):
            for j in range(i + 3, len(run) + 1):
                letters.append("".join(run[i:j]))
        run = []
    return toks, names, set(letters)


def all_caps(value):
    letters = re.sub(r"[^A-Za-z]", "", plain(value))
    return bool(letters) and letters.isupper()


def foreign(value, names, spelled, own):
    """the foreign names in this line: a spoken name written as an acronym / CamelCase word (or in an
    all-caps word), or a spelled-out letter run ("C F W") written as an acronym"""
    out = []
    for m in TOKEN.finditer(plain(value)):
        tok, b = m.group(0), base(m.group(0))
        if not b or b in own or b in GENERIC or b in COMMON or not re.search(r"[a-z]", b):
            continue
        bare = POSS.sub("", tok)
        if not bare[:1].isupper() or NAME_PREFIX.match(bare):
            continue
        upper = re.sub(r"[^A-Za-z]", "", bare).isupper()
        if (b in names and (upper or shaped(bare))) or (b in spelled and upper and len(b) >= 3):
            out.append(tok)
    return out


def quoted(value, said, hits):
    toks = [t for t in (norm(t) for t in TOKEN.findall(plain(value))) if t]
    if len(toks) < MIN_QUOTE or 2 * len(hits) > len(toks):
        return False
    return (" " + " ".join(toks) + " ") in (" " + " ".join(said) + " ")


def fix_text(seg, names_hit, brand, caps):
    hit = {base(t) for t in names_hit}
    toks = list(TOKEN.finditer(seg))
    out, pos, i = [], 0, 0
    while i < len(toks):
        m = toks[i]
        if base(m.group(0)) not in hit:
            i += 1
            continue
        j = i  # a run of adjacent names ("Acme Labs") is one name
        while j + 1 < len(toks) and base(toks[j + 1].group(0)) in hit and seg[toks[j].end():toks[j + 1].start()].strip() == "":
            j += 1
        poss = POSS.search(toks[j].group(0))
        out.append(seg[pos:m.start()])
        pos = toks[j].end()
        if brand:
            out.append((brand.upper() if caps else brand) + (poss.group(0) if poss else ""))
        else:
            # drop the name and the space after it (or before it at the end)
            if seg[pos:pos + 1].isspace():
                pos += 1
            elif out and out[-1][-1:].isspace():
                out[-1] = out[-1][:-1]
        i = j + 1
    out.append(seg[pos:])
    return "".join(out)


def fix_value(value, names_hit, brand, is_html):
    caps = all_caps(value)
    if not is_html:
        return re.sub(r"\s{2,}", " ", fix_text(value, names_hit, brand, caps)).strip()
    hit = {base(t) for t in names_hit}
    parts = []
    for p in TAG.split(value):
        if TAG.fullmatch(p):
            parts.append(p)
            continue
        text = html.unescape(p)   # tokenise the text as shown (CFW&nbsp;writes is CFW + writes)
        if not any(base(t) in hit for t in TOKEN.findall(text)):
            parts.append(p)
            continue
        parts.append(html.escape(fix_text(text, names_hit, brand, caps), quote=False).replace("\xa0", "&nbsp;"))
    new = re.sub(r"<span[^>]*>\s*</span>", "", "".join(parts))
    return re.sub(r"[ \t]{2,}", " ", new).strip()


def problems(plan, said, names, spelled, own):
    bad = []
    for i, tk in enumerate(plan.get("takeovers") or []):
        fill = tk.get("fill") if isinstance(tk, dict) else None
        if not isinstance(fill, dict):
            continue
        skip = SKIP.get(tk.get("template"), set())
        for key, v in fill.items():
            if key in skip or not isinstance(v, str):
                continue
            hits = foreign(v, names, spelled, own)
            if hits and not quoted(v, said, hits):
                bad.append((i, key, v, hits))
    return bad


def main(argv):
    check = argv[:1] == ["--check"]
    args = argv[1:] if check else argv
    if len(args) not in (2, 3):
        stop("usage: takeover_brand.py [--check] PLAN.json WORDS.json [BRAND] (WI2.95)")
    path, wpath = args[0], args[1]
    brand = args[2].strip() if len(args) == 3 else order_brand()
    for p in (path, wpath):
        if not os.path.isfile(p):
            stop("file not found: %s (WI2.95)" % p)
    try:
        plan, words = json.load(open(path)), json.load(open(wpath))
    except ValueError as exc:
        stop("not valid JSON: %s (WI2.95)" % exc)
    if isinstance(words, dict):
        words = words.get("words") or []
    if not isinstance(plan, dict) or not isinstance(words, list):
        stop("plan must be a JSON object and words a JSON list (WI2.95)")
    said, names, spelled = transcript(words)
    own = {base(t) for t in TOKEN.findall(brand)}
    bad = problems(plan, said, names, spelled, own)
    if check:
        for i, key, v, hits in bad:
            print("takeover brand check: takeover %d %s %r names %s, not the order brand %r, and is not a word-for-word "
                  "quote of the speech - quote the speech or use the order brand (WI2.95)"
                  % (i + 1, key, v, "/".join(hits), brand or "(none)"), file=sys.stderr)
        sys.exit(1 if bad else 0)
    for i, key, v, hits in bad:
        tk = plan["takeovers"][i]
        new = fix_value(v, hits, brand, key in HTML_KEYS)
        if not re.search(r"[A-Za-z0-9]", plain(new)):
            stop("takeover %d %s %r is only a foreign name; rewrite it from the speech (WI2.95)" % (i + 1, key, v))
        tk["fill"][key] = new
        print("[plan] takeover %d %s: %r -> %r (names %s; order brand %r)" % (i + 1, key, v, new, "/".join(hits), brand or "(none)"))
    if bad:
        json.dump(plan, open(path, "w"), indent=2)
    else:
        print("[plan] takeover brand: no foreign brand names, plan unchanged")
    left = problems(plan, said, names, spelled, own)
    for i, key, v, hits in left:
        print("takeover brand check: takeover %d %s %r still names %s (WI2.95)" % (i + 1, key, v, "/".join(hits)), file=sys.stderr)
    sys.exit(1 if left else 0)


if __name__ == "__main__":
    main(sys.argv[1:])
'''
_SPOTLIGHT_TK_BRAND_RULE_OLD = (
    "   in that window. Use `tk-typing-ui` only when the content involves AI / prompts / terminal work.\n"
)
_SPOTLIGHT_TK_BRAND_RULE_WI295A = (
    "   in that window. Use `tk-typing-ui` only when the content involves AI / prompts / terminal work.\n"
    "   Takeover text names only the order's brand (WI2.95): quote the speech word for word, or write the\n"
    "   order's brand in place of any other brand or product the clip names; never invent a brand.\n"
)
SPOTLIGHT_TK_BRAND_RULE = (
    "   in that window. Use `tk-typing-ui` only when the content involves AI / prompts / terminal work.\n"
    "   Takeover text names only the order's brand (WI2.95): quote the speech word for word, or write the\n"
    "   order's brand in place of any other brand or product the clip names; never invent a brand, and\n"
    "   never write a competitor or comparison line that names another brand (`X vs Y`, `better than X`).\n"
)
_SPOTLIGHT_TK_BRAND_GUARD_ANCHOR = "Then run the mechanical guard — fix the plan and rerun until it prints `plan OK`:\n"
_SPOTLIGHT_TK_BRAND_SECTION_HELPER = (
    "```bash\nmkdir -p work saves\ncat > work/takeover_brand.py <<'PY'\n" + SPOTLIGHT_TK_BRAND_PY + "PY\n```\n\n"
    "```bash\npython3 work/takeover_brand.py saves/edit_plan.json work/words.json || exit 1\n```\n\n"
)
_SPOTLIGHT_TK_BRAND_SECTION_WI295A = (
    "Keep takeover text on the order's brand (WI2.95). A clip may name another brand or product (a CFW\n"
    "promo cut for a `Test Brand` order says `CFW already learned her voice`). A takeover line that quotes\n"
    "the speech word for word keeps it. Any other line that carries a spoken acronym or CamelCase name\n"
    "(`CFW`, `HubSpot`) the order does not own gets the order's brand instead (`inputs/cta/cta.json`\n"
    "`brandName`, else `brief.json` `brand.name`, as on the end card), or loses the name when the order\n"
    "has no brand. Write the helper, then run it on the plan; it prints each line it changed.\n\n"
    + _SPOTLIGHT_TK_BRAND_SECTION_HELPER
)
SPOTLIGHT_TK_BRAND_SECTION = (
    "Keep takeover text on the order's brand (WI2.95). A clip may name another brand or product (a CFW\n"
    "promo cut for a `Test Brand` order says `CFW already learned her voice`). A takeover line of 3+ words\n"
    "that quotes the speech word for word keeps it. Any other line that carries a spoken acronym (also\n"
    "spelled out, `C F W`) or CamelCase name (`CFW`, `HubSpot`) the order does not own gets the order's\n"
    "brand instead (`inputs/cta/cta.json` `brandName`, else `brief.json` `brand.name`, as on the end card),\n"
    "or loses the name when the order has no brand. Generic acronyms (`CAC`, `MLS`, `HOA`, `NYC`, `PhD`),\n"
    "`iPhone`-style words and names like `McKenzie` are never swapped. Write the helper, then run it on\n"
    "the plan; it prints each line it changed.\n\n"
    + _SPOTLIGHT_TK_BRAND_SECTION_HELPER
)
_SPOTLIGHT_TK_BRAND_PRINT = "print(f\"plan OK: {len(p['caption_groups'])} groups, {len(tks)} takeovers"
_SPOTLIGHT_TK_BRAND_GUARD_WI295A = (
    "import subprocess\n"
    "assert subprocess.run([sys.executable, \"work/takeover_brand.py\", \"--check\", sys.argv[1], \"work/words.json\"]).returncode == 0, \\\n"
    "    \"takeover text names a brand the order does not own (WI2.95) — run python3 work/takeover_brand.py saves/edit_plan.json work/words.json\"\n"
)
SPOTLIGHT_TK_BRAND_GUARD = (
    "assert __import__(\"subprocess\").run([sys.executable, \"work/takeover_brand.py\", \"--check\", sys.argv[1], \"work/words.json\"]).returncode == 0, \\\n"
    "    \"takeover text names a brand the order does not own (WI2.95) — run python3 work/takeover_brand.py saves/edit_plan.json work/words.json\"\n"
)
_SPOTLIGHT_TK_BRAND_SKILL_RULE_OLD = (
    "   SAID in that window. Use tk-typing-ui only when the content involves AI/prompts/terminal workflows.\n"
)
_SPOTLIGHT_TK_BRAND_SKILL_RULE_WI295A = (
    "   SAID in that window. Use tk-typing-ui only when the content involves AI/prompts/terminal workflows.\n"
    "   Takeover text names only the order's brand ($BRAND_NAME, WI2.95): quote the speech word for word,\n"
    "   or write the order's brand in place of any other brand or product the clip names; never invent one.\n"
)
SPOTLIGHT_TK_BRAND_SKILL_RULE = (
    "   SAID in that window. Use tk-typing-ui only when the content involves AI/prompts/terminal workflows.\n"
    "   Takeover text names only the order's brand ($BRAND_NAME, WI2.95): quote the speech word for word,\n"
    "   or write the order's brand in place of any other brand or product the clip names; never invent one,\n"
    "   and never write a competitor or comparison line that names another brand (X vs Y, better than X).\n"
)
_SPOTLIGHT_TK_BRAND_SKILL_GUARD_OLD = "python3 - \"$W/plan.json\" \"$DUR\" <<'PY'\n"
SPOTLIGHT_TK_BRAND_SKILL_GUARD = (
    "# WI2.95: takeover text names only the order's brand unless it quotes the speech word for word.\n"
    "cat > \"$W/takeover_brand.py\" <<'PY'\n" + SPOTLIGHT_TK_BRAND_PY + "PY\n"
    "python3 \"$W/takeover_brand.py\" \"$W/plan.json\" \"$W/words.json\" \"$BRAND_NAME\" || exit 1\n"
    "BRAND_NAME=\"$BRAND_NAME\" python3 - \"$W/plan.json\" \"$DUR\" <<'PY'\n"
)
_SPOTLIGHT_TK_BRAND_SKILL_PRINT = "print(f\"plan OK: {len(p['caption_groups'])} groups, {len(p.get('takeovers',[]))} takeovers, \"\n"
SPOTLIGHT_TK_BRAND_SKILL_CHECK = (
    "import os, subprocess\n"
    "_d = os.path.dirname(sys.argv[1])\n"
    "assert subprocess.run([sys.executable, os.path.join(_d, \"takeover_brand.py\"), \"--check\", sys.argv[1],\n"
    "                       os.path.join(_d, \"words.json\"), os.environ.get(\"BRAND_NAME\", \"\")]).returncode == 0, \\\n"
    "    \"takeover text names a brand the order does not own (WI2.95) — run python3 $W/takeover_brand.py\"\n"
)
_SPOTLIGHT_TK_BRAND_FILES = (
    # (file under a spotlight root, only in a full p-reels-spotlight copy,
    #  edits as (anchor, new, insert-before, earlier WI2.95 texts upgraded in place to `new`))
    (Path("steps") / "03-plan-edit.md", False,
     ((_SPOTLIGHT_TK_BRAND_RULE_OLD, SPOTLIGHT_TK_BRAND_RULE, False, (_SPOTLIGHT_TK_BRAND_RULE_WI295A,)),
      (_SPOTLIGHT_TK_BRAND_GUARD_ANCHOR, SPOTLIGHT_TK_BRAND_SECTION, True, (_SPOTLIGHT_TK_BRAND_SECTION_WI295A,)),
      (_SPOTLIGHT_TK_BRAND_PRINT, SPOTLIGHT_TK_BRAND_GUARD, True, (_SPOTLIGHT_TK_BRAND_GUARD_WI295A,)))),
    (Path("SKILL.md"), True,
     ((_SPOTLIGHT_TK_BRAND_SKILL_RULE_OLD, SPOTLIGHT_TK_BRAND_SKILL_RULE, False, (_SPOTLIGHT_TK_BRAND_SKILL_RULE_WI295A,)),
      (_SPOTLIGHT_TK_BRAND_SKILL_GUARD_OLD, SPOTLIGHT_TK_BRAND_SKILL_GUARD, False, ()),
      (_SPOTLIGHT_TK_BRAND_SKILL_PRINT, SPOTLIGHT_TK_BRAND_SKILL_CHECK, True, ()))),
)
# An earlier WI2.95 helper body in a copy is replaced by the current one before the edits above.
_SPOTLIGHT_TK_BRAND_HELPER_RE = re.compile(r"(cat > (?:work/|\"\$W/)takeover_brand\.py\"? <<'PY'\n)(.*?\n)(PY\n)", re.S)


def apply_spotlight_takeover_brand(directory: Path, recipe: str) -> int:
    """WI2.95: every p-reels-spotlight copy under `directory` (the top-level p-reels-spotlight /
    p-reels-spotlight-heygen steps/03-plan-edit.md, .hub/p-reels-spotlight, and SKILL.md Step 4 of each
    full copy) writes work/takeover_brand.py and runs it on the plan, so takeover text names only the
    order's brand unless it quotes the speech word for word; the plan guard runs its --check and rule 5
    states it. Idempotent; fails fast when a copy lost its anchor or file, or when a spotlight recipe
    ships no plan-edit step."""
    changed = 0
    if not directory.is_dir():
        return 0
    plan_step = Path("steps") / "03-plan-edit.md"
    roots = [directory] if directory.name.startswith("p-reels-spotlight") else []
    roots += sorted(p for p in directory.rglob("p-reels-spotlight") if p.is_dir() and p.parent.name == ".hub")
    roots = [r for r in roots if (r / plan_step).is_file()]
    if recipe.startswith("p-reels-spotlight") and not roots:
        raise SystemExit(f"sync-skills.py: ERROR - no p-reels-spotlight {plan_step} under {directory} "
                         f"({recipe}); the WI2.95 transform cannot apply")
    for root in roots:
        for rel, full_only, edits in _SPOTLIGHT_TK_BRAND_FILES:
            if full_only and root.name != "p-reels-spotlight":
                continue
            path = root / rel
            if not path.is_file():
                raise SystemExit(f"sync-skills.py: ERROR - {path} is missing ({recipe}); the WI2.95 transform cannot apply")
            text = path.read_text(encoding="utf-8")
            helpers = _SPOTLIGHT_TK_BRAND_HELPER_RE.findall(text)
            if len(helpers) > 1:
                raise SystemExit(f"sync-skills.py: ERROR - {len(helpers)} takeover_brand.py helpers in {path} ({recipe}); "
                                 "the WI2.95 transform cannot apply")
            new_text = _SPOTLIGHT_TK_BRAND_HELPER_RE.sub(lambda m: m.group(1) + SPOTLIGHT_TK_BRAND_PY + m.group(3), text)
            for old, new, before, earlier in edits:
                if new in new_text:
                    continue
                prev = next((e for e in earlier if new_text.count(e) == 1), None)
                if prev is not None:
                    new_text = new_text.replace(prev, new, 1)
                    continue
                if new_text.count(old) != 1:
                    raise SystemExit(f"sync-skills.py: ERROR - takeover brand anchor {old.strip().splitlines()[0][:60]!r} "
                                     f"found {new_text.count(old)} time(s) in {path} ({recipe}); "
                                     "the WI2.95 transform cannot apply")
                new_text = new_text.replace(old, (new + old) if before else new, 1)
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
        rel = p.relative_to(root)
        # Generated bytecode is never part of a recipe. A stray import of a bundled script
        # (an editor, a probe, a test) must not change the pinned file list or its hashes.
        if "__pycache__" in rel.parts or p.suffix in (".pyc", ".pyo"):
            continue
        if p.is_file() and p.name not in IGNORE_NAMES:
            out.append(str(rel).replace("\\", "/"))
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

        # WI2.73: the chat mock-up finishes typing before the cut (every c-typing-ui copy).
        apply_typing_hold(recipe_dest, recipe)

        # WI2.80: step 04 names the real c-typing-ui render; its SKILL.md states the shipped timing.
        apply_typing_render_usage(recipe_dest, recipe)

        # WI2.83: the spotlight big-stat takeover fits its stat to the safe width (every copy);
        # WI2.85: its slam-in start scale is capped to the same safe width.
        apply_spotlight_stat_fit(recipe_dest, recipe)

        # WI2.86: the spotlight end card starts only after the last spoken word ends (every copy).
        apply_spotlight_end_card(recipe_dest, recipe)

        # WI2.89: the bed gets a silent end-card tail so the card always fits after the last word.
        apply_spotlight_bed_tail(recipe_dest, recipe)

        # WI2.87: the typing takeover is a real sub-composition, so the HyperFrames render runs (every copy).
        apply_spotlight_typing_takeover(recipe_dest, recipe)

        # WI2.93: the end card renders through hyperframes from a project dir, or the step fails (every copy).
        apply_spotlight_end_card_render(recipe_dest, recipe)

        # WI2.92: a failed takeover render fails step 05 with the hyperframes error; no still cards (every copy).
        apply_spotlight_takeover_render_fail_loud(recipe_dest, recipe)

        # WI2.94: every single-line takeover text (tk-stat label, tk-list title/items, ...) fits on one line.
        apply_spotlight_takeover_line_fit(recipe_dest, recipe)

        # WI2.90: step 06 fails when the end card has no room; SKILL.md reads the order's cta_card (every copy).
        apply_spotlight_end_card_room(recipe_dest, recipe)

        # WI2.91: the typing takeover's prompt is a JSON-encoded JS literal; its card label is CARD_LABEL (every copy).
        apply_spotlight_typing_prompt(recipe_dest, recipe)

        # WI2.88: the caption emphasis word is a plain word until spoken; its pop keeps the space before it.
        apply_spotlight_caption_pop(recipe_dest, recipe)

        # WI2.96: the end-card headline keeps the brand name on one line, balanced and fitted (every copy).
        apply_spotlight_end_card_fit(recipe_dest, recipe)

        # WI2.95: takeover text names only the order's brand unless it quotes the speech (every copy).
        apply_spotlight_takeover_brand(recipe_dest, recipe)

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
