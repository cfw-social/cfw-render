#!/usr/bin/env python3
"""Offline tests for p-ai-character step 03's scene sheet (WI31.14).

  python3 -I harness/skills/p-ai-character/test/test_scene_sheet.py -v

No network, no kie.ai calls and no paid APIs. Needs python3, bash and ImageMagick
(`convert`), which the recipe needs too. The test runs the step's OWN "Write the saves"
block, read from steps/03-scene-images.md, in a throwaway step workdir, so an edit that
brings the fault back fails here.

The fault: `montage` always loads a font and exits 1 ("unable to read font") where
ImageMagick has no default font, so under `set -e` scenes.json was never written. A
`montage` shim emulates that Mac on any OS. The sheet must be one row of scenes 1..N, each
1080x1920, for every allowed scene count (3-6).
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
STEP03 = os.path.join(SKILL_DIR, "steps", "03-scene-images.md")

W, H = 1080, 1920  # the step writes this canvas into scenes.json; the harness checks it
COUNTS = (3, 4, 5, 6)  # manifest `num_scenes` choices
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


def make_shim(root):
    """A PATH dir with a `montage` that, like ImageMagick with no default font, needs -font."""
    shim = os.path.join(root, "shim")
    os.makedirs(shim)
    write(os.path.join(shim, "montage"),
          "#!/bin/sh\n"
          "prev=; ok=\n"
          "for a in \"$@\"; do if [ \"$prev\" = -font ] && [ -n \"$a\" ]; then ok=1; fi; prev=$a; done\n"
          "if [ -z \"$ok\" ]; then echo \"montage: unable to read font \\`' @ error/annotate.c/RenderFreetype/1660.\" >&2; exit 1; fi\n"
          "exec '%s' \"$@\"\n" % (shutil.which("montage") or "false"))
    os.chmod(os.path.join(shim, "montage"), 0o755)
    return shim


def signature(path, crop=None):
    """ImageMagick's pixel signature (pixels only, not the file bytes)."""
    cmd = ["convert", path] + (["-crop", crop, "+repage"] if crop else []) + ["-format", "%#", "info:"]
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.strip()


def dims(path):
    out = subprocess.run(["convert", path, "-format", "%w %h", "info:"], capture_output=True,
                         text=True, check=True).stdout
    return tuple(int(v) for v in out.split())


class SceneSheet(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        assert shutil.which("convert"), "ImageMagick `convert` is required (the recipe needs it too)"
        cls.block = bash_block(STEP03, "### 3. Write the saves")

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="aichar-")
        self.shim = make_shim(self.root)

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def test_step_text_has_no_empty_font(self):
        self.assertNotRegex(read(STEP03), r"-font\s+(''|\"\")", "an empty -font is the fault itself")

    def test_shim_reproduces_the_fault(self):
        env = dict(os.environ, PATH=self.shim + os.pathsep + os.environ.get("PATH", ""))
        p = subprocess.run(["sh", "-c", "montage -tile 1x x.png y.png"], env=env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)
        self.assertIn("unable to read font", p.stderr)

    def test_sheet_for_every_scene_count(self):
        for shell in shells():
            for n in COUNTS:
                with self.subTest(shell=shell, n=n):
                    self.check_sheet(shell, n)

    def check_sheet(self, shell, n):
        wd = tempfile.mkdtemp(dir=self.root)
        os.makedirs(os.path.join(wd, "saves"))
        os.makedirs(os.path.join(wd, "work"))
        for i in range(1, n + 1):
            subprocess.run(["convert", "-size", "%dx%d" % (W, H), "xc:" + COLOURS[i - 1],
                            os.path.join(wd, "work", "scene-%d.png" % i)], capture_output=True, check=True)
        write(os.path.join(wd, "prior", "story_arc.json"), json.dumps({"num_scenes": n}))
        write(os.path.join(wd, "work", "tasks.json"), json.dumps(
            {str(i): {"task_id": "task-%d" % i, "attempts": 1, "divergence": "PASS"} for i in range(1, n + 1)}))
        env = dict(os.environ, PATH=self.shim + os.pathsep + os.environ.get("PATH", ""))
        p = subprocess.run([shell, "-c", "set -eu\nN=%d\n%s\n" % (n, self.block)], cwd=wd, env=env,
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, "03 scene_images failed:\n" + p.stderr)
        saves = os.path.join(wd, "saves")
        self.assertEqual(json.loads(read(os.path.join(saves, "scenes.json")))["count"], n)
        sheet = os.path.join(saves, "scene_sheet.png")
        self.assertEqual(dims(sheet), (n * W, H))  # the harness scene_dims check
        for i in range(1, n + 1):
            want = signature(os.path.join(wd, "work", "scene-%d.png" % i))
            got = signature(sheet, "%dx%d+%d+0" % (W, H, (i - 1) * W))
            self.assertEqual(got, want, "sheet tile %d is not scene %d" % (i, i))
        self.assertEqual(signature(os.path.join(saves, "scene_1.png")),
                         signature(os.path.join(wd, "work", "scene-1.png")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
