#!/usr/bin/env python3
"""build-segments.py - turn a b-roll plan into one 1920x1080 segment per row.

Used by p-longform step 06 (composite). Pure ffmpeg + Python standard library.
No network. Deterministic: the same inputs give the same ffmpeg commands.

Usage
  build-segments.py --plan prior/broll_plan.json \\
      --avatar work/avatar-on-bg.mp4 --avatar-raw prior/avatar_video.mp4 \\
      --key "colorkey=0x00FF00:0.25:0.05,colorkey=0x00FF00:0.40:0.01" \\
      --visuals work/visuals --broll inputs/broll --out work/seg \\
      --pip-card rounded --pip-size 304x380 --pip-margin 72 --pip-border "#D4A84C"

Inputs
  --plan        broll_plan.json: {"duration": s, "rows": [{start, end, says, layout,
                asset, zoom, pip_side}, ...]} (a bare list of rows also works).
                layout is AVATAR_FULL | PIP_CORNER | PIP_SIDE | FULLSCREEN_BROLL |
                SIDE_BY_SIDE. asset is "broll/<file>" (a file in --broll), or
                "gfx:<id>" / "hf:<id>" / "still:<id>" (<id>.mp4 or <id>.png in
                --visuals), or null. zoom is "slow-in" or "none". pip_side is
                "left" | "right" | null (null alternates, starting on the right).
  --avatar      The avatar already composited on its background (1920x1080).
                AVATAR_FULL rows are cut from it.
  --avatar-raw  The sealed avatar track. EVERY segment takes its audio from it,
                and the PIP card / side column shows its picture.
  --key         colorkey filter chain applied to the raw avatar before it is put in
                a card or column. Empty or absent = opaque avatar, no keying.
  --visuals     Folder holding the rendered cards (<id>.mp4 or <id>.png).
  --broll       Folder holding the owner's footage and stills.
  --no-pip      Voice-only / no presenter: PIP_CORNER, PIP_SIDE and SIDE_BY_SIDE
                rows are built as FULLSCREEN_BROLL (alias --voice-only).

Output (in --out)
  seg-0001-<layout>.mp4, seg-0002-...: 1920x1080, 25 fps, H.264 yuv420p, a keyframe every
  second, and the exact audio window of the row as 48 kHz stereo PCM (the container is
  QuickTime, the name ends .mp4). PCM on purpose: an AAC segment ends with up to 21 ms of
  encoder padding that a concat keeps, so a long video drifts by seconds; the step's one
  AAC encode happens after the concat. Rows are cut on the 25 fps grid (start =
  round(start * 25) / 25), so the segments join with no gap and no overlap. segments.json
  lists what was built. _assets/ and _state/ hold the PIP card images and the resume
  records. Any other seg-*.mp4 in --out is removed so the concat in the step never picks
  up a stale file.

Exit codes
  0 all segments built      1 ffmpeg failed or an output failed verification
  2 bad arguments or an input is missing or unusable (nothing was encoded)
"""
import argparse
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import struct
import subprocess
import sys
import zlib

FPS = 25
CW, CH = 1920, 1080
LAYOUTS = ("AVATAR_FULL", "PIP_CORNER", "PIP_SIDE", "FULLSCREEN_BROLL", "SIDE_BY_SIDE")
PIP_LAYOUTS = ("PIP_CORNER", "PIP_SIDE", "SIDE_BY_SIDE")
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".webp", ".bmp")
VIDEO_EXT = (".mp4", ".mov", ".m4v", ".mkv", ".webm")
KEY_ITEM = r"colorkey=0x[0-9A-Fa-f]{6}:[0-9.]+:[0-9.]+"
KEY_RE = re.compile("^" + KEY_ITEM + "(," + KEY_ITEM + ")*$")
HEX_RE = re.compile(r"^#?[0-9A-Fa-f]{6}$")
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
PAD = 48          # room for the card shadow around the PIP card
SHADOW_DY = 6
SHADOW_SIGMA = 11.0
SHADOW_ALPHA = 150.0 / 255.0


class Usage(Exception):
    """Bad arguments or an unusable input (exit 2)."""


class BuildError(Exception):
    """ffmpeg failed or an output did not verify (exit 1)."""


def log(msg):
    sys.stderr.write("build-segments: " + msg + "\n")


# ---------------------------------------------------------------- tools

def find_tool(name):
    found = shutil.which(name)
    if found:
        return found
    for d in ("/opt/homebrew/bin", "/usr/local/bin"):
        cand = os.path.join(d, name)
        if os.access(cand, os.X_OK):
            return cand
    raise Usage(name + " not found on PATH; install ffmpeg")


def run(cmd, timeout=None):
    try:
        return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise BuildError("timed out after %ss: %s" % (timeout, os.path.basename(cmd[0])))


def probe(ffprobe, path):
    r = run([ffprobe, "-v", "error", "-show_entries",
             "format=duration:stream=index,codec_type,width,height",
             "-of", "json", path])
    if r.returncode != 0:
        raise Usage("cannot read %s: %s" % (path, (r.stderr.strip() or "ffprobe failed").splitlines()[-1]))
    try:
        data = json.loads(r.stdout or "{}")
    except ValueError:
        raise Usage("cannot read %s (ffprobe gave no data)" % path)
    info = {"duration": None, "video": None, "audio": False}
    try:
        info["duration"] = float((data.get("format") or {}).get("duration"))
    except (TypeError, ValueError):
        pass
    for s in data.get("streams") or []:
        if s.get("codec_type") == "video" and info["video"] is None:
            info["video"] = (int(s.get("width") or 0), int(s.get("height") or 0))
        elif s.get("codec_type") == "audio":
            info["audio"] = True
    return info


# ---------------------------------------------------------------- plan

def num(v, what):
    try:
        f = float(v)
    except (TypeError, ValueError):
        raise Usage("%s is not a number: %r" % (what, v))
    if math.isnan(f) or math.isinf(f):
        raise Usage("%s is not finite" % what)
    return f


def load_plan(path):
    try:
        with open(path, "r") as fh:
            data = json.load(fh)
    except IOError as e:
        raise Usage("cannot read plan %s: %s" % (path, e.strerror or e))
    except ValueError as e:
        raise Usage("plan %s is not valid JSON: %s" % (path, e))
    rows = data.get("rows") if isinstance(data, dict) else data
    if not isinstance(rows, list) or not rows:
        raise Usage("plan %s has no rows" % path)
    out = []
    for i, r in enumerate(rows):
        n = i + 1
        if not isinstance(r, dict):
            raise Usage("row %d is not an object" % n)
        layout = str(r.get("layout") or "").upper()
        if layout not in LAYOUTS:
            raise Usage("row %d has layout %r; use one of %s" % (n, r.get("layout"), ", ".join(LAYOUTS)))
        start = num(r.get("start"), "row %d start" % n)
        end = num(r.get("end"), "row %d end" % n)
        if end <= start:
            raise Usage("row %d ends (%.2f) before it starts (%.2f)" % (n, end, start))
        side = r.get("pip_side")
        if side not in (None, "", "left", "right"):
            raise Usage("row %d pip_side must be left, right or null" % n)
        zoom = r.get("zoom") or "none"
        out.append({"n": n, "start": start, "end": end, "layout": layout,
                    "asset": r.get("asset") or None, "zoom": str(zoom), "pip_side": side or None})
    if out[0]["start"] > 0.1:
        raise Usage("plan must start at 0 (row 1 starts at %.2f)" % out[0]["start"])
    for a, b in zip(out, out[1:]):
        if abs(a["end"] - b["start"]) > 0.1:
            raise Usage("rows %d and %d do not meet: row %d ends at %.2f, row %d starts at %.2f"
                        % (a["n"], b["n"], a["n"], a["end"], b["n"], b["start"]))
    return out


def snap(t):
    return int(math.floor(t * FPS + 0.5))


# ---------------------------------------------------------------- PIP card images (stdlib PNG)

def write_png(path, w, h, ctype, pixels):
    ch = {0: 1, 6: 4}[ctype]
    stride = w * ch
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += pixels[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
           + chunk(b"IEND", b""))
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(png)
    os.replace(tmp, path)


def rr_sd(px, py, cx, cy, hw, hh, r):
    """Signed distance to a rounded rectangle: negative inside, positive outside."""
    qx = abs(px - cx) - (hw - r)
    qy = abs(py - cy) - (hh - r)
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r


def cover(sd):
    return min(1.0, max(0.0, 0.5 - sd))


def make_pip_assets(folder, w, h, radius, bw, border_rgb):
    """Rounded alpha mask (w x h) and frame overlay (border + outside-only shadow)."""
    os.makedirs(folder, exist_ok=True)
    tag = "%dx%d-r%d-bw%d-%02x%02x%02x" % ((w, h, radius, bw) + tuple(border_rgb))
    mask_path = os.path.join(folder, "pip-mask-%s.png" % tag)
    frame_path = os.path.join(folder, "pip-frame-%s.png" % tag)
    if os.path.exists(mask_path) and os.path.exists(frame_path):
        return mask_path, frame_path
    r = min(radius, w // 2, h // 2)
    mask = bytearray()
    for y in range(h):
        py = y + 0.5
        for x in range(w):
            mask.append(int(round(255 * cover(rr_sd(x + 0.5, py, w / 2.0, h / 2.0, w / 2.0, h / 2.0, r)))))
    write_png(mask_path, w, h, 0, mask)
    fw, fh = w + 2 * PAD, h + 2 * PAD
    cx, cy = fw / 2.0, fh / 2.0
    hw, hh = w / 2.0, h / 2.0
    br, bgc, bb = border_rgb
    frame = bytearray()
    reach = 4.0 * SHADOW_SIGMA
    for y in range(fh):
        py = y + 0.5
        for x in range(fw):
            px = x + 0.5
            sd = rr_sd(px, py, cx, cy, hw, hh, r)
            outer = cover(sd)
            ring = outer * (1.0 - cover(sd + bw))
            sds = rr_sd(px, py - SHADOW_DY, cx, cy, hw, hh, r)
            if outer >= 1.0 or sds > reach:
                sh = 0.0
            else:
                sh = SHADOW_ALPHA * 0.5 * math.erfc(sds / (SHADOW_SIGMA * math.sqrt(2.0)))
                sh *= (1.0 - outer)
            a = ring + sh * (1.0 - ring)
            if a <= 0.0:
                frame += b"\x00\x00\x00\x00"
            else:
                rr = ring * br / a
                gg = ring * bgc / a
                b2 = ring * bb / a
                frame += bytes((int(round(min(255.0, rr))), int(round(min(255.0, gg))),
                                int(round(min(255.0, b2))), int(round(255 * min(1.0, a)))))
    write_png(frame_path, fw, fh, 6, frame)
    return mask_path, frame_path


# ---------------------------------------------------------------- filter graph pieces

def audio_chain(src, dur):
    return ("[%s]aresample=async=1:first_pts=0,"
            "aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,"
            "apad,atrim=duration=%.6f,asetpts=PTS-STARTPTS[a]" % (src, dur))


def fit_chain(inlabel, outlabel, tw, th, sw, sh):
    """Fit a source into tw x th with no bars: scale when the shapes match, else blurred fill."""
    if sw and sh and abs(float(sw) / sh - float(tw) / th) < 0.012:
        return ["[%s]scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,setsar=1[%s]"
                % (inlabel, tw, th, tw, th, outlabel)]
    return [
        "[%s]split=2[%s_a][%s_b]" % (inlabel, outlabel, outlabel),
        "[%s_a]scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,boxblur=30:3,setsar=1[%s_bg]"
        % (outlabel, tw, th, tw, th, outlabel),
        "[%s_b]scale=%d:%d:force_original_aspect_ratio=decrease,setsar=1[%s_fg]" % (outlabel, tw, th, outlabel),
        "[%s_bg][%s_fg]overlay=(W-w)/2:(H-h)/2[%s]" % (outlabel, outlabel, outlabel),
    ]


def asset_chain(inlabel, outlabel, tw, th, asset, zoom_on, frames, hold_s):
    """Source -> tw x th, 25 fps, optional slow zoom, optional hold of the last frame."""
    parts = []
    head = "%s_in" % outlabel
    pre = "fps=%d,setpts=PTS-STARTPTS" % FPS
    parts.append("[%s]%s[%s]" % (inlabel, pre, head))
    sw, sh = asset["size"]
    cur = outlabel + "_fit"
    parts += fit_chain(head, cur, tw, th, sw, sh)
    if zoom_on:
        z = outlabel + "_z"
        parts.append("[%s]scale=%d:%d,zoompan=z='1+0.08*on/%d':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'"
                     ":d=1:s=%dx%d:fps=%d[%s]" % (cur, tw * 3 // 2, th * 3 // 2, max(frames, 1), tw, th, FPS, z))
        cur = z
    tail = []
    if hold_s:
        tail.append("tpad=stop_mode=clone:stop_duration=%.3f" % hold_s)
    tail.append("setpts=PTS-STARTPTS")
    tail.append("format=yuv420p")
    parts.append("[%s]%s[%s]" % (cur, ",".join(tail), outlabel))
    return parts


def person_chain(inlabel, outlabel, tw, th, key, card_bg, rgba):
    """The raw avatar at tw x th: keyed onto a solid card when keyed, else centre-cropped."""
    parts = []
    fit = "scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,setsar=1" % (tw, th, tw, th)
    base = "fps=%d,setpts=PTS-STARTPTS" % FPS
    if key:
        parts.append("[%s]%s,format=rgba,%s,%s,format=rgba[%s_p]" % (inlabel, base, key, fit, outlabel))
        parts.append("color=c=0x%s:s=%dx%d:r=%d[%s_c]" % (card_bg, tw, th, FPS, outlabel))
        parts.append("[%s_c][%s_p]overlay=0:0:format=auto,format=%s[%s]"
                     % (outlabel, outlabel, "rgba" if rgba else "yuv420p", outlabel))
    else:
        parts.append("[%s]%s,%s,format=%s[%s]" % (inlabel, base, fit, "rgba" if rgba else "yuv420p", outlabel))
    return parts


# ---------------------------------------------------------------- building

def parse_size(text):
    m = re.match(r"^(\d+)x(\d+)$", text or "")
    if not m:
        raise Usage("--pip-size must look like 304x380, got %r" % text)
    w, h = int(m.group(1)), int(m.group(2))
    if not (64 <= w <= 960 and 64 <= h <= 1080):
        raise Usage("--pip-size %dx%d is outside 64x64 .. 960x1080" % (w, h))
    return w, h


def parse_hex(text, name):
    if not HEX_RE.match(text or ""):
        raise Usage("%s must be a 6-digit hex colour like #D4A84C, got %r" % (name, text))
    return text.lstrip("#").upper()


def resolve_asset(ref, row, args, ffprobe, cache):
    """Return {"path","kind","size","dur","policy"} for a row's asset, or None."""
    if not ref:
        return None
    n = row["n"]
    if ref.startswith("broll/"):
        if not args.broll or not os.path.isdir(args.broll):
            raise Usage("row %d uses %s but the --broll folder is missing: %s" % (n, ref, args.broll or "(not given)"))
        base = os.path.realpath(args.broll)
        full = os.path.realpath(os.path.join(base, ref[len("broll/"):]))
        if os.path.commonpath([base, full]) != base:
            raise Usage("row %d asset %s is outside the b-roll folder" % (n, ref))
        cands = [full]
        policy = "loop"
    else:
        m = re.match(r"^(gfx|hf|still):(.+)$", ref)
        if not m or not ID_RE.match(m.group(2)):
            raise Usage("row %d has an asset reference I do not understand: %r" % (n, ref))
        if not args.visuals or not os.path.isdir(args.visuals):
            raise Usage("row %d uses %s but the --visuals folder is missing: %s" % (n, ref, args.visuals or "(not given)"))
        base = os.path.realpath(args.visuals)
        cands = [os.path.join(base, m.group(2) + e) for e in (".mp4", ".mov", ".png", ".jpg", ".jpeg")]
        policy = "hold"
    path = next((c for c in cands if os.path.isfile(c)), None)
    if not path:
        raise Usage("row %d asset %s not found (looked for %s)" % (n, ref, os.path.basename(cands[0])
                                                                    if len(cands) == 1 else
                                                                    ", ".join(os.path.basename(c) for c in cands)))
    if path in cache:
        return cache[path]
    info = probe(ffprobe, path)
    if not info["video"]:
        raise Usage("row %d asset %s has no picture" % (n, ref))
    kind = "image" if path.lower().endswith(IMAGE_EXT) else "video"
    if kind == "video" and not path.lower().endswith(VIDEO_EXT):
        log("row %d asset %s has an unusual extension; treating it as video" % (n, ref))
    cache[path] = {"path": path, "kind": kind, "size": info["video"], "dur": info["duration"], "policy": policy}
    return cache[path]


def build_command(ffmpeg, args, seg, ctx):
    """Return (argv, expected_frames) for one segment."""
    frames = seg["frames"]
    dur = frames / float(FPS)
    start = seg["t0"]
    layout = seg["layout"]
    inputs = []
    graph = []
    count = [0]

    def add(opts):
        """Append one input; return its index."""
        inputs.extend(opts)
        count[0] += 1
        return count[0] - 1

    ss = ["-ss", "%.6f" % start]
    if layout == "AVATAR_FULL":
        v = add(ss + ["-i", args.avatar])
        a = add(ss + ["-i", args.avatar_raw])
        graph.append("[%d:v:0]fps=%d,setpts=PTS-STARTPTS,scale=%d:%d:force_original_aspect_ratio=increase,"
                     "crop=%d:%d,setsar=1,format=yuv420p[v]" % (v, FPS, CW, CH, CW, CH))
        graph.append(audio_chain("%d:a:0" % a, dur))
    else:
        asset = seg["asset"]
        if asset["kind"] == "image":
            ai = add(["-loop", "1", "-framerate", str(FPS), "-i", asset["path"]])
            hold = 0
        else:
            opts = []
            if asset["policy"] == "loop":
                opts += ["-stream_loop", "-1"]
            if seg["offset"] > 0:
                opts += ["-ss", "%.6f" % seg["offset"]]
            ai = add(opts + ["-i", asset["path"]])
            hold = dur if asset["policy"] == "hold" else 0
        zoom_on = seg["zoom"] == "slow-in"
        pi = add(ss + ["-i", args.avatar_raw])
        if layout == "FULLSCREEN_BROLL":
            graph += asset_chain("%d:v:0" % ai, "v", CW, CH, asset, zoom_on, frames, hold)
        elif layout == "PIP_CORNER":
            mi = add(["-loop", "1", "-framerate", str(FPS), "-i", ctx["mask"]])
            fi = add(["-loop", "1", "-framerate", str(FPS), "-i", ctx["frame"]])
            pw, ph = ctx["pip_w"], ctx["pip_h"]
            m = ctx["margin"]
            px = (CW - m - pw) if seg["side"] == "right" else m
            py = CH - m - ph
            graph += asset_chain("%d:v:0" % ai, "base", CW, CH, asset, zoom_on, frames, hold)
            graph += person_chain("%d:v:0" % pi, "card", pw, ph, args.key, ctx["card_bg"], True)
            graph.append("[%d:v]format=gray,fps=%d[mask]" % (mi, FPS))
            graph.append("[card][mask]alphamerge[pip]")
            graph.append("[base][pip]overlay=%d:%d:format=auto[wp]" % (px, py))
            graph.append("[wp][%d:v]overlay=%d:%d:format=auto,format=yuv420p[v]" % (fi, px - PAD, py - PAD))
        else:  # PIP_SIDE and SIDE_BY_SIDE: a picture beside the avatar column
            col_w = 640 if layout == "PIP_SIDE" else 960
            main_w = CW - col_w
            graph += asset_chain("%d:v:0" % ai, "main", main_w, CH, asset, zoom_on, frames, hold)
            graph += person_chain("%d:v:0" % pi, "col", col_w, CH, args.key, ctx["card_bg"], False)
            if seg["side"] == "left":
                graph.append("[col][main]hstack=inputs=2,format=yuv420p[v]")
            else:
                graph.append("[main][col]hstack=inputs=2,format=yuv420p[v]")
        graph.append(audio_chain("%d:a:0" % pi, dur))

    cmd = [ffmpeg, "-hide_banner", "-nostdin", "-v", "error", "-y"] + inputs
    cmd += ["-filter_complex", ";".join(graph), "-map", "[v]", "-map", "[a]",
            "-c:v", "libx264", "-preset", args.preset, "-crf", str(args.crf), "-g", str(FPS),
            "-pix_fmt", "yuv420p", "-r", str(FPS), "-frames:v", str(frames),
            "-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2",
            "-f", "mov", "-movflags", "+faststart", seg["out"] + ".part.mp4"]
    return cmd


def file_sig(path):
    st = os.stat(path)
    return "%s:%d:%d" % (os.path.basename(path), st.st_size, int(st.st_mtime))


def verify_segment(ffprobe, path, frames):
    info = probe(ffprobe, path)
    if not info["video"] or tuple(info["video"]) != (CW, CH):
        raise BuildError("%s is not %dx%d" % (os.path.basename(path), CW, CH))
    if not info["audio"]:
        raise BuildError("%s has no audio" % os.path.basename(path))
    want = frames / float(FPS)
    if info["duration"] is None or abs(info["duration"] - want) > 0.08:
        raise BuildError("%s is %.3fs long, expected %.3fs"
                         % (os.path.basename(path), info["duration"] or -1, want))


def main(argv):
    ap = argparse.ArgumentParser(description="Build one 1920x1080 segment per b-roll plan row.",
                                 epilog="Exit 0 ok, 1 build failure, 2 bad input.")
    ap.add_argument("--plan", required=True)
    ap.add_argument("--avatar", required=True, help="avatar on its background (1920x1080)")
    ap.add_argument("--avatar-raw", required=True, help="sealed avatar track; audio source")
    ap.add_argument("--key", default="", help="colorkey filter chain; empty = opaque avatar")
    ap.add_argument("--visuals", default="")
    ap.add_argument("--broll", default="")
    ap.add_argument("--out", required=True)
    ap.add_argument("--pip-card", default="rounded")
    ap.add_argument("--pip-size", default="304x380")
    ap.add_argument("--pip-margin", type=int, default=72)
    ap.add_argument("--pip-border", default="#D4A84C")
    ap.add_argument("--pip-radius", type=int, default=24)
    ap.add_argument("--pip-border-width", type=int, default=4)
    ap.add_argument("--card-bg", default="#0F172A", help="solid colour behind a keyed avatar")
    ap.add_argument("--no-pip", "--voice-only", dest="no_pip", action="store_true")
    ap.add_argument("--preset", default="fast")
    ap.add_argument("--crf", type=int, default=18)
    ap.add_argument("--timeout", type=int, default=1800, help="seconds allowed per segment")
    ap.add_argument("--no-resume", action="store_true", help="rebuild even if a segment is already done")
    ap.add_argument("--dry-run", action="store_true", help="check inputs and print the ffmpeg commands")
    args = ap.parse_args(argv)

    ffmpeg, ffprobe = find_tool("ffmpeg"), find_tool("ffprobe")
    if args.pip_card != "rounded":
        raise Usage("--pip-card %r is not supported; only 'rounded' is" % args.pip_card)
    pip_w, pip_h = parse_size(args.pip_size)
    if not (0 <= args.pip_margin <= 400):
        raise Usage("--pip-margin must be 0..400")
    if not (0 <= args.pip_radius <= 200 and 0 <= args.pip_border_width <= 20):
        raise Usage("--pip-radius must be 0..200 and --pip-border-width 0..20")
    border = parse_hex(args.pip_border, "--pip-border")
    card_bg = parse_hex(args.card_bg, "--card-bg")
    args.key = (args.key or "").strip().strip(",")
    if args.key and not KEY_RE.match(args.key):
        raise Usage("--key must be a chain of colorkey=0xRRGGBB:similarity:blend filters, got %r" % args.key)
    for label, p in (("--plan", args.plan), ("--avatar", args.avatar), ("--avatar-raw", args.avatar_raw)):
        if not os.path.isfile(p):
            raise Usage("%s file not found: %s" % (label, p))

    rows = load_plan(args.plan)
    av_info = probe(ffprobe, args.avatar)
    raw_info = probe(ffprobe, args.avatar_raw)
    if not av_info["video"]:
        raise Usage("--avatar has no picture: " + args.avatar)
    if not raw_info["audio"]:
        raise Usage("--avatar-raw has no audio stream (the narration): " + args.avatar_raw)
    edges = [snap(r["start"]) for r in rows] + [snap(rows[-1]["end"])]
    edges[0] = 0
    total = edges[-1] / float(FPS)
    if raw_info["duration"] is not None and total > raw_info["duration"] + 0.5:
        raise Usage("the plan runs to %.1fs but the avatar track is only %.1fs long"
                    % (total, raw_info["duration"]))
    if av_info["duration"] is not None and total > av_info["duration"] + 0.5:
        raise Usage("the plan runs to %.1fs but --avatar is only %.1fs long" % (total, av_info["duration"]))

    cache = {}
    offsets = {}
    pip_counter = 0
    segs = []
    for i, r in enumerate(rows):
        frames = edges[i + 1] - edges[i]
        if frames < 1:
            raise Usage("row %d is shorter than one frame (%.3fs)" % (r["n"], r["end"] - r["start"]))
        layout = r["layout"]
        asset = resolve_asset(r["asset"], r, args, ffprobe, cache) if layout != "AVATAR_FULL" else None
        if layout in PIP_LAYOUTS and args.no_pip:
            layout = "FULLSCREEN_BROLL" if asset else "AVATAR_FULL"
            if not asset:
                log("row %d: no picture to show and no presenter; using the avatar track" % r["n"])
        if layout != "AVATAR_FULL" and asset is None:
            raise Usage("row %d is %s but has no asset" % (r["n"], layout))
        side = r["pip_side"]
        if layout == "PIP_CORNER":
            if side is None:
                side = "right" if pip_counter % 2 == 0 else "left"
            pip_counter += 1
        elif layout in ("PIP_SIDE", "SIDE_BY_SIDE") and side is None:
            side = "right"
        zoom = r["zoom"]
        if zoom not in ("none", "slow-in"):
            log("row %d: zoom %r is not known; using none" % (r["n"], zoom))
            zoom = "none"
        offset = 0.0
        if asset and asset["kind"] == "video" and asset["policy"] == "loop" and asset["dur"]:
            cur = offsets.get(asset["path"], 0.0)
            offset = cur if cur + frames / float(FPS) <= asset["dur"] else 0.0
            offsets[asset["path"]] = offset + frames / float(FPS)
        name = "seg-%04d-%s.mp4" % (r["n"], layout.lower())
        segs.append({"n": r["n"], "frames": frames, "t0": edges[i] / float(FPS), "layout": layout,
                     "asset": asset, "ref": r["asset"], "side": side, "zoom": zoom, "offset": offset,
                     "name": name, "out": os.path.join(args.out, name)})

    ctx = {"pip_w": pip_w, "pip_h": pip_h, "margin": args.pip_margin, "card_bg": card_bg,
           "mask": None, "frame": None}
    needs_card = any(s["layout"] == "PIP_CORNER" for s in segs)
    if not args.dry_run:
        os.makedirs(args.out, exist_ok=True)
    if needs_card and not args.dry_run:
        br = tuple(int(border[k:k + 2], 16) for k in (0, 2, 4))
        ctx["mask"], ctx["frame"] = make_pip_assets(os.path.join(args.out, "_assets"), pip_w, pip_h,
                                                    args.pip_radius, args.pip_border_width, br)
    elif needs_card:
        ctx["mask"], ctx["frame"] = "_assets/pip-mask.png", "_assets/pip-frame.png"

    if args.dry_run:
        for s in segs:
            cmd = build_command(ffmpeg, args, s, ctx)
            sys.stdout.write("# row %d %s %d frames\n%s\n" % (s["n"], s["layout"], s["frames"],
                                                              " ".join(shlex.quote(c) for c in cmd)))
        sys.stdout.write("OK dry run: %d segments, %.1fs, nothing encoded\n" % (len(segs), total))
        return 0

    state_dir = os.path.join(args.out, "_state")
    os.makedirs(state_dir, exist_ok=True)
    keep = set(s["name"] for s in segs)
    removed = 0
    for f in os.listdir(args.out):
        if f.startswith("seg-") and f.endswith(".mp4") and f not in keep:
            os.remove(os.path.join(args.out, f))
            removed += 1
    if removed:
        log("removed %d stale segment file(s) from %s" % (removed, args.out))

    base_sig = "|".join([file_sig(args.avatar), file_sig(args.avatar_raw), args.key, str(pip_w), str(pip_h),
                         str(args.pip_margin), border, card_bg, str(args.pip_radius),
                         str(args.pip_border_width), args.preset, str(args.crf), "v1"])
    built = reused = 0
    for s in segs:
        sig = hashlib.sha1((base_sig + "|" + json.dumps(
            [s["n"], s["frames"], s["t0"], s["layout"], s["side"], s["zoom"], s["offset"],
             file_sig(s["asset"]["path"]) if s["asset"] else None], sort_keys=True)).encode()).hexdigest()
        stamp = os.path.join(state_dir, s["name"] + ".sha1")
        if (not args.no_resume and os.path.isfile(s["out"]) and os.path.isfile(stamp)
                and open(stamp).read().strip() == sig):
            try:
                verify_segment(ffprobe, s["out"], s["frames"])
                reused += 1
                continue
            except BuildError:
                pass
        if os.path.exists(stamp):
            os.remove(stamp)
        cmd = build_command(ffmpeg, args, s, ctx)
        r = run(cmd, timeout=args.timeout)
        part = s["out"] + ".part.mp4"
        if r.returncode != 0:
            if os.path.exists(part):
                os.remove(part)
            tail = "\n".join((r.stderr or "").strip().splitlines()[-12:])
            raise BuildError("row %d (%s) failed in ffmpeg:\n%s" % (s["n"], s["layout"], tail))
        os.replace(part, s["out"])
        verify_segment(ffprobe, s["out"], s["frames"])
        with open(stamp, "w") as fh:
            fh.write(sig + "\n")
        built += 1

    listing = [{"file": s["name"], "row": s["n"], "layout": s["layout"], "start": s["t0"],
                "frames": s["frames"], "seconds": s["frames"] / float(FPS), "asset": s["ref"],
                "pip_side": s["side"] if s["layout"] in ("PIP_CORNER", "PIP_SIDE", "SIDE_BY_SIDE") else None}
               for s in segs]
    with open(os.path.join(args.out, "segments.json"), "w") as fh:
        json.dump({"fps": FPS, "canvas": [CW, CH], "duration": total, "segments": listing}, fh, indent=1)
    print("OK %d segments (%d built, %d reused), %.2fs, %s" % (len(segs), built, reused, total, args.out))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Usage as e:
        log("input problem: %s" % e)
        sys.exit(2)
    except BuildError as e:
        log("build failed: %s" % e)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
