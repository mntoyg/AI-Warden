# AI Warden — Session Handoff

> **Living document.** Read it at the start of every session; update it at the end.
> **Reality beats this file.** If git, CI or the running system disagree with it,
> the system is right — fix this file in your first commit and say so.

- **Last updated:** 2026-09-14 (session 3)
- **Latest release:** [v1.0.1](https://github.com/mntoyg/AI-Warden/releases/tag/v1.0.1) — security release, marked Latest
- **Next prompt:** [`.ai/NEXT_PROMPT.md`](NEXT_PROMPT.md) (v2)

---

## 1. Status (verified 2026-09-14)

| Thing | State |
|---|---|
| `main` | `ff1fe75` (phase E drills) + this handoff commit, pushed, tree clean |
| Tags | `v1.0.0` (release notes carry a "superseded by v1.0.1" warning), `v1.0.1` (Latest) |
| CI | 3 jobs — static · image CVE scan · isolation drills on ext4 — **green** on `main` and on tag `v1.0.1`; the phase-E commit's run is the one to confirm green |
| Local suite (Docker Desktop / Windows) | Phase A 31/31 · B exit 99 · C exit 78 · D exit 99 · **E1–E4 all pass** · `enforced=4/7` (expected there) · suite exit 0 |
| CI suite (ext4) | all phases incl. E · `enforced=7/7` · compose handshake OK · 0 leaked volumes |
| CVEs | 0 HIGH/CRITICAL in OS packages and in `/opt/warden`; ~70 in the bundled agents' own trees (reported, deliberately not gated — see `SECURITY.md`) |

---

## 2. Next steps — priority order

Pick the top unchecked item unless the user asks for something else. Each has a
reason; if the reason no longer holds, delete the item instead of doing it.

1. **Close the mount-guard gaps that phase E3 surfaced.** This is the recurring bug
   shape: `assert_safe_mount` in `warden-cli.sh` reports itself as the guard rail
   yet ACCEPTS three classes of dangerous target today (found by *writing* the E3
   drill, not by reading the code):
   - `/bin`, `/sbin`, `/lib` — usrmerge symlinks. `real="$(cd "$abs" && pwd -P)"`
     resolves them to `/usr/bin` etc., which are not in the refuse list (`/usr` is,
     `/usr/bin` is not). Fix: also test the LOGICAL path `pwd -L` against the same
     `case` (input `/bin` → logical `/bin` → matches; `/var/www` → `/var/www` →
     still allowed, so no false positive).
   - `/media/usb` and `/cygdrive/c` — the `/media/*/` and `/cygdrive/*/` `case`
     patterns are DEAD: `pwd -P` never yields a trailing slash, so they can never
     match. A whole removable drive or a whole Windows drive is mountable. Fix:
     refuse when `dirname(real)` is `/media`, `/run/media` or `/cygdrive` (the drive
     root), while keeping `/mnt`'s existing single-letter rule so a hand-made
     `/mnt/project` still works, and still allowing a project nested inside a drive.
   Repro (each must be refused; none is today), inside the agent image:
   `. scripts/warden-cli.sh; assert_safe_mount /bin` and `assert_safe_mount /media/usb`
   both return 0 and set `RESOLVED_MOUNT`. When fixed, add these paths to phase E3
   (the harness is already there) and **ship the fix in a tag (v1.0.2)** — it is a
   security fix, not just a test.
2. **Weekly scheduled rebuild + CVE gate** (`on: schedule` in CI, build with `--pull`).
   v1.0.1 found libpcre2 only because a release forced a rebuild; drift in the base
   image should be caught on a timer, not by luck.
3. **Optional gVisor runtime** — `WARDEN_RUNTIME=runsc` passed through `warden-cli.sh`
   and compose. The threat model already *recommends* gVisor for kernel-escape
   defence but nothing in the tooling supports it.
4. **Investigate domain fronting through allowlisted CDN hosts** (e.g.
   `.githubusercontent.com` sits on a shared CDN). The proxy filters on the CONNECT
   host; whether a different `Host` inside TLS reaches another tenant is untested.
   Research item — do not claim a bypass or a defence until a probe proves it.
5. **Decide what to do with the 3 inert canaries on 9p.** On Docker Desktop they are
   seeded into the user's project but cannot be enforced. Options: stop seeding them
   where the probe says `DEGRADED`, or keep them as decoys. Needs a decision, not code first.

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
| `assert_safe_mount` string-matches paths, but `cd; pwd -P` resolves symlinks | On usrmerge hosts `/bin`→`/usr/bin`, so a name-based refuse list misses `/bin /sbin /lib`. Check `pwd -L` too (see Next-steps #1). |

---

## 6. Conventions

- Talk to the user in **Thai**; code, comments, commit messages and CI in **English**.
- Commit **and push after every completed step**. Author email is the GitHub noreply
  address (already configured in this repo). This repo is **public** by design.
- Commit messages explain *why*, and name the evidence (what was run, what it showed).
- Keep docs honest: limitations are stated, never softened (see `docs/THREAT_MODEL.md` §4).

---

## 7. Session log (newest first)

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
