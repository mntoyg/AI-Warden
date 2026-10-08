#!/usr/bin/env python3
# AI Warden - phase M drill helper (verify-isolation.sh). NOT part of any image.
#
# Measures a process cap instead of reading its label. The sandbox's self-test
# asks the cgroup for pids.max, but under gVisor that file reads "max" while
# --pids-limit silently bounds the runtime's HOST tasks, and under Kata it
# bounds nothing in the guest at all - a label that can mean three different
# things. So this forks until the kernel refuses and prints the count.
#
# The probe must survive its own failure: a shell fork loop dies when fork
# fails and prints nothing, which is how six measurements once came back empty.
# os.fork() in try/except with flush=True cannot do that - every run ends in
# exactly one "forked N, then: errno E <text>" or "forked N - no limit hit".
#
# Usage: python3 drill-fork-count.py <max forks to attempt> [child lifetime s]
import os
import sys
import time

target = int(sys.argv[1]) if len(sys.argv) > 1 else 200
hold = float(sys.argv[2]) if len(sys.argv) > 2 else 12.0

for path in ("/sys/fs/cgroup/pids.max", "/sys/fs/cgroup/pids/pids.max"):
    try:
        with open(path) as fh:
            print("label {} {}".format(path, fh.read().strip()), flush=True)
    except OSError as exc:
        print("label {} unreadable ({})".format(path, exc.strerror), flush=True)

n = 0
for _ in range(target):
    try:
        pid = os.fork()
    except OSError as exc:
        print("forked {}, then: errno {} {}".format(n, exc.errno, exc.strerror), flush=True)
        break
    if pid == 0:
        # A child that exits at once frees its slot and the cap is never
        # reached; it has to stay alive while the parent keeps forking.
        time.sleep(hold)
        os._exit(0)
    n += 1
else:
    print("forked {} - no limit hit".format(n), flush=True)
print("done forked {} of {}".format(n, target), flush=True)
