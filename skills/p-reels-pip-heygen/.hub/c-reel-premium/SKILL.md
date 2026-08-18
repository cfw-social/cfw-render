---
name: c-reel-premium
description: Premium polish pass for any assembled 9:16 reel — word-synced kinetic captions with accent-keyword pops, SFX (whoosh/impact/riser) at planned cues, and a cinematic grade. Runs AFTER a reel is assembled, regardless of how it was built (ffmpeg, HyperFrames, or Remotion), because the input is just the finished MP4 + a word transcript. Extracted from p-reels-fmt3 v0.5 so every p-reels-* format gets the same premium layer.
kind: component
visibility: internal
version: 1.0.0
dependsOn: [f-hyperframes, f-hyperframes-cli, c-ffmpeg]
requires: ffmpeg, node, chromium
---


# c-reel-premium — captions + SFX + grade polish pass

Takes an **already-assembled reel** (final audio mastered by the calling recipe) and returns the
same reel with the premium layer on top:

1. **Kinetic captions** — word-synced karaoke groups, ONE emphasis word per line popping in the
   brand accent with glow + scale, entrance styles cycling per group.
2. **SFX** — whoosh/impact/riser/click cues mixed UNDER the existing audio with
   `amix=normalize=0` (the recipe's mastering is never re-touched — no loudnorm here).
3. **Grade** — one `warm-amber` or `clean-bright` ffmpeg pass + light sharpen.

The pass renders the caption overlay as a HyperFrames composition with the reel as a muted video
layer, then muxes the original audio + SFX and grades in ONE ffmpeg pass.

## Inputs (set by the calling recipe)

| Var | Required | Default | Notes |
|---|---|---|---|
| `REEL_IN` | Yes | — | The assembled reel (1080×1920 H.264 + final AAC audio). |
| `REEL_OUT` | Yes | — | Output path. |
| `WORDS_JSON` | Yes | — | Word-level transcript `[{text,start,end}]`. Recipes usually have this already; if not: `npx hyperframes@0.7.5 transcribe "$REEL_IN" --model small` (NO `.en` unless confirmed English) + the quality check from `f-hyperframes/references/transcript-guide.md`. |
| `CAP_TOP` | No | `1180` | Caption band top edge (px). **Use `1020` when the format has a bottom PIP** (fmt1/fmt2/fmt5 siblings) so the band clears the card. The standard bottom PIP is the **framed-inset** (rounded-rect, gold `#D4A84C` border + soft shadow — see `c-ffmpeg/references/landscape-pip.md` "Framed-Inset PIP"); on landscape VSL it alternates bottom L↔R, so keep captions clear of **both** bottom corners, not just the right. Never let a caption cover the framed card or its gold rim. |
| `CAPTIONS` | No | `on` | `off` → skip the overlay render entirely (SFX+grade still run). |
| `SFX` | No | `on` | `off` → no cues mixed. |
| `GRADE` | No | planner picks | `warm-amber` \| `clean-bright` \| `off`. |
| brand | Yes | — | `{accent, fg}` 6-digit hexes via the Visual Identity Gate. Never hard-code. |

```bash
PREMIUM_DIR=$(find "$HOME/.claude/skills" "$HOME/.hermes/skills" -maxdepth 4 -type d -name c-reel-premium 2>/dev/null | head -1)
[ -n "$PREMIUM_DIR" ] || PREMIUM_DIR="$SKILL_DIR/.hub/c-reel-premium"   # pack form
PW="$W/premium" ; mkdir -p "$PW"
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$REEL_IN")
```

## Step P1 — Plan captions + SFX + grade with OPUS (kimi fallback)

Plan-on-Opus, execute-on-kimi (see `p-reels-fmt3` Step 4 for the architecture note). One curated
JSON; the executor never authors anything:

```bash
PLAN_PROMPT="You are planning the PREMIUM POLISH layer for an assembled 9:16 reel (captions + SFX + grade — the picture is already edited; do NOT plan any takeovers or cuts).
Output STRICT JSON ONLY (one object, no prose).
Word transcript: $(cat "$WORDS_JSON")
Total duration: $DUR seconds.
Brand: <from brief via Visual Identity Gate; default accent #F97316, fg #F1F5F9>.
Schema:
{ \"grade\": \"warm-amber|clean-bright\",
  \"brand\": {\"accent\":\"#hex6\",\"fg\":\"#hex6\"},
  \"caption_groups\": [ {\"start\":s,\"end\":s,\"style\":0|1|2,
        \"words\":[{\"w\":\"TEXT\",\"s\":start,\"e\":end,\"em\":false}] } ],
  \"sfx\": [ {\"t\":s,\"name\":\"whoosh-deep|whoosh-air|impact-sub|impact-punch|riser|click|pop|swipe\",\"gain\":0.0-0.6} ] }
RULES:
1. caption_groups cover the FULL duration, 2-4 words each, non-overlapping, break on sentence
   boundaries or pauses >=150ms. Words VERBATIM from the transcript.
2. LATIN SCRIPT ONLY: transliterate any non-Latin script word phonetically. NEVER translate —
   Hinglish stays Hinglish.
3. At most ONE word per group gets \"em\":true. Some groups have none.
4. \"style\" cycles 0/1/2 — never the same style on adjacent groups.
5. sfx: 4-10 cues total — whoosh at the strongest sentence boundaries, impact-sub on the 2-3
   biggest emphasis words, click/pop sparingly. gain <=0.6. None in the first 1s."

PLAN_JSON=$(env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
  -u ANTHROPIC_DEFAULT_OPUS_MODEL -u ANTHROPIC_DEFAULT_SONNET_MODEL -u ANTHROPIC_DEFAULT_HAIKU_MODEL \
  -u CLAUDE_CODE_SUBAGENT_MODEL \
  timeout 240 claude --print "$PLAN_PROMPT" --dangerously-skip-permissions 2>/dev/null \
  | python3 -c "import sys,re; m=re.search(r'\{.*\}', sys.stdin.read(), re.S); print(m.group(0) if m else '')")
if ! echo "$PLAN_JSON" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  echo "[c-reel-premium] Opus unavailable — planning on kimi"
  PLAN_JSON=$(claude --print "$PLAN_PROMPT" --dangerously-skip-permissions 2>/dev/null \
    | python3 -c "import sys,re; m=re.search(r'\{.*\}', sys.stdin.read(), __import__('re').S); print(m.group(0) if m else '')")
fi
echo "$PLAN_JSON" > "$PW/plan.json"
python3 - "$PW/plan.json" "$DUR" <<'PY'
import json,re,sys
p=json.load(open(sys.argv[1])); dur=float(sys.argv[2])
assert p["caption_groups"], "no caption groups"
assert abs(p["caption_groups"][-1]["end"]-dur) < 3.0, "captions do not cover the reel"
assert not re.search(r'[ऀ-ॿ]', json.dumps(p)), "Devanagari in plan — Latin script only"
print(f"plan OK: {len(p['caption_groups'])} groups, {len(p.get('sfx',[]))} sfx")
PY
```

## Step P2 — Render the caption overlay over the reel (skip when CAPTIONS=off)

```bash
python3 - "$PW" "$PREMIUM_DIR" "$REEL_IN" "${CAP_TOP:-1180}" <<'PY'
import json, os, shutil, sys
PW, PREMIUM, REEL, CAP_TOP = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
plan = json.load(open(f"{PW}/plan.json"))
import subprocess
dur = round(float(subprocess.run(["ffprobe","-v","error","-show_entries","format=duration",
  "-of","csv=p=0",REEL],capture_output=True,text=True).stdout.strip()),2)
proj = f"{PW}/comp"; os.makedirs(f"{proj}/compositions", exist_ok=True)
shutil.copy(REEL, f"{proj}/reel-in.mp4")
def fill(t, m):
    for k, v in m.items(): t = t.replace("{{%s}}" % k, str(v))
    return t
cap = open(f"{PREMIUM}/templates/caption-overlay.html").read()
open(f"{proj}/compositions/caption-overlay.html","w").write(fill(cap, {
    "DURATION": dur, "CAP_TOP": CAP_TOP, "ACCENT": plan["brand"]["accent"],
    "FG": plan["brand"]["fg"], "GROUPS_JSON": json.dumps(plan["caption_groups"])}))
root = open(f"{PREMIUM}/templates/root-shell-polish.html").read()
open(f"{proj}/index.html","w").write(fill(root, {"DURATION": dur, "VIDEO_SRC": "reel-in.mp4"}))
print(f"assembled polish comp: {len(plan['caption_groups'])} groups, {dur}s, cap_top={CAP_TOP}")
PY
cd "$PW/comp" && npx hyperframes@0.7.5 lint && npx hyperframes@0.7.5 validate && \
  npx hyperframes@0.7.5 render --output "$PW/visuals.mp4" --fps 30 --quality high
cd - >/dev/null
```

`CAPTIONS=off` → `cp "$REEL_IN" "$PW/visuals.mp4"` (SFX+grade still apply below). The reel's
audio is NOT in visuals.mp4 (video muted in the composition) — it returns in P3.

## Step P3 — Grade + audio (original audio untouched, SFX under, ONE pass)

```bash
python3 - "$PW" "$PREMIUM_DIR" "$REEL_IN" <<'PY' > "$PW/mux.sh"
import json, sys
PW, PREMIUM, REEL = sys.argv[1], sys.argv[2], sys.argv[3]
plan = json.load(open(f"{PW}/plan.json"))
cues = plan.get("sfx", [])
GRADES = {
  "warm-amber":   "curves=r='0/0 0.5/0.55 1/1':b='0/0 0.5/0.46 1/0.95',eq=contrast=1.05:saturation=1.08,unsharp=5:5:0.5",
  "clean-bright": "eq=brightness=0.02:contrast=1.06:saturation=1.1,unsharp=5:5:0.5",
  "off":          "null",
}
grade = GRADES.get(plan.get("grade", "clean-bright"), GRADES["clean-bright"])
inputs = " ".join(f"-i \"{PREMIUM}/assets/sfx/{c['name']}.wav\"" for c in cues)
parts, mix = [], "[1:a]"
for j, c in enumerate(cues):
    ms = int(float(c["t"]) * 1000)
    parts.append(f"[{j+2}:a]adelay={ms}|{ms},volume={min(float(c.get('gain', 0.5)), 0.6)}[s{j}]")
    mix += f"[s{j}]"
fc = (";".join(parts) + f";{mix}amix=inputs={len(cues)+1}:normalize=0:duration=first[aout]") if cues else "[1:a]anull[aout]"
print(f'''ffmpeg -y -i "{PW}/visuals.mp4" -i "{REEL}" {inputs} \\
  -filter_complex "[0:v]{grade},format=yuv420p[vout];{fc}" \\
  -map "[vout]" -map "[aout]" \\
  -c:v libx264 -preset medium -crf 19 -r 30 \\
  -c:a aac -b:a 192k -ar 48000 -ac 2 -movflags +faststart "{PW}/polished.mp4"''')
PY
bash "$PW/mux.sh" && cp "$PW/polished.mp4" "$REEL_OUT"
```

**Never loudnorm here** — the calling recipe already mastered the audio; `normalize=0` keeps it at
exactly that level with SFX tucked under.

## Step P4 — QA gate (mandatory)

```bash
ffmpeg -v error -i "$REEL_OUT" -f null -    # clean decode
for pct in 10 35 60 85; do
  t=$(python3 -c "print(round($DUR*0.$pct,1))")
  ffmpeg -v error -y -ss "$t" -i "$REEL_OUT" -frames:v 1 "$PW/qa_$pct.png"
done

# DELIVERY-GATE PROOF — every reel recipe's delivery gate reads this. Writing it is how the
# gate knows the premium pass (kinetic captions + SFX + grade) ACTUALLY ran on this reel, so a
# rushed executor can't hand-burn captions with raw ffmpeg and pass it off as premium. The stamp
# lands next to REEL_OUT so each recipe (whose $W == dirname of its polished output) finds it.
python3 - "$REEL_OUT" <<'PY'
import os, sys, json
out = sys.argv[1]
gate = os.path.join(os.path.dirname(os.path.abspath(out)), ".gate")
os.makedirs(gate, exist_ok=True)
assert os.path.exists(out) and os.path.getsize(out) > 100_000, "REEL_OUT missing/empty — premium pass did not produce output"
json.dump({"applied": True, "captions": os.environ.get("CAPTIONS", "on"),
           "sfx": os.environ.get("SFX", "on"), "by": "c-reel-premium"},
          open(os.path.join(gate, "premium.json"), "w"))
print(f"[gate-stamp] premium: applied → {gate}/premium.json")
PY
```

READ each frame with your vision: captions legible in the band, accent on emphasis words, **zero
Devanagari**, captions NOT covering a face/PIP, grade subtle (skin natural, no crushed blacks).
Spot-listen one SFX cue: audible but clearly UNDER the voice. Any failure → fix, re-render, look
again. Duration of `REEL_OUT` must equal `REEL_IN` (the pass never extends or trims).

## Gotchas (inherited from the fmt3 v0.5 build — do not relearn these)

- Root must be a FULL HTML document; sub-comps keep `<template>`. Bare fragment → bundler
  `Unexpected token '*'`.
- Timing attrs on LOADER divs only; inner template divs carry none.
- Sub-composition `window` is a non-binding Proxy — bare `getComputedStyle(el)`, never
  `window.getComputedStyle`.
- Lint's tag scanner reads comments — no literal tags / brace-tokens in template comments.
- Fonts: Oswald / Inter / JetBrains Mono only (Barlow Condensed is NOT compiler-resolved).
- `{{ACCENT}}` must be a 6-digit hex (templates append alpha hex pairs).
- Run `lint` AND `validate` before `render`.
