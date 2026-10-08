# AI Warden — next-session prompt · v20 · 2026-10-08

Copy everything inside the fence into a new chat. The session that uses it MUST
rewrite this file (see step 3) before it ends.

```text
You are continuing AI Warden: a Zero-Trust Docker sandbox for AI coding agents.
Project: D:\code-project\AI Warden   (the folder name has a space)
Repo:    https://github.com/mntoyg/AI-Warden   (PUBLIC on purpose)
Talk to me in Thai. Code, comments, commit messages and CI stay in English.
Docs are Thai prose + English commands/output/table headers - don't draft a doc in English.
🚩 First live demo: POSTPONED, no date. Nothing is frozen: ship normally (drill + tag + CI). Ask
   for a date once per session; with one, freeze before it.

0) WHERE AM I - first 60 seconds
   - `uname -a; docker info`. Cloud Linux: no Docker Desktop/.env/GGUF/GPU; `dockerd &` works as
     root, Hub pulls work, deb.debian.org blocked (no builds), git proxy refuses tag pushes (403)
     - PR + CI + merge works there, tag + release does not. Windows box: full access. Prove it
     either way: `git push --dry-run origin <branch>`.

1) START - before any work
   a. Read .ai/HANDOFF.md fully - a claim to verify; re-run any Next-steps repro first (v7).
   b. Reality check: git status; git fetch; `git log origin/main..origin/<b>` for EVERY remote
      branch, reading any `.ai/` file it changes; `git ls-remote --tags origin` vs `main` HEAD (a
      merged PR with no version-string bump = the LAST tag is stale, session 14); last 3 CI runs;
      `warden-cli.sh status` (audit trail says live; `up` heals it). Fix HANDOFF first.
   c. BUDGET (user rule, 2026-10-08): two END triggers, `get_usage` for both - (1) WEEKLY paced at
      ~10%/calendar day (delta since this chat began); (2) CONTEXT at ~70%. Either fires END.
   d. Keys live only in `.env`: test presence, never print one (redact `sk-[A-Za-z0-9_*-]+`).
   e. Check yourself before asking (Colab GGUF in Downloads / D: / G: / warden-model-lab - session
      15 found only the untuned base). Report in 3-5 lines, then ask with the AskUserQuestion TOOL,
      ONE call, only what blocks work. Open 2026-10-08: no demo date, no credit, no Colab run.

2) WORK
   - Top item of `.ai/HANDOFF.md` Next steps unless told otherwise; HANDOFF beats ROADMAP.md.
   - A platform this host lacks (runsc, KVM, real build): a TEMPORARY branch whose ci.yml push
     trigger includes it + a step measuring BOTH ways before the suite judges; delete it after.
     `rc=0; cmd || rc=$?` - `bash -e` also kills a `( ... ) &` sampler on its first non-match (v20:
     pgrep ran before the VM existed and the step blamed Kata). A sample comes from its own run's
     file, checked against the measurement. Blocked on what only I can make? A PUBLIC STAND-IN.
   - A finished job's FULL log: `gh api repos/<o>/<r>/actions/jobs/<id>/logs
     --allow-escape-sequences`, not `gh run view --log` (refused mid-run) - an end-of-job
     `if: always()` step is a belt now, not the only way (v20).
   - After ANY `build --pull`, re-run the real agent path with my key - bump versions FIRST, then
     re-verify under the NEW label (v19). A new CLI can add real behaviour (codex-cli 0.161.0
     refuses a non-git workspace): test both ways before calling it a regression.
   - Done means RUN, on the PATH I WILL RUN: `./scripts/verify-isolation.sh` green A-M, exit 0,
     enforced=4/7 on Docker Desktop; report CONTENT claims via `warden-cli.sh run`.
   - New drill/assertion: write it FIRST, watch it FAIL on the OLD code, fix, run green - ONLY that
     phase (regenerate the scratch harness after every suite edit); prove a check both ways.
   - JUDGE BY MEASUREMENT, NEVER BY A LABEL - a guard that READS a kernel file is a label, suite
     reads included: phase A's `memory.max` check passed on a file gVisor lacks entirely (v20).
     Make the kernel ACT, print the label beside it, and SILENCE IS NOT EVIDENCE: control first.
   - A RUNTIME-SPECIFIC fix is proven ON that runtime, old vs new; a drill side this host lacks
     gets a PATH shim, proven live with `command -v`. Kill a hung session by polling + `docker rm
     -f`, never `timeout`.
   - EVERY RECORD THE AGENT CAN WRITE IS FORGEABLE; only the sentinel's container log is not - and
     ask what a REFUSAL leaks, not only whether it refused.
   - Probes survive their own failure and print state; one measurement per clean container. When
     the log echoes the command, anchor greps on output lines (`grep -x`, `^`).
   - Agent CLIs: assert on output, never rc. codex "Quota exceeded" = my credit - ask, don't debug.
     Output surprises you: STOP reading code, run the smallest experiment by hand.
   - NEVER edit a script a background run is executing. verify-isolation.sh is `set -uo pipefail`
     (NO -e): NEVER add `set -e` in a phase. Canary paths trip if opened; `[ -f ]` doesn't.
   - NEVER type a backslash in heredoc-fed Python or sed: write the script with the Write tool.
   - Commit + push after every step, message in a NEW file per commit (`git log -1` first). A
     SECURITY fix ships as TAG + release + superseded note; a verification/docs release gets
     the tag and NO superseded note (v1.2.9, v20).

3) END - self-triggered (1c), do NOT wait to be asked, do NOT stop earlier
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
belonging to the previous container), and that not every tag owes a superseded note.
