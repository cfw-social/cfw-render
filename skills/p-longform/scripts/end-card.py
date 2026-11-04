#!/usr/bin/env python3
"""end-card.py - the Longform end card: what it says, and proof the video ends on it.

Stdlib only. ffmpeg and ffprobe do the picture work (both are recipe needs).

Modes (all take --dir, the step workdir that holds brief.json, inputs/, prior/, saves/):

  resolve          Print the end_card object for this order, as JSON. The words never
                   come from the script. First source that exists wins:
                     1. inputs/outro/ clip   the brand's own closing clip. It still plays AFTER
                                             the card (the composite appends it), so it does not
                                             supply words: `outro` is true and the words come
                                             from 2-4.
                     2. typed CTA            inputs/cta/cta.json, cta.md or cta.txt
                                             (source = cta_input)
                     3. brand file           brand-overrides/<brand.slug>/brand.json: cta.line,
                                             cta.handle, palette, fonts (source = brand_overrides)
                     4. brand name           brief.json brand.name + "Follow for more", no handle
                                             (source = brand_name)
                   kicker is the brand name. A handle is printed only when one was typed or the
                   brand file holds one; a typed line that already holds a handle or URL gets no
                   second handle. A literal handle lives only in brand-overrides/**.

  verify-manifest  build_visuals check. The visuals manifest has exactly one end card (id cta,
                   5-12 s), its end_card object equals `resolve`, the card's own markup shows those
                   words and nothing else, a 1920x1080 reference still of the card is attached
                   (ref_png_b64) and is not blank, and no card carries a production label.

  verify-plan      plan_broll check. Rows run from 0 to the duration with no gap or overlap and the
                   LAST row is the end card (gfx:cta, FULLSCREEN_BROLL, zoom none), as long as the
                   card (a zoom would crop and move it).

  verify-final     final_checks check. The frame 1 s before the end of the card matches the
                   reference still (score >= --threshold, default 0.80), the frame 14 s before the
                   end does not, and the last frame is not black. When an outro clip follows the
                   card, the offsets count back from where the outro starts, and the black test
                   moves to the frame just before the outro (the outro may fade out).

Exit 0 = pass, 1 = the check failed (reasons printed, last line summarises), 2 = it could not run.

The match score is a structure-weighted SSIM: 8x8 windows on 480x270 grey frames, averaged only over
the windows where either picture has detail (local variance above 20). A plain whole-frame mean
is dominated by flat dark background, which two different cards share, so it cannot tell cards
apart; the weighted score can. It is also drift tolerant (drift_match): the best score over integer
shifts of up to 8 pixels each way on the 480x270 grid (32 on the 1920x1080 frame) and over the plain
and 3x3-blurred pictures, so a card that sits a few pixels off, or is zoomed by about 1 %, still
matches; a different card, a black frame or a card that fills the 14 s before still does not.
"""
import argparse
import base64
import binascii
import fnmatch
import html.parser
import itertools
import json
import os
import re
import struct
import subprocess
import sys
import unicodedata

GENERIC_LINE = "Follow for more"
DEFAULT_PALETTE = {"bg": "#0F172A", "accent": "#F97316", "fg": "#F1F5F9"}
DEFAULT_FONT = "Poppins"
CARD_MIN_S, CARD_MAX_S = 5.0, 12.0
THRESHOLD = 0.80
CANVAS = (1920, 1080)
SMALL_W, SMALL_H = 480, 270
WIN, STEP = 8, 4
VAR_FLOOR = 20.0
BLUR_PASSES = (1, 3)        # 3x3 box-blur passes tried besides the plain picture
MATCH_RADIUS = 8           # shift search, in 480x270 pixels each way (= 32 px on the 1920x1080 frame)
MIN_DETAIL = 0.01          # share of windows with detail a real card must have
EXTRA_CHARS = 6            # letters/digits allowed on the card beyond kicker, hero and handle
PNG_SIG = b"\x89PNG\r\n\x1a\n"

# Layout names are production labels. The underscore forms (AVATAR_FULL) never occur in real copy and
# are flagged anywhere; the spaced forms (avatar full) only when the run is that name, or in capitals.
LAYOUT_CONST_RE = re.compile(r"(?<![a-z0-9])(avatar_full|pip_corner|pip_side|fullscreen_broll|side_by_side)(?![a-z0-9])", re.I)
LAYOUT_SPACED_RE = re.compile(r"(?<![a-z0-9])(avatar[ -]full|pip[ -]corner|pip[ -]side|fullscreen[ -]b-?roll)(?![a-z0-9])", re.I)
# what is left of the end card's text, letters and digits only, must hold none of these
BANNED_SQUASHED = ("broll", "graphic", "template", "screenshot", "avatarfull", "pipcorner", "pipside",
                   "fullscreenbroll", "sidebyside")
WORD_RE = re.compile(r"(?<![a-z0-9])(b[- ]?rolls?|graphics?|templates?|screen[- ]?shots?)(?![a-z0-9])", re.I)
TAG_JOINER_RE = re.compile(r"[+|#_\u00b7\u2022]")             # + | # _ and the middle dot / bullet
TAG_MARKER_RE = re.compile(r"(?<![a-z0-9])(b[-_ ]?rolls?|graphics?|templates?|screen[-_ ]?shots?)[-_ #]*\d+(?![a-z0-9])", re.I)
# Two or more of these in one short run is a production tag, whatever the joiner or the case
# (REAL SITE B-ROLL / GRAPHICS, Real Site B-roll & Graphics, B-ROLL GRAPHICS). One alone is content.
PRODUCTION_WORDS = {"broll", "graphics", "template", "screenshot", "placeholder", "stock", "layoutname"}
TAG_MAX_TOKENS = 8
_TOKEN_FORMS = (
    (re.compile(r"(?<![a-z0-9])(fullscreen[-_ ]?b[-_ ]?rolls?|avatar[-_ ]full|pip[-_ ]corner|pip[-_ ]side|side[-_ ]by[-_ ]side)(?![a-z0-9])", re.I), " layoutname "),
    (re.compile(r"(?<![a-z0-9])b[-_ ]?rolls?(?![a-z0-9])", re.I), " broll "),
    (re.compile(r"(?<![a-z0-9])graphics?(?![a-z0-9])", re.I), " graphics "),
    (re.compile(r"(?<![a-z0-9])templates?(?![a-z0-9])", re.I), " template "),
    (re.compile(r"(?<![a-z0-9])screen[-_ ]?shots?(?![a-z0-9])", re.I), " screenshot "),
    (re.compile(r"(?<![a-z0-9])placeholders?(?![a-z0-9])", re.I), " placeholder "),
)
HOLDS_HANDLE_RE = re.compile(r"@\w|://|\bwww\.|[\w-]+\.[A-Za-z]{2,}(?:/\S*)?", re.I)
HANDLE_ONLY_RE = re.compile(r"^(@\S+|https?://\S+|www\.\S+|[\w-]+\.[A-Za-z]{2,}(?:/\S*)?)$", re.I)
SLUG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
FONT_RE = re.compile(r"^[A-Za-z][A-Za-z0-9 ]{0,40}$")


class Fatal(Exception):
    """The check could not run (exit 2)."""


# ---------------------------------------------------------------------------- small helpers

def norm(text):
    return " ".join(unicodedata.normalize("NFKC", text).replace("’", "'").split())


def squash(text):
    return re.sub(r"[\W_]+", "", unicodedata.normalize("NFKC", text).casefold())


def read_json(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        raise Fatal("%s is not readable JSON (%s)" % (what, exc.__class__.__name__))


def read_text(path, limit=4096):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read(limit)
    except OSError:
        return ""


def hexcolor(value):
    return value.upper() if isinstance(value, str) and re.fullmatch(r"#[0-9a-fA-F]{6}", value) else None


def run(cmd, stdin=None):
    try:
        p = subprocess.run(cmd, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    except FileNotFoundError:
        raise Fatal("%s is not installed" % cmd[0])
    except subprocess.TimeoutExpired:
        raise Fatal("%s took too long" % cmd[0])
    return p.returncode, p.stdout, p.stderr.decode("utf-8", "replace")


# ---------------------------------------------------------------------------- resolve

def outro_clip(workdir):
    base = os.path.join(workdir, "inputs", "outro")
    if not os.path.isdir(base):
        return None
    for name in sorted(os.listdir(base)):
        # the composite takes `ls inputs/outro/*.m*`; same rule here
        if not name.startswith(".") and fnmatch.fnmatch(name, "*.m*") and os.path.isfile(os.path.join(base, name)):
            return os.path.join(base, name)
    return None


def parse_typed(text):
    """Typed offer text -> (hero, handle). Lines that are only a handle or URL are the handle.
    The manifest's own default for this input is the word "brand" (use the brand); it is not copy."""
    if text.strip().casefold() == "brand":
        return "", ""
    lines = [norm(ln) for ln in text.splitlines() if ln.strip()]
    hero = " ".join(ln for ln in lines if not HANDLE_ONLY_RE.match(ln))
    handles = [ln for ln in lines if HANDLE_ONLY_RE.match(ln)]
    return hero, (handles[-1] if handles else "")


def typed_cta(workdir):
    """The typed CTA answer as {hero, handle, brand_name}, or None when nothing usable was typed."""
    base = os.path.join(workdir, "inputs", "cta")
    for name in ("cta.json", "cta.md", "cta.txt"):
        path = os.path.join(base, name)
        if not os.path.isfile(path):
            continue
        if name.endswith(".json"):
            data = read_json(path, "the typed call to action")
            if not isinstance(data, dict):
                raise Fatal("the typed call to action must be a JSON object")
            text = data.get("text") if isinstance(data.get("text"), str) else ""
            hero, handle = parse_typed(text)
            if isinstance(data.get("handle"), str) and data["handle"].strip():
                handle = norm(data["handle"])
            brand_name = norm(data["brandName"]) if isinstance(data.get("brandName"), str) else ""
        else:
            hero, handle = parse_typed(read_text(path))
            brand_name = ""
        if hero or handle:
            return {"hero": hero, "handle": handle, "brand_name": brand_name}
    return None


def pick_font(*sources):
    for src in sources:
        if isinstance(src, dict):
            for key in ("display", "heading", "headline", "title", "primary"):
                val = src.get(key)
                if isinstance(val, str) and FONT_RE.match(val.strip()):
                    return val.strip()
    return DEFAULT_FONT


def resolve(workdir, skill_dir):
    brief = read_json(os.path.join(workdir, "brief.json"), "the order brief")
    if not isinstance(brief, dict):
        raise Fatal("the order brief (brief.json) is missing")
    brand = brief.get("brand") if isinstance(brief.get("brand"), dict) else {}
    slug = brand.get("slug") if isinstance(brand.get("slug"), str) else ""
    override = {}
    if slug:
        if not SLUG_RE.match(slug) or ".." in slug:
            raise Fatal("the brand slug is not a safe folder name")
        data = read_json(os.path.join(skill_dir, "brand-overrides", slug, "brand.json"), "the brand file")
        if data is not None:
            if not isinstance(data, dict):
                raise Fatal("the brand file must be a JSON object")
            override = data
    ov_cta = override.get("cta") if isinstance(override.get("cta"), dict) else {}
    ov_palette = override.get("palette") if isinstance(override.get("palette"), dict) else {}
    brief_palette = brand.get("palette") if isinstance(brand.get("palette"), dict) else {}

    def words(value):
        return norm(value) if isinstance(value, str) else ""

    typed = typed_cta(workdir)
    kicker = (typed or {}).get("brand_name") or words(brand.get("name")) or words(override.get("brand"))
    if not kicker:
        raise Fatal("the order brief has no brand name, so there is nothing to put on the end card")

    ov_line, ov_handle = words(ov_cta.get("line")), words(ov_cta.get("handle"))
    if typed and typed["hero"]:
        source, hero = "cta_input", typed["hero"]
        handle = typed["handle"] or ("" if HOLDS_HANDLE_RE.search(hero) else ov_handle)
    elif ov_line:
        source, hero = "brand_overrides", ov_line
        handle = (typed or {}).get("handle") or ov_handle
    else:
        source, hero = "brand_name", GENERIC_LINE
        handle = (typed or {}).get("handle") or ""

    palette = {}
    for key in ("bg", "accent", "fg"):
        palette[key] = hexcolor(brief_palette.get(key)) or hexcolor(ov_palette.get(key)) or DEFAULT_PALETTE[key]
    font = pick_font(brand.get("typography"), brand.get("fonts"), override.get("fonts"))
    return {
        "source": source, "kicker": kicker, "hero": hero, "handle": handle,
        "outro": outro_clip(workdir) is not None,
        "palette": palette, "font": font,
    }


CORE_KEYS = ("source", "kicker", "hero", "handle", "outro")


# ---------------------------------------------------------------------------- html text

class TextRuns(html.parser.HTMLParser):
    """Visible text of a card, one entry per text run. Scripts, styles and titles are not visible."""
    SKIP = {"script", "style", "title", "noscript"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.runs, self._skip = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self._skip += 1

    def handle_endtag(self, tag):
        if tag in self.SKIP and self._skip:
            self._skip -= 1

    def handle_data(self, data):
        if not self._skip and data.strip():
            self.runs.append(norm(data))


def text_runs(markup):
    parser = TextRuns()
    try:
        parser.feed(markup)
        parser.close()
    except Exception:
        pass
    return parser.runs


# ---------------------------------------------------------------------------- picture maths

def integral(vals, w, h):
    w1 = w + 1
    out = [0] * w1
    prev = out
    for y in range(h):
        row = [0]
        row.extend(itertools.accumulate(vals[y * w:(y + 1) * w]))
        cur = [p + r for p, r in zip(prev, row)]
        out.extend(cur)
        prev = cur
    return out


def windows(a, b, w=SMALL_W, h=SMALL_H, win=WIN, step=STEP):
    """Yield (ssim, var_a, var_b) for every win x win window. b may be None (variance only)."""
    n = float(win * win)
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    ia, iaa = integral(a, w, h), integral([v * v for v in a], w, h)
    if b is not None:
        ib, ibb = integral(b, w, h), integral([v * v for v in b], w, h)
        iab = integral([x * y for x, y in zip(a, b)], w, h)
    w1 = w + 1
    for y in range(0, h - win + 1, step):
        r0, r1 = y * w1, (y + win) * w1
        for x in range(0, w - win + 1, step):
            sa = ia[r1 + x + win] - ia[r1 + x] - ia[r0 + x + win] + ia[r0 + x]
            saa = iaa[r1 + x + win] - iaa[r1 + x] - iaa[r0 + x + win] + iaa[r0 + x]
            ma = sa / n
            va = saa / n - ma * ma
            if b is None:
                yield 0.0, va, 0.0
                continue
            sb = ib[r1 + x + win] - ib[r1 + x] - ib[r0 + x + win] + ib[r0 + x]
            sbb = ibb[r1 + x + win] - ibb[r1 + x] - ibb[r0 + x + win] + ibb[r0 + x]
            sab = iab[r1 + x + win] - iab[r1 + x] - iab[r0 + x + win] + iab[r0 + x]
            mb = sb / n
            vb = sbb / n - mb * mb
            cov = sab / n - ma * mb
            s = ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
            yield s, va, vb


def detail_share(gray):
    vs = [va for _, va, _ in windows(gray, None)]
    return sum(1 for v in vs if v > VAR_FLOOR) / float(len(vs) or 1)


def ssim_weighted(a, b, w=SMALL_W, h=SMALL_H, win=WIN, step=STEP):
    """(weighted score, plain whole-frame mean) of two grey frames of the same size."""
    every, kept = [], []
    for s, va, vb in windows(a, b, w, h, win, step):
        every.append(s)
        if va > VAR_FLOOR or vb > VAR_FLOOR:
            kept.append(s)
    plain = sum(every) / float(len(every) or 1)
    return (sum(kept) / len(kept) if kept else plain), plain


def box_blur3(a, w, h):
    """3x3 box mean, edge pixels repeated."""
    rows = []
    for y in range(h):
        r = list(a[y * w:(y + 1) * w])
        p = [r[0]] + r + [r[-1]]
        rows.append([x + y_ + z for x, y_, z in zip(p, p[1:], p[2:])])
    out = []
    for y in range(h):
        up, mid, dn = rows[max(y - 1, 0)], rows[y], rows[min(y + 1, h - 1)]
        out.extend([(p + q + r) / 9.0 for p, q, r in zip(up, mid, dn)])
    return out


def shrink4(a, w, h):
    """Average 4x4 blocks. Returns (pixels, width, height)."""
    cw, ch = w // 4, h // 4
    out = []
    for y in range(ch):
        rows = [a[(4 * y + k) * w:(4 * y + k) * w + cw * 4] for k in range(4)]
        s = [p + q + r + t for p, q, r, t in zip(*rows)]
        out.extend([(s[i] + s[i + 1] + s[i + 2] + s[i + 3]) / 16.0 for i in range(0, cw * 4, 4)])
    return out, cw, ch


def crop(a, w, x0, y0, cw, ch):
    out = []
    for y in range(y0, y0 + ch):
        out.extend(a[y * w + x0:y * w + x0 + cw])
    return out


def drift_match(cand, ref):
    """How well a video frame matches the reference when it may sit a little off or be slightly zoomed.

    The weighted SSIM is taken for integer shifts of the frame against the reference, up to
    MATCH_RADIUS pixels each way on the 480x270 grid (4 times as many on the 1920x1080 frame), on
    the plain picture and on 3x3 box-blurred pictures (one pass and three passes), and the best
    score wins. The search is coarse to fine: a quarter-size pass finds the shift, a full-size pass
    refines it. Only the middle of the picture (the shift range trimmed from every edge) is
    compared, so every shift scores the same area.
    Returns (score, (dx, dy), blur passes)."""
    r = MATCH_RADIUS
    rw, rh = SMALL_W - 2 * r, SMALL_H - 2 * r
    ref_c, cw, ch = shrink4(ref, SMALL_W, SMALL_H)
    cand_c, _, _ = shrink4(cand, SMALL_W, SMALL_H)
    rc = r // 4
    crw, crh = cw - 2 * rc, ch - 2 * rc
    ref_mid_c = crop(ref_c, cw, rc, rc, crw, crh)
    coarse = None
    for sy in range(-rc, rc + 1):
        for sx in range(-rc, rc + 1):
            sc = ssim_weighted(ref_mid_c, crop(cand_c, cw, rc + sx, rc + sy, crw, crh), crw, crh, 4, 2)[0]
            if coarse is None or sc > coarse[0]:
                coarse = (sc, sx, sy)
    pics = {0: (ref, cand)}
    for passes in BLUR_PASSES:
        a, b = pics[max(k for k in pics if k < passes)]
        for _ in range(passes - max(k for k in pics if k < passes)):
            a, b = box_blur3(a, SMALL_W, SMALL_H), box_blur3(b, SMALL_W, SMALL_H)
        pics[passes] = (a, b)
    mids = {k: crop(v[0], SMALL_W, r, r, rw, rh) for k, v in pics.items()}
    seen = {}

    def clip(v):
        return max(-r, min(r, v))

    def score(dx, dy, passes):
        dx, dy = clip(dx), clip(dy)
        if (dx, dy, passes) not in seen:
            seen[(dx, dy, passes)] = ssim_weighted(mids[passes], crop(pics[passes][1], SMALL_W, r + dx, r + dy, rw, rh), rw, rh)[0]
        return seen[(dx, dy, passes)]

    cx, cy = 4 * coarse[1], 4 * coarse[2]
    spots = [(0, 0)] + [(cx + i, cy + j) for j in range(-2, 3) for i in range(-2, 3)]
    best = (-1.0, (0, 0), 0)
    for passes in BLUR_PASSES:
        for dx, dy in spots:
            sc = score(dx, dy, passes)
            if sc > best[0]:
                best = (sc, (clip(dx), clip(dy)), passes)
    # the plain picture around the best shift, so a sharp match is not lost to the blur
    bx, by = best[1]
    for dy in range(by - 1, by + 2):
        for dx in range(bx - 1, bx + 2):
            sc = score(dx, dy, 0)
            if sc > best[0]:
                best = (sc, (clip(dx), clip(dy)), 0)
    return best


def gray_args():
    return ["-vf", "scale=%d:%d:flags=area,format=gray" % (SMALL_W, SMALL_H),
            "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1"]


def gray_from_png(raw):
    rc, out, err = run(["ffmpeg", "-v", "error", "-f", "image2pipe", "-c:v", "png", "-i", "pipe:0"] + gray_args(), stdin=raw)
    if rc != 0 or len(out) != SMALL_W * SMALL_H:
        raise Fatal("the reference still could not be decoded")
    return list(out)


def gray_from_video(video, t, from_end=False, required=True):
    """One 480x270 grey frame at t seconds (or t seconds before the end of the file).
    With required=False a read that returns no frame gives None instead of an error."""
    head = ["ffmpeg", "-v", "error"] + (["-sseof", "-%.2f" % t] if from_end else ["-ss", "%.3f" % max(t, 0.0)]) + ["-i", video]
    rc, out, err = run(head + gray_args())
    if rc != 0 or len(out) != SMALL_W * SMALL_H:
        if required:
            raise Fatal("a frame of the video could not be read")
        return None
    return list(out)


def last_frame(video, dur):
    """The last frame. -sseof counts from the end of the FILE, so when the audio runs longer than
    the picture it finds no frame; then read half a second before the end instead."""
    got = gray_from_video(video, 0.1, from_end=True, required=False)
    return got if got is not None else gray_from_video(video, max(dur - 0.5, 0.0))


def probe_duration(path):
    rc, out, err = run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path])
    try:
        return float(out.decode().strip())
    except ValueError:
        raise Fatal("the video length could not be read")


def probe_video_duration(path):
    """Length of the picture: the video stream's own duration, else the file's."""
    rc, out, err = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=duration", "-of", "csv=p=0", path])
    try:
        d = float(out.decode().split()[0])
        if d > 0:
            return d
    except (ValueError, IndexError):
        pass
    return probe_duration(path)


# ---------------------------------------------------------------------------- manifest + labels

def find_file(workdir, *rels):
    for rel in rels:
        p = os.path.join(workdir, rel)
        if os.path.isfile(p):
            return p
    return None


def load_manifest(workdir, path, *default_rels):
    p = path or find_file(workdir, *default_rels)
    if not p:
        return None
    data = read_json(p, "the visuals list")
    return data if isinstance(data, dict) else None


def cta_asset(manifest):
    assets = manifest.get("assets") if isinstance(manifest, dict) else None
    found = [a for a in (assets or []) if isinstance(a, dict) and a.get("is_cta")]
    return found


def production_tokens(text):
    """(all tokens, production tokens) of a text run, ignoring case. Joiners (+ / & &amp; , | - and
    whitespace) are dropped; b-roll, graphics, template, screenshot, placeholder, stock and the layout
    names are the production tokens."""
    t = unicodedata.normalize("NFKC", text).replace("&amp;", "&")
    for rx, token in _TOKEN_FORMS:
        t = rx.sub(token, t)
    toks = [x for x in re.split(r"[\s+/&,|\u00b7\u2022#_.\-]+", t.casefold()) if x]
    return toks, [x for x in toks if x in PRODUCTION_WORDS]


def production_label(text):
    """The production label in one text run of a content card, or None. What counts:
    a layout name used as visible text; a short run (at most TAG_MAX_TOKENS tokens) holding two or
    more production tokens, in any case and with any joiner ("REAL SITE B-ROLL / GRAPHICS",
    "Real Site B-roll & Graphics", "B-ROLL GRAPHICS"); an all-caps tag that carries a joiner, stands
    alone (TEMPLATE, SCREENSHOT) or ends in a number (B-ROLL 02); a slug (a token with an underscore)
    holding b-roll, graphics, template or screenshot. One production word in an ordinary run
    ("Make B-roll with AI", "MOTION GRAPHICS IN 5 MIN", "REAL SITE B-ROLL") is content, not a label."""
    hit = LAYOUT_CONST_RE.search(text)
    if hit:
        return hit.group(0)
    hit = LAYOUT_SPACED_RE.search(text)
    if hit and (text.isupper() or squash(text) == squash(hit.group(0))):
        return hit.group(0)
    toks, prod = production_tokens(text)
    if len(prod) >= 2 and len(toks) <= TAG_MAX_TOKENS:
        return text[:60]
    hit = WORD_RE.search(text)
    if not hit:
        return None
    if any("_" in tok and WORD_RE.search(tok) for tok in text.split()):
        return hit.group(0)
    if text.isupper() and (TAG_JOINER_RE.search(text) or len(text.split()) == 1 or TAG_MARKER_RE.search(text)):
        return hit.group(0)
    return None


def scan_labels(assets, expected):
    """Production labels on the content cards (see production_label). The brand's own words
    (kicker, hero, handle) are not labels, so they are taken out of every text run first. The end
    card is held to the stricter rule in check_card_words (nothing but its three texts), so it is
    skipped here."""
    known = [expected[k] for k in ("kicker", "hero", "handle") if expected.get(k)]
    problems = []
    for a in assets:
        if not isinstance(a, dict) or not isinstance(a.get("html"), str) or a.get("is_cta"):
            continue
        for run_ in text_runs(a["html"]):
            left = run_
            for k in known:
                left = re.sub(re.escape(k), " ", left, flags=re.I)
            left = " ".join(left.split())
            hit = production_label(left) if left else None
            if hit:
                problems.append("card %s shows the production label \"%s\"" % (a.get("id", "?"), hit))
                break
    return problems


def check_card_words(cta, expected, problems):
    runs = text_runs(cta.get("html") or "")
    visible = squash("".join(runs))
    spaced = " ".join(runs)
    for field in ("kicker", "hero", "handle"):
        want = expected.get(field) or ""
        if want and squash(want) not in visible:
            problems.append("the end card does not show its %s text" % field)
    if not (expected.get("handle") or ""):
        for field in ("kicker", "hero"):      # a typed line may hold a handle or link of its own
            if expected.get(field):
                spaced = re.sub(re.escape(expected[field]), " ", spaced, flags=re.I)
        if re.search(r"@\w|://|\bwww\.", spaced):
            problems.append("the end card shows a handle or link, but this brand has none")
    left = visible
    for field in ("kicker", "hero", "handle"):
        s = squash(expected.get(field) or "")
        if s:
            left = left.replace(s, "")
    for word in BANNED_SQUASHED:
        if word in left:
            problems.append("the end card carries a production label (%s)" % word)
            break
    if len(left) > EXTRA_CHARS:
        problems.append("the end card carries words beyond the brand name, the offer line and the handle")


def decode_reference(cta, problems):
    b64 = cta.get("ref_png_b64")
    if not isinstance(b64, str) or not b64.strip():
        problems.append("the end card has no reference still (ref_png_b64)")
        return None
    try:
        raw = base64.b64decode("".join(b64.split()), validate=True)
    except (binascii.Error, ValueError):
        problems.append("the end card reference still is not valid base64")
        return None
    if raw[:8] != PNG_SIG or raw[12:16] != b"IHDR" or len(raw) < 24:
        problems.append("the end card reference still is not a PNG")
        return None
    w, h = struct.unpack(">II", raw[16:24])
    if (w, h) != CANVAS:
        problems.append("the end card reference still is %dx%d, not 1920x1080" % (w, h))
        return None
    return raw


# ---------------------------------------------------------------------------- the four modes

def verify_manifest(workdir, skill_dir, manifest_path):
    expected = resolve(workdir, skill_dir)
    manifest = load_manifest(workdir, manifest_path, "saves/visuals_manifest.json", "prior/visuals_manifest.json")
    if manifest is None:
        return ["the visuals list was not saved"], expected
    problems = []
    assets = manifest.get("assets") if isinstance(manifest.get("assets"), list) else []
    if not assets:
        return ["the visuals list has no cards"], expected
    ctas = cta_asset(manifest)
    if len(ctas) != 1:
        return ["expected exactly one end card, found %d" % len(ctas)], expected
    cta = ctas[0]
    if cta.get("id") != "cta" or cta.get("section") != "cta" or cta.get("kind") != "gfx":
        problems.append("the end card must be a gfx card with id cta and section cta")
    secs = cta.get("seconds")
    if isinstance(secs, bool) or not isinstance(secs, (int, float)) or not (CARD_MIN_S <= secs <= CARD_MAX_S):
        problems.append("the end card must run %d to %d seconds" % (CARD_MIN_S, CARD_MAX_S))
    if not isinstance(cta.get("html"), str) or not cta["html"].strip():
        problems.append("the end card has no markup")
    else:
        check_card_words(cta, expected, problems)
    have = manifest.get("end_card")
    if not isinstance(have, dict):
        problems.append("the visuals list has no end_card object")
    else:
        for key in CORE_KEYS:
            a, b = have.get(key), expected[key]
            if key == "handle" and a is None:
                a = ""
            if isinstance(b, str):
                a = norm(a) if isinstance(a, str) else a
            if a != b:
                problems.append("end_card.%s does not match the brand's end card (%s)" % (key, "wanted " + json.dumps(b, ensure_ascii=False)[:80]))
    raw = decode_reference(cta, problems)
    if raw is not None:
        if detail_share(gray_from_png(raw)) < MIN_DETAIL:
            problems.append("the end card reference still is blank")
    problems.extend(scan_labels(assets, expected))
    return problems, expected


def verify_plan(workdir, skill_dir, plan_path, manifest_path):
    plan = read_json(plan_path or os.path.join(workdir, "saves", "broll_plan.json"), "the b-roll plan")
    if not isinstance(plan, dict) or not isinstance(plan.get("rows"), list) or not plan["rows"]:
        return ["the b-roll plan was not saved or has no rows"]
    rows, problems = plan["rows"], []
    try:
        dur = float(plan["duration"])
        for r in rows:
            r["start"], r["end"] = float(r["start"]), float(r["end"])
    except (KeyError, TypeError, ValueError):
        return ["the b-roll plan rows have no usable times"]
    if abs(rows[0]["start"]) >= 0.05:
        problems.append("the plan does not start at 0")
    for a, b in zip(rows, rows[1:]):
        if abs(a["end"] - b["start"]) >= 0.05:
            problems.append("gap or overlap in the plan at %.1f s" % a["end"])
            break
    if abs(rows[-1]["end"] - dur) >= 0.5:
        problems.append("the plan ends at %.1f s, not at the video length %.1f s" % (rows[-1]["end"], dur))
    cta_rows = [r for r in rows if r.get("asset") == "gfx:cta"]
    last = rows[-1]
    if len(cta_rows) != 1 or last.get("asset") != "gfx:cta":
        problems.append("the last row of the plan must be the end card (gfx:cta), used once")
    else:
        if last.get("layout") != "FULLSCREEN_BROLL":
            problems.append("the end card row must be FULLSCREEN_BROLL")
        if last.get("zoom") not in (None, "none"):
            problems.append("the end card row must have zoom none (a zoom crops and moves the card)")
        length = last["end"] - last["start"]
        if length < CARD_MIN_S - 0.05:
            problems.append("the end card row is %.1f s; it must be at least %d s" % (length, CARD_MIN_S))
        if length > CARD_MAX_S + 0.5:
            problems.append("the end card row is %.1f s; it must be at most %d s" % (length, CARD_MAX_S))
        manifest = load_manifest(workdir, manifest_path, "prior/visuals_manifest.json", "saves/visuals_manifest.json")
        ctas = cta_asset(manifest) if manifest else []
        if len(ctas) == 1 and isinstance(ctas[0].get("seconds"), (int, float)) and length < ctas[0]["seconds"] - 0.6:
            # a longer row only holds the card's last frame; a shorter one cuts the card off
            problems.append("the end card row (%.1f s) is shorter than the card (%.1f s) and would cut it off" % (length, ctas[0]["seconds"]))
    return problems


def verify_final(workdir, skill_dir, video, manifest_path, threshold):
    video = video or os.path.join(workdir, "saves", "final_video.mp4")
    if not os.path.isfile(video):
        return ["the final video was not saved"], []
    expected = resolve(workdir, skill_dir)
    manifest = load_manifest(workdir, manifest_path, "prior/visuals_manifest.json", "saves/visuals_manifest.json")
    ctas = cta_asset(manifest) if manifest else []
    if len(ctas) != 1:
        return ["the visuals list has no single end card to compare with: rerun the order from build_visuals"], []
    if not (isinstance(ctas[0].get("ref_png_b64"), str) and ctas[0]["ref_png_b64"].strip()):
        return ["the end card has no reference still, so the video cannot be checked (the order was resumed from visuals saved "
                "before this check existed): rerun the order from build_visuals"], []
    problems, notes = [], []
    raw = decode_reference(ctas[0], problems)
    if raw is None:
        return problems, notes
    ref = gray_from_png(raw)
    dur = probe_video_duration(video)
    tail = 0.0
    if expected["outro"]:
        tail = probe_duration(outro_clip(workdir))
    t_card, t_before = dur - tail - 1.0, dur - tail - 14.0
    score, shift, _ = drift_match(gray_from_video(video, t_card), ref)
    notes.append("end card match %.2f (need %.2f)" % (score, threshold))
    if score < threshold:
        problems.append("the video does not end on the brand end card (match %.2f, need %.2f)" % (score, threshold))
    if t_before >= 0.5:
        earlier = drift_match(gray_from_video(video, t_before), ref)[0]
        notes.append("14 s earlier %.2f" % earlier)
        if earlier >= threshold:
            problems.append("the end card is already on screen 14 s before the end (match %.2f)" % earlier)
    if expected["outro"]:
        # the last frame belongs to the outro clip (it may fade out); the card must not end on black
        if max(gray_from_video(video, dur - tail - 0.1)) < 48:
            problems.append("the end card is black just before the outro")
    elif max(last_frame(video, dur)) < 48:
        problems.append("the last frame is black")
    return problems, notes


# ---------------------------------------------------------------------------- command line

def report(problems, ok_line):
    if not problems:
        print(ok_line)
        return 0
    for p in problems:
        print("x " + p, file=sys.stderr)
    print("End card check failed: %s%s" % (problems[0], " (+%d more)" % (len(problems) - 1) if len(problems) > 1 else ""), file=sys.stderr)
    return 1


def main(argv):
    ap = argparse.ArgumentParser(description="Longform end card: resolve the words and verify the picture.")
    ap.add_argument("mode", choices=["resolve", "verify-manifest", "verify-plan", "verify-final"])
    ap.add_argument("--dir", default=".", help="step workdir (brief.json, inputs/, prior/, saves/)")
    ap.add_argument("--skill-dir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    ap.add_argument("--manifest", help="visuals manifest to read instead of the default location")
    ap.add_argument("--plan", help="b-roll plan to read instead of saves/broll_plan.json")
    ap.add_argument("--video", help="final video to read instead of saves/final_video.mp4")
    ap.add_argument("--threshold", type=float, default=THRESHOLD, help="SSIM needed to count as the end card (default %.2f)" % THRESHOLD)
    a = ap.parse_args(argv)
    workdir, skill_dir = os.path.abspath(a.dir), os.path.abspath(a.skill_dir)
    try:
        if a.mode == "resolve":
            print(json.dumps(resolve(workdir, skill_dir), indent=2, ensure_ascii=False))
            return 0
        if a.mode == "verify-manifest":
            problems, _ = verify_manifest(workdir, skill_dir, a.manifest)
            return report(problems, "End card check passed: one end card, its words match the brand, no production labels")
        if a.mode == "verify-plan":
            return report(verify_plan(workdir, skill_dir, a.plan, a.manifest), "End card check passed: the plan ends on the end card")
        problems, notes = verify_final(workdir, skill_dir, a.video, a.manifest, a.threshold)
        return report(problems, "End card check passed: the video ends on the brand end card (%s)" % "; ".join(notes))
    except Fatal as exc:
        print("End card check could not run: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
