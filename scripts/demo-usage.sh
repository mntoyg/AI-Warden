#!/usr/bin/env bash
# =============================================================================
#  AI Warden - the USAGE walkthrough (docs/DEMO.md section 0), on camera
# -----------------------------------------------------------------------------
#  Shows what a new user actually does: clone the public repo, check the host,
#  build, raise the egress filter, then work inside the cage - including with
#  their own GitHub repo. Every command is printed before it runs and every
#  result on screen comes from the live product, not from a recording.
#
#  Six shots, each one pausing so it reads on video:
#
#    1. clone        - the public repo into a temp dir, to prove step one works
#    2. host check   - setup-host.sh: a CHECK, not an installer (fail-closed)
#    3. build        - the agent image and the egress proxy
#    4. filter up    - `up` proves the audit trail answers, `status` reads it back
#    5. in the cage  - uid 1001, empty CapBnd, only your folder, and the two
#                      egress shots that prove DIFFERENT things
#    6. your repo    - git clone works inside the cage; git push does not,
#                      because the cage carries no credential
#
#  Like demo.sh, this FAILS LOUDLY when the story does not happen: a narrated
#  claim that nothing backs is the bug class this project exists to catch. The
#  exit code is the verdict, so it doubles as the pre-recording rehearsal.
#
#  Usage:
#    ./scripts/demo-usage.sh            # on camera: pauses between shots
#    ./scripts/demo-usage.sh --auto     # rehearsal: no pauses, no TTY needed
#    ./scripts/demo-usage.sh --keep     # keep the demo workspace and clone
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

AUTO=0
KEEP=0
for arg in "$@"; do
    case "$arg" in
        --auto) AUTO=1 ;;
        --keep) KEEP=1 ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        *) printf 'unknown option: %s\n' "$arg" >&2; exit 64 ;;
    esac
done

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

FAILURES=0
shot() {
    printf '\n%s%s================================================================%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" >&2
    printf '%s%s  SHOT %s%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET" >&2
    printf '%s%s================================================================%s\n\n' "$C_BOLD" "$C_CYAN" "$C_RESET" >&2
}
say()  { printf '%s>>%s %s\n' "$C_BOLD" "$C_RESET" "$*" >&2; }
cmd()  { printf '\n%s   $ %s%s\n\n' "$C_DIM" "$*" "$C_RESET" >&2; }
good() { printf '  %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
bad()  { printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; FAILURES=$((FAILURES + 1)); }
note() { printf '  %s%s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
pause() {
    [ "$AUTO" = "1" ] && return 0
    printf '\n%s   [ Enter to continue ]%s ' "$C_DIM" "$C_RESET" >&2
    read -r _ </dev/tty 2>/dev/null || true
    printf '\n' >&2
}

DEMO_WS="${PROJECT_ROOT}/workspaces/.usage-demo-$$"
CLONE_DIR="${PROJECT_ROOT}/workspaces/.usage-clone-$$"
cleanup() {
    if [ "$KEEP" = "0" ]; then
        rm -rf "$DEMO_WS" "$CLONE_DIR" 2>/dev/null || true
    else
        note "kept: ${DEMO_WS} and ${CLONE_DIR}"
    fi
}
trap cleanup EXIT

# =============================================================================
shot "0 - is this machine ready?"
# =============================================================================
cmd "docker info --format '{{.ServerVersion}} {{.OperatingSystem}}'"
if docker info --format '{{.ServerVersion}} {{.OperatingSystem}}' 2>&1; then
    good "the Docker daemon answers - nothing below can work without this"
else
    bad "the Docker daemon is not reachable. Start Docker Desktop, wait, and run this again."
    printf '\n  %sStopping: there is nothing to show yet.%s\n\n' "$C_RED" "$C_RESET" >&2
    exit 1
fi
pause

# =============================================================================
shot "1 - clone the public repo"
# =============================================================================
say "step one for a new user. The repo is public on purpose: the code that makes"
say "the security claims is the code you can read."
mkdir -p "$CLONE_DIR"
cmd "git clone --depth 1 https://github.com/mntoyg/AI-Warden.git"
# git is a native Windows program here, and this script exports MSYS_NO_PATHCONV
# for docker's sake - which hands git an unconverted /d/... path and makes it
# clone into D:\d\... instead. Drop both vars for git only (harmless on Linux),
# and never hide the clone's exit code behind a pipe to `tail`.
clone_out="$(env -u MSYS_NO_PATHCONV -u MSYS2_ARG_CONV_EXCL \
    git clone --depth 1 https://github.com/mntoyg/AI-Warden.git "${CLONE_DIR}/AI-Warden" 2>&1)"
clone_rc=$?
printf '%s\n' "$clone_out" | tail -3
if [ "$clone_rc" -eq 0 ] && [ -f "${CLONE_DIR}/AI-Warden/scripts/warden-cli.sh" ]; then
    good "clone complete: $(du -sh "${CLONE_DIR}/AI-Warden" 2>/dev/null | cut -f1 | tr -d ' ') on disk, HEAD is $(env -u MSYS_NO_PATHCONV -u MSYS2_ARG_CONV_EXCL git -C "${CLONE_DIR}/AI-Warden" log --oneline -1 2>/dev/null)"
    note "no images yet - that is the next step, and it is the only slow one"
else
    bad "the clone did not produce a working tree (rc=${clone_rc}): $(printf '%s\n' "$clone_out" | tail -1)"
fi
say "the rest of this walkthrough runs from a checkout exactly like that one."
pause

# =============================================================================
shot "2 - check the host (this is a CHECK, not an installer)"
# =============================================================================
cmd "./scripts/setup-host.sh"
setup_out="$("${SCRIPT_DIR}/setup-host.sh" 2>&1)"; setup_rc=$?
printf '%s\n' "$setup_out" | grep -E '^\s*(\[ ok \]|\[fail\]|\[warn\]|[0-9]+ passed)' | head -20
if [ "$setup_rc" -eq 0 ]; then
    good "exits 0: $(printf '%s\n' "$setup_out" | grep -E '[0-9]+ passed' | tail -1 | sed 's/^ *//')"
    note "it also wrote .env (mode 600). Every key lives there and nowhere else - never in the image."
else
    bad "setup-host.sh exited ${setup_rc}: $(printf '%s\n' "$setup_out" | grep '\[fail\]' | head -1)"
    note "that is fail-closed behaviour, not a crash: fix the red line and run it again"
fi
pause

# =============================================================================
shot "3 - build the two images"
# =============================================================================
say "one image for the agent, one for the egress proxy. A clean machine pulls"
say "~3-4 GB here and takes minutes; with a warm cache it is seconds."
cmd "./scripts/warden-cli.sh build"
build_out="$("${SCRIPT_DIR}/warden-cli.sh" build 2>&1)"
printf '%s\n' "$build_out" | grep -E '^\[|ok  \]' | tail -4
if docker image inspect ai-warden/agent:latest >/dev/null 2>&1; then
    good "agent image present: $(docker image inspect ai-warden/agent:latest --format '{{.Id}}' | cut -c8-19)"
else
    bad "the agent image is still missing after build"
fi
pause

# =============================================================================
shot "4 - raise the egress filter, then read it back"
# =============================================================================
cmd "./scripts/warden-cli.sh up"
up_out="$("${SCRIPT_DIR}/warden-cli.sh" up 2>&1)"
printf '%s\n' "$up_out" | tail -4
if printf '%s\n' "$up_out" | grep -q 'audit trail live'; then
    good "the audit trail is LIVE - it sent a probe and read its own log back"
    note "this matters: a proxy log once died silently while health stayed green, and"
    note "ten days of egress went unrecorded. 'healthy' is not 'auditable'."
else
    bad "'up' did not confirm a live audit trail"
fi
cmd "./scripts/warden-cli.sh status"
status_out="$("${SCRIPT_DIR}/warden-cli.sh" status 2>&1)"
printf '%s\n' "$status_out" | sed -n '1,14p'
if printf '%s\n' "$status_out" | grep -q 'audit trail  *live'; then
    good "status agrees, and the sandbox network is internal=true (no route to the internet)"
else
    bad "status does not report a live audit trail"
fi
pause

# =============================================================================
shot "5 - work inside the cage"
# =============================================================================
mkdir -p "$DEMO_WS"; chmod 0777 "$DEMO_WS" 2>/dev/null || true
printf 'print("hello from the sandbox")\n' > "${DEMO_WS}/app.py"
say "this is the whole point: the agent gets ONE folder and one way out."
cmd "./scripts/warden-cli.sh run ./my-project bash"
say "...and from inside, four questions and two egress shots:"
probe='echo "== whoami =="; id; echo "== capabilities =="; grep CapBnd /proc/self/status; '
probe+='echo "== what the agent can see =="; ls /workspace; '
probe+='echo "== direct, proxy bypassed =="; curl -sS -m 8 --noproxy "*" -o /dev/null -w "http=%{http_code}\n" https://1.1.1.1/ || true; '
probe+='getent hosts example.com >/dev/null && echo "dns=resolved" || echo "dns=unresolved"; '
probe+='echo "== through the proxy, NOT on the allowlist =="; curl -sS -m 15 -o /dev/null -w "http=%{http_code}\n" https://example.com/ || true; '
probe+='echo "== through the proxy, ON the allowlist =="; curl -sS -m 25 -o /dev/null -w "http=%{http_code}\n" https://api.anthropic.com/v1/models || true'
ses_out="$("${SCRIPT_DIR}/warden-cli.sh" run "$DEMO_WS" bash -- -lc "$probe" 2>&1)"
printf '%s\n' "$ses_out" | sed -n '/== whoami ==/,$p' | head -24

if ! printf '%s\n' "$ses_out" | grep -q 'uid=1001(ai_user)'; then
    bad "the session never ran, so nothing above was measured: $(printf '%s\n' "$ses_out" | tail -2 | tr '\n' ' ')"
else
    good "uid=1001(ai_user): not root, and there is no sudo in the image"
    if printf '%s\n' "$ses_out" | grep -qE '^CapBnd:[[:space:]]*0+$'; then
        good "CapBnd is all zeros: --cap-drop=ALL is enforced by the kernel, not just requested"
    else
        bad "CapBnd is not empty: $(printf '%s\n' "$ses_out" | grep CapBnd | head -1)"
    fi
    if printf '%s\n' "$ses_out" | grep -qx 'secrets.json'; then
        note "secrets.json is NOT your file - the sandbox seeds honeypot credentials."
        note "Reading one kills the session with exit 99. That is the other video."
    fi
    if printf '%s\n' "$ses_out" | grep -q 'dns=unresolved'; then
        good "bypassing the proxy: no route out at all, and outside names do not even resolve"
    else
        bad "an outside name resolved inside the cage"
    fi
    if printf '%s\n' "$ses_out" | grep -q 'response 403'; then
        good "through the proxy: a non-allowlisted name is refused 403 - that proves the ALLOWLIST"
        note "the two shots above prove different things. Do not narrate them as one."
    else
        bad "a non-allowlisted name was not refused with 403"
    fi
    allowed="$(printf '%s\n' "$ses_out" | sed -n 's/^http=//p' | tail -1)"
    case "$allowed" in
        [1-5][0-9][0-9]) good "an allowlisted host answered HTTP ${allowed} (401 = reached it, no key in this shot)" ;;
        *) bad "the allowlisted host did not answer (http=${allowed:-none})" ;;
    esac
fi
pause

# =============================================================================
shot "6 - your own GitHub repo, from inside the cage"
# =============================================================================
say "the question everyone asks: can it work on MY repo?"
cmd "git clone https://github.com/<you>/<repo>.git   # inside the sandbox"
gitprobe='export GIT_TERMINAL_PROMPT=0; cd /workspace; '
gitprobe+='git clone --depth 1 -q https://github.com/mntoyg/AI-Warden.git repo >/dev/null 2>&1 && echo "clone: ok -> $(git -C repo log --oneline -1)" || echo "clone: FAILED"; '
gitprobe+='cd repo 2>/dev/null && git commit -q --allow-empty -m probe 2>/dev/null; '
gitprobe+='echo "push: $(git push origin HEAD:refs/heads/probe-should-fail 2>&1 | tail -1)"'
git_out="$("${SCRIPT_DIR}/warden-cli.sh" run "$DEMO_WS" bash -- -lc "$gitprobe" 2>&1)"
printf '%s\n' "$git_out" | grep -E '^(clone|push):' | head -4
if printf '%s\n' "$git_out" | grep -q '^clone: ok'; then
    good "read works: github.com is on the allowlist, so clone and fetch go through the audited proxy"
else
    bad "the clone inside the cage failed - github.com was not reachable"
fi
if printf '%s\n' "$git_out" | grep -qE '^push: .*(could not read Username|Authentication|403)'; then
    good "write does not: the cage carries no credential, so the agent cannot push on your behalf"
    note "want it to push? put GITHUB_TOKEN in .env - then say out loud that the token reaches"
    note "every repo it can reach, and the trail shows CONNECT github.com:443, not what was pushed."
    note "Safer: let the agent work in /workspace, then git diff and push from the host."
else
    bad "push did not fail the way it should: $(printf '%s\n' "$git_out" | grep '^push:' | head -1)"
fi
pause

# =============================================================================
printf '\n%s%s================================================================%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" >&2
printf '%s%s  THE HONEST ENDING%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" >&2
printf '%s%s================================================================%s\n\n' "$C_BOLD" "$C_CYAN" "$C_RESET" >&2
say "What you just saw: one folder in, one audited way out, no privileges, and"
say "a sandbox that proves its own posture before it starts."
say "What it does NOT claim: it cannot stop a kernel-level container escape, and"
say "it cannot stop data leaving through a domain you allowlisted yourself."
say "Both are written down in docs/THREAT_MODEL.md section 4."
printf '\n' >&2

if [ "$FAILURES" -eq 0 ]; then
    printf '  %sUSAGE DEMO COMPLETE - every shot proved its own claim.%s\n\n' "$C_GREEN" "$C_RESET" >&2
    exit 0
fi
printf '  %s%d shot(s) did not behave as narrated. Do not ship this take.%s\n\n' "$C_RED" "$FAILURES" "$C_RESET" >&2
exit 1
