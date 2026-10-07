# Session 12 notes (2026-09-28) — merge into HANDOFF.md, then delete this file

Written in a **cloud Linux container**, not the Windows box. `git push` and the GitHub API
returned 403 ("Resource not accessible by integration"), and auto-mode denied reading the rest of
HANDOFF.md / NEXT_PROMPT.md, so this file stands in for the HANDOFF update. The next session on the
Windows box: apply the patches (see "How to land this"), merge the sections below into HANDOFF.md,
replace NEXT_PROMPT.md with the v16 text at the end, delete this file, commit, push.

## How to land this

The user got `000*.patch` files (git format-patch of the session branch over `2133814`).
`git am` them onto a branch, NOT onto main before the demo (2026-09-29): they change the proxy
image (squid.conf) and the monitor inside the agent image, so they need a rebuild - the freeze
forbids that before the take. After the demo: `build --pull`, real codex path, suite A-L, CI, tag.

## Status deltas

| Thing | State |
|---|---|
| Demo | **DATE SET: 2026-09-29** (user, session 12). Freeze until it is recorded. User will top up OpenAI credit before it (act 4 = codex). Interactive rehearsal still never run |
| Unshipped security fixes | On branch `claude/wizardly-edison-9pzqzk` (pushed once the user granted write access): `fix(monitor)` inotify overflow -> breach (drill E9) and `fix(proxy)` DNS exfiltration through squid (phase L, self-test 3b2). **Verified on the REAL images by full CI on a temporary branch** (run 36364368300, commit 7a74f50: static, CVE, ext4 "All phases passed" incl. `PASS phase E9`, both `PASS phase L`, enforced=7/7; gVisor job green). Negative proof on the real proxy image (Squid 5.7) with the OLD squid.conf: `FAIL phase L: the proxy resolved the non-allowlisted name ... a DNS exfiltration channel` (run 36365091898). Not yet on Docker Desktop; not merged (freeze) |
| v1.2.5 (what the demo runs) | **has the proxy DNS exfiltration channel - confirmed on its real Squid 5.7**: squid resolves any CONNECT hostname before refusing it. Say it on camera or not - the user's call; the fix needs a proxy-image rebuild |
| Kata | **Measured** (Kata 4.2.0 static, qemu, GitHub runner with KVM; workflow kept at `.ai/kata-probe.yml`): a real CLI session under `WARDEN_RUNTIME=kata` runs, inline tripwire enforced=7/7, reaches api.anthropic.com through the proxy (`--add-host` path works), and the sentinel says `NOT armed` with its reason (own PID namespace) - the v1.2.4 self-proof is generic; a held-open canary read -> CLI exit 99. The full suite under Kata passed A-H and most of I, then HUNG >19 min at phase I's aider-local metadata check (38 s on runc) - open. Raw P1-P4 probe lines (DNS, --pid, inotify, pids) are in run 36366900384's log, not yet read (the log is ~2800 lines; the API only returns a tail). Kata 4.2.0 ships no `kata-runtime` CLI and keeps the shim outside /opt/kata/bin |
| Demo rehearsal on a runner (v1.2.5, `demo.sh --auto`) | DEMO COMPLETE on some takes; act 3 FAILED on 2 of ~8 (runs 36368314520 take 2, 36368859278 take 1): exit 99 + "Confirmed by the sentinel" but NO report and "possibly forged termination". Cause measured (36369383799): on a 0755 Linux workspace the root sentinel (no CAP_DAC_OVERRIDE) cannot write any report 6/6, so when it kills the inline monitor first nothing is written; 0777 -> the sentinel writes. Docker Desktop's 9p mount is writable by all, so the Windows take should not hit it (session 11 saw sentinel reports there). ROADMAP phase 2 #3. Also: `scripts/demo.sh` was 100644 in git (fixed on the branch, 253c059) |
| Phase 2 #2/#3 (user chose the fixes, 2026-09-29) | 7a5f491 on the session branch: the CLI writes `WARDEN_SECURITY_INCIDENT.sentinel-log.<ts>.<pid>.json` from the sentinel log when no report appeared (noclobber, never through a symlink), never says 'possibly forged' when the sentinel confirmed; unprobeable canary dirs are UNVERIFIED, not counted. Drill E10 (0755 workspace, inline killed). Real images: CI 36500312536 green (4 jobs); old CLI -> `FAIL phase E10: rc=99 reports=0` (36500312493). Ships in v1.2.6 |
| Temporary branches | `kata-probe` and `verify-s12` are still on origin: the git proxy of the cloud session refused the delete. Delete them in the GitHub UI |
| Cloud sessions | `dockerd` starts fine (root); deb.debian.org and Alpine CDN are blocked by the environment's egress policy -> no image builds; Docker Hub pulls work |

## Next steps (re-prioritised)

1. **After the demo: merge the session branch and ship v1.2.6** (security: tag + release +
   superseded note on v1.2.5). CI on real images is already green (see Status); still to do on the
   Windows box: bump versions, `build --pull`, real codex path, suite A-L on Docker Desktop (3b2 has
   never met Docker Desktop's DNS), re-quote VERIFICATION.md from one real run.
2. Local model (old #1): unchanged, waits on the user's Colab GGUF.
3. Kata: read P1-P4 from run 36366900384 (or rerun `.ai/kata-probe.yml` with `docker build -q` so
   the log is short), find the phase-I aider-local hang under Kata (a docker call with no timeout?),
   then decide whether to document Kata as supported-with-limits in THREAT_MODEL 4.1. In probe steps
   capture rc with `|| rc=$?` - GitHub runs steps with `bash -e` (bit this session twice).
4. **(decide first) CLI trusts a report file that appeared during the session.** An agent can write
   `WARDEN_SECURITY_INCIDENT.json` (and `/run/warden/breach.flag`) and `kill -USR1 1`: exit 99 and
   the headline "the canary tripwire terminated this sandbox" (the sentinel line then says it
   recorded no breach). Only a false positive can be forged, but the headline claims authorship the
   CLI cannot verify. Fix = headline only when the sentinel confirms; changes demo act-3 wording and
   the message for real home-canary breaches (inline-only evidence), so decide after the demo.
5. **(decide first) `probe_inotify_delivery` -> None counts as enforced.** When a monitor cannot
   write a canary directory it logs `unknown` but still counts the watch in `enforced=N/M`. On a deaf
   filesystem (9p/virtiofs) that it cannot write, that is "armed while enforcing nothing". Not
   measured (no deaf fs in the cloud); changing it moves the enforced numbers CI asserts.
6. Old #3 (detect-only witness under gVisor) and #5 (udisks mount guard): unchanged.

## Gotchas (new)

| Gotcha | What to do |
|---|---|
| A cloud session is not the Windows box | Check `uname -a; docker info` first; prove push access (`git push --dry-run`) before planning work that needs it. Session 12 wrote a whole Kata workflow, then hit 403 |
| squid `dst` ACLs resolve the name | Any `dst` rule evaluated before the allowlist makes squid resolve attacker-chosen names (DNS exfiltration). Keep `deny !allowed_domains` ahead of every DNS-needing ACL; phase L guards it |
| inotify `IN_Q_OVERFLOW` has wd -1 | It matches no watch, so a loop keyed on wd skips it silently. The monitor now trips on it (E9) |
| `mktemp -d` is 0700 | A container user other than root cannot read files in it; chmod before mounting (phase L's fake DNS died silently this way in the harness) |
| GitHub Actions steps run `bash -e` | `cmd; rc=$?` never reaches `rc=$?` when cmd fails - the step dies silently. s12-negative printed only the squid version and exited 1. Use `rc=0; cmd || rc=$?` |
| Temp-branch CI is the real-image test bed | A cloud session that cannot build images can still prove a fix on the real images: branch off, add the branch to ci.yml's push trigger ON THAT BRANCH ONLY, plus a negative job that puts the old file back. Session 12 did this for phase L/E9 |
| I typed a backslash in heredoc-fed Python again (6th time) | It happened to come out right (checked for control chars), but use the Edit tool - no exceptions |

## Session log

### 2026-09-28 — session 12 · cloud container, no push access
- **Did:** reality check (HANDOFF matched origin; tag v1.2.5; CI green). Asked with the tool: weekly
  ~30% (stop line 35%), Kata first, then learned the demo is **2026-09-29** and credit will be topped
  up. Found I was in a cloud container: started dockerd; image builds blocked (deb.debian.org 403);
  push + API 403. Wrote the Kata probe workflow (not run). Then audited the tripwire and the proxy:
  (1) inotify queue overflow silently lost a canary read (paused monitor + 24000 events -> no breach)
  - fixed fail-closed, drill E9, CLI reports the sentinel's events-lost line; not shown exploitable
  against an unpaused monitor (C floods on 2 shared cores). (2) **squid resolved every CONNECT
  hostname before refusing it -> DNS exfiltration through the proxy**, measured with a logging fake
  DNS; fixed by rule order, phase L (old FAIL / new PASS in a harness from the suite's own text),
  plus self-test 3b2 for Docker's embedded resolver (proven in 4 network setups).
  **Cont. (user granted write access):** pushed the session branch; ran full CI on a temporary
  branch - both fixes green on the real images (E9, phase L on Squid 5.7, gVisor job) - and a
  negative job: the old squid.conf on the real proxy image FAILS phase L, so v1.2.5 is confirmed
  leaky. Measured Kata 4.2.0 on a runner: sessions work, sentinel honestly NOT armed, breach -> 99,
  suite hangs in phase I (open).
- **Learned:** (1) the egress boundary had a silent channel that no drill looked at because every
  check asked "was the request refused?" and none asked "what did the refusal leak?"; (2) a harness
  with offline stand-in images (ubuntu/squid + the project's entrypoint) is enough to prove a drill
  both ways when the real image cannot be built; (3) the harness found a real drill bug (0700 temp
  dir) before any real run did.
- **Prompt should have said:** check where you are running and whether you can push BEFORE
  planning; if get_usage is missing ask for the weekly % once; when the user says "there is a date",
  ask for the date. All in v16.

### Prompt changelog line
- v16 (session 12): new step 0 (where am I + prove push access), budget question when get_usage is
  missing, demo date/freeze encoded, Kata probe hand-off, "if push is impossible hand over patches".
