#!/usr/bin/env python3
"""Offline tests for p-reels-pip step 05 helpers (WI31.10).

  python3 harness/skills/p-reels-pip/test/test_composite_helpers.py -v

No network and no paid APIs. Needs python3 and ffmpeg (the recipe needs both).

- scripts/cta_takeover.py: the reel ends on ONE CTA and step 05 never invents copy.
- scripts/pip_card.py: the rounded mask and ring + shadow frame are built with the
  standard library only, so a missing Pillow cannot ship a square, ringless card.
  Checked by reading pixel values back, and by running step 05's real composite
  filter graph on a tiny generated fixture.
"""
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(HERE)
CTA_SCRIPT = os.path.join(SKILL_DIR, "scripts", "cta_takeover.py")
CARD_SCRIPT = os.path.join(SKILL_DIR, "scripts", "pip_card.py")
STEP05 = os.path.join(SKILL_DIR, "steps", "05-composite.md")
SKILL_MD = os.path.join(SKILL_DIR, "SKILL.md")

ACCENT = (0xF9, 0x73, 0x16)  # the default brand accent, F97316
CW, CH, RADIUS, RING, SHADOW = 364, 504, 40, 8, 22
PAD = RING + SHADOW
FW, FH = CW + 2 * PAD, CH + 2 * PAD


# ---------------------------------------------------------------- fixtures

def beat(i, start, end, scene_type, kind="graphics"):
    b = {"index": i, "start": start, "end": end, "kind": kind, "slug": "beat%d-%s" % (i, scene_type)}
    if kind == "graphics":
        b["scene"] = {"id": scene_type, "type": scene_type, "scene_id": scene_type,
                      "title_html": "LINE %d" % i, "source": "scene_plan"}
    else:
        b["broll"] = {"clip": "inputs/broll/a.mp4", "in": 0, "out": end - start}
    return b


ENDS_ON_CTA = [beat(0, 0, 10, "hook"), beat(1, 10, 24, "standard"), beat(2, 24, 30, "cta")]
ENDS_ON_CONTENT = [beat(0, 0, 10, "hook"), beat(1, 10, 24, "cta"), beat(2, 24, 30, "standard")]


def make_workdir(root, beats, cta=None, brand=None, options=None):
    """A step workdir shaped like the harness's: brief.json, prior/, inputs/, work/."""
    wd = tempfile.mkdtemp(dir=root)
    os.makedirs(os.path.join(wd, "prior"))
    os.makedirs(os.path.join(wd, "work"))
    brief = {"recipe": "p-reels-pip", "intent": "test", "targets": ["instagram"],
             "brand": brand if brand is not None else {"slug": "test-brand", "name": "Test Brand"},
             "options": options or {}}
    with open(os.path.join(wd, "brief.json"), "w") as fh:
        json.dump(brief, fh)
    with open(os.path.join(wd, "prior", "beat_list.json"), "w") as fh:
        json.dump({"bed_duration": 30.0, "cover_at": 12.0, "beats": beats}, fh)
    if cta is not None:
        os.makedirs(os.path.join(wd, "inputs", "cta"))
        with open(os.path.join(wd, "inputs", "cta", "cta.json"), "w") as fh:
            json.dump(cta, fh)
    return wd


def run_cta(wd, cta_card="on"):
    """Run the decision exactly as step 05 does (capture, eval) and return the shell vars."""
    script = ('VARS=$("$PY" "$CTA_SCRIPT" --brief brief.json --beats prior/beat_list.json '
              '--cta inputs/cta/cta.json --cta-card "$CARD" --decision work/cta-decision.json) || exit 9\n'
              'eval "$VARS"\n'
              'printf "%s\\n%s\\n%s\\n%s\\n" "$CTA_TAKEOVER" "$CTA_TEXT" "$CTA_HANDLE" "$CTA_REASON"\n')
    env = dict(os.environ, PY=sys.executable, CTA_SCRIPT=CTA_SCRIPT, CARD=cta_card)
    p = subprocess.run(["bash", "-c", script], cwd=wd, env=env, capture_output=True, text=True)
    if p.returncode != 0:
        raise AssertionError("cta_takeover.py failed (%d): %s" % (p.returncode, p.stderr))
    lines = p.stdout.split("\n")
    with open(os.path.join(wd, "work", "cta-decision.json")) as fh:
        decision = json.load(fh)
    return {"takeover": lines[0], "text": lines[1], "handle": lines[2], "reason": lines[3],
            "stderr": p.stderr, "decision": decision}


# ---------------------------------------------------------------- PNG reader (independent of pip_card.py)

def read_png_rgba(path):
    with open(path, "rb") as fh:
        data = fh.read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, ihdr = 8, b"", None
    while pos < len(data):
        n = struct.unpack(">I", data[pos:pos + 4])[0]
        tag, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + n]
        if tag == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif tag == b"IDAT":
            idat += body
        pos += 12 + n
    w, h, depth, ctype = ihdr[0], ihdr[1], ihdr[2], ihdr[3]
    assert (depth, ctype) == (8, 6), "expected 8-bit RGBA, got depth %d type %d" % (depth, ctype)
    raw, bpp, stride = zlib.decompress(idat), 4, w * 4
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        f, line = raw[i], bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        rows.append(line)
        prev = line
    return w, h, lambda x, y: tuple(rows[y][x * 4:x * 4 + 4])


# ---------------------------------------------------------------- Pillow-blocked python

def blocked_env(root):
    """An env where `import PIL` fails even if Pillow is installed: run python with -S
    (no site-packages) and a PIL package on PYTHONPATH that raises ImportError."""
    block = os.path.join(root, "pil-blocker")
    os.makedirs(os.path.join(block, "PIL"), exist_ok=True)
    with open(os.path.join(block, "PIL", "__init__.py"), "w") as fh:
        fh.write("raise ImportError('Pillow is blocked by the WI31.10 test')\n")
    return dict(os.environ, PYTHONPATH=block)


def run_card(root, args, env):
    return subprocess.run([sys.executable, "-S", CARD_SCRIPT] + args, cwd=root, env=env,
                          capture_output=True, text=True)


def card_args(out, accent="F97316", ring=RING, shadow=SHADOW, frame=True):
    a = ["--card", "%dx%d" % (CW, CH), "--radius", str(RADIUS), "--ring", str(ring),
         "--shadow", str(shadow), "--accent", accent, "--mask", os.path.join(out, "pip-mask.png")]
    a += ["--frame", os.path.join(out, "pip-frame.png") if frame else ""]
    return a


def close(px, rgb, tol):
    return all(abs(int(p) - int(q)) <= tol for p, q in zip(px[:3], rgb))


# ================================================================ tests

class CtaTakeoverTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="wi31-10-cta-")

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def test_a_no_cta_json_and_plan_ends_on_cta_beat_skips_takeover(self):
        r = run_cta(make_workdir(self.root, ENDS_ON_CTA))
        self.assertEqual(r["takeover"], "off")
        self.assertEqual(r["text"], "")
        self.assertIn("already ends on its CTA beat", r["reason"])
        self.assertIn("no second CTA and no scrim", r["reason"])
        self.assertEqual(r["decision"]["cta_beat"], {"index": 2, "slug": "beat2-cta", "start": 24, "end": 30})
        self.assertIn("[pip] end card skipped", r["stderr"])

    def test_a2_cta_beat_wins_even_with_cta_json(self):
        r = run_cta(make_workdir(self.root, ENDS_ON_CTA, cta={"text": "Comment DUET", "handle": "testbrand"}))
        self.assertEqual(r["takeover"], "off")
        self.assertIn("inputs/cta/cta.json copy was not drawn", r["reason"])

    def test_a3_cta_beat_found_by_largest_end_not_list_order(self):
        beats = [ENDS_ON_CTA[2], ENDS_ON_CTA[0], ENDS_ON_CTA[1]]
        self.assertEqual(run_cta(make_workdir(self.root, beats))["takeover"], "off")

    def test_b_no_copy_and_no_cta_beat_skips_and_says_so(self):
        r = run_cta(make_workdir(self.root, ENDS_ON_CONTENT))
        self.assertEqual(r["takeover"], "off")
        self.assertEqual(r["text"], "")
        self.assertIn("no CTA copy", r["reason"])
        self.assertIn("never invents copy", r["reason"])
        self.assertNotIn("Follow", r["text"] + r["reason"])
        self.assertIn("[pip] end card skipped: no CTA copy", r["stderr"])

    def test_b2_cta_json_without_text_is_no_copy(self):
        r = run_cta(make_workdir(self.root, ENDS_ON_CONTENT, cta={"brandName": "Test Brand", "handle": "testbrand"}))
        self.assertEqual(r["takeover"], "off")
        self.assertIn("no CTA copy", r["reason"])

    def test_c_cta_json_and_no_cta_beat_uses_cta_json(self):
        text = "Comment 'DUET' & I'll DM you"
        r = run_cta(make_workdir(self.root, ENDS_ON_CONTENT, cta={"text": text, "handle": "testbrand"},
                                 brand={"name": "Test Brand", "cta": "brand line", "handle": "otherhandle"}))
        self.assertEqual(r["takeover"], "on")
        self.assertEqual(r["text"], text)
        self.assertEqual(r["handle"], "testbrand")
        self.assertIn("inputs/cta/cta.json", r["reason"])

    def test_c2_brand_cta_used_when_no_cta_json(self):
        r = run_cta(make_workdir(self.root, ENDS_ON_CONTENT, brand={"name": "Test Brand", "cta": "Comment GUIDE"}))
        self.assertEqual((r["takeover"], r["text"], r["handle"]), ("on", "Comment GUIDE", ""))

    def test_broll_last_beat_is_not_a_cta_beat(self):
        beats = [beat(0, 0, 20, "hook"), beat(1, 20, 30, "clip", kind="broll")]
        r = run_cta(make_workdir(self.root, beats, cta={"text": "Comment DUET"}))
        self.assertEqual(r["takeover"], "on")

    def test_cta_card_off(self):
        r = run_cta(make_workdir(self.root, ENDS_ON_CONTENT, cta={"text": "Comment DUET"}), cta_card="off")
        self.assertEqual(r["takeover"], "off")
        self.assertIn("cta_card=off", r["reason"])

    def test_missing_beat_list_fails_loudly(self):
        wd = make_workdir(self.root, ENDS_ON_CONTENT, cta={"text": "Comment DUET"})
        os.remove(os.path.join(wd, "prior", "beat_list.json"))
        p = subprocess.run([sys.executable, CTA_SCRIPT, "--beats", "prior/beat_list.json"], cwd=wd,
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)
        self.assertIn("beat list prior/beat_list.json is missing", p.stderr)
        self.assertEqual(p.stdout, "")


class PipCardWithoutPillowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.mkdtemp(prefix="wi31-10-card-")
        cls.env = blocked_env(cls.root)
        cls.out = os.path.join(cls.root, "out")
        os.makedirs(cls.out)
        cls.proc = run_card(cls.root, card_args(cls.out), cls.env)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.root, ignore_errors=True)

    def test_d0_pillow_really_is_unavailable_in_this_env(self):
        p = subprocess.run([sys.executable, "-S", "-c", "import PIL"], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("ImportError", p.stderr)

    def test_d1_files_are_produced(self):
        self.assertEqual(self.proc.returncode, 0, self.proc.stderr)
        for name in ("pip-mask.png", "pip-frame.png"):
            self.assertGreater(os.path.getsize(os.path.join(self.out, name)), 0)

    def test_d2_mask_has_rounded_corners(self):
        w, h, px = read_png_rgba(os.path.join(self.out, "pip-mask.png"))
        self.assertEqual((w, h), (CW, CH))
        for x, y in ((0, 0), (CW - 1, 0), (0, CH - 1), (CW - 1, CH - 1), (5, 5)):
            self.assertEqual(px(x, y)[3], 0, "corner pixel (%d,%d) must be transparent" % (x, y))
        for x, y in ((CW // 2, CH // 2), (0, CH // 2), (CW // 2, 0), (RADIUS, RADIUS)):
            self.assertEqual(px(x, y), (255, 255, 255, 255), "inside pixel (%d,%d) must be opaque white" % (x, y))

    def test_d3_frame_has_accent_ring_rounded_corners_and_shadow(self):
        w, h, px = read_png_rgba(os.path.join(self.out, "pip-frame.png"))
        self.assertEqual((w, h), (FW, FH))
        mid = PAD - RING // 2  # middle of the ring band
        for x, y in ((mid, FH // 2), (FW - 1 - mid, FH // 2), (FW // 2, mid), (FW // 2, FH - 1 - mid)):
            self.assertEqual(px(x, y), ACCENT + (255,), "ring pixel (%d,%d) must be the accent" % (x, y))
        self.assertEqual(px(0, 0)[3], 0, "outer corner must be transparent")
        corner = px(PAD - RING, PAD - RING)  # the ring rectangle's own corner pixel: rounded off
        self.assertLess(corner[3], 255)
        self.assertFalse(corner[3] == 255 and corner[:3] == ACCENT, "ring corner is square")
        shadow = px(FW // 2, FH - (PAD - RING) + 4)  # just below the ring, bottom middle
        self.assertGreater(shadow[3], 0, "no drop shadow under the ring")
        self.assertEqual(shadow[:3], (0, 0, 0))

    def test_d4_ring_colour_follows_the_brand_accent(self):
        out = os.path.join(self.root, "cyan")
        os.makedirs(out)
        p = run_card(self.root, card_args(out, accent="#06B6D4"), self.env)
        self.assertEqual(p.returncode, 0, p.stderr)
        _, _, px = read_png_rgba(os.path.join(out, "pip-frame.png"))
        self.assertEqual(px(PAD - RING // 2, FH // 2), (0x06, 0xB6, 0xD4, 255))

    def test_d5_ring_zero_writes_mask_only(self):
        out = os.path.join(self.root, "noring")
        os.makedirs(out)
        p = run_card(self.root, card_args(out, ring=0, frame=False), self.env)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(os.path.exists(os.path.join(out, "pip-mask.png")))
        self.assertFalse(os.path.exists(os.path.join(out, "pip-frame.png")))

    def test_d6_failure_exits_nonzero_and_names_what_failed(self):
        bad = run_card(self.root, card_args(self.out, accent="orange"), self.env)
        self.assertEqual(bad.returncode, 1)
        self.assertIn("brand accent 'orange' is not a 6-digit hex colour", bad.stderr)
        missing = os.path.join(self.root, "no-such-dir")
        nowrite = run_card(self.root, card_args(missing), self.env)
        self.assertEqual(nowrite.returncode, 1)
        self.assertIn("FAILED - rounded mask %s" % os.path.join(missing, "pip-mask.png"), nowrite.stderr)
        self.assertFalse(os.path.exists(missing))


class CompositeFilterGraphTest(unittest.TestCase):
    """Step 05's real ring-path filter graph, fed the Pillow-free PNGs: the card is rounded
    and ringed in the composed frame (a square card would show the head at its corner)."""

    def setUp(self):
        self.assertIsNotNone(shutil.which("ffmpeg"), "ffmpeg is required by this recipe")
        self.root = tempfile.mkdtemp(prefix="wi31-10-ff-")

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def step05_fc(self, ring_path=True):
        text = read_text(STEP05)
        fcs = re.findall(r'^\s*FC="([^"]+)"$', text, re.M)
        fc = next(f for f in fcs if ("[3:v]" in f) == ring_path)
        for k, v in (("CARD_W", CW), ("CARD_H", CH), ("PFROM", 110 - PAD), ("MARGIN", 110)):
            fc = fc.replace("${%s}" % k, str(v))
        self.assertNotIn("${", fc)
        return fc

    def test_composed_card_is_rounded_and_ringed(self):
        r = self.root
        p = run_card(r, card_args(r), blocked_env(r))
        self.assertEqual(p.returncode, 0, p.stderr)
        ff = ["ffmpeg", "-v", "error", "-y"]
        subprocess.run(ff + ["-f", "lavfi", "-i", "color=c=0x2040A0:s=1080x1920:r=30:d=0.5",
                             "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "bg.mp4"],
                       cwd=r, check=True)
        subprocess.run(ff + ["-f", "lavfi", "-i", "color=c=red:s=360x640:r=30:d=0.5",
                             "-f", "lavfi", "-i", "sine=frequency=220:duration=0.5",
                             "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                             "-c:a", "aac", "-shortest", "head.mp4"], cwd=r, check=True)
        subprocess.run(ff + ["-i", "bg.mp4", "-i", "head.mp4", "-i", "pip-mask.png", "-i", "pip-frame.png",
                             "-filter_complex", self.step05_fc(), "-map", "[v]", "-map", "[a]",
                             "-c:v", "libx264", "-preset", "ultrafast", "-crf", "12", "-pix_fmt", "yuv420p",
                             "-c:a", "aac", "composed.mp4"], cwd=r, check=True)
        raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", "0.2", "-i", "composed.mp4", "-frames:v", "1",
                              "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], cwd=r, check=True,
                             capture_output=True).stdout
        self.assertEqual(len(raw), 1080 * 1920 * 3)
        px = lambda x, y: tuple(raw[(y * 1080 + x) * 3:(y * 1080 + x) * 3 + 3])
        x0, y0 = (1080 - CW) // 2, 1920 - CH - 110  # card top-left: 358, 1306
        self.assertTrue(close(px(540, y0 + CH // 2), (255, 0, 0), 40), "head missing: %r" % (px(540, y0 + CH // 2),))
        self.assertTrue(close(px(x0 - RING // 2, y0 + CH // 2), ACCENT, 30), "left ring: %r" % (px(x0 - RING // 2, y0 + CH // 2),))
        self.assertTrue(close(px(540, y0 - RING // 2), ACCENT, 30), "top ring: %r" % (px(540, y0 - RING // 2),))
        corner = px(x0 + 1, y0 + 1)  # inside a square card; outside the rounded one
        self.assertGreater(corner[2], 100, "card corner is not background: %r (square card?)" % (corner,))
        self.assertLess(corner[0], 60, "card corner shows the head: %r (square card?)" % (corner,))


def read_text(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


class StaticTextTest(unittest.TestCase):
    def absent(self, pattern, text, what):
        m = re.search(pattern, text, re.M)
        self.assertIsNone(m, "%s: found %r" % (what, m.group(0) if m else ""))

    def test_step05_has_no_pillow_no_hidden_errors_no_invented_copy(self):
        text = read_text(STEP05)
        sec1 = text.split("### 1.", 1)[1].split("### 2.", 1)[0]
        self.absent(r"PIL\b", sec1, "step 05 section 1 uses Pillow")
        self.absent(r"2>/dev/null", sec1, "step 05 section 1 hides errors")
        self.assertIn("scripts/pip_card.py", sec1)
        self.absent(r"f\"Follow \{", text, "step 05 invents 'Follow <brand> for more' copy")
        self.assertIn("scripts/cta_takeover.py", text)
        self.absent(r"FC=\"\[1:v\]scale=[^\"]*setsar=1\[thfit\]", text, "step 05 keeps a square, unmasked card branch")

    def test_skill_md_agrees(self):
        text = read_text(SKILL_MD)
        self.absent(r"CTA_TEXT=\"\$\{CTA_TEXT:-[^}]", text, "SKILL.md has a default CTA_TEXT")
        self.absent(r"^\s*from PIL import", text, "SKILL.md imports Pillow")
        self.absent(r"FC=\"\[1:v\]scale=[^\"]*setsar=1\[thfit\]", text, "SKILL.md keeps a square, unmasked card branch")
        self.assertIn("scripts/pip_card.py", text)
        self.assertIn("scripts/cta_takeover.py", text)

    def test_scripts_do_not_import_pillow(self):
        for path in (CARD_SCRIPT, CTA_SCRIPT):
            self.absent(r"^\s*(from|import) PIL", read_text(path), path)


if __name__ == "__main__":
    unittest.main()
