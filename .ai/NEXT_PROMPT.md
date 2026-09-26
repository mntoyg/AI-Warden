# AI Warden — next-session prompt · v14 · 2026-09-26

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
   a. Read .ai/HANDOFF.md fully — a claim to verify, including any Next-steps DIAGNOSIS:
      re-run its repro before building on it (v7: session 6's repro A blamed the wrong one).
   b. Reality check: git status, git fetch + commits on origin not in HEAD, latest tag vs
      commits after it, `gh run list --limit 3`, `docker info` (if DOWN: PowerShell
      Start-Process Docker Desktop, poll `docker info` in the background), and
      `./scripts/warden-cli.sh status` ("audit trail" must say live, v12). HANDOFF wrong? Fix + commit first.
   c. BUDGET: `get_usage` tool (via ToolSearch). CONTEXT % is the only END trigger (v14: I
      stopped at 30% for a plan limit that reset a minute later - you rejected that).
   d. Keys live only in `.env`: test presence, never print one (redact `sk-[A-Za-z0-9_*-]+`).
   e. Report in 3-5 lines (state, budget, first task), then ask what blocks work with the
      AskUserQuestion TOOL: demo date, OpenAI credit (v14: my key hit "Quota exceeded" -
      demo act 4 cannot pass until I top up), downloads (name+source+size).

2) WORK
   - Default task: HANDOFF Next steps #1 - local model side DONE (offline, GPU, metadata,
     measured); if my Colab GGUF exists, run it WARDEN_MODEL_GPU=1 aider-local vs the untuned
     base in the lab's outputs/qwen-base/, else the next item. Act 4 = CODEX.
   - Blocked on something only I can produce? Find a PUBLIC STAND-IN with the same shape
     (v13: the untuned Qwen 1.5B answered every resource question the trained one would).
   - After ANY `build --pull`, re-run the real agent path with my key before trusting the
     image (v10: a rebuild moved codex-cli 0.154.0 → 0.156.1). Bump versions BEFORE it.
   - Done means RUN, on the PATH I WILL RUN: `./scripts/verify-isolation.sh` green A-J,
     exit 0, enforced=4/7 here; report CONTENT claims via `warden-cli.sh run`.
   - New drill/assertion: write it FIRST, watch it FAIL on the OLD code, fix, run green -
     ONLY that phase (preamble + phase block sed-extracted into a scratch harness).
     REGENERATE the harness after every suite edit (v14: a stale copy failed E7 on a fix).
   - A drill side this host cannot run: a PATH shim, proven live with `command -v` first.
   - EVERY RECORD THE AGENT CAN WRITE IS FORGEABLE (workspace, /run/warden, PID 1's signal,
     its own stdout). Never let a monitor or the CLI defer to one; write your own and label
     what is unproven. v14's three record bugs (swallowed report, self-sent SIGUSR1, newline
     in exe) all came from asking "how does the agent make this lie?" - ask it of the TOOL
     too (v13: CUDA image healthy on CPU). Only the sentinel's container log is unforgeable.
   - SILENCE IS NOT EVIDENCE: make X happen once before trusting "the log shows no X", and a
     "nothing left behind" PASS must prove the thing EXISTED (v12, both).
   - Agent CLIs: assert on output, never rc. codex "Quota exceeded" = my credit, not the
     sandbox - ask me, don't debug (v14).
   - Output surprises you / a drill fails on a fixed build: STOP reading code, run the
     smallest experiment by hand (v14: E8's "said nothing" was the doctor dying silently).
   - NEVER edit a script a background run is executing. verify-isolation.sh is
     `set -uo pipefail` (NO -e): NEVER add `set -e` in a phase.
   - Canary paths (`$WARDEN_CANARY_FILES`, e.g. ~/.aws/credentials) trip if opened; `[ -f ]` doesn't.
   - Quoted output in docs comes from ONE real run; check every quoted line against its log
     with a script (strip ANSI: the in-container self-test prints colour regardless).
   - Scripted doc edits: NO backslashes in heredoc-fed Python or sed, not even doubled (v14:
     three corrupted files) - use chr(92) or the Edit tool, then scan for control chars.
     Read the Gotchas table first (MSYS paths, curl.exe, commit -F without MSYS_NO_PATHCONV).
   - Commit + push after every step. A security fix ships as TAG + release + superseded
     note (CI green on the tag, re-read); a feature is a minor version; never leave main red.

3) END — self-triggered at ~70% CONTEXT, do NOT wait to be asked, do NOT stop earlier
   a. At ~70% context STOP taking new work, finish and verify only what is in flight, then run
      this END sequence. A plan limit near 85% only earns a HANDOFF checkpoint commit.
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
stand-ins and live-proven shims; v14 makes context the only stop signal (the user's call),
and turns session 10's record bugs into one rule: never trust a record the agent can write.
