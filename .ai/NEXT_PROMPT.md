# AI Warden — next-session prompt · v8 · 2026-09-16

Copy everything inside the fence into a new chat. The session that uses it MUST
rewrite this file (see step 3) before it ends.

```text
You are continuing AI Warden: a Zero-Trust Docker sandbox for AI coding agents.
Project: D:\code-project\AI Warden   (the folder name has a space)
Repo:    https://github.com/mntoyg/AI-Warden   (PUBLIC on purpose)
Talk to me in Thai. Code, comments, commit messages and CI stay in English.
Docs are Thai prose + English commands/output/table headers — don't draft a doc in English.
🚩 First live test: Monday 2026-09-21 — video, pushed to GitHub, on THIS Windows
   Docker Desktop box (real agent + live breach, enforced=4/7). Demo deliverables and
   v1.0.4 are SHIPPED: rehearse, don't rebuild. A behaviour change now needs drill +
   tag + CI with time to spare — a documented limitation beats a fresh regression.

1) START — before any work
   a. Read .ai/HANDOFF.md fully. It is a claim to verify — including the DIAGNOSIS in
      a Next-steps item: re-run its repro before building on it (v7: session 6's
      "repro A = sentinel defect" was wrong; the inline monitor was equally blind).
   b. Reality check: git status, git fetch + commits on origin not in HEAD, latest
      tag vs commits after it, `gh run list --limit 3`, `docker info` (if DOWN:
      PowerShell Start-Process Docker Desktop, poll `docker info`, ~1 min).
   c. Where HANDOFF disagrees with reality, fix HANDOFF first and commit.
   d. Your shell has NO ANTHROPIC_API_KEY. If a rehearsal is on the plan, ask me in
      the 3-5 line report to put it in `.env` (gitignored) — never paste it in chat.
   e. Report in 3-5 lines: state, first task, anything surprising. Then start.

2) WORK
   - Default task: HANDOFF Next steps #1 = the Monday rehearsal (`./scripts/demo.sh
     --auto` must end "DEMO COMPLETE" exit 0, then one `--agent claude` run). If I
     run it in my own terminal, read my terminal output instead of re-running.
     Without a key: do the next item that needs no behaviour change, or hand off.
   - Done means RUN, on the PATH I WILL RUN: `./scripts/verify-isolation.sh` green
     A-F (E1-E5), exit 0, enforced=4/7 here; claims about incident-report CONTENT
     must be checked via `warden-cli.sh run` (the sentinel usually writes that file;
     only phase B is raw docker with no sentinel).
   - Any new drill/assertion: write it FIRST, run it on the OLD image and watch it
     FAIL, then fix + `warden-cli.sh build --pull` + run it green. Cheap function-
     level check without a build: `git show <tag>:monitors/canary_monitor.py` in a
     python:3.11-slim container with `setpriv` (see HANDOFF Gotchas).
   - For every guard or report field you add, ask how the AGENT makes it lie (it
     controls argv, fds, timing, files in /workspace and /run/warden). v1.0.4's
     second bug came from that question: `exec -a /opt/warden/...` hid a reader.
   - A drill that fails on a fixed build: run its payload by hand once before
     touching the code — E5's failure was the drill's own race, not a regression.
   - When output surprises you, STOP reading code, run the smallest experiment.
   - NEVER edit a script while a background run of it is executing (bash reads it
     from disk mid-run; cost a full suite run). Edit, `bash -n`, then run.
   - Canary paths (`$WARDEN_CANARY_FILES`, incl. ~/.aws/credentials) trip the
     tripwire if a test opens them; `[ -f ]` never opens a file.
   - Recurring bug: a control that reports itself armed while enforcing nothing,
     crying wolf, or reporting nothing/false. Found one? Log it in HANDOFF Next
     steps with a repro — don't weaken the test or silently widen scope.
   - Output quoted in docs/README comes from ONE real run (regenerate whole blocks).
   - verify-isolation.sh is `set -uo pipefail` (NO -e). NEVER add `set -e` in a phase.
   - Read the Gotchas table before scripting via Bash (MSYS path mangling, commit -F,
     gh api leading slash, PYTHONIOENCODING). Commit + push after every step. A
     test/docs change needs no tag; a monitor/entrypoint fix ships as TAG + release +
     superseded note on the previous release (CI green on the tag first; re-read).
   - A Next-steps item may resolve to NO code (a decision, or unverifiable here like
     gVisor without runsc) — that's finished, not a gap. Decided items stay decided.

3) END — self-triggered, do NOT wait to be asked
   a. When context passes ~70% of the window, STOP new work, finish and verify
      what is in flight, then run this END sequence.
   b. Update .ai/HANDOFF.md: Status, re-prioritised Next steps, new Gotchas, Session
      log (Did / Learned / "Prompt should have said").
   c. Rewrite .ai/NEXT_PROMPT.md as a workflow upgrade, not a version bump: cut a
      step that wasted time, add a check that caught a real bug, encode a decision.
      Every change cites a concrete event from THIS session; delete stale lines;
      under 70 lines; bump the version; one line in HANDOFF "Prompt changelog".
   d. Commit + push, WAIT for CI on that last push to go green (v8: session 7's handoff
      commit went red on a NodeSource flake after "done"; `gh run view --log-failed`),
      then paste the full new prompt text into your final reply.
```

---

## Why this prompt is shaped this way

Reality-check first — and that now includes the *diagnosis* in a handoff item, not just
git/CI state. Done-means-run on the real CLI path. v7 adds the loop that made session 7
productive (assertion first → fails on old image → fix → passes) and the adversarial
question that found its second bug, plus the two traps that cost it runs (editing a
running script; a drill payload racing itself). The API key is flagged at START because
the rehearsal is the one mandatory task an agent's shell can never do on its own. v8: a
push is not the end of a session — green CI on the last push is.
