# AI Warden — next-session prompt · v3 · 2026-09-15

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
      and `docker info` — Docker Desktop is often DOWN at session start (start it
      with PowerShell Start-Process, it takes ~1 min; poll `docker info`).
   c. Wherever HANDOFF disagrees with reality, reality wins: fix HANDOFF first.
   d. Report to me in 3-5 lines: current state, what you will do first, anything
      that surprised you. Then start.

2) WORK
   - Default task: the top item in HANDOFF "Next steps", unless I ask otherwise.
   - Done means RUN, not reasoned about: ./scripts/verify-isolation.sh must stay
     green on phases A-E (exit 0). On Docker Desktop `enforced=4/7` is correct;
     7/7 is a CI-on-ext4 claim. New behaviour gets a drill, not just a code change.
   - This project's recurring bug is a control that reports itself armed while
     enforcing nothing (v1.0.2: the mount guard "refused whole drives" but did not).
     For every guard you touch ask "how would I know if this silently did nothing?"
     and test exactly that. Writing that test can EXPOSE a new bug — when it does,
     record it in HANDOFF "Next steps" with a repro; do NOT weaken the drill to hide
     it, and do NOT silently widen this task into fixing it.
   - verify-isolation.sh runs `set -uo pipefail` (NO -e). NEVER add `set -e` in a
     phase: a breach drill exiting 99 is expected DATA, and a stray `set -e` kills
     the whole suite silently at 99 (cost ~20 min in session 3).
   - Read the Gotchas table in HANDOFF before scripting through the Bash tool
     (path mangling, `\033`/backslash escapes, `git commit -F`, set traps).
   - Commit + push after every finished step. A test-only change needs no tag. A
     security fix (even one touching only a host script) ships in a TAG and gets a
     superseded note on the release it replaces. For a release rebuild call
     `docker build --pull` directly — `warden-cli.sh build --pull` drops the flag.

3) END — mandatory, before your final message
   a. Update .ai/HANDOFF.md: Status, re-prioritised Next steps, new Gotchas, and a
      Session log entry (Did / Learned / "Prompt should have said").
   b. Rewrite .ai/NEXT_PROMPT.md so the next session does better than you did:
      - bump the version;
      - every change must cite a concrete event from THIS session
        ("lost N min because X -> now says Y"); no vague advice;
      - delete stale/unhelpful lines; stay under 70 lines and move detail into
        HANDOFF instead of growing the prompt;
      - add one line to HANDOFF "Prompt changelog".
   c. Commit + push, then paste the full new prompt text into your final reply.
```

---

## Why this prompt is shaped this way

- **Reality check first** — sessions have opened to audit fixes only on `main`,
  and to Docker Desktop being down. Trusting the notes would have missed both.
- **"Done means run"** — every serious bug here passed code review and failed only
  when the drills ran; twice now, *writing* a drill is what exposed the bug.
- **The `set -e` line** — a stray `set -e` (session 3) turned a legit exit-99 drill
  into a silent whole-suite abort with no error message; only bisecting found it.
- **"Record, don't widen" + tag discipline** — the loop rots if scope balloons or if
  security fixes sit untagged. New findings become the next task; fixes become tags.
- **Size-capped, evidence-cited rewrites** — each line earns its place with a real
  event; adding one should usually mean removing one.
