#!/usr/bin/env python3
"""Local recipe checkpoints and attempt-scoped write-ahead report outbox.

Only non-secret identities, declared saves, check results and reports are stored.
Writes are locked, fsynced and atomically replaced. No network or third-party deps.
"""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
import time
import uuid

EXT = {"video": "mp4", "image": "png", "audio": "mp3", "json": "json", "text": "md"}
ID = re.compile(r"[a-z][a-z0-9_]{0,119}\Z")
TOKEN = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,199}\Z")


class Blocked(Exception):
    pass


def require(ok):
    if not ok:
        raise Blocked()


def contained(root, relative):
    """Reject symlinks, including parent components, even if they point inside."""
    rel = Path(relative)
    require(not rel.is_absolute() and rel.parts and all(p not in (".", "..") for p in rel.parts))
    path = root / rel
    for parent in [root, *root.parents]:
        require(not parent.is_symlink())
    current = root
    for part in rel.parts:
        current = current / part
        require(not current.is_symlink())
    require(path.resolve().is_relative_to(root.resolve()))
    return path


def read_json(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as f:
        require(stat.S_ISREG(os.fstat(f.fileno()).st_mode))
        return json.load(f)


def atomic_json(path, value):
    fd, tmp = tempfile.mkstemp(prefix=".checkpoint-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(value, f, separators=(",", ":"))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        dfd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def identity(order, worker):
    m, c = order["manifest"], order["checkpoint"]
    # No combined protocol exists yet. Presence (even null) must not downgrade
    # a bounded request into a whole-recipe run.
    require(not any(k in order for k in ("stageRange", "stopAfterStepId", "stageRangeCompleted")))
    require("stageRange" not in (order.get("taskOrder") or {}))
    require(not order.get("savedOutputs"))
    require(c["mode"] == "local-v1" and c["action"] in ("start", "resume", "finalize-only"))
    require(type(c["generation"]) is int and c["generation"] >= 0)
    require(TOKEN.fullmatch(order["id"]) and worker and order.get("brandId"))
    require(order.get("recipeVersion", m["recipeVersion"]) == m["recipeVersion"])
    return {"orderId": order["id"], "brandId": order["brandId"], "workerId": worker,
            "recipe": m["recipe"], "recipeVersion": m["recipeVersion"],
            "generation": c["generation"],
            "manifestHash": hashlib.sha256(json.dumps(m, sort_keys=True).encode()).hexdigest()}


def steps_of(order):
    steps = order["manifest"]["steps"]
    require(len({s["id"] for s in steps}) == len(steps))
    for s in steps:
        require(ID.fullmatch(s["id"]))
        saves = s.get("saves", [])
        require(len({v["id"] for v in saves}) == len(saves))
        for v in saves:
            require(ID.fullmatch(v["id"]) and v["kind"] in EXT)
    return [s for s in steps if s.get("runsOn", "computer") == "computer"]


def output(root, step, save):
    name = save["id"] + "." + EXT[save["kind"]]
    relative = "steps/" + step["id"] + "/saves/" + name
    path = contained(root, relative)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as f:
        before = os.fstat(f.fileno())
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= 9007199254740991)
        h = hashlib.sha256()
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
        after = os.fstat(f.fileno())
        require((before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns))
        os.fsync(f.fileno())
    return {"saveId": save["id"], "fileName": name, "kind": save["kind"],
            "bytes": before.st_size, "checksum": "sha256:" + h.hexdigest(), "path": relative}


def final_refs(order):
    steps = {s["id"]: s for s in steps_of(order)}
    refs = order["manifest"].get("finalOutputs", [])
    require(0 < len(refs) <= 30 and refs[0]["role"] == "deliverable")
    seen, roles = set(), set()
    for ref in refs:
        key = (ref["stepId"], ref["saveId"])
        role = ref["role"]
        require(key not in seen and role in ("deliverable", "poster", "captions"))
        require(role == "deliverable" or role not in roles)
        seen.add(key)
        roles.add(role)
        step = steps[ref["stepId"]]
        save = next(s for s in step.get("saves", []) if s["id"] == ref["saveId"])
        require(step.get("when", "always") == "always")
        require(save["kind"] in ({"json"} if role == "captions" else
                {"image"} if role == "poster" else {"video", "image", "audio"}))
    # The current uploader supports one video + poster, ordered images, or audio.
    # Reject ambiguous mixed outputs rather than silently reclassify a slide.
    kinds = [next(v["kind"] for v in steps[r["stepId"]]["saves"] if v["id"] == r["saveId"])
             for r in refs if r["role"] == "deliverable"]
    require(all(k == "image" for k in kinds) or len(kinds) == 1)
    require("poster" not in roles or kinds == ["video"])
    return refs


def final_outputs(root, order, steps, state):
    require(len(prefix(root, steps, state)) == len(steps))
    result = []
    for ref in final_refs(order):
        record = state["stages"][ref["stepId"]]
        require(record["event"] == "step_completed")
        item = next(o for o in record["outputs"] if o["saveId"] == ref["saveId"])
        result.append({"id": item["saveId"], "path": str(contained(root, item["path"])),
                       "role": ref["role"], "kind": item["kind"]})
    return result


def valid_checks(step, checks):
    require(isinstance(checks, list))
    require(len({c["id"] for c in checks}) == len(checks))
    require(all(c.get("passed") is True for c in checks))
    require({c["id"] for c in step.get("checks", [])} <= {c["id"] for c in checks})


def validate_stage(root, step, record):
    require(record["event"] in ("step_completed", "step_skipped"))
    if record["event"] == "step_skipped":
        require(step.get("when", "always") != "always" and not record["outputs"])
        return
    valid_checks(step, record["checks"])
    require([output(root, step, v) for v in step.get("saves", [])] == record["outputs"])


def prefix(root, steps, state):
    result = []
    for step in steps:
        record = state["stages"].get(step["id"])
        if record is None:
            break
        validate_stage(root, step, record)
        result.append(step)
    return result


def report_extra(sid, record):
    if record["event"] == "step_skipped":
        return {"stepId": sid, "message": "condition not met"}
    return {"stepId": sid, "checks": record["checks"],
            "localOutputs": [{k: v for k, v in o.items() if k != "path"} for o in record["outputs"]]}


def import_revision(root, order, worker, steps, state):
    resume = (order.get("taskOrder") or {}).get("resume") or {}
    source_id = resume.get("fromOrderId", "")
    require(TOKEN.fullmatch(source_id) and source_id != order["id"])
    source = contained(root.parent, source_id)
    old = read_json(contained(source, "checkpoint.json"))
    expected = dict(state["identity"], orderId=source_id, generation=resume["fromGeneration"])
    require(old["identity"] == expected)
    ids = [s["id"] for s in steps]
    stop = ids.index(order["resumeFromStepId"])
    require(stop <= ids.index(resume["fromStepId"]))
    require(len(prefix(source, steps[:stop], old)) == stop)
    for step in steps[:stop]:
        record = old["stages"][step["id"]]
        for item in record["outputs"]:
            src = contained(source, item["path"])
            dst = contained(root, item["path"])
            dst.parent.mkdir(parents=True, exist_ok=True)
            with os.fdopen(os.open(src, os.O_RDONLY | os.O_NOFOLLOW), "rb") as f:
                with os.fdopen(os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as out:
                    shutil.copyfileobj(f, out)
                    out.flush()
                    os.fsync(out.fileno())
        validate_stage(root, step, record)
        state["stages"][step["id"]] = record


@contextlib.contextmanager
def locked(root):
    lock = contained(root, ".checkpoint.lock")
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def live_job(root):
    active = contained(root, ".active.json")
    if not active.exists():
        return False
    try:
        pid = read_json(active)["pid"]
        require(type(pid) is int and pid > 1)
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except (PermissionError, ValueError, KeyError, TypeError, Blocked):
        return True  # Uncertain ownership never permits deletion.


def remove_entry(path):
    # Never follow symlinks, including when removing transient engine files.
    if path.is_symlink() or not path.is_dir():
        path.unlink()
    else:
        shutil.rmtree(path)


def scrub_transients(root):
    """Keep checkpoint data and saves only; claims/prompts/logs may hold keys.

    Saves remain even if checkpoint metadata is corrupt: cleanup must not turn
    a recoverable metadata problem into silent loss of completed paid work.
    """
    for path in root.iterdir():
        if path.name in ("checkpoint.json", ".checkpoint.lock", ".activity.json", ".active.json",
                         ".delivery-started", ".retain-artifacts", ".outcome"):
            continue
        if path.name.startswith("retired-") and path.is_dir() and not path.is_symlink():
            scrub_transients(path)
        elif path.name == "steps" and path.is_dir() and not path.is_symlink():
            for step in path.iterdir():
                if step.is_dir() and not step.is_symlink() and ID.fullmatch(step.name):
                    for child in step.iterdir():
                        if child.name != "saves" or child.is_symlink():
                            remove_entry(child)
                else:
                    remove_entry(step)
        else:
            remove_entry(path)


def lifecycle(command, root, args):
    with locked(root):
        active = contained(root, ".active.json")
        activity = contained(root, ".activity.json")
        if command == "active":
            require(not live_job(root))
            pid = int(args[0])
            require(pid > 1)
            os.kill(pid, 0)
            atomic_json(active, {"pid": pid})
        elif command == "finish":
            # Only the recorded owning job may remove its admission marker.
            require(read_json(active)["pid"] == int(args[1]))
            if args[0] == "local-v1":
                scrub_transients(root)
            if active.exists():
                active.unlink()
        else:
            raise Blocked()
        atomic_json(activity, {"at": time.time()})


def janitor(scratch):
    """Two-day STOPPED retention, under the same lock as job admission.

    The drainer's tick lock serializes claims and this sweep. The active marker
    also protects an in-flight job when this helper is called independently.
    """
    cutoff = time.time() - 48 * 60 * 60
    for brand in scratch.iterdir():
        if brand.is_symlink() or not brand.is_dir():
            continue
        for root in brand.iterdir():
            if root.is_symlink() or not root.is_dir():
                continue
            try:
                # Capture directory age BEFORE opening/creating the lock file.
                last = root.stat().st_mtime
                with locked(root):
                    if live_job(root) or any((root / name).exists() for name in
                                             (".delivery-started", ".retain-artifacts")):
                        continue
                    for name, field in ((".activity.json", "at"), ("checkpoint.json", "activityAt")):
                        path = contained(root, name)
                        if path.exists():
                            last = max(last, float(read_json(path)[field]))
                    if last < cutoff:
                        shutil.rmtree(root)
            except (OSError, ValueError, KeyError, TypeError, Blocked):
                # Malformed state or unsafe paths need inspection, not deletion.
                continue


def main():
    command, directory, *args = sys.argv[1:]
    root = Path(directory).absolute()
    # macOS exposes its temporary directories through root-owned OS aliases.
    # Allow only these exact aliases, never a caller-created scratch/save link.
    system_aliases = {Path("/var"): Path("/private/var"), Path("/tmp"): Path("/private/tmp")}
    for path in [root, *root.parents]:
        if path.is_symlink():
            require(sys.platform == "darwin" and path in system_aliases
                    and path.lstat().st_uid == 0 and path.resolve() == system_aliases[path])
    if command == "active":
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root = root.resolve()
    if command == "janitor":
        janitor(root)
        return
    if command in ("active", "finish"):
        lifecycle(command, root, args)
        return
    worker, *args = args
    with locked(root):
        order = read_json(contained(root, "order.json"))
        ident = identity(order, worker)
        steps = steps_of(order)
        sid_map = {s["id"]: s for s in steps}
        state_path = contained(root, "checkpoint.json")
        state = read_json(state_path) if state_path.exists() else None
        attempt = order["attempt"]["id"]
        require(TOKEN.fullmatch(attempt))
        if command == "init":
            final_refs(order)  # Reject ambiguous delivery before any engine runs.
            if state is None or state["identity"] != ident:
                action = order["checkpoint"]["action"]
                if state is not None:
                    # Only an explicitly fresh, newer generation may supersede local bytes.
                    require(action == "start" and state["identity"]["orderId"] == ident["orderId"]
                            and state["identity"]["generation"] < ident["generation"])
                    archive = contained(root, "retired-" + uuid.uuid4().hex)
                    archive.mkdir(mode=0o700)
                    os.replace(state_path, archive / "checkpoint.json")
                    if contained(root, "steps").exists():
                        os.replace(root / "steps", archive / "steps")
                state = {"identity": ident, "stages": {}, "attempts": {}}
                if action != "start":
                    import_revision(root, order, worker, steps, state)
            done = prefix(root, steps, state)
            claimed = order.get("resumeFromStepId")
            required = len(steps) if order["checkpoint"]["action"] == "finalize-only" else (
                [s["id"] for s in steps].index(claimed) if claimed else 0)
            require(len(done) >= required)
            state["attempts"].setdefault(attempt, {"seq": 0, "pending": [], "acked": []})
        else:
            require(state is not None and state["identity"] == ident and attempt in state["attempts"])
        outbox = state["attempts"][attempt]
        result = None
        if command == "final":
            result = final_outputs(root, order, steps, state)
        elif command == "restore":
            result = [str(root / o["path"]) for s in prefix(root, steps, state)
                      for o in state["stages"][s["id"]]["outputs"]]
        elif command == "cached":
            sid = args[0]
            done = {s["id"] for s in prefix(root, steps, state)}
            require(sid not in state["stages"] or sid in done)
            record = state["stages"].get(sid)
            if record:
                validate_stage(root, sid_map[sid], record)
                result = {"event": record["event"], "extra": report_extra(sid, record)}
        elif command == "prepare":
            sid = args[0]
            require(sid in sid_map and sid not in state["stages"])
            for name in ("saves", "prior"):
                path = contained(root, "steps/" + sid + "/" + name)
                if path.exists():
                    os.replace(path, path.with_name("incomplete-" + name + "-" + uuid.uuid4().hex))
                path.mkdir(parents=True, mode=0o700)
        elif command in ("save", "skip"):
            sid = args[0]
            step = sid_map[sid]
            require(all(s["id"] in state["stages"] for s in steps[:steps.index(step)]))
            checks = json.loads(args[1]) if command == "save" else []
            # Persist only the check identity and outcome, never engine output/logs.
            checks = [{"id": c["id"], "passed": c["passed"]} for c in checks]
            record = {"event": "step_completed" if command == "save" else "step_skipped",
                      "checks": checks, "outputs": [output(root, step, v) for v in step.get("saves", [])]
                      if command == "save" else [], "acknowledgedAttempts": []}
            validate_stage(root, step, record)
            state["stages"][sid] = record
            result = report_extra(sid, record)
        elif command == "enqueue":
            event, extra = args[0], json.loads(args[1])
            # Idempotent durable completions: restart within one attempt never adds duplicates.
            existing = next((e for e in outbox["pending"] + outbox["acked"]
                             if e["event"] == event and e["extra"] == extra), None)
            if event not in ("step_completed", "step_skipped", "attempt_completed") or not existing:
                outbox["seq"] += 1
                outbox["pending"].append({"attemptId": attempt, "seq": outbox["seq"], "event": event, "extra": extra})
        elif command == "pending":
            result = outbox["pending"]
        elif command == "ack":
            seq = int(args[0])
            require(outbox["pending"] and outbox["pending"][0]["seq"] == seq)
            report = outbox["pending"].pop(0)
            if report["event"] in ("step_completed", "step_skipped", "attempt_completed"):
                outbox["acked"].append(report)
                record = state["stages"].get(report["extra"].get("stepId"))
                if record and attempt not in record["acknowledgedAttempts"]:
                    record["acknowledgedAttempts"].append(attempt)
        elif command not in ("init",):
            raise Blocked()
        state["activityAt"] = time.time()
        atomic_json(state_path, state)
        print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except (Blocked, OSError, ValueError, KeyError, TypeError, IndexError, AttributeError, StopIteration):
        # Deliberately omit paths and raw exceptions from owner-visible failures.
        print("Local checkpoint is missing, changed or incompatible. Restart the entire recipe to continue.", file=sys.stderr)
        sys.exit(31)
