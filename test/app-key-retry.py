#!/usr/bin/env python3
"""Hermetic from-app key-rotation regression; no installer or live services.

Run: python3 test/app-key-retry.py
All subprocesses use an allowlisted fake PATH. Each exec boundary checks argv;
only fake credentials in a temporary HOME are used. The real from-app functions
are sourced; exchange, MCP, env access and platform commands are fixtures.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


def key(label: str) -> str:
    return "cfw_render_fixture-only-" + label


def assert_no_secrets(text: str) -> None:
    for secret in [key(label) for label in "ABCD"] + ["cfw_brand_fixture-only-parent"]:
        if secret in text:
            raise AssertionError("fixture credential leaked")


def event(value: str) -> None:
    assert_no_secrets(value)
    with (Path(os.environ["FIXTURE_ROOT"]) / "events").open("a") as output:
        output.write(value + "\n")


def pending_keys() -> list[str]:
    path = Path(os.environ["WORKER_ID_FILE"]).parent / "pending-key-revocations.json"
    return json.loads(path.read_text())["keys"]


def fake_command(command: str, args: list[str]) -> int:
    """Allow only commands used by the sourced functions; never call the network."""
    assert_no_secrets("\n".join(sys.argv))
    event("exec:" + command)
    if command == "python3":
        assert args[:1] == ["-c"], "unexpected Python entrypoint"
        # The actual inline persistence/JSON code runs, with argv checked before
        # exec. Fault injection proves failed writes do not truncate the outbox.
        code = args[1]
        if 'name = "pending-key-revocations.json"' in code:
            fault = os.environ.get("FIXTURE_WRITE_FAULT", "")
            if fault:
                assert fault in ("replace", "fsync")
                code = (
                    "import os\n"
                    "def injected_failure(*args, **kwargs):\n"
                    "    raise OSError(\"injected fixture failure\")\n"
                    f"os.{fault} = injected_failure\n"
                ) + code
        os.execve(sys.executable, [sys.executable, "-c", code, *args[2:]], dict(os.environ))
    if command == "curl":
        assert "exchange" in args[args.index("-X") + 2]
        assert args[args.index("-H") + 1] == "@-"
        assert sys.stdin.read() == "x-api-key: cfw_brand_fixture-only-parent\n"
        previous = read_env("CFW_RENDER_WORKER_KEY")
        assert not previous or previous in pending_keys(), "exchange preceded journaling"
        event("exchange:" + os.environ["FIXTURE_NEW"])
        print(json.dumps({"key": {"plain": key(os.environ["FIXTURE_NEW"]), "scope": "user"}}))
        print("201", end="")
    elif command == "tr":
        assert args == ["-d", "[:space:]"]
        print("".join(sys.stdin.read().split()), end="")
    elif command == "dirname":
        print(Path(args[0]).parent)
    elif command == "date":
        assert args == ["+%s"]
        print("1000")
    elif command == "hostname":
        print("Fixture Mac")
    else:
        raise AssertionError("unexpected external command")
    return 0


def read_env(name: str) -> str:
    for line in Path(os.environ["ENV_FILE"]).read_text().splitlines():
        field, _, value = line.partition("=")
        if field == name:
            return value
    return ""


def fake_helper(args: list[str]) -> int:
    assert_no_secrets("\n".join(sys.argv))
    event("helper:" + args[0])
    if args[0] == "env-get":
        print(read_env(args[1]))
    elif args[0] == "env-set":
        value = sys.stdin.readline().rstrip("\n")
        if args[1] == "CFW_RENDER_WORKER_KEY":
            assert value in pending_keys(), "env overwritten before durable journal"
            old = read_env(args[1])
            assert not old or old in pending_keys(), "previous key not journaled"
            if os.environ.get("FIXTURE_ENV_FAIL") == "1":
                return 8
        path = Path(args[2])
        lines = [line for line in path.read_text().splitlines() if not line.startswith(args[1] + "=")]
        path.write_text("\n".join([*lines, args[1] + "=" + value]) + "\n")
        path.chmod(0o600)
        event("env-write:" + args[1])
    elif args[0] == "mcp":
        tool, data = args[1], json.loads(args[2])
        if tool == "report_byoa_setup_step" and data["step"] == "probe_render":
            if os.environ["FIXTURE_PROBE"] == "fail":
                event("probe:fail")
                print('{"ok":false,"error":"fixture_probe_failed"}')
            else:
                event("probe:success")
                if os.environ.get("FIXTURE_CORRUPT_AFTER_PROBE") == "1":
                    path = Path(os.environ["WORKER_ID_FILE"]).parent / "pending-key-revocations.json"
                    path.write_text("invalid fixture state")
                print('{"ok":true}')
        elif tool == "revoke_this_computer":
            token = os.environ["CFW_RENDER_WORKER_KEY"]
            assert token != read_env("CFW_RENDER_WORKER_KEY"), "revoked current key"
            label = next(label for label in "ABCD" if token == key(label))
            event("revoke:" + label)
            if label == os.environ.get("FIXTURE_REVOKE_FAIL"):
                print('{"ok":false}')
            elif label == os.environ.get("FIXTURE_REVOKE_TRANSPORT_FAIL"):
                return 9
            else:
                print('{"ok":true}')
        else:
            assert tool in ("report_byoa_setup_step", "get_byoa_setup_instructions", "create_probe_render_order")
            print('{"ok":true}')
    else:
        raise AssertionError("unexpected fixture helper")
    return 0


class KeyRetryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="cfw-key-retry-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.state = self.root / "state"
        self.state.mkdir(mode=0o700)
        self.worker = self.state / "worker-id"
        self.worker.write_text("fixture-stable-identity\n")
        self.pending = self.state / "pending-key-revocations.json"
        self.env_file = self.root / "worker.env"
        self.env_file.write_text("CFW_RENDER_WORKER_KEY=" + key("A") + "\n")
        self.env_file.chmod(0o600)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        helper = Path(__file__).resolve()
        for command in ("python3", "curl", "tr", "dirname", "date", "hostname"):
            path = self.bin / command
            path.write_text(
                "#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(helper))
                + " --fake-command " + command + ' "$@"\n'
            )
            path.chmod(0o700)
        self.script = self.root / "run.sh"
        self.script.write_text(r'''set -euo pipefail
source "$FROM_APP"
env_value() { "$PYTHON" "$HELPER" --fake-helper env-get "$@"; }
fa_env_set() { "$PYTHON" "$HELPER" --fake-helper env-set "$@"; }
cr_computer_name() { printf '%s\n' 'Fixture Mac'; }
cr_mcp_call_soft() { "$PYTHON" "$HELPER" --fake-helper mcp "$@"; }
app_step() { printf '%s %s\n' "$1" "$2"; }
app_fail() { printf '%s\n' "$3" >&2; exit "$2"; }
if [[ "${FIXTURE_ACTION:-connect}" == connect ]]; then
  fa_connect_and_probe
else
  fa_pending_keys "$FIXTURE_ACTION"
fi
''')
        # Do not inherit user configuration, credentials, BASH_ENV or tool paths.
        self.env = {
            "HOME": str(self.root), "PATH": str(self.bin), "LC_ALL": "C",
            "FROM_APP": str(helper.parent.parent / "install" / "from-app.sh"),
            "PYTHON": sys.executable, "HELPER": str(helper),
            "FIXTURE_ROOT": str(self.root), "WORKER_ID_FILE": str(self.worker),
            "ENV_FILE": str(self.env_file), "CFW_RENDER_API_BASE": "https://fixture.invalid",
            "CFW_RENDER_SKIP_LAUNCHCTL": "1", "CFW_RENDER_INSTALL_NO_LAUNCHCTL": "1",
            "CFW_RENDER_PROBE_TIMEOUT_SEC": "0", "BRAND_KEY": "cfw_brand_fixture-only-parent",
            "FIXTURE_NEW": "B", "FIXTURE_PROBE": "success",
        }

    def run_shell(self, expected: int = 0, stdin: str = "", **overrides: str) -> subprocess.CompletedProcess[str]:
        args = ["/bin/bash", "--noprofile", "--norc", str(self.script)]
        assert_no_secrets("\n".join(args))
        result = subprocess.run(args, input=stdin, env={**self.env, **overrides},
                                capture_output=True, text=True, timeout=30)
        assert_no_secrets(result.stdout + result.stderr)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertEqual(self.worker.read_text(), "fixture-stable-identity\n")
        self.assertEqual(list(self.state.glob(".pending-key-revocations-*")), [])
        return result

    def events(self) -> list[str]:
        return (self.root / "events").read_text().splitlines()

    def keys(self) -> list[str]:
        self.assertEqual(self.pending.stat().st_mode & 0o777, 0o600)
        self.assertFalse(self.pending.is_symlink())
        return json.loads(self.pending.read_text())["keys"]

    def seed(self, keys: list[str]) -> None:
        self.pending.write_text(json.dumps({"version": 1, "keys": keys}))
        self.pending.chmod(0o600)

    def test_failed_probe_then_cross_parent_retry(self) -> None:
        self.run_shell(expected=7, FIXTURE_PROBE="fail")
        self.assertEqual(self.keys(), [key("A"), key("B")])
        self.assertIn(key("B"), self.env_file.read_text())
        self.assertFalse(any(row.startswith("revoke:") for row in self.events()))
        self.run_shell(FIXTURE_NEW="C")
        self.assertEqual(self.keys(), [])
        self.assertIn(key("C"), self.env_file.read_text())
        events = self.events()
        self.assertEqual([row for row in events if row.startswith("revoke:")], ["revoke:A", "revoke:B"])
        self.assertLess(events.index("probe:success"), events.index("revoke:A"))
        self.assertLess(events.index("probe:success"), events.index("revoke:B"))

    def test_failed_revocations_retained_until_later_success(self) -> None:
        self.run_shell(expected=7, FIXTURE_PROBE="fail")
        self.run_shell(FIXTURE_NEW="C", FIXTURE_REVOKE_FAIL="A", FIXTURE_REVOKE_TRANSPORT_FAIL="B")
        self.assertEqual(self.keys(), [key("A"), key("B")])
        self.run_shell(expected=7, FIXTURE_NEW="D", FIXTURE_PROBE="fail")
        self.assertEqual([row for row in self.events() if row.startswith("revoke:")], ["revoke:A", "revoke:B"])
        self.run_shell(FIXTURE_NEW="D")
        self.assertEqual(self.keys(), [])
        self.assertEqual([row for row in self.events() if row.startswith("revoke:")],
                         ["revoke:A", "revoke:B", "revoke:A", "revoke:B", "revoke:C"])

    def test_corruption_after_probe_prevents_revocation(self) -> None:
        self.run_shell(expected=6, FIXTURE_CORRUPT_AFTER_PROBE="1")
        self.assertIn("probe:success", self.events())
        self.assertFalse(any(row.startswith("revoke:") for row in self.events()))
        self.assertEqual(self.pending.read_text(), "invalid fixture state")

    def test_current_key_is_not_revoked(self) -> None:
        self.seed([key("A")])
        self.run_shell(FIXTURE_NEW="A")
        self.assertEqual(self.keys(), [])
        self.assertFalse(any(row.startswith("revoke:") for row in self.events()))

    def test_env_write_failure_preserves_issued_and_old_keys(self) -> None:
        self.run_shell(expected=8, FIXTURE_ENV_FAIL="1")
        self.assertEqual(self.keys(), [key("A"), key("B")])
        self.assertIn(key("A"), self.env_file.read_text())
        self.assertFalse(any(row.startswith("revoke:") for row in self.events()))
        self.run_shell(FIXTURE_NEW="C")
        self.assertEqual(self.keys(), [])

    def test_corrupt_state_fails_before_exchange(self) -> None:
        cases = ["", "not-json", "[]", '{"version":2,"keys":[]}',
                 '{"version":1,"version":1,"keys":[]}',
                 '{"version":true,"keys":[]}', '{"version":1,"keys":"bad"}',
                 json.dumps({"version": 1, "keys": [key("A"), key("A")]}),
                 json.dumps({"version": 1, "keys": [key("A") + "\nmalformed"]})]
        for raw in cases:
            with self.subTest(raw_shape=len(raw)):
                self.pending.write_text(raw)
                self.pending.chmod(0o600)
                self.run_shell(expected=6)
                self.assertEqual(self.pending.read_text(), raw)
                self.assertIn(key("A"), self.env_file.read_text())
                self.assertFalse(any(row.startswith(("exchange:", "revoke:")) for row in self.events()))

    def test_pending_symlink_rejected_without_touching_target(self) -> None:
        outside = self.root / "outside"
        outside.write_text("fixture target unchanged")
        self.pending.symlink_to(outside)
        self.run_shell(expected=6)
        self.assertEqual(outside.read_text(), "fixture target unchanged")
        self.assertTrue(self.pending.is_symlink())
        self.assertFalse(any(row.startswith("exchange:") for row in self.events()))
        self.pending.unlink()
        self.pending.symlink_to(self.root / "missing-target")
        self.run_shell(expected=6)
        self.assertFalse((self.root / "missing-target").exists())

    def test_state_directory_symlink_rejected(self) -> None:
        alias = self.root / "state-alias"
        alias.symlink_to(self.state, target_is_directory=True)
        self.run_shell(expected=6, WORKER_ID_FILE=str(alias / "worker-id"))
        self.assertFalse(self.pending.exists())
        self.assertFalse(any(row.startswith("exchange:") for row in self.events()))

    def test_unsafe_permissions_and_hardlinks_rejected(self) -> None:
        self.seed([key("A")])
        self.pending.chmod(0o644)
        self.run_shell(expected=6)
        self.pending.chmod(0o600)
        os.link(self.pending, self.root / "hardlink")
        self.run_shell(expected=6)
        self.assertFalse(any(row.startswith("exchange:") for row in self.events()))

    def test_atomic_write_failure_preserves_existing_state(self) -> None:
        self.seed([key("A")])
        original = self.pending.read_bytes()
        for fault in ("fsync", "replace"):
            with self.subTest(fault=fault):
                self.run_shell(expected=1, stdin=key("B") + "\n", FIXTURE_ACTION="add", FIXTURE_WRITE_FAULT=fault)
                self.assertEqual(self.pending.read_bytes(), original)
        # A successful mutation replaces the inode rather than truncating it.
        with self.pending.open() as old_inode:
            self.run_shell(stdin=key("B") + "\n", FIXTURE_ACTION="add")
            self.assertEqual(old_inode.read().encode(), original)
        self.assertEqual(self.keys(), [key("A"), key("B")])


if __name__ == "__main__":
    if sys.argv[1:2] == ["--fake-command"]:
        raise SystemExit(fake_command(sys.argv[2], sys.argv[3:]))
    if sys.argv[1:2] == ["--fake-helper"]:
        raise SystemExit(fake_helper(sys.argv[2:]))
    unittest.main(verbosity=2)
