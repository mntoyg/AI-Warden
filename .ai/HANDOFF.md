# AI Warden — Session Handoff

> **Living document.** Read it at the start of every session; update it at the end.
> **Reality beats this file.** If git, CI or the running system disagree with it,
> the system is right — fix this file in your first commit and say so.

- **Last updated:** 2026-09-16 (session 7)
- **Latest release:** [v1.0.4](https://github.com/mntoyg/AI-Warden/releases/tag/v1.0.4) — forensic honesty fix (attribution verdict + argv-impersonation evasion), marked Latest
- **Next prompt:** [`.ai/NEXT_PROMPT.md`](NEXT_PROMPT.md) (v7)
- **🚩 MILESTONE — first live test: Monday 2026-09-21** (video, pushed to GitHub;
  run on THIS Windows Docker Desktop, real agent + live breach, enforced=4/7). Keep
  `main` green and release-ready; reliability/trust fixes before new features.

---

## 1. Status (verified 2026-09-16, session 7)

| Thing | State |
|---|---|
| `main` | handoff/prompt commit on top of `9bdae58` (the v1.0.4 fix, = tag `v1.0.4`), tree clean, in sync with origin |
| Tags | `v1.0.0`…`v1.0.3` all carry a "superseded" warning · `v1.0.4` (Latest) |
| CI | 3 jobs — static · image CVE scan · isolation drills on ext4 — **green on `main` `9bdae58`** (run 35076143327: phase D `restricted` + E5 pass, `enforced=7/7`) and on tag `v1.0.4` (run 35076865482) |
| Local suite (Docker Desktop / Windows) | re-verified on the v1.0.4 image: A · B exit 99 · C exit 78 · D exit 99 + single clean report + **sentinel report `"attribution": "restricted"`** · E1–E5 · F · `enforced=4/7` · exit 0 |
| CI suite (ext4) | all phases A–F · `enforced=7/7` · compose handshake OK · 0 leaked volumes (F passthrough skips on CI: no non-default runtime) |
| CVEs | trivy on the v1.0.4 images: 0 HIGH/CRITICAL OS packages (both images) · 0 in `/opt/warden` · **74** in bundled-agent deps (reported, not gated — `SECURITY.md`) |
| Security review (2026-09-15) | Egress boundary (squid.conf) strong: default-deny, IP-literal/RFC1918/loopback/link-local/cloud-metadata blocked, cache off, body cap, header/query hygiene. proxy-entrypoint fail-closed. **No new critical finding.** Only known bypass = SNI domain fronting (§4.2, accepted). |
| Demo readiness | `./scripts/demo.sh --auto` on v1.0.4: **DEMO COMPLETE, exit 0** (act 3 now also asserts the attribution verdict). `claude --version` inside the v1.0.4 sandbox → `2.1.197 (Claude Code)`, exit 0. **Not done: the `--agent claude` rehearsal — there is no `ANTHROPIC_API_KEY` on this box** (the agent's shell never has it; the user must provide it via `.env` or their own terminal). |

---

## 2. Next steps — priority order

Pick the top unchecked item unless the user asks for something else. Each has a
reason; if the reason no longer holds, delete the item instead of doing it.

1. **Monday rehearsal — blocked on the user's API key, not on code.** Needs
   `ANTHROPIC_API_KEY` in `.env` (gitignored; `warden-cli.sh` passes it with
   `--env-file`) or exported in the user's own terminal — never pasted into chat.
   Then: `./scripts/demo.sh --auto` (must end `DEMO COMPLETE`, exit 0) and one
   `./scripts/demo.sh --agent claude` rehearsal following `docs/DEMO.md` act 4.
   The agent's Bash tool does not inherit the user's terminal exports, so if the
   user runs the rehearsal themselves, read their terminal instead of re-running.
2. **gVisor: verify the happy-path on a real gVisor host, then tag v1.1.0.** The
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
3. **(low, idea) Surface the inline monitor's richer record without new privileges.**
   v1.0.4 makes the sentinel's report honest (`restricted`), but the full view
   (open-descriptor proof, exe) still only reaches the terminal log. The entrypoint's
   USR1 trap could print `/run/warden/breach.flag` the way the normal-exit path
   already does - BUT that file is written by uid 1001 into a tmpfs the agent owns,
   so the agent can replace it: anything printed from it must be labelled as
   agent-forgeable, never as "the record". Decide the labelling before coding; do
   not merge it into the sentinel's report.
4. **(low) Cover the udisks two-level drive root `/media/<user>/<label>` in the mount
   guard.** v1.0.2 refuses one level under `/media`/`/run/media`/`/cygdrive`, but the
   udisks layout puts the drive root two levels down (`/media/john/USB`), which is
   structurally indistinguishable from a project nested inside a drive
   (`/media/usb/app`, which must stay allowed). Needs a heuristic (e.g. is it itself a
   mountpoint?) not just a path pattern — decide before coding. Low risk: nobody keeps
   source at `/media/<user>/<label>` by hand, and $HOME/.ssh guards still apply.
5. **(cosmetic, low) Two glitch-looking lines on video after a breach:**
   `SIGUSR1 received from the canary tripwire` prints twice (both monitors signal
   PID 1 on purpose; the entrypoint's USR1 trap runs twice), and bash prints
   `warden-entrypoint: line 454: <pid> Killed "$@"`. Both are documented/expected
   (`docs/DEMO.md` act 3). If fixed: make the trap idempotent with a shell variable
   and keep both signals; it is an entrypoint change, so rebuild + drills + tag -
   not worth it in the last days before a recording.

### Decided this session (do not re-raise without new evidence)

- **Sentinel attribution → honest verdict, not more privilege or a wait** (session 7,
  shipped v1.0.4). The sentinel keeps `CAP_KILL` only and says `"attribution":
  "restricted"`. Rejected with evidence: `CAP_SYS_PTRACE` (anti-tamper layer could
  read every process); "sentinel waits ~300 ms for the inline report" (delaying
  SIGUSR1 turns exit 99 into 137 when the inline monitor is dead, and a sidecar in a
  shared PID namespace is SIGKILLed the moment PID 1 exits - run and confirmed with
  two containers, `--pid container:<A>` vanished when A died).

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
| A test that reads `$HOME/.aws/credentials` inside the sandbox trips the tripwire | That path (and `~/.ssh/id_rsa_backup`) is a **seeded canary**, not a host secret. A host-leak probe must skip anything listed in the live `$WARDEN_CANARY_FILES` and use `[ -f ]` (access(2), never opens the file). Cost 1 demo run to find. |
| The drills' incident report is the *inline* monitor's; the real CLI's is the *sentinel's* | Phase B uses raw `docker run` with no sentinel, so the report on disk is the rich one (phase D does go through `warden-cli.sh run`, but kills the inline monitor first, so it only ever sees the sentinel's report). `warden-cli.sh run` attaches a sentinel that wins the write race and has weaker attribution (no `CAP_SYS_PTRACE`). Any claim about report **content** must be checked on the CLI path. |
| `gh api /markdown` becomes `C:/Program Files/Git/markdown` | Git Bash rewrites the leading slash. Call `gh api markdown` (no leading slash) and pass a **Windows** path to `--input`; `MSYS_NO_PATHCONV=1` fixes the endpoint but then breaks the file path. To really check a README's links/anchors: `gh api repos/<owner>/<repo>/readme -H 'Accept: application/vnd.github.html'` and grep for `id="user-content-..."` (the plain `markdown` endpoint emits no heading anchors). |
| Windows python dies printing Thai (`UnicodeEncodeError: charmap`) | stdout is cp1252. Prefix with `PYTHONIOENCODING=utf-8`, or print ASCII labels only. |
| Editing a bash script while a background run of it is in flight | bash reads the script from disk as it goes; a header edit shifted offsets and the running suite died with `syntax error near unexpected token` at a line that was fine on disk. Cost one full suite run (session 7). Finish editing, `bash -n`, THEN start the run - and don't touch it until it reports. |
| bash 5.2 execs the last command of a `-c` list | `bash -c 'cat canary; sleep 25'` leaves the PID as `sleep 25` with no canary in argv, so a "short-lived reader" leaves no trace for either monitor. Session 6's repro A blamed the sentinel for this; re-running it showed the inline monitor was equally blind. Re-run a logged repro before trusting its diagnosis. |
| A drill payload that changes identity mid-flight is timing-dependent | E5's first payload opened fd 3 in bash, then `exec -a`'d into sleep; when the monitor scanned before the exec it saw plain bash, so the drill FAILED on a fixed build. One manual run of the payload found it. The adversary must be ONE process that holds its identity for the whole window (E5 now uses `exec -a ... python3 -c "f = open(...)"`). |
| Proving a new assertion has teeth | Write it first and run it on the OLD image (must FAIL) before rebuilding. For a monitor function, `git show v1.0.3:monitors/canary_monitor.py` + a `python:3.11-slim` container with `setpriv --reuid=1001` (inline-like) or root with `setpriv --bounding-set=-all,+kill` (sentinel-like) compares old vs new in seconds, no image build. |
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

### 2026-09-16 — session 7 · v1.0.4 (attribution honesty + argv-impersonation evasion)
- **Did:** fixed HANDOFF first (stale `main` hash; the phase-D gotcha wrongly said
  D was raw docker). Re-ran the attribution repros through `warden-cli.sh run`:
  repro B confirmed the sentinel defect, repro A turned out NOT to be one (bash 5.2
  exec'd `sleep`, so the inline monitor was blind too) - corrected the item. Chose
  fix (a), honest degradation, and rejected (b) with two runs (a shared-PID-ns
  sidecar dies with PID 1). Wrote the phase-D content assertion first and proved it
  FAILED on the v1.0.3 image; added `attribution` / `attribution_note` to every
  record. Testing the new verdict on the CLI path exposed a second defect: the
  warden-marker filter let `exec -a /opt/warden/canary_monitor.py` hide a reader
  holding a canary from both monitors, while the log said no one held it. Fixed
  (marker silences only the argv hint), added drill E5 (FAILED pre-fix, v1.0.3's
  function returns `[]`, passes now). Rebuilt `--pull`, suite A-F green exit 0,
  `demo.sh --auto` DEMO COMPLETE, trivy 0/0, CI green on main + tag, shipped
  **v1.0.4** with v1.0.3 marked superseded. Quoted output in README / DEMO.md /
  VERIFICATION.md replaced from single runs. `claude --version` smoke in v1.0.4: OK.
- **Learned:** (1) a new *honesty* field is itself a control that can lie - the first
  thing to test is how the adversary makes it say something false (E5 came from
  exactly that question, on the real CLI path). (2) Drills can be flaky in a way
  that looks like a regression: E5 failed on the fixed build because its payload
  changed identity mid-flight; one manual run of the payload settled it. (3) I
  edited `verify-isolation.sh` while a background run was executing it and lost the
  run to a bogus syntax error. (4) A logged repro's diagnosis can be wrong even
  when its output is right - repro A's `suspects: []` was real, the blame was not.
- **Prompt should have said:** the rehearsal needs the user's API key, which the
  agent's shell never has - ask for it (via `.env`, never in chat) at START, not
  discover it at the end; never edit a script a background run is executing; prove
  an assertion's teeth on the old image before rebuilding.

### 2026-09-16 — session 6 · demo deliverables for the Monday first test
- **Did:** shipped the three Monday deliverables and ran them. `scripts/demo.sh`
  drives the real product path (`warden-cli.sh run`) in four acts - perimeter,
  the agent auditing its own prison from inside, a live breach, hand-over to a
  real agent - and **asserts every claim it narrates**, so a demo cannot say
  "breach contained" unless exit 99, exactly one clean report, no false tamper
  alarm and real attribution are all true. Ran it end-to-end: 24 PASS, 0 FAIL,
  exit 0. Wrote `docs/DEMO.md` (T-30 pre-flight, verbatim expected output, what
  to say, limitations to read out loud, failure playbook keyed by symptom) in
  Thai prose + English commands to match the other docs. Rewrote the top of the
  README around the demo (transcript, report, in-sandbox proofs, CI badge, nav)
  and fixed two stale claims: the suite has six phases (F was missing) and the
  tree still said "3 phases". Verified the README's anchors and relative links
  against GitHub's own rendering, not by eye. Full suite re-run green A-F, exit
  0, enforced=4/7; CI green on the commits.
- **Learned:** writing the demo found two real bugs, both of the house shape.
  (1) My own in-sandbox probe read `$HOME/.aws/credentials` as a "host secret" -
  that path is a seeded canary, so the proof act would have tripped the tripwire
  mid-take; it now derives its skip list from `$WARDEN_CANARY_FILES` and never
  opens a file. (2) The incident report that lands on disk is always the
  *sentinel's*, and the sentinel holds `CAP_KILL` only, so it cannot read
  `/proc/<pid>/fd` or `exe`; against a short-lived `cat` the report can name the
  canary but **no process at all**, while the inline monitor had the answer and
  wrote it to a tmpfs that dies with the container. The drills never saw this
  because phases B/D run raw docker with no sentinel - the same "run the path
  the user will run" lesson as v1.0.3, now with a second scar. Logged as Next
  steps #1 with a three-part repro instead of being fixed hastily before a demo.
  Also: a README block I drafted mixed output from two different runs; caught it
  by re-reading against the logs. For a project whose whole claim is honesty,
  demo copy has to be quoted from one real run.
- **Prompt should have said:** check the docs' language convention before writing
  a new doc (all docs here are Thai prose + English code; DEMO.md was drafted in
  English and rewritten). And: when a new script asserts things about the
  sandbox, check whether the paths it touches are canaries first.

### 2026-09-15 — session 5 (cont.) · demo prep · v1.0.3
- **Did:** with a first live test (video → GitHub) set for Mon 2026-09-21 on this
  Docker Desktop box, dry-ran the actual demo path (`warden-cli run`, sentinel on) —
  which surfaced a real bug the raw-docker drills never hit: a benign breach printed a
  **false "report redirected by a symlink" alarm** + an empty fallback, because the
  inline monitor and the sentinel race to write the workspace report and the loser
  mistook `EACCES` for tampering. Fixed (only `ELOOP` = tamper), added a phase-D guard
  that fails on a false tamper report, dropped the obsolete `dns_v4_first` squid
  directive (it printed `ERROR:` on every build), and shipped **v1.0.3** (rebuilt
  --pull, trivy 0, A–F green, v1.0.2 marked superseded). Confirmed the demo works:
  claude 2.1.197 launches under warden, egress reaches api.anthropic.com via the proxy.
- **Learned:** the drills used raw `docker run` (one monitor); the real CLI runs the
  inline monitor AND the sentinel, so the report-writer race only ever appears on the
  real path. "Done means run" has to mean run the PATH THE USER WILL RUN, not a proxy
  for it. The dry-run for the demo was itself the highest-value test this session.
- **Prompt should have said:** before a demo/release, run `warden-cli run` end-to-end
  (agent launch + live breach) and read the incident report, not just the drills.

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
- **v7 · 2026-09-16** — session 7. (a) **START asks for the API key** (`.env`, never in
  chat) — the session found "API key: NOT set" at start and could not do the mandatory
  `--agent claude` rehearsal; default task is now that rehearsal, and "read my terminal
  if I run it myself". (b) **verify a Next-steps DIAGNOSIS by re-running its repro** —
  session 6's repro A blamed the sentinel; one re-run showed bash had exec'd `sleep` and
  the inline monitor was blind too. (c) **assertion first, watch it FAIL on the old
  image, then fix** — did this for phase D and E5; both failed pre-fix, proving teeth.
  (d) **ask how the agent makes a new guard/field lie** — that question, on the CLI path,
  found the `exec -a /opt/warden/...` attribution evasion. (e) **a drill failing on a
  fixed build: run its payload by hand first** — E5's failure was its own race, found
  in one manual run. (f) **never edit a script a background run is executing** — lost a
  full suite run to a bogus syntax error. (g) corrected "phases B/D are raw docker"
  (only B is). Cut: the inline GitHub-anchor check (still in Gotchas; no anchors changed
  this session) and v6's `WARDEN_CANARY_ACTION=log` example, to stay under 70 lines.
- **v6 · 2026-09-16** — session 6. Workflow upgrades, each from an event in this
  session: (a) **encode the docs convention** (Thai prose + English commands) — DEMO.md
  was drafted in English and had to be rewritten, pure waste; (b) **"when output
  surprises you, stop reading code and run the smallest controlled experiment"** — an
  audit-mode raw `docker run` settled the empty-`suspects` mystery in one run after
  three rounds of reading canary_monitor.py got nowhere; (c) **claims about report
  CONTENT must be checked on the CLI path**, because phases B/D have no sentinel and
  show the rich inline report while the real CLI writes the sentinel's weaker one —
  that gap hid both of the last two sessions' bugs; (d) **check whether a path a test
  touches is a seeded canary** — the demo's own probe read `~/.aws/credentials` and
  would have tripped the tripwire mid-take; (e) **quoted output must come from ONE real
  run** — a README block stitched from two runs was caught in review; (f) the Monday
  deliverables are done, so the default task moved to the attribution defect and the
  milestone line now says "rehearse, don't rebuild"; (g) added the GitHub-rendering
  link check (`gh api repos/.../readme` + `user-content-` anchors).
- **v5 · 2026-09-16** — session 5 (cont.), at the user's request: (a) the handoff is now
  **self-triggered at ~70% context** (stop, verify, hand off) instead of waiting to be told;
  (b) the rewrite is explicitly a **workflow upgrade, not a version bump** — each edition must
  let the next chat do more per chat and get better results, citing a real event; (c) "done
  means run **the path the user will run**" — v1.0.3's false-alarm bug showed only in a real
  `warden-cli run` demo dry-run, never in the raw-docker drills; (d) named the concrete next
  task (Monday demo deliverables) + the first-test milestone up top.
- **v4 · 2026-09-15** — session 5. Corrected the now-stale v3 line: `warden-cli.sh
  build --pull` was FIXED this session and re-pulls both images, so the prompt says
  to use it (not raw docker). Added: a Next-steps item may resolve to "no code" (a
  decision, or a feature unverifiable on this host like gVisor) — that's finished, not
  a gap; when the runnable backlog is clear, hand off instead of manufacturing work;
  and the CI gitleaks step flakes on its Docker Hub pull (re-run, don't "fix"). Shrank
  the "why" section to prose to stay under 70 lines.
