#!/usr/bin/env python3
"""scripts/check-step-files.py — static gate for recipe step files (M1-09).

For every <skills-dir>/<recipe>/manifest.json (``.hub`` mirrors skipped):
  * each steps[].instructions file exists and is > 40 lines
  * no banned tokens (TODO / placeholder case-insensitive; /opt/,
    ANTHROPIC_API_KEY, GEMINI_API_KEY, claude-3, claude-sonnet, claude-opus
    case-sensitive)
  * each step file mentions ``saves/<id>.`` for every saves[].id of its step
  * steps/_shared.md exists when any step has instructions
  * a step file mentions ``needs_input.json`` iff its step has a non-empty canAsk
    (a line that says "never" alongside the mention is a prohibition — the
    no-canAsk steps say "Never write `needs_input.json`" — and does not count)

Exit 1 with ``file:line: reason`` lines (line 0 = file-level), else one PASS line.
stdlib only.
"""
import argparse
import json
import os
import sys

TOKENS_CI = ["TODO", "placeholder"]
TOKENS_CS = ["/opt/", "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "claude-3", "claude-sonnet", "claude-opus"]
MIN_LINES = 40


def find_manifests(skills_dir):
    out = []
    for name in sorted(os.listdir(skills_dir)):
        if name == ".hub":
            continue
        m = os.path.join(skills_dir, name, "manifest.json")
        if os.path.isfile(m):
            out.append(m)
    return out


def check_recipe(manifest_path, errors):
    recipe_dir = os.path.dirname(manifest_path)
    try:
        with open(manifest_path, encoding="utf-8") as fh:
            manifest = json.load(fh)
    except (OSError, ValueError) as exc:
        errors.append(f"{manifest_path}:0: cannot parse manifest ({exc})")
        return 0
    checked = 0
    any_instructions = False
    for step in manifest.get("steps") or []:
        rel = step.get("instructions")
        if not rel:
            continue
        any_instructions = True
        sid = step.get("id", "?")
        path = os.path.join(recipe_dir, rel)
        if not os.path.isfile(path):
            errors.append(f"{path}:0: steps[{sid}].instructions file missing")
            continue
        checked += 1
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
        if len(lines) <= MIN_LINES:
            errors.append(f"{path}:0: only {len(lines)} lines (need > {MIN_LINES})")
        for n, line in enumerate(lines, 1):
            low = line.lower()
            for tok in TOKENS_CI:
                if tok.lower() in low:
                    errors.append(f"{path}:{n}: banned token '{tok}' (case-insensitive)")
            for tok in TOKENS_CS:
                if tok in line:
                    errors.append(f"{path}:{n}: banned token '{tok}'")
        text = "\n".join(lines)
        for save in step.get("saves") or []:
            save_id = save.get("id", "?")
            if f"saves/{save_id}." not in text:
                errors.append(f"{path}:0: steps[{sid}] never mentions saves/{save_id}.<ext> for save '{save_id}'")
        can_ask = bool(step.get("canAsk"))
        mentions = any("needs_input.json" in ln and "never" not in ln.lower() for ln in lines)
        if can_ask and not mentions:
            errors.append(f"{path}:0: steps[{sid}] has canAsk but never mentions needs_input.json")
        if mentions and not can_ask:
            errors.append(f"{path}:0: steps[{sid}] mentions needs_input.json but has no canAsk")
    if any_instructions:
        shared = os.path.join(recipe_dir, "steps", "_shared.md")
        if not os.path.isfile(shared):
            errors.append(f"{shared}:0: missing steps/_shared.md (recipe steps have instructions)")
    return checked


def main():
    ap = argparse.ArgumentParser(description="Static gate for recipe step files.")
    ap.add_argument("--skills-dir", default="skills")
    args = ap.parse_args()
    if not os.path.isdir(args.skills_dir):
        print(f"{args.skills_dir}:0: not a directory")
        return 1
    manifests = find_manifests(args.skills_dir)
    errors = []
    checked = 0
    for m in manifests:
        checked += check_recipe(m, errors)
    if errors:
        for e in errors:
            print(e)
        print(f"FAIL — {len(errors)} step-file problem(s) across {len(manifests)} manifest(s)")
        return 1
    print(f"PASS — {checked} step file(s) across {len(manifests)} manifest(s) clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
