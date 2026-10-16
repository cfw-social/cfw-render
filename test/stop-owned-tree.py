#!/usr/bin/env python3
"""Stop only a recorded test child and its descendants, never command matches."""
import os
import signal
import subprocess
import sys


def processes():
    # Do not collect command lines: unrelated processes can contain credentials.
    rows = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,lstart="], text=True
    ).splitlines()
    return {int(p): (int(parent), start) for p, parent, start in
            (row.split(None, 2) for row in rows if row.strip())}


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
    if owned:
        result = subprocess.run(["ps", "-o", "args=", "-p", ",".join(map(str, sorted(owned)))],
                                text=True, capture_output=True)
        sys.stdout.write(result.stdout)


if __name__ == "__main__":
    if sys.argv[1] == "--arguments":
        owned_arguments(int(sys.argv[2]))
    else:
        stop_owned_tree(int(sys.argv[1]), int(sys.argv[2]))
