#!/usr/bin/env python3
"""Build the Spotlight end-card spec (cta-card.json) from the brand palette in
plan.json plus the per-brand copy exported by the caller (CFW-354 / M1-00).

Usage:
  python3 cta-card.py <plan.json> <out cta-card.json>

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


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: cta-card.py <plan.json> <out cta-card.json>", file=sys.stderr)
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
    for layer in layers:
        print(f"[spotlight] cta-card layer: {layer['type']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
