# CLAUDE.md — AI Warden

Zero-Trust Docker sandbox for AI coding agents. Public repo.

## Session loop (do this every time)

1. **Start:** read [`.ai/HANDOFF.md`](.ai/HANDOFF.md). Then verify it against reality
   (git status/fetch, latest tag, `gh run list`, `docker info`). Reality wins — fix the
   handoff if it is wrong.
2. **Work:** top item in HANDOFF "Next steps" unless told otherwise.
3. **End:** update `.ai/HANDOFF.md`, rewrite [`.ai/NEXT_PROMPT.md`](.ai/NEXT_PROMPT.md)
   (bump version, cite the event behind every change, stay under 70 lines), add a line
   to the prompt changelog, commit and push.

## Non-negotiables

- **Done means run.** `./scripts/verify-isolation.sh` must pass phases A–D. New
  behaviour gets a drill.
- **Recurring bug shape:** a control that reports itself armed while enforcing nothing.
  Test the "silently did nothing" case of every guard you touch.
- **Security fixes ship in a tag**, not just on `main`.
- Commit messages via `git commit -F <file>`; explain why and what was run.
- Docs state limitations plainly (`docs/THREAT_MODEL.md` §4).

The Gotchas table in `.ai/HANDOFF.md` lists the Windows/Git Bash traps that have
cost the most time. Read it before scripting through Bash.
