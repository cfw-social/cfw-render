#!/usr/bin/env python3
"""Hermetic provider-key scope regression: python3 test/provider-keys.py.

Real harness and export helper; fake engine, timer and report transport. Every
external command checks argv for fixture secrets. No network or process stops.
"""
from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


def provider_env() -> dict[str, str]:
    return {"heygen": "HEYGEN_API_KEY", "elevenlabs": "ELEVENLABS_API_KEY",
            "kie": "KIE_AI_API_KEY", "gemini": "GEMINI_API_KEY", "fal": "FAL_KEY",
            "replicate": "REPLICATE_API_TOKEN"}


def fixture_key(provider: str) -> str:
    return "fixture-secret-" + provider + "-$()'\"\nsecond-line"


class ProviderKeys(unittest.TestCase):
    def run_claim(
        self, fields: dict[str, object], steps: list[dict], expected: dict[str, dict[str, str]],
        *, parser_fault: bool = False,
    ) -> tuple[int, list[dict], list[str]]:
        with tempfile.TemporaryDirectory(prefix="provider-keys-") as temporary:
            root = Path(temporary)
            commands = root / "commands"
            commands.mkdir()
            (root / "recipe").mkdir()
            names = provider_env()
            ambient = {name: "fixture-ambient-" + name for name in names.values()}
            secrets = list(ambient.values()) + [fixture_key(p) for p in names] + ["fixture-oauth-only"]
            config = {"secrets": secrets, "names": list(names.values()), "expected": expected,
                      "ambient": ambient, "parser_fault": parser_fault}
            (root / "config.json").write_text(json.dumps(config))
            real = {}
            for name in ("bash", "cat", "cp", "date", "dirname", "mkdir", "mktemp", "rm", "rmdir", "tr"):
                real[name] = shutil.which(name)
                self.assertIsNotNone(real[name], name)
            real["python3"] = sys.executable
            # No curl, engine, sleep or process-stop tool can be resolved.
            wrapper = root / "command.py"
            wrapper.write_text(f"#!{sys.executable}\n" + r'''
import json, os, sys
from pathlib import Path
root = Path(os.environ["FIXTURE_ROOT"])
config = json.loads((root / "config.json").read_text())
assert not any(secret in arg for secret in config["secrets"] for arg in sys.argv), "secret in argv"
name = Path(sys.argv[0]).name
with (root / "argv").open("a") as output:
    output.write(json.dumps(sys.argv) + "\n")
if name == "python3" and sys.argv[1:2] == ["-"]:
    source = sys.stdin.read()
    if config["parser_fault"] and "__CFW_KEYS_OK__" in source:
        raise SystemExit(9)  # Process substitution failure must not mean no keys.
    os.execve(sys.executable, [sys.executable, "-c", source, *sys.argv[2:]], dict(os.environ))
real = json.loads((root / "real.json").read_text())[name]
os.execve(real, [real, *sys.argv[1:]], dict(os.environ))
''')
            wrapper.chmod(0o755)
            (root / "real.json").write_text(json.dumps(real))
            for name in real:
                (commands / name).symlink_to(wrapper)
            checker = root / "check-env.py"
            checker.write_text(r'''
import json, os, sys
from pathlib import Path
root = Path(os.environ["FIXTURE_ROOT"])
c = json.loads((root / "config.json").read_text())
actual = {k: os.environ[k] for k in c["names"] if k in os.environ}
if sys.argv[1] == "parent":
    assert actual == c["ambient"], "parent env changed"
else:
    sid = os.environ["CFW_STEP_ID"]
    assert actual == c["expected"][sid], "stage env differs"
    with (root / "runs").open("a") as out:
        out.write(sid + "\n")
''')
            order = {"id": "fixture-order", "attempt": {"id": "fixture-attempt"},
                     "manifest": {"recipe": "fixture", "steps": steps}, **fields}
            (root / "order.json").write_text(json.dumps(order))
            harness = Path(__file__).resolve().parents[1] / "bin/cfw-render-harness.sh"
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
  python3 "$dir/check-env.py" engine || exit 98
  : > "$4"
}
cr_report_step() {
  python3 -c 'import json,sys; print(json.dumps({"event":sys.argv[1], "extra":json.loads(sys.argv[2])}))' "$5" "$6" >> "$dir/events"
  printf '%s' '{"ok":true,"directive":"continue"}'
}
rc=0
cr_harness_run "$dir/order.json" "$dir" "$dir/recipe" || rc=$?
python3 "$dir/check-env.py" parent
exit "$rc"
'''
            env = {"PATH": str(commands), "HOME": str(root), "TMPDIR": str(root),
                   "FIXTURE_ROOT": str(root), "CFW_WORKER_ID": "fixture", "LC_ALL": "C",
                   "PYTHONDONTWRITEBYTECODE": "1", **ambient}
            result = subprocess.run(
                [str(commands / "bash"), "-x", "-c", script, "fixture", str(harness), str(root)],
                env=env, capture_output=True, text=True, timeout=15,
            )
            # Include trace, harness/engine logs, reports and recorded argv, not
            # the fixture order/config or prompts (which have separate contracts).
            observed = result.stdout + result.stderr
            for path in [root / "log", root / "events", root / "argv", *(root / "logs").glob("*")]:
                if path.exists():
                    observed += path.read_text()
            for secret in secrets:
                self.assertNotIn(secret, observed)
                self.assertNotIn(secret.split("\n")[0], observed)
            self.assertNotIn("secret in argv", observed)
            self.assertNotIn("stage env differs", observed)
            self.assertNotIn("parent env changed", observed)
            events = [json.loads(line) for line in (root / "events").read_text().splitlines()]
            runs = (root / "runs").read_text().splitlines() if (root / "runs").exists() else []
            return result.returncode, events, runs

    def test_mapping_stage_scope_and_parent_isolation(self) -> None:
        names = provider_env()
        keys = [{"provider": p, "value": fixture_key(p), "expiresAt": "2999-01-01T00:00:00Z"} for p in names]
        steps = [
            {"id": "legacy"},
            {"id": "generate", "uses": {"providers": [["kie", "fal"]], "optionalProviders": ["replicate"]}},
            {"id": "qa", "uses": {"tools": ["python3"]}},
        ]
        expected = {
            "legacy": {name: fixture_key(p) for p, name in names.items()},
            "generate": {names[p]: fixture_key(p) for p in ("kie", "fal", "replicate")},
            "qa": {},
        }
        rc, events, runs = self.run_claim({"providerKeys": keys}, steps, expected)
        self.assertEqual(rc, 0)
        self.assertEqual(runs, ["legacy", "generate", "qa"])
        self.assertEqual(events[-1]["event"], "attempt_completed")

    def test_absent_keys_never_use_ambient_or_oauth(self) -> None:
        for fields in ({}, {"providerKeys": []}, {"taskOrder": {"credentials": {"heygen": {
            "mode": "oauth", "accessToken": "fixture-oauth-only", "expiresAt": "2999-01-01T00:00:00Z",
        }}}}):
            with self.subTest(fields=fields):
                rc, events, runs = self.run_claim(fields, [{"id": "legacy"}], {"legacy": {}})
                self.assertEqual(rc, 0)
                self.assertEqual(runs, ["legacy"])
                self.assertEqual(events[-1]["event"], "attempt_completed")

    def assert_rejected(self, fields: dict[str, object], step: dict, *, parser_fault: bool = False) -> None:
        rc, events, runs = self.run_claim(fields, [step], {}, parser_fault=parser_fault)
        self.assertEqual(rc, 30)
        self.assertEqual(runs, [])
        self.assertEqual([e["event"] for e in events], ["step_started", "step_failed", "attempt_failed"])
        for event in events[-2:]:
            self.assertEqual(event["extra"]["message"], "Invalid or expired provider key claim")

    def test_expired_and_malformed_claims_fail_closed(self) -> None:
        valid = {"provider": "kie", "value": fixture_key("kie")}
        invalid_keys = [None, {}, "bad", [None], [{}],
                        [{"provider": "PATH", "value": fixture_key("kie")}],
                        [valid, valid]]
        invalid_keys += [[{**valid, "value": value}] for value in (None, "", " ", 5, "bad\u0000key")]
        invalid_keys += [[{**valid, "expiresAt": expiry}] for expiry in (
            "2000-01-01T00:00:00Z", "bad", None, 7, "2999-01-01T00:00:00",
        )]
        for keys in invalid_keys:
            with self.subTest(keys=keys):
                self.assert_rejected({"providerKeys": keys}, {"id": "generate"})
        # An invalid non-selected entry cannot partially deliver earlier keys.
        self.assert_rejected({"providerKeys": [valid, {"provider": "fal", "value": ""}]},
                             {"id": "generate", "uses": {"providers": [["kie"]]}})

    def test_invalid_scope_and_failed_parser_do_not_start_engine(self) -> None:
        fields = {"providerKeys": [{"provider": "kie", "value": fixture_key("kie")}]}
        for uses in (None, [], {"providers": ["kie"]}, {"providers": [[]]},
                     {"providers": [[5]]}, {"optionalProviders": "kie"}):
            with self.subTest(uses=uses):
                self.assert_rejected(fields, {"id": "generate", "uses": uses})
        self.assert_rejected(fields, {"id": "generate"}, parser_fault=True)


if __name__ == "__main__":
    unittest.main()
