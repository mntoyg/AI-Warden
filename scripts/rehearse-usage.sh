#!/usr/bin/env bash
# =============================================================================
#  AI Warden - usage-video rehearsal (docs/DEMO.md section 0)
# -----------------------------------------------------------------------------
#  Runs the "how to use" path a viewer follows after `git clone` and ASSERTS the
#  lines that are supposed to appear on camera. Run it before recording: red
#  here means the take would have gone wrong, not that the sandbox is broken.
#
#  It does not build (a clean machine pulls ~3-4 GB; do that first) and it does
#  not run the full suite. What it proves: the host is ready, `up` says the
#  audit trail is alive, a session starts and shows the cage, and the two curl
#  shots each say what DEMO.md section 0 claims they say - the direct one has no
#  route out, the proxied one is refused by the allowlist. They prove different
#  things and the narration must not swap them.
#
#  Usage:  ./scripts/rehearse-usage.sh [--keep]
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""
fi
info() { printf '%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*" >&2; }
good() { printf '  %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
bad()  { printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$*"; FAILURES=$((FAILURES + 1)); }
FAILURES=0

REHEARSE_WS="${PROJECT_ROOT}/workspaces/.rehearse-$$"
cleanup() {
    if [ "$KEEP" = "0" ]; then rm -rf "$REHEARSE_WS" 2>/dev/null || true
    else info "workspace kept at ${REHEARSE_WS}"; fi
}
trap cleanup EXIT

# --- shot 1: the host is ready --------------------------------------------
info "shot 1-2: the host Docker Desktop must answer before setup-host.sh runs"
if docker info >/dev/null 2>&1; then
    good "docker daemon reachable ($(docker info --format '{{.ServerVersion}}' 2>/dev/null))"
else
    bad "docker daemon is NOT reachable - start Docker Desktop and wait for 'docker info' (setup-host.sh would exit 1 on camera)"
    printf '\n  %d check(s) failed. Do not record yet.\n\n' "$FAILURES"; exit 1
fi

setup_out="$("${SCRIPT_DIR}/setup-host.sh" 2>&1)"; setup_rc=$?
setup_tally="$(printf '%s\n' "$setup_out" | grep -E '^[[:space:]]+[0-9]+ passed' | tail -1 | sed 's/^[[:space:]]*//')"
if [ "$setup_rc" -eq 0 ]; then
    good "setup-host.sh exits 0 (${setup_tally:-no tally line})"
else
    bad "setup-host.sh exits ${setup_rc} (${setup_tally:-no tally line}): $(printf '%s\n' "$setup_out" | grep -E '\[fail\]' | head -2 | tr '\n' ' ')"
fi

# --- shot 3-4: images present, egress filter up ----------------------------
info "shot 3-4: the images must already be built, and 'up' must prove the audit trail"
if docker image inspect ai-warden/agent:latest >/dev/null 2>&1; then
    good "agent image present (a clean machine needs ./scripts/warden-cli.sh build first, ~3-4 GB)"
else
    bad "ai-warden/agent:latest is missing - run ./scripts/warden-cli.sh build before recording"
fi
up_out="$("${SCRIPT_DIR}/warden-cli.sh" up 2>&1)"
if printf '%s\n' "$up_out" | grep -q 'audit trail live'; then
    good "up: egress proxy healthy and the audit trail answered a fresh probe"
else
    bad "up did not report a live audit trail: $(printf '%s\n' "$up_out" | tail -2 | tr '\n' ' ')"
fi

# --- shot 5: status --------------------------------------------------------
status_out="$("${SCRIPT_DIR}/warden-cli.sh" status 2>&1)"
if printf '%s\n' "$status_out" | grep -q 'audit trail  *live'; then
    good "status: $(printf '%s\n' "$status_out" | grep -E 'AI Warden v' | head -1 | sed 's/^[[:space:]]*//'), allowlist $(printf '%s\n' "$status_out" | grep -oE '[0-9]+ domain rule' | head -1)"
else
    bad "status does not say the audit trail is live - 'up' heals it; re-run before recording"
fi

# --- shot 6: the session on camera ----------------------------------------
info "shot 6: one real session - uid, capabilities, workspace, and the two curl shots"
mkdir -p "$REHEARSE_WS"
chmod 0777 "$REHEARSE_WS" 2>/dev/null || true
printf 'print("hello from the sandbox")\n' > "${REHEARSE_WS}/app.py"
probe='id; grep CapBnd /proc/self/status; ls /workspace; '
probe+='curl -sS -m 8 --noproxy "*" -o /dev/null -w "direct=%{http_code}\n" https://1.1.1.1/ || true; '
probe+='getent hosts example.com >/dev/null && echo "dns=resolved" || echo "dns=unresolved"; '
probe+='curl -sS -m 15 -o /dev/null -w "denied=%{http_code}\n" https://example.com/ || true; '
probe+='curl -sS -m 25 -o /dev/null -w "allowed=%{http_code}\n" https://api.anthropic.com/v1/models || true'
ses_out="$("${SCRIPT_DIR}/warden-cli.sh" run "$REHEARSE_WS" bash -- -lc "$probe" 2>&1)"

# Positive control first: a session that never started would fail every check
# below for the wrong reason, and "nothing happened" must not read as "safe".
if ! printf '%s\n' "$ses_out" | grep -q 'uid=1001(ai_user)'; then
    bad "the session never reached the probe (no uid line) - nothing below was measured: $(printf '%s\n' "$ses_out" | tail -3 | tr '\n' ' ')"
    printf '\n  %d check(s) failed. Do not record yet.\n\n' "$FAILURES"; exit 1
fi
good "session: uid=1001(ai_user), workspace holds $(printf '%s\n' "$ses_out" | grep -c '^app\.py$' >/dev/null 2>&1 && echo 'app.py' || echo 'the mounted project')"

if printf '%s\n' "$ses_out" | grep -qE '^CapBnd:[[:space:]]*0+$'; then
    good "capabilities: CapBnd is empty - --cap-drop=ALL is real, not a flag"
else
    bad "CapBnd is not empty: $(printf '%s\n' "$ses_out" | grep CapBnd | head -1)"
fi

# The canary is seeded by the sandbox, not by the viewer. Say so on camera.
if printf '%s\n' "$ses_out" | grep -qx 'secrets.json'; then
    good "/workspace also shows the seeded canary (secrets.json) - call it a honeytoken, do NOT open it on camera (exit 99)"
else
    bad "no seeded canary in /workspace - the tripwire has nothing to watch in this workspace"
fi

if printf '%s\n' "$ses_out" | grep -qx 'direct=000' && printf '%s\n' "$ses_out" | grep -qx 'dns=unresolved'; then
    good "direct shot: no route out of the cage (curl 000 with the proxy bypassed) and outside names do not resolve"
else
    bad "the direct shot did not behave as DEMO.md section 0 claims: $(printf '%s\n' "$ses_out" | grep -E '^direct=|^dns=' | tr '\n' ' ')"
fi

if printf '%s\n' "$ses_out" | grep -qx 'denied=000' && printf '%s\n' "$ses_out" | grep -q 'response 403'; then
    good "proxied shot: a non-allowlisted name is refused by squid (403), which proves the ALLOWLIST, not the missing route"
else
    bad "the proxied shot did not show a 403 refusal: $(printf '%s\n' "$ses_out" | grep -E '^denied=|403' | head -2 | tr '\n' ' ')"
fi

allowed="$(printf '%s\n' "$ses_out" | sed -n 's/^allowed=//p' | tail -1)"
case "$allowed" in
    [1-5][0-9][0-9]) good "allowlisted shot: api.anthropic.com answered HTTP ${allowed} through the proxy (401 = reached it, no key)" ;;
    *) bad "an allowlisted host did not answer through the proxy (allowed=${allowed:-none})" ;;
esac

if printf '%s\n' "$ses_out" | grep -q 'session ended cleanly'; then
    good "the session closed with 'session ended cleanly' - the closing shot"
else
    bad "the session did not report a clean end"
fi

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
    printf '  %sEvery shot in DEMO.md section 0 behaved as written. Ready to record.%s\n\n' "$C_GREEN" "$C_RESET"
    exit 0
fi
printf '  %s%d check(s) failed. Fix them before recording.%s\n\n' "$C_RED" "$FAILURES" "$C_RESET"
exit 1
