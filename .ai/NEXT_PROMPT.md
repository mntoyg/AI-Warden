# AI Warden — next-session prompt · v22 · 2026-10-10

Copy everything inside the fence into a new chat. The session that uses it MUST
rewrite this file (see step 3) before it ends.

```text
You are continuing AI Warden: a Zero-Trust Docker sandbox for AI coding agents.
Project: D:\code-project\AI Warden   (the folder name has a space)
Repo:    https://github.com/mntoyg/AI-Warden   (PUBLIC on purpose)
Talk to me in Thai. Code, comments, commit messages and CI stay in English.
Docs are Thai prose + English commands/output/table headers - don't draft a doc in English.
🚩 Demo: POSTPONED, no date - nothing frozen, ship normally; ask once, and with a date, freeze.

0) WHERE AM I - first 60 seconds
   - `uname -a; docker info`. Cloud Linux: no Docker Desktop/.env/GGUF/GPU; `dockerd &` works as
     root, Hub pulls work, no apt (so no builds), git proxy refuses TAG pushes - PR + CI + merge
     works there, release does not. Windows box: full access. `git push --dry-run` proves it.

1) START - before any work
   a. Read .ai/HANDOFF.md fully - a claim to verify; re-run any Next-steps repro first (v7). Then
      reality: git status/fetch; `git log origin/main..origin/<b>` for EVERY remote branch + the
      `.ai/` files it changes; `git ls-remote --tags origin` vs `main` HEAD (a merged PR with no
      version bump = a stale tag); last 3 CI runs; `warden-cli.sh status` (says live). Fix HANDOFF.
   b. BUDGET (user rule, 2026-10-08): two END triggers, `get_usage` for both - (1) WEEKLY paced at
      ~10%/calendar day (delta since this chat began); (2) CONTEXT at ~70%. Either fires END.
   c. Keys live only in `.env`: test presence, never print one (redact `sk-[A-Za-z0-9_*-]+`).
   d. Check yourself first (Colab GGUF in Downloads / D: / G: / warden-model-lab - only the untuned
      base as of session 16), report in 3-5 lines, then ask with the AskUserQuestion TOOL, ONE call,
      only what blocks work. Still open: no demo date, no OpenAI credit, no Colab run.

2) WORK
   - Top item of `.ai/HANDOFF.md` Next steps unless told otherwise (it beats ROADMAP.md); a platform
     this host lacks (runsc, KVM, real build): open a PR - `pull_request` runs ALL FIVE jobs with no
     ci.yml scaffolding and caught a bug before `main` saw it twice (v21/v22); a temp branch is only
     for one that must NOT merge. In steps `rc=0; cmd || rc=$?`: `bash -e` kills a `( ... ) &`
     sampler on its first non-match (v20). Blocked on what only I can make? STAND-IN.
   - A finished job's FULL log: `gh api repos/<o>/<r>/actions/jobs/<id>/logs
     --allow-escape-sequences`, not `gh run view --log` (refused mid-run) - v20.
   - After ANY `build --pull`, re-run the real agent path with my key - bump versions FIRST, then
     re-verify under the NEW label (v19); a new CLI can add real behaviour, so test both ways.
   - Done means RUN, on the PATH I WILL RUN: `verify-isolation.sh` green A-M, exit 0, enforced=4/7.
   - A probe that NEVER RAN looks like a guard that held: check each measurement for its own first
     line, say "nothing was measured" when missing, and PRINT the staging lines in the failure note
     - E3's grepped only its verdicts and swallowed the `SETUP:` lines explaining them (v22). An
     rlimit is a per-UID budget whose reach is the HOST's: measure it on an unused uid (v21).
   - New drill/assertion: write it FIRST, watch it FAIL on the OLD code, fix, run green - ONLY that
     phase (regenerate the scratch harness after every suite edit); prove a check both ways.
   - A CAPABILITY IS NOT PERMISSION: a fixture needing `mount` needs CAP_SYS_ADMIN *and*
     `--security-opt apparmor=unconfined` - with the cap alone it mounts on Docker Desktop (WSL2, no
     AppArmor) and fails on every runner (v22). Flags like these are the harness, never the sandbox.
   - JUDGE BY MEASUREMENT, NEVER BY A LABEL - a guard that READS a kernel file is a label, suite
     reads included: `memory.max` passed on a file gVisor lacks, `memory.swap.max=0` never tried the
     sidestep (v20/v21). Make the kernel ACT, print the label beside it; control first.
   - A RUNTIME-SPECIFIC fix is proven ON that runtime, old vs new; a cap is asserted only where it
     IS the bound, elsewhere SKIP with the reason (`--pids-limit`: host tasks under gVisor, nothing
     in a Kata guest). A side this host cannot run gets a PATH shim, proven with `command -v`.
   - EVERY RECORD THE AGENT CAN WRITE IS FORGEABLE (only the sentinel's container log is not); ask
     what a REFUSAL leaks too, and check CONTENT claims on the `warden-cli.sh run` path.
   - Probes survive their own failure and print state; one measurement per clean container; anchor
     greps on output lines (`grep -x`, `^`) when the log echoes the command.
   - Agent CLIs: assert on output, never rc. codex "Quota exceeded" = my credit - ask, don't debug.
     Output surprises you: STOP reading code, run the smallest experiment by hand.
   - NEVER edit a script a background run is executing. verify-isolation.sh is `set -uo pipefail`
     (NO -e): never add `set -e` in a phase. Canary paths trip if opened; `[ -f ]` doesn't. NEVER
     type a backslash in heredoc-fed Python or sed: write the file with the Write tool.
   - Commit + push after every step, message in a NEW file per commit (`git log -1` first). A
     SECURITY fix ships as TAG + release + a superseded note on EVERY release still carrying the hole
     (v22); push the tag, THEN `gh release create <tag>` (`--target` is refused). Docs release: none.

3) END - self-triggered (1b), do NOT wait to be asked, do NOT stop earlier
   a. STOP taking new work, finish and verify only what is in flight.
   b. Update .ai/HANDOFF.md (Status, Next steps, Gotchas, Session log: Did / Learned / "Prompt
      should have said") and land it on main - a handoff left on a branch is lost.
   c. Rewrite .ai/NEXT_PROMPT.md: a workflow upgrade, every change citing an event from THIS
      session, under 70 lines, bump version, log it in HANDOFF §8 (v19 never got its line).
   d. Commit + push, WAIT for CI on that push to go green, then paste the new prompt in the reply.
```

---

## Why this prompt is shaped this way

Reality-check first, done-means-run on the real CLI path, assertion-first drills (v12-v15).
v16-v18 added cloud-vs-Windows awareness, reading every remote branch, the cloud ship path
(PR + real-image CI + merge, never tag) and runtime-specific proof. v19 added the stale-tag check
and the re-verify after a version bump. v20 comes from session 15, where the suite's own resource
section turned out to be four cgroup READS - and under gVisor one of those files does not exist,
so the check skipped and looked like coverage: a guard that reads a kernel file is a label. It
also records what made that session's CI measurements cheap (a finished job's full log is
reachable) and what made them expensive (`bash -e` killing a background sampler; a sampled value
belonging to the previous container), and that not every tag owes a superseded note. v22 comes from
session 16, where a drill that had to mount tmpfs passed on Docker Desktop and failed on every
runner: a capability is not permission where AppArmor runs, and the suite's own failure note had the
explanation in hand and printed only its verdicts. It also widens the superseded-note rule, since
three releases carried the mount-guard hole with no warning on any of them.
