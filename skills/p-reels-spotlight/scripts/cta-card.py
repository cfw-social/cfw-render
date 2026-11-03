#!/usr/bin/env python3
"""Build the Spotlight end-card spec (cta-card.json) from the brand palette in
plan.json plus the per-brand copy exported by the caller (CFW-354 / M1-00).

Usage:
  python3 cta-card.py <plan.json> <out cta-card.json> [<project dir> <gsap.min.js>]
  With a project dir, also writes <dir>/index.html + gsap.min.js: an animated HyperFrames
  composition of the card that `hyperframes render <dir>` renders (WI2.93).

Env (all resolved from the ACTIVE brand by the caller — never hard-coded):
  CTA_TEXT      hero line. Default "FOLLOW FOR MORE" (generic, carries no brand).
  CTA_HANDLE    handle/URL line. EMPTY → the handle layer is omitted entirely.
                No handle known means NO handle line; a placeholder or another
                brand's handle is never printed.
  BRAND_NAME    kicker line above the hero. EMPTY → the kicker layer is omitted.
  CTA_DURATION  seconds, default 3.0.

Prints the layer types it emitted, one per line, so the caller's log shows
whether a handle line shipped.
"""
import json
import os
import sys


# WI2.93: hyperframes 0.7.5 `render` takes a project DIRECTORY holding index.html; handed
# cta-card.json it stops with "Not a directory" and the step used to fall back to a still FFmpeg
# card. The spec above is now also written out as a real HyperFrames project: one full-frame
# composition whose GSAP timeline plays the scale-pop entry, staggers the kicker, hero words and
# handle in, draws the arrow at appearAt and keeps the glow and arrow moving to the last frame.
def write_project(card: dict, project_dir: str, gsap_src: str) -> None:
    import html
    import shutil
    if not os.path.isfile(gsap_src):
        raise SystemExit(f"cta-card.py: vendored gsap.min.js not found at {gsap_src}; never fall back to a CDN")
    os.makedirs(project_dir, exist_ok=True)
    shutil.copy(gsap_src, os.path.join(project_dir, "gsap.min.js"))
    dur = round(float(card["duration"]), 3)
    w, h = card["size"]
    entry = card.get("entry") or {}
    pop_from, pop_dur = float(entry.get("from", 0.92)), float(entry.get("duration", 0.35))
    parts, css = [], []
    for n, layer in enumerate(card["layers"]):
        kind, cls = layer["type"], f"l{n}"
        if kind == "arrow":
            (x0, y0), (x1, y1) = layer["from"], layer["to"]
            css.append(f"#cta-card .{cls}{{left:{x0 - 40}px;top:{y0}px;width:80px;height:{y1 - y0 + 40}px;}}"
                       f"#cta-card .{cls} .shaft{{left:36px;top:0;width:8px;height:{y1 - y0}px;background:{layer['color']};"
                       f"border-radius:4px;transform-origin:50% 0;}}"
                       f"#cta-card .{cls} .head{{left:12px;top:{y1 - y0 - 24}px;width:56px;height:56px;"
                       f"border-right:8px solid {layer['color']};border-bottom:8px solid {layer['color']};"
                       f"border-radius:4px;transform:rotate(45deg);}}")
            parts.append(f'<div class="layer arrow {cls}"><div class="shaft"></div><div class="head"></div></div>')
            continue
        size = int(layer.get("fontSize", 52 if kind == "kicker" else 80))
        font = "'Oswald', sans-serif" if kind in ("hero", "kicker") else "'Inter', sans-serif"
        weight = int(layer.get("weight", 700))
        css.append(f"#cta-card .{cls}{{top:{int(layer['y'])}px;color:{layer['color']};font-family:{font};font-size:{size}px;"
                   f"font-weight:{weight};opacity:{float(layer.get('opacity', 1.0))};"
                   + ("letter-spacing:0.18em;" if kind == "kicker" else "")
                   + ("text-transform:uppercase;line-height:1.0;" if kind == "hero" else "") + "}")
        if kind == "hero":
            # WI2.96: the brand name (the kicker text) is ONE unit: a nowrap span whose words are joined by
            # non-breaking spaces, so the headline never splits it ("FOLLOW TEST / BRAND FOR / MORE").
            norm = lambda t: t.strip(".,!?:;'\"()").upper()
            keep = [norm(t) for t in next((l["text"] for l in card["layers"] if l["type"] == "kicker"), "").split()]
            toks, units, i = layer["text"].split(), [], 0
            while i < len(toks):
                if keep and [norm(t) for t in toks[i:i + len(keep)]] == keep:
                    units.append('<span class="word brand">'
                                 + "&#160;".join(html.escape(t) for t in toks[i:i + len(keep)]) + "</span>")
                    i += len(keep)
                else:
                    units.append(f'<span class="word">{html.escape(toks[i])}</span>')
                    i += 1
            words = " ".join(units)
            parts.append(f'<div class="layer hero {cls}" data-size="{size}">{words}</div>')
        else:
            parts.append(f'<div class="layer {kind} {cls}" data-size="{size}">{html.escape(layer["text"])}</div>')
    accent = next((l["color"] for l in card["layers"] if l["type"] == "arrow"), "#ffffff")
    arrow_at = next((float(l.get("appearAt", 0.5)) for l in card["layers"] if l["type"] == "arrow"), 0.5)
    bobs = max(0, int((dur - arrow_at - 0.6) / 0.5) * 2 - 1)
    css_text, body_text = "".join(css), "\n        ".join(parts)
    # WI2.96: fit the headline and the kicker before the timeline is built, and again once fonts load.
    fit_js = r'''        // WI2.96: the brand name is one hero unit (.word.brand, nowrap) and never breaks. The units go on
        // the fewest lines (max 3) whose most balanced split fits HERO_MAX_W ((1080 - 2 x 60) / 1.04 breathe),
        // at the design size when possible, else the font shrinks; at HERO_MIN a unit still wider than the
        // safe width (a very long brand name) shrinks on its own. The kicker stays on one line inside
        // KICKER_MAX_W. Refit once fonts load. The text is never cut.
        var HERO_MAX_W = 920, HERO_MAX_LINES = 3, HERO_MIN = 60, KICKER_MAX_W = 960;
        function fitOne(el, base, maxW) {
          el.style.fontSize = base + "px";
          var w = el.scrollWidth;
          if (w <= maxW) return;
          var size = Math.floor(base * maxW / w);
          el.style.fontSize = size + "px";
          while (size > 8 && el.scrollWidth > maxW) { size -= 1; el.style.fontSize = size + "px"; }
        }
        function splitLines(ws, gap) {
          var n = ws.length;
          function span(a, b) { var s = gap * (b - a - 1); for (var i = a; i < b; i++) s += ws[i]; return s; }
          for (var k = 1; k <= Math.min(HERO_MAX_LINES, n); k++) {
            var cuts = [], best = null, bestW = Infinity;
            if (k === 1) cuts.push([]);
            if (k === 2) for (var a = 1; a < n; a++) cuts.push([a]);
            if (k === 3) for (var b = 1; b < n - 1; b++) for (var c = b + 1; c < n; c++) cuts.push([b, c]);
            cuts.forEach(function (cut) {
              var edges = [0].concat(cut, [n]), widest = 0;
              for (var j = 0; j < k; j++) widest = Math.max(widest, span(edges[j], edges[j + 1]));
              if (widest < bestW) { bestW = widest; best = edges; }
            });
            if (bestW <= HERO_MAX_W) return best;
          }
          return null;
        }
        function fitHero() {
          var hero = document.querySelector("#cta-card .hero");
          if (!hero) return;
          var units = Array.prototype.slice.call(hero.querySelectorAll(".word"));
          if (!units.length) return;
          var size = parseFloat(hero.getAttribute("data-size")) || 110, edges = null;
          for (;;) {
            hero.style.fontSize = size + "px";
            units.forEach(function (u) {
              u.style.fontSize = "";
              if (size <= HERO_MIN && u.scrollWidth > HERO_MAX_W) fitOne(u, size, HERO_MAX_W);
            });
            edges = splitLines(units.map(function (u) { return u.scrollWidth; }), size * 0.28);
            if (edges || size <= 8) break;
            size = size > HERO_MIN ? Math.max(HERO_MIN, Math.floor(size * 0.94)) : size - 2;
          }
          if (!edges) edges = [0, units.length];
          var old = Array.prototype.slice.call(hero.querySelectorAll(".line"));
          for (var j = 0; j + 1 < edges.length; j++) {
            var row = document.createElement("div");
            row.className = "line";
            for (var i = edges[j]; i < edges[j + 1]; i++) row.appendChild(units[i]);
            hero.appendChild(row);
          }
          old.forEach(function (r) { hero.removeChild(r); });
        }
        function fitCard() {
          var kicker = document.querySelector("#cta-card .kicker");
          if (kicker) fitOne(kicker, parseFloat(kicker.getAttribute("data-size")) || 52, KICKER_MAX_W);
          fitHero();
        }
        fitCard();
        if (document.fonts && document.fonts.ready) { document.fonts.ready.then(fitCard); }
'''
    doc = f'''<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width={w}, height={h}" />
    <script src="gsap.min.js"></script>
    <style>
      * {{ margin: 0; padding: 0; box-sizing: border-box; }}
      html, body {{ width: {w}px; height: {h}px; overflow: hidden; background: {card['background']}; }}
      #cta-card {{ position: relative; width: {w}px; height: {h}px; overflow: hidden; background: {card['background']}; }}
      #cta-card .glow {{ position: absolute; left: -260px; top: 260px; width: 1100px; height: 1100px;
        background: radial-gradient(circle, {accent}33 0%, transparent 62%); }}
      #cta-card .card {{ position: absolute; inset: 0; transform-origin: 50% 45%; }}
      #cta-card .layer {{ position: absolute; left: 60px; right: 60px; text-align: center; }}
      #cta-card .hero {{ display: flex; flex-wrap: wrap; justify-content: center; gap: 0 0.28em; }}
      #cta-card .word {{ display: inline-block; }}
      #cta-card .hero .line {{ flex: 0 0 100%; display: flex; justify-content: center; gap: 0 0.28em; }}
      #cta-card .hero .word {{ flex: none; }}
      #cta-card .word.brand, #cta-card .kicker {{ white-space: nowrap; }}
      #cta-card .arrow, #cta-card .arrow div {{ position: absolute; right: auto; }}
      {css_text}
    </style>
  </head>
  <body>
    <div id="cta-card" data-composition-id="cta-card" data-start="0" data-duration="{dur}"
         data-width="{w}" data-height="{h}">
      <div class="glow"></div>
      <div class="card">
        {body_text}
      </div>
    </div>
    <script>
      window.__timelines = window.__timelines || {{}};
      (function () {{
        var DUR = {dur};
{fit_js}        var tl = gsap.timeline({{ paused: true }});
        tl.fromTo("#cta-card .glow", {{ x: -120, y: 80, opacity: 0.4 }},
          {{ x: 360, y: -140, opacity: 1, duration: DUR, ease: "sine.inOut" }}, 0);
        tl.fromTo("#cta-card .card", {{ scale: {pop_from}, opacity: 0 }},
          {{ scale: 1, opacity: 1, duration: {pop_dur}, ease: "back.out(2)" }}, 0);
        tl.from("#cta-card .kicker", {{ y: -40, opacity: 0, duration: 0.4, ease: "power3.out" }}, 0.08);
        tl.from("#cta-card .word", {{ y: 90, opacity: 0, duration: 0.45, ease: "power4.out", stagger: 0.07 }}, 0.14);
        tl.to("#cta-card .hero", {{ scale: 1.04, duration: Math.max(0.5, DUR - 0.9), ease: "sine.inOut" }}, 0.8);
        tl.from("#cta-card .handle", {{ y: 40, opacity: 0, duration: 0.4, ease: "power3.out" }}, 0.42);
        tl.from("#cta-card .arrow .shaft", {{ scaleY: 0, duration: 0.3, ease: "power2.out" }}, {arrow_at});
        tl.from("#cta-card .arrow .head", {{ opacity: 0, y: -30, duration: 0.25, ease: "back.out(3)" }}, {arrow_at + 0.2});
        tl.to("#cta-card .arrow", {{ y: 24, duration: 0.25, ease: "sine.inOut", yoyo: true, repeat: {bobs} }}, {arrow_at + 0.5});
        window.__timelines["cta-card"] = tl;
      }})();
    </script>
  </body>
</html>
'''
    with open(os.path.join(project_dir, "index.html"), "w", encoding="utf-8") as fh:
        fh.write(doc)


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 5):
        print("usage: cta-card.py <plan.json> <out cta-card.json> [<project dir> <gsap.min.js>]", file=sys.stderr)
        return 2
    plan_path, out_path = argv[1], argv[2]
    with open(plan_path, encoding="utf-8") as fh:
        brand = json.load(fh)["brand"]
    bg = brand["bg"].lstrip("#")
    accent = brand["accent"].lstrip("#")
    fg = brand["fg"].lstrip("#")

    env = os.environ
    cta_text = env.get("CTA_TEXT", "").strip() or "FOLLOW FOR MORE"
    cta_handle = env.get("CTA_HANDLE", "").strip()
    brand_name = env.get("BRAND_NAME", "").strip()
    duration = float(env.get("CTA_DURATION", "").strip() or "3.0")

    layers: list[dict] = []
    if brand_name:
        layers.append({"type": "kicker", "text": brand_name.upper(), "color": f"#{accent}", "y": 540})
    layers.append(
        {"type": "hero", "text": cta_text, "color": f"#{fg}", "y": 760, "fontSize": 110, "weight": 800, "wrap": True}
    )
    if cta_handle:
        layers.append(
            {"type": "handle", "text": cta_handle, "color": f"#{fg}", "y": 1180, "fontSize": 56, "opacity": 0.72}
        )
    layers.append({"type": "arrow", "from": [540, 1320], "to": [540, 1420], "color": f"#{accent}", "appearAt": 0.5})

    card = {
        "duration": duration,
        "fps": 30,
        "size": [1080, 1920],
        "background": f"#{bg}",
        "layers": layers,
        "entry": {"type": "scale-pop", "from": 0.92, "to": 1.0, "duration": 0.35, "sfx": "impact-sub"},
        "exit": {"type": "none"},
    }
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(card, fh, indent=2)
        fh.write("\n")
    if len(argv) == 5:
        write_project(card, argv[3], argv[4])
        print(f"[spotlight] cta-card project: {argv[3]}/index.html ({card['duration']:.3f}s)")
    for layer in layers:
        print(f"[spotlight] cta-card layer: {layer['type']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
