# AI Warden — next-session prompt · v6 · 2026-09-16

Copy everything inside the fence into a new chat. The session that uses it MUST
rewrite this file (see step 3) before it ends.

```text
You are continuing AI Warden: a Zero-Trust Docker sandbox for AI coding agents.
Project: D:\code-project\AI Warden   (the folder name has a space)
Repo:    https://github.com/mntoyg/AI-Warden   (PUBLIC on purpose)
Talk to me in Thai. Code, comments, commit messages and CI stay in English.
Docs are Thai prose + English commands/output/table headers (README, THREAT_MODEL,
VERIFICATION, DEMO all follow this) — don't draft a new doc in English.
🚩 First live test: Monday 2026-09-21 — recorded to video, pushed to GitHub, on THIS
   Windows Docker Desktop box (real agent + live breach, enforced=4/7). The demo
   deliverables SHIPPED (scripts/demo.sh, docs/DEMO.md, README): rehearse, don't rebuild.

1) START — before any work
   a. Read .ai/HANDOFF.md fully. It is a claim to verify, not a fact.
   b. Reality check: git status, git fetch + commits on origin not in HEAD, latest
      tag vs commits after it, `gh run list --limit 3`, `docker info` — Docker Desktop
      is often DOWN at start (PowerShell Start-Process; poll `docker info`, ~1 min).
   c. Where HANDOFF disagrees with reality, fix HANDOFF first (stale twice running).
   d. Report in 3-5 lines: state, first task, anything surprising. Then start.

2) WORK
   - Default task: top of HANDOFF "Next steps" — now the SENTINEL ATTRIBUTION defect
     (the on-disk incident report can name no process at all). Repro + three fix
     options are in the item; option (c) says what NOT to do. Monitor behaviour
     change: needs a drill + a tag, so ship it before Monday only if green with time
     to spare — a documented limitation beats a fresh regression.
   - Mandatory before Monday: `export ANTHROPIC_API_KEY=...`, `./scripts/demo.sh
     --auto` (must end "DEMO COMPLETE", exit 0), one `--agent claude` rehearsal.
   - Done means RUN — and run the PATH I WILL RUN. `./scripts/verify-isolation.sh`
     stays green A-F (exit 0), but any claim about the incident report's CONTENT must
     be checked through `warden-cli.sh run`: phases B/D use raw docker with no
     sentinel, so they show the rich inline report, while the real CLI's report is
     the sentinel's and is weaker. Both bugs found in the last two sessions hid in
     exactly that gap. On Docker Desktop enforced=4/7 is correct.
   - When output surprises you, STOP reading code and run the smallest controlled
     experiment instead (this session: `-e WARDEN_CANARY_ACTION=log` + raw docker run
     settled in one run what three rounds of reading the monitor could not).
   - Before a script asserts anything about the sandbox, check whether the paths it
     touches are seeded canaries (`$WARDEN_CANARY_FILES` — `~/.aws/credentials` and
     `~/.ssh/id_rsa_backup` are): reading one mid-test trips the tripwire. `[ -f ]`
     never opens a file.
   - Recurring bug: a control that reports itself armed while enforcing nothing,
     crying wolf, or reporting nothing at all. Test that case for every guard you
     touch; when it finds a bug, log it in HANDOFF Next steps with a repro — don't
     weaken the test or silently widen scope.
   - Output quoted in docs/README must come from ONE real run: a block stitched from
     two runs was caught in review this session, which for this project is a real
     defect, not a cosmetic one.
   - verify-isolation.sh is `set -uo pipefail` (NO -e). NEVER add `set -e` in a phase.
   - Read the Gotchas table before scripting via Bash (path mangling, \033 escapes,
     git commit -F, gh api leading slash, PYTHONIOENCODING for Thai). Commit + push
     after every finished step. A test/docs change needs no tag; a security fix ships
     in a TAG + superseded note (rebuild: `warden-cli.sh build --pull`, trivy, CI).
   - Check doc links/anchors against GitHub's rendering, not by eye: `gh api
     repos/mntoyg/AI-Warden/readme -H 'Accept: application/vnd.github.html'`, grep
     `id="user-content-..."` (the plain `markdown` endpoint emits no anchors).
   - A Next-steps item may resolve to NO code (a decision, or unverifiable here like
     gVisor without runsc) — that's finished, not a gap.

3) END — self-triggered, do NOT wait to be asked
   a. When your context passes ~70% of the window, STOP taking new work, finish and
      verify what is in flight, then run this END sequence and hand off.
   b. Update .ai/HANDOFF.md: Status, re-prioritised Next steps, new Gotchas, Session log
      (Did / Learned / "Prompt should have said").
   c. Rewrite .ai/NEXT_PROMPT.md so the NEXT chat does MORE per chat and gets BETTER
      results — a workflow upgrade, not a version bump: cut a step that wasted time,
      add a check that caught a real bug, encode a decision so it is not re-litigated.
      Every change cites a concrete event from THIS session; delete stale lines; keep
      it under 70 lines (detail goes to HANDOFF); bump the version; add one line to
      HANDOFF "Prompt changelog". If nothing genuinely improved, say why.
   d. Commit + push, then paste the full new prompt text into your final reply.
```

---

## Why this prompt is shaped this way

Reality-check first (HANDOFF has been stale at session start twice running; Docker is
often down). Done-means-run **on the real CLI path** — the v1.0.3 false alarm and the
session-6 attribution defect both hid where the drills don't look. Prefer one controlled
experiment over three rounds of reading code. Treat quoted output as evidence, not copy.
`set -uo pipefail` (never `set -e` in a phase), tag security fixes, record-don't-widen.
The session self-triggers its handoff at ~70% context, and every rewrite must earn its
lines with a real event from the session that wrote it.
