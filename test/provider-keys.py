#!/usr/bin/env python3
"""Hermetic provider-key scope regression: python3 test/provider-keys.py.

Real harness and export helper; fake engine, timer and report transport. Every
external command checks argv for fixture secrets. Python itself runs inside
this process so each claim does not pay a new interpreter. No network or
process stops.
"""
from __future__ import annotations

import io
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import unittest


def provider_env() -> dict[str, str]:
    return {"heygen": "HEYGEN_API_KEY", "elevenlabs": "ELEVENLABS_API_KEY",
            "kie": "KIE_AI_API_KEY", "gemini": "GEMINI_API_KEY", "fal": "FAL_KEY",
            "replicate": "REPLICATE_API_TOKEN"}


def fixture_key(provider: str) -> str:
    return "fixture-secret-" + provider + "-$()'\"\nsecond-line"


# One compiled guard for the class. It logs argv, rejects a fixture secret in
# any argument, then execs the real binary. python3 is the exception: the
# guard hands the command to the daemon below. A shell guard in front of every
# mkdir/date, plus a new interpreter for every snippet, was the whole claim.
# The frame is big-endian: argc, each arg, envc, each KEY=VAL, cwd, stdin.
GUARD_C = r"""
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

extern char **environ;

static void fail(const char *msg) {
  if (msg) {
    size_t n = strlen(msg);
    while (n) {
      ssize_t w = write(2, msg, n);
      if (w < 0) break;
      msg += w;
      n -= (size_t)w;
    }
  }
  _exit(127);
}

static int write_all(int fd, const void *buf, size_t n) {
  const char *p = buf;
  while (n) {
    ssize_t w = write(fd, p, n);
    if (w < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    p += w;
    n -= (size_t)w;
  }
  return 0;
}

static int read_all(int fd, void *buf, size_t n) {
  char *p = buf;
  while (n) {
    ssize_t r = read(fd, p, n);
    if (r < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (r == 0) return -1;
    p += r;
    n -= (size_t)r;
  }
  return 0;
}

static int write_u32(int fd, uint32_t v) {
  uint32_t be = htonl(v);
  return write_all(fd, &be, 4);
}

static int write_blob(int fd, const void *buf, uint32_t n) {
  if (write_u32(fd, n) < 0) return -1;
  return write_all(fd, buf, n);
}

static void log_line(int fd, const char *text) {
  size_t n = strlen(text);
  if (write_all(fd, text, n) < 0 || write_all(fd, "\n", 1) < 0) fail("argv-guard: argv log failed\n");
}

static void record_argv(const char *root, int argc, char **argv) {
  char path[PATH_MAX];
  int n = snprintf(path, sizeof path, "%s/argv", root);
  if (n < 0 || (size_t)n >= sizeof path) fail("argv-guard: argv path\n");
  int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
  if (fd < 0) fail("argv-guard: argv log failed\n");
  for (int i = 0; i < argc; i++) log_line(fd, argv[i]);
  if (write_all(fd, "\n", 1) < 0) fail("argv-guard: argv log failed\n");
  close(fd);
}

static int secret_in_argv(const char *root, int argc, char **argv) {
  char path[PATH_MAX];
  int n = snprintf(path, sizeof path, "%s/secrets.bin", root);
  if (n < 0 || (size_t)n >= sizeof path) fail("argv-guard: secrets path\n");
  int fd = open(path, O_RDONLY);
  if (fd < 0) return 0;
  off_t len = lseek(fd, 0, SEEK_END);
  if (len <= 0) { close(fd); return 0; }
  if (lseek(fd, 0, SEEK_SET) < 0) fail("argv-guard: secrets read\n");
  if ((unsigned long long)len > 8ull * 1024ull * 1024ull) fail("argv-guard: secrets too large\n");
  char *data = malloc((size_t)len + 1);
  if (!data) fail("argv-guard: out of memory\n");
  if (read_all(fd, data, (size_t)len) < 0) fail("argv-guard: secrets read\n");
  close(fd);
  data[len] = '\0';
  int hit = 0;
  char *p = data;
  char *end = data + len;
  while (p < end && !hit) {
    char *nul = memchr(p, '\0', (size_t)(end - p));
    if (p[0] != '\0') {
      for (int i = 0; i < argc; i++) {
        if (strstr(argv[i], p)) { hit = 1; break; }
      }
    }
    if (!nul) break;
    p = nul + 1;
  }
  free(data);
  if (!hit) return 0;
  n = snprintf(path, sizeof path, "%s/argv", root);
  if (n < 0 || (size_t)n >= sizeof path) fail("argv-guard: argv path\n");
  int out = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
  if (out < 0) fail("argv-guard: argv log failed\n");
  if (write_all(out, "secret in argv\n", 15) < 0) fail("argv-guard: argv log failed\n");
  close(out);
  return 1;
}

static char *read_stdin(uint32_t *out_len) {
  size_t cap = 4096, len = 0;
  char *buf = malloc(cap);
  if (!buf) fail("argv-guard: out of memory\n");
  for (;;) {
    if (len == cap) {
      if (cap > 32u * 1024u * 1024u) fail("argv-guard: stdin too large\n");
      cap *= 2;
      char *grown = realloc(buf, cap);
      if (!grown) fail("argv-guard: out of memory\n");
      buf = grown;
    }
    ssize_t r = read(0, buf + len, cap - len);
    if (r < 0) {
      if (errno == EINTR) continue;
      fail("argv-guard: stdin read\n");
    }
    if (r == 0) break;
    len += (size_t)r;
  }
  *out_len = (uint32_t)len;
  return buf;
}

static void forward_python(int argc, char **argv, int read_stdin_program) {
  const char *spec = getenv("CFW_PY_SOCKET");
  if (!spec || !spec[0]) fail("argv-guard: CFW_PY_SOCKET is unset\n");
  uint32_t stdin_len = 0;
  char *stdin_buf = NULL;
  if (read_stdin_program) stdin_buf = read_stdin(&stdin_len);
  /* 127.0.0.1:port. The bound suite allows localhost TCP and denies AF_UNIX. */
  const char *colon = strrchr(spec, ':');
  if (!colon || colon == spec || colon[1] == '\0') fail("argv-guard: socket path\n");
  char host[64];
  size_t host_len = (size_t)(colon - spec);
  if (host_len >= sizeof host) fail("argv-guard: socket path\n");
  memcpy(host, spec, host_len);
  host[host_len] = '\0';
  char *end = NULL;
  unsigned long port = strtoul(colon + 1, &end, 10);
  if (end == colon + 1 || !end || *end != '\0' || port == 0 || port > 65535ul) fail("argv-guard: socket path\n");
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) fail("argv-guard: cannot reach python\n");
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) fail("argv-guard: socket path\n");
  if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) fail("argv-guard: cannot reach python\n");
  if (write_u32(fd, (uint32_t)argc) < 0) fail("argv-guard: short write\n");
  for (int i = 0; i < argc; i++) {
    if (write_blob(fd, argv[i], (uint32_t)strlen(argv[i])) < 0) fail("argv-guard: short write\n");
  }
  uint32_t envc = 0;
  for (char **e = environ; *e; e++) envc++;
  if (write_u32(fd, envc) < 0) fail("argv-guard: short write\n");
  for (char **e = environ; *e; e++) {
    if (write_blob(fd, *e, (uint32_t)strlen(*e)) < 0) fail("argv-guard: short write\n");
  }
  char cwd[PATH_MAX];
  if (!getcwd(cwd, sizeof cwd)) fail("argv-guard: cwd\n");
  if (write_blob(fd, cwd, (uint32_t)strlen(cwd)) < 0) fail("argv-guard: short write\n");
  if (write_blob(fd, stdin_buf ? stdin_buf : "", stdin_len) < 0) fail("argv-guard: short write\n");
  uint32_t raw = 0;
  if (read_all(fd, &raw, 4) < 0) fail("argv-guard: python daemon closed\n");
  int32_t code = (int32_t)ntohl(raw);
  uint32_t out_len = 0, err_len = 0;
  if (read_all(fd, &raw, 4) < 0) fail("argv-guard: python daemon closed\n");
  out_len = ntohl(raw);
  if (out_len > 32u * 1024u * 1024u) fail("argv-guard: stdout too large\n");
  char *out = out_len ? malloc(out_len) : NULL;
  if (out_len && !out) fail("argv-guard: out of memory\n");
  if (out_len && read_all(fd, out, out_len) < 0) fail("argv-guard: python daemon closed\n");
  if (read_all(fd, &raw, 4) < 0) fail("argv-guard: python daemon closed\n");
  err_len = ntohl(raw);
  if (err_len > 32u * 1024u * 1024u) fail("argv-guard: stderr too large\n");
  char *err = err_len ? malloc(err_len) : NULL;
  if (err_len && !err) fail("argv-guard: out of memory\n");
  if (err_len && read_all(fd, err, err_len) < 0) fail("argv-guard: python daemon closed\n");
  if (out_len && write_all(1, out, out_len) < 0) fail(NULL);
  if (err_len && write_all(2, err, err_len) < 0) fail(NULL);
  _exit((unsigned)code & 0xffu);
}

static void exec_real(const char *base, int argc, char **argv) {
  const char *real_dir = getenv("CFW_FIXTURE_REAL");
  if (!real_dir || !real_dir[0]) fail("argv-guard: CFW_FIXTURE_REAL is unset\n");
  char real[PATH_MAX];
  int n = snprintf(real, sizeof real, "%s/%s", real_dir, base);
  if (n < 0 || (size_t)n >= sizeof real) fail("argv-guard: real path\n");
  char **nav = malloc((size_t)(argc + 1) * sizeof(char *));
  if (!nav) fail("argv-guard: out of memory\n");
  nav[0] = real;
  for (int i = 1; i < argc; i++) nav[i] = argv[i];
  nav[argc] = NULL;
  execv(real, nav);
  fail("argv-guard: exec failed\n");
}

int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
  const char *base = argv[0] ? argv[0] : "";
  const char *slash = strrchr(base, '/');
  if (slash) base = slash + 1;
  const char *root = getenv("FIXTURE_ROOT");
  if (root && root[0]) {
    record_argv(root, argc, argv);
    if (secret_in_argv(root, argc, argv)) _exit(97);
  }
  int python = strcmp(base, "python3") == 0;
  if (python && getenv("CFW_PY_SOCKET")) {
    int heredoc = argc >= 2 && strcmp(argv[1], "-") == 0;
    forward_python(argc, argv, heredoc);
  }
  exec_real(base, argc, argv);
  return 127;
}
"""

GUARDED = ("bash", "cat", "cp", "date", "dirname", "mkdir", "mktemp", "rm", "rmdir", "tr", "python3")
# Same search as test/gate-suite.test.mjs. /bin/bash is 3.2 and breaks the harness.
BASH4_DIRS = ("/opt/homebrew/bin", "/usr/local/bin")
_FRAME_CAP = 32 * 1024 * 1024


def real_bash() -> str:
    for directory in BASH4_DIRS:
        candidate = Path(directory) / "bash"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    found = shutil.which("bash")
    if found is None:
        raise AssertionError("bash")
    return found


class _Capture:
    """Text stream over one buffer. Scripts write str or .buffer bytes."""

    encoding = "utf-8"
    errors = "surrogateescape"

    def __init__(self) -> None:
        self.buffer = io.BytesIO()

    def write(self, data: str) -> int:
        if not isinstance(data, str):
            raise TypeError("string argument expected")
        self.buffer.write(data.encode("utf-8", "surrogateescape"))
        return len(data)

    def flush(self) -> None:
        return None

    def isatty(self) -> bool:
        return False

    def fileno(self) -> int:
        raise OSError("captured stream has no fileno")

    def reconfigure(self, **_kwargs: object) -> None:
        return None

    def readable(self) -> bool:
        return False

    def writable(self) -> bool:
        return True


def _read_exact(conn: socket.socket, size: int) -> bytes:
    buf = bytearray()
    while len(buf) < size:
        chunk = conn.recv(size - len(buf))
        if not chunk:
            raise EOFError("short frame")
        buf += chunk
    return bytes(buf)


def _read_u32(conn: socket.socket) -> int:
    return int.from_bytes(_read_exact(conn, 4), "big")


def _read_blob(conn: socket.socket) -> bytes:
    size = _read_u32(conn)
    if size > _FRAME_CAP:
        raise ValueError("frame too large")
    return _read_exact(conn, size) if size else b""


def _send_response(conn: socket.socket, code: int, out: bytes, err: bytes) -> None:
    conn.sendall((code & 0xFFFFFFFF).to_bytes(4, "big"))
    conn.sendall(len(out).to_bytes(4, "big") + out)
    conn.sendall(len(err).to_bytes(4, "big") + err)


def _status_from(exc: SystemExit) -> int:
    status = exc.code
    if status is None:
        return 0
    if isinstance(status, int):
        return status
    if status != "":
        sys.stderr.write(str(status) + "\n")
    return 1


def _run_inprocess(argv: list[str], env: dict[str, str], cwd: str, stdin_bytes: bytes) -> tuple[int, bytes, bytes]:
    # Real python3 - file <<'PY' consumes the program and leaves the script an empty stdin.
    # A parser fault must fail before any secret byte is written, same as a dead interpreter.
    if len(argv) >= 2 and argv[1] == "-" and env.get("CFW_PARSER_FAULT") == "1" and b"__CFW_KEYS_OK__" in stdin_bytes:
        return 9, b"", b""
    out = _Capture()
    err = _Capture()
    old_env = dict(os.environ)
    old_argv = sys.argv[:]
    old_out, old_err, old_in = sys.stdout, sys.stderr, sys.stdin
    old_path = sys.path[:]
    old_bytecode = sys.dont_write_bytecode
    cwd_fd = os.open(".", os.O_RDONLY)
    try:
        sys.dont_write_bytecode = True
        os.environ.clear()
        os.environ.update(env)
        if cwd:
            os.chdir(cwd)
        sys.stdout, sys.stderr = out, err
        sys.stdin = io.TextIOWrapper(io.BytesIO(), encoding="utf-8", errors="surrogateescape")
        if len(argv) >= 2 and argv[1] == "-c":
            sys.argv = ["-c", *argv[3:]]
            sys.path.insert(0, "")
            code = compile(argv[2], "<string>", "exec")
            ns: dict[str, object] = {"__name__": "__main__"}
        elif len(argv) >= 2 and argv[1] == "-":
            sys.argv = ["-", *argv[2:]]
            sys.path.insert(0, "")
            source = stdin_bytes.decode("utf-8", "surrogateescape")
            code = compile(source, "<stdin>", "exec")
            ns = {"__name__": "__main__"}
        elif len(argv) >= 2:
            path = argv[1]
            sys.argv = [path, *argv[2:]]
            script_dir = os.path.dirname(os.path.abspath(path)) or ""
            sys.path.insert(0, script_dir)
            source_bytes = Path(path).read_bytes()
            code = compile(source_bytes.decode("utf-8", "surrogateescape"), path, "exec")
            ns = {"__name__": "__main__", "__file__": path, "__package__": None}
        else:
            return 2, b"", b"python3: not enough arguments\n"
        try:
            exec(code, ns)  # noqa: S102 — the harness snippets are the program under test
        except SystemExit as exc:
            return _status_from(exc), out.buffer.getvalue(), err.buffer.getvalue()
        except Exception:
            traceback.print_exc(file=sys.stderr)
            return 1, out.buffer.getvalue(), err.buffer.getvalue()
        return 0, out.buffer.getvalue(), err.buffer.getvalue()
    except FileNotFoundError as exc:
        message = f"python3: can't open file: {exc.strerror}\n"
        return 2, b"", message.encode()
    except Exception:
        buffer = io.StringIO()
        traceback.print_exc(file=buffer)
        return 1, out.buffer.getvalue(), buffer.getvalue().encode()
    finally:
        sys.stdout, sys.stderr, sys.stdin = old_out, old_err, old_in
        sys.argv = old_argv
        sys.path[:] = old_path
        sys.dont_write_bytecode = old_bytecode
        os.environ.clear()
        os.environ.update(old_env)
        try:
            os.fchdir(cwd_fd)
        finally:
            os.close(cwd_fd)


class _PythonDaemon:
    def __init__(self, suffix: str) -> None:
        # AF_UNIX bind is denied by the bound-suite sandbox, including under
        # TMPDIR, and /tmp is not writable. Localhost TCP is allowed.
        self._stop = threading.Event()
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.bind(("127.0.0.1", 0))
        host, port = self._sock.getsockname()
        self.path = f"{host}:{port}"
        self._sock.listen(128)
        self._sock.settimeout(0.5)
        self._thread = threading.Thread(target=self._serve, name=f"cfw-py-{suffix}", daemon=True)
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
        self._sock.close()
        self._thread.join(timeout=5)

    def _serve(self) -> None:
        while not self._stop.is_set():
            try:
                conn, _addr = self._sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with conn:
                try:
                    self._handle(conn)
                except Exception:
                    try:
                        _send_response(conn, 1, b"", traceback.format_exc().encode())
                    except OSError:
                        pass

    def _handle(self, conn: socket.socket) -> None:
        argc = _read_u32(conn)
        if argc > 10000:
            raise ValueError("too many arguments")
        argv = [_read_blob(conn).decode("utf-8", "surrogateescape") for _ in range(argc)]
        envc = _read_u32(conn)
        if envc > 100000:
            raise ValueError("too many environment entries")
        env: dict[str, str] = {}
        for _ in range(envc):
            item = _read_blob(conn).decode("utf-8", "surrogateescape")
            key, sep, value = item.partition("=")
            if sep and key:
                env[key] = value
        cwd = _read_blob(conn).decode("utf-8", "surrogateescape")
        stdin_bytes = _read_blob(conn)
        code, out, err = _run_inprocess(argv, env, cwd, stdin_bytes)
        _send_response(conn, code, out, err)


def _compile_guard(directory: Path) -> Path:
    source = directory / "argv-guard.c"
    obj = directory / "argv-guard.o"
    binary = directory / "argv-guard"
    source.write_text(GUARD_C)
    compiler = "/usr/bin/clang" if os.access("/usr/bin/clang", os.X_OK) else shutil.which("clang") or shutil.which("cc")
    if compiler is None:
        raise AssertionError("clang")
    # Two steps, both in the fixture dir. One-step `clang -o` writes a temp
    # object outside this directory, which the confined test step blocks.
    compiled = subprocess.run(
        [compiler, "-O2", "-c", str(source), "-o", str(obj)],
        capture_output=True, text=True, cwd=directory,
    )
    if compiled.returncode != 0:
        detail = compiled.stderr or compiled.stdout or "clang failed"
        raise AssertionError(detail)
    linked = subprocess.run(
        [compiler, str(obj), "-o", str(binary)],
        capture_output=True, text=True, cwd=directory,
    )
    if linked.returncode != 0:
        detail = linked.stderr or linked.stdout or "clang failed"
        raise AssertionError(detail)
    binary.chmod(0o755)
    return binary


class ProviderKeys(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._fixture = tempfile.TemporaryDirectory(prefix="provider-keys-bin-")
        cls.addClassCleanup(cls._fixture.cleanup)
        root = Path(cls._fixture.name)
        cls.real_dir = root / "real"
        cls.commands = root / "commands"
        cls.real_dir.mkdir()
        cls.commands.mkdir()
        guard = _compile_guard(root)
        cls.daemon = _PythonDaemon("keys")
        cls.addClassCleanup(cls.daemon.close)
        cls.py_socket = cls.daemon.path
        for name in GUARDED:
            target = sys.executable if name == "python3" else real_bash() if name == "bash" else shutil.which(name)
            if target is None:
                raise AssertionError(name)
            (cls.real_dir / name).symlink_to(target)
            (cls.commands / name).symlink_to(guard)
        cls.harness = Path(__file__).resolve().parents[1] / "bin/cfw-render-harness.sh"

    def run_claim(
        self, fields: dict[str, object], steps: list[dict], expected: dict[str, dict[str, str]],
        *, parser_fault: bool = False, trace: bool = False,
    ) -> tuple[int, list[dict], list[str]]:
        with tempfile.TemporaryDirectory(prefix="provider-keys-") as temporary:
            root = Path(temporary)
            (root / "recipe").mkdir()
            names = provider_env()
            ambient = {name: "fixture-ambient-" + name for name in names.values()}
            secrets = list(ambient.values()) + [fixture_key(p) for p in names] + ["fixture-oauth-only"]
            config = {"secrets": secrets, "names": list(names.values()), "expected": expected,
                      "ambient": ambient, "parser_fault": parser_fault}
            (root / "config.json").write_text(json.dumps(config))
            (root / "secrets.bin").write_bytes(b"".join(secret.encode() + b"\0" for secret in secrets))
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
            script = r'''
set -euo pipefail
source "$1"
dir="$2"
# Rename the real pause hook without a double-quoted eval: its body contains
# command substitutions, and those must not run while the name is rewritten.
declare -f cr_h_wait_pause > "$dir/wait-src.sh"
python3 -c 'import pathlib,sys
p=pathlib.Path(sys.argv[1])
t=p.read_text()
if not t.startswith("cr_h_wait_pause"):
    raise SystemExit(1)
p.write_text("cr_h_wait_pause_orig"+t[len("cr_h_wait_pause"):])' "$dir/wait-src.sh"
source "$dir/wait-src.sh"
_cfw_mark() {
  python3 -c 'import os,sys,time; open(os.environ["FIXTURE_ROOT"]+"/step-clock","a").write("%.6f %s\n" % (time.monotonic(), sys.argv[1]))' "$1"
}
# step_id is local in cr_harness_run and already set when this hook runs.
cr_h_wait_pause() {
  _cfw_mark "${step_id:-pre}" || return 31
  cr_h_wait_pause_orig "$@"
}
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
_cfw_mark preamble
rc=0
cr_harness_run "$dir/order.json" "$dir" "$dir/recipe" || rc=$?
_cfw_mark end
python3 "$dir/check-env.py" parent
exit "$rc"
'''
            env = {"PATH": str(self.commands), "HOME": str(root), "TMPDIR": str(root),
                   "FIXTURE_ROOT": str(root), "CFW_FIXTURE_REAL": str(self.real_dir),
                   "CFW_PY_SOCKET": self.py_socket,
                   "CFW_PARSER_FAULT": "1" if parser_fault else "0",
                   "CFW_WORKER_ID": "fixture", "LC_ALL": "C",
                   "PYTHONDONTWRITEBYTECODE": "1", **ambient}
            # bash -x traces every simple command. Only claims that put a
            # fixture secret into the child environment need that trace in the
            # secret scan. Rejected claims fail before export; their stdout,
            # stderr, logs, events and argv are still scanned. CLAIM_TIMEOUT_S
            # is the ceiling. The stderr line PROVIDER-KEYS-STEP-SECONDS is the
            # measurement: preamble, then each claim step (the last span runs
            # through harness return). The claim fails if that sum or the
            # subprocess wall reaches the ceiling. 90s remains the ceiling
            # until a measured run shows a lower one still holds. It is not a
            # hung restore, lock, or engine.
            CLAIM_TIMEOUT_S = 90

            def step_spans(wall: float) -> list[tuple[str, float]]:
                marks: list[tuple[float, str]] = []
                clock = root / "step-clock"
                text = clock.read_text(encoding="utf-8") if clock.is_file() else ""
                ok = True
                for line in text.splitlines():
                    if not line:
                        continue
                    stamp, sep, name = line.partition(" ")
                    if not sep:
                        ok = False
                        break
                    try:
                        marks.append((float(stamp), name))
                    except ValueError:
                        ok = False
                        break
                spans = [(marks[i][1], marks[i + 1][0] - marks[i][0]) for i in range(len(marks) - 1)] if ok else []
                safe = bool(spans) and all(
                    0 < len(name) <= 40 and all(ch.isalnum() or ch in "_.-" for ch in name) and delta >= 0
                    for name, delta in spans)
                if safe:
                    detail = " ".join("%s=%.3f" % (name, delta) for name, delta in spans)
                else:
                    detail = "unreadable=%d" % len(text.splitlines())
                print("PROVIDER-KEYS-STEP-SECONDS %s wall=%.3f timeout=%d" % (detail, wall, CLAIM_TIMEOUT_S),
                      file=sys.stderr)
                return spans if safe else []

            argv = [str(self.commands / "bash")]
            if trace:
                argv.append("-x")
            argv.extend(["-c", script, "fixture", str(self.harness), str(root)])
            started = time.perf_counter()
            try:
                result = subprocess.run(
                    argv, env=env, capture_output=True, text=True, timeout=CLAIM_TIMEOUT_S,
                )
            except subprocess.TimeoutExpired:
                step_spans(time.perf_counter() - started)
                raise
            wall = time.perf_counter() - started
            spans = step_spans(wall)
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
            self.assertTrue(spans, "claim step clock missing")
            self.assertEqual(spans[0][0], "preamble")
            self.assertLess(sum(delta for _, delta in spans), CLAIM_TIMEOUT_S)
            self.assertLess(wall, CLAIM_TIMEOUT_S)
            for step in steps:
                self.assertIn(step["id"], [name for name, _ in spans])
            events = [json.loads(line) for line in (root / "events").read_text().splitlines()]
            runs = (root / "runs").read_text().splitlines() if (root / "runs").exists() else []
            return result.returncode, events, runs

    def _run_all(self, calls: list[dict]) -> list[tuple[int, list[dict], list[str]]]:
        # The daemon is one thread and borrows this process's env and stdio.
        # Claims stay in order so those stay restored before the next claim.
        return [self.run_claim(**call) for call in calls]

    def test_mapping_stage_scope_and_parent_isolation(self) -> None:
        names = provider_env()
        keys = [{"provider": p, "value": fixture_key(p), "expiresAt": "2999-01-01T00:00:00Z"} for p in names]
        steps = [
            {"id": "legacy"},
            {"id": "generate", "uses": {"providers": [["kie", "fal"]], "optionalProviders": ["replicate"]}},
            {"id": "qa", "uses": {"tools": ["python3"]}},
        ]
        expected = {
            # WI2.152: a step that declares no `uses` receives no provider key.
            "legacy": {},
            "generate": {names[p]: fixture_key(p) for p in ("kie", "fal", "replicate")},
            "qa": {},
        }
        rc, events, runs = self.run_claim({"providerKeys": keys}, steps, expected, trace=True)
        self.assertEqual(rc, 0)
        self.assertEqual(runs, ["legacy", "generate", "qa"])
        self.assertEqual(events[-1]["event"], "attempt_completed")

    def test_absent_keys_never_use_ambient_or_oauth(self) -> None:
        field_list = [{}, {"providerKeys": []}, {"taskOrder": {"credentials": {"heygen": {
            "mode": "oauth", "accessToken": "fixture-oauth-only", "expiresAt": "2999-01-01T00:00:00Z",
        }}}}]
        results = self._run_all([
            {"fields": fields, "steps": [{"id": "legacy"}], "expected": {"legacy": {}}, "trace": True}
            for fields in field_list
        ])
        for fields, (rc, events, runs) in zip(field_list, results):
            with self.subTest(fields=fields):
                self.assertEqual(rc, 0)
                self.assertEqual(runs, ["legacy"])
                self.assertEqual(events[-1]["event"], "attempt_completed")

    def _assert_rejected(self, rc: int, events: list[dict], runs: list[str]) -> None:
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
        calls = [{"fields": {"providerKeys": keys}, "steps": [{"id": "generate"}], "expected": {}}
                 for keys in invalid_keys]
        # An invalid non-selected entry cannot partially deliver earlier keys.
        calls.append({"fields": {"providerKeys": [valid, {"provider": "fal", "value": ""}]},
                      "steps": [{"id": "generate", "uses": {"providers": [["kie"]]}}], "expected": {}})
        labels = [(keys,) for keys in invalid_keys] + [([valid, {"provider": "fal", "value": ""}],)]
        results = self._run_all(calls)
        for (keys,), (rc, events, runs) in zip(labels, results):
            with self.subTest(keys=keys):
                self._assert_rejected(rc, events, runs)

    def test_invalid_scope_and_failed_parser_do_not_start_engine(self) -> None:
        fields = {"providerKeys": [{"provider": "kie", "value": fixture_key("kie")}]}
        uses_list = (None, [], {"providers": ["kie"]}, {"providers": [[]]},
                     {"providers": [[5]]}, {"optionalProviders": "kie"})
        calls = [{"fields": fields, "steps": [{"id": "generate", "uses": uses}], "expected": {}}
                 for uses in uses_list]
        calls.append({"fields": fields, "steps": [{"id": "generate"}], "expected": {}, "parser_fault": True})
        results = self._run_all(calls)
        for uses, (rc, events, runs) in zip(uses_list, results):
            with self.subTest(uses=uses):
                self._assert_rejected(rc, events, runs)
        self._assert_rejected(*results[-1])


if __name__ == "__main__":
    unittest.main()
