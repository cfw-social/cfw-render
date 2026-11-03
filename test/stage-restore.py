#!/usr/bin/env python3
"""Hermetic resume-restore regression (B27): python3 test/stage-restore.py.

Runs the real `cfw-render-stage.py restore` against a loopback server that acts
like media.cfw.social behind Cloudflare: urllib's default "Python-urllib/3.x"
User-Agent gets 403 "error code: 1010", any other agent gets the file. No
network beyond 127.0.0.1, no services, no process stops.
"""
from __future__ import annotations

import hashlib
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

STAGE = Path(__file__).resolve().parents[1] / "bin/cfw-render-stage.py"

FILES = {
    "/brands/b/renders/o/source_video.mp4": b"\x00\x00\x00\x18ftypmp42" + b"v" * 4096,
    "/brands/b/renders/o/format_analysis.json": b'{"beats": 3}\n',
    "/brands/b/renders/o/adapted_script.md": b"# Script\nHello.\n",
}


class MediaHandler(BaseHTTPRequestHandler):
    agents: list[str] = []

    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        agent = self.headers.get("User-Agent") or ""
        type(self).agents.append(agent)
        if agent.startswith("Python-urllib"):
            self.reply(403, b"error code: 1010\n")
        elif self.path == "/redirect/format_analysis.json":
            self.send_response(302)
            self.send_header("Location", "/brands/b/renders/o/format_analysis.json")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path in FILES:
            self.reply(200, FILES[self.path])
        else:
            self.reply(404, b"not found\n")

    def reply(self, code: int, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args: object) -> None:
        pass


def sha(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


class StageRestore(unittest.TestCase):
    def setUp(self) -> None:
        MediaHandler.agents = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), MediaHandler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        temporary = tempfile.TemporaryDirectory(prefix="stage-restore-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def restore(self, saved: list[dict]) -> tuple[subprocess.CompletedProcess[str], Path]:
        order_dir = self.root / "order"
        order_dir.mkdir()
        order = {
            "id": "fixture-order", "attempt": {"id": "attempt-2"},
            "resumeFromStepId": "generate_narration",
            "manifest": {"recipe": "fixture", "steps": [
                {"id": "ingest_reference", "saves": [
                    {"id": "source_video", "kind": "video"}, {"id": "format_analysis", "kind": "json"}]},
                {"id": "adapt_script", "saves": [{"id": "adapted_script", "kind": "text"}]},
                {"id": "generate_narration", "saves": [{"id": "narration", "kind": "video"}]},
            ]},
            "savedOutputs": saved,
        }
        order_file = self.root / "order.json"
        order_file.write_text(json.dumps(order))
        result = subprocess.run(
            [sys.executable, str(STAGE), "restore", str(order_file), str(order_dir), "", self.base],
            capture_output=True, text=True, timeout=60, check=False)
        return result, order_dir

    def saved(self, step: str, save: str, path: str, data: bytes) -> dict:
        return {"stepId": step, "saveId": save, "url": self.base + path, "checksum": sha(data)}

    def test_restores_every_save_past_a_cloudflare_style_agent_check(self) -> None:
        # Social lists a step's saves newest first; format_analysis was first live.
        saved = [
            self.saved("ingest_reference", "format_analysis", "/brands/b/renders/o/format_analysis.json",
                       FILES["/brands/b/renders/o/format_analysis.json"]),
            self.saved("ingest_reference", "source_video", "/brands/b/renders/o/source_video.mp4",
                       FILES["/brands/b/renders/o/source_video.mp4"]),
            self.saved("adapt_script", "adapted_script", "/brands/b/renders/o/adapted_script.md",
                       FILES["/brands/b/renders/o/adapted_script.md"]),
        ]
        result, order_dir = self.restore(saved)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        restored = json.loads(result.stdout)
        self.assertEqual([r["id"] for r in restored], ["format_analysis", "source_video", "adapted_script"])
        for step, name, path in (("ingest_reference", "format_analysis.json", "format_analysis.json"),
                                 ("ingest_reference", "source_video.mp4", "source_video.mp4"),
                                 ("adapt_script", "adapted_script.md", "adapted_script.md")):
            got = (order_dir / "steps" / step / "saves" / name).read_bytes()
            self.assertEqual(got, FILES["/brands/b/renders/o/" + path])
        self.assertTrue(MediaHandler.agents)
        self.assertFalse([a for a in MediaHandler.agents if a.startswith("Python-urllib")], MediaHandler.agents)

    def test_redirected_request_keeps_the_worker_agent(self) -> None:
        data = FILES["/brands/b/renders/o/format_analysis.json"]
        result, order_dir = self.restore([
            {"stepId": "ingest_reference", "saveId": "format_analysis",
             "url": self.base + "/redirect/format_analysis.json", "checksum": sha(data)}])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((order_dir / "steps/ingest_reference/saves/format_analysis.json").read_bytes(), data)
        self.assertEqual(len(MediaHandler.agents), 2)  # the 302 and the file
        self.assertFalse([a for a in MediaHandler.agents if a.startswith("Python-urllib")], MediaHandler.agents)

    def test_failed_download_names_the_save_and_status_but_never_the_url(self) -> None:
        result, order_dir = self.restore([
            {"stepId": "ingest_reference", "saveId": "format_analysis",
             "url": self.base + "/brands/b/renders/o/gone.json", "checksum": sha(b"x")}])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout), {"missing": "ingest_reference/format_analysis"})
        self.assertIn("ingest_reference/format_analysis: HTTP 404", result.stderr)
        self.assertNotIn("127.0.0.1", result.stdout + result.stderr)
        self.assertNotIn("gone.json", result.stdout + result.stderr)
        self.assertFalse((order_dir / "steps/ingest_reference/saves/format_analysis.json").exists())

    def test_checksum_mismatch_still_refuses(self) -> None:
        result, _ = self.restore([
            self.saved("ingest_reference", "format_analysis", "/brands/b/renders/o/format_analysis.json", b"other")])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout), {"missing": "ingest_reference/format_analysis"})
        self.assertIn("ingest_reference/format_analysis: ValueError", result.stderr)


if __name__ == "__main__":
    unittest.main()
