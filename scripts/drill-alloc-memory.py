#!/usr/bin/env python3
# AI Warden - phase M drill helper (verify-isolation.sh). NOT part of any image.
#
# Measures a memory cap instead of reading its label. The sandbox's self-test
# asks the cgroup whether memory.max is set; under a VM or user-space runtime
# that file can say "capped" while nothing enforces it, which is the project's
# recurring bug shape. So this allocates past the cap in 16 MiB chunks and
# TOUCHES every page (bytearray(n) can leave the pages untouched), printing the
# running total after each chunk.
#
# The last "alloc <N> MiB" line IS the measurement: a cgroup kill arrives as
# SIGKILL, so the process gets no chance to report its own death. The probe
# therefore survives neither-crash-nor-kill the only way that works - by
# printing as it goes - and also prints what the cgroup CLAIMS, so the label and
# the measurement appear side by side in one log.
#
# Usage: python3 drill-alloc-memory.py <target MiB>
import sys

CHUNK = 16 * 1024 * 1024
PAGE = 4096
target = int(sys.argv[1]) if len(sys.argv) > 1 else 768

for path in ("/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory/memory.limit_in_bytes"):
    try:
        with open(path) as fh:
            print("label {} {}".format(path, fh.read().strip()), flush=True)
    except OSError as exc:
        print("label {} unreadable ({})".format(path, exc.strerror), flush=True)

held = []
done = 0
try:
    while done < target:
        buf = bytearray(CHUNK)
        for off in range(0, CHUNK, PAGE):
            buf[off] = 1
        held.append(buf)
        done += CHUNK // (1024 * 1024)
        print("alloc {} MiB".format(done), flush=True)
except MemoryError:
    # A cgroup kill never gets here; a refused allocation does.
    print("MemoryError after {} MiB".format(done), flush=True)
print("done {} MiB of {}".format(done, target), flush=True)
