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
        self, when: object, fields: dict[str, object], *, corrupt: bool = False, ask: bool = False,
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
ask_mode="$4"
cr_log() { printf '%s\n' "$*" >> "$dir/log"; }
cr_harness_heartbeat_start() { :; }
cr_harness_heartbeat_stop() { :; }
cr_h_run_with_timeout() { shift; "$@"; }
cr_engine_detect() { printf fixture; }
cr_engine_limit_detect() { return 1; }
cr_engine_limit_until() { :; }
cr_engine_run() {
  printf '%s\n' "$CFW_STEP_ID" >> "$dir/engine-runs"
  # The step asks for its script unless the harness staged it (the recipe's
  # voice_over step reads inputs/script/).
  if [[ "$ask_mode" == ask && ! -s "$3/inputs/script/script.md" ]]; then
    printf '%s' '{"inputId":"script","reason":"Need the script."}' > "$3/needs_input.json"
  fi
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
             str(self.harness), str(directory), "corrupt" if corrupt else "normal", "ask" if ask else "no"],
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

    def test_typed_answers_are_staged_as_inputs(self) -> None:
        # B13: Social sends a typed start/step answer only in `answers`. The step
        # reads inputs/<name>/, so the harness must write it there or the step
        # asks for the same input again (R-EPLF#1 -> R-EPLF#2).
        script = "Hook line.\nOne idea per sentence.  Keep this spacing.\nFollow for more."
        for answers in (
            [{"inputId": "script", "text": script}],
            {"script": script},
        ):
            with self.subTest(answers=answers):
                directory = self.assert_decision("always", {"answers": answers}, True)
                staged = directory / "steps/conditional/inputs/script"
                self.assertEqual([path.name for path in staged.iterdir()], ["script.md"])
                self.assertEqual((staged / "script.md").read_text(), script)
        # Two answers, an unrelated media input, and the later answer for one id wins.
        directory = self.assert_decision("always", {
            "inputs": [{"inputId": "clip", "items": [{"kind": "video", "url": "https://fixture.invalid/clip.mp4"}]}],
            "answers": [{"inputId": "voice_id", "text": "voice-1"}, {"inputId": "cta", "text": "Follow us"},
                        {"inputId": "voice_id", "text": "voice-2"}],
        }, True)
        inputs = directory / "steps/conditional/inputs"
        self.assertEqual(sorted(path.name for path in inputs.iterdir()), ["clip", "cta", "voice_id"])
        self.assertEqual((inputs / "voice_id/voice_id.md").read_text(), "voice-2")
        self.assertEqual((inputs / "cta/cta.md").read_text(), "Follow us")
        self.assertEqual((inputs / "clip/clip.mp4").read_text(), "fixture-media")

    def test_answers_do_not_override_inputs_or_stage_controls(self) -> None:
        # `inputs` is the owner's own value for that name; an answer fills gaps only.
        directory = self.assert_decision("always", {
            "inputs": {"topic": "from inputs"},
            "answers": [{"inputId": "topic", "text": "from answers"}],
        }, True)
        self.assertEqual((directory / "steps/conditional/inputs/topic/topic.md").read_text(), "from inputs")
        # `alternative` is a condition value, not a step input; blank answers stage nothing.
        directory = self.assert_decision({"alternative": "generate"}, {"answers": [
            {"inputId": "alternative", "text": "generate"},
            {"inputId": "script", "text": ""}, {"inputId": "cta", "text": " \n\t"},
        ]}, True)
        self.assertEqual(list((directory / "steps/conditional/inputs").iterdir()), [])
        # Legacy dict answers may carry non-text values; they are not staged.
        directory = self.assert_decision("always", {"answers": {"count": 3, "script": "ok"}}, True)
        self.assertEqual(sorted(path.name for path in (directory / "steps/conditional/inputs").iterdir()), ["script"])

    def test_answered_ask_is_released_and_the_next_claim_carries_it(self) -> None:
        # B13: the worker's claim was taken before the ask, so it holds no answer.
        # Rerunning the step in the same run would ask again (R-EPLF#2). The
        # attempt is handed back; the next claim's answers are staged for the step.
        result, events, directory = self.run_order("always", {"answers": []}, ask=True)
        self.assertEqual(result.returncode, 21, result.stderr)
        self.assertEqual([event["event"] for event in events], ["step_started", "needs_input", "attempt_released"])
        self.assertEqual(events[1]["extra"]["ask"]["inputId"], "script")
        self.assertEqual(events[2]["extra"], {"stepId": "conditional", "reason": "ask_answered"})
        self.assertEqual((directory / "engine-runs").read_text().splitlines(), ["conditional"])
        self.assertIn("ask at step conditional answered; released", (directory / "log").read_text())
        self.assertFalse((directory / "current-step.json").exists())
        # The next claim carries the answer: the step finds the script and does not ask.
        script = "Hook line.\nOne idea per sentence.\nFollow for more."
        result, events, directory = self.run_order(
            "always", {"answers": [{"inputId": "script", "text": script}]}, ask=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([event["event"] for event in events], ["step_started", "step_completed", "attempt_completed"])
        self.assertEqual((directory / "steps/conditional/inputs/script/script.md").read_text(), script)
        self.assertEqual((directory / "engine-runs").read_text().splitlines(), ["conditional"])

    def test_answer_name_cannot_leave_inputs(self) -> None:
        for name in ("../escape", "a/b", "..", "x..y"):
            with self.subTest(name=name):
                result, events, directory = self.run_order("always", {"answers": [{"inputId": name, "text": "t"}]})
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertFalse((directory / "engine-runs").exists())
                self.assertIn("input name refused", (directory / "log").read_text())
                self.assertEqual(sorted(path.name for path in directory.rglob("*.md")), [])
                self.assertNotIn("step_completed", [event["event"] for event in events])

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
