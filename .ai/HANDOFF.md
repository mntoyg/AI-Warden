# AI Warden — Session Handoff

> **Living document.** Read it at the start of every session; update it at the end.
> **Reality beats this file.** If git, CI or the running system disagree with it,
> the system is right — fix this file in your first commit and say so.

- **Last updated:** 2026-10-10 (session 16, Windows box)
- **Latest release:** [v1.2.11](https://github.com/mntoyg/AI-Warden/releases/tag/v1.2.11) — **SECURITY: the mount guard refuses a whole removable volume.** `assert_safe_mount()` read the parent's NAME, so it caught `/media/<label>` and nothing else; udisks mounts one level deeper (`/media/<user>/<label>`, parent `/media/alice`, matching no rule), so a whole USB stick or external disk was accepted silently - and macOS (`/Volumes`, `/Volumes/<label>`) was never covered at all. A name cannot tell a volume root from an ordinary folder, so the guard now asks the kernel: `is_mount_point()` (`mountpoint -q`, else the device number vs the parent's) refuses any path under `/media`, `/run/media`, `/cygdrive` or `/Volumes` that is its own filesystem's root. It does NOT refuse by prefix: a project inside a volume, a plain folder beside one, and a mountpoint outside those prefixes (`/data` on its own disk) all stay allowed. Drill E3 mounts three real tmpfs volumes and proves each is a mountpoint before testing it. v1.2.8, v1.2.9 and v1.2.10 now carry a superseded note - they all had the hole.
- **Previous release:** [v1.2.10](https://github.com/mntoyg/AI-Warden/releases/tag/v1.2.10) — **phase M now measures the WHOLE of phase A's resource section**, not just `--memory`. Measured: swap really is a sidestep (`--memory 256m --memory-swap 512m` reached **496 MiB** against 240 with equal values, so setting them equal is what holds the cap, not the `memory.swap.max=0` label); `--ulimit nproc=64` stops a fork loop at 63 with EAGAIN on every runtime; `--pids-limit 64` stops it at 63 on runc and is SKIPped with its reason elsewhere (gVisor counts host tasks, Kata bounds nothing in the guest). And `RLIMIT_NPROC` is a per-uid budget whose reach is the host's: on a GitHub runner, whose job user IS uid 1001, the same 64 cap let uid 4242 fork 63 but uid 1001 only **4** (and, before the fix, the container could not even start: `exit=255`, zero forks) - tighter than asked, never looser, and the CLI's real `nproc=512` leaves the headroom the drill's 64 does not. Shipped through PR #9 (all five jobs green). v1.2.9 is NOT superseded (no security change).
- **Before that:** [v1.2.9](https://github.com/mntoyg/AI-Warden/releases/tag/v1.2.9) — **phase M: the memory cap is MEASURED, not read off a label.** Not a security fix; no cage behaviour changed, but the suite proves one more thing. `--memory` is enforced on all three runtimes (runc 240/256 MiB usable, gVisor 208–224, Kata 144; at a 1 GiB cap 1008 / 976 / 896 — the overhead is fixed, not proportional, so the CLI's default `4g` still leaves the agent ~3.9 GiB). Two findings beside it: under Kata the kill is `exit=137` with **`OOMKilled=false`** (the guest kernel does it; the host never sees an OOM), and under gVisor `/sys/fs/cgroup/memory.max` **does not exist in the sandbox at all**, so phase A can only `skip` and the outside measurement is the only proof. v1.2.8 is NOT superseded (no security change).
- **Before that:** [v1.2.8](https://github.com/mntoyg/AI-Warden/releases/tag/v1.2.8) — PID 1's own log line no longer claims the tripwire sent SIGUSR1 when the agent could have forged the breach record itself (extends E11 to the entrypoint, PR #4). On top of v1.2.7 (breach headline only when the sentinel confirms, E11; stdin EOF under Kata, E12; Kata supported with limits) and v1.2.6 (proxy DNS exfiltration closed, L; inotify overflow, E9; sentinel-only record, E10; UNVERIFIED dirs). All three were merged on `main` by cloud sessions 12/13 but left untagged (their git proxy refused tag pushes, HTTP 403); tagged, released and verified on Docker Desktop this session (v1.2.8 twice - once to confirm the merged fix, again after bumping the stale version strings). v1.0.0–v1.2.7 carry a superseded note.
- **Next prompt:** [`.ai/NEXT_PROMPT.md`](NEXT_PROMPT.md) (v22)
- **🚩 MILESTONE — first live test: POSTPONED, no date.** The 2026-09-29 date set in session 12
  passed without a recording (user, 2026-10-07). Nothing is frozen. Still a video on the Windows
  Docker Desktop box with a real agent + live breach, `enforced=4/7`, act 4 = codex.

---

## 1. Status (verified 2026-10-08, session 15, Windows box)

| Thing | State |
|---|---|
| `main` | **v1.2.11 = the mount guard refuses a whole removable volume (udisks `/media/<user>/<label>`, macOS `/Volumes`), merged through PR #10, tagged at `e0b93f6` and released as Latest.** Drill E3 mounts real tmpfs volumes; all five CI jobs green on the PR and on both `main` pushes. Under it: **v1.2.10 = phase M extended to swap + process caps, merged through PR #9** (all five jobs green, run 37764437022) on top of **v1.2.9 = phase M (measured memory cap)** (`ef3a83b`, CI green on its `main` push and tag). Both tagged and released from this box. Under those: v1.2.8 = PR #4 (E11 extended to PID 1's log line) on top of PR #3 (v1.2.7: E11, E12, Kata CI job) on top of `9d265d0` (v1.2.6), plus PRs #5-#8 (notebook/ data collection + training, see item 2). `main` fast-forwarded here from 73 commits behind at session start. Version strings were bumped to 1.2.8 this session - PR #4's fix was merged under `[Unreleased]` with the code still saying 1.2.7 |
| Tags | `v1.0.0`…`v1.2.10` ALL carry a superseded warning (v1.2.8/v1.2.9/v1.2.10 got theirs in session 16 - the mount-guard hole was in every one of them) · **`v1.2.11` (Latest)**. v1.2.6–v1.2.8 were tagged + released in session 14; v1.2.9 and v1.2.10 in session 15, same way (`git tag -a ...; git push origin ...` from the Windows box - the cloud sessions' git proxy had refused this with 403). v1.2.9/v1.2.10 had deliberately carried no note while the newest release was verification-only; v1.2.11 is a real security fix, so the note went on all three |
| CI | **5 jobs**: static · CVE scan · ext4 drills · gVisor (runsc) drills · Kata Containers drills. Green on every tag through v1.2.9 and on `main` through `ef3a83b`. Phase M's memory measurements came from a temporary branch (`kata-memcap-probe`, deleted): runs **37749560187** (cap 256m) and **37751167935** (cap 256m + 1024m), all 5 jobs green each. The swap/process measurements came through **PR #9** instead - `pull_request` already runs all five jobs, so no ci.yml scaffolding was needed, and its first run (37760397979) caught the uid-1001 nproc collision before `main` ever saw it (fixed in 37764437022, all green). Real-image proofs from sessions 12/13: 36364368300 (E9, L), 36500312536 (E10), negatives 36365091898 / 36500312493; E11 negative 37705657498 → fix 37705778556; E12 under Kata old rc=142 → new rc=1 (37711877983) |
| Local suite (Docker Desktop / Windows) | **session 16: A–M exit 0 on v1.2.11** (60 PASS), and session 15: the same on v1.2.10, self-test 35/35, `enforced=4/7`, one SKIP (phase J's no-GPU side, CI runs it). Phase M measures memory, swap and the process caps; every new assertion was watched FAILING on the old behaviour first (guards stripped: capped allocation reached the full 768 MiB and the fork loop ran all 150 with no refusal, suite exit 1). Run AFTER the version bump, on an image rebuilt from cache (no `--pull`, so the bundled CLIs are still session 14's: codex-cli 0.161.0, claude 2.1.197, aider 0.86.2). Phase M's teeth were proven on the old behaviour first with a phase-M-only scratch harness: cap stripped → uncapped 768 / capped 768, `exit=0 OOMKilled=false`, `memory.max=max`, suite **exit 1**; cap in place → capped 240 MiB, `exit=137 OOMKilled=true`, exit 0. `docs/VERIFICATION.md` §0 now carries the phase M block from the v1.2.9 run. Session 14's run, for reference: rebuilt `--pull` (codex-cli 0.156.1 → **0.161.0**; claude 2.1.197 and aider 0.86.2 unchanged), full `verify-isolation.sh` A–L exit 0, `enforced=4/7` on the v1.2.7-era code; after the version bump, rebuilt (cached, fast) and ran again clean on v1.2.8 (35 passed in the self-test, was 34). **3b2, L, E9, E10, E11, E12 all PASS on Docker Desktop for the first time** (previously CI-only). `docs/VERIFICATION.md` §0 re-quoted from the v1.2.8 run |
| Real codex path | **confirmed working on codex-cli 0.161.0**: login from `OPENAI_API_KEY` OK, `sandbox_mode=danger-full-access` OK, reached api.openai.com - but every prompt returns `ERROR: Quota exceeded`. Not a sandbox fault (same as session 10). Needs a workspace that is a git repo - 0.161.0 added a trusted-directory check (`--skip-git-repo-check` exists but unneeded for a real project folder, which is always a git repo) |
| CI suite, ext4 / gVisor / Kata | ext4 `enforced=7/7` all phases; gVisor D = honest SKIP, sentinel `NOT armed`; Kata supported with limits, same tradeoff, CI job green. **Session 15 adds phase M to all three** and it passes on each: `--memory` enforced everywhere with a fixed per-runtime overhead (runc ~16 MiB, gVisor ~48, Kata ~112–128); `nproc` enforced everywhere; `--pids-limit` asserted on runc only, SKIPped elsewhere with the reason |
| Egress audit trail | live (`up` healed it at session start, same as every session) |
| Local model | unchanged: no trained GGUF locally. `notebook/` (collect + train) merged to main this session (PRs #5-#8, user's Colab run in progress/result not seen here) |
| OpenAI key | **still out of credit** (confirmed again this session via a real codex call) - ask the user to top up, do not debug further |
| Temporary branches | `kata-probe`, `verify-s12`, `claude/wizardly-edison-9pzqzk` deleted this session (user had already agreed 2026-10-08; cloud session's API delete was refused, this session's `git push --delete` worked) |

---
## 2. Next steps — priority order

Pick the top unchecked item unless the user asks for something else. Each has a
reason; if the reason no longer holds, delete the item instead of doing it.
`.ai/ROADMAP.md` (Thai, session 12) gives the phase view; this list wins where they differ.

0. **Kata follow-ups (low):** a detect-only runc witness is possible under Kata too (a runc inotify
   watcher heard the Kata agent's reads via virtiofsd) - but NOT via `--pid container:`, which gave a
   runc container the HOST PID namespace. (`--memory` under Kata: **ANSWERED session 15** — enforced,
   measured by the new phase M, v1.2.9. The Kata/gVisor numbers are in `docs/THREAT_MODEL.md`'s runtime
   tables and CHANGELOG `[1.2.9]`; nothing left to measure there.)
1. **Demo recording — no date. Ask again each session** (AskUserQuestion). With a date: no rebuild
   in the days before it; the interactive `./scripts/demo.sh --agent codex` rehearsal is the user's
   step; `demo.sh --auto --agent codex` must end DEMO COMPLETE that day. Blocked separately on OpenAI
   credit (session 14 re-confirmed `Quota exceeded` through a real codex call - ask, don't debug).
2. **Local model - our own, trained in `notebook/`** (user call 2026-10-08: notebook in this repo, data
   never committed). Step 1 DONE: `notebook/collect_data.ipynb` + `notebook/collect/` gather chat-format
   JSONL from the user's git repos (commit -> diff), project files (docs/docstrings -> text/code), Claude /
   ChatGPT exports, and licence-checked Hugging Face datasets; every record redacted; 14 stdlib tests run in
   CI's static job. Step 2 WRITTEN (`notebook/train.ipynb`, LoRA on Qwen2.5-Coder-1.5B, SMOKE=True first ->
   merge -> GGUF q8_0 + `warden-model-lab/manifest/1`), merged through PR #7/#8 (torchao removed before peft
   builds LoRA layers - a real Colab run hit this). **Next:** the user runs it (smoke, then full) on Colab,
   downloads the model dir outside any workspace, then
   `WARDEN_MODEL_GPU=1 WARDEN_MODEL_MANIFEST=<it> warden-cli.sh run <ws> aider-local` vs the untuned base.
   **Measured this session (not a replacement for the Colab run):** the full pipeline (collect -> LoRA
   SMOKE -> merge -> GGUF q8_0 -> manifest) runs end-to-end on THIS box's RTX 3050 (4GB) in a scratch
   venv, but only with **bf16, not the notebook's float32** (a T4 has no bf16; this GPU does, and float32
   alone needs ~6GB for the 1.5B base model - would OOM on 4GB). 30 smoke steps: val loss 3.61 -> 2.21,
   peak VRAM 4.47GB (nvidia-smi topped at 3957MiB - the excess is Windows WDDM shared-memory spillover,
   not a true overflow; nothing crashed), ~48 min for training alone, ~52 min wall end to end. All
   scratch files/venv deleted after, nothing committed (train.ipynb itself was NOT edited - still
   correctly tuned for Colab/T4). Useful if the user wants to iterate locally without Colab someday,
   with a bf16 variant of the training cell - not needed if the Colab run goes fine.
3. **(ideas, decide first)** a detect-only runc witness beside a runsc agent (hears canary reads,
   cannot signal - restores the unforgeable record, not containment); udisks `/media/<user>/<label>`
   in the mount guard (needs an is-it-a-mountpoint heuristic); SNI peek-and-splice (needs an
   OpenSSL squid build).

### Decided this session (do not re-raise without new evidence)

- **v1.2.6 and v1.2.7 are tagged + released from the Windows box** (session 14): both were merged
  to `main` by cloud sessions 12/13 but left untagged because their git proxy refused tag pushes
  (403). This session has real write access, so both were tagged at their merge commits
  (`9d265d0`, `7a577d8`), pushed, CI confirmed green, and released with superseded notes on the
  predecessors. v1.2.8 followed immediately: `main` already had PR #4's entrypoint fix merged
  under `[Unreleased]` with the version strings still saying 1.2.7, so the Windows run that was
  Next steps #1 (build --pull, real codex path, full suite) was done against code one commit
  past the v1.2.7 tag. Rather than verify a stale tag, bumped to 1.2.8, re-verified, and shipped
  that instead - the version string now matches what was actually tested.
- **v1.2.6 ships from a cloud session on CI evidence** (user call 2026-10-07): v1.2.5's DNS
  channel was confirmed on its real image and the repo is public, so waiting for the Windows box
  was worse than shipping with "not yet run on Docker Desktop" written in the release. The Windows
  run is Next steps #1, not optional.
- **The breach headline needs the sentinel** (user call 2026-10-08, E11): "the canary tripwire terminated this
  sandbox" only when the sentinel confirms; otherwise `SECURITY BREACH (unconfirmed)`. Accepted cost: a real
  home-canary breach and every gVisor/Kata breach print unconfirmed.
- **Kata is supported with limits and runs in CI** (user call 2026-10-08), like gVisor: VM boundary, no sentinel.
- **Session 12's fixes for the sentinel-only breach (E10) and UNVERIFIED dirs were the user's
  choice** (2026-09-29, from the options in ROADMAP phase 2). Phase 2 #1 is still undecided.
- **gVisor is verified on a GitHub runner, not on this box** (user call 2026-09-27, over installing
  dockerd + runsc into the WSL kali distro). Under runsc the sentinel cannot share the agent's PID
  namespace, so it refuses to arm and says so; gVisor trades the sentinel for the kernel boundary.
  Do not "fix" this with privileges or by moving the sentinel out of gVisor without item #4's decision.
- **The inline monitor's richer record stays best-effort; PID 1 does not wait for it** (session 11,
  measured): 3 real breaches through `warden-cli.sh run` (python holding the canary open). The
  inline monitor detected all 3 with full evidence (`evidence=open file descriptor exe=...`) and
  printed it to the console 3/3, but its report FILE survived 1/3 - when the sentinel signals first,
  PID 1's `stop_monitor` kills it before it writes. The only fix is PID 1 waiting for it after a
  confirmed breach, i.e. letting the agent's other processes run on to save a record the agent can
  forge anyway (workspace). Not worth it; the sentinel's `restricted` report + console line suffice.

- **GPU is opt-in, per run, and proven or refused** (session 10, on evidence): llama.cpp's CUDA
  image with no usable GPU turns healthy on the CPU, so `WARDEN_MODEL_GPU=1` requires
  `offloaded N/N layers to GPU` in the server log; never read from `.env` (it exposes the host
  NVIDIA driver to the model server, M7); the agent never gets a device. CPU stays the default.
- **Local-model sessions are OFFLINE** (user call, 2026-09-26, on evidence): the agent sits
  on a private internal network with its model container ONLY - no proxy, no route out -
  so code cannot leave the box structurally, not just because no cloud key was forwarded.
  Measured first: aider 0.86.2 -> llama-server answered in 5 s with proxy and 1.1.1.1:443
  both unreachable. Cost accepted: no pip/npm/git network inside such a session.
- **Fine-tuning path = (b) Colab LoRA -> local GGUF** (user call, 2026-09-26). Not the
  OpenAI fine-tuning API (closed to new users per its own docs, account had 0 jobs) and
  not "no fine-tuning". Do not re-offer the OpenAI probe.
- **Demo act 4 = codex with the user's OpenAI key** (user call, 2026-09-16), not claude.
- **codex runs with its own sandbox OFF inside AI Warden** (session 7, evidence-based):
  its bubblewrap sandbox cannot work under cap-drop=ALL and made every command fail
  while exiting 0. AI Warden is the boundary; documented in THREAT_MODEL §3.6 and
  guarded by phase G. Do not "fix" this by installing bubblewrap or adding caps.

- **Self-trained model → local container + aider, code after the demo** (user call,
  2026-09-16). Option B (GGUF served on this box, no egress) over option A (Colab
  endpoint via tunnel): a tunnel URL changes every session, code leaves the box, and a
  wildcard tunnel domain in the allowlist would open exfiltration to anyone's tunnel.
  aider over Codex/Claude Code (OpenAI-compatible base URL, tolerates small models).
  Notebook + training data in a separate private repo. Details:
  [`.ai/design-local-model.md`](design-local-model.md).

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
./scripts/verify-isolation.sh          # phases A-I must all pass (exit 0)
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
| Backslashes and `\n` inside heredoc-fed Python collapse | Use `chr(92)`/`chr(10)`, or the Write/Edit tools, for any source containing backslashes. **Doubling them does NOT help**: session 10 put real newlines/tabs into HANDOFF and CHANGELOG three times that way, and two `sed` one-liners with escaped backslashes broke too. After any scripted doc edit, scan the file for control characters. |
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
| codex-cli 0.154.0 ignores `OPENAI_API_KEY` and its sandbox is dead in the container | Env-only: "Not logged in" + 401 loops. Default sandbox: commands fail "due to sandbox permissions" but `codex exec` exits 0. Launch codex ONLY via `warden-cli.sh run <dir> codex` (logs in from env, `-c sandbox_mode="danger-full-access"`). `codex login --with-api-key` works offline (a fake key "logs in"), which is what makes phase G possible without a secret. |
| A release rebuild moves the bundled agent CLIs | `build --pull` for v1.0.5 took codex-cli 0.154.0 → **0.156.1** in eight days (claude/aider unchanged). The launcher's login + sandbox behaviour is version-specific, so after ANY rebuild re-run `warden-cli.sh run <ws> codex -- exec …` with the real key and a honeypot read (expect exit 99) before claiming the image is good. Phase G only proves the launcher's shape, with a fake key. |
| `bash` typed in PowerShell is WSL, not Git Bash | On this box `Get-Command bash` -> `C:\Windows\system32\bash.exe` (WSL, kali-linux first). Everything was verified under Git Bash, so run scripts as `& "C:\Program Files\Git\bin\bash.exe" -lc '...'` (the app's terminal panel is PowerShell 7). A codex TUI cannot be captured headlessly: under `script(1)` with no emulator answering its terminal queries it renders nothing and times out - only a real terminal rehearsal tests act 4's screens. |
| `codex login status` prints part of the key (`sk-proj-***XXXXX`) | A redaction regex for `sk-[A-Za-z0-9_-]+` does not match `sk-proj-***` - include `*` in the class, or better, never run `login status` with a real key in a logged session. |
| A "secret present" check that only looks at exported env | Keys belong in `.env` (passed with `--env-file`), so an export-only check lies. Test presence in env OR `.env`, never read the value (`demo.sh` `key_available`). |
| NodeSource's setup script exits 0 when it fails | CI (run 35077858862, image CVE job): `curl: (35) Connection reset` on the signing key -> `Error: Failed to download and import the NodeSource signing key (Exit Code: 0)` -> `apt-get install nodejs` silently took Debian's node 18 (no npm), caught only by `npm --version`. `core/Dockerfile` §2 now retries until `apt-cache policy nodejs` shows `Candidate: 20.`, refuses the fallback and checks `node --version`. A red image job that says `npm: not found` is this; `gh run rerun <id> --failed`. |
| A check that passes because nothing happened | Phase I's "no model container left behind" passed on the OLD code, which never started one. Every absence assertion must also prove the thing existed (model seen during the run, `local model ready` in the output). |
| Git Bash's `curl` is a native Windows program | With `MSYS_NO_PATHCONV=1` exported it cannot write to `/d/...` (`-o` fails silently with `-f`). Run it as `env -u MSYS_NO_PATHCONV -u MSYS2_ARG_CONV_EXCL curl ...`. MSYS tools (sha256sum, dd, sed) are fine. |
| aider exits 0 on a model error | A `BadRequestError` / token-limit failure still returns rc 0 (same shape as codex in v9). Assert on `Tokens: N sent, M received`. The tiny CI model (stories260K) rambles to the context limit, so CI checks agent→model with a bounded `curl /v1/chat/completions` instead of aider. |
| Retaking a quoted transcript from a new run | The v1.1.0 demo run had no inline `SIGKILL`/`SIGUSR1` lines (the sentinel won the race), so the README's act-3 quote stayed on the v1.0.6 run (labelled). Check every quoted line against the new run's log before swapping. |
| `docker logs warden-egress-proxy` silently dead after an unclean Docker shutdown | NUL bytes land in the json log; `docker logs` stops there while squid keeps writing and health stays `healthy`. Found 2026-09-26 (10 days of egress missing) only because a control CONNECT did not show up. `docker restart` keeps the file; recreate the container. Since v1.0.6 `up` proves liveness with a nonce and heals/refuses (phase H). **Any "the log shows no X" claim needs a positive control first** (make X happen once, see it logged). |
| llama.cpp's CUDA image falls back to the CPU silently | Started without a usable GPU it prints `no usable GPU found, --gpu-layers option will be ignored`, turns **healthy** and serves from the CPU. At default verbosity it prints no offload line at all; `-lv 4` prints `load_tensors: offloaded N/N layers to GPU` (and, checked with a marker, no prompt text). Since v1.2.0 the CLI requires N/N or refuses (phase J). |
| A docker shim on PATH that is silently not used | To run the "no GPU" side of phase J on the GPU box, a `docker` shim goes first on PATH. Written as `C:/Users/...` the colon split the entry and the real docker ran - the shim run "passed" while inactive. Use `cygpath -u` paths and prove the shim is live with `command -v docker` first. |
| `--fit` (llama.cpp, default on) changes unset args to fit VRAM | It only touches args you did NOT set; the CLI sets `-c` and `-ngl 999` explicitly, so ctx/layers are never shrunk behind your back (too little VRAM = load fails = refused). |
| The agent image's baked `HTTP_PROXY` breaks ad-hoc clients on the model net | `docker run --network <sess>-net --entrypoint curl ai-warden/agent` gets an empty reply (it tries the proxy). Add `--noproxy '*'`; the real entrypoint handles this in offline sessions. |
| A scratch harness is a COPY of the suite | It is sed-extracted at one moment; edit the drill afterwards and the harness still runs the old text. Session 10 watched E7 "fail" on a fixed build because the harness still grepped a message the drill no longer used. Regenerate the harness after every edit of `verify-isolation.sh`. |
| `git commit -F /tmp/...` fails with `MSYS_NO_PATHCONV=1` exported | git.exe is a native program; the Git Bash path `/tmp/claude/...` reaches it unconverted (`could not read log file`). Do not export `MSYS_NO_PATHCONV` in the same command as `git commit -F`, or pass a `cygpath -w` path. |
| Everything an incident record lives in is agent-writable | PID 1 runs as uid 1001 (the agent can SIGUSR1 it), `/run/warden` is a uid-1001 tmpfs, the workspace and the vault are writable by the agent. So never let a monitor or the CLI *defer to* an existing record it cannot authenticate (the pre-v1.2.1 O_TRUNC report bug) - write your own, and label what cannot be proven. The only record the agent cannot touch is the sentinel container's own log. |
| `ERROR: Quota exceeded. Check your plan and billing details.` from codex | The user's OpenAI key is out of credit (hit 2026-09-26 after ~10 codex runs that session). Not a sandbox fault: login, sandbox mode and egress to api.openai.com all worked. codex 0.156.1 exits **1** on this (unlike its exit 0 on sandbox failures). Demo act 4 and the real-codex check cannot pass until the user tops up - ask, do not debug. |
| `cmd | grep -q x` is false under `pipefail` even when x is there | grep -q exits at the first match, `cmd` then dies of SIGPIPE, and pipefail reports the pipeline as failed. Session 10's first E6 status check failed on the FIXED code this way. Capture first (`out="$(cmd)"; printf '%s' "$out" | grep -q x`) - the suite already does this everywhere else. |
| CI "Secret scan" flakes on the Docker Hub pull | It pulls `zricethezav/gitleaks:latest` at runtime; Docker Hub occasionally resets the connection (`read: connection reset by peer`, exit 125). Not your code — `gh run rerun <id> --failed`. The static job's pre-pull step now retries 5x (checked session 10), so this should be rare; pinning by digest is optional. |
| gVisor (runsc) is not "runc but safer" - four behaviours differ, all silent | Measured session 11 on a GitHub runner: Docker DNS (127.0.0.11) does not answer (sessions died 78 until `--add-host`); `--pid container:` is ignored rc 0 (sentinel alone in its namespace); inotify does not cross sandboxes; `--pids-limit` caps HOST tasks (512 kills the sandbox at ~150-300 guest processes, exit 2, no output). The fstype inside reads `9p` and `pids.max` reads `max` - measure, never judge by those names. |
| A probe that dies prints nothing, and nothing is not a result | Round 3's fork loop had `2>/dev/null` and busybox sh exits when fork fails - six configurations printed nothing. Use a counter that survives its own failure (python `os.fork()` in try/except, `flush=True`) and print the container state (`docker inspect` exit/OOMKilled) beside it. |
| `grep -q X log` where the log echoes the command | The CLI prints `launching agent : <cmd>`, so the breach check matched the drill's own `echo NOT KILLED` text and failed a contained breach. Anchor on the output line: `grep -qx` or `^`. |
| A chained commit that reuses a message file | `... && grep -c ... && git add && cat > msg <<EOF ... && git commit -F msg`: grep -c exits 1 on a zero count, the chain stopped, and the next commit silently took the PREVIOUS message. Use a new file name per commit, or check `git log -1` before pushing (fixed with `--amend` before push). |
| Heredoc-fed Python ate a backslash for the 5th time | `tr '\n' ' '` written inside a `python - <<'EOF'` non-raw string became a real newline in a workflow file (session 11). No exceptions: write `chr(10)`, use `paste -sd ' '`, or the Edit tool. |
| Two measurements back to back share state | Session 11's CI step ran the fork bomb at pids 512 and, right after the crashed sandbox, at 4096 - the second "died" too and became a false OPEN QUESTION. A clean run of 4096 alone stopped at 508 with EAGAIN three times. One measurement per clean session/container, or a fresh workspace each. |

| A cloud session is not the Windows box | Check `uname -a; docker info` first and prove push access (`git push --dry-run`) before planning. Session 12 wrote a whole Kata workflow, then hit 403; session 13's dry-run passed in seconds |
| squid `dst` ACLs resolve the name | Any `dst` rule evaluated before the allowlist makes squid resolve attacker-chosen names (DNS exfiltration). Keep `deny !allowed_domains` ahead of every DNS-needing ACL; phase L guards it |
| inotify `IN_Q_OVERFLOW` has wd -1 | It matches no watch, so a loop keyed on wd skips it silently. The monitor trips on it since v1.2.6 (E9) |
| `mktemp -d` is 0700 | A container user other than root cannot read files in it; chmod before mounting (phase L's fake DNS died silently this way in session 12's harness) |
| GitHub Actions steps run `bash -e` | `cmd; rc=$?` never reaches `rc=$?` when cmd fails - the step dies silently (twice in session 12). Use `rc=0; cmd || rc=$?` |
| Temp-branch CI is the real-image test bed | A session that cannot build images can still prove a fix on the real images: a branch whose ci.yml push trigger includes it, plus a negative job that restores the old file (session 12, phase L / E9 / E10) |
| A root sentinel cannot write to a 0755 Linux workspace | No `CAP_DAC_OVERRIDE`: 6/6 writes failed (run 36369383799). When it also kills the inline monitor first, no report existed until v1.2.6's host-written record (E10). Docker Desktop's 9p mount is writable by all, so the Windows box never showed it |
| A Kata container's stdin without `-i` is a pipe that never closes | runc gives /dev/null (EOF). Any agent prompt waits forever: aider's first-run "what's new?" sat in `anon_pipe_read` and phase I hung >30 min (session 13). `docker run -i ... </dev/null` did NOT help - Kata did not pass the EOF on (E12 still timed out). The entrypoint now runs the agent `< /dev/null` when the CLI passes `WARDEN_STDIN=closed` |
| `timeout N warden-cli.sh run ...` does not stop a hung session | bash waits for its foreground `docker run` before running any trap, and timeout signals only its child. A probe must poll and `docker rm -f` the containers itself (session 13 lost a 17-minute job to this) |
| A runc container with `--pid container:<kata container>` gets the HOST PID namespace | It listed dockerd, qemu and the runner (session 13, P2). Never build a runc witness for Kata that way |
| The API returns only a log tail, and `gh api .../logs` is refused | The built-in gh will not follow the blob redirect; `get_job_logs` gives `tail_lines` only. Put what you need at the END of a job (an `if: always()` report step) or in its own small job (session 13: probes and suite as separate jobs) |
| A fix can pass every runc check and do nothing on the runtime it targets | Session 13's first stdin fix was green on runc; only E12 run under Kata showed `rc=142`. Prove a runtime-specific fix on that runtime, old vs new, before claiming it |
| `bash -e` kills a `( ... ) &` sampler too, not just the step | Session 15: a background loop sampling `pgrep -af qemu` every 0.5 s died on its FIRST sample - taken before the VM existed, so pgrep exited 1 - and the step reported `vm=unseen` as if Kata had hidden it. `\|\| true` belongs INSIDE the sampler, not only on the measured command |
| A sampled value can belong to the PREVIOUS container | The same sampler, read with `head -1` from an appended file, reported `-m1056M` for a run that allocated 1536 MiB - impossible, it was the previous VM still shutting down. One file per run, and sanity-check every sample against the measurement it sits beside (the capped rows' `-m 288M` / `-m 1056M` were credible because they tracked their own caps) |
| `gh run view --log` is refused, but the job-log API is not a tail after all | Session 15, from the Windows box: `gh run view --job <id> --log` says "still in progress; logs will be available when it is complete", and the plain API call dies with "the response contains terminal escape sequences". `gh api repos/<owner>/<repo>/actions/jobs/<id>/logs --allow-escape-sequences` returns the **whole** log of a completed job (lines from the middle of a 10-minute job came back fine). Still put the evidence at the end of a job when the run may stay in flight, but a finished job's full log IS reachable |
| CAP_SYS_ADMIN is not permission to mount | Session 16: E3's drill container mounts tmpfs to make a real volume root. With `--cap-add SYS_ADMIN` it worked on Docker Desktop (WSL2 has no AppArmor) and failed on every GitHub runner, where the `docker-default` AppArmor profile denies `mount` outright. A fixture that needs a syscall needs the capability AND whatever MAC profile is in the way: add `--security-opt apparmor=unconfined` (drill only - the sandbox keeps its profiles). The three jobs went red honestly because the drill's positive control counted the missing mounts |
| A failure note that greps only the verdict lines hides the diagnosis | The same run printed `SETUP:not a mountpoint ...` inside the container, but phase E3's note grepped `LEAK:|REGRESSION:` only, so the suite reported two leaks and swallowed the three staging failures that explained them. Notes must print the staging lines too, and the probe must capture the failing command's own stderr (`mount` said nothing until it was asked) |
| A security fix's superseded note belongs on every release that still carries the hole | Session 16: v1.2.8, v1.2.9 and v1.2.10 had no note at all (the two newest were verification-only releases, so none was due). The mount-guard hole was in all three, so all three got the v1.2.11 note. Marking only the immediate predecessor would leave two releases that look current |
| `gh release create --target <sha>` is refused once the tag exists | `Release.target_commitish is invalid`. Push the annotated tag first, then `gh release create <tag>` with no `--target` - the tag already pins the commit |
| `RLIMIT_NPROC` is a per-uid budget and its reach is the HOST's | Session 15, measured both ways: on a GitHub runner (job user = uid 1001) the same `nproc=64` cap let uid 4242 fork 63 and uid 1001 only **4**, and one run earlier the container could not start python at all (`exit=255`, zero forks) - while on Docker Desktop 100 live uid-1001 processes in another container did not count against it. Measure an rlimit mechanism on an unused uid; the real uid's number says what that host does. gVisor and Kata are immune (Sentry / guest kernel count inside the sandbox) |
| A probe that never ran looks exactly like a cap that held | The `exit=255` nproc run printed nothing at all and the first version of the assertion reported "did not bound the fork loop" - wrong diagnosis, right redness. Every measurement now checks for its own first line (the cgroup label) and says "nothing was measured" when it is absent |
| `pull_request` already runs every CI job | Session 15: a PR needs no ci.yml scaffolding to measure on runtimes this box lacks - all five jobs ran on PR #9, and its first run caught the uid-1001 collision before `main` saw it. The temporary-branch-plus-push-trigger dance is only for a branch that should NOT be proposed for merge |
| Docker's `.State.OOMKilled` is false under Kata when the cap kills | The guest kernel does the kill, so the host records `exit=137 OOMKilled=false` (measured, 256m and 1024m caps). Judge a memory kill by the exit code and the allocation high-water mark, never by that flag. Under gVisor the opposite trap: `/sys/fs/cgroup/memory.max` does not exist in the sandbox at all, so an in-container check `skip`s and proves nothing - only an allocation past the cap does (phase M) |
---

## 6. Conventions

- Talk to the user in **Thai**; code, comments, commit messages and CI in **English**.
- Commit **and push after every completed step**. Author email is the GitHub noreply
  address (already configured in this repo). This repo is **public** by design.
- Commit messages explain *why*, and name the evidence (what was run, what it showed).
- Keep docs honest: limitations are stated, never softened (see `docs/THREAT_MODEL.md` §4).

---

## 7. Session log (newest first)

### 2026-10-10 — session 16 · Windows box · v1.2.11: the mount guard stops a whole removable volume
- **Did:** verified the handoff first (clean `main` = origin, `v1.2.10` one docs commit behind HEAD so the
  tag was not stale, last CI runs green, audit trail live, and - checked before asking - still no Colab
  output on this box). The user picked Next steps #3's mount-guard item. `assert_safe_mount()`'s own comment
  admitted the gap: its parent-NAME rule catches `/media/<label>`, but udisks mounts one level deeper, so
  `/media/<user>/<label>` (parent `/media/alice`) matched nothing and a whole USB stick or external disk was
  accepted silently; macOS `/Volumes` and `/Volumes/<label>` were never covered at all. Wrote the drill
  FIRST - E3 now mounts three real tmpfs volumes and proves each is a mountpoint before testing it - and
  watched it fail on the old code (4 problems: `LEAK:/Volumes`, `LEAK:/media/alice/USB-STICK`,
  `LEAK:/run/media/bob/DATA`, `LEAK:/Volumes/BACKUP`, no `SETUP:` lines, no `REGRESSION:`). Fixed it by
  asking the kernel instead of the name: `is_mount_point()` uses `mountpoint -q` where util-linux exists and
  otherwise compares the device number with the parent's, and any path under `/media`, `/run/media`,
  `/cygdrive` or `/Volumes` that is its own filesystem's root is refused with the way forward in the message;
  `/Volumes` also joined the shared-parent list and the whole-drive parent rule. Kept the other failure mode
  out with two accept-tests (a project inside a volume, a plain folder beside one) and scoped the heuristic to
  those prefixes so `/data` on its own disk stays mountable. Shipped through PR #10 (per v21: `pull_request`
  runs all five jobs for free) - **whose first run turned all three drill jobs red, correctly**: the tmpfs
  mounts never happened on the runners, the positive control counted it, and the two "leaks" it then reported
  proved nothing. CAP_SYS_ADMIN is not permission to mount where AppArmor runs. Added
  `--security-opt apparmor=unconfined` to the drill container, made the probe capture `mount`'s own stderr,
  and fixed phase E3's note to print `SETUP:` lines instead of hiding them. Second run: all five jobs green,
  E3 passing on real ext4, gVisor and Kata. Local suite A-M exit 0 on v1.2.11 (60 PASS, `enforced=4/7`).
  Merged, deleted the branch, then stopped at the user's request with the fix on `main` and no tag - and said
  so in `progress.md` ("RESUME HERE") and at the top of this file rather than leaving it to be discovered.
  On return: CI green on both `main` pushes → tagged `v1.2.11` at `e0b93f6` → released as Latest →
  superseded notes on v1.2.8, v1.2.9 AND v1.2.10, all of which carried the hole.
- **Learned:** a capability is not permission - a fixture that needs `mount` needs CAP_SYS_ADMIN *and* the
  MAC profile out of the way, and the difference between WSL2 and an Ubuntu runner is exactly AppArmor. The
  drill survived that only because its staging check counted; what nearly cost the diagnosis was the suite's
  own note, which grepped the verdict lines and dropped the explanation sitting right beside them.
- **Prompt should have said:** print the staging lines in a failure note, not only the verdict ones; and a
  security fix's superseded note goes on every release that still carries the hole, not just the last one.

### 2026-10-08 — session 15 · Windows box · v1.2.9: the memory cap is measured, not read off a label
- **Did:** verified the handoff against reality first (clean `main`, `v1.2.8` = HEAD~1 with only a docs
  commit past it, so the tag was NOT stale this time; the one remaining remote branch
  `claude/cool-knuth-mh33o8` has no commits past `main`; last 3 CI runs green; audit trail live). Checked
  for the Colab output before asking: `D:\code-project\warden-model-lab` holds only the **untuned** base
  GGUF from 26 Sep, no `manifest/`, nothing from October - so Next steps #2 is still on the user's side,
  and they confirmed the training run has not happened, the demo still has no date, and the OpenAI key is
  still not topped up. They picked Next steps #0's open question: **is `--memory` enforced under Kata?**
  Phase A could not answer it - it READS `/sys/fs/cgroup/memory.max` and passes when the file says
  "capped", which is the project's recurring defect shape. Wrote the assertion first
  (`scripts/drill-alloc-memory.py` + a new **phase M**: allocate past the cap in 16 MiB chunks, touching
  every page, uncapped container first as the positive control), watched it FAIL on the old behaviour with
  a phase-M-only scratch harness (cap stripped: capped run reached the full 768 MiB, `exit=0
  OOMKilled=false`, `memory.max=max`, suite exit 1), then saw it pass with the cap in place (240 MiB,
  `exit=137 OOMKilled=true`). Measured the runtimes this box cannot run on a temporary branch
  (`kata-memcap-probe`): a push trigger for it, plus a raw both-ways measurement step in the gVisor and
  Kata jobs before the suite, and the same numbers repeated in an `if: always()` end-of-job step. Runs
  37749560187 (256m) and 37751167935 (256m + 1024m) were green on all five jobs each. **Answer: enforced
  on all three**, with a fixed overhead (runc ~16 MiB, gVisor ~48, Kata ~112–128) - so the CLI's default
  `--memory 4g` is still honest, while a 256 MiB cap loses almost half under Kata. Two findings beside it:
  under Kata the kill is `exit=137` with **`OOMKilled=false`** (the guest kernel does it, the host never
  sees an OOM), and under gVisor `memory.max` **does not exist in the sandbox at all**, so phase A can only
  `skip`. Landed phase M on `main` without the temporary CI scaffolding, bumped to 1.2.9 FIRST, rebuilt from
  cache (no `--pull`, CLIs untouched), re-ran the whole suite on the new label (A–M exit 0, 35/35,
  `enforced=4/7`), waited for CI green on the `main` push, then tagged and released v1.2.9 - **without** a
  superseded note on v1.2.8, which would have been false (no security change). Deleted the probe branch.
  Docs: README claimed "11 phases" and its table stopped at **K** (phase L from v1.2.6 was never added) -
  now 13 with both L and M; `docs/THREAT_MODEL.md` gained a `--memory` row in the gVisor and Kata tables;
  `VERIFICATION.md` §0 quotes phase M from the v1.2.9 run; DEMO's checklist says A–M.
- **Learned:** the project's own rule "judge by measurement, never by a label" had a blind spot inside the
  suite itself - phase A's resource section was four cgroup READS, and under gVisor one of those files is
  absent, which `skip`s quietly and looks like coverage. Also: `gh api .../actions/jobs/<id>/logs
  --allow-escape-sequences` returns a finished job's FULL log from this box, not the tail the handoff
  assumed, which makes CI measurements much cheaper to read back. And `bash -e` reaches further than the
  step: it killed a background `pgrep` sampler on its first non-match, and the step then reported the
  missing VM size as if Kata had hidden it.
- **Prompt should have said:** a guard that READS a kernel file is a label, not a measurement - including
  the ones already inside the suite; and `|| true` belongs inside any background sampler in an Actions step.
- **Then, same session (user asked for the rest of it):** v1.2.10 extended phase M to the three remaining
  reads. SWAP: the posture `memory.swap.max=0` rules out is `--memory-swap` bigger than `--memory`, so the
  phase runs it - 496 MiB against the 240 the equal-swap run gets, i.e. swap is a real sidestep here and
  setting the two EQUAL is what holds the cap. PROCESSES: `scripts/drill-fork-count.py` forks until the
  kernel refuses (`os.fork()` in try/except, `flush=True`, children that keep their slot) - `nproc=64` stops
  at 63 with EAGAIN, `--pids-limit 64` at 63 with `pids.max=64`, both watched failing first (guards stripped:
  150 forks, no refusal, exit 1). `--pids-limit` is asserted on runc only and SKIPped with its reason
  elsewhere, because under gVisor it caps host tasks and under Kata nothing in the guest. Shipped as PR #9
  rather than a temp branch: `pull_request` runs all five jobs for free, and **its first run turned the ext4
  job red** - as uid 1001 the nproc container came back `exit=255` with zero forks, nothing measured, while
  gVisor and Kata passed. That is the per-uid budget: a runner's job user IS uid 1001. Measured both ways
  (Docker Desktop: 100 live uid-1001 processes elsewhere did NOT count; runner: uid 4242 forked 63, uid 1001
  only 4), then measured the mechanism on uid 4242 with a note-only uid-1001 run beside it, and added a
  guard so a probe that never ran reports "nothing was measured" instead of a cap that held. Local suite
  A–M exit 0 on v1.2.10, all five PR jobs green (37764437022), merged, branch deleted.
- **Learned (second half):** my first explanation of the red job was wrong and a 20-fork test "confirmed" it
  by being too small to distinguish - the decisive test needed a target above the cap. Cost ~10 minutes;
  the habit that saved it was running the experiment by hand instead of reasoning further.

### 2026-10-08 — session 14 · Windows box · v1.2.6/v1.2.7/v1.2.8 tagged, released and verified
- **Did:** `main` was 73 commits behind origin (fast-forwarded, clean - no local-only work). `git ls-remote
  --tags` confirmed v1.2.6 and v1.2.7 were merged but untagged, exactly as sessions 12/13 left them - this
  session has real write access (`git push --dry-run` succeeded), so tagged both at their merge commits
  (`9d265d0`, `7a577d8`), pushed, waited for CI green on both, published releases with drafted notes, marked
  v1.2.5 and v1.2.6 superseded. Deleted the three agreed-stray branches (`kata-probe`, `verify-s12`,
  `claude/wizardly-edison-9pzqzk`) that the cloud session's API delete had refused. Started Docker Desktop,
  rebuilt `--pull` (codex-cli 0.156.1 → 0.161.0, claude/aider unchanged). Ran the real codex path: with a
  non-git scratch workspace it refused ("Not inside a trusted directory" - 0.161.0's new check, not a warden
  bug); with a git-initialized workspace (what every real project is) it logged in, launched with
  `sandbox_mode=danger-full-access`, reached api.openai.com, and hit `Quota exceeded` - same unresolved
  credit issue as session 10, confirmed again rather than assumed. Ran the full `verify-isolation.sh` suite
  on Docker Desktop for the first time against this code line: A–L exit 0, `enforced=4/7`, and - for the
  first time ever on Docker Desktop rather than CI only - 3b2, L, E9, E10, E11 and E12 all passed. While
  re-quoting `docs/VERIFICATION.md` from that run, noticed the version strings (CLI, entrypoint, monitor)
  still said 1.2.7 even though `main` HEAD already carried PR #4's entrypoint fix under `[Unreleased]` -
  the Windows run had therefore verified code one commit past the v1.2.7 tag, unlabelled. Bumped to 1.2.8,
  turned CHANGELOG's `[Unreleased]` into `[1.2.8]`, rebuilt (cache-fast), re-ran the full suite clean a
  second time (self-test 35 passed, was 34), tagged and released v1.2.8 as Latest, marked v1.2.7 superseded.
- **Learned:** a tag can go stale the moment a later PR merges without a version bump - "done means run"
  has to include checking the version string actually matches what the suite just verified, not just that
  the suite passed. codex-cli 0.161.0's git-repo-trust check is a real behaviour change but not a bug to
  chase: every real `warden-cli.sh run <project>` target is already a git repo, so it never fires in
  practice - confirmed by testing both ways instead of assuming either.
- **Prompt should have said:** after a version-string bump driven by a merged-but-unlabelled fix, re-run
  the suite before tagging rather than trusting the previous run's result under the old label.

### 2026-10-08 — session 13 (cont. 2) · notebook/: data collection for our own model
- **Did:** the user asked for a `notebook/` folder to train our own AI and to collect data today. Found the
  2026-09-16 decision that notebook + data live in a separate private repo; asked: notebook here, data never
  committed; all four sources. Built `notebook/collect/` (common/redact, from_git, from_files, from_chats,
  from_hf, build) and `collect_data.ipynb` (14 cells, Colab + Drive). 14 tests; a mutation (redact() doing
  nothing) failed 4 of them; every notebook cell executed against this checkout (215 records, 0 secret-shaped
  strings left); `.gitignore` proven with `git check-ignore`. Trailers (Co-Authored-By) were leaking into
  prompts - stripped, tested.
- **Learned:** the generic "token = ..." rule over-redacted real code (`token = get_token()`); only literal
  values are secrets. A leak re-scan must strip the markers first, or it flags its own `<REDACTED:...>`.

### 2026-10-08 — session 13 (cont.) · v1.2.7: E11, E12, Kata supported
- **Did:** the user returned (context 18%, weekly 59% → stop 70%) and said continue. v1.2.6 still
  untagged (user's step). Asked: fix the forged-report headline (yes) and how to declare Kata. E11 written
  first; negative CI 37705657498 (one phase failed on the old CLI), fix green 37705778556. Kata: probes
  P1-P4 read for the first time; a watchdog in the suite job located the phase-I hang (aider on its first-run
  prompt); a targeted probe showed fd 0 = a pipe in `anon_pipe_read`. First fix (`-i </dev/null`) was
  green on runc but E12 under Kata still timed out (rc=142) - replaced by closing stdin in the entrypoint;
  old CLI rc=142 vs new rc=1, aider-local 70 s, full suite under Kata `All phases passed` (37711877983).
  User chose Kata supported with limits + CI job; added it. Bumped to 1.2.7; PR #3.
- **Learned:** E12 caught a fix that did nothing on the runtime it was for - the recurring bug shape, in my
  own change. A watchdog snapshot inside the hung CI job found in one run what session 12 could not.
  Then PR #4: E11 extended to PID 1's "from the canary tripwire" line (user call), drill first, fix green.
- **Prompt should have said:** "a runtime-specific fix is proven on that runtime, old vs new" and "put CI
  evidence at the end of the job; the API only gives a tail" (both now Gotchas, and in v18).

### 2026-10-07 — session 13 · v1.2.6 shipped from a cloud session
- **Did:** the user pasted a prompt for another project (Forge); attaching that repo was denied,
  so asked once which project, the demo outcome, how to ship and the budget (weekly 59%, stop
  70%). Found session 12's unshipped security fixes on `claude/wizardly-edison-9pzqzk` and
  `.ai/SESSION12.md` (the HANDOFF update it could not write). Merged the branch, bumped 1.2.5 →
  1.2.6 (CLI, entrypoint, monitor, CHANGELOG, DEMO.md), ran `bash -n`, `py_compile` and
  shellcheck as CI does (dockerd in the container), opened PR #1, merged it on green CI (runs
  37701110789, 37701337562). The tag push got HTTP 403 from the session's git proxy, so tag,
  release (notes with the "not run on Docker Desktop" warning) and v1.2.5's superseded note
  are the user's step in the GitHub UI.
  Folded SESSION12.md into this file (Status, Next steps, Decided, Gotchas, its log below),
  deleted it, NEXT_PROMPT v17.
- **Learned:** a handoff that lives on an unmerged branch is invisible to a session that starts
  from `main` - only `git branch -a` + a log of each remote branch found it. Read remote
  branches in the reality check.
- **Prompt should have said:** "list origin branches newer than main and read their `.ai/`
  files" (v17 START b), and "a date in the past is a question" was already v10 - it worked.

### 2026-09-28/29 — session 12 · cloud container · fixes verified on real images (written up in session 13)
- **Did:** found it was in a cloud container (no Docker Desktop; image builds blocked by
  deb.debian.org 403). Audited the tripwire and the proxy: (1) an inotify queue overflow silently
  lost a canary read - fixed fail-closed, drill E9; (2) **squid resolved every CONNECT hostname
  before refusing it - DNS exfiltration through the proxy** - fixed by rule order, phase L, plus
  self-test 3b2. After write access was granted: both verified on the real images by temp-branch CI
  with negative jobs (v1.2.5 confirmed leaky). Measured Kata 4.2.0 (works, sentinel honestly NOT
  armed, suite hangs in phase I). A runner rehearsal of `demo.sh --auto` showed act 3 ending with
  no report on a 0755 workspace; the user chose the fixes (E10, UNVERIFIED dirs). The demo date
  2026-09-29 was set, then passed unrecorded.
- **Learned:** the egress boundary had a silent channel because every check asked "was the request
  refused?" and none asked "what did the refusal leak?"; offline stand-in images are enough to prove
  a drill both ways when the real image cannot be built.

### 2026-09-27 — session 11 · v1.2.4 (sentinel self-proof; gVisor run for real)
- **Did:** reality check: Docker down (started), HANDOFF carried three stale Status tables (fixed
  first), the audit trail was DEAD again (173 NUL bytes) and `up` healed it. Asked 4 questions with
  the tool: no demo date, no OpenAI credit, gVisor via GitHub Actions, and "check the Colab model for
  me" - none exists. Closed Next-steps #4 by measurement (3 real breaches: inline record file survives
  1/3, console 3/3; decided not to delay PID 1). Verified gVisor on a runner through a temporary
  branch workflow (5 probe rounds): runsc ignores `--pid container:` (sentinel alone, `kill -USR1 1`
  hits itself), no cross-sandbox inotify, no Docker DNS (every CLI session died 78). Reproduced the
  sentinel lie here with a docker shim: `armed out-of-band`, agent killed the inline monitor, read the
  canary, exit 0. Wrote phase K first (FAILED 3/4 on v1.2.3), made the sentinel prove PID 1 is
  `warden-entrypoint` or say NOT armed (entrypoint + CLI from its own log), pinned proxy/model names
  with `--add-host` off runc, ran A/B under the runtime, fixed the self-test's by-name vault check
  (now measured, both directions) and its pids check (RLIMIT_NPROC), added the CI gVisor job. Local
  A-K exit 0 twice; CI 4 jobs green on main and the tag; shipped **v1.2.4**, v1.2.3 superseded.
  Measured the fork-death cause: `--pids-limit` counts gVisor host tasks (sweep: >=2048 lets nproc
  512 bind) - left as Next steps #1 with an open repro.
- **Learned:** (1) the house bug shape again, twice: "sentinel attached/armed" under a runtime where
  it saw nothing, and a self-test failing a WORKING vault by its fstype name - measure, never read a
  label; (2) a public CI runner is a real host for what this box cannot run (runsc), and a temporary
  branch + worktree keeps main green and the local suite untouched; (3) three of my own probes/checks
  lied first (a loop that died silently, a grep that matched the echoed command, a wrong theory
  about pids 4096) - each was caught only because the next step demanded positive evidence.
- **Cont. (after the first handoff, weekly still at 25% of the 30% line):** I had started END
  early by over-estimating its cost (it took ~0.5%). Kept going on Next steps #1: probe 4 showed
  the "CLI + 4096 still died" repro was contamination (clean run: 508 forks, EAGAIN); set the host
  task cap to 8x under `runsc*`, made CI's fork step demand EAGAIN + a surviving session, local A-K
  exit 0, CI green on main (`forked 508 ... python rc=0` through the real CLI) and on the tag -
  shipped **v1.2.5**, v1.2.4 superseded.
- **Prompt should have said:** the user's budget rule (this chat: stop at weekly +10%, i.e. 30%) is
  an END trigger alongside 70% context; check the Colab GGUF yourself before asking; verify on a CI
  runner via a temp branch when this host lacks the platform. All in v15.

### 2026-09-26 — session 10 · v1.2.0 (GPU model server, measured)
- **Did:** reality check matched HANDOFF (nothing to fix). Asked 3 blocking questions with the tool:
  no demo date; download the official Qwen2.5-Coder-1.5B-Instruct `q8_0` (1.89 GB, sha256 = HF's)
  to measure instead of waiting for the Colab model; CPU first, then GPU. Measured CPU through the
  real `start_model` (RAM peak 2.29 GB → `4g` holds; a 5.9k-token prompt takes 90 s), then GPU with
  the same hardening (VRAM 1.95/4 GB, 2 s for that prompt). Reproduced the CUDA image's silent CPU
  fallback (healthy, `no usable GPU found`), wrote phase J first (FAILED 3 on v1.1.0), built
  `WARDEN_MODEL_GPU=1` (pinned `server-cuda-b10991`, `--gpus` on the model only, offload proven from
  `-lv 4` log or refused, no-GPU refused before the pull). Ran J 7/7 here, the no-GPU side under a
  docker shim, and the silent-fallback path on the real CLI under a second shim (refused). Real
  `aider-local` fixed a bug on GPU and CPU. Bumped 1.2.0, rebuilt `--pull` (agents unchanged),
  real codex path (answered, honeypot → 99), suite A–J exit 0, demo COMPLETE, trivy 0, CI proved
  the no-GPU side on Linux, tagged **v1.2.0**.
- **Learned:** (1) a blocked task often has a public stand-in with the same shape - the base model
  answered every resource question the trained one would have; (2) "GPU enabled" was the house bug
  shape again (healthy while on CPU) and only running the image without a GPU showed it; (3) my
  first shim run "passed" while the shim was not even on PATH (`C:/...` split at the colon) -
  silence-is-not-evidence applies to test scaffolding too; (4) the Pro plan's 5-hour limit, not
  context, was the binding budget: 66% at start, 80% after ~45 min while context was at 27%.
- **Prompt should have said:** check `get_usage` (context % AND the 5-hour plan limit) at start
  and between steps, and hand off on whichever runs out first; look for a public stand-in before
  declaring a task blocked on the user. Both are in v13.

- **Cont. (user: "no prompt yet - work until 70% context"):** I had handed off at 30% context
  because the Pro 5-hour limit was at 83%; it reset a minute later. Kept going:
  `status` now lists model servers and flags ORPHANED ones (a `kill -9`'d CLI left a 2.2 GB model
  running while status said "none running"); aider-local gets local model metadata (no GitHub
  fetch, knows ctx; "Loaded model metadata from" was rejected as proof - the old code printed it
  too); `--no-breach` skips phase I's breach. Then the "how does the agent make it lie" question
  found three real record bugs: (1) an existing `WARDEN_SECURITY_INCIDENT.json` (earlier breach,
  or planted) swallowed every later breach's report - O_TRUNC + EACCES read as "the peer wrote it";
  (2) the agent can `kill -USR1 1` (PID 1 shares its uid) and got "from the canary tripwire" plus a
  report path that did not exist; (3) the sentinel's log - the one record the agent cannot write -
  was thrown away by `--rm`. Shipped **v1.2.1** (O_EXCL + own labelled record, CLI lists only this
  session's reports, honest unrecorded-signal wording, `Confirmed by the sentinel`; drills E6/E7 +
  D, all failing first). Then (4) `sanitize()` let newlines through: an exe path with a newline
  printed a whole forged `mode=sentinel` line in the inline log (not reachable in the sentinel's
  log, but fixed; E2b) and (5) `doctor` died silently under `set -euo pipefail` when df failed
  (E8) - **v1.2.2**. Measured and dropped the model-store idea (load is 31 s from a volume or the
  9p mount alike). The user's OpenAI key hit "Quota exceeded" - demo act 4 blocked until top-up.
  Last: `status` missed the new-style reports v1.2.1 itself introduced (E6 extended) - **v1.2.3**.
- **Learned (cont.):** (1) every record the agent can write is forgeable, so a monitor must never
  *defer* to one - the pre-v1.2.1 "peer already wrote it" guess was the whole bug; (2) a scratch
  harness is a stale copy - E7 "failed" on a fixed build because I had edited the drill after
  extracting it; (3) heredoc-fed Python ate my backslashes three more times even when doubled;
  (4) a drill written for one symptom (E8: "passes without measuring") exposed a worse one (the
  doctor dies silently) - write the drill first even for "cosmetic" fixes.
- **Prompt should have said:** END is triggered by CONTEXT only - a plan limit that is about to
  reset is a reason for a HANDOFF checkpoint, not for stopping; and codex "Quota exceeded" means ask
  the user about credit, not debug. Both in v14.

### 2026-09-26 — session 9 · v1.0.6 (audit trail) + v1.1.0 (offline local model)
- **Did:** reality check (Docker down → started; HANDOFF Status stale → fixed first). Asked
  both blocking questions with the question tool: no demo date; fine-tuning = (b) Colab LoRA
  → local. Proved the local-model assumptions by experiment (two `--network`s, llama-server
  as 65534 read-only no caps, endpoint behaviour, aider ↔ server) - and a control CONNECT to
  api.openai.com never showed in the proxy log: `docker logs` had been dead for 10 days (519
  NUL bytes from an unclean shutdown; `restart` keeps the file). Reproduced it, wrote phase H
  (FAILED on v1.0.5), made `up` prove liveness with a nonce and heal/refuse; shipped
  **v1.0.6** (rebuild, real codex path, A–H, demo COMPLETE, trivy 0, CI on tag, v1.0.5 marked
  superseded). Asked the user offline-vs-two-networks with the evidence → offline. Wrote phase
  I first (FAILED 5 on v1.0.6), built `WARDEN_EGRESS=none` + `aider-local`, added the
  manifest-outside-workspace guard from the "how does the agent make it lie" question, ran A–I
  green, real `aider-local` with the lab GGUF, real codex, demo COMPLETE, trivy 0, CI 12/12 on
  Linux, tagged **v1.1.0**.
- **Learned:** (1) silence is not evidence - the audit trail was the recurring bug shape in
  its purest form, and only a positive control exposed it; (2) a leftover check can pass
  vacuously - phase I's M5 did on the old code until it required proof the model existed;
  (3) running a single phase from a scratch harness made fail-first cheap (4 runs, seconds
  to minutes each, instead of 6-minute suites); (4) aider, like codex, exits 0 on failure.
- **Prompt should have said:** ask blocking questions with the tool so the answers arrive
  before work starts; "the log shows nothing" needs a positive control; absence checks must
  prove existence. All three are in v12.

### 2026-09-24 — session 8 · v1.0.5 released after the demo slipped
- **Did:** reality check first: repo untouched since 2026-09-16, weekly cron CI green on
  2026-09-21, Docker Desktop down (started), terminal panel empty - so the recording had
  not happened. User confirmed it was postponed with no new date and chose to release.
  Bumped 1.0.5 in the three version strings BEFORE rebuilding (the image carries two of
  them), turned CHANGELOG "Unreleased" into `[1.0.5]`, rebuilt both images `--pull`.
  The rebuild moved codex-cli 0.154.0 → 0.156.1, so the whole codex path was re-run with
  the real key: login from env OK, `sandbox: danger-full-access`, shell command answered,
  and a codex reading the honeypot was killed (exit 99, sentinel report `restricted`,
  `warden_version: 1.0.5`). Suite A-G exit 0, `demo.sh --auto --agent codex` DEMO
  COMPLETE, trivy 0/0 (75 agent-dep CVEs reported), shellcheck + hadolint clean.
  Regenerated the quoted blocks in README / DEMO.md / VERIFICATION.md from this build's
  single runs, tagged **v1.0.5** (CI green on main and on the tag), published the release
  as Latest and marked v1.0.4 superseded (both re-read afterwards).
- **Learned:** the freeze was doing real work - the very first rebuild after it lifted
  changed the agent CLI version, which is exactly what would have broken a recording.
  "Do not rebuild before the demo" and "after any rebuild, re-run the real agent path"
  are the same rule seen from two sides; the second half is now a gotcha.
- **Prompt should have said:** ask for the demo date up front when the milestone in this
  file is in the past - the whole plan (freeze vs release) depends on it.

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
- **Cont. (after the handoff commit):** CI on the handoff commit went RED - not code:
  NodeSource's setup script failed to fetch its key and exited 0, so the image build
  silently fell back to Debian's node 18 and died on `npm --version`. Re-ran (green),
  proved the exit-0 behaviour and a guard for it with the EXACT Dockerfile RUN block
  under dash in `debian:bookworm-slim` (key blocked: 3 retries then refuses, exit 1;
  normal: exit 0, npm 10.8.2), hadolint clean, full image built to a side tag
  `ai-warden/agent:nodeguard` so the demo image (claude 2.1.197) is untouched.
  Build-time only, identical image when NodeSource works -> main commit, no tag.
  Lesson: a session is not over at `git push` - it is over when CI on the LAST push
  is green; this one would have ended on a red main before the Monday cron
  (`0 6 * * 1` = 13:00 Thai time on demo day).
- **Cont. 2 (user asked about training their own model):** user chose option (ก):
  train in Colab, agent in AI Warden uses it. Checked the box first (RTX 3050 4 GB,
  aider 0.86.2 in the image, NO_PROXY contents), asked 4 decisions (answers in
  "Decided"), then built the notebook side in a new PRIVATE repo and wrote
  `.ai/design-local-model.md` - no AI Warden code, no change to the demo image.
  The libraries were newer than my own knowledge (transformers 5.17, trl 1.13), so
  the notebook was proven by executing it, not by reading it: smoke on CPU passed
  (validator refuses 6 bad-data cases, 3 LoRA steps, GGUF, llama.cpp server answers
  `/v1/chat/completions`). Inspecting `llama-server --help` found that the Web UI and
  `/slots` are ON by default and that `--tools` would hand an untrusted client
  `read_file`/`grep_search` - recorded as flags the design must pin (M4).
  NEXT_PROMPT unchanged: nothing here changed how a session should work; the
  decision lives in this file's Next steps #2, where the prompt already points.
- **Cont. 3 (user: "use my OpenAI key, I have credit"):** asked what for -> both the
  demo (act 4 = codex) and fine-tuning via the OpenAI API. Verified the key through
  the real CLI with output redacted (200, 130 models; fine-tuning list 200, 0 jobs).
  Ran codex the way Monday will: env-only login fails (401 loops); with
  `codex login --with-api-key` it answers, but its own sandbox made every shell command
  fail while exiting 0; with `sandbox_mode=danger-full-access` commands work and a
  codex told to read the honeypot died with exit 99. Wrote phase G first (FAILED on
  the old CLI), fixed the launcher, fixed `demo.sh`'s export-only key check (it would
  have skipped act 4 with the key in `.env`), added a live READY proof to act 4,
  switched the runbook to codex and "no rebuild on demo day". Suite A-G green,
  `demo.sh --auto --agent codex` DEMO COMPLETE. Official docs say OpenAI's fine-tuning
  platform is closed to new users -> pending user decision (Next steps #2).
  Slip: ran `codex login status` with the real key and it printed 5 key characters
  into my own log (not committed, not in docs) - gotcha recorded.

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
- **v22 · 2026-10-10** — session 16. (a) A CAPABILITY IS NOT PERMISSION: a fixture that needs
  `mount` needs CAP_SYS_ADMIN *and* `--security-opt apparmor=unconfined` - with the cap alone E3
  mounted on Docker Desktop (WSL2, no AppArmor) and failed on every GitHub runner; harness flags,
  never the sandbox; (b) a failure note must PRINT the staging lines, not only the verdicts - phase
  E3 reported two leaks and swallowed the three `SETUP:` lines that explained them, and the probe had
  to be told to capture `mount`'s own stderr; (c) a security fix's superseded note goes on EVERY
  release still carrying the hole (v1.2.8-v1.2.10 each got one), not just the predecessor; (d) push
  the annotated tag first - `gh release create --target <sha>` is refused once the tag exists.
- **v21 · 2026-10-08** — session 15 (second half; v20 was this session's first rewrite). (a) a PR is
  the cheapest way to measure on a platform this box lacks - `pull_request` already runs all five
  jobs, no ci.yml scaffolding, and PR #9's first run caught the uid-1001 nproc collision before
  `main` saw it; the temp-branch-plus-push-trigger dance is only for a branch that must not merge;
  (b) a probe that NEVER RAN looks exactly like a guard that held - check each measurement for its
  own first line and say "nothing was measured" when it is absent (an `exit=255` container with no
  output was first misreported as a cap that did not bound); (c) an rlimit is a per-uid budget whose
  reach is the host's, so measure the mechanism on an unused uid and run the real uid as a note;
  (d) a cap is asserted only where it IS the bound, elsewhere SKIP with the reason.
- **v20 · 2026-10-08** — session 15 (first half). (a) WORK: a guard that READS a kernel file is a LABEL, the
  reads already inside the suite included - phase A's `memory.max` check passed on a file gVisor
  does not even have, so it `skip`ped and looked like coverage (phase M now makes the kernel act);
  (b) a finished job's FULL log is reachable with `gh api .../actions/jobs/<id>/logs
  --allow-escape-sequences` (not `gh run view --log`, refused mid-run), so an end-of-job report
  step is a belt, not the only way - v18's "the API gives a tail only" was too pessimistic;
  (c) `bash -e` kills a `( ... ) &` sampler on its first non-match, and a sampled value read with
  `head -1` can belong to the PREVIOUS container (both cost this session a wrong `vm=unseen` and
  one impossible VM size); (d) a SECURITY fix owes a superseded note, a verification/docs release
  does not - v1.2.9 claiming one would have been false; (e) START e names the three standing
  blockers so they are asked once, not re-litigated.
- **v19 · 2026-10-08** — session 14, logged late (session 15 noticed the line was missing).
  (a) START b: check `main` HEAD against the last tag - a merged PR with no version-string bump
  makes the tag stale, and the Windows suite run had verified untagged code without knowing it;
  (b) WORK: after a version bump, re-verify rather than trusting a prior run under the old label;
  (c) a newer agent CLI can add real new behaviour (codex-cli 0.161.0's trusted-directory check) -
  test both ways before calling it a regression.
- **v18 · 2026-10-08** — session 13 (cont.). (a) WORK: prove a runtime-specific fix ON that runtime, old vs
  new (the first stdin fix was green on runc and did nothing on Kata; E12 caught it); (b) CI evidence goes at
  the END of a job or in its own job - the API returns only a tail; (c) a hung session is stopped by polling +
  `docker rm -f`, never by `timeout`; (d) START: both v1.2.6 and v1.2.7 need tagging first.
- **v17 · 2026-10-07** — session 13. (a) START b reads **origin branches newer than main** and their
  `.ai/` files (session 12's handoff sat unmerged on a branch for 8 days); (b) step 0 keeps "where am
  I + prove push" but adds "a cloud session can still merge: PR + CI on real images; the tag push is refused (403), so tag + release go to the user" (session 13
  merged v1.2.6 that way); (c) budget: the user's weekly number from the question tool is the stop
  line (59% → 70% this session); (d) the demo freeze text is gone (date passed, no new one).
- **v16 · 2026-09-28** — session 12. Step 0 (where am I + prove push access), budget question when
  `get_usage` is missing, demo date/freeze, Kata probe hand-off, "if push is impossible hand over
  patches". Lived in `.ai/NEXT_PROMPT_v16.md` on a branch until session 13 merged it.
- **v15 · 2026-09-27** — session 11. (a) **END triggers on the user's budget rule too**: the user set
  "use 10% of the weekly limit" (20% → stop at 30%) - START records the weekly % and the stop line,
  END fires at ~70% context OR that line minus the END cost, whichever first; (b) **a platform this
  host lacks = a GitHub runner via a temporary branch workflow + git worktree** - gVisor went from
  "unverifiable" to 4 found bugs in 5 probe rounds without touching the user's WSL or main;
  (c) **probes must survive their own failure and print state** - a fork loop with `2>/dev/null` died
  silently in 6 configurations; (d) **judge by measurement, never by a label** - `attached`, `9p`,
  `pids.max max` all misled this session; (e) START checks the Colab GGUF itself (user: "check it for
  me"); (f) the gVisor pids item was finished in the same session (v1.2.5), so the default task is the local model again; (g) END's cost is ~0.5% weekly - do not start it 5% early (I did, then resumed). Cut: v14's
  "CONTEXT % is the only END trigger" (superseded by (a)) and the local-model default task.
- **v14 · 2026-09-26** — session 10 (cont.). (a) **CONTEXT is the only END trigger** (user call):
  v13 made the plan's 5-hour limit an END trigger; I handed off at 30% context, the user said
  "work until 70%", and the limit reset a minute later - a plan limit now only earns a HANDOFF
  checkpoint; (b) **every record the agent can write is forgeable** - never defer to one: the
  swallowed-report, self-sent-SIGUSR1 and newline-in-exe bugs (v1.2.1/v1.2.2) all came from the
  "how does it lie" question; (c) **regenerate the scratch harness after every suite edit** - a
  stale copy failed E7 on a fixed build; (d) **no backslashes in heredoc-fed Python/sed, not even
  doubled; scan for control chars** - three corrupted files; (e) START asks about **OpenAI credit**
  and "Quota exceeded" means ask, not debug - the key ran dry mid-session. Cut: the standalone
  "recurring bug shape" line (folded into (b)) and the shim example text, to stay at 69.
- **v13 · 2026-09-26** — session 10. (a) **budget = context AND the plan's 5-hour limit**: START reads
  both with the `get_usage` tool and END triggers on whichever runs out first - this session opened
  at 66% of the 5-hour limit and hit 80% while context was at 27%, so a pure "70% context" rule
  would have died mid-work with no handoff; (b) **blocked on the user? find a public stand-in with
  the same shape** - the untuned base model answered every resource question the Colab model
  would have (4g holds, VRAM fits); (c) **a drill side this host cannot run: simulate it with a
  PATH shim, and prove the shim is live first** - the first shim run passed while inactive;
  (d) the "how does it lie" question now covers the TOOL too (CUDA image healthy on CPU);
  (e) quoted-output check is a script that strips ANSI; (f) default task/decisions updated (GPU
  shipped + decided, suite A-J). Merged, not dropped: HANDOFF-fix into START b, `set -e` into the
  edit-while-running line, the two "passes while proving nothing" items into one - 69 lines.
- **v12 · 2026-09-26** — session 9. (a) **silence is not evidence**: the egress audit trail
  had been dead for 10 days and a control CONNECT exposed it - START now checks `status`'s
  audit-trail row and WORK requires a positive control before trusting "no X in the log";
  (b) **absence checks must prove existence** - phase I's leftover checks passed on code
  that never started a model; (c) **ask blocking questions with the AskUserQuestion tool** -
  both answers arrived in the first minute instead of at turn end; (d) **prove a new phase's
  teeth by running only that phase** from a scratch harness (used 4×); (e) agent CLIs exit 0
  on failure (aider joined codex); (f) default task/decisions updated: fine-tuning decided
  and shipped, local sessions are offline, suite is A-I. Cut: the fine-tuning question and
  two compressible lines, to stay at 69.
- **v11 · 2026-09-26** — at the user's explicit request, the two rules they care most about
  are now unmissable: (a) END is titled "self-triggered at ~70% CONTEXT" and says a session
  that stops without handing off has failed its job; (b) step c states the goal in the
  user's words - the next chat must do MORE per chat and get BETTER results, never a bare
  version bump - and keeps "if nothing improved, say why". Also: START must ask, in its
  opening report, the two questions that block work (new demo date, fine-tuning choice),
  because two sessions in a row opened with them still unanswered. Five WORK items were
  compressed to stay at 69 lines; no rule was dropped.
- **v10 · 2026-09-24** — session 8. (a) **a milestone date in the past is a question, not a
  fact**: this session opened with the 2026-09-21 demo already gone and had to ask whether it
  happened before choosing between freeze and release. (b) **after any `build --pull`, re-run
  the real agent path with the real key** - the first rebuild after the freeze moved codex-cli
  0.154.0 → 0.156.1. (c) default task now points at "ask for the new demo date"; the v9 lines
  about the Monday rehearsal and the freeze were stale.
- **v9 · 2026-09-16** — session 7 (cont. 3). (a) **run the exact agent the user will use,
  with their key, through warden-cli before a demo** — codex looked fine but ignored the
  env key and its own sandbox failed every command while exiting 0; only real runs showed
  it. (b) **keys: presence checks only, redact `sk-[A-Za-z0-9_*-]+`** — `codex login
  status` printed 5 key characters into the session log. (c) default task rewritten: act 4
  is codex, key in `.env`, no rebuild before the recording, fine-tuning waits for the user
  (the v8 "no ANTHROPIC key, ask for it" lines were stale). Compressed three lines to stay
  at 69.
- **v8 · 2026-09-16** — session 7 (cont.). END now **waits for CI on the last push to be
  green** before handing off: the v7 handoff commit went red (NodeSource key download
  reset, setup script exited 0, build fell back to Debian node 18) after the session had
  pushed and considered itself done; without the check the next chat would have
  started on a red main three working days before the Monday demo + cron run.
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
