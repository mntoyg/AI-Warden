# AI Warden — Session Handoff

> **Living document.** Read it at the start of every session; update it at the end.
> **Reality beats this file.** If git, CI or the running system disagree with it,
> the system is right — fix this file in your first commit and say so.

- **Last updated:** 2026-09-15 (session 5)
- **Latest release:** [v1.0.2](https://github.com/mntoyg/AI-Warden/releases/tag/v1.0.2) — mount-guard hardening (security), marked Latest
- **Next prompt:** [`.ai/NEXT_PROMPT.md`](NEXT_PROMPT.md) (v4)
- **🚩 MILESTONE — first live test: Monday 2026-09-21.** Keep `main` green and
  release-ready; reliability/security fixes before new features until then.

---

## 1. Status (verified 2026-09-15)

| Thing | State |
|---|---|
| `main` | `8f61b3e` (CI pull-hardening), tree clean; gVisor plumbing (`65f2cbd`) + this handoff on top |
| Tags | `v1.0.0` & `v1.0.1` both carry a "superseded" warning · `v1.0.2` (Latest) |
| CI | 3 jobs — static · image CVE scan · isolation drills on ext4 — **green** (tag `v1.0.2`: run 34937500342; gVisor commit `65f2cbd`: run 34946167536) |
| Local suite (Docker Desktop / Windows) | Phase A 34/34 · B exit 99 · C exit 78 · D exit 99 · E1–E4 pass · **F (runtime fail-closed) pass, passthrough proven via nvidia** · `enforced=4/7` · suite exit 0 |
| CI suite (ext4) | all phases incl. E + F · `enforced=7/7` · compose handshake OK · 0 leaked volumes (F passthrough skips: no non-default runtime on CI) |
| CVEs | 0 HIGH/CRITICAL in OS packages and in `/opt/warden` (trivy, debian 12.15); **74** in the bundled agents' own trees (reported, deliberately not gated — see `SECURITY.md`) |
| Security review (2026-09-15) | Egress boundary (squid.conf) strong: default-deny, IP-literal/RFC1918/loopback/link-local/cloud-metadata blocked, cache off, body cap, header/query hygiene. proxy-entrypoint fail-closed. **No new critical finding.** Only known bypass = SNI domain fronting (§4.2, accepted). |

---

## 2. Next steps — priority order

Pick the top unchecked item unless the user asks for something else. Each has a
reason; if the reason no longer holds, delete the item instead of doing it.

1. **gVisor: verify the happy-path on a real gVisor host, then tag v1.1.0.** The
   plumbing shipped (session 5): `WARDEN_RUNTIME` is passed to the agent and the
   sentinel by `warden-cli.sh` and compose, `assert_runtime` fails closed on an
   unavailable runtime (never downgrades to runc), and phase F proves fail-closed +
   that a valid runtime is actually applied e2e (using `nvidia` as a stand-in on the
   dev box). What is NOT yet verified: gVisor itself. On a host with `runsc`
   installed, run `WARDEN_RUNTIME=runsc ./scripts/verify-isolation.sh` — phase F's
   passthrough check will pick runsc automatically — and specifically confirm the
   **sentinel** works, because gVisor + a shared PID namespace (`--pid container:`)
   is a known gVisor limitation and is untested (THREAT_MODEL §4.1). Only once that
   is green should "gVisor support" be claimed in a release (v1.1.0 - it is a feature,
   not a fix).
2. **(low) Cover the udisks two-level drive root `/media/<user>/<label>` in the mount
   guard.** v1.0.2 refuses one level under `/media`/`/run/media`/`/cygdrive`, but the
   udisks layout puts the drive root two levels down (`/media/john/USB`), which is
   structurally indistinguishable from a project nested inside a drive
   (`/media/usb/app`, which must stay allowed). Needs a heuristic (e.g. is it itself a
   mountpoint?) not just a path pattern — decide before coding. Low risk: nobody keeps
   source at `/media/<user>/<label>` by hand, and $HOME/.ssh guards still apply.
### Decided this session (do not re-raise without new evidence)

- **SNI domain fronting → accept + document only** (user call, 2026-09-15). Bypass is
  real and written up in `docs/THREAT_MODEL.md` §4.2; the proxy stays simple. A strict
  deployment drops CDN-shared allowlist entries. Only revisit if someone needs a
  hardened egress profile — then it is a peek-and-splice proxy on a Linux host, item 1's
  cousin, not a config tweak.
- **3 inert canaries on 9p → keep seeding as decoys** (user call, 2026-09-15). They are
  honeytokens with value even unenforced; the monitor already reports `enforced=4/7`
  honestly and lists the DEGRADED paths, so nothing is claimed falsely.

---

## 3. Definition of done

Nothing is done until it has been run. Minimum before any commit that touches
behaviour:

```bash
./scripts/warden-cli.sh build          # if an image-affecting file changed (agent build ~5-10 min)
./scripts/verify-isolation.sh          # phases A-E must all pass
```

Before a release, additionally: shellcheck + hadolint + gitleaks + trivy (all run
via containers — see Gotchas), and CI green on the tag.

---

## 4. Architecture in 60 seconds

- Agent container: uid 1001, `--cap-drop=ALL`, `no-new-privileges`, no setuid bits,
  on network `warden_internal` which is `internal: true` → no route out at all.
- `warden-egress-proxy` (Squid) is dual-homed and the only exit; default deny,
  allowlist in `core/network/whitelist_domains.txt`; no SSL-bump by design.
- Canary tripwire, two layers: inline monitor (same uid as the agent) + a sentinel
  container (root, CAP_KILL only, no network, shared PID namespace, `--group-add 1001`).
- Canary vault = named volume at `/workspace/.secrets`, shared by both, because the
  9p bind mount delivers no inotify events and a tmpfs is invisible to the sentinel.
- Entrypoint ↔ sentinel handshake via `.warden-seeded` / `.warden-sentinel-armed`.
- Exit codes: `99` breach · `78` refused unsafe posture · `143` SIGTERM.

---

## 5. Gotchas — each of these cost real time

**The recurring bug shape:** a control that reports itself armed while enforcing
nothing. Every serious defect so far was this. For any guard you touch, ask "how
would I know if this silently did nothing?" — then run that.

| Gotcha | What to do |
|---|---|
| Docker Desktop is often not running at session start | `Start-Process "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"` (PowerShell), then poll `docker info` in the background |
| Bash tool is Git Bash: `/workspace` gets rewritten into a Windows path | `export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'` — and then pass *host* paths through `cygpath -w` |
| Backslashes and `\n` inside heredoc-fed Python collapse | Use `chr(92)`/`chr(10)`, or the Write/Edit tools, for any source containing backslashes |
| Backticks in `git commit -m` get eaten | Write the message to a file and use `git commit -F file` |
| `set -e` + `[ test ] && cmd` exits the script when the test is false | Use `if ...; then ...; fi` |
| `die` inside `$(...)` only kills the subshell | Call guard functions directly; publish results in a global |
| shellcheck, hadolint, make, pyyaml are not installed on the host | Run them via containers (`koalaman/shellcheck`, `hadolint/hadolint`, `debian:bookworm-slim` + make, `python:3.11-slim` + pyyaml) |
| Squid refuses to start if the allowlist has a wildcard and one of its own subdomains | One form per zone; the proxy image runs `squid -k parse` at build time |
| Compose will not adopt a network made with `docker network create` | Only compose creates `warden_internal` / `warden_external` |
| gitleaks in CI on a shallow checkout sees one synthetic commit | `fetch-depth: 0`; `.gitleaksignore` is commit-fingerprint based |
| trivy gate went red with no code change (base-image drift) | Both Dockerfiles run `apt-get upgrade`; rebuild with `--pull` before releasing |
| Security fixes sitting on `main` ship to nobody | Cut a tag; flag the old release |
| GitHub accepts some writes and changes nothing | Re-read after every release/settings edit |
| A `set +e … set -e` pair assumes errexit is the baseline | This suite runs `set -uo pipefail` (NO `-e`). A stray `set -e` leaked out of phase D and a *legitimate* exit-99 breach drill then killed the whole suite silently. Restore with `set +e`, or save/restore `$-`. |
| `assert_safe_mount` string-matches paths, but `cd; pwd -P` resolves symlinks | On usrmerge hosts `/bin`→`/usr/bin`, so a name-based refuse list misses `/bin /sbin /lib`. Fixed in v1.0.2 by also checking `pwd -L`. |
| `warden-cli.sh build --pull` used to drop the flag | Fixed: `cmd_build` now puts `"$@"` BEFORE the context and applies it to both images. `warden-cli.sh build --pull` re-pulls the base for proxy + agent. |
| Debian's squid (5.7, `--with-gnutls`, no `--with-openssl`) has no `ssl_bump` | `squid -k parse` on any `at_step`/`ssl_bump` line dies `FATAL: Invalid ACL type 'at_step'`. Peek-and-splice / SNI enforcement needs a different squid build. Relevant to the §4.2 domain-fronting decision. |
| CI "Secret scan" flakes on the Docker Hub pull | It pulls `zricethezav/gitleaks:latest` at runtime; Docker Hub occasionally resets the connection (`read: connection reset by peer`, exit 125). Not your code — `gh run rerun <id> --failed`. Pinning + a pull retry would remove it (low-priority next-step). |

---

## 6. Conventions

- Talk to the user in **Thai**; code, comments, commit messages and CI in **English**.
- Commit **and push after every completed step**. Author email is the GitHub noreply
  address (already configured in this repo). This repo is **public** by design.
- Commit messages explain *why*, and name the evidence (what was run, what it showed).
- Keep docs honest: limitations are stated, never softened (see `docs/THREAT_MODEL.md` §4).

---

## 7. Session log (newest first)

### 2026-09-15 — session 5 · CVE-drift gate · fronting probe · resource drill
(same chat as session 4, continued after the v1.0.2 release)
- **Did:** (1) shipped the **weekly scheduled CVE gate** — added a Monday cron and made
  the CI builds `--pull`; fixed `cmd_build`, which appended `"$@"` after the context
  (a no-op) and only on the agent image, so `warden-cli.sh build --pull` now re-pulls
  the base for both images. (2) **Confirmed SNI domain fronting** with a working exploit
  against our own proxy (`--connect-to octocat.github.io:443:raw.githubusercontent.com:443`
  → 200 `<title>Octocat.github.io</title>`, squid logged CONNECT to the allowlisted host);
  wrote it up in THREAT_MODEL §4.2. No in-proxy fix: Debian squid has no `ssl_bump`.
  (3) **Audited cgroup resource limits** and turned the audit into a Phase-A drill
  (memory.max, memory.swap.max=0, pids.max) — 34/34, teeth verified against an
  unconstrained container. (4) Recorded 2 user decisions: fronting = document-only,
  inert 9p canaries = keep as decoys. All green locally and in CI (one transient
  gitleaks Docker Hub pull reset in `static`, fixed by `gh run rerun --failed`).
- **Learned:** the runnable, non-decision backlog is now empty on this host — gVisor
  needs a Linux box with `runsc`, and shipping a `--runtime` passthrough here (unverifiable)
  would be the very bug this project hunts. A decision item can resolve to "no code"; that
  is a finished item, not a gap. Writing a drill (E3 last time, resources this time) keeps
  finding real things reading the code did not.
- **Prompt should have said:** don't manufacture code to fill a session — when the
  runnable backlog is clear, verify what you shipped and hand off. And expect the CI
  gitleaks step to flake on its Docker Hub pull; re-run rather than "fix" it.

### 2026-09-15 — session 4 · v1.0.2 (mount-guard hardening)
- **Did:** closed the mount-guard gaps phase E3 surfaced last session.
  `assert_safe_mount` now checks BOTH `pwd -P` and `pwd -L` (catches usrmerge
  `/bin /sbin /lib`) and refuses a drive root by its parent (`/media`, `/run/media`,
  `/cygdrive`), while still allowing a project nested in a drive and keeping `/mnt`'s
  single-letter rule. Expanded E3 to 23 refuse-cases + 2 accept-cases. Bumped
  version to 1.0.2 (CLI, entrypoint, monitor), wrote CHANGELOG, rebuilt both images
  with `--pull` (trivy: 0 HIGH/CRITICAL, debian 12.15), verified A–E green on the
  fresh image, tagged **v1.0.2** (CI green on the tag, run 34937500342), and
  amended the v1.0.1 notes with a superseded warning (they had claimed "whole
  drives — all refused", which was untrue).
- **Learned:** Docker Desktop was down at session start (the day rolled over) —
  starting it cost ~1 min, as the prompt warned. `warden-cli.sh build --pull` does
  not actually pass `--pull` (it lands after the build context); use `docker build`
  directly for a release rebuild. The residual udisks `/media/<user>/<label>` case
  can't be closed with a path pattern alone — it's now Next-steps #5, not a rushed fix.
- **Prompt should have said:** it already said "start Docker Desktop first" and it
  paid off. Added this session: for a release rebuild, call `docker build --pull`
  directly, and a security fix (even one that only touches a host script) still owes
  a tag + a superseded note on the release it replaces.

### 2026-09-14 — session 3 · phase E drills
- **Did:** added Phase E to `verify-isolation.sh` — the four v1.0.1 audit exploits
  as permanent regression drills (E1 report-symlink redirect, E2 argv log injection,
  E3 mount guard, E4 dangling canary symlink), each written to FAIL against the
  pre-fix behaviour. Made `warden-cli.sh` sourceable (guarded `main`) so E3 exercises
  the real `assert_safe_mount`. Fixed a latent phase-D bug: it ended with `set -e`,
  which — once Phase E followed it — turned a legitimate exit-99 breach drill into a
  silent whole-suite abort with code 99. Updated README (was "3 phases", missing D
  and E) and VERIFICATION.md to 5 phases. Suite A–E green locally, exit 0, `enforced=4/7`.
- **Learned:** writing the E3 drill is what exposed real mount-guard holes
  (`/media/usb`, and usrmerged `/bin /sbin /lib` accepted); reading the code had not.
  That is the whole argument for "new behaviour gets a drill." I did NOT fold the fix
  into E3 — the correct fix has cross-platform nuance and is a tagged security change,
  so it is Next-steps #1 with a repro, and E3 asserts only what v1.0.1 shipped.
- **Prompt should have said:** the suite baseline is `set -uo pipefail` (no `-e`), so
  never write `set -e` inside a phase; and a new drill can uncover a new bug — record
  it as a Next-step with a repro, don't silently widen scope or drop the finding.

### 2026-09-14 — session 2 · v1.0.1
- **Did:** found the audit fixes were only on `main`, not in any tag → v1.0.1
  security release; rebuilding for it tripped the trivy gate on libpcre2 (2× HIGH) →
  root cause was no `apt-get upgrade` in either Dockerfile; `actions/checkout@v5`;
  fixed stale VERIFICATION.md (phase D missing) and a stale `0400` comment; flagged
  v1.0.0 as superseded; created this handoff loop.
- **Learned:** a CVE gate is only as good as its trigger — it caught drift on the
  first rebuild in 8 days, which is an argument for rebuilding on a schedule.
- **Prompt should have said:** "check whether the last fixes are in a tag" and
  "start Docker Desktop first" — both now in the prompt.

### 2026-09-06 — session 1 · v1.0.0
- **Did:** built the whole project; bug hunt driven by running the drills (9p inotify,
  sentinel capabilities, arming race, exit-99 contract, compose labels, squid
  overlaps); CI with drills on ext4; full security audit (4 fixes).
- **Exploits used in the audit** (re-use them for Phase E):
  - Symlink redirect: in the sandbox, `ln -sf /home/ai_user/.bashrc /workspace/WARDEN_SECURITY_INCIDENT.json`,
    then `cat /workspace/.secrets/credentials`. Expect: ELOOP logged, link untouched,
    `WARDEN_SECURITY_INCIDENT.<pid>.<ts>.json` written with `report_path_tampered`.
  - Log injection: `exec -a "$(printf 'evil\033[2K\033[1G[canary ...] all clear')" sh -c 'cat /workspace/.secrets/credentials'`.
    Expect the escapes rendered as `?[2K?[1G` in the suspect line.
  - Mount guard: source `assert_safe_mount` from `warden-cli.sh` in a Debian container
    and feed it `/ /home /Users /mnt /mnt/c /media /srv /etc /usr /var /root` — all must refuse.
  - Sentinel drill (already Phase D): `pkill -9 -f "canary_mon[i]tor"` then read a canary.

---

## 8. Prompt changelog

Every change to `NEXT_PROMPT.md` gets one line here: version, date, what changed,
and the concrete event that motivated it. If a change made sessions worse, revert
it and say why.

- **v1 · 2026-09-14** — first version. Built from sessions 1–2: start-of-session
  reality check (tree/tags/CI/Docker), "prove by running", the recurring bug shape,
  mandatory end-of-session handoff + prompt rewrite with evidence and a size cap.
- **v2 · 2026-09-14** — session 3. Added: (a) "the suite is `set -uo pipefail`, never
  add `set -e`" — a stray `set -e` in phase D silently killed the suite at exit 99
  when phase E ran after it, ~20 min to trace because there was no error message;
  (b) "a new drill may find a new bug — record it with a repro, don't widen scope" —
  E3 surfaced live mount-guard holes. Dropped the v1 line about tolerating a slow
  first `docker info` (Docker was already up; it never cost time).
- **v3 · 2026-09-15** — session 4. Added the release-rebuild note: `warden-cli.sh
  build --pull` does not pass `--pull` (it lands after the context), so call
  `docker build --pull` directly; and a security fix owes a tag + a superseded note
  on the release it replaces. Restored the "start Docker Desktop first" emphasis —
  it was down at session start and the prompt's warning saved time, so it stays.
- **v4 · 2026-09-15** — session 5. Corrected the now-stale v3 line: `warden-cli.sh
  build --pull` was FIXED this session and re-pulls both images, so the prompt says
  to use it (not raw docker). Added: a Next-steps item may resolve to "no code" (a
  decision, or a feature unverifiable on this host like gVisor) — that's finished, not
  a gap; when the runnable backlog is clear, hand off instead of manufacturing work;
  and the CI gitleaks step flakes on its Docker Hub pull (re-run, don't "fix"). Shrank
  the "why" section to prose to stay under 70 lines.
