#!/usr/bin/env python3
"""Offline tests for p-ai-image steps 02 and 03 (WI31.14).

  python3 -I harness/skills/p-ai-image/test/test_image_steps.py -v

No network, no kie.ai calls and no paid APIs. Needs python3, bash and ImageMagick
(`convert`), which the recipe needs too. Every test runs the step's OWN code block, read
from the step file, in a throwaway step workdir, so an edit that brings a fault back fails.

- 02 generate: the contact sheet is made under `set -e` on a machine whose ImageMagick has
  no default font (a `montage` shim emulates the Mac where `montage` exits 1 with "unable to
  read font"), for every allowed count (1, 2, 3, 4, 6).
- 03 qa_gate: the re-split loop does nothing for one image and crops images 2..N for N >= 2,
  with a `seq` shim that counts down like macOS seq ("seq 2 1" prints "2 1").
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
STEP02 = os.path.join(SKILL_DIR, "steps", "02-generate.md")
STEP03 = os.path.join(SKILL_DIR, "steps", "03-qa-gate.md")

W, H = 120, 90  # a small canvas keeps the ImageMagick runs fast
COUNTS = (1, 2, 3, 4, 6)  # manifest `count` choices
COLOURS = ["#C0392B", "#27AE60", "#2980B9", "#8E44AD", "#D35400", "#16A085"]


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def bash_block(path, heading):
    """The first ```bash block after `heading` in a step file."""
    text = read(path)
    at = text.index(heading)  # ValueError (test error) when the heading is renamed
    m = re.compile(r"```bash\n(.*?)\n```", re.S).search(text, at)
    assert m, "no bash block after %r in %s" % (heading, path)
    return m.group(1)


def shells():
    """bash, plus macOS /bin/bash 3.2 and zsh when present (the bot may run either)."""
    found, seen = [], set()
    for cand in (shutil.which("bash"), "/bin/bash", shutil.which("zsh")):
        if cand and os.path.exists(cand):
            real = os.path.realpath(cand)
            if real not in seen:
                seen.add(real)
                found.append(cand)
    return found


def make_shims(root):
    """A PATH dir with BSD-style seq, a no-default-font montage and a logging convert."""
    shim = os.path.join(root, "shim")
    os.makedirs(shim)
    real_seq = shutil.which("seq") or "false"
    real_montage = shutil.which("montage") or "false"
    real_convert = shutil.which("convert")
    write(os.path.join(shim, "seq"),
          "#!/bin/sh\n"
          "# macOS seq: counts DOWN when FIRST > LAST ('seq 2 1' prints 2 then 1).\n"
          "if [ \"$#\" -ne 2 ]; then exec '%s' \"$@\"; fi\n"
          "i=$1\n"
          "if [ \"$1\" -le \"$2\" ]; then while [ \"$i\" -le \"$2\" ]; do echo \"$i\"; i=$((i+1)); done\n"
          "else while [ \"$i\" -ge \"$2\" ]; do echo \"$i\"; i=$((i-1)); done; fi\n" % real_seq)
    write(os.path.join(shim, "montage"),
          "#!/bin/sh\n"
          "# ImageMagick with no default font: montage needs a non-empty -font.\n"
          "prev=; ok=\n"
          "for a in \"$@\"; do if [ \"$prev\" = -font ] && [ -n \"$a\" ]; then ok=1; fi; prev=$a; done\n"
          "if [ -z \"$ok\" ]; then echo \"montage: unable to read font \\`' @ error/annotate.c/RenderFreetype/1660.\" >&2; exit 1; fi\n"
          "exec '%s' \"$@\"\n" % real_montage)
    write(os.path.join(shim, "convert"),
          "#!/bin/sh\n"
          "if [ -n \"$CONVERT_LOG\" ]; then printf '%%s\\n' \"$*\" >> \"$CONVERT_LOG\"; fi\n"
          "exec '%s' \"$@\"\n" % real_convert)
    for name in ("seq", "montage", "convert"):
        os.chmod(os.path.join(shim, name), 0o755)
    return shim


def run_block(shell, wd, prelude, block, shim, log=None):
    env = dict(os.environ, PATH=shim + os.pathsep + os.environ.get("PATH", ""))
    env.pop("CONVERT_LOG", None)
    if log:
        env["CONVERT_LOG"] = log
    script = "set -eu\n" + prelude + "\n" + block + "\n"
    return subprocess.run([shell, "-c", script], cwd=wd, env=env, capture_output=True, text=True)


def rgb(path):
    """Raw 8-bit RGB pixels, for an exact pixel comparison."""
    return subprocess.run(["convert", path, "-depth", "8", "rgb:-"], capture_output=True, check=True).stdout


def dims(path):
    out = subprocess.run(["convert", path, "-format", "%w %h", "info:"], capture_output=True,
                         text=True, check=True).stdout
    return tuple(int(v) for v in out.split())


def tile(path, x, y, out):
    subprocess.run(["convert", path, "-crop", "%dx%d+%d+%d" % (W, H, x, y), "+repage", out],
                   capture_output=True, check=True)
    return rgb(out)


def cols_for(n):
    return 1 if n <= 1 else (2 if n <= 4 else 3)  # the step's own COLS rule


def make_images(wd, n):
    """work/img-1..n.png: one solid colour per image at the test canvas."""
    os.makedirs(os.path.join(wd, "work"), exist_ok=True)
    for i in range(1, n + 1):
        subprocess.run(["convert", "-size", "%dx%d" % (W, H), "xc:" + COLOURS[i - 1],
                        os.path.join(wd, "work", "img-%d.png" % i)], capture_output=True, check=True)


class ImageStepCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        assert shutil.which("convert"), "ImageMagick `convert` is required (the recipe needs it too)"

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="aiimg-")
        self.shim = make_shims(self.root)

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def for_each(self, check):
        for shell in shells():
            for n in COUNTS:
                with self.subTest(shell=shell, n=n):
                    check(shell, n)


class GenerateContactSheet(ImageStepCase):
    """Step 02's "Write the saves" block makes the sheet under `set -e` with no default font."""

    def test_step_text_has_no_empty_font(self):
        self.assertNotRegex(read(STEP02), r"-font\s+(''|\"\")", "an empty -font is the fault itself")

    def test_shims_reproduce_the_faults(self):
        """Guard the guard: the shims really behave like the bot's Mac."""
        env = dict(os.environ, PATH=self.shim + os.pathsep + os.environ.get("PATH", ""))
        out = subprocess.run(["sh", "-c", "seq 2 1"], env=env, capture_output=True, text=True).stdout.split()
        self.assertEqual(out, ["2", "1"])
        p = subprocess.run(["sh", "-c", "montage -tile 1x x.png y.png"], env=env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)
        self.assertIn("unable to read font", p.stderr)

    def test_sheet_for_every_count(self):
        self.for_each(self.check_sheet)

    def check_sheet(self, shell, n):
        wd = tempfile.mkdtemp(dir=self.root)
        make_images(wd, n)
        os.makedirs(os.path.join(wd, "saves"))
        write(os.path.join(wd, "prior", "prompts.json"), json.dumps(
            {"count": n, "aspect_ratio": "1:1", "model": "test-model", "negative": "", "images": []}))
        write(os.path.join(wd, "work", "tasks.json"), json.dumps(
            {str(i): {"task_id": "task-%d" % i, "attempts": 1} for i in range(1, n + 1)}))
        p = run_block(shell, wd, "W=%d H=%d" % (W, H), bash_block(STEP02, "### 3. Write the saves"), self.shim)
        self.assertEqual(p.returncode, 0, "02 generate failed:\n" + p.stderr)
        saves = os.path.join(wd, "saves")
        meta = json.loads(read(os.path.join(saves, "images.json")))
        cols = meta["cols"]
        self.assertEqual((meta["count"], cols), (n, cols_for(n)))
        rows = -(-n // cols)
        sheet = os.path.join(saves, "contact_sheet.png")
        self.assertEqual(dims(sheet), (cols * W, rows * H))  # the harness image_dims check
        for k in range(rows * cols):
            got = tile(sheet, (k % cols) * W, (k // cols) * H, os.path.join(self.root, "t.png"))
            if k < n:
                want = rgb(os.path.join(wd, "work", "img-%d.png" % (k + 1)))
                self.assertEqual(got, want, "sheet tile %d is not image %d" % (k + 1, k + 1))
            else:
                self.assertEqual(set(got), {0}, "padding tile %d is not black" % (k + 1))
        self.assertEqual(rgb(os.path.join(saves, "image_1.png")), rgb(os.path.join(wd, "work", "img-1.png")))


class QaGateResplit(ImageStepCase):
    """Step 03's re-split loop does nothing for one image and crops 2..N for N >= 2."""

    def test_resplit_for_every_count(self):
        self.for_each(self.check_resplit)

    def check_resplit(self, shell, n):
        # prior/ as step 02 leaves it, built here without step 02 so this test stands alone.
        src = tempfile.mkdtemp(dir=self.root)
        make_images(src, n)
        cols = cols_for(n)
        prior = os.path.join(src, "prior")
        os.makedirs(prior)
        sheet = ["convert"]
        for r in range(-(-n // cols)):
            sheet.append("(")
            for c in range(1, cols + 1):
                i = r * cols + c
                sheet += ([os.path.join(src, "work", "img-%d.png" % i)] if i <= n
                          else ["-size", "%dx%d" % (W, H), "xc:black"])
            sheet += ["+append", ")"]
        subprocess.run(sheet + ["-append", os.path.join(prior, "contact_sheet.png")], capture_output=True, check=True)
        shutil.copy(os.path.join(src, "work", "img-1.png"), os.path.join(prior, "image_1.png"))
        with open(os.path.join(prior, "image_1.png"), "rb") as fh:
            sha1 = hashlib.sha256(fh.read()).hexdigest()
        write(os.path.join(prior, "images.json"), json.dumps(
            {"width": W, "height": H, "count": n, "cols": cols, "model": "test-model",
             "images": [{"n": 1, "sha256": sha1}]}))

        wd = tempfile.mkdtemp(dir=self.root)
        os.makedirs(os.path.join(wd, "work"))
        shutil.copytree(prior, os.path.join(wd, "prior"))
        log = os.path.join(self.root, "convert-%s.log" % os.path.basename(wd))
        prelude = "W=%d H=%d N=%d COLS=%d" % (W, H, n, cols)
        p = run_block(shell, wd, prelude, bash_block(STEP03, "### 1. Re-split the batch from the contact sheet"),
                      self.shim, log)
        self.assertEqual(p.returncode, 0, "03 re-split failed:\n" + p.stderr)
        calls = read(log).splitlines() if os.path.exists(log) else []
        self.assertEqual(len(calls), n - 1, "crops for images 2..N only: %r" % calls)
        for i, call in enumerate(calls, start=2):
            self.assertTrue(call.endswith("work/img-%d.png" % i), call)
        made = sorted((f for f in os.listdir(os.path.join(wd, "work")) if f.startswith("img-")),
                      key=lambda f: int(re.search(r"(\d+)", f).group(1)))
        self.assertEqual(made, ["img-%d.png" % i for i in range(1, n + 1)])
        for i in range(1, n + 1):
            self.assertEqual(rgb(os.path.join(wd, "work", "img-%d.png" % i)),
                             rgb(os.path.join(src, "work", "img-%d.png" % i)), "image %d changed in transit" % i)


if __name__ == "__main__":
    unittest.main(verbosity=2)
