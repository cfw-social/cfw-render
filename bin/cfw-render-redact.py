#!/usr/bin/env python3
"""cfw-render-redact.py — [M3-06a] the ONE support-bundle redactor (stdin→stdout).

The Rust port lives in desktop/src-tauri/src/support.rs (`redact`); both are
checked against desktop/src-tauri/tests/fixtures/redact-{input,expected}.txt.
Rules are applied in order; each replacement is shaped so later rules can't
re-match it.
"""
import re
import sys

RULES = [
    (r"cfw_render_[A-Za-z0-9_]+", "cfw_render_[redacted]"),
    (r"cfw_[A-Za-z0-9_]{8,}", "cfw_[redacted]"),
    (r"sk-ant-[A-Za-z0-9_-]{16,}", "sk-ant-[redacted]"),
    (r"sk-[A-Za-z0-9_-]{16,}", "sk-[redacted]"),
    (r"AIza[0-9A-Za-z_-]{30,}", "AIza[redacted]"),
    (r"xai-[A-Za-z0-9]{20,}", "xai-[redacted]"),
    (r"Bearer [A-Za-z0-9._-]{16,}", "Bearer [redacted]"),
    (r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "[email]"),
    (r"([?&](?:token|key|sig|signature|auth|code|password)=)[^&\s#\"']*", r"\1[redacted]"),
    (r"/Users/[^/\s]+/", "/Users/[user]/"),
]
COMPILED = [(re.compile(p), r) for p, r in RULES]


def redact(text: str) -> str:
    for rx, rep in COMPILED:
        text = rx.sub(rep, text)
    return text


if __name__ == "__main__":
    data = sys.stdin.buffer.read().decode("utf-8", "replace")
    sys.stdout.write(redact(data))
