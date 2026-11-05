#!/usr/bin/env python3
"""Hermetic condition/staging regression: python3 test/harness-conditions.py.

Runs the real harness, parser, staging and report code. Only the engine, timer,
network transport and timeout wrapper are stubs. No services or process stops.
Social's claim-attempt.ts defines answers as [{inputId, text}], not {id, value}.
"""
from __future__ import annotations

import importlib.util
import json
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

# One scale for this file's load wait. 15s expired while the bound suite shared the machine.
LOAD_WAIT_SCALE = 8
# Independent orders share no files, so a few run at once. The cap stays small
# so a loaded merge runner still finishes.
HARNESS_WORKERS = 4
TOOL_NAMES = ("bash", "cat", "cp", "date", "dirname", "mkdir", "mktemp",
              "rm", "rmdir", "tr", "basename")
# Same search as test/gate-suite.test.mjs. /bin/bash is 3.2 and breaks the harness.
BASH4_DIRS = ("/opt/homebrew/bin", "/usr/local/bin")


def real_bash() -> str:
    for directory in BASH4_DIRS:
        candidate = Path(directory) / "bash"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    found = shutil.which("bash")
    if found is None:
        raise AssertionError("bash")
    return found


def _provider_keys():
    # The argv guard and in-process python live next to this file. Loading it
    # does not run its tests. python3 is the only command routed through it;
    # the other tools stay direct symlinks. No FIXTURE_ROOT, so nothing here
    # is treated as a provider secret.
    path = Path(__file__).with_name("provider-keys.py")
    spec = importlib.util.spec_from_file_location("provider_keys_support", path)
    if spec is None or spec.loader is None:
        raise AssertionError("provider-keys.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HarnessConditions(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        support = _provider_keys()
        cls._bin = tempfile.TemporaryDirectory(prefix="harness-conditions-bin-")
        cls.addClassCleanup(cls._bin.cleanup)
        root = Path(cls._bin.name)
        commands = root / "commands"
        real = root / "real"
        commands.mkdir()
        real.mkdir()
        guard = support._compile_guard(root)
        cls.daemon = support._PythonDaemon("cond")
        cls.addClassCleanup(cls.daemon.close)
        cls.py_socket = cls.daemon.path
        cls.real_dir = real
        for name in TOOL_NAMES:
            executable = real_bash() if name == "bash" else shutil.which(name)
            if executable is None:
                raise AssertionError(name)
            (commands / name).symlink_to(str(executable))
        (real / "python3").symlink_to(sys.executable)
        (commands / "python3").symlink_to(guard)
        cls.commands = commands
        cls.harness = Path(__file__).resolve().parents[1] / "bin/cfw-render-harness.sh"

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="harness-conditions-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        # No network clients, engines, sleep or process-stop tools on PATH.
        self.env = {
            "PATH": str(self.commands), "HOME": str(self.root),
            "TMPDIR": str(self.root), "LC_ALL": "C", "CFW_WORKER_ID": "fixture",
            "PYTHONDONTWRITEBYTECODE": "1",
            "CFW_PY_SOCKET": self.py_socket,
            "CFW_FIXTURE_REAL": str(self.real_dir),
        }
        self.case_number = 0
        self._case_lock = threading.Lock()

    def run_order(
        self, when: object, fields: dict[str, object], *, corrupt: bool = False, ask: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], list[dict], Path]:
        with self._case_lock:
            self.case_number += 1
            number = self.case_number
        directory = self.root / str(number)
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
# These orders declare no saves and no reel deliverable. The real filter would
# return the output list unchanged and name nothing missing. Writing that
# result here skips two interpreter starts and does not change the events,
# files or exit code this file checks. The brief and prompt are not asserted.
cr_h_write_brief() { printf '%s\n' '{}' > "$1/brief.json"; }
cr_h_build_prompt() { : > "$2/prompt.md"; }
cr_h_reel_delivery_outputs() { printf '%s' "$2"; }
cr_h_reel_missing_delivery() { :; }
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
            env=self.env, capture_output=True, text=True, timeout=15 * LOAD_WAIT_SCALE,
        )
        events_path = directory / "events"
        events = [json.loads(line) for line in events_path.read_text().splitlines()] if events_path.exists() else []
        return result, events, directory

    def _parallel(self, jobs: list[tuple[object, dict, dict]]) -> list[tuple]:
        def once(job: tuple) -> tuple:
            when, fields, kwargs = job
            return self.run_order(when, fields, **kwargs)

        if len(jobs) <= 1:
            return [once(job) for job in jobs]
        with ThreadPoolExecutor(max_workers=HARNESS_WORKERS) as pool:
            return list(pool.map(once, jobs))

    def _check_decision(self, result: subprocess.CompletedProcess[str], events: list[dict],
                        directory: Path, runs: bool) -> Path:
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = ["step_started", "step_completed", "attempt_completed"] if runs else ["step_skipped", "attempt_completed"]
        self.assertEqual([event["event"] for event in events], expected)
        engine_log = directory / "engine-runs"
        self.assertEqual(engine_log.read_text().splitlines() if engine_log.exists() else [], ["conditional"] if runs else [])
        self.assertNotIn("Traceback", result.stderr)
        if not runs:
            self.assertFalse((directory / "steps/conditional").exists())
        return directory

    def assert_decision(self, when: object, fields: dict[str, object], runs: bool) -> Path:
        result, events, directory = self.run_order(when, fields)
        return self._check_decision(result, events, directory, runs)

    def test_input_presence_list_and_dict(self) -> None:
        media = {"kind": "video", "url": "https://fixture.invalid/clip.mp4"}
        true_inputs = (
            [{"inputId": "clip", "items": [media]}],
            {"clip": [media]}, {"clip": media},
            # Multiple entries for one input retain all items, even if one is empty.
            [{"inputId": "clip", "items": [media]}, {"inputId": "clip", "items": []}],
        )
        true_jobs = [({"inputPresent": "clip"}, {"inputs": inputs}, {}) for inputs in true_inputs]
        for inputs, (result, events, directory) in zip(true_inputs, self._parallel(true_jobs)):
            with self.subTest(inputs=inputs):
                self._check_decision(result, events, directory, True)
                self.assertEqual((directory / "steps/conditional/inputs/clip/clip.mp4").read_text(), "fixture-media")
                self.assertEqual((directory / "downloads").read_text().splitlines(), [media["url"]])
        false_fields = (
            {}, {"inputs": None}, {"inputs": []}, {"inputs": {}},
            {"inputs": [{"inputId": "clip", "items": []}]},
            {"inputs": [{"inputId": "other", "items": [media]}]},
            {"inputs": {"other": [media]}},
            *({"inputs": {"clip": value}} for value in (None, "", [], {}, 0, False)),
        )
        false_jobs = [({"inputPresent": "clip"}, fields, {}) for fields in false_fields]
        for fields, (result, events, directory) in zip(false_fields, self._parallel(false_jobs)):
            with self.subTest(fields=fields):
                self._check_decision(result, events, directory, False)

    def test_alternative_list_and_dict(self) -> None:
        true_answers = (
            [{"inputId": "alternative", "text": "generate"}],
            [{"inputId": "other", "text": "upload"}, {"inputId": "alternative", "text": "generate"}],
            {"alternative": "generate"},
        )
        true_jobs = [({"alternative": "generate"}, {"answers": answers}, {}) for answers in true_answers]
        for answers, outcome in zip(true_answers, self._parallel(true_jobs)):
            with self.subTest(answers=answers):
                self._check_decision(*outcome, True)
        false_fields = (
            {}, {"answers": None}, {"answers": []}, {"answers": {}},
            {"answers": [{"inputId": "alternative", "text": "upload"}]},
            {"answers": [{"inputId": "alternative", "text": ""}]},
            {"answers": [{"inputId": "other", "text": "generate"}]},
            {"answers": {"alternative": "upload"}},
            {"answers": {"alternative": ""}},
            {"answers": {"other": "generate"}},
        )
        false_jobs = [({"alternative": "generate"}, fields, {}) for fields in false_fields]
        for fields, outcome in zip(false_fields, self._parallel(false_jobs)):
            with self.subTest(fields=fields):
                self._check_decision(*outcome, False)

    def test_text_staging_keeps_zero_and_false(self) -> None:
        inputs = {"zero": 0, "off": False, "ready": True, "count": 3, "topic": "Hello\nworld"}
        jobs = [
            ("always", {"inputs": inputs}, {}),
            ({"inputPresent": "topic"}, {"inputs": inputs}, {}),
            ("always", {"inputs": []}, {}),
            ("always", {"inputs": {}}, {}),
        ]
        full, present, empty_list, empty_dict = self._parallel(jobs)
        directory = self._check_decision(*full, True)
        for name, text in (("zero", "0"), ("off", "false"), ("ready", "true"), ("count", "3"), ("topic", "Hello\nworld")):
            self.assertEqual((directory / f"steps/conditional/inputs/{name}/{name}.md").read_text(), text)
        self._check_decision(*present, True)
        for outcome in (empty_list, empty_dict):
            directory = self._check_decision(*outcome, True)
            self.assertEqual(list((directory / "steps/conditional/inputs").iterdir()), [])

    def test_typed_answers_are_staged_as_inputs(self) -> None:
        # B13: Social sends a typed start/step answer only in `answers`. The step
        # reads inputs/<name>/, so the harness must write it there or the step
        # asks for the same input again (R-EPLF#1 -> R-EPLF#2).
        script = "Hook line.\nOne idea per sentence.  Keep this spacing.\nFollow for more."
        answers_list = (
            [{"inputId": "script", "text": script}],
            {"script": script},
        )
        jobs = [("always", {"answers": answers}, {}) for answers in answers_list]
        jobs.append(("always", {
            "inputs": [{"inputId": "clip", "items": [{"kind": "video", "url": "https://fixture.invalid/clip.mp4"}]}],
            "answers": [{"inputId": "voice_id", "text": "voice-1"}, {"inputId": "cta", "text": "Follow us"},
                        {"inputId": "voice_id", "text": "voice-2"}],
        }, {}))
        first, second, combined = self._parallel(jobs)
        for answers, outcome in zip(answers_list, (first, second)):
            with self.subTest(answers=answers):
                directory = self._check_decision(*outcome, True)
                staged = directory / "steps/conditional/inputs/script"
                self.assertEqual([path.name for path in staged.iterdir()], ["script.md"])
                self.assertEqual((staged / "script.md").read_text(), script)
        # Two answers, an unrelated media input, and the later answer for one id wins.
        directory = self._check_decision(*combined, True)
        inputs = directory / "steps/conditional/inputs"
        self.assertEqual(sorted(path.name for path in inputs.iterdir()), ["clip", "cta", "voice_id"])
        self.assertEqual((inputs / "voice_id/voice_id.md").read_text(), "voice-2")
        self.assertEqual((inputs / "cta/cta.md").read_text(), "Follow us")
        self.assertEqual((inputs / "clip/clip.mp4").read_text(), "fixture-media")

    def test_answers_do_not_override_inputs_or_stage_controls(self) -> None:
        # `inputs` is the owner's own value for that name; an answer fills gaps only.
        jobs = [
            ("always", {
                "inputs": {"topic": "from inputs"},
                "answers": [{"inputId": "topic", "text": "from answers"}],
            }, {}),
            # `alternative` is a condition value, not a step input; blank answers stage nothing.
            ({"alternative": "generate"}, {"answers": [
                {"inputId": "alternative", "text": "generate"},
                {"inputId": "script", "text": ""}, {"inputId": "cta", "text": " \n\t"},
            ]}, {}),
            # Legacy dict answers may carry non-text values; they are not staged.
            ("always", {"answers": {"count": 3, "script": "ok"}}, {}),
        ]
        topic, blank, legacy = self._parallel(jobs)
        directory = self._check_decision(*topic, True)
        self.assertEqual((directory / "steps/conditional/inputs/topic/topic.md").read_text(), "from inputs")
        directory = self._check_decision(*blank, True)
        self.assertEqual(list((directory / "steps/conditional/inputs").iterdir()), [])
        directory = self._check_decision(*legacy, True)
        self.assertEqual(sorted(path.name for path in (directory / "steps/conditional/inputs").iterdir()), ["script"])

    def test_answered_ask_is_released_and_the_next_claim_carries_it(self) -> None:
        # B13: the worker's claim was taken before the ask, so it holds no answer.
        # Rerunning the step in the same run would ask again (R-EPLF#2). The
        # attempt is handed back; the next claim's answers are staged for the step.
        script = "Hook line.\nOne idea per sentence.\nFollow for more."
        asked, carried = self._parallel([
            ("always", {"answers": []}, {"ask": True}),
            ("always", {"answers": [{"inputId": "script", "text": script}]}, {"ask": True}),
        ])
        result, events, directory = asked
        self.assertEqual(result.returncode, 21, result.stderr)
        self.assertEqual([event["event"] for event in events], ["step_started", "needs_input", "attempt_released"])
        self.assertEqual(events[1]["extra"]["ask"]["inputId"], "script")
        self.assertEqual(events[2]["extra"], {"stepId": "conditional", "reason": "ask_answered"})
        self.assertEqual((directory / "engine-runs").read_text().splitlines(), ["conditional"])
        self.assertIn("ask at step conditional answered; released", (directory / "log").read_text())
        self.assertFalse((directory / "current-step.json").exists())
        # The next claim carries the answer: the step finds the script and does not ask.
        result, events, directory = carried
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([event["event"] for event in events], ["step_started", "step_completed", "attempt_completed"])
        self.assertEqual((directory / "steps/conditional/inputs/script/script.md").read_text(), script)
        self.assertEqual((directory / "engine-runs").read_text().splitlines(), ["conditional"])

    def test_answer_name_cannot_leave_inputs(self) -> None:
        names = ("../escape", "a/b", "..", "x..y")
        jobs = [("always", {"answers": [{"inputId": name, "text": "t"}]}, {}) for name in names]
        for name, (result, events, directory) in zip(names, self._parallel(jobs)):
            with self.subTest(name=name):
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertFalse((directory / "engine-runs").exists())
                self.assertIn("input name refused", (directory / "log").read_text())
                self.assertEqual(sorted(path.name for path in directory.rglob("*.md")), [])
                self.assertNotIn("step_completed", [event["event"] for event in events])

    def _assert_failed_condition(self, result: subprocess.CompletedProcess[str], events: list[dict], directory: Path) -> None:
        self.assertEqual(result.returncode, 30, result.stderr)
        self.assertEqual([event["event"] for event in events], ["step_failed", "attempt_failed"])
        for event in events:
            self.assertEqual(event["extra"]["stepId"], "conditional")
            self.assertIn("Condition evaluation failed", event["extra"]["message"])
        self.assertFalse((directory / "engine-runs").exists())
        self.assertFalse((directory / "steps/conditional").exists())
        self.assertIn("condition evaluation failed", (directory / "log").read_text())

    def test_malformed_collections_fail_instead_of_skip(self) -> None:
        jobs: list[tuple[object, dict, dict]] = []
        labels: list[tuple[str, object]] = []
        for field, when in (("inputs", {"inputPresent": "clip"}), ("answers", {"alternative": "generate"})):
            for value in ("bad", 7, 0, False, [None], ["bad"], [{}], [{"inputId": ""}], [{"inputId": 1}]):
                jobs.append((when, {field: value}, {}))
                labels.append((field, value))
        outcomes = self._parallel(jobs)
        for (field, value), outcome in zip(labels, outcomes):
            with self.subTest(field=field, value=value):
                self._assert_failed_condition(*outcome)
        item_jobs = []
        item_values = (None, {}, "bad")
        for items in item_values:
            item_jobs.append(({"inputPresent": "clip"}, {"inputs": [{"inputId": "clip", "items": items}]}, {}))
        for items, outcome in zip(item_values, self._parallel(item_jobs)):
            with self.subTest(items=items):
                self._assert_failed_condition(*outcome)
        answers = (
            {"inputId": "alternative"}, {"inputId": "alternative", "text": None},
            {"inputId": "alternative", "text": []}, {"id": "alternative", "value": "generate"},
        )
        answer_jobs = [({"alternative": "generate"}, {"answers": [answer]}, {}) for answer in answers]
        for answer, outcome in zip(answers, self._parallel(answer_jobs)):
            with self.subTest(answer=answer):
                self._assert_failed_condition(*outcome)

    def test_json_parse_error_reports_failure(self) -> None:
        jobs = [
            ({"inputPresent": "clip"}, {"inputs": {}}, {"corrupt": True}),
            ({"alternative": "generate"}, {"answers": {}}, {"corrupt": True}),
        ]
        for outcome in self._parallel(jobs):
            self._assert_failed_condition(*outcome)


if __name__ == "__main__":
    unittest.main()
