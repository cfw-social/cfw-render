#!/usr/bin/env python3
"""Read-only lookup for the pasted render identity. Prints paths, never log contents.

Usage: python3 render-debug.py < identity.json
Optional --log-dir and --scratch-dir override the worker's default locations.
No shell, network, settings-file sourcing, writes or third-party dependencies.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import sys


def identifier(value):
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,199}", value) is not None


def timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.timestamp() if parsed.tzinfo else None
    except (ValueError, OverflowError):
        return None


def contained_file(path, root):
    # Reject symlinks as evidence: a sibling retry or an outside file is not this log.
    try:
        current = path
        while current != root:
            if current.is_symlink() or current == current.parent:
                return False
            current = current.parent
        path.resolve().relative_to(root.resolve())
        return path.is_file()
    except (OSError, ValueError):
        return False


def locate(identity, log_dir, scratch_dir):
    if not isinstance(identity, dict):
        raise ValueError("Render identity must be a JSON object")
    oid = identity.get("orderId")
    result = {"directorLog": None, "scratchDirectory": None, "notes": []}
    notes = result["notes"]
    if not identifier(oid):
        notes.append("Order ID missing or invalid; no exact-attempt lookup is possible.")
        return result
    runs = Path(log_dir) / "runs"
    start, finish = timestamp(identity.get("startedAt")), timestamp(identity.get("finishedAt"))
    name = identity.get("directorLog")
    pattern = re.compile(re.escape(oid) + r"-([0-9]+)(?:-[A-Za-z0-9_]+)?\.out")
    if name is not None:
        # Recorded basename is authoritative. Never fall back to a different retry.
        match = pattern.fullmatch(name) if isinstance(name, str) else None
        if match and contained_file(runs / name, Path(log_dir)):
            result["directorLog"] = str(runs / name)
        else:
            notes.append("The recorded Director log is missing or invalid; no substitute selected.")
    elif start is not None and finish is not None and start <= finish:
        candidates = []
        if runs.is_dir():
            for path in runs.iterdir():
                match = pattern.fullmatch(path.name)
                if match and start <= int(match[1]) <= finish and contained_file(path, Path(log_dir)):
                    candidates.append(path)
        if len(candidates) == 1:
            result["directorLog"] = str(candidates[0])
            notes.append("Legacy log matched by exact order ID and attempt time window; confirm against the journal.")
        else:
            notes.append("No unique Director log in this attempt's time window; do not choose the newest retry.")
    else:
        notes.append("Attempt timestamps missing or invalid; no Director log guessed.")

    slug, aid = identity.get("brandSlug"), identity.get("attemptId")
    if identifier(slug) and identifier(aid):
        scratch = Path(scratch_dir)
        folder = scratch / slug / oid
        order_file = folder / "order.json"
        if contained_file(order_file, scratch):
            try:
                # This file can hold secrets. Read identity only; never return its contents.
                with order_file.open() as f:
                    order = json.load(f)
                if (order.get("id") == oid and (order.get("attempt") or {}).get("id") == aid
                        and ((order.get("taskOrder") or {}).get("brand") or {}).get("slug") == slug):
                    result["scratchDirectory"] = str(folder)
                    notes.append("Scratch identity matches. Step logs may append across retries; they are not isolated attempt evidence.")
                else:
                    notes.append("Scratch belongs to a different attempt or brand; do not use it.")
            except (OSError, ValueError, AttributeError):
                notes.append("Scratch identity could not be verified.")
        else:
            notes.append("Scratch is missing or outside the expected directory (failed scratch is kept about 48 hours).")
    else:
        notes.append("Attempt ID or brand slug unknown; scratch cannot be attributed to this attempt.")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    home = Path(os.environ.get("CFW_RENDER_HOME") or Path.home() / "CFW Render")
    parser.add_argument("--log-dir", default=os.environ.get("CFW_RENDER_LOG_DIR") or home / "logs")
    parser.add_argument("--scratch-dir", default=os.environ.get("CFW_RENDER_SCRATCH") or Path.home() / ".cfw-render/scratch")
    args = parser.parse_args()
    try:
        identity = json.load(sys.stdin)
        print(json.dumps(locate(identity, args.log_dir, args.scratch_dir), indent=2))
    except (OSError, ValueError) as error:
        # Do not echo input or file contents in errors.
        print("Could not look up render identity: " + type(error).__name__, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
