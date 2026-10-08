> **Security + compatibility release — breach headlines need the sentinel, and non-interactive sessions no longer hang under Kata.** Upgrade from v1.2.6; rebuild both images.

```bash
git fetch --tags && git checkout v1.2.7
./scripts/warden-cli.sh build --pull
./scripts/verify-isolation.sh            # phases A-L must pass
```

## Security

- **CLI headlined an agent-forged report as the tripwire's.** An agent that writes
  `WARDEN_SECURITY_INCIDENT.json` into the workspace itself and signals `kill -USR1 1` used
  to get the same "SECURITY BREACH: the canary tripwire terminated this sandbox" headline as
  a real, sentinel-confirmed breach — a false positive, not a bypass, but the headline named
  an author the CLI could not verify. The headline now appears only when the sentinel
  (outside the agent's reach) confirms; otherwise it reads `SECURITY BREACH (unconfirmed)` —
  still exit 99, still shows the report, still tells you to rotate keys. Cost accepted: a
  real breach on a home-directory canary (`~/.aws`, `~/.ssh`, seen only by the inline
  monitor) and every breach under gVisor/Kata (no sentinel) now read unconfirmed too. Drill
  **E11**.

## Fixed

- **A non-interactive session hung forever under Kata on the agent's first prompt.** Without
  `-i`, runc hands the container's stdin as `/dev/null` (immediate EOF); Kata instead gives a
  pipe that never closes, so any agent prompt (e.g. aider's first-run question) blocked in
  `anon_pipe_read` — phase I hung 30+ minutes every time under Kata. `docker run -i ... </dev/null`
  does **not** fix this (Kata still never delivers EOF — confirmed, drill still timed out).
  The CLI now passes `WARDEN_STDIN=closed` when not attached to a TTY, and the entrypoint
  runs the agent with `</dev/null` from inside the cage — EOF arrives immediately on every
  runtime, matching what runc always did. Drill **E12** (old CLI: rc=142 hang; fixed: rc=1,
  clean exit).

## Added

- **Kata Containers supported, with limits.** New CI job `Kata Containers drills`: full suite
  against a real session through the proxy, live breach → exit 99, fork bomb stopped at the
  guest's `nproc` limit. Like gVisor, Kata trades the in-cage sentinel for the VM boundary —
  the CLI says `NOT armed` honestly rather than pretending to attach. `docs/THREAT_MODEL.md`
  §4.1 has the measured comparison table (PID namespace, inotify, `--pids-limit` scope, stdin).

## Verified

Real-image CI on ext4, gVisor and the new Kata job, including negative runs that fail E11/E12
on the pre-fix code; full suite green under Kata after the stdin fix (423s). **Not yet run
against Docker Desktop at tag time** — see [`.ai/HANDOFF.md`](../blob/main/.ai/HANDOFF.md).

---
v1.2.6 is marked superseded by this release.
