#!/usr/bin/env python3
"""Vendor the reviewed render guide from a local cfw-social checkout. Never fetch it."""
import argparse
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "src/lib/agent-library/content/render-debug.md"
URL = "https://app.cfw.social/assets/guides/render-debug.md"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail on missing or drifting snapshot")
    args = parser.parse_args()
    social = Path(os.environ.get("CFW_SOCIAL_DIR", str(ROOT.parent / "cfw-social")))
    source = social / SOURCE
    if not source.is_file():
        parser.exit(1, "Canonical render guide is missing; set CFW_SOCIAL_DIR to the reviewed cfw-social checkout. Nothing downloaded.\n")
    body = source.read_bytes()
    if not body.startswith(b"# Debug an existing CFW render\n"):
        parser.exit(1, "Source is not the expected render guide. Nothing changed.\n")
    record = {"schemaVersion": 1, "documents": [{"path": "lib/render-debug.md", "url": URL,
              "source": SOURCE, "sha256": hashlib.sha256(body).hexdigest()}]}
    targets = {ROOT / "lib/render-debug.md": body,
               ROOT / "config/agent-guides.json": (json.dumps(record, indent=2) + "\n").encode()}
    if args.check:
        drift = [str(path.relative_to(ROOT)) for path, content in targets.items()
                 if not path.is_file() or path.read_bytes() != content]
        if drift:
            parser.exit(1, "Agent guide snapshot drift: " + ", ".join(drift) + "\n")
        print("Agent guide snapshot matches the canonical library.")
        return
    for path, content in targets.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    print("Updated the bundled render guide and its source checksum. Review and commit both files.")


if __name__ == "__main__":
    main()
