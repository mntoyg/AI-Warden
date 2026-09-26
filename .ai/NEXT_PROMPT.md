# AI Warden — next-session prompt · v12 · 2026-09-26

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
      re-run its repro before building on it (v7: session 6's repro A blamed the wrong monitor).
   b. Reality check: git status, git fetch + commits on origin not in HEAD, latest tag vs
      commits after it, `gh run list --limit 3`, `docker info` (if DOWN: PowerShell
      Start-Process Docker Desktop, poll `docker info` in the background, ~5-60 s), and
      `./scripts/warden-cli.sh status` — its "audit trail" row must say live (v12).
   c. Where HANDOFF disagrees with reality, fix HANDOFF first and commit.
   d. Keys live only in `.env`: test presence, never print one (redact `sk-[A-Za-z0-9_*-]+`).
   e. Report in 3-5 lines (state, first task, surprises), then ask what blocks work —
      the demo date — with the AskUserQuestion TOOL, not prose: session 9 got both of
      its answers in the first minute and started the right work immediately.

2) WORK
   - Default task: HANDOFF Next steps #1 (the local model's AI Warden side shipped in
     v1.1.0; what is left needs my Colab run / GPU - don't rebuild what exists). Demo act 4
     is CODEX; `demo.sh --auto --agent codex` must stay DEMO COMPLETE.
   - After ANY `build --pull`, re-run the real agent path with my key before trusting the
     image (v10: a rebuild moved codex-cli 0.154.0 → 0.156.1). Bump versions BEFORE it.
   - Done means RUN, on the PATH I WILL RUN: `./scripts/verify-isolation.sh` green A-I,
     exit 0, enforced=4/7 here; report CONTENT claims via `warden-cli.sh run`.
   - New drill/assertion: write it FIRST, watch it FAIL on the OLD code, fix, run green.
     Run ONLY that phase for this (sed-extract helpers + the phase block into a scratch
     harness): the full suite is ~6 min and session 9 proved 2 phases this way, 4 runs.
   - SILENCE IS NOT EVIDENCE. Before trusting "the log / list shows no X", make X happen
     once and see it appear (v12: the egress audit trail had been dead for 10 days and
     was found only because a control CONNECT to api.openai.com never showed up).
   - A "nothing left behind / nothing happened" PASS must also prove the thing EXISTED
     (v12: phase I's leftover checks passed on the old code, which never started a model).
   - Agent CLIs exit 0 on failure (codex, aider): assert on their output, never rc alone.
   - For every guard/report field you add, ask how the AGENT makes it lie (it controls
     argv, fds, timing, files, the workspace): v12's "manifest inside the workspace lets
     the agent rewrite model AND hash" came from that question, like v1.0.4's argv bug.
   - Output surprises you, or a drill fails on a fixed build: STOP reading code, run the
     smallest experiment / the payload by hand (E5's race; phase I's M6 was a `tr` bug).
   - NEVER edit a script while a background run of it (or of the suite) is executing.
   - Canary paths (`$WARDEN_CANARY_FILES`, e.g. ~/.aws/credentials) trip if opened; `[ -f ]` doesn't.
   - Recurring bug: a control that reports itself armed while enforcing nothing, crying
     wolf, or reporting nothing/false. Found one? Drill + fix + HANDOFF entry. Decided
     items stay decided (HANDOFF "Decided", e.g. local-model sessions are offline).
   - Quoted output in docs comes from ONE real run, checked line-by-line against its log;
     if that run lacks a quoted line (sentinel won the race), keep the older labelled quote.
   - verify-isolation.sh is `set -uo pipefail` (NO -e). NEVER add `set -e` in a phase.
   - Read the Gotchas table before scripting via Bash (MSYS paths, native curl.exe,
     commit -F, heredoc backslashes, PYTHONIOENCODING). Commit + push after every step.
     A security fix ships as TAG + release + superseded note (CI green on the tag, re-read);
     a feature is a minor version; a test/docs change needs no tag. Never leave main red.

3) END — self-triggered at ~70% CONTEXT, do NOT wait to be asked
   a. The moment your context passes ~70% of the window: STOP taking new work, finish
      and verify only what is already in flight, then run this END sequence. Every
      session ends this way - a session that stops without it has failed its job.
   b. Update .ai/HANDOFF.md: Status, re-prioritised Next steps, new Gotchas, Session
      log (Did / Learned / "Prompt should have said").
   c. Rewrite .ai/NEXT_PROMPT.md so the NEXT chat does MORE per chat and gets BETTER
      results - a workflow upgrade, never a version bump: cut a step that wasted time,
      add a check that caught a real bug, encode a decision so it is not re-litigated.
      Every change cites a concrete event from THIS session; delete stale lines; under
      70 lines; bump the version; one line in HANDOFF "Prompt changelog".
   d. Commit + push, WAIT for CI on that last push to go green (`gh run view
      --log-failed` if red), then paste the full new prompt text into your final reply.
```

---

## Why this prompt is shaped this way

Reality-check first — including the *diagnosis* in a handoff item and, since v12, the
liveness of the egress audit trail. Done-means-run on the real CLI path. The loop that
makes sessions productive: assertion first → fails on old code → fix → passes, now run
per-phase so it costs seconds, not suite runs. v12 adds the two ways a check can pass
while proving nothing — silence that was never tested (dead log) and absence of
something that never existed (vacuous leftover check) — both found in session 9.
