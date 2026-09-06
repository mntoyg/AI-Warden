#!/usr/bin/env python3
# =============================================================================
#  AI Warden - Honeypot Canary Monitor / Intrusion Tripwire
# -----------------------------------------------------------------------------
#  Watches a set of synthetic credential files ("canary tokens") and terminates
#  the sandbox the instant an agent process opens, reads, writes, moves or
#  deletes one of them.
#
#  WHY RAW inotify AND NOT watchdog ALONE
#  --------------------------------------
#  Reading a file produces IN_OPEN / IN_ACCESS. The `watchdog` library's inotify
#  emitter subscribes to create/modify/delete/move only, so a plain `cat
#  secrets.json` is invisible to it. AI Warden therefore drives inotify(7)
#  directly through ctypes and uses watchdog only as a secondary, portable
#  detector for structural events.
#
#  fanotify would give us per-open process attribution, but it requires
#  CAP_SYS_ADMIN - which this sandbox deliberately does not have. Attribution
#  is instead reconstructed best-effort from /proc.
#
#  MODES
#  -----
#    inline    Runs inside the agent container as the agent's own UID. Kills
#              the agent's process tree, then signals PID 1 (SIGUSR1) so the
#              entrypoint exits with WARDEN_BREACH_EXIT_CODE.
#
#    sentinel  Runs in a separate container that shares the agent's PID
#              namespace and holds ONLY CAP_KILL, as a different UID. The agent
#              cannot signal it, cannot ptrace it and cannot unmount its view of
#              the workspace, so the tripwire survives an agent that actively
#              tries to disarm it.
#
#  Exit codes:  0 clean shutdown | 99 breach handled | 78 fatal configuration
# =============================================================================

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import errno
import json
import os
import select
import signal
import struct
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence

WARDEN_VERSION = "1.0.0"
BREACH_EXIT_CODE = int(os.environ.get("WARDEN_BREACH_EXIT_CODE", "99"))

# --- inotify(7) constants -----------------------------------------------------
IN_ACCESS = 0x00000001
IN_MODIFY = 0x00000002
IN_ATTRIB = 0x00000004
IN_CLOSE_WRITE = 0x00000008
IN_CLOSE_NOWRITE = 0x00000010
IN_OPEN = 0x00000020
IN_MOVED_FROM = 0x00000040
IN_MOVED_TO = 0x00000080
IN_CREATE = 0x00000100
IN_DELETE = 0x00000200
IN_DELETE_SELF = 0x00000400
IN_MOVE_SELF = 0x00000800
IN_IGNORED = 0x00008000
IN_ONLYDIR = 0x01000000
IN_EXCL_UNLINK = 0x04000000

# Events on the canary file itself that constitute a breach.
#
# IN_ATTRIB is deliberately NOT in this set. A bare chmod is not an exfiltration
# attempt, and the seeding path ends with chmod 0400 - watching ATTRIB would let
# the out-of-band sentinel trip on the warden's own housekeeping if it armed
# mid-seed. Nothing is lost: a file cannot be read or written without open(2),
# so IN_OPEN already covers every access that matters.
FILE_MASK = (
    IN_ACCESS
    | IN_MODIFY
    | IN_OPEN
    | IN_CLOSE_WRITE
    | IN_DELETE_SELF
    | IN_MOVE_SELF
)

# Structural events on the containing directory. Kept narrow on purpose: a busy
# workspace would otherwise flood the inotify queue with irrelevant events.
DIR_MASK = IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_ONLYDIR

EVENT_NAMES = {
    IN_ACCESS: "ACCESS(read)",
    IN_MODIFY: "MODIFY(write)",
    IN_ATTRIB: "ATTRIB(metadata)",
    IN_CLOSE_WRITE: "CLOSE_WRITE",
    IN_OPEN: "OPEN",
    IN_MOVED_FROM: "MOVED_FROM",
    IN_MOVED_TO: "MOVED_TO",
    IN_CREATE: "CREATE",
    IN_DELETE: "DELETE",
    IN_DELETE_SELF: "DELETE_SELF",
    IN_MOVE_SELF: "MOVE_SELF",
}

INOTIFY_HEADER = struct.Struct("iIII")  # wd, mask, cookie, len


# =============================================================================
#  Logging
# =============================================================================
def _ts() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def log(msg: str) -> None:
    sys.stderr.write(f"[canary {_ts()}] {msg}\n")
    sys.stderr.flush()


def alert(msg: str) -> None:
    sys.stderr.write(f"[canary {_ts()}] *** {msg}\n")
    sys.stderr.flush()


# =============================================================================
#  inotify binding
# =============================================================================
class Inotify:
    """Minimal, dependency-free inotify(7) binding via ctypes."""

    def __init__(self) -> None:
        libc_name = ctypes.util.find_library("c") or "libc.so.6"
        self._libc = ctypes.CDLL(libc_name, use_errno=True)
        self._libc.inotify_init1.argtypes = [ctypes.c_int]
        self._libc.inotify_init1.restype = ctypes.c_int
        self._libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
        self._libc.inotify_add_watch.restype = ctypes.c_int
        self._libc.inotify_rm_watch.argtypes = [ctypes.c_int, ctypes.c_int]
        self._libc.inotify_rm_watch.restype = ctypes.c_int

        fd = self._libc.inotify_init1(os.O_CLOEXEC | os.O_NONBLOCK)
        if fd < 0:
            err = ctypes.get_errno()
            raise OSError(err, f"inotify_init1 failed: {os.strerror(err)}")
        self.fd = fd

    def add_watch(self, path: str, mask: int) -> int:
        wd = self._libc.inotify_add_watch(self.fd, path.encode("utf-8"), mask)
        if wd < 0:
            err = ctypes.get_errno()
            raise OSError(err, f"inotify_add_watch({path}) failed: {os.strerror(err)}")
        return wd

    def rm_watch(self, wd: int) -> None:
        self._libc.inotify_rm_watch(self.fd, wd)

    def read_events(self) -> List[tuple]:
        """Return a list of (wd, mask, cookie, name) tuples."""
        try:
            data = os.read(self.fd, 8192)
        except BlockingIOError:
            return []
        except OSError as exc:
            if exc.errno in (errno.EAGAIN, errno.EINTR):
                return []
            raise

        events, offset = [], 0
        while offset + INOTIFY_HEADER.size <= len(data):
            wd, mask, cookie, length = INOTIFY_HEADER.unpack_from(data, offset)
            offset += INOTIFY_HEADER.size
            raw_name = data[offset : offset + length]
            offset += length
            name = raw_name.split(b"\x00", 1)[0].decode("utf-8", "replace")
            events.append((wd, mask, cookie, name))
        return events

    def close(self) -> None:
        try:
            os.close(self.fd)
        except OSError:
            pass


def describe_mask(mask: int) -> str:
    names = [label for bit, label in EVENT_NAMES.items() if mask & bit]
    return "|".join(names) if names else f"0x{mask:08x}"


def filesystem_of(path: str) -> str:
    """Filesystem type backing `path`, from the longest matching mountpoint."""
    best, best_fs = "", "unknown"
    try:
        with open("/proc/mounts") as fh:
            for line in fh:
                fields = line.split()
                if len(fields) < 3:
                    continue
                mount, fstype = fields[1], fields[2]
                if (path == mount or path.startswith(mount.rstrip("/") + "/")) and len(mount) >= len(best):
                    best, best_fs = mount, fstype
    except OSError:
        pass
    return best_fs


def probe_inotify_delivery(directory: str, timeout: float = 1.0) -> Optional[bool]:
    """Does inotify actually deliver events for files in this directory?

    inotify_add_watch succeeds on filesystems that never deliver a single event
    - most importantly the 9p/virtiofs bind mounts Docker Desktop uses on
    Windows and macOS, where /workspace is mounted `noatime` and neither
    inotify nor an atime heuristic sees a read. A tripwire that reports itself
    armed while silently observing nothing is worse than no tripwire at all, so
    the capability is measured rather than assumed.

    The probe uses a throwaway file, never a canary: reading a real canary here
    would trip whichever *other* monitor is watching the same path from another
    container.

    Returns True (events delivered), False (silently deaf), or None (could not
    determine - e.g. the directory is not writable).
    """
    probe_path = os.path.join(directory, f".warden-probe-{os.getpid()}")
    ino = None
    try:
        with open(probe_path, "w") as fh:
            fh.write("warden inotify capability probe\n")
        ino = Inotify()
        ino.add_watch(probe_path, IN_OPEN | IN_ACCESS)
        with open(probe_path, "rb") as fh:
            fh.read()
        ready, _, _ = select.select([ino.fd], [], [], timeout)
        return bool(ready and ino.read_events())
    except OSError:
        return None
    finally:
        if ino is not None:
            ino.close()
        try:
            os.unlink(probe_path)
        except OSError:
            pass


# =============================================================================
#  Process attribution (best effort, from /proc)
# =============================================================================
@dataclass
class ProcInfo:
    pid: int
    uid: int
    cmdline: str
    exe: str
    open_canaries: List[str] = field(default_factory=list)


def _read(path: str) -> str:
    try:
        with open(path, "r", errors="replace") as fh:
            return fh.read()
    except (OSError, PermissionError):
        return ""


def iter_processes() -> Iterable[ProcInfo]:
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        status = _read(f"/proc/{pid}/status")
        uid = -1
        for line in status.splitlines():
            if line.startswith("Uid:"):
                parts = line.split()
                if len(parts) > 1:
                    try:
                        uid = int(parts[1])
                    except ValueError:
                        uid = -1
                break
        cmdline = _read(f"/proc/{pid}/cmdline").replace("\x00", " ").strip()
        if not cmdline:
            cmdline = _read(f"/proc/{pid}/comm").strip()
        try:
            exe = os.readlink(f"/proc/{pid}/exe")
        except OSError:
            exe = ""
        yield ProcInfo(pid=pid, uid=uid, cmdline=cmdline, exe=exe)


def attribute_breach(canary_paths: Sequence[str], self_pid: int) -> List[ProcInfo]:
    """Find processes that currently hold a canary open, or that mention one."""
    suspects: List[ProcInfo] = []
    canary_set = set(canary_paths)
    basenames = {os.path.basename(p) for p in canary_paths}

    for proc in iter_processes():
        if proc.pid in (self_pid, 1):
            continue
        holding: List[str] = []
        fd_dir = f"/proc/{proc.pid}/fd"
        try:
            for fd_name in os.listdir(fd_dir):
                try:
                    target = os.readlink(os.path.join(fd_dir, fd_name))
                except OSError:
                    continue
                if target in canary_set:
                    holding.append(target)
        except (OSError, PermissionError):
            pass

        mentions = any(b in proc.cmdline for b in basenames)
        if holding or mentions:
            proc.open_canaries = holding
            suspects.append(proc)
    return suspects


# =============================================================================
#  Containment
# =============================================================================
def kill_processes(target_uid: Optional[int], self_pid: int, dry_run: bool = False) -> List[int]:
    """SIGKILL every candidate agent process. Never touches PID 1 or self."""
    killed: List[int] = []

    for proc in iter_processes():
        # PID 1 is the warden entrypoint (and is signal-protected inside the
        # namespace anyway); it is told about the breach with SIGUSR1 instead.
        if proc.pid in (1, self_pid):
            continue
        if target_uid is not None and proc.uid != target_uid:
            continue
        if dry_run:
            killed.append(proc.pid)
            continue
        try:
            os.kill(proc.pid, signal.SIGKILL)
            killed.append(proc.pid)
        except ProcessLookupError:
            continue
        except PermissionError:
            log(f"cannot signal pid {proc.pid} (no CAP_KILL for uid {proc.uid})")
    return killed


def write_breach_record(run_dir: Path, record: dict) -> None:
    try:
        run_dir.mkdir(parents=True, exist_ok=True)
        flag = run_dir / "breach.flag"
        with open(flag, "w") as fh:
            fh.write(json.dumps(record, indent=2, sort_keys=True))
            fh.write("\n")
        os.chmod(flag, 0o444)
    except OSError as exc:
        log(f"could not persist breach record: {exc}")

    # A second copy in the workspace makes the incident visible on the host
    # even after the container is gone.
    workspace = os.environ.get("WARDEN_WORKSPACE", "/workspace")
    try:
        report = Path(workspace) / "WARDEN_SECURITY_INCIDENT.json"
        with open(report, "w") as fh:
            fh.write(json.dumps(record, indent=2, sort_keys=True))
            fh.write("\n")
    except OSError:
        pass


# =============================================================================
#  Monitor
# =============================================================================
class CanaryMonitor:
    def __init__(
        self,
        canaries: Sequence[str],
        mode: str,
        action: str,
        run_dir: Path,
        target_uid: Optional[int],
        signal_pid1: bool,
    ) -> None:
        self.canaries = [os.path.abspath(p) for p in canaries if p]
        self.mode = mode
        self.action = action
        self.run_dir = run_dir
        self.target_uid = target_uid
        self.signal_pid1 = signal_pid1
        self.self_pid = os.getpid()
        self.inotify = Inotify()
        self.wd_files: Dict[int, str] = {}
        self.wd_dirs: Dict[int, str] = {}
        self.dir_basenames: Dict[str, set] = {}
        self.deaf_dirs: Dict[str, bool] = {}
        self.degraded: List[str] = []
        self._running = True

    # --- watch management -----------------------------------------------------
    def arm(self) -> int:
        armed = 0
        for path in self.canaries:
            directory = os.path.dirname(path) or "/"
            self.dir_basenames.setdefault(directory, set()).add(os.path.basename(path))

        # Measure inotify delivery once per directory before trusting any watch.
        for directory in self.dir_basenames:
            if not os.path.isdir(directory):
                continue
            fstype = filesystem_of(directory)
            delivers = probe_inotify_delivery(directory)
            self.deaf_dirs[directory] = delivers is False
            if delivers is True:
                log(f"watchable  : {directory} ({fstype}) - inotify delivers events")
            elif delivers is False:
                alert(
                    f"DEGRADED   : {directory} ({fstype}) does NOT deliver inotify events. "
                    "Canaries on this path CANNOT be enforced."
                )
                alert(
                    "DEGRADED   : this is normal for Docker Desktop bind mounts on "
                    "Windows/macOS (9p/virtiofs). See docs/THREAT_MODEL.md 4.5."
                )
            else:
                log(f"unknown    : {directory} ({fstype}) - could not probe (not writable?)")

        for path in self.canaries:
            directory = os.path.dirname(path) or "/"
            if self.deaf_dirs.get(directory):
                self.degraded.append(path)
                continue
            if os.path.isfile(path):
                try:
                    wd = self.inotify.add_watch(path, FILE_MASK | IN_EXCL_UNLINK)
                    self.wd_files[wd] = path
                    armed += 1
                except OSError as exc:
                    log(f"cannot watch {path}: {exc}")
            else:
                log(f"canary not present yet, watching its directory: {path}")

        for directory in self.dir_basenames:
            if not os.path.isdir(directory) or self.deaf_dirs.get(directory):
                continue
            try:
                wd = self.inotify.add_watch(directory, DIR_MASK)
                self.wd_dirs[wd] = directory
            except OSError as exc:
                log(f"cannot watch directory {directory}: {exc}")

        # Discard anything the probes left in the queue.
        self.inotify.read_events()
        return armed

    def rearm_file(self, path: str) -> None:
        if self.deaf_dirs.get(os.path.dirname(path) or "/"):
            return
        if not os.path.isfile(path):
            return
        if path in self.wd_files.values():
            return
        try:
            wd = self.inotify.add_watch(path, FILE_MASK | IN_EXCL_UNLINK)
            self.wd_files[wd] = path
            log(f"re-armed watch on {path}")
        except OSError as exc:
            log(f"cannot re-arm {path}: {exc}")

    # --- main loop ------------------------------------------------------------
    def stop(self, *_args) -> None:
        self._running = False

    def run(self) -> int:
        signal.signal(signal.SIGTERM, self.stop)
        signal.signal(signal.SIGINT, self.stop)

        armed = self.arm()
        log(
            f"v{WARDEN_VERSION} mode={self.mode} action={self.action} "
            f"enforced={armed}/{len(self.canaries)} watching="
            + ", ".join(sorted(self.wd_files.values()))
        )
        if self.degraded:
            alert(
                f"{len(self.degraded)} canary path(s) are NOT enforced on this host: "
                + ", ".join(self.degraded)
            )
        if armed == 0:
            alert(
                "NO canary is enforceable here. The tripwire is inert - rely on "
                "capability dropping, the mount scope and the egress allowlist."
            )
        # Publish readiness so the entrypoint can hold the agent back until the
        # watches are actually in place, instead of guessing with a sleep.
        try:
            self.run_dir.mkdir(parents=True, exist_ok=True)
            (self.run_dir / "armed").write_text(f"{armed}\n")
        except OSError:
            pass

        while self._running:
            try:
                ready, _, _ = select.select([self.inotify.fd], [], [], 1.0)
            except (InterruptedError, OSError):
                continue
            if not ready:
                # Cheap self-healing: a canary deleted and recreated outside an
                # inotify event still gets re-armed within a second.
                for path in self.canaries:
                    if path not in self.wd_files.values():
                        self.rearm_file(path)
                continue

            for wd, mask, _cookie, name in self.inotify.read_events():
                if mask & IN_IGNORED:
                    self.wd_files.pop(wd, None)
                    continue

                path = self.wd_files.get(wd)
                if path is not None:
                    self.trip(path, mask)
                    return BREACH_EXIT_CODE

                directory = self.wd_dirs.get(wd)
                if directory is not None and name in self.dir_basenames.get(directory, set()):
                    full = os.path.join(directory, name)
                    if mask & (IN_DELETE | IN_MOVED_FROM):
                        self.trip(full, mask)
                        return BREACH_EXIT_CODE
                    if mask & (IN_CREATE | IN_MOVED_TO):
                        # Re-created by the agent (classic tamper attempt) or by
                        # the entrypoint during seeding. Re-arm and keep going.
                        self.rearm_file(full)

        log("shutting down cleanly")
        self.inotify.close()
        return 0

    # --- breach handling ------------------------------------------------------
    def trip(self, path: str, mask: int) -> None:
        event = describe_mask(mask)
        alert("[SECURITY BREACH] Canary file accessed by Agent Process!")
        alert(f"[SECURITY BREACH] file={path} event={event} mode={self.mode}")

        suspects = attribute_breach(self.canaries, self.self_pid)
        for proc in suspects:
            alert(
                f"[SECURITY BREACH] suspect pid={proc.pid} uid={proc.uid} "
                f"exe={proc.exe or '?'} cmd={proc.cmdline[:180]!r}"
            )
        if not suspects:
            alert(
                "[SECURITY BREACH] no process still holds the file open "
                "(short-lived reader such as `cat`); attribution unavailable"
            )

        record = {
            "schema": "ai-warden/breach/1",
            "warden_version": WARDEN_VERSION,
            "timestamp_utc": _ts(),
            "canary_path": path,
            "inotify_event": event,
            "mode": self.mode,
            "action": self.action,
            "monitor_pid": self.self_pid,
            "suspects": [
                {
                    "pid": p.pid,
                    "uid": p.uid,
                    "exe": p.exe,
                    "cmdline": p.cmdline[:500],
                    "open_canaries": p.open_canaries,
                }
                for p in suspects
            ],
        }
        write_breach_record(self.run_dir, record)

        if self.action == "log":
            alert("[SECURITY BREACH] action=log - not terminating (audit mode)")
            return

        killed = kill_processes(self.target_uid, self.self_pid)
        alert(f"[SECURITY BREACH] SIGKILL delivered to {len(killed)} process(es): {killed}")

        if self.signal_pid1:
            try:
                os.kill(1, signal.SIGUSR1)
                alert("[SECURITY BREACH] SIGUSR1 sent to PID 1 - container will exit 99")
            except (ProcessLookupError, PermissionError) as exc:
                log(f"could not signal PID 1: {exc}")

        self.inotify.close()


# =============================================================================
#  Optional watchdog cross-check
# =============================================================================
def watchdog_available() -> bool:
    try:
        import watchdog  # noqa: F401

        return True
    except ImportError:
        return False


# =============================================================================
#  CLI
# =============================================================================
def parse_canaries(raw: str) -> List[str]:
    if not raw:
        return []
    # Accept both ':' (env-style) and ',' separated lists.
    parts: List[str] = []
    for chunk in raw.split(","):
        parts.extend(chunk.split(":"))
    return [p.strip() for p in parts if p.strip()]


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="canary_monitor.py",
        description="AI Warden honeypot canary tripwire",
    )
    parser.add_argument(
        "--canaries",
        default=os.environ.get("WARDEN_CANARY_FILES", "/workspace/.secrets.canary"),
        help="':' or ',' separated list of canary file paths",
    )
    parser.add_argument(
        "--mode",
        choices=("inline", "sentinel"),
        default="inline",
        help="inline: same container as the agent. sentinel: sidecar with CAP_KILL.",
    )
    parser.add_argument(
        "--action",
        choices=("kill", "log"),
        default=os.environ.get("WARDEN_CANARY_ACTION", "kill"),
        help="kill: terminate the sandbox. log: audit only.",
    )
    parser.add_argument("--run-dir", default="/run/warden", help="where breach.flag is written")
    parser.add_argument(
        "--target-uid",
        type=int,
        default=int(os.environ.get("WARDEN_TARGET_UID", "1001")),
        help="UID whose processes are killed on a breach",
    )
    parser.add_argument(
        "--wait-for-canaries",
        type=float,
        default=0.0,
        help="seconds to wait for at least one canary to appear before arming",
    )
    parser.add_argument(
        "--quiesce",
        type=float,
        default=-1.0,
        help="seconds of no writes to any canary before arming "
             "(default: 3s in sentinel mode, 0s inline)",
    )
    args = parser.parse_args(argv)

    if not sys.platform.startswith("linux"):
        log("FATAL: inotify is Linux-only; this monitor must run inside the container")
        return 78

    canaries = parse_canaries(args.canaries)
    if not canaries:
        log("FATAL: no canary paths configured")
        return 78

    # Wait for the entrypoint to finish seeding before arming.
    #
    # This matters for the out-of-band sentinel, which starts in its own
    # container and has no way to know how far the agent container has got. If
    # it armed halfway through seeding it would trip on the warden's own writes.
    # The gate is "at least one canary exists AND nothing has touched any of
    # them for `quiesce` seconds", which needs no shared marker file - and so
    # cannot be forged by the agent to arm the sentinel early.
    quiesce = args.quiesce if args.quiesce >= 0 else (3.0 if args.mode == "sentinel" else 0.0)
    deadline = time.time() + args.wait_for_canaries
    while time.time() < deadline:
        present = [p for p in canaries if os.path.isfile(p)]
        if present:
            newest = 0.0
            for p in present:
                try:
                    st = os.stat(p)
                    newest = max(newest, st.st_mtime, st.st_ctime)
                except OSError:
                    continue
            if time.time() - newest >= quiesce:
                break
        time.sleep(0.25)

    log(
        "watchdog library: "
        + ("available (secondary detector)" if watchdog_available() else "absent (inotify only)")
    )

    monitor = CanaryMonitor(
        canaries=canaries,
        mode=args.mode,
        action=args.action,
        run_dir=Path(args.run_dir),
        # In sentinel mode we hold CAP_KILL and can reap the agent's UID.
        # Inline we are the agent's UID, so the same filter applies.
        target_uid=args.target_uid,
        # Only the in-container monitor can meaningfully signal PID 1.
        signal_pid1=(args.mode == "inline"),
    )
    return monitor.run()


if __name__ == "__main__":
    sys.exit(main())
