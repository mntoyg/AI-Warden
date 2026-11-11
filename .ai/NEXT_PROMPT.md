# AI Warden — next-session prompt · v23 · 2026-11-11

Copy everything inside the fence into a new chat. The session that uses it MUST
rewrite this file (see step 3) before it ends.

```text
You are continuing AI Warden: a Zero-Trust Docker sandbox for AI coding agents.
Project: D:\code-project\AI Warden   (the folder name has a space)
Repo:    https://github.com/mntoyg/AI-Warden   (PUBLIC on purpose)
Talk to me in Thai. Code, comments, commit messages and CI stay in English.
Docs are Thai prose + English commands/output/table headers - don't draft a doc in English.
🚩 Demo: POSTPONED, no date - nothing frozen, ship normally; ask once, and with a date, freeze.

0) WHERE AM I - `uname -a; docker info`. Cloud Linux: no Docker Desktop/.env/GGUF/GPU, `dockerd &` as root,
   no apt, git proxy refuses TAG pushes - PR + CI + merge, never release. Windows box: full access.

1) START - before any work
   a. Read .ai/HANDOFF.md fully - a claim to VERIFY, never a fact; re-run any Next-steps repro (v7). Then
      git status/fetch, `git log origin/main..origin/<b>` for EVERY remote branch, `git ls-remote --tags`
      vs `main` (merged PR + no bump = stale tag), `warden-cli.sh status`. Fix HANDOFF in commit #1.
   b. **`gh run list` IS the first alarm and nothing else rings it.** v23: the weekly schedule was RED for
      three weeks (10-26, 11-02, 11-09) while the handoff sat a month stale, so only this found it. A red
      suite makes every README claim unprovable: read the failing LINE, and fix CI before new work.
   c. BUDGET (2026-10-08): two END triggers via `get_usage` - WEEKLY ~10%/calendar day (delta since this
      chat began), CONTEXT ~70%. Keys live only in `.env`: presence only, never print (redact `sk-...`).
   d. Check yourself first (Colab GGUF in Downloads / D: / G: / warden-model-lab - only the untuned
      base as of 2026-11-11), report in 3-5 lines, then ask with the AskUserQuestion TOOL, ONE call,
      only what blocks work. Still open: no demo date, no OpenAI credit, no Colab run.

2) WORK
   - Top item of HANDOFF Next steps unless told otherwise (beats ROADMAP.md). A platform this host lacks
     (runsc, KVM, real build): open a PR - `pull_request` runs ALL FIVE jobs with no ci.yml scaffolding and
     caught a bug before `main` saw it twice (v21/v22); a temp branch is for one that must NOT merge.
     Blocked on what only I can make? STAND-IN. Finished job's log: `gh api .../jobs/<id>/logs
     --allow-escape-sequences` (v20).
   - AN AGENT CLI'S OUTPUT IS PROSE, AND PROSE GETS REWORDED. v23: phase G grepped `codex login status`
     for "Logged in using an API key"; 0.167.1 renamed it "API key configured" and CI went red three weeks
     on a cage that was fine - `rc=0, sandbox_off=1` said so in the failure line. Assert on what MOVES with
     the input (two keys -> two identities) or make the tool ACT (`codex sandbox -- <cmd>`: runs under
     warden's flag, refused under a later `-c sandbox_mode="read-only"`). Surprised by output? STOP reading
     code and run it BY HAND on the old and the new image - two `docker run`s answered this one.
   - After ANY `build --pull`, DIFF the bundled CLI versions and re-run the phase touching each one;
     bump versions FIRST, then re-verify under the NEW label (v19/v23: codex-cli 0.161.0 -> 0.167.1
     WAS the whole bug). A new CLI can add real behaviour, so test both ways.
   - Done means RUN, on the PATH I WILL RUN: `verify-isolation.sh` green A-M, exit 0, enforced=4/7. Write
     the suite's own rc INTO the log - `{ suite; printf '===EXIT=%s===' $?; } > log` - and before believing
     ANY background run check the LAST phase reached AND that marker. v23: a Git for Windows auto-update
     (`gfw-install-*`) killed the suite at phase J, K/L/M never ran, the task reported exit 0 with EMPTY
     output, 45 PASS / 0 FAIL looked like a pass. Bash broken? `Get-Process gfw-install*` before your code.
   - A probe that NEVER RAN looks like a guard that held: check every measurement for its own first
     line, say "nothing was measured" when it is missing, and PRINT the staging lines in the failure
     note, not just the verdicts (v22). An rlimit's reach is the HOST's: use an unused uid (v21).
   - New drill/assertion: write it FIRST, watch it FAIL on the OLD code, fix, run green - ONLY that phase
     (regenerate the scratch harness after every suite edit); prove it BOTH ways. v23: a sabotaged COPY of
     warden-cli.sh is cheapest - G1 failed with login stripped, G2 with the flag stripped, neither covered.
   - JUDGE BY MEASUREMENT, NEVER BY A LABEL - a guard that READS a kernel file is a label, and our own log
     line saying we PASSED a flag is one too (v23). Make the thing ACT, print the label beside it; control
     first. A CAPABILITY IS NOT PERMISSION: `mount` needs CAP_SYS_ADMIN *and* `--security-opt
     apparmor=unconfined` (WSL2 has no AppArmor, runners do, v22) - harness, never sandbox.
   - EVERY RECORD THE AGENT CAN WRITE IS FORGEABLE (only the sentinel's container log is not); ask
     what a REFUSAL leaks; check CONTENT claims on the `run` path. Anchor greps (`grep -x`) where the
     log echoes the command, and build the marker at RUNTIME so that echo cannot satisfy it (v23).
   - NEVER edit a script a background run is executing. verify-isolation.sh is `set -uo pipefail`
     (NO -e): never add `set -e` in a phase. Canary paths trip if opened; `[ -f ]` does not. NEVER
     type a backslash in heredoc-fed Python or sed: write the file with the Write tool.
   - Commit + push after every step, message in a NEW file per commit (`git log -1` first). A
     SECURITY fix ships as TAG + release + a superseded note on EVERY release still carrying the hole
     (v22); push the tag, THEN `gh release create <tag>` (`--target` refused). VERIFICATION-only
     still gets a tag (v1.2.9, v1.2.12), no note. Docs-only: no release.

3) END - self-triggered (1c), do NOT wait to be asked, do NOT stop earlier. (a) STOP taking new work;
   finish and verify only what is in flight. (b) Update .ai/HANDOFF.md (Status, Next steps, Gotchas,
   Session log: Did / Learned / "Prompt should have said") and land it on main - one left on a branch is
   lost, a STALE one is worse than none (v23 found one a month old that knew nothing of three weeks of red
   CI). (c) Rewrite this file: a workflow upgrade, every change citing an event from THIS session, under 70
   lines, bump version, log it in HANDOFF §8. (d) Push, WAIT for CI green, paste the new prompt in reply.
```

---

## Why this prompt is shaped this way

Reality-check first, done-means-run on the real CLI path, assertion-first drills (v12-v15).
v16-v18 added cloud-vs-Windows awareness, reading every remote branch, the cloud ship path
(PR + real-image CI + merge, never tag) and runtime-specific proof. v19 added the stale-tag check
and the re-verify after a version bump. v20-v21 come from session 15, where the suite's own resource
section turned out to be four cgroup READS - and under gVisor one of those files does not exist, so
the check skipped and looked like coverage: a guard that reads a kernel file is a label. v22 comes
from session 16, where a drill that had to mount tmpfs passed on Docker Desktop and failed on every
runner: a capability is not permission where AppArmor runs, and the suite's own failure note had the
explanation in hand and printed only its verdicts.

v23 comes from session 17, which opened on a handoff a month stale and a CI that had been red for
three weeks without anyone knowing. The cause was not in this repo at all: codex-cli reworded one
sentence, and phase G was grepping that sentence. So v23 promotes `gh run list` to the first alarm,
bans asserting on a vendor's prose (assert on what moves with the input, or make the tool act), and
demands the bundled CLI versions be diffed after every `--pull`. It also records the harness trap
that nearly let a half-run suite pass as a green one: a Git for Windows auto-update killed the run at
phase J and the background task reported exit 0 with no output - so the suite's own exit code now
goes into the log, and the last phase reached is checked before any run is believed. Step 3 was
folded into one paragraph to pay for the new material and stay under the line cap.
