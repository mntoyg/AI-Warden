# AI Warden — next-session prompt · v5 · 2026-09-16

Copy everything inside the fence into a new chat. The session that uses it MUST
rewrite this file (see step 3) before it ends.

```text
You are continuing AI Warden: a Zero-Trust Docker sandbox for AI coding agents.
Project: D:\code-project\AI Warden   (the folder name has a space)
Repo:    https://github.com/mntoyg/AI-Warden   (PUBLIC on purpose)
Talk to me in Thai. Code, comments, commit messages and CI stay in English.
🚩 First live test: Monday 2026-09-21 — recorded to video, pushed to GitHub, on
   THIS Windows Docker Desktop box (real agent + live breach, enforced=4/7).

1) START — before any work
   a. Read .ai/HANDOFF.md fully. It is a claim to verify, not a fact.
   b. Reality check: git status, git fetch + commits on origin not in HEAD, latest
      tag vs commits after it, `gh run list --limit 3`, `docker info` — Docker Desktop
      is often DOWN at start (PowerShell Start-Process; poll `docker info`, ~1 min).
   c. Where HANDOFF disagrees with reality, fix HANDOFF first.
   d. Report in 3-5 lines: state, first task, anything surprising. Then start.

2) WORK
   - Default task: top of HANDOFF "Next steps". Right now that is the DEMO deliverables
     for Monday (scripts/demo.sh + docs/DEMO.md + README polish) — unless I say otherwise.
   - Done means RUN — and run the PATH I WILL RUN. `./scripts/verify-isolation.sh` must
     stay green A-F (exit 0), but a demo/release ALSO needs a real `warden-cli.sh run`
     end-to-end (agent launch + live breach) with the incident report read by eye. The
     v1.0.3 false-alarm bug only ever appeared on the real CLI (inline monitor + sentinel
     race), never in the raw-docker drills. On Docker Desktop enforced=4/7 is correct.
   - Recurring bug: a control that reports itself armed while enforcing nothing (or
     crying wolf). For every guard you touch, test the "silently did nothing" / "false
     alarm" case. Writing that test keeps exposing real bugs — when it finds one, log it
     in HANDOFF Next steps with a repro; don't weaken the test or silently widen scope.
   - verify-isolation.sh is `set -uo pipefail` (NO -e). NEVER add `set -e` in a phase.
   - Read the Gotchas table before scripting via Bash (path mangling, \033 escapes,
     git commit -F, set traps). Commit + push after every finished step. A test/docs
     change needs no tag; a security/correctness fix ships in a TAG with a superseded
     note. Release rebuild: `warden-cli.sh build --pull` + trivy + CI green on the tag.
   - A Next-steps item may resolve to NO code (a decision, or unverifiable here like
     gVisor without runsc) — that's finished, not a gap.

3) END — self-triggered, do NOT wait to be asked
   a. When your context passes ~70% of the window, STOP taking new work, finish and
      verify what is in flight, then run this END sequence and hand off.
   b. Update .ai/HANDOFF.md: Status, re-prioritised Next steps, new Gotchas, Session log
      (Did / Learned / "Prompt should have said").
   c. Rewrite .ai/NEXT_PROMPT.md to make the NEXT chat do MORE per chat and get BETTER
      results — this is a workflow upgrade, not a version bump: cut a step that wasted
      time, add a check that caught a real bug, encode a decision so it is not
      re-litigated. Every change cites a concrete event from THIS session; delete stale
      lines; keep it under 70 lines (move detail to HANDOFF); bump the version; add one
      line to HANDOFF "Prompt changelog". If nothing genuinely improved, say why.
   d. Commit + push, then paste the full new prompt text into your final reply.
```

---

## Why this prompt is shaped this way

Reality-check first (sessions open to fixes only on `main`, or Docker down). Done-means-run,
and run the real path: every serious bug here passed review and failed only when a drill —
or a real `warden-cli run` — was run (v1.0.3 caught only in a demo dry-run). `set -uo pipefail`
(never `set -e` in a phase), tag security/correctness fixes, record-don't-widen. The prompt
self-triggers at ~70% context so a session hands off with room to spare, and each rewrite must
raise the ceiling on what one chat can finish — earn every line with a real event.
