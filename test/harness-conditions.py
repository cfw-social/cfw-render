#!/usr/bin/env python3
"""Hermetic condition/staging regression: python3 test/harness-conditions.py.

Runs the real harness, parser, staging and report code. Only the engine, timer,
network transport and timeout wrapper are stubs. No services or process stops.
Social's claim-attempt.ts defines answers as [{inputId, text}], not {id, value}.
"""
from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class HarnessConditions(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="harness-conditions-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.harness = Path(__file__).resolve().parents[1] / "bin/cfw-render-harness.sh"
        self.commands = self.root / "commands"
        self.commands.mkdir()
        # No network clients, engines, sleep or process-stop tools on PATH.
        for name in ("bash", "cat", "cp", "date", "dirname", "mkdir", "mktemp",
                     "rm", "rmdir", "tr", "basename"):
            executable = shutil.which(name)
            self.assertIsNotNone(executable, name)
            (self.commands / name).symlink_to(str(executable))
        (self.commands / "python3").symlink_to(sys.executable)
        self.env = {
            "PATH": str(self.commands), "HOME": str(self.root),
            "TMPDIR": str(self.root), "LC_ALL": "C", "CFW_WORKER_ID": "fixture",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        self.case_number = 0

    def run_order(
        self, when: object, fields: dict[str, object], *, corrupt: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], list[dict], Path]:
        self.case_number += 1
        directory = self.root / str(self.case_number)
        directory.mkdir()
        (directory / "recipe").mkdir()
        order = {
            "id": "fixture-order", "attempt": {"id": "fixture-attempt"},
            "manifest": {"recipe": "fixture", "steps": [
                {"id": "conditional", "when": when, "saves": [], "checks": []},
            ]},
            **fields,
        }
        (directory / "order.json").write_text(json.dumps(order))
        script = r'''
set -euo pipefail
source "$1"
dir="$2"
cr_log() { printf '%s\n' "$*" >> "$dir/log"; }
cr_harness_heartbeat_start() { :; }
cr_harness_heartbeat_stop() { :; }
cr_h_run_with_timeout() { shift; "$@"; }
cr_engine_detect() { printf fixture; }
cr_engine_limit_detect() { return 1; }
cr_engine_limit_until() { :; }
cr_engine_run() {
  printf '%s\n' "$CFW_STEP_ID" >> "$dir/engine-runs"
  : > "$4"
}
cr_report_step() {
  python3 -c 'import json,sys; print(json.dumps({"event":sys.argv[1], "extra":json.loads(sys.argv[2])}))' "$5" "$6" >> "$dir/events"
  printf '%s' '{"ok":true,"directive":"continue"}'
}
curl() {
  local out="" previous="" arg
  for arg in "$@"; do
    if [[ "$previous" == "-o" ]]; then out="$arg"; fi
    previous="$arg"
  done
  [[ "$previous" == https://fixture.invalid/* && "$out" == "$dir/steps/conditional/inputs/"* ]] || return 99
  printf '%s\n' "$previous" >> "$dir/downloads"
  printf 'fixture-media' > "$out"
}
if [[ "$3" == corrupt ]]; then
  # Corrupt only after planning, to exercise evaluation failure in the loop.
  cr_h_wait_pause() { printf '{' > "$dir/order.json"; }
fi
rc=0
cr_harness_run "$dir/order.json" "$dir" "$dir/recipe" || rc=$?
exit "$rc"
'''
        result = subprocess.run(
            [str(self.commands / "bash"), "-c", script, "fixture",
             str(self.harness), str(directory), "corrupt" if corrupt else "normal"],
            env=self.env, capture_output=True, text=True, timeout=15,
        )
        events_path = directory / "events"
        events = [json.loads(line) for line in events_path.read_text().splitlines()] if events_path.exists() else []
        return result, events, directory

    def assert_decision(self, when: object, fields: dict[str, object], runs: bool) -> Path:
        result, events, directory = self.run_order(when, fields)
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = ["step_started", "step_completed", "attempt_completed"] if runs else ["step_skipped", "attempt_completed"]
        self.assertEqual([event["event"] for event in events], expected)
        engine_log = directory / "engine-runs"
        self.assertEqual(engine_log.read_text().splitlines() if engine_log.exists() else [], ["conditional"] if runs else [])
        self.assertNotIn("Traceback", result.stderr)
        if not runs:
            self.assertFalse((directory / "steps/conditional").exists())
        return directory

    def test_input_presence_list_and_dict(self) -> None:
        media = {"kind": "video", "url": "https://fixture.invalid/clip.mp4"}
        for inputs in (
            [{"inputId": "clip", "items": [media]}],
            {"clip": [media]}, {"clip": media},
            # Multiple entries for one input retain all items, even if one is empty.
            [{"inputId": "clip", "items": [media]}, {"inputId": "clip", "items": []}],
        ):
            with self.subTest(inputs=inputs):
                directory = self.assert_decision({"inputPresent": "clip"}, {"inputs": inputs}, True)
                self.assertEqual((directory / "steps/conditional/inputs/clip/clip.mp4").read_text(), "fixture-media")
                self.assertEqual((directory / "downloads").read_text().splitlines(), [media["url"]])
        for fields in (
            {}, {"inputs": None}, {"inputs": []}, {"inputs": {}},
            {"inputs": [{"inputId": "clip", "items": []}]},
            {"inputs": [{"inputId": "other", "items": [media]}]},
            {"inputs": {"other": [media]}},
            *({"inputs": {"clip": value}} for value in (None, "", [], {}, 0, False)),
        ):
            with self.subTest(fields=fields):
                self.assert_decision({"inputPresent": "clip"}, fields, False)

    def test_alternative_list_and_dict(self) -> None:
        for answers in (
            [{"inputId": "alternative", "text": "generate"}],
            [{"inputId": "other", "text": "upload"}, {"inputId": "alternative", "text": "generate"}],
            {"alternative": "generate"},
        ):
            with self.subTest(answers=answers):
                self.assert_decision({"alternative": "generate"}, {"answers": answers}, True)
        for fields in (
            {}, {"answers": None}, {"answers": []}, {"answers": {}},
            {"answers": [{"inputId": "alternative", "text": "upload"}]},
            {"answers": [{"inputId": "alternative", "text": ""}]},
            {"answers": [{"inputId": "other", "text": "generate"}]},
            {"answers": {"alternative": "upload"}},
            {"answers": {"alternative": ""}},
            {"answers": {"other": "generate"}},
        ):
            with self.subTest(fields=fields):
                self.assert_decision({"alternative": "generate"}, fields, False)

    def test_text_staging_keeps_zero_and_false(self) -> None:
        inputs = {"zero": 0, "off": False, "ready": True, "count": 3, "topic": "Hello\nworld"}
        directory = self.assert_decision("always", {"inputs": inputs}, True)
        for name, text in (("zero", "0"), ("off", "false"), ("ready", "true"), ("count", "3"), ("topic", "Hello\nworld")):
            self.assertEqual((directory / f"steps/conditional/inputs/{name}/{name}.md").read_text(), text)
        self.assert_decision({"inputPresent": "topic"}, {"inputs": inputs}, True)
        for empty in ([], {}):
            directory = self.assert_decision("always", {"inputs": empty}, True)
            self.assertEqual(list((directory / "steps/conditional/inputs").iterdir()), [])

    def assert_failed_condition(self, when: object, fields: dict[str, object], *, corrupt: bool = False) -> None:
        result, events, directory = self.run_order(when, fields, corrupt=corrupt)
        self.assertEqual(result.returncode, 30, result.stderr)
        self.assertEqual([event["event"] for event in events], ["step_failed", "attempt_failed"])
        for event in events:
            self.assertEqual(event["extra"]["stepId"], "conditional")
            self.assertIn("Condition evaluation failed", event["extra"]["message"])
        self.assertFalse((directory / "engine-runs").exists())
        self.assertFalse((directory / "steps/conditional").exists())
        self.assertIn("condition evaluation failed", (directory / "log").read_text())

    def test_malformed_collections_fail_instead_of_skip(self) -> None:
        for field, when in (("inputs", {"inputPresent": "clip"}), ("answers", {"alternative": "generate"})):
            for value in ("bad", 7, 0, False, [None], ["bad"], [{}], [{"inputId": ""}], [{"inputId": 1}]):
                with self.subTest(field=field, value=value):
                    self.assert_failed_condition(when, {field: value})
        for items in (None, {}, "bad"):
            with self.subTest(items=items):
                self.assert_failed_condition({"inputPresent": "clip"}, {"inputs": [{"inputId": "clip", "items": items}]})
        for answer in (
            {"inputId": "alternative"}, {"inputId": "alternative", "text": None},
            {"inputId": "alternative", "text": []}, {"id": "alternative", "value": "generate"},
        ):
            with self.subTest(answer=answer):
                self.assert_failed_condition({"alternative": "generate"}, {"answers": [answer]})

    def test_json_parse_error_reports_failure(self) -> None:
        self.assert_failed_condition({"inputPresent": "clip"}, {"inputs": {}}, corrupt=True)
        self.assert_failed_condition({"alternative": "generate"}, {"answers": {}}, corrupt=True)


if __name__ == "__main__":
    unittest.main()
