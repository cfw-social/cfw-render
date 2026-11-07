#!/usr/bin/env python3
"""Decide whether step 05 draws the CTA end-card takeover (p-reels-pip, WI31.10).

The reel ends on ONE call to action, and step 05 never invents its copy.

  1. options.cta_card is not "on"                          -> no takeover.
  2. The planned background already ends on a CTA beat:
     the last beat of the beat list (largest `end`) has
     kind "graphics" and scene.type "cta"                   -> no takeover, no scrim.
  3. CTA copy: --text, else inputs/cta/cta.json `text`,
     else brand.cta. No copy at all                         -> no takeover (said so).
  4. Otherwise                                              -> takeover with that copy.

The handle comes from --handle, else cta.json `handle`, else brand.handle, else none.
The brand is brief.json `brand`, or the --brand FILE when given (SKILL.md's $W/brand.json).

Prints shell assignments for `eval` (CTA_TAKEOVER=on|off, CTA_TEXT, CTA_HANDLE,
CTA_REASON) and writes the same decision to --decision as JSON. The reason line also
goes to stderr. Bad input (missing or malformed beat list, unreadable JSON) exits 2.

  VARS=$(python3 "$SKILL_DIR/scripts/cta_takeover.py" --brief brief.json \
         --beats prior/beat_list.json --cta inputs/cta/cta.json --cta-card "$CTA_CARD" \
         --decision work/cta-decision.json) || exit 1
  eval "$VARS"
"""
import argparse
import json
import os
import shlex
import sys


class InputError(Exception):
    pass


def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as e:
        raise InputError("%s %s could not be read: %s" % (what, path, e))


def text_field(obj, key, where):
    v = obj.get(key) if isinstance(obj, dict) else None
    if v is None:
        return ""
    if not isinstance(v, str):
        raise InputError("%s `%s` is not text" % (where, key))
    return v.strip()


def final_cta_beat(beats_path):
    """The last planned beat when it is a CTA beat, else None."""
    if not os.path.isfile(beats_path):
        raise InputError("beat list %s is missing" % beats_path)
    bl = load_json(beats_path, "beat list")
    beats = bl.get("beats") if isinstance(bl, dict) else None
    if not isinstance(beats, list) or not beats or not all(isinstance(b, dict) for b in beats):
        raise InputError("beat list %s has no beats" % beats_path)
    try:
        last = max(beats, key=lambda b: float(b["end"]))
    except (KeyError, TypeError, ValueError):
        raise InputError("beat list %s has a beat without a numeric `end`" % beats_path)
    scene = last.get("scene") if isinstance(last.get("scene"), dict) else {}
    if last.get("kind") == "graphics" and str(scene.get("type") or "").strip().lower() == "cta":
        return last
    return None


def decide(brief_path, beats_path, cta_path, cta_card, text_arg="", handle_arg="", brand_path=""):
    if brand_path:
        brand = load_json(brand_path, "brand")
    else:
        brief = load_json(brief_path, "brief") if brief_path and os.path.isfile(brief_path) else {}
        brand = brief.get("brand") if isinstance(brief, dict) else {}
    if not isinstance(brand, dict):
        brand = {}
    cta = load_json(cta_path, "CTA input") if cta_path and os.path.isfile(cta_path) else {}
    if not isinstance(cta, dict):
        raise InputError("CTA input %s is not a JSON object" % cta_path)

    cta_text = text_field(cta, "text", "inputs/cta/cta.json")
    brand_cta = text_field(brand, "cta", "brand")
    text, source = "", ""
    for value, name in ((text_arg.strip(), "CTA_TEXT"), (cta_text, "inputs/cta/cta.json"),
                        (brand_cta, "brand.cta")):
        if value:
            text, source = value, name
            break
    handle = (handle_arg.strip() or text_field(cta, "handle", "inputs/cta/cta.json")
              or text_field(brand, "handle", "brand"))

    beat = final_cta_beat(beats_path)
    d = {"takeover": False, "text": "", "handle": "", "source": None, "cta_beat": None}
    if (cta_card or "").strip().lower() != "on":
        d["reason"] = "end card off (options.cta_card=%s); no takeover drawn" % (cta_card or "off")
    elif beat is not None:
        d["cta_beat"] = {k: beat.get(k) for k in ("index", "slug", "start", "end")}
        d["reason"] = ("end card skipped: the planned background already ends on its CTA beat "
                       "(beat %s %s, %s-%s s, scene.type=cta); no second CTA and no scrim drawn"
                       % (beat.get("index"), beat.get("slug") or "", beat.get("start"), beat.get("end")))
        if source:
            d["reason"] += "; the %s copy was not drawn" % source
    elif not text:
        d["reason"] = ("end card skipped: no CTA copy (no inputs/cta/cta.json text, no brand.cta); "
                       "step 05 never invents copy")
    else:
        d.update(takeover=True, text=text, handle=handle, source=source,
                 reason="end card drawn from %s%s" % (source, " with handle" if handle else ", no handle line"))
    return d


def main(argv=None):
    p = argparse.ArgumentParser(description="Decide the p-reels-pip CTA end-card takeover.")
    p.add_argument("--brief", default="brief.json", help="order brief; its `brand` gives cta/handle")
    p.add_argument("--brand", default="", help="a brand JSON file to use instead of the brief's `brand`")
    p.add_argument("--beats", default="prior/beat_list.json")
    p.add_argument("--cta", default="inputs/cta/cta.json")
    p.add_argument("--cta-card", default="on")
    p.add_argument("--text", default="", help="explicit CTA copy (wins over cta.json and brand.cta)")
    p.add_argument("--handle", default="", help="explicit handle (wins over cta.json and brand.handle)")
    p.add_argument("--decision", default="", help="write the decision JSON here")
    a = p.parse_args(sys.argv[1:] if argv is None else argv)
    try:
        d = decide(a.brief, a.beats, a.cta, a.cta_card, a.text, a.handle, a.brand)
    except InputError as e:
        sys.stderr.write("cta_takeover.py: FAILED - %s\n" % e)
        return 2
    if a.decision:
        with open(a.decision, "w", encoding="utf-8") as fh:
            json.dump(d, fh, indent=1)
    sys.stderr.write("[pip] %s\n" % d["reason"])
    print("CTA_TAKEOVER=%s; CTA_TEXT=%s; CTA_HANDLE=%s; CTA_REASON=%s" % (
        "on" if d["takeover"] else "off", shlex.quote(d["text"]), shlex.quote(d["handle"]),
        shlex.quote(d["reason"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
