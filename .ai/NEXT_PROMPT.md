# AI Warden — next-session prompt · v18 · 2026-10-08

Copy everything inside the fence into a new chat. The session that uses it MUST
rewrite this file (see step 3) before it ends.

```text
You are continuing AI Warden: a Zero-Trust Docker sandbox for AI coding agents.
Project: D:\code-project\AI Warden   (the folder name has a space)
Repo:    https://github.com/mntoyg/AI-Warden   (PUBLIC on purpose)
Talk to me in Thai. Code, comments, commit messages and CI stay in English.
Docs are Thai prose + English commands/output/table headers - don't draft a doc in English.
🚩 First live demo: POSTPONED, no date (2026-09-29 passed unrecorded). Nothing is frozen: ship
   normally (drill + tag + CI). Ask for a date once per session; with one, freeze before it.

0) WHERE AM I - first 60 seconds
   - `uname -a; docker info`. Cloud Linux (sessions 12, 13): no Docker Desktop, no .env, no GGUF,
     no GPU; `dockerd &` works as root, Docker Hub pulls work, deb.debian.org is blocked -> no
     image builds. Prove write access: `git push --dry-run origin <branch>`; if denied, say so at once.
   - A cloud session CAN still merge (session 13, v1.2.6): branch -> PR -> CI builds the real images
     (ext4 + gVisor) -> merge on green. Its git proxy REFUSED the tag push (403): in the cloud, hand
     tag + release to me with drafted notes; never route around it. On Windows: tag + release.

1) START - before any work
   a. Read .ai/HANDOFF.md fully - a claim to verify; re-run any Next-steps repro first (v7).
   b. Reality check: git status; git fetch; `git branch -r` + `git log origin/main..origin/<b>` for
      EVERY remote branch, and read any `.ai/` file it changes (session 12's handoff sat unmerged on
      a branch for 8 days; session 13 found it only this way). Latest tag vs commits after it, last
      3 CI runs, `docker info`, `./scripts/warden-cli.sh status` (audit trail must say live; `up`
      heals it). Fix HANDOFF first.
   c. BUDGET: `get_usage` via ToolSearch; if missing, ask once with the question tool for the weekly
      % and the stop line (session 13: 59% -> stop 70%). END fires at ~70% context OR ~1% before
      the stop line (END costs ~0.5%). 5-hour limit: never (v14).
   d. Keys live only in `.env`: test presence, never print one (redact `sk-[A-Za-z0-9_*-]+`).
   e. Check yourself before asking (Colab GGUF in Downloads / D: / G: / lab outputs). Then report
      in 3-5 lines and ask with the AskUserQuestion TOOL, in ONE call, only what blocks work.

2) WORK
   - FIRST: `git ls-remote --tags origin` - v1.2.6 (9d265d0) and v1.2.7 (PR #3 merge) untagged? HANDOFF #0.
   - Default task: HANDOFF #1 - on the Windows box run v1.2.7 for real (build --pull, real codex +
     honeypot, suite A-L incl. 3b2/L/E9-E12 on Docker Desktop, re-quote VERIFICATION.md). Cloud: #2/#3.
   - `.ai/ROADMAP.md` is the phase view; HANDOFF wins where they differ (fix the roadmap).
   - A platform or image this host lacks (runsc, KVM, real build): a TEMPORARY branch whose ci.yml
     push trigger includes it + a negative job that restores the old file (session 12). In workflow
     steps capture rc as `rc=0; cmd || rc=$?` - steps run `bash -e`.
   - Blocked on something only I can produce? Find a PUBLIC STAND-IN with the same shape (v13).
   - After ANY `build --pull`, re-run the real agent path with my key (v10). Bump versions first.
   - Done means RUN, on the PATH I WILL RUN: `./scripts/verify-isolation.sh` green A-L, exit 0,
     enforced=4/7 on Docker Desktop; report CONTENT claims via `warden-cli.sh run`.
   - New drill/assertion: write it FIRST, watch it FAIL on the OLD code, fix, run green - ONLY that
     phase (scratch harness regenerated after every suite edit - v14). Prove a check both ways.
   - A drill side this host cannot run: a PATH shim, proven live with `command -v` first.
   - A RUNTIME-SPECIFIC fix is proven ON that runtime, old vs new (v18: the first stdin fix was green on
     runc and did nothing under Kata - E12 caught it). Runner evidence goes at the END of a job or in
     its own job (the API gives a tail only); stop a hung session by polling + `docker rm -f`, never `timeout`.
   - EVERY RECORD THE AGENT CAN WRITE IS FORGEABLE; only the sentinel's container log is not.
     Also ask what a REFUSAL leaks, not only whether it refused (session 12: squid's DNS channel).
   - JUDGE BY MEASUREMENT, NEVER BY A LABEL. SILENCE IS NOT EVIDENCE: positive control first.
   - Probes survive their own failure and print state; one measurement per clean container (v15).
     When the log echoes the command, anchor greps on output lines (`grep -x`, `^`).
   - Agent CLIs: assert on output, never rc. codex "Quota exceeded" = my credit - ask, don't debug.
   - Output surprises you: STOP reading code, run the smallest experiment by hand.
   - NEVER edit a script a background run is executing. verify-isolation.sh is `set -uo pipefail`
     (NO -e): NEVER add `set -e` in a phase. Canary paths trip if opened; `[ -f ]` doesn't.
   - NEVER type a backslash in heredoc-fed Python or sed: write the script with the Write tool.
   - Commit messages: a NEW file per commit, check `git log -1` before push.
   - Commit + push after every step. A security fix ships as TAG + release + superseded note.

3) END - self-triggered (1c), do NOT wait to be asked, do NOT stop earlier
   a. STOP taking new work, finish and verify only what is in flight.
   b. Update .ai/HANDOFF.md: Status, Next steps, Gotchas, Session log (Did / Learned / "Prompt
      should have said"). Land it on main (PR) - a handoff left on a branch is lost (session 12).
   c. Rewrite .ai/NEXT_PROMPT.md: a workflow upgrade, every change cites an event from THIS
      session, under 70 lines, bump version, log it in HANDOFF.
   d. Commit + push, WAIT for CI on that push to go green, then paste the new prompt in the reply.
```

---

## Why this prompt is shaped this way

Reality-check first, done-means-run on the real CLI path, assertion-first drills (v12-v15).
v16 added "where am I + prove push" after session 12 lost hours to a cloud container with no
write access. v17 adds the two things session 13 needed: read every remote branch (the last
handoff was stranded on one), and the cloud ship path (PR + real-image CI + tag) that got
v1.2.6 merged while the Windows box was away (the tag push itself was refused - 403). v18 adds the rule
session 13 learned the hard way: a fix for one runtime is proven on that runtime, old vs new.
