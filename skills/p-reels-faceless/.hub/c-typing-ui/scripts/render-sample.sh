#!/usr/bin/env bash
# c-typing-ui — render a self-contained sample to /tmp/c-typing-ui-sample/
# Usage: bash scripts/render-sample.sh [output_dir]
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-/tmp/c-typing-ui-sample}"
mkdir -p "$OUT_DIR"

echo "[c-typing-ui] Building sample renders → $OUT_DIR"

# ── Helper: fill a template and return a standalone HTML string ─────────────
fill_template() {
  local tmpl_path="$1"
  shift
  # Read template, strip <template> wrapper (sub-comp → standalone body)
  local body
  body=$(python3 - "$tmpl_path" "$@" <<'PY'
import sys, re, html as h

tmpl_path = sys.argv[1]
args      = dict(a.split("=",1) for a in sys.argv[2:])

content = open(tmpl_path).read()
# Strip sub-composition <template> wrapper
content = re.sub(r'<template[^>]*>\s*', '', content)
content = re.sub(r'\s*</template>\s*$', '', content)

for k, v in args.items():
    content = content.replace("{{" + k + "}}", v)

print(content)
PY
)
  echo "$body"
}

# ── Sample 1: TYPING SCENE (pip-safe) ──────────────────────────────────────
TYPING_DIR="$OUT_DIR/typing-scene"
mkdir -p "$TYPING_DIR"

PROMPT_ESCAPED=$(python3 -c "
import html
s = 'Research this person based on their LinkedIn bio: [paste bio].\n\nFind one real thing they did recently.\n\nWrite a two-sentence opening that references it.\n\nNo fake compliments.'
# Encode newlines as HTML entity so the template placeholder is one line
print(html.escape(s).replace('\n', '&#10;'))
")

python3 - "$SKILL_DIR/templates/typing-scene.html" "$TYPING_DIR/index.html" \
  "DURATION=10.0" \
  "LABEL=claude.ai" \
  "TYPING_SPEED=1.0" \
  "ACCENT=F97316" \
  "VARIANT=pip-safe" \
  "BOTTOM_TAG=research · personalise · send" \
  "PROMPT=$PROMPT_ESCAPED" <<'PY'
import sys, re, html as h

tmpl_path, out_path = sys.argv[1], sys.argv[2]
args = dict(a.split("=",1) for a in sys.argv[3:])

content = open(tmpl_path).read()
# Strip sub-composition <template> wrapper
content = re.sub(r'<template[^>]*>\s*', '', content)
content = re.sub(r'\s*</template>\s*$', '', content)

# Apply BOTTOM_TAG_DISPLAY based on BOTTOM_TAG value
bottom_tag = args.get("BOTTOM_TAG", "").strip()
args["BOTTOM_TAG_DISPLAY"] = "" if bottom_tag else "display:none"

for k, v in args.items():
    content = content.replace("{{" + k + "}}", v)

doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<style>
html, body {{
  margin: 0; padding: 0;
  width: 1080px; height: 1920px;
  overflow: hidden;
  background: #0F172A;
}}
</style>
</head>
<body>{content}</body>
</html>"""

open(out_path, "w").write(doc)
print(f"[c-typing-ui] Wrote {out_path}")
PY

echo "[c-typing-ui] Linting typing scene..."
cd "$TYPING_DIR" && npx hyperframes@0.7.5 lint
echo "[c-typing-ui] Rendering typing scene → $OUT_DIR/typing-scene.mp4"
npx hyperframes@0.7.5 render --output "$OUT_DIR/typing-scene.mp4" --fps 30 --quality standard
cd -

# ── Sample 2: HOOK SCENE ────────────────────────────────────────────────────
HOOK_DIR="$OUT_DIR/hook-scene"
mkdir -p "$HOOK_DIR"

python3 - "$SKILL_DIR/templates/hook-scene.html" "$HOOK_DIR/index.html" \
  "DURATION=3.0" \
  "EYEBROW=Day 13 · Prompt of the Day" \
  "LINE1=PROMPT 13." \
  "LINE2=COLD EMAIL" \
  "LINE3=OPENER." \
  "SUBHEAD=paste into Claude." \
  "ACCENT=F97316" <<'PY'
import sys, re

tmpl_path, out_path = sys.argv[1], sys.argv[2]
args = dict(a.split("=",1) for a in sys.argv[3:])

content = open(tmpl_path).read()
content = re.sub(r'<template[^>]*>\s*', '', content)
content = re.sub(r'\s*</template>\s*$', '', content)

for k, v in args.items():
    content = content.replace("{{" + k + "}}", v)

doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<style>
html, body {{
  margin: 0; padding: 0;
  width: 1080px; height: 1920px;
  overflow: hidden;
  background: #0F172A;
}}
</style>
</head>
<body>{content}</body>
</html>"""

open(out_path, "w").write(doc)
print(f"[c-typing-ui] Wrote {out_path}")
PY

echo "[c-typing-ui] Linting hook scene..."
cd "$HOOK_DIR" && npx hyperframes@0.7.5 lint
echo "[c-typing-ui] Rendering hook scene → $OUT_DIR/hook-scene.mp4"
npx hyperframes@0.7.5 render --output "$OUT_DIR/hook-scene.mp4" --fps 30 --quality standard
cd -

# ── Extract frames from both renders ────────────────────────────────────────
echo "[c-typing-ui] Extracting QA frames..."

for pct in 10 35 65 85; do
  T_TYPING=$(python3 -c "print(round(10.0 * $pct / 100, 1))")
  ffmpeg -y -ss "$T_TYPING" -i "$OUT_DIR/typing-scene.mp4" \
    -frames:v 1 "$OUT_DIR/typing_frame_${pct}pct.png" 2>/dev/null && \
    echo "  typing @${pct}% → typing_frame_${pct}pct.png"
done

for pct in 20 60 90; do
  T_HOOK=$(python3 -c "print(round(3.0 * $pct / 100, 1))")
  ffmpeg -y -ss "$T_HOOK" -i "$OUT_DIR/hook-scene.mp4" \
    -frames:v 1 "$OUT_DIR/hook_frame_${pct}pct.png" 2>/dev/null && \
    echo "  hook @${pct}% → hook_frame_${pct}pct.png"
done

echo ""
echo "[c-typing-ui] Done. Outputs:"
ls -lh "$OUT_DIR"/*.mp4 "$OUT_DIR"/*.png 2>/dev/null
