#!/usr/bin/env python3
"""Stop only a recorded test child and its descendants, never command matches.

Process facts come from macOS libproc and sysctl through ctypes, not from `ps`
or any other setuid binary: the runner sandbox refuses those, and plain
library calls read the same process table without them.
"""
import ctypes
import ctypes.util
import os
import signal
import sys

CTL_KERN = 1
KERN_ARGMAX = 8
KERN_PROCARGS2 = 49
PROC_PIDTBSDINFO = 3
PROC_PIDTBSDINFO_SIZE = 136
MAXCOMLEN = 16


class ProcBsdInfo(ctypes.Structure):
    """struct proc_bsdinfo from <sys/proc_info.h> (PROC_PIDTBSDINFO)."""
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * MAXCOMLEN),
        ("pbi_name", ctypes.c_char * (2 * MAXCOMLEN)),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


assert ctypes.sizeof(ProcBsdInfo) == PROC_PIDTBSDINFO_SIZE


def _load(names):
    for name in names:
        try:
            return ctypes.CDLL(name, use_errno=True)
        except OSError:
            continue
    raise OSError("no process library: " + ", ".join(names))


_LIBPROC = _load(["/usr/lib/libproc.dylib", "libproc.dylib", "/usr/lib/libSystem.B.dylib"])
_LIBC = _load([ctypes.util.find_library("c") or "libc.dylib", "/usr/lib/libSystem.B.dylib"])

_LIBPROC.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
_LIBPROC.proc_listallpids.restype = ctypes.c_int
_LIBPROC.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
_LIBPROC.proc_pidinfo.restype = ctypes.c_int
_LIBPROC.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
_LIBPROC.proc_pidpath.restype = ctypes.c_int
_LIBC.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
                         ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
_LIBC.sysctl.restype = ctypes.c_int


def _all_pids():
    size = 1024
    while True:
        buffer = (ctypes.c_int * size)()
        count = _LIBPROC.proc_listallpids(buffer, ctypes.sizeof(buffer))
        if count < 0:
            raise OSError(ctypes.get_errno(), "proc_listallpids failed")
        if count < size:
            return [pid for pid in buffer[:count] if pid > 0]
        size *= 2


def _bsdinfo(pid):
    info = ProcBsdInfo()
    # arg=1: include zombies, as `ps -ax` did, so a reaped-but-unwaited child
    # still has the same identity until it disappears.
    got = _LIBPROC.proc_pidinfo(pid, PROC_PIDTBSDINFO, 1, ctypes.byref(info), PROC_PIDTBSDINFO_SIZE)
    if got != PROC_PIDTBSDINFO_SIZE:
        return None
    return info


def processes():
    # Do not collect command lines: unrelated processes can contain credentials.
    # Identity is (parent, start time): a reused pid never matches an old record.
    table = {}
    for pid in _all_pids():
        info = _bsdinfo(pid)
        if info is None:
            continue   # exited between the listing and the lookup
        table[pid] = (int(info.pbi_ppid), (int(info.pbi_start_tvsec), int(info.pbi_start_tvusec)))
    return table


def stop_owned_tree(pid, owner):
    table = processes()
    if pid not in table:
        return
    if pid <= 1 or table[pid][0] != owner:
        raise ValueError("refusing cleanup of a process not owned by this test")
    stopped = []

    def freeze(child, identity):
        # Stop parents before enumerating children so loops cannot keep spawning.
        if processes().get(child) != identity:
            return
        try:
            os.kill(child, signal.SIGSTOP)
        except ProcessLookupError:
            return
        stopped.append((child, identity))
        for descendant, record in processes().items():
            if record[0] == child:
                freeze(descendant, record)

    try:
        freeze(pid, table[pid])
    finally:
        # Test fixtures need no shutdown side effects. Frozen parents cannot
        # orphan/replace children while this exact recorded tree is removed.
        for child, identity in reversed(stopped):
            if processes().get(child) == identity:
                try:
                    os.kill(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass


def _argmax():
    mib = (ctypes.c_int * 2)(CTL_KERN, KERN_ARGMAX)
    value = ctypes.c_int(0)
    size = ctypes.c_size_t(ctypes.sizeof(value))
    if _LIBC.sysctl(mib, 2, ctypes.byref(value), ctypes.byref(size), None, 0) != 0 or value.value <= 0:
        return 1 << 20
    return value.value


def _arguments(pid, argmax):
    """argv of one process as `ps -o args=` printed it, or None when unavailable."""
    mib = (ctypes.c_int * 3)(CTL_KERN, KERN_PROCARGS2, pid)
    buffer = ctypes.create_string_buffer(argmax)
    size = ctypes.c_size_t(argmax)
    if _LIBC.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
        return None
    raw = buffer.raw[:size.value]
    if len(raw) < 4:
        return None
    argc = int.from_bytes(raw[:4], sys.byteorder)
    rest = raw[4:]
    end = rest.find(b"\0")             # the executable path comes first
    if end < 0:
        return None
    rest = rest[end:].lstrip(b"\0")    # then padding, then argv, then environ
    parts = rest.split(b"\0")[:max(argc, 0)]
    return b" ".join(parts).decode("utf-8", "replace")


def _path(pid):
    buffer = ctypes.create_string_buffer(4096)
    if _LIBPROC.proc_pidpath(pid, buffer, ctypes.sizeof(buffer)) <= 0:
        return None
    return buffer.value.decode("utf-8", "replace")


def owned_arguments(owner):
    table = processes()
    owned = {owner}
    while True:
        children = {pid for pid, (parent, _) in table.items() if parent in owned}
        expanded = owned | children
        if expanded == owned:
            break
        owned = expanded
    owned.discard(owner)
    if not owned:
        return
    argmax = _argmax()
    lines = []
    for pid in sorted(owned):
        args = _arguments(pid, argmax)
        if args is None:
            # Gone, or a kernel that withholds argv: show at least the program.
            path = _path(pid)
            if path is None:
                continue
            args = path + " (arguments unavailable)"
        lines.append(args + "\n")
    sys.stdout.write("".join(lines))


if __name__ == "__main__":
    if sys.argv[1] == "--arguments":
        owned_arguments(int(sys.argv[2]))
    else:
        stop_owned_tree(int(sys.argv[1]), int(sys.argv[2]))
