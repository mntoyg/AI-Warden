# AI Warden — next-session prompt · v19 · 2026-10-08

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
   - `uname -a; docker info`. Cloud Linux: no Docker Desktop, no .env, no GGUF, no GPU;
     `dockerd &` works as root, Docker Hub pulls work, deb.debian.org is blocked -> no image
     builds, and its git proxy refuses tag pushes (403, sessions 12/13/14 all hit this - PR +
     real-image CI + merge works fine from there, tag + release does not). Windows box: full
     access, including tags. Prove write access either way: `git push --dry-run origin <branch>`.

1) START - before any work
   a. Read .ai/HANDOFF.md fully - a claim to verify; re-run any Next-steps repro first (v7).
   b. Reality check: git status; git fetch; `git branch -r` + `git log origin/main..origin/<b>` for
      EVERY remote branch, and read any `.ai/` file it changes. `git ls-remote --tags origin` vs
      `main` HEAD - a merged PR with no matching version-string bump means the LAST tag is stale
      (session 14: PR #4 landed under CHANGELOG `[Unreleased]` with the code still saying the old
      version - the Windows suite run had verified untagged code without knowing it). Last 3 CI
      runs, `docker info`, `./scripts/warden-cli.sh status` (audit trail must say live; `up` heals
      it). Fix HANDOFF first.
   c. BUDGET: `get_usage` via ToolSearch; if missing, ask once with the question tool for the weekly
      % and the stop line. END fires at ~70% context OR ~1% before the stop line (costs ~0.5%).
   d. Keys live only in `.env`: test presence, never print one (redact `sk-[A-Za-z0-9_*-]+`).
   e. Check yourself before asking (Colab GGUF in Downloads / D: / G: / lab outputs). Then report
      in 3-5 lines and ask with the AskUserQuestion TOOL, in ONE call, only what blocks work.

2) WORK
   - `.ai/HANDOFF.md` Next steps, top item, unless told otherwise. `.ai/ROADMAP.md` is the phase
     view; HANDOFF wins where they differ (fix the roadmap).
   - A platform or image this host lacks (runsc, KVM, real build): a TEMPORARY branch whose ci.yml
     push trigger includes it + a negative job that restores the old file. In workflow steps
     capture rc as `rc=0; cmd || rc=$?` - steps run `bash -e`.
   - Blocked on something only I can produce? Find a PUBLIC STAND-IN with the same shape.
   - After ANY `build --pull`, re-run the real agent path with my key - bump versions FIRST, and if
     a merged PR changed behaviour without bumping the version, that is the bug to fix before
     trusting the run (v19). A newer agent CLI can add real new behaviour (session 14: codex-cli
     0.161.0 refuses a non-git workspace) - test it both ways before calling it a regression.
   - Done means RUN, on the PATH I WILL RUN: `./scripts/verify-isolation.sh` green A-L, exit 0,
     enforced=4/7 on Docker Desktop; report CONTENT claims via `warden-cli.sh run`.
   - New drill/assertion: write it FIRST, watch it FAIL on the OLD code, fix, run green - ONLY that
     phase (scratch harness regenerated after every suite edit). Prove a check both ways.
   - A drill side this host cannot run: a PATH shim, proven live with `command -v` first.
   - A RUNTIME-SPECIFIC fix is proven ON that runtime, old vs new. Runner evidence goes at the END
     of a job or in its own job (the API gives a tail only); stop a hung session by polling +
     `docker rm -f`, never `timeout`.
   - EVERY RECORD THE AGENT CAN WRITE IS FORGEABLE; only the sentinel's container log is not.
     Also ask what a REFUSAL leaks, not only whether it refused.
   - JUDGE BY MEASUREMENT, NEVER BY A LABEL. SILENCE IS NOT EVIDENCE: positive control first.
   - Probes survive their own failure and print state; one measurement per clean container.
     When the log echoes the command, anchor greps on output lines (`grep -x`, `^`).
   - Agent CLIs: assert on output, never rc. codex "Quota exceeded" = my credit - ask, don't debug.
   - Output surprises you: STOP reading code, run the smallest experiment by hand.
   - NEVER edit a script a background run is executing. verify-isolation.sh is `set -uo pipefail`
     (NO -e): NEVER add `set -e` in a phase. Canary paths trip if opened; `[ -f ]` doesn't.
   - NEVER type a backslash in heredoc-fed Python or sed: write the script with the Write tool.
   - Commit messages: a NEW file per commit, check `git log -1` before push.
   - Commit + push after every step. A security fix ships as TAG + release + superseded note -
     and re-verify after any version bump, don't trust a prior run under the old label (v19).

3) END - self-triggered (1c), do NOT wait to be asked, do NOT stop earlier
   a. STOP taking new work, finish and verify only what is in flight.
   b. Update .ai/HANDOFF.md: Status, Next steps, Gotchas, Session log (Did / Learned / "Prompt
      should have said"). Land it on main (PR) - a handoff left on a branch is lost.
   c. Rewrite .ai/NEXT_PROMPT.md: a workflow upgrade, every change cites an event from THIS
      session, under 70 lines, bump version, log it in HANDOFF.
   d. Commit + push, WAIT for CI on that push to go green, then paste the new prompt in the reply.
```

---

## Why this prompt is shaped this way

Reality-check first, done-means-run on the real CLI path, assertion-first drills (v12-v15).
v16-v18 added cloud-vs-Windows awareness, reading every remote branch, the cloud ship path
(PR + real-image CI + merge, never tag), and runtime-specific proof. v19 adds what session 14
found doing the Windows-box catch-up itself owed: a merged-but-unlabelled fix makes the last tag
stale, so check `main` HEAD against the last tag before trusting it; and a version bump needs its
own re-verify run, not a reuse of the previous run's result under the old label.
