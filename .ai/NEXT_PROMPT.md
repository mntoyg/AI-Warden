# AI Warden — next-session prompt · v1 · 2026-09-14

Copy everything inside the fence into a new chat. The session that uses it must
rewrite this file (and bump the version) before it ends — see step 3.

```text
You are continuing AI Warden: a Zero-Trust Docker sandbox for AI coding agents.
Project: D:\code-project\AI Warden   (the folder name has a space)
Repo:    https://github.com/mntoyg/AI-Warden   (PUBLIC on purpose)
Talk to me in Thai. Code, comments, commit messages and CI stay in English.

1) START — before doing any work
   a. Read .ai/HANDOFF.md completely. It is a claim to verify, not a fact.
   b. Check reality: git status, git fetch + commits on origin not in HEAD,
      latest tag vs commits after it (unreleased fixes?), `gh run list --limit 3`,
      and `docker info` — if Docker Desktop is down, start it now; it takes a minute.
   c. Wherever HANDOFF disagrees with reality, reality wins: fix HANDOFF first.
   d. Report to me in 3-5 lines: current state, what you will do first, anything
      that surprised you. Then start.

2) WORK
   - Default task: the top item in HANDOFF "Next steps", unless I ask otherwise.
   - Done means RUN, not reasoned about: ./scripts/verify-isolation.sh must stay
     green on phases A-D, and new behaviour gets a drill, not just a code change.
   - This project's recurring bug is a control that reports itself armed while
     enforcing nothing. For every guard you touch, ask "how would I know if this
     silently did nothing?" and test exactly that.
   - Read the Gotchas table in HANDOFF before writing shell or Python through the
     Bash tool (path mangling, backslash escapes, `git commit -F`, set -e traps).
   - Commit + push after every finished step. Security fixes are not shipped until
     they are in a tag.

3) END — mandatory, before your final message
   a. Update .ai/HANDOFF.md: Status, re-prioritised Next steps, new Gotchas, and a
      Session log entry (Did / Learned / "Prompt should have said").
   b. Rewrite .ai/NEXT_PROMPT.md so the next session does better than you did:
      - bump the version;
      - every change must cite a concrete event from THIS session
        ("lost N min because X -> now says Y"); no vague advice;
      - delete lines that were stale or did not help; stay under 70 lines and
        move detail into HANDOFF instead of growing the prompt;
      - add one line to HANDOFF "Prompt changelog".
   c. Commit + push, then paste the full new prompt text into your final reply.
```

---

## Why this prompt is shaped this way

- **Reality check first** — session 2 opened to find the audit fixes only on `main`
  and Docker Desktop not running; both would have been missed by trusting the notes.
- **"Done means run"** — every serious bug in sessions 1–2 passed code review and
  failed only when the drills ran.
- **Evidence-cited, size-capped rewrites** — a self-improving prompt otherwise grows
  into a list of platitudes. Each line has to earn its place with a real event, and
  adding a line should usually mean removing one.
