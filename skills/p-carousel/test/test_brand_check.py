#!/usr/bin/env python3
"""Offline tests for p-carousel step 02's brand self-check (WI31.14).

  python3 -I harness/skills/p-carousel/test/test_brand_check.py -v

No network and no paid APIs. Needs python3 and bash. Each test runs the step's OWN
"Write the saves and self-check" block, read from steps/02-author-slides.md, in a throwaway
step workdir, so an edit that brings the fault back fails here.

The check refuses #3b82f6 as the stock template blue. A brand whose own palette uses
#3B82F6 (Test Brand's accent) must pass; a brand with another accent must still be refused
when the stock blue is left in the HTML. A text check keeps SKILL.md, the step files and
acceptance.json saying the same thing.
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
STEP02 = os.path.join(SKILL_DIR, "steps", "02-author-slides.md")
STOCK_BLUE = "#3B82F6"
SLIDES = 3


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


def carousel_html(accent, extra=""):
    sections = "".join('<section class="slide" id="s%d"><h1>Slide %d</h1></section>' % (n, n)
                       for n in range(1, SLIDES + 1))
    return ('<!doctype html><html><head><meta charset="UTF-8"><style>'
            ':root{--accent:%s;--ink:#1A1A1A;--bg:#0F172A;--card:#FFFFFF;--line:#E5E7EB;--muted:#64748B}%s'
            '</style></head><body>%s</body></html>' % (accent, extra, sections))


class AuthorSlidesBrandCheck(unittest.TestCase):
    """AC1 for p-carousel: brand_vars_set as the step's self-check enforces it."""

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="car02-")
        self.block = bash_block(STEP02, "### 4. Write the saves and self-check")

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def run_check(self, palette, html):
        wd = tempfile.mkdtemp(dir=self.root)
        brand = {"slug": "test-brand", "name": "Test Brand"}
        if palette is not None:
            brand["palette"] = palette
        write(os.path.join(wd, "brief.json"), json.dumps({"recipe": "p-carousel", "intent": "t", "brand": brand}))
        write(os.path.join(wd, "prior", "outline.json"), json.dumps(
            {"num_slides": SLIDES, "slides": [{"n": n, "role": "content", "headline": "H%d" % n}
                                              for n in range(1, SLIDES + 1)]}))
        write(os.path.join(wd, "work", "slide_copy.json"), json.dumps(
            {"aspect_ratio": "4:5", "slides": [{"n": n, "role": "content", "headline": "H%d" % n,
                                                "body": "B.", "visual": "step list"}
                                               for n in range(1, SLIDES + 1)]}))
        write(os.path.join(wd, "work", "carousel.html"), html)
        os.makedirs(os.path.join(wd, "saves"))
        p = subprocess.run(["bash", "-c", "set -eu\n" + self.block], cwd=wd, capture_output=True, text=True)
        return p, wd

    def test_blue_brand_accent_passes(self):
        p, wd = self.run_check({"bg": "#0F172A", "accent": STOCK_BLUE}, carousel_html(STOCK_BLUE))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(os.path.exists(os.path.join(wd, "saves", "slide_copy.json")))
        self.assertIn(STOCK_BLUE, read(os.path.join(wd, "saves", "carousel_html.md")))

    def test_blue_brand_lowercase_palette_passes(self):
        p, _ = self.run_check({"accent": "#3b82f6"}, carousel_html(STOCK_BLUE))
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_stock_blue_refused_for_other_accent(self):
        html = carousel_html("#E11D48", ".pill{color:#3b82f6}")
        p, wd = self.run_check({"bg": "#0F172A", "accent": "#E11D48"}, html)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("stock blue left in template", p.stderr)
        self.assertFalse(os.path.exists(os.path.join(wd, "saves", "slide_copy.json")))

    def test_stock_blue_refused_without_palette(self):
        p, _ = self.run_check(None, carousel_html(STOCK_BLUE))
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("stock blue left in template", p.stderr)

    def test_other_accent_clean_html_passes(self):
        p, _ = self.run_check({"accent": "#E11D48"}, carousel_html("#E11D48"))
        self.assertEqual(p.returncode, 0, p.stderr)


# ------------------------------------------------------------ recipe text

EXCEPTION = "brief.json.brand.palette"


def prose_units(text):
    """The bullets and paragraphs of a Markdown file, with code fences dropped."""
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    units, cur = [], []
    for line in text.splitlines():
        s = re.sub(r"^[>\s]*", "", line)
        if not s or re.match(r"([-*]|\d+\.)\s|#", s):
            if cur:
                units.append(" ".join(cur))
                cur = []
        if s:
            cur.append(s)
    if cur:
        units.append(" ".join(cur))
    return units


def recipe_text_units():
    """(file, text) for each Markdown bullet/paragraph and acceptance desc in this recipe."""
    for dirpath, dirs, files in os.walk(SKILL_DIR):
        dirs[:] = sorted(d for d in dirs if d not in ("test", ".hub"))
        for name in sorted(files):
            path = os.path.join(dirpath, name)
            if name.endswith(".md"):
                for unit in prose_units(read(path)):
                    yield path, unit
            elif name.startswith("acceptance") and name.endswith(".json"):
                for check in json.loads(read(path)).get("checks", []):
                    if "desc" in check:
                        yield path, check["desc"]


class BlueBrandText(unittest.TestCase):
    """The recipe's words say what the check does: #3b82f6 is off-brand only outside the brand palette."""

    def test_no_stock_blue_rule_without_the_brand_palette_exception(self):
        bad = ["%s: %s" % (os.path.relpath(p, SKILL_DIR), u[:140]) for p, u in recipe_text_units()
               if "3b82f6" in u.lower() and EXCEPTION not in u]
        self.assertEqual(bad, [], "these call #3b82f6 off-brand with no %s exception" % EXCEPTION)

    def test_palette_rubric_judges_against_the_brand_palette(self):
        acc = json.loads(read(os.path.join(SKILL_DIR, "acceptance.json")))
        desc = next(c["desc"] for c in acc["checks"] if c["id"] == "on_brand_palette")
        self.assertIn(EXCEPTION, desc)


if __name__ == "__main__":
    unittest.main(verbosity=2)
