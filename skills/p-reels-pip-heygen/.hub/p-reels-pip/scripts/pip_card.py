#!/usr/bin/env python3
"""Build the PIP card's rounded mask and its ring + shadow frame (p-reels-pip, WI31.10).

Standard library only (a zlib + struct PNG writer), so the card never depends on
Pillow. There is no square-card path: any failure exits 1 with one line that
names what failed, and the step stops.

  pip_card.py --card 364x504 --radius 40 --ring 8 --shadow 22 --accent F97316 \
              --mask work/pip-mask.png --frame work/pip-frame.png

mask   WxH RGBA. Opaque white inside a rounded rectangle, transparent black
       outside. ffmpeg `alphamerge` reads its luma as the talking head's alpha.
frame  (W+2P)x(H+2P) RGBA, P = ring + shadow. A soft black drop shadow (alpha
       150, 6 px down, Gaussian sigma max(1, int(shadow * 0.6))) under a rounded
       rectangle of radius + ring filled with the accent. The masked head covers
       its middle, so `ring` px of accent show around the card. Written only when
       ring > 0; with ring 0 no frame is written (and --frame may be omitted).
"""
import argparse
import math
import os
import re
import struct
import sys
import zlib

SHADOW_ALPHA = 150
SHADOW_DROP = 6


def write_png(path, width, height, rows):
    """Write 8-bit RGBA rows (bytes of width*4 each) as a PNG; atomic replace."""
    if len(rows) != height or any(len(r) != width * 4 for r in rows):
        raise ValueError("row data does not match %dx%d" % (width, height))
    raw = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(png)
    os.replace(tmp, path)
    if os.path.getsize(path) <= 0:
        raise OSError("%s is empty after writing" % path)


def rounded_rect_distance(px, py, x0, y0, x1, y1, r):
    """Signed distance from (px, py) to the rounded rectangle [x0,x1] x [y0,y1]
    with corner radius r, in continuous pixel coordinates. Negative = inside."""
    qx = abs(px - (x0 + x1) / 2.0) - ((x1 - x0) / 2.0 - r)
    qy = abs(py - (y0 + y1) / 2.0) - ((y1 - y0) / 2.0 - r)
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r


def coverage(d):
    """Anti-aliased coverage of a pixel whose centre is at signed distance d."""
    return min(1.0, max(0.0, 0.5 - d))


def build_mask(cw, ch, radius):
    rows = []
    for y in range(ch):
        row = bytearray(cw * 4)
        cy = y + 0.5
        for x in range(cw):
            a = int(round(255 * coverage(rounded_rect_distance(x + 0.5, cy, 0, 0, cw, ch, radius))))
            if a:
                i = x * 4
                row[i] = row[i + 1] = row[i + 2] = 255
                row[i + 3] = a
        rows.append(row)
    return rows


def build_frame(cw, ch, radius, ring, shadow, accent):
    pad = ring + shadow
    fw, fh = cw + 2 * pad, ch + 2 * pad
    rr = radius + ring
    # Ring rectangle: the card grown by `ring` on every side (concentric corners).
    x0, y0, x1, y1 = pad - ring, pad - ring, fw - (pad - ring), fh - (pad - ring)
    sigma = max(1, int(shadow * 0.6))
    inv = 1.0 / (sigma * math.sqrt(2.0))
    ar, ag, ab = accent
    rows = []
    for y in range(fh):
        row = bytearray(fw * 4)
        cy = y + 0.5
        for x in range(fw):
            cx = x + 0.5
            c = coverage(rounded_rect_distance(cx, cy, x0, y0, x1, y1, rr))
            sa = 0.0
            if shadow > 0 and c < 1.0:
                ds = rounded_rect_distance(cx, cy, x0, y0 + SHADOW_DROP, x1, y1 + SHADOW_DROP, rr)
                sa = (SHADOW_ALPHA / 255.0) * 0.5 * math.erfc(ds * inv)
            out_a = c + sa * (1.0 - c)  # accent ring "over" a black shadow
            if out_a <= 0.0:
                continue
            k = c / out_a
            i = x * 4
            row[i] = int(round(ar * k))
            row[i + 1] = int(round(ag * k))
            row[i + 2] = int(round(ab * k))
            row[i + 3] = int(round(255 * out_a))
        rows.append(row)
    return fw, fh, rows


def parse_args(argv):
    p = argparse.ArgumentParser(description="PIP card mask + ring/shadow frame (stdlib only).")
    p.add_argument("--card", required=True, help="card size WxH, e.g. 364x504")
    p.add_argument("--radius", type=int, default=40)
    p.add_argument("--ring", type=int, default=8)
    p.add_argument("--shadow", type=int, default=22)
    p.add_argument("--accent", required=True, help="brand accent, 6-digit hex (leading # optional)")
    p.add_argument("--mask", required=True, help="output path of the rounded mask PNG")
    p.add_argument("--frame", default="", help="output path of the ring + shadow PNG (needed when --ring > 0)")
    return p.parse_args(argv)


def fail(msg):
    sys.stderr.write("pip_card.py: FAILED - %s\n" % msg)
    return 1


def main(argv=None):
    a = parse_args(sys.argv[1:] if argv is None else argv)
    m = re.fullmatch(r"(\d+)x(\d+)", a.card.strip())
    if not m:
        return fail("--card %r is not WxH" % a.card)
    cw, ch = int(m.group(1)), int(m.group(2))
    if cw <= 0 or ch <= 0:
        return fail("--card %r must be positive" % a.card)
    if a.radius < 0 or 2 * a.radius > min(cw, ch):
        return fail("--radius %d does not fit a %dx%d card" % (a.radius, cw, ch))
    if a.ring < 0 or a.shadow < 0:
        return fail("--ring and --shadow must be >= 0 (got %d, %d)" % (a.ring, a.shadow))
    hexv = a.accent.strip().lstrip("#")
    if not re.fullmatch(r"[0-9A-Fa-f]{6}", hexv):
        return fail("brand accent %r is not a 6-digit hex colour" % a.accent)
    accent = tuple(int(hexv[i:i + 2], 16) for i in (0, 2, 4))
    if a.ring > 0 and not a.frame:
        return fail("--ring %d needs --frame PATH for the ring + shadow PNG" % a.ring)

    try:
        write_png(a.mask, cw, ch, build_mask(cw, ch, a.radius))
    except Exception as e:  # name the file that failed, then stop
        return fail("rounded mask %s: %s: %s" % (a.mask, type(e).__name__, e))
    if a.ring > 0:
        try:
            fw, fh, rows = build_frame(cw, ch, a.radius, a.ring, a.shadow, accent)
            write_png(a.frame, fw, fh, rows)
        except Exception as e:
            return fail("ring + shadow frame %s: %s: %s" % (a.frame, type(e).__name__, e))
        print("[pip] card %dx%d r%d: mask %s; ring %d px #%s + shadow %d px: frame %s (%dx%d)"
              % (cw, ch, a.radius, a.mask, a.ring, hexv.upper(), a.shadow, a.frame, fw, fh))
    else:
        print("[pip] card %dx%d r%d: mask %s; ring off (pip_ring 0), no frame"
              % (cw, ch, a.radius, a.mask))
    return 0


if __name__ == "__main__":
    sys.exit(main())
