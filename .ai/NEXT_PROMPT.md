# AI Warden — next-session prompt · v15 · 2026-09-27

Copy everything inside the fence into a new chat. The session that uses it MUST
rewrite this file (see step 3) before it ends.

```text
You are continuing AI Warden: a Zero-Trust Docker sandbox for AI coding agents.
Project: D:\code-project\AI Warden   (the folder name has a space)
Repo:    https://github.com/mntoyg/AI-Warden   (PUBLIC on purpose)
Talk to me in Thai. Code, comments, commit messages and CI stay in English.
Docs are Thai prose + English commands/output/table headers — don't draft a doc in English.
🚩 First live test: POSTPONED, no date — nothing is frozen. With a date: stop rebuilding
   in the days before it and rehearse; without one: ship normally (drill + tag + CI).

1) START — before any work
   a. Read .ai/HANDOFF.md fully — a claim to verify, including any Next-steps DIAGNOSIS or
      OPEN QUESTION: re-run its repro first (v7; v15's "CLI + 4096 died" was contamination).
   b. Reality check: git status, git fetch + commits on origin not in HEAD, latest tag vs
      commits after it, `gh run list --limit 3`, `docker info` (if DOWN: PowerShell
      Start-Process Docker Desktop, poll in the background), `./scripts/warden-cli.sh status`
      ("audit trail" must say live; if DEAD, `up` heals it - v15 saw it twice). Fix HANDOFF first.
   c. BUDGET: `get_usage` (via ToolSearch). Write down weekly % at start and the STOP LINE
      (default: start + 10%, v15 user rule) - END fires at ~70% context OR ~1% before the stop
      line (END costs ~0.5%: v15 began it 5% early, then resumed). 5-hour limit: never (v14).
   d. Keys live only in `.env`: test presence, never print one (redact `sk-[A-Za-z0-9_*-]+`).
   e. Check yourself before asking: a Colab GGUF in Downloads / D: / G: / lab outputs (v15:
      I said "check it for me"). Then report in 3-5 lines and ask with the AskUserQuestion
      TOOL only what blocks work: demo date, OpenAI credit (empty since 2026-09-26), downloads.

2) WORK
   - Default task: HANDOFF Next steps #1 - run my Colab GGUF (WARDEN_MODEL_GPU=1 aider-local vs
     the untuned base in the lab's outputs/qwen-base/) if it exists, else the next item.
   - A platform this host lacks (runsc, KVM, Linux ext4): a GitHub runner via a TEMPORARY
     branch with its own `on: push: branches: [it]` workflow, in a `git worktree` (never switch
     the tree a suite runs from); delete branch + worktree after (v15: 5 gVisor rounds, main green).
   - Blocked on something only I can produce? Find a PUBLIC STAND-IN with the same shape (v13).
   - After ANY `build --pull`, re-run the real agent path with my key (v10). Bump versions first.
   - Done means RUN, on the PATH I WILL RUN: `./scripts/verify-isolation.sh` green A-K,
     exit 0, enforced=4/7 here; report CONTENT claims via `warden-cli.sh run`.
   - New drill/assertion: write it FIRST, watch it FAIL on the OLD code, fix, run green -
     ONLY that phase (preamble + phase block extracted into a scratch harness, regenerated
     after every suite edit - v14). Prove a new check both ways (v15: vault volume PASS, 9p FAIL).
   - A drill side this host cannot run: a PATH shim, proven live with `command -v` first
     (v15's phase K shim reproduced gVisor's PID-namespace bug on Docker Desktop).
   - EVERY RECORD THE AGENT CAN WRITE IS FORGEABLE; only the sentinel's container log is not.
     Ask "how does the agent - or the TOOL/RUNTIME - make this lie?" (v15: runsc made the
     sentinel say armed while it saw nothing).
   - JUDGE BY MEASUREMENT, NEVER BY A LABEL: "attached", fstype `9p`, `pids.max max` all
     misled v15. SILENCE IS NOT EVIDENCE: positive control first; absence checks prove existence.
   - Probes must survive their own failure and print state (v15: a fork loop with 2>/dev/null
     died silently 6 times) - python try/except + `docker inspect` exit/OOM; one measurement per
     clean container (v15: a run right after a crashed sandbox faked an OPEN QUESTION). When the
     log echoes the command, anchor greps on output lines (`grep -x`, `^`).
   - Agent CLIs: assert on output, never rc. codex "Quota exceeded" = my credit - ask, don't debug.
   - Output surprises you: STOP reading code, run the smallest experiment by hand (v14, v15).
   - NEVER edit a script a background run is executing. verify-isolation.sh is
     `set -uo pipefail` (NO -e): NEVER add `set -e` in a phase.
   - Canary paths (`$WARDEN_CANARY_FILES`, e.g. ~/.aws/credentials) trip if opened; `[ -f ]` doesn't.
   - Quoted output in docs/releases comes from ONE real run, checked line by line by script.
   - NEVER type a backslash in heredoc-fed Python or sed (5th corruption in v15): chr(10),
     `paste -sd ' '`, or the Edit tool; scan for control chars. Read the Gotchas table first.
   - Commit messages: a NEW file per commit, check `git log -1` before push (v15 reused one).
   - Commit + push after every step. A security fix ships as TAG + release + superseded
     note (CI green on the tag, re-read); a feature is a minor version; never leave main red.

3) END — self-triggered (1c), do NOT wait to be asked, do NOT stop earlier
   a. STOP taking new work, finish and verify only what is in flight.
   b. Update .ai/HANDOFF.md: Status, re-prioritised Next steps, new Gotchas, Session
      log (Did / Learned / "Prompt should have said").
   c. Rewrite .ai/NEXT_PROMPT.md so the NEXT chat does MORE per chat and gets BETTER results:
      a workflow upgrade, never a version bump - cut a step that wasted time, add a check
      that caught a real bug, encode a decision. Every change cites an event from THIS
      session; delete stale lines; under 70 lines; bump version; log it in HANDOFF.
   d. Commit + push, WAIT for CI on that last push to go green (`gh run view
      --log-failed` if red), then paste the full new prompt text into your final reply.
```

---

## Why this prompt is shaped this way

Reality-check first — including the *diagnosis* in a handoff item and the liveness of the
egress audit trail. Done-means-run on the real CLI path. The loop that makes sessions
productive: assertion first → fails on old code → fix → passes, run per-phase so it costs
seconds. v12 added the two ways a check passes while proving nothing; v13 added public
stand-ins and live-proven shims; v14 turned session 10's record bugs into one rule: never
trust a record the agent can write. v15 adds the user's budget line as a stop signal, a
public CI runner for platforms this box lacks, and "measure, never read a label" - the
three things that made session 11 find four gVisor bugs without breaking anything.
