#!/usr/bin/env python3
"""scripts/validate-manifests.py — validate every recipe manifest (M1-01).

Validates `skills/*/manifest.json` against `schemas/recipe-manifest.v1.schema.json`
(plans/m1/CONTRACTS.md section 2) and runs the cross-reference checks a JSON
Schema cannot express:

  * `recipe` matches the skill folder name
  * `inputs[].id`, `steps[].id`, `alternatives[].id`, `saves[].id`, `checks[].id`
    are unique
  * `steps[].canAsk[]` names an existing input
  * `inputs[].alternatives[].runsSteps[]` names an existing step
  * `steps[].when.inputPresent` names an existing input
  * `steps[].when.alternative` names an existing alternative
  * `inputs[].neededAt.step` names an existing step
  * `steps[].instructions` points at a file that exists inside the skill folder
  * `count.min <= count.max`, `durationSec.min <= durationSec.max`
  * `alternatives` only on `required: true` inputs; `choices` only with kind `choice`

Runtime-free repo: Python 3 standard library only. If the `jsonschema` package
happens to be importable it is used as an extra layer; every rule above is also
enforced by hand so the gate is identical with or without it.

Usage:
  validate-manifests.py [--skills-dir DIR] [--schema FILE] [MANIFEST ...]
    --skills-dir DIR  skills root to scan for */manifest.json (default: <repo>/skills)
    --schema FILE     schema path (default: <repo>/schemas/recipe-manifest.v1.schema.json)
    MANIFEST ...      explicit manifest paths; when given, --skills-dir is not scanned

Exit codes: 0 = every manifest valid; 1 = at least one error (each printed as
"<path>: <message>"); 2 = usage / unreadable schema.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent.parent
DEFAULT_SKILLS_DIR = REPO_DIR / "skills"
DEFAULT_SCHEMA = REPO_DIR / "schemas" / "recipe-manifest.v1.schema.json"

SNAKE = re.compile(r"^[a-z][a-z0-9_]*$")
RECIPE_ID = re.compile(r"^[a-z0-9][a-z0-9-]*$")
TOOL = re.compile(r"^[a-z0-9][a-z0-9._-]*(>=[0-9][0-9.]*)?$")
PROVIDER = re.compile(r"^[a-z][a-z0-9-]*$")
ASPECT = re.compile(r"^[0-9]+:[0-9]+$")

INPUT_KINDS = {"video", "audio", "image", "link", "text", "choice"}
SAVE_KINDS = {"video", "audio", "image", "text", "json"}
DELIVERABLE_KINDS = {"video", "image", "audio", "text"}
ENGINES = {"codex", "claude-code", "api-key"}
OSES = {"macos", "linux"}
ORIENTATIONS = {"portrait", "landscape", "square", "any"}
RUNS_ON = {"computer", "server"}

TOP_REQUIRED = ["manifestFormat", "recipe", "recipeVersion", "label", "deliverable", "needs", "inputs", "steps"]
TOP_ALLOWED = set(TOP_REQUIRED)
DELIVERABLE_ALLOWED = {"kind", "aspect", "width", "height", "durationSec"}
NEEDS_REQUIRED = ["os", "engines", "tools", "providers"]
INPUT_REQUIRED = ["id", "label", "kinds", "required", "count", "neededAt"]
INPUT_ALLOWED = set(INPUT_REQUIRED) | {"constraints", "alternatives", "default", "prompt", "choices"}
CONSTRAINT_ALLOWED = {"durationSec", "orientation", "maxBytes"}
STEP_REQUIRED = ["id", "label", "weight", "runsOn", "when"]
STEP_ALLOWED = set(STEP_REQUIRED) | {"instructions", "saves", "checks", "maxCheckRetries", "canAsk"}


class Errors:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.items: list[str] = []

    def add(self, msg: str) -> None:
        self.items.append(f"{self.path}: {msg}")


def _is_int(v: object) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _is_num(v: object) -> bool:
    return (isinstance(v, (int, float))) and not isinstance(v, bool)


def _nonempty_str(v: object) -> bool:
    return isinstance(v, str) and len(v) > 0


def _check_keys(err: Errors, obj: dict, where: str, required: list[str], allowed: set[str]) -> None:
    for k in required:
        if k not in obj:
            err.add(f"{where}: missing required field '{k}'")
    for k in obj:
        if k not in allowed:
            err.add(f"{where}: unknown field '{k}'")


def _check_range(err: Errors, obj: object, where: str) -> None:
    if not isinstance(obj, dict):
        err.add(f"{where}: must be an object {{min, max}}")
        return
    for k in obj:
        if k not in ("min", "max"):
            err.add(f"{where}: unknown field '{k}'")
    for k in ("min", "max"):
        if k in obj and (not _is_num(obj[k]) or obj[k] < 0):
            err.add(f"{where}.{k}: must be a number >= 0")
    lo, hi = obj.get("min"), obj.get("max")
    if _is_num(lo) and _is_num(hi) and lo > hi:
        err.add(f"{where}: min ({lo}) must be <= max ({hi})")


def _check_unique(err: Errors, ids: list[object], where: str) -> None:
    seen: set[str] = set()
    for i in ids:
        if isinstance(i, str):
            if i in seen:
                err.add(f"{where}: duplicate id '{i}'")
            seen.add(i)


def _check_id_list(err: Errors, lst: object, where: str, known: set[str], what: str) -> None:
    if not isinstance(lst, list):
        err.add(f"{where}: must be an array of {what} ids")
        return
    _check_unique(err, lst, where)
    for i, ref in enumerate(lst):
        if not (isinstance(ref, str) and SNAKE.match(ref)):
            err.add(f"{where}[{i}]: must be a snake_case {what} id")
        elif ref not in known:
            err.add(f"{where}: references unknown {what} '{ref}'")


def validate_structure(err: Errors, m: object, skill_dir: Path) -> None:
    """Hand-written equivalent of the schema plus the cross-reference checks."""
    if not isinstance(m, dict):
        err.add("manifest must be a JSON object")
        return
    _check_keys(err, m, "manifest", TOP_REQUIRED, TOP_ALLOWED)

    if "manifestFormat" in m and (not _is_int(m["manifestFormat"]) or m["manifestFormat"] != 1):
        err.add("manifestFormat: must be the integer 1")
    if "recipe" in m:
        if not (isinstance(m["recipe"], str) and RECIPE_ID.match(m["recipe"])):
            err.add("recipe: must match ^[a-z0-9][a-z0-9-]*$")
        elif m["recipe"] != skill_dir.name:
            err.add(f"recipe: '{m['recipe']}' does not match the skill folder name '{skill_dir.name}'")
    if "recipeVersion" in m and not _nonempty_str(m["recipeVersion"]):
        err.add("recipeVersion: must be a non-empty string")
    if "label" in m and not _nonempty_str(m["label"]):
        err.add("label: must be a non-empty string")

    d = m.get("deliverable")
    if d is not None:
        if not isinstance(d, dict):
            err.add("deliverable: must be an object")
        else:
            _check_keys(err, d, "deliverable", ["kind"], DELIVERABLE_ALLOWED)
            if "kind" in d and d["kind"] not in DELIVERABLE_KINDS:
                err.add(f"deliverable.kind: must be one of {sorted(DELIVERABLE_KINDS)}")
            if "aspect" in d and not (isinstance(d["aspect"], str) and ASPECT.match(d["aspect"])):
                err.add("deliverable.aspect: must look like W:H")
            for k in ("width", "height"):
                if k in d and (not _is_int(d[k]) or d[k] < 1):
                    err.add(f"deliverable.{k}: must be an integer >= 1")
            if "durationSec" in d:
                _check_range(err, d["durationSec"], "deliverable.durationSec")

    n = m.get("needs")
    if n is not None:
        if not isinstance(n, dict):
            err.add("needs: must be an object")
        else:
            _check_keys(err, n, "needs", NEEDS_REQUIRED, set(NEEDS_REQUIRED))
            for key, allowed, pat in (
                ("os", OSES, None),
                ("engines", ENGINES, None),
                ("tools", None, TOOL),
                ("providers", None, PROVIDER),
            ):
                v = n.get(key)
                if v is None:
                    continue
                if not isinstance(v, list):
                    err.add(f"needs.{key}: must be an array")
                    continue
                _check_unique(err, v, f"needs.{key}")
                for i, item in enumerate(v):
                    if not isinstance(item, str):
                        err.add(f"needs.{key}[{i}]: must be a string")
                    elif allowed is not None and item not in allowed:
                        err.add(f"needs.{key}[{i}]: '{item}' not one of {sorted(allowed)}")
                    elif pat is not None and not pat.match(item):
                        err.add(f"needs.{key}[{i}]: '{item}' does not match {pat.pattern}")
            if isinstance(n.get("engines"), list) and len(n["engines"]) == 0:
                err.add("needs.engines: must list at least one engine")

    inputs = m.get("inputs")
    steps = m.get("steps")
    if inputs is not None and not isinstance(inputs, list):
        err.add("inputs: must be an array")
        inputs = None
    if steps is not None and not isinstance(steps, list):
        err.add("steps: must be an array")
        steps = None
    if isinstance(steps, list) and len(steps) == 0:
        err.add("steps: must list at least one step")

    input_ids: set[str] = set()
    step_ids: set[str] = set()
    alt_ids: set[str] = set()
    if inputs:
        _check_unique(err, [i.get("id") for i in inputs if isinstance(i, dict)], "inputs")
        input_ids = {i["id"] for i in inputs if isinstance(i, dict) and isinstance(i.get("id"), str)}
    if steps:
        _check_unique(err, [s.get("id") for s in steps if isinstance(s, dict)], "steps")
        step_ids = {s["id"] for s in steps if isinstance(s, dict) and isinstance(s.get("id"), str)}

    # ---- inputs ----
    for idx, inp in enumerate(inputs or []):
        where = f"inputs[{idx}]"
        if not isinstance(inp, dict):
            err.add(f"{where}: must be an object")
            continue
        iid = inp.get("id")
        if isinstance(iid, str):
            where = f"inputs[{iid}]"
        _check_keys(err, inp, where, INPUT_REQUIRED, INPUT_ALLOWED)
        if "id" in inp and not (isinstance(iid, str) and SNAKE.match(iid)):
            err.add(f"{where}.id: must be snake_case (^[a-z][a-z0-9_]*$)")
        if "label" in inp and not _nonempty_str(inp["label"]):
            err.add(f"{where}.label: must be a non-empty string")
        kinds = inp.get("kinds")
        if kinds is not None:
            if not isinstance(kinds, list) or len(kinds) == 0:
                err.add(f"{where}.kinds: must be a non-empty array")
            else:
                _check_unique(err, kinds, f"{where}.kinds")
                for k in kinds:
                    if k not in INPUT_KINDS:
                        err.add(f"{where}.kinds: '{k}' not one of {sorted(INPUT_KINDS)}")
        if "required" in inp and not isinstance(inp["required"], bool):
            err.add(f"{where}.required: must be a boolean")
        cnt = inp.get("count")
        if cnt is not None:
            if not isinstance(cnt, dict):
                err.add(f"{where}.count: must be an object {{min, max}}")
            else:
                _check_keys(err, cnt, f"{where}.count", ["min", "max"], {"min", "max"})
                if "min" in cnt and (not _is_int(cnt["min"]) or cnt["min"] < 0):
                    err.add(f"{where}.count.min: must be an integer >= 0")
                if "max" in cnt and cnt["max"] is not None and (not _is_int(cnt["max"]) or cnt["max"] < 0):
                    err.add(f"{where}.count.max: must be an integer >= 0 or null")
                if _is_int(cnt.get("min")) and _is_int(cnt.get("max")) and cnt["min"] > cnt["max"]:
                    err.add(f"{where}.count: min ({cnt['min']}) must be <= max ({cnt['max']})")
        cons = inp.get("constraints")
        if cons is not None:
            if not isinstance(cons, dict):
                err.add(f"{where}.constraints: must be an object")
            else:
                _check_keys(err, cons, f"{where}.constraints", [], CONSTRAINT_ALLOWED)
                if "durationSec" in cons:
                    _check_range(err, cons["durationSec"], f"{where}.constraints.durationSec")
                if "orientation" in cons and cons["orientation"] not in ORIENTATIONS:
                    err.add(f"{where}.constraints.orientation: must be one of {sorted(ORIENTATIONS)}")
                if "maxBytes" in cons and (not _is_int(cons["maxBytes"]) or cons["maxBytes"] < 1):
                    err.add(f"{where}.constraints.maxBytes: must be an integer >= 1")
        na = inp.get("neededAt")
        if "neededAt" in inp:
            if na == "start":
                pass
            elif isinstance(na, dict) and set(na) == {"step"} and isinstance(na["step"], str) and SNAKE.match(na["step"]):
                if na["step"] not in step_ids:
                    err.add(f"{where}.neededAt: references unknown step '{na['step']}'")
            else:
                err.add(f"{where}.neededAt: must be \"start\" or {{\"step\": \"<stepId>\"}}")
        alts = inp.get("alternatives")
        if alts is not None:
            if not isinstance(alts, list):
                err.add(f"{where}.alternatives: must be an array")
            else:
                if inp.get("required") is False:
                    err.add(f"{where}.alternatives: only a required input can have alternatives")
                _check_unique(err, [a.get("id") for a in alts if isinstance(a, dict)], f"{where}.alternatives")
                for j, alt in enumerate(alts):
                    aw = f"{where}.alternatives[{j}]"
                    if not isinstance(alt, dict):
                        err.add(f"{aw}: must be an object")
                        continue
                    _check_keys(err, alt, aw, ["id", "label", "runsSteps"], {"id", "label", "runsSteps"})
                    aid = alt.get("id")
                    if "id" in alt and not (isinstance(aid, str) and SNAKE.match(aid)):
                        err.add(f"{aw}.id: must be snake_case")
                    elif isinstance(aid, str):
                        if aid in alt_ids:
                            err.add(f"{aw}.id: alternative id '{aid}' is already used by another input")
                        alt_ids.add(aid)
                    if "label" in alt and not _nonempty_str(alt["label"]):
                        err.add(f"{aw}.label: must be a non-empty string")
                    if "runsSteps" in alt:
                        rs = alt["runsSteps"]
                        if not isinstance(rs, list) or len(rs) == 0:
                            err.add(f"{aw}.runsSteps: must be a non-empty array of step ids")
                        else:
                            _check_id_list(err, rs, f"{aw}.runsSteps", step_ids, "step")
        if "default" in inp and not _nonempty_str(inp["default"]):
            err.add(f"{where}.default: must be a non-empty string")
        if "prompt" in inp and not _nonempty_str(inp["prompt"]):
            err.add(f"{where}.prompt: must be a non-empty string")
        if "choices" in inp:
            ch = inp["choices"]
            if isinstance(kinds, list) and "choice" not in kinds:
                err.add(f"{where}.choices: only valid when kinds includes 'choice'")
            if not isinstance(ch, list) or len(ch) == 0:
                err.add(f"{where}.choices: must be a non-empty array")
            else:
                for j, c in enumerate(ch):
                    if _nonempty_str(c):
                        continue
                    if isinstance(c, dict) and set(c) == {"id", "label"} and isinstance(c["id"], str) \
                            and SNAKE.match(c["id"]) and _nonempty_str(c["label"]):
                        continue
                    err.add(f"{where}.choices[{j}]: must be a string or {{id, label}}")

    # ---- steps ----
    for idx, st in enumerate(steps or []):
        where = f"steps[{idx}]"
        if not isinstance(st, dict):
            err.add(f"{where}: must be an object")
            continue
        sid = st.get("id")
        if isinstance(sid, str):
            where = f"steps[{sid}]"
        _check_keys(err, st, where, STEP_REQUIRED, STEP_ALLOWED)
        if "id" in st and not (isinstance(sid, str) and SNAKE.match(sid)):
            err.add(f"{where}.id: must be snake_case (^[a-z][a-z0-9_]*$)")
        if "label" in st and not _nonempty_str(st["label"]):
            err.add(f"{where}.label: must be a non-empty string")
        if "weight" in st and (not _is_int(st["weight"]) or st["weight"] < 0):
            err.add(f"{where}.weight: must be an integer >= 0")
        runs_on = st.get("runsOn")
        if "runsOn" in st and runs_on not in RUNS_ON:
            err.add(f"{where}.runsOn: must be one of {sorted(RUNS_ON)}")
        w = st.get("when")
        if "when" in st:
            if w == "always":
                pass
            elif isinstance(w, dict) and set(w) == {"inputPresent"} and isinstance(w["inputPresent"], str) \
                    and SNAKE.match(w["inputPresent"]):
                if w["inputPresent"] not in input_ids:
                    err.add(f"{where}.when.inputPresent: references unknown input '{w['inputPresent']}'")
            elif isinstance(w, dict) and set(w) == {"alternative"} and isinstance(w["alternative"], str) \
                    and SNAKE.match(w["alternative"]):
                if w["alternative"] not in alt_ids:
                    err.add(f"{where}.when.alternative: references unknown alternative '{w['alternative']}'")
            else:
                err.add(f"{where}.when: must be \"always\", {{\"inputPresent\": \"<inputId>\"}} or {{\"alternative\": \"<alternativeId>\"}}")
        ins = st.get("instructions")
        if runs_on == "computer" and "instructions" not in st:
            err.add(f"{where}.instructions: required for a computer step")
        if "instructions" in st:
            if not (_nonempty_str(ins) and ins.endswith(".md") and not ins.startswith("/") and ".." not in ins.split("/")):
                err.add(f"{where}.instructions: must be a relative .md path inside the skill folder")
            else:
                target = skill_dir / ins
                if not target.is_file():
                    err.add(f"{where}.instructions: file not found: {target}")
        saves = st.get("saves")
        if saves is not None:
            if not isinstance(saves, list):
                err.add(f"{where}.saves: must be an array")
            else:
                _check_unique(err, [s.get("id") for s in saves if isinstance(s, dict)], f"{where}.saves")
                for j, sv in enumerate(saves):
                    sw = f"{where}.saves[{j}]"
                    if not isinstance(sv, dict):
                        err.add(f"{sw}: must be an object")
                        continue
                    _check_keys(err, sv, sw, ["id", "kind"], {"id", "kind", "preview"})
                    if "id" in sv and not (isinstance(sv["id"], str) and SNAKE.match(sv["id"])):
                        err.add(f"{sw}.id: must be snake_case")
                    if "kind" in sv and sv["kind"] not in SAVE_KINDS:
                        err.add(f"{sw}.kind: must be one of {sorted(SAVE_KINDS)}")
                    if "preview" in sv and not isinstance(sv["preview"], bool):
                        err.add(f"{sw}.preview: must be a boolean")
        checks = st.get("checks")
        if checks is not None:
            if not isinstance(checks, list):
                err.add(f"{where}.checks: must be an array")
            else:
                _check_unique(err, [c.get("id") for c in checks if isinstance(c, dict)], f"{where}.checks")
                for j, ck in enumerate(checks):
                    cw = f"{where}.checks[{j}]"
                    if not isinstance(ck, dict):
                        err.add(f"{cw}: must be an object")
                        continue
                    _check_keys(err, ck, cw, ["id", "label"], {"id", "label"})
                    if "id" in ck and not (isinstance(ck["id"], str) and SNAKE.match(ck["id"])):
                        err.add(f"{cw}.id: must be snake_case")
                    if "label" in ck and not _nonempty_str(ck["label"]):
                        err.add(f"{cw}.label: must be a non-empty string")
        if "maxCheckRetries" in st and (not _is_int(st["maxCheckRetries"]) or st["maxCheckRetries"] < 0):
            err.add(f"{where}.maxCheckRetries: must be an integer >= 0")
        if "canAsk" in st:
            _check_id_list(err, st["canAsk"], f"{where}.canAsk", input_ids, "input")


def validate_with_jsonschema(err: Errors, m: object, schema: dict) -> None:
    """Optional extra layer — only when the package is already installed."""
    try:
        import jsonschema  # type: ignore
    except Exception:  # noqa: BLE001 — missing package is the normal case
        return
    try:
        cls = jsonschema.validators.validator_for(schema)
        cls.check_schema(schema)
        validator = cls(schema)
    except Exception as e:  # noqa: BLE001
        err.add(f"schema is not a valid JSON Schema: {e}")
        return
    for ve in sorted(validator.iter_errors(m), key=lambda e: list(e.absolute_path)):
        loc = "/".join(str(p) for p in ve.absolute_path) or "(root)"
        err.add(f"schema: {loc}: {ve.message}")


def validate_file(path: Path, schema: dict) -> Errors:
    err = Errors(path)
    try:
        m = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        err.add(f"cannot parse JSON: {e}")
        return err
    skill_dir = path.resolve().parent
    validate_structure(err, m, skill_dir)
    validate_with_jsonschema(err, m, schema)
    # De-duplicate (schema + hand checks may name the same fault) while keeping order.
    seen: set[str] = set()
    err.items = [x for x in err.items if not (x in seen or seen.add(x))]
    return err


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Validate skills/*/manifest.json (recipe manifest v1).")
    ap.add_argument("--skills-dir", default=str(DEFAULT_SKILLS_DIR))
    ap.add_argument("--schema", default=str(DEFAULT_SCHEMA))
    ap.add_argument("manifests", nargs="*")
    args = ap.parse_args(argv)

    schema_path = Path(args.schema)
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        print(f"validate-manifests.py: cannot read schema {schema_path}: {e}", file=sys.stderr)
        return 2

    if args.manifests:
        paths = [Path(p) for p in args.manifests]
    else:
        skills_dir = Path(args.skills_dir)
        if not skills_dir.is_dir():
            print(f"validate-manifests.py: skills dir not found: {skills_dir}", file=sys.stderr)
            return 2
        paths = sorted(p for p in skills_dir.glob("*/manifest.json") if p.is_file())

    if not paths:
        print("validate-manifests.py: no manifests found (nothing to validate)")
        return 0

    failed = 0
    for p in paths:
        err = validate_file(p, schema)
        if err.items:
            failed += 1
            print(f"FAIL {p}")
            for line in err.items:
                print(f"  {line}")
        else:
            print(f"OK   {p}")
    if failed:
        print(f"validate-manifests.py: FAIL — {failed} of {len(paths)} manifest(s) invalid", file=sys.stderr)
        return 1
    print(f"validate-manifests.py: PASS — {len(paths)} manifest(s) valid")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
