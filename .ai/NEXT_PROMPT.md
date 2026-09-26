# AI Warden — next-session prompt · v13 · 2026-09-26

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
   c. BUDGET: `get_usage` tool (via ToolSearch) = context % AND the 5-hour plan limit (v13:
      66% of the plan at start, 80% while context was 27%). Re-check between steps.
   d. Keys live only in `.env`: test presence, never print one (redact `sk-[A-Za-z0-9_*-]+`).
   e. Report in 3-5 lines (state, budget, first task), then ask what blocks work (demo date,
      downloads: name+source+size) with the AskUserQuestion TOOL - answers in minute one.

2) WORK
   - Default task: HANDOFF Next steps #1 - local model side DONE (offline v1.1.0, GPU v1.2.0,
     measured); if my Colab GGUF exists, run it WARDEN_MODEL_GPU=1 aider-local vs the untuned
     base in the lab's outputs/qwen-base/, else the next item. Act 4 = CODEX: `demo.sh
     --auto --agent codex` must stay DEMO COMPLETE.
   - Blocked on something only I can produce? Find a PUBLIC STAND-IN with the same shape
     (v13: the untuned Qwen 1.5B answered every resource question the trained one would).
   - After ANY `build --pull`, re-run the real agent path with my key before trusting the
     image (v10: a rebuild moved codex-cli 0.154.0 → 0.156.1). Bump versions BEFORE it.
   - Done means RUN, on the PATH I WILL RUN: `./scripts/verify-isolation.sh` green A-J,
     exit 0, enforced=4/7 here; report CONTENT claims via `warden-cli.sh run`.
   - New drill/assertion: write it FIRST, watch it FAIL on the OLD code, fix, run green -
     ONLY that phase (preamble + phase block sed-extracted into a scratch harness).
   - A drill side this host cannot run (J's no-GPU side): simulate it with a `docker` shim
     on PATH and PROVE it is live (`command -v docker`) - v13's first shim run "passed"
     while the real docker ran (a `C:/...` PATH entry splits at the colon).
   - SILENCE IS NOT EVIDENCE: make X happen once before trusting "the log shows no X" (v12:
     audit trail dead 10 days), and a "nothing left behind" PASS must prove the thing
     EXISTED (v12: phase I's leftover checks passed on code that never started a model).
   - Agent CLIs exit 0 on failure (codex, aider): assert on their output, never rc alone.
   - For every guard/report field you add, ask how the AGENT makes it lie (it controls
     argv, fds, timing, files, the workspace) - and how the TOOL does: v13's CUDA image
     turns healthy on the CPU when it sees no GPU, so "GPU mode" is proven from its log.
   - Output surprises you / a drill fails on a fixed build: STOP reading code, run the
     smallest experiment by hand (E5's race; v13's CUDA fallback, found in one run).
   - NEVER edit a script a background run is executing. verify-isolation.sh is
     `set -uo pipefail` (NO -e): NEVER add `set -e` in a phase.
   - Canary paths (`$WARDEN_CANARY_FILES`, e.g. ~/.aws/credentials) trip if opened; `[ -f ]` doesn't.
   - Recurring bug: a control that reports itself armed while enforcing nothing -> drill +
     fix + HANDOFF entry. Decided items stay decided (HANDOFF "Decided").
   - Quoted output in docs comes from ONE real run; check every quoted line against its log
     with a script (strip ANSI: the in-container self-test prints colour regardless).
   - Read the Gotchas table before scripting via Bash (MSYS paths, native curl.exe,
     commit -F, heredoc backslashes, PYTHONIOENCODING). Commit + push after every step.
     A security fix ships as TAG + release + superseded note (CI green on the tag, re-read);
     a feature is a minor version; a test/docs change needs no tag. Never leave main red.

3) END — self-triggered at ~70% CONTEXT or ~85% of the 5-hour limit, whichever is first
   a. At that point STOP taking new work, finish and verify only what is in flight, then
      run this END sequence. A session that stops without it has failed its job.
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
seconds. v12 added the two ways a check passes while proving nothing (untested silence,
vacuous absence). v13 adds the budget that actually ends sessions (the plan's 5-hour limit),
public stand-ins for work blocked on the user, and proving test scaffolding is live — all
from session 10.
