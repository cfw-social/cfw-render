#!/usr/bin/env python3
"""
wowx-motions — apply a cinematic camera MOTION to a B-roll clip with one command.

A unified motion library an AI agent can fire on arbitrary footage. Two render backends,
both pure FFmpeg (no browser / GPU / 3D pipeline), all deterministic, audio preserved:

  ZOOM backend  (animated scale+crop, sub-pixel smooth — not juddery zoompan):
      push-in   focus/Ken-Burns punch toward the subject        (alias: focus)
      pull-out  slow zoom-out reveal
      pan-left  pan-right  pan-up  pan-down   zoomed directional pan
      ken-burns diagonal zoom + drift (the classic)

  WARP backend  (in-frame perspective corner-pin, gap-free via a base inset):
      tilt-back     plane leans away at the top   (pseudo-3D)
      tilt-forward  plane leans toward you at the top
      orbit         gentle Y-axis rocking "orbit" of a flat plane
      sway          slow idle float — keeps a near-static shot alive

  STAGE backend (the TiltIt look — footage as a rounded, shadowed 3D CARD on a background;
                 green screen by default or transparent; a virtual camera moves around it):
      card-orbit    card floats on bg, rocks around the vertical axis + parallax
      card-swoop    card starts tilted+small, dollies in to flatter+bigger
      card-focus    clean cinematic push-in toward the floating card
      card-glide    card slides across the frame with a constant tilt

Honest scope: WARP/STAGE motions are 2D perspective approximations of 3D moves — convincing on
flat B-roll, but NOT a true volumetric orbit/tilt with depth + reflections. That requires the
Wowx 3D engine (R3F/WebGL) and is the roadmap path; see the SKILL.md "Roadmap" section.

Usage:
  python3 wowx_motion.py INPUT --motion push-in [OUTPUT] [options]
  python3 wowx_motion.py --list
"""
import argparse, json, math, os, subprocess, sys

PI = math.pi

# ----------------------------------------------------------------------------- probe
def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height,avg_frame_rate,nb_frames",
         "-show_entries", "format=duration", "-of", "json", path],
        capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"[wowx-motions] ffprobe failed:\n{out.stderr.strip()}")
    d = json.loads(out.stdout)
    st = d["streams"][0]
    W, H = int(st["width"]), int(st["height"])
    dur = float(d["format"]["duration"])
    # fps from avg_frame_rate "30000/1001"
    fr = st.get("avg_frame_rate", "30/1")
    try:
        num, den = fr.split("/"); fps = float(num) / float(den) if float(den) else 30.0
    except Exception:
        fps = 30.0
    nb = st.get("nb_frames")
    N = int(nb) if (nb and nb.isdigit()) else max(1, round(dur * fps))
    return W, H, dur, fps, N


# ------------------------------------------------------------------ shared exprs
def _p_time(dur):                       # progress 0..1 by time (zoom backend)
    return f"min(t/{dur:.6f},1)"

def _ss(p):                             # smoothstep ease-in-out
    return f"(({p})*({p})*(3-2*({p})))"

def _p_frame(N):                        # progress 0..1 by output frame (warp backend)
    return f"min(on/{max(N-1,1)},1)"


# ------------------------------------------------------------------ ZOOM backend
def _zoom_pushpan(W, H, dur, amount, z_in, drift_x, drift_y, pan):
    """Generic scale+crop move. z_in: True=zoom in, False=out, None=constant (pans)."""
    p = _p_time(dur); ss = _ss(p)
    if z_in is True:
        z = f"(1+{amount}*{ss})"
    elif z_in is False:
        z = f"(1+{amount}*(1-{ss}))"
    else:                                # constant zoom for pure pans
        z = f"(1+{amount})"
    sw = f"2*round(iw*{z}/2)"; sh = f"2*round(ih*{z}/2)"
    scale = f"scale=w='{sw}':h='{sh}':eval=frame:flags=lanczos"
    # focal point: pan presets sweep the crop; drifts add a subtle turn
    if pan == "left":   px, py = f"(1-{ss})", "0.5"
    elif pan == "right":px, py = f"({ss})",   "0.5"
    elif pan == "up":   px, py = "0.5", f"(1-{ss})"
    elif pan == "down": px, py = "0.5", f"({ss})"
    else:               px, py = f"(0.5+{drift_x}*(2*{p}-1))", f"(0.5+{drift_y}*(2*{p}-1))"
    crop = f"crop=w={W}:h={H}:x='(in_w-{W})*{px}':y='(in_h-{H})*{py}'"
    return f"{scale},{crop},setsar=1"


# ------------------------------------------------------------------ WARP backend
def _persp(W, H, c):
    """c = dict of 8 corner expressions (x0..y3). Adds a normalising scale."""
    return ("perspective="
            f"x0='{c['x0']}':y0='{c['y0']}':x1='{c['x1']}':y1='{c['y1']}':"
            f"x2='{c['x2']}':y2='{c['y2']}':x3='{c['x3']}':y3='{c['y3']}':"
            "interpolation=cubic:eval=frame"
            f",scale={W}:{H},setsar=1")

def _warp(W, H, N, motion, intensity):
    p = _p_frame(N); e = _ss(p)                  # eased 0..1
    bw, bh = 0.07 * W, 0.07 * H                  # base inset → room to warp w/o black gaps
    I = max(0.0, min(intensity, 1.5))
    # baseline = uniform inset (a slight zoom-in); motions push corners from here
    L, R, T, B = bw, W - bw, bh, H - bh
    if motion in ("tilt-back", "tilt-forward"):
        aw, ah = 0.10 * W * I, 0.06 * H * I
        if motion == "tilt-back":                # top edge recedes (in + down)
            c = dict(x0=f"{L}+{aw}*{e}", y0=f"{T}+{ah}*{e}",
                     x1=f"{R}-{aw}*{e}", y1=f"{T}+{ah}*{e}",
                     x2=f"{L}", y2=f"{B}", x3=f"{R}", y3=f"{B}")
        else:                                    # bottom edge recedes (in + up)
            c = dict(x0=f"{L}", y0=f"{T}", x1=f"{R}", y1=f"{T}",
                     x2=f"{L}+{aw}*{e}", y2=f"{B}-{ah}*{e}",
                     x3=f"{R}-{aw}*{e}", y3=f"{B}-{ah}*{e}")
    elif motion == "orbit":
        s = f"sin({p}*2*{PI:.6f})"               # there-and-back-and-back → orbit rock
        av, ah = 0.05 * H * I, 0.05 * W * I
        c = dict(
            x0=f"{L}+{ah}*{s}", y0=f"{T}-{av}*{s}",     # left edge taller as it swings
            x1=f"{R}+{ah}*{s}", y1=f"{T}+{av}*{s}",     # right edge shorter
            x2=f"{L}+{ah}*{s}", y2=f"{B}+{av}*{s}",
            x3=f"{R}+{ah}*{s}", y3=f"{B}-{av}*{s}")
    elif motion == "sway":
        s1 = f"sin({p}*2*{PI:.6f})"; s2 = f"sin({p}*2*{PI:.6f}+{PI/2:.6f})"
        ah, av = 0.035 * W * I, 0.035 * H * I    # gentle idle float
        c = dict(
            x0=f"{L}+{ah}*{s1}", y0=f"{T}+{av}*{s2}",
            x1=f"{R}+{ah}*{s1}", y1=f"{T}+{av}*{s2}",
            x2=f"{L}+{ah}*{s1}", y2=f"{B}+{av}*{s2}",
            x3=f"{R}+{ah}*{s1}", y3=f"{B}+{av}*{s2}")
    else:
        sys.exit(f"[wowx-motions] unknown warp motion: {motion}")
    return _persp(W, H, c)


# ------------------------------------------------------------------ STAGE backend
# Floats the footage as a 3D "card" on a background canvas (green screen by default) and
# moves a virtual camera around it — the TiltIt look. Built from an alpha-preserving
# animated `perspective` (sense=destination, driven by `on`) composited over a color source.
def _even(n): return int(round(n / 2.0)) * 2

def _stage_graph(srcW, srcH, dur, fps, N, motion, intensity, canvas, card_scale, bg,
                 corner_radius, shadow):
    CW, CH = canvas
    I = max(0.0, min(intensity, 1.5))
    aspect = srcW / float(srcH)
    cardH = _even(card_scale * CH)
    cardW = _even(cardH * aspect)
    if cardW > 0.94 * CW:                       # clamp very-wide cards by width
        cardW = _even(0.94 * CW); cardH = _even(cardW / aspect)
    padx, pady = (CW - cardW) // 2, (CH - cardH) // 2
    cx, cy = CW / 2.0, CH / 2.0

    p  = f"(on/{max(N-1,1)})"
    ss = f"({p}*{p}*(3-2*{p}))"                  # smoothstep
    IX = [0, CW, 0, CW]; IY = [0, 0, CH, CH]     # TL, TR, BL, BR (identity = centered card)
    dx = ["0", "0", "0", "0"]; dy = ["0", "0", "0", "0"]
    sgn = [1, -1, -1, 1]                          # per-corner sign for a Y-axis tilt

    if motion == "card-orbit":                   # Y-axis rock + horizontal parallax
        s = f"sin({p}*{2*PI*0.75:.6f})"          # ~0.75 cycles over the clip = slow single sweep
        ah, av = 0.07 * CW * I, 0.085 * CH * I
        dx = [f"{ah:.2f}*{s}"] * 4
        dy = [f"-{av:.2f}*{s}", f"{av:.2f}*{s}", f"{av:.2f}*{s}", f"-{av:.2f}*{s}"]
    elif motion == "card-swoop":                 # start tilted+small, dolly in to flatter+bigger
        grow = f"({0.26*I:.4f}*{ss})"            # scale-1 about centre
        tlt = f"({0.09*CH*I:.2f}*(1-{ss}))"      # tilt that flattens out
        arc = f"(-{0.05*CH*I:.2f}*sin({p}*{PI:.6f}))"
        for i in range(4):
            dx[i] = f"({IX[i]-cx:.1f})*{grow}"
            dy[i] = f"({IY[i]-cy:.1f})*{grow}+({sgn[i]})*{tlt}+{arc}"
    elif motion == "card-focus":                 # clean cinematic push-in toward the card
        grow = f"({0.17*I:.4f}*{ss})"            # gentle dolly-in
        tlt = 0.018 * CH * I                      # a hair of constant tilt for depth
        for i in range(4):
            dx[i] = f"({IX[i]-cx:.1f})*{grow}"
            dy[i] = f"({IY[i]-cy:.1f})*{grow}+({sgn[i]})*{tlt:.2f}"
    elif motion == "card-glide":                 # translate across + constant slight tilt
        tx = f"({0.15*CW*I:.2f})*(2*{p}-1)"
        tlt = 0.035 * CH * I
        dx = [tx] * 4
        dy = [f"{tlt:.2f}", f"-{tlt:.2f}", f"-{tlt:.2f}", f"{tlt:.2f}"]
    else:
        sys.exit(f"[wowx-motions] unknown stage motion: {motion}")

    persp = ("perspective="
             + ":".join(f"x{i}='{IX[i]}+({dx[i]})':y{i}='{IY[i]}+({dy[i]})'" for i in range(4))
             + ":sense=destination:eval=frame:interpolation=cubic")

    # rounded corners: carve the card's alpha with a rounded-rectangle mask (1px AA)
    R = int(round(corner_radius * min(cardW, cardH)))
    if R > 0:
        a = (f"255*clip(({R}-sqrt(pow(max(abs(X-W/2)-(W/2-{R})\\,0)\\,2)"
             f"+pow(max(abs(Y-H/2)-(H/2-{R})\\,0)\\,2)))+0.5\\,0\\,1)")
        rounded = f"format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='{a}'"
    else:
        rounded = "format=rgba"

    card_core = (f"[0:v]scale={cardW}:{cardH},{rounded},"
                 f"pad={CW}:{CH}:{padx}:{pady}:color=0x00000000,{persp}")

    transparent = (bg == "transparent")
    bgcolor = "0x00000000" if transparent else bg
    base = f"color=c={bgcolor}:s={CW}x{CH}:r={fps:.4f}:d={dur:.3f},format=rgba[bg]"

    if shadow:
        sx, sy = int(round(0.006 * CW)), int(round(0.018 * CH))
        sig = 0.018 * CH
        card = f"{card_core},split[cs][cf]"
        sh = f"[cs]colorchannelmixer=rr=0:gg=0:bb=0:aa=0.5,gblur=sigma={sig:.1f}[sh]"
        comp = (f"[bg][sh]overlay={sx}:{sy}:format=auto[b2];"
                f"[b2][cf]overlay=0:0:format=auto:shortest=1[out]")
        graph = f"{base};{card};{sh};{comp}"
    else:
        graph = f"{base};{card_core}[cf];[bg][cf]overlay=0:0:format=auto:shortest=1[out]"
    return graph, "[out]", transparent


def run_stage(args, srcW, srcH, dur, fps, N):
    canvas = tuple(int(x) for x in args.canvas.lower().split("x"))
    bg = "transparent" if args.background.lower() in ("transparent", "none", "alpha") \
        else args.background
    graph, omap, transparent = _stage_graph(srcW, srcH, dur, fps, N, args.motion,
                                             args.intensity, canvas, args.card_scale, bg,
                                             args.corner_radius, args.shadow)
    if args.print_filter:
        print(graph); return

    base, ext = os.path.splitext(args.input)
    if transparent and ext.lower() not in (".mov", ".webm"):
        ext = ".mov"                              # alpha needs a capable container
    output = args.output or f"{base}.{args.motion}{ext or '.mp4'}"

    cmd = ["ffmpeg", "-y", "-i", args.input, "-filter_complex", graph,
           "-map", omap, "-map", "0:a?"]
    if transparent and output.lower().endswith(".mov"):
        cmd += ["-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le"]
    elif transparent:
        cmd += ["-c:v", "libvpx-vp9", "-pix_fmt", "yuva420p", "-b:v", "0", "-crf", "24"]
    else:
        cmd += ["-c:v", "libx264", "-crf", str(args.crf), "-preset", args.preset,
                "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
    cmd += ["-c:a", "copy", output]
    print(f"[wowx-motions] {args.motion} (stage)  card {srcW}x{srcH} on {canvas[0]}x{canvas[1]} "
          f"bg={bg} -> {output}")
    if subprocess.run(cmd).returncode != 0:
        sys.exit("[wowx-motions] ffmpeg render failed (see output above).")
    print(f"[wowx-motions] done -> {output}")


STAGE = {"card-orbit", "card-swoop", "card-focus", "card-glide"}


# ------------------------------------------------------------------ registry
ZOOM = {
    "push-in":  dict(z_in=True,  amount=0.18, drift_x=0.06, drift_y=0.0),
    "focus":    dict(z_in=True,  amount=0.18, drift_x=0.06, drift_y=0.0),   # alias
    "pull-out": dict(z_in=False, amount=0.18, drift_x=0.0,  drift_y=0.0),
    "ken-burns":dict(z_in=True,  amount=0.20, drift_x=0.10, drift_y=0.08),
    "pan-left": dict(z_in=None,  amount=0.14, pan="left"),
    "pan-right":dict(z_in=None,  amount=0.14, pan="right"),
    "pan-up":   dict(z_in=None,  amount=0.14, pan="up"),
    "pan-down": dict(z_in=None,  amount=0.14, pan="down"),
}
WARP = {"tilt-back", "tilt-forward", "orbit", "sway"}
ALL_MOTIONS = list(ZOOM.keys()) + sorted(WARP)


def build_filter(W, H, dur, N, motion, amount, intensity, drift_x, drift_y):
    if motion in ZOOM:
        cfg = dict(ZOOM[motion])
        amt = amount if amount is not None else cfg.get("amount", 0.18)
        return _zoom_pushpan(W, H, dur, amt,
                             cfg.get("z_in", True),
                             drift_x if drift_x is not None else cfg.get("drift_x", 0.0),
                             drift_y if drift_y is not None else cfg.get("drift_y", 0.0),
                             cfg.get("pan"))
    if motion in WARP:
        return _warp(W, H, N, motion, intensity)
    sys.exit(f"[wowx-motions] unknown motion '{motion}'. Try --list.")


# ------------------------------------------------------------------ cli
def main():
    ap = argparse.ArgumentParser(description="Apply a cinematic camera motion to B-roll.")
    ap.add_argument("input", nargs="?")
    ap.add_argument("output", nargs="?", default=None)
    ap.add_argument("--motion", "-m", default="push-in", help="motion name (see --list)")
    ap.add_argument("--amount", type=float, default=None,
                    help="ZOOM motions: travel fraction (e.g. 0.18). Overrides preset.")
    ap.add_argument("--intensity", type=float, default=1.0,
                    help="WARP/STAGE motions: strength 0..1.5 (default 1.0).")
    ap.add_argument("--drift-x", type=float, default=None, help="ZOOM: horizontal focal sweep.")
    ap.add_argument("--drift-y", type=float, default=None, help="ZOOM: vertical focal sweep.")
    ap.add_argument("--background", "--bg", default="0x00FF00",
                    help="STAGE motions: canvas bg — hex (e.g. 0x00FF00 green screen) or "
                         "'transparent' (exports .mov ProRes4444). Default green screen.")
    ap.add_argument("--canvas", default="1920x1080",
                    help="STAGE motions: output canvas WxH (default 1920x1080).")
    ap.add_argument("--card-scale", type=float, default=0.76,
                    help="STAGE motions: card size as fraction of canvas height (default 0.76).")
    ap.add_argument("--corner-radius", type=float, default=0.05,
                    help="STAGE motions: rounded-corner radius as fraction of card's short "
                         "side (default 0.05; 0 = sharp corners).")
    ap.add_argument("--shadow", dest="shadow", action="store_true", default=True,
                    help="STAGE motions: drop shadow behind the card (on by default).")
    ap.add_argument("--no-shadow", dest="shadow", action="store_false",
                    help="STAGE motions: disable the drop shadow.")
    ap.add_argument("--crf", type=int, default=18)
    ap.add_argument("--preset", default="medium")
    ap.add_argument("--print-filter", action="store_true", help="print filtergraph, no render")
    ap.add_argument("--list", action="store_true", help="list available motions and exit")
    args = ap.parse_args()

    if args.list:
        print("ZOOM  (in-frame 2D):   " + ", ".join(k for k in ZOOM if k != "focus")
              + "   [focus = alias of push-in]")
        print("WARP  (in-frame 3D-ish):" + ", ".join(sorted(WARP)))
        print("STAGE (card on bg, the TiltIt look): card-orbit, card-swoop, card-focus, card-glide")
        return
    if not args.input:
        ap.error("INPUT is required (or use --list)")
    if not os.path.isfile(args.input):
        sys.exit(f"[wowx-motions] input not found: {args.input}")
    if args.motion not in ZOOM and args.motion not in WARP and args.motion not in STAGE:
        sys.exit(f"[wowx-motions] unknown motion '{args.motion}'. Run --list.")

    W, H, dur, fps, N = probe(args.input)

    if args.motion in STAGE:                      # card-on-background (TiltIt-style) path
        run_stage(args, W, H, dur, fps, N)
        return

    vf = build_filter(W, H, dur, N, args.motion, args.amount, args.intensity,
                      args.drift_x, args.drift_y)
    if args.print_filter:
        print(vf); return

    base, ext = os.path.splitext(args.input)
    output = args.output or f"{base}.{args.motion}{ext or '.mp4'}"
    cmd = ["ffmpeg", "-y", "-i", args.input, "-vf", vf,
           "-c:v", "libx264", "-crf", str(args.crf), "-preset", args.preset,
           "-pix_fmt", "yuv420p", "-c:a", "copy", "-movflags", "+faststart", output]
    backend = "zoom" if args.motion in ZOOM else "warp"
    print(f"[wowx-motions] {args.motion} ({backend})  {W}x{H} {dur:.2f}s {fps:.1f}fps -> {output}")
    if subprocess.run(cmd).returncode != 0:
        sys.exit("[wowx-motions] ffmpeg render failed (see output above).")
    print(f"[wowx-motions] done -> {output}")


if __name__ == "__main__":
    main()
