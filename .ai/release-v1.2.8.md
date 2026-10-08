> **Small security follow-up — PID 1's own log no longer claims the tripwire sent a signal it couldn't verify.** Upgrade from v1.2.7; rebuild the agent image.

```bash
git fetch --tags && git checkout v1.2.8
./scripts/warden-cli.sh build --pull
./scripts/verify-isolation.sh            # phases A-L must pass
```

## Security

- **PID 1's own log line claimed an attribution it couldn't verify.** v1.2.7 fixed the CLI's
  breach *headline* so it only credits the sentinel when the sentinel actually confirmed a
  breach. The entrypoint's own log line had the same gap: on receiving SIGUSR1 with a breach
  record present, it logged `SIGUSR1 received from the canary tripwire` even when that record
  was written entirely inside the agent's reach (workspace, `breach.flag`) and the signal could
  have come from the agent itself. It now logs `SIGUSR1 received with a breach record present
  (written inside the agent's reach)` instead — stating what's provable, not what's assumed.
  Extends drill **E11** to PID 1's log output (negative CI failed ext4/gVisor/Kata on the old
  line; fix green on all three).

## Verified

Full `verify-isolation.sh` suite (phases A–L) run twice on Docker Desktop this release: once
against the merged fix before the version strings were bumped, once after, both clean — exit 0,
`enforced=4/7`, including **3b2, L, E9, E10, E11 and E12 passing on Docker Desktop for the first
time** (previously proven on CI real-image runs only). `docs/VERIFICATION.md` §0 re-quoted from
the second run.

---
v1.2.7 is marked superseded by this release.
