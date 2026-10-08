> **Security release — closes a DNS exfiltration channel through the egress proxy.** Upgrade from v1.2.5; rebuild both images (`./scripts/warden-cli.sh build --pull`).

```bash
git fetch --tags && git checkout v1.2.6
./scripts/warden-cli.sh build --pull
./scripts/verify-isolation.sh            # phases A-L must pass
```

## Security

- **DNS exfiltration through the egress proxy.** Squid resolved every CONNECT hostname
  *before* checking it against the allowlist (a `dst` ACL needing the resolve sat ahead of
  the deny rule), so a name's own label could carry data to an attacker-controlled
  nameserver even though the CONNECT itself was refused with 403. Fixed by rule order —
  non-allowlisted names are now denied by name, never resolved. New phase **L** (real proxy
  image + a fake DNS server that logs every query; fails on the old config) and self-test
  **3b2** (Docker's own resolver must not answer names outside the allowlist). See
  `docs/THREAT_MODEL.md` §4.2.
- **Silent inotify queue overflow.** When the vault's inotify queue filled (16384 events),
  the kernel drops events that follow — including the OPEN on a canary — while the monitor
  kept reporting itself armed. Queue overflow (`IN_Q_OVERFLOW`, watch descriptor `-1`) now
  trips the tripwire (exit 99) with `events lost: inotify queue overflowed` and a record that
  says "cannot rule out a read" instead of claiming one happened. Drill **E9**.
- **A sentinel-only breach left no record and was called "possibly forged."** On a 0755
  Linux workspace the root sentinel has no `CAP_DAC_OVERRIDE` and can't write a report; if it
  kills the inline monitor first, no report exists at all, yet the CLI still printed
  "possibly forged termination" even when the sentinel itself had confirmed the breach. The
  CLI now writes its own record from the sentinel's log (`WARDEN_SECURITY_INCIDENT.sentinel-log.<ts>.json`,
  schema `ai-warden/breach-witness/1`, `O_EXCL`) and never calls a sentinel-confirmed breach
  forged. Drill **E10**.
- A canary directory the monitor can't probe (`unknown`) no longer counts toward
  `enforced=N/M` — it's reported `UNVERIFIED` and still watched.

## Verified

Real-image CI on `ext4` and `gVisor` runtimes (temp-branch proof before merge, then on `main`
and this tag): all 4 jobs green, including a negative run that fails phases L/E9/E10 on the
pre-fix code. **Not yet run against Docker Desktop at tag time** — tracked in
[`.ai/HANDOFF.md`](../blob/main/.ai/HANDOFF.md) Next steps; this tag was cut by a session with
write access to ship a confirmed-real fix to a public repo rather than wait.

---
v1.2.5 is marked superseded by this release.
