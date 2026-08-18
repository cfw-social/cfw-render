#!/usr/bin/env python3
"""eval_run.py — generic eval ENGINE for the skills pack.

Reads a per-recipe spec (acceptance.json), runs the declared checks, optionally
deep-merges a per-brand override, and writes a structured scorecard.json. The
engine is plumbing only — ALL thresholds live in the recipe's spec, so making
the engine generic does NOT relax any recipe's bar (see cfw-skills-pack/
docs/skills-audit.md §4). Exotic checks a recipe needs that aren't built in are
handled by the `custom` type (escape hatch → recipe-local script).

stdlib only (no PyYAML / no third-party). python3 + ffmpeg/ffprobe required.

Usage:
  eval_run.py <file> --recipe-dir DIR [--step NAME] [--spec PATH]
              [--brand SLUG] [--outdir DIR]

Verdict:
  PASS          — every HARD check passed, no perceptual check pending
  NEEDS_VISION  — HARD checks passed, perceptual checks still PENDING
  FAIL          — any HARD check failed (exit 1, blocks delivery)
Exit: 0 = no HARD fail, 1 = HARD fail, 2 = usage/IO error.
"""
import argparse, datetime, json, os, shutil, subprocess, sys

def die(msg, code=2):
    print(f"ERROR: {msg}", file=sys.stderr); sys.exit(code)

def sh(cmd):
    """Run a command, return (exit_code, stdout_bytes, stderr_text)."""
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return p.returncode, p.stdout, p.stderr.decode("utf-8", "replace")

# ── ffprobe/ffmpeg primitives ────────────────────────────────────────────────
def probe_dims(f):
    _, out, _ = sh(["ffprobe","-v","error","-select_streams","v:0",
        "-show_entries","stream=width,height","-of","csv=p=0",f])
    s = out.decode().strip().split(",")
    return (int(s[0]), int(s[1])) if len(s) >= 2 and s[0] else (None, None)

def probe_dur(f):
    _, out, _ = sh(["ffprobe","-v","error","-show_entries","format=duration",
        "-of","csv=p=0",f])
    try: return float(out.decode().strip())
    except ValueError: return None

def crop_luma(f, crop, t):
    """Mean luma 0-255 of a crop (W:H:X:Y) at time t — dependency-free."""
    rc, out, _ = sh(["ffmpeg","-v","error","-ss",str(t),"-i",f,
        "-vf",f"crop={crop},scale=1:1,format=gray","-frames:v","1",
        "-f","rawvideo","-"])
    return out[0] if rc == 0 and out else 0

def integrated_lufs(f):
    # NOTE: ebur128 prints its summary at info level — do NOT pass -v error here
    # or the "I: -14.0 LUFS" line is suppressed and the reading comes back empty.
    rc, _, err = sh(["ffmpeg","-hide_banner","-i",f,"-af","ebur128","-f","null","-"])
    val = None
    for line in err.splitlines():
        if "I:" in line and "LUFS" in line:
            try: val = float(line.split("I:")[1].split("LUFS")[0])
            except (IndexError, ValueError): pass
    return val

def mean_volume_db(f):
    # volumedetect also prints at info level — same caveat as ebur128 above.
    rc, _, err = sh(["ffmpeg","-hide_banner","-i",f,"-af","volumedetect","-f","null","-"])
    for line in err.splitlines():
        if "mean_volume" in line:
            try: return float(line.split(":")[1].strip().split()[0])
            except (IndexError, ValueError): pass
    return None

# ── check-type dispatch ──────────────────────────────────────────────────────
# Each returns (status, value, detail). status in PASS/FAIL/PENDING/SKIP.
def ck_qa_gate(f, c, ctx):
    gate = ctx["qa_gate"]
    if not gate:
        return "SKIP", "", "c-shorts-qa-gate not found"
    rc, _, _ = sh(["bash", gate, f, "--format", c.get("format","reel"),
                   "--outdir", os.path.join(ctx["outdir"], "qa")])
    return ("PASS","exit 0","all HARD checks") if rc == 0 else \
           ("FAIL","exit!=0", f"see {ctx['outdir']}/qa/qa-report.txt")

def ck_dims(f, c, ctx):
    w, h = probe_dims(f)
    return ("PASS", f"{w}x{h}", "") if (w, h) == (c["w"], c["h"]) else \
           ("FAIL", f"{w}x{h}", f"expected {c['w']}x{c['h']}")

def ck_duration_window(f, c, ctx):
    d = probe_dur(f)
    if d is None: return "FAIL", "?", "no duration"
    ok = c.get("min_s",0) <= d <= c.get("max_s",1e9)
    return ("PASS" if ok else "FAIL", f"{d:.2f}s",
            "" if ok else f"want {c.get('min_s')}–{c.get('max_s')}s")

def ck_luma_floor(f, c, ctx):
    floor = c.get("floor",16); crop = c["crop"]
    samples = c.get("samples",[0.05,0.2,0.4,0.6,0.8,0.95])
    d = probe_dur(f) or 0
    black = sum(1 for p in samples if crop_luma(f, crop, round(d*p,2)) < floor)
    return ("PASS", f"luma>={floor} all", "") if black == 0 else \
           ("FAIL", f"{black}/{len(samples)} below {floor}", "zone black/dark")

def ck_loudness(f, c, ctx):
    i = integrated_lufs(f); t, tol = c.get("target",-14), c.get("tol",1.5)
    if i is None: return "FAIL", "?", "no loudness reading"
    ok = (t-tol) <= i <= (t+tol)
    return ("PASS" if ok else "FAIL", f"{i} LUFS", "" if ok else f"want {t}±{tol}")

def ck_mean_volume(f, c, ctx):
    mv = mean_volume_db(f)
    if mv is None: return "FAIL", "?", "no mean_volume"
    ok = c.get("min_db",-90) <= mv <= c.get("max_db",0)
    return ("PASS" if ok else "FAIL", f"{mv} dB", "" if ok else "silence/clip")

def ck_custom(f, c, ctx):
    """Escape hatch — run a recipe-local check. exit 0 = PASS."""
    script = os.path.join(ctx["recipe_dir"], c["script"])
    if not os.path.isfile(script):
        return "FAIL", "", f"custom script missing: {c['script']}"
    rc, out, err = sh(["bash", script, f, *[str(a) for a in c.get("args",[])]])
    detail = (out.decode("utf-8","replace") + err).strip().splitlines()
    return ("PASS" if rc == 0 else "FAIL", f"exit {rc}",
            detail[-1] if detail else "")

def ck_perceptual(f, c, ctx):
    return "PENDING", "", c.get("desc", f"review frames in {ctx['outdir']}")

DISPATCH = {
    "qa_gate": ck_qa_gate, "dims": ck_dims, "duration_window": ck_duration_window,
    "luma_floor": ck_luma_floor, "loudness": ck_loudness,
    "mean_volume": ck_mean_volume, "custom": ck_custom, "perceptual": ck_perceptual,
}

# ── spec load + brand merge ──────────────────────────────────────────────────
def load_spec(path):
    if not os.path.isfile(path): die(f"spec not found: {path}")
    with open(path) as fh: return json.load(fh)

def merge_checks(base, override):
    """Override by id (brand wins); new ids appended."""
    by_id = {c["id"]: c for c in base}
    for o in override:
        by_id[o["id"]] = {**by_id.get(o["id"], {}), **o}
    return list(by_id.values())

def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("file")
    ap.add_argument("--recipe-dir", required=True)
    ap.add_argument("--step")
    ap.add_argument("--spec")
    ap.add_argument("--brand")
    ap.add_argument("--outdir")
    a = ap.parse_args()

    if not os.path.isfile(a.file): die(f"file not found: {a.file}")
    for bin_ in ("ffmpeg","ffprobe"):
        if not shutil.which(bin_): die(f"{bin_} required")

    spec = load_spec(a.spec or os.path.join(a.recipe_dir, "acceptance.json"))
    recipe = spec.get("recipe","?")
    outdir = a.outdir or os.path.join(os.path.dirname(os.path.abspath(a.file)), "eval")
    os.makedirs(outdir, exist_ok=True)

    # which checks: a named interim step, or the top-level final set
    if a.step:
        step = spec.get("steps",{}).get(a.step)
        if not step: die(f"no such step '{a.step}' in spec")
        checks = step["checks"]
    else:
        checks = spec.get("checks",[])

    # brand override (deep-merge by id) — recipe-relative
    if a.brand:
        ov = os.path.join(a.recipe_dir, "brand-overrides", a.brand, "acceptance.json")
        if os.path.isfile(ov):
            with open(ov) as fh: bspec = json.load(fh)
            key = "checks" if not a.step else None
            if key:
                checks = merge_checks(checks, bspec.get("checks",[]))

    # resolve the shared mechanical gate from the recipe's vendored closure
    gate = os.path.join(a.recipe_dir, ".hub", "c-shorts-qa-gate", "scripts", "qa-gate.sh")
    if not os.path.isfile(gate):
        found = subprocess.run(["bash","-c",
            'find "$HOME/.hermes/skills" "$HOME/.claude/skills" "$HOME/Code/skills" '
            '-type f -path "*c-shorts-qa-gate/scripts/qa-gate.sh" -print 2>/dev/null | head -1'],
            stdout=subprocess.PIPE).stdout.decode().strip()
        gate = found or None
    ctx = {"outdir": outdir, "recipe_dir": a.recipe_dir, "qa_gate": gate}

    rows, hard_fails = [], 0
    for c in checks:
        typ = c.get("type")
        fn = DISPATCH.get(typ)
        if not fn:
            rows.append({"kind":c.get("kind","?"),"id":c["id"],"status":"SKIP",
                         "value":"","detail":f"unknown check type '{typ}'"})
            continue
        status, value, detail = fn(a.file, c, ctx)
        is_hard = c.get("hard", typ != "perceptual")
        if status == "FAIL" and is_hard: hard_fails += 1
        rows.append({"kind":c.get("kind","?"),"id":c["id"],"status":status,
                     "value":value,"detail":detail})

    # perceptual evidence: dump a frame sweep when any perceptual check ran
    if any(r["status"] == "PENDING" for r in rows) and not a.step:
        d = probe_dur(a.file) or 0
        sh(["ffmpeg","-v","error","-i",a.file,"-frames:v","1",
            os.path.join(outdir,"frame0.png"),"-y"])
        for p in (5,20,40,60,80,95):
            sh(["ffmpeg","-v","error","-ss",f"{d*p/100:.2f}","-i",a.file,
                "-frames:v","1",os.path.join(outdir,f"frame_{p:02d}.png"),"-y"])

    pending = any(r["status"] == "PENDING" for r in rows)
    verdict = "FAIL" if hard_fails else ("NEEDS_VISION" if pending else "PASS")
    card = {
        "recipe": recipe, "spec": os.path.basename(a.spec or "acceptance.json"),
        "step": a.step or "final", "brand": a.brand,
        "file": os.path.abspath(a.file),
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "verdict": verdict, "hard_fails": hard_fails, "criteria": rows,
    }
    out_path = os.path.join(outdir, "scorecard.json")
    with open(out_path,"w") as fh: json.dump(card, fh, indent=2)
    print(json.dumps(card, indent=2))
    print(f"\nscorecard → {out_path}")
    if hard_fails:
        print(f"VERDICT: FAIL ({hard_fails} hard) — do NOT deliver."); sys.exit(1)
    print(f"VERDICT: {verdict}")
    sys.exit(0)

if __name__ == "__main__":
    main()
