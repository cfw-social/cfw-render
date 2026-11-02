#!/usr/bin/env python3
"""Manifest bounds and contained, verified resume downloads for the shell harness."""

from __future__ import annotations

import hashlib
import json
import re
import sys
import tempfile
import time
import urllib.request
from email.message import Message
from http.client import HTTPException
from pathlib import Path
from typing import BinaryIO
from urllib.parse import urlsplit

# media.cfw.social sits behind Cloudflare, whose browser integrity check answers
# urllib's default "Python-urllib/3.x" with 403 (error 1010). Name the worker
# instead, on the first request and on every redirect (B27).
USER_AGENT = "cfw-render"


def save_extension(kind: str) -> str:
    return {"video": "mp4", "image": "png", "audio": "mp3", "json": "json", "text": "md"}.get(kind, "bin")


def identifier(value: object) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[a-zA-Z0-9_-]+", value):
        raise ValueError("invalid manifest identifier")
    return value


def plan(order: dict) -> dict:
    steps = order["manifest"]["steps"]
    ids = [identifier(s["id"]) for s in steps]
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate step")
    for step in steps:
        saves = [identifier(s["id"]) for s in step.get("saves", [])]
        if len(saves) != len(set(saves)):
            raise ValueError("duplicate save")
    computer = [s["id"] for s in steps if s.get("runsOn", "computer") == "computer"]
    if not computer:
        raise ValueError("no computer steps")
    task_range = (order.get("taskOrder") or {}).get("stageRange")
    stage_range = order.get("stageRange", task_range)
    if task_range is not None and stage_range != task_range:
        raise ValueError("inconsistent stage range")
    first, last = 0, len(computer) - 1
    if stage_range is not None:
        first = computer.index(stage_range["fromStepId"])
        last = computer.index(stage_range["toStepId"])
    stop = order.get("stopAfterStepId")
    if stop is not None:
        stop_index = computer.index(stop)
        if stage_range is not None and stop_index != last:
            raise ValueError("inconsistent stop bound")
        last = stop_index
    if first > last:
        raise ValueError("reversed stage range")
    resume = order.get("resumeFromStepId")
    # Legacy claims may resume at a server step (for example research).
    # Resolve its manifest position, but only select computer steps at/after it.
    # index() deliberately rejects unknown resume IDs before any execution.
    resume_index = ids.index(resume) if resume else 0
    resume_computer = sum(s.get("runsOn", "computer") == "computer" for s in steps[:resume_index])
    start = max(first, resume_computer)
    completed = order.get("stageRangeCompleted", False)
    if not isinstance(completed, bool) or (completed and stage_range is None):
        raise ValueError("invalid range completion")
    # A resume beyond the endpoint means no work, never a clamp BACK to the end.
    start = min(start, last + 1)
    if completed:
        start = last + 1
    return {"stepIds": computer[start:last + 1], "endpoint": computer[last],
            "restoreBefore": ids.index(computer[start]) if start < len(computer) else len(ids),
            "nonfinal": last < len(computer) - 1,
            "resume": computer[start] if start <= last else "", "completed": start > last}


def contained(root: Path, relative: Path) -> Path:
    path = root / relative
    # Reject symlinks even when they happen to point back inside this order.
    for part in (path, *path.parents):
        if part == root:
            break
        if part.is_symlink():
            raise ValueError("symlink in saved output path")
    if not path.resolve().is_relative_to(root):
        raise ValueError("saved output outside order directory")
    return path


def approved_url(url: str, media_base: str = "", test_base: str = "") -> bool:
    try:
        parsed = urlsplit(url)
        if parsed.username or parsed.password or parsed.fragment:
            return False
        if any(ord(c) <= 32 or ord(c) == 127 for c in url):
            return False
        if test_base:
            test = urlsplit(test_base)
            if (test.scheme == "http" and test.hostname == "127.0.0.1"
                    and test.port and parsed.scheme == "http"
                    and parsed.netloc == test.netloc):
                return True
        hosts = {"media.cfw.social"}
        if media_base:
            base = urlsplit(media_base)
            if base.scheme != "https" or base.username or base.password or base.port not in (None, 443):
                return False
            hosts.add(base.hostname)
        return parsed.scheme == "https" and parsed.port in (None, 443) and parsed.hostname in hosts
    except (ValueError, TypeError):
        return False


class MediaRedirect(urllib.request.HTTPRedirectHandler):
    def __init__(self, media_base: str, test_base: str) -> None:
        super().__init__()
        self.media_base = media_base
        self.test_base = test_base

    def redirect_request(
        self, req: urllib.request.Request, fp: BinaryIO, code: int,
        msg: str, headers: Message, newurl: str,
    ) -> urllib.request.Request | None:
        if not approved_url(newurl, self.media_base, self.test_base):
            raise ValueError("unapproved saved output redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class SavedOutputError(ValueError):
    def __init__(self, missing: str) -> None:
        super().__init__("unusable saved output")
        self.missing = missing


def restore(order: dict, root: Path, media_base: str = "", test_base: str = "") -> list[dict]:
    bounds = plan(order)
    root = root.resolve()
    known = {}
    for index, step in enumerate(order["manifest"]["steps"]):
        for save in step.get("saves", []):
            known[(step["id"], save["id"])] = (index, save_extension(save.get("kind", "")))
    selected = []
    seen = set()
    # Validate the entire list BEFORE making any requests or creating paths.
    for saved in order.get("savedOutputs") or []:
        key = (identifier(saved["stepId"]), identifier(saved["saveId"]))
        if key not in known or key in seen:
            raise ValueError("unknown or duplicate saved output")
        seen.add(key)
        index, extension = known[key]
        if index >= bounds["restoreBefore"]:
            continue  # never restore stale outputs at/after the actual resume point
        url = saved["url"]
        if not approved_url(url, media_base, test_base):
            raise ValueError("unapproved saved output URL")
        checksum = saved.get("checksum") or ""
        algo, digest = "sha256", ""
        if checksum:
            checksum = checksum.lower()
            if ":" in checksum:
                algo, digest = checksum.split(":", 1)
            else:
                digest = checksum
                algo = "md5" if len(digest) == 32 else "sha256"
            size = {"sha256": 64, "md5": 32}.get(algo)
            if size is None or not re.fullmatch(r"[0-9a-f]{%d}" % size, digest):
                raise ValueError("invalid saved output checksum")
        relative = Path("steps") / key[0] / "saves" / f"{key[1]}.{extension}"
        contained(root, relative)
        selected.append((key, relative, url, algo, digest))
    opener = urllib.request.build_opener(MediaRedirect(media_base, test_base))
    opener.addheaders = [("User-Agent", USER_AGENT)]
    restored = []
    for key, relative, url, algo, digest in selected:
        dest = contained(root, relative)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest = contained(root, relative)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=dest.parent, delete=False) as output:
                temporary = Path(output.name)
                hasher = hashlib.new(algo)
                size = 0
                deadline = time.monotonic() + 600
                with opener.open(url, timeout=60) as response:
                    while chunk := response.read(1024 * 1024):
                        size += len(chunk)
                        if size > 2 * 1024**3 or time.monotonic() > deadline:
                            raise ValueError("saved output download limit")
                        hasher.update(chunk)
                        output.write(chunk)
            if not size or (digest and hasher.hexdigest() != digest):
                raise ValueError("empty saved output or checksum mismatch")
            temporary.replace(contained(root, relative))
            restored.append({"id": key[1], "url": url, "path": str(dest)})
        except (ValueError, OSError, HTTPException) as error:
            raise SavedOutputError("/".join(key)) from error
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    return restored


def main() -> int:
    try:
        command, order_file, directory = sys.argv[1:4]
        with Path(order_file).open() as source:
            order = json.load(source)
        root = Path(directory)
        if command == "plan":
            result = plan(order)
        elif command == "restore":
            result = restore(order, root, *sys.argv[4:6])
        else:
            raise ValueError("invalid command")
        print(json.dumps(result))
        return 0
    except (ValueError, KeyError, TypeError, AttributeError, OSError, HTTPException) as error:
        print(json.dumps({"missing": error.missing if isinstance(error, SavedOutputError) else "invalid_output"}))
        # Do not print URLs, signed query strings, claim data or exception bodies.
        # The save name and the HTTP status (or error class) are safe and say why.
        reason = ""
        if isinstance(error, SavedOutputError):
            cause = error.__cause__
            code = getattr(cause, "code", None)
            reason = f" ({error.missing}: {'HTTP %d' % code if isinstance(code, int) else type(cause).__name__})"
        print("cfw-render: invalid stage bounds or unusable saved outputs" + reason, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
