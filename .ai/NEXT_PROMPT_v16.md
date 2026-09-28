You are continuing AI Warden: a Zero-Trust Docker sandbox for AI coding agents.
Project: D:\code-project\AI Warden   (the folder name has a space)
Repo:    https://github.com/mntoyg/AI-Warden   (PUBLIC on purpose)
Talk to me in Thai. Code, comments, commit messages and CI stay in English.
Docs are Thai prose + English commands/output/table headers - don't draft a doc in English.
🚩 First live demo: 2026-09-29 (set in session 12). If today is BEFORE or ON it: FREEZE - no
   image rebuild, no change to scripts/ or core/ on main; only rehearse and fix docs. If AFTER:
   ask how the take went (AskUserQuestion), record it in HANDOFF, then ship normally.

0) WHERE AM I - first 60 seconds (v16: session 12 was a CLOUD Linux container, not the Windows box,
   and found out only after writing a whole workflow)
   - `uname -a; docker info`. Cloud Linux: no Docker Desktop, no .env, no GGUF, no GPU. If the
     daemon is down there, `dockerd` in the background works (as root). apt inside `docker build`
     got 403 from deb.debian.org -> no image builds in the cloud unless the user allows that host.
   - PROVE WRITE ACCESS BEFORE PLANNING: `git push --dry-run origin <branch>`. Session 12 got 403
     "Resource not accessible by integration" on push AND on the API - all work stayed local.
     If denied: tell the user at once (reconnect GitHub / install the Claude App with write).

1) START - before any work
   a. Read .ai/HANDOFF.md fully - a claim to verify; re-run any Next-steps repro first (v7).
   b. Reality check: git status, git fetch + commits on origin not in HEAD, latest tag vs commits
      after it, last 3 CI runs, `docker info` (Windows + DOWN: PowerShell Start-Process Docker
      Desktop, poll in background), `./scripts/warden-cli.sh status` ("audit trail" must say live;
      if DEAD, `up` heals it). Fix HANDOFF first.
   c. BUDGET: `get_usage` via ToolSearch. If it does not exist (session 12), ask the user for the
      weekly % ONCE with the question tool. STOP LINE = user's number (session 12: 35%). END fires
      at ~70% context OR ~1% before the stop line (END costs ~0.5%). 5-hour limit: never (v14).
   d. Keys live only in `.env`: test presence, never print one (redact `sk-[A-Za-z0-9_*-]+`).
   e. Check yourself before asking (Colab GGUF in Downloads / D: / G: / lab outputs). Then report
      in 3-5 lines and ask with the AskUserQuestion TOOL only what blocks work. If the user says
      "there is a date" without giving it, ask for the date itself (session 12 needed 2 rounds).

2) WORK
   - FIRST, if `.ai/SESSION12.md` or my session-12 patches (`000*.patch`) exist: session 12 could not
     push. `git am` the patches on a branch, merge SESSION12.md into HANDOFF, delete it. They hold two
     UNSHIPPED security fixes (proxy DNS exfiltration: phase L; inotify overflow: E9) proven only
     with stand-in images - after the demo: rebuild, real codex path, suite A-L, CI, tag v1.2.6.
   - Default task after that: HANDOFF Next steps. Kata has a ready probe workflow
     from session 12 (`kata-probe.yml`, given to the user as a file): put it on a TEMPORARY branch
     `kata-probe` with its own `on: push: branches: [kata-probe]`, in a `git worktree`, read the
     run, delete branch + worktree after. Do not extend `runsc*` handling to Kata by guess.
   - A platform this host lacks (runsc, KVM, Linux ext4): a GitHub runner via a temporary branch.
   - Blocked on something only I can produce? Find a PUBLIC STAND-IN with the same shape (v13).
   - After ANY `build --pull`, re-run the real agent path with my key (v10). Bump versions first.
   - Done means RUN, on the PATH I WILL RUN: `./scripts/verify-isolation.sh` green A-K, exit 0,
     enforced=4/7 on Docker Desktop; report CONTENT claims via `warden-cli.sh run`.
   - New drill/assertion: write it FIRST, watch it FAIL on the OLD code, fix, run green - ONLY that
     phase (scratch harness regenerated after every suite edit - v14). Prove a check both ways.
   - A drill side this host cannot run: a PATH shim, proven live with `command -v` first.
   - EVERY RECORD THE AGENT CAN WRITE IS FORGEABLE; only the sentinel's container log is not.
   - JUDGE BY MEASUREMENT, NEVER BY A LABEL. SILENCE IS NOT EVIDENCE: positive control first.
   - Probes survive their own failure and print state; one measurement per clean container (v15).
     When the log echoes the command, anchor greps on output lines (`grep -x`, `^`).
   - Agent CLIs: assert on output, never rc. codex "Quota exceeded" = my credit - ask, don't debug.
   - Output surprises you: STOP reading code, run the smallest experiment by hand.
   - NEVER edit a script a background run is executing. verify-isolation.sh is `set -uo pipefail`
     (NO -e): NEVER add `set -e` in a phase. Canary paths trip if opened; `[ -f ]` doesn't.
   - NEVER type a backslash in heredoc-fed Python or sed: chr(10), `paste -sd ' '`, or Edit.
   - Commit messages: a NEW file per commit, check `git log -1` before push.
   - Commit + push after every step. A security fix ships as TAG + release + superseded note.

3) END - self-triggered (1c), do NOT wait to be asked, do NOT stop earlier
   a. STOP taking new work, finish and verify only what is in flight.
   b. Update .ai/HANDOFF.md: Status, Next steps, Gotchas, Session log (Did / Learned / "Prompt
      should have said").
   c. Rewrite .ai/NEXT_PROMPT.md: a workflow upgrade, every change cites an event from THIS
      session, under 70 lines, bump version, log it in HANDOFF.
   d. Commit + push, WAIT for CI on that push to go green, then paste the new prompt in the reply.
      If push is impossible (session 12), hand the user the files and say so plainly.
