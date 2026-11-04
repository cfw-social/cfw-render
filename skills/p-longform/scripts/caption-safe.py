#!/usr/bin/env python3
"""caption-safe.py - keep the caption band clear on full-frame stills (B51, composite step).

Stdlib only; ffmpeg does the picture work. Captions are burned once, in post_process, over the bottom of
the finished video (y 820 and down). A still that fills the frame and has its own text near the bottom
(a diagram with labels, a slide) ends up under the captions, so the final check fails the picture. This
script fits every such still above the caption band instead: scaled to fit inside the top 800 px of the
frame, centred, over a blurred, slightly darkened copy of itself that fills the rest of the frame (no bars).

  caption-safe.py --plan prior/broll_plan.json --broll inputs/broll --visuals work/visuals \\
                  --out-plan work/broll_plan.safe.json [--no-pip] [--band-top 800]

A row is fitted when it shows one picture over the whole frame (layout FULLSCREEN_BROLL or PIP_CORNER, or
any layout with presenter off, --no-pip) and its asset is a still: `broll/<image file>` or `still:<id>`.
The layout name is read in any case, as build-segments reads it. The fitted copy is written to
<visuals>/capsafe-<hash>.png, and in the new plan that row's asset becomes `still:capsafe-<hash>` with zoom
`none` (a slow zoom would push the bottom edge into the band). A `still:capsafe-*` asset is never fitted again.
Everything else is copied as it was: cards (`gfx:`, `hf:`), video footage, side layouts, and above all the
end card.
Then build the segments from --out-plan instead of the plan.

Exit 0 = written, 2 = bad input (nothing written).
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

CANVAS_W, CANVAS_H = 1920, 1080
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".webp", ".bmp")
PIP_LAYOUTS = ("PIP_CORNER", "PIP_SIDE", "SIDE_BY_SIDE")
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
FITTED_PREFIX = "capsafe-"      # the stills this script wrote; running it again must not shrink them twice


class Usage(Exception):
    pass


def load_plan(path):
    try:
        with open(path, encoding="utf-8") as fh:
            plan = json.load(fh)
    except OSError as exc:
        raise Usage("cannot read the plan (%s): %s" % (path, exc.strerror or exc))
    except ValueError as exc:
        raise Usage("the plan (%s) is not valid JSON: %s" % (path, exc))
    rows = plan.get("rows") if isinstance(plan, dict) else plan
    if not isinstance(rows, list) or not all(isinstance(r, dict) for r in rows):
        raise Usage("the plan (%s) has no rows" % path)
    return plan, rows


def shows_whole_frame(row, no_pip):
    layout = str(row.get("layout") or "").upper()          # build-segments upper-cases the layout too
    return layout in ("FULLSCREEN_BROLL", "PIP_CORNER") or (no_pip and layout in PIP_LAYOUTS)


def find_source(ref, n, broll, visuals):
    """The picture file for a still asset reference, or None when the asset is not a still."""
    if ref.startswith("broll/"):
        if not broll or not os.path.isdir(broll):
            raise Usage("row %d uses %s but the --broll folder is missing" % (n, ref))
        base = os.path.realpath(broll)
        full = os.path.realpath(os.path.join(base, ref[len("broll/"):]))
        if os.path.commonpath([base, full]) != base:
            raise Usage("row %d asset %s is outside the b-roll folder" % (n, ref))
        if not full.lower().endswith(IMAGE_EXT):
            return None
        if not os.path.isfile(full):
            raise Usage("row %d asset %s not found" % (n, ref))
        return full
    m = re.match(r"^still:(.+)$", ref)
    if not m or m.group(1).startswith(FITTED_PREFIX):          # not a still, or already fitted: leave it
        return None
    if not ID_RE.match(m.group(1)):
        raise Usage("row %d has an asset reference I do not understand: %r" % (n, ref))
    if not visuals or not os.path.isdir(visuals):
        raise Usage("row %d uses %s but the --visuals folder is missing" % (n, ref))
    base = os.path.realpath(visuals)
    for ext in (".mp4", ".mov", ".png", ".jpg", ".jpeg"):      # the order build-segments looks in
        cand = os.path.join(base, m.group(1) + ext)
        if os.path.isfile(cand):
            return cand if ext in (".png", ".jpg", ".jpeg") else None
    raise Usage("row %d asset %s not found" % (n, ref))


def fit_command(src, out, band_top):
    graph = ("[0:v]split=2[a][b];"
             "[a]scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,boxblur=60:4,eq=brightness=-0.08,setsar=1[bg];"
             "[b]scale=%d:%d:force_original_aspect_ratio=decrease,setsar=1[fg];"
             "[bg][fg]overlay=(W-w)/2:(%d-h)/2,format=rgb24[o]"
             % (CANVAS_W, CANVAS_H, CANVAS_W, CANVAS_H, CANVAS_W, band_top, band_top))
    return ["ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-y", "-i", src,
            "-filter_complex", graph, "-map", "[o]", "-frames:v", "1", "-update", "1", out]


def main(argv=None):
    ap = argparse.ArgumentParser(prog="caption-safe.py", description=__doc__.split("\n")[0])
    ap.add_argument("--plan", required=True)
    ap.add_argument("--broll", default="")
    ap.add_argument("--visuals", required=True)
    ap.add_argument("--out-plan", required=True)
    ap.add_argument("--no-pip", action="store_true")
    ap.add_argument("--band-top", type=int, default=800, help="the stills are fitted into y 0..this (default 800)")
    args = ap.parse_args(argv)
    try:
        if not 200 <= args.band_top < CANVAS_H:
            raise Usage("--band-top must be 200..1079")
        plan, rows = load_plan(args.plan)
        os.makedirs(args.visuals, exist_ok=True)
        made, fitted = {}, 0
        for i, row in enumerate(rows):
            n = i + 1
            ref = row.get("asset")
            if not isinstance(ref, str) or not shows_whole_frame(row, args.no_pip):
                continue
            src = find_source(ref, n, args.broll, args.visuals)
            if not src:
                continue
            name = FITTED_PREFIX + hashlib.sha1(("%s|%d" % (src, args.band_top)).encode("utf-8")).hexdigest()[:10]
            if name not in made:
                out = os.path.join(args.visuals, name + ".png")
                proc = subprocess.run(fit_command(src, out, args.band_top), capture_output=True, text=True)
                if proc.returncode != 0 or not os.path.isfile(out) or os.path.getsize(out) == 0:
                    tail = " ".join((proc.stderr or "").split())[-200:]
                    raise Usage("ffmpeg could not fit row %d (%s): %s" % (n, ref, tail or "no output"))
                made[name] = out
            print("row %d: %s fitted above the caption band (y 0-%d) -> still:%s, zoom none"
                  % (n, ref, args.band_top, name))
            row["asset"] = "still:" + name
            row["zoom"] = "none"
            fitted += 1
        os.makedirs(os.path.dirname(os.path.abspath(args.out_plan)), exist_ok=True)
        with open(args.out_plan, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(plan, fh, indent=1)
            fh.write("\n")
        print("caption-safe: %d of %d rows fitted -> %s" % (fitted, len(rows), args.out_plan))
        return 0
    except Usage as exc:
        print("ERROR caption-safe: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
