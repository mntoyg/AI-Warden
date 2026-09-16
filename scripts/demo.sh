#!/usr/bin/env bash
# =============================================================================
#  AI Warden - scripted demo (the on-camera walkthrough)
# -----------------------------------------------------------------------------
#  Runs the real product the way a user runs it: ./scripts/warden-cli.sh run.
#  Not a simulation - every line of output below comes from the live sandbox.
#
#  Four acts, each with a banner and a pause so it reads on video:
#
#    1. Perimeter      - the egress filter and the two networks, from the host.
#    2. Inside the cage - uid 1001, CapBnd=0, no host filesystem, no direct
#                        egress, allowlist allow vs deny - asserted by the
#                        agent itself, from inside the sandbox.
#    3. The tripwire    - the agent reads a honeypot credential file. The
#                        sandbox dies with exit 99 and leaves exactly ONE clean
#                        incident report.
#    4. Hand-over       - the same command with a real agent, for the live part
#                        of the recording.
#
#  This script FAILS LOUDLY if the story does not actually happen: a demo that
#  narrates "breach contained" while nothing was contained is the exact bug
#  class this project exists to catch (see .ai/HANDOFF.md, "the recurring bug
#  shape"). Every act asserts its own claim and the exit code is the verdict.
#
#  Usage:
#    ./scripts/demo.sh                 # on camera: pauses between acts
#    ./scripts/demo.sh --auto          # rehearsal: no pauses, no TTY needed
#    ./scripts/demo.sh --agent claude  # act 4 hands over to claude (needs a key)
#    ./scripts/demo.sh --keep          # keep the demo workspace afterwards
#
#  Exit: 0 = the whole story played out and every claim was verified.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT

# Git Bash rewrites container-side paths like /workspace into Windows paths.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

readonly CLI="${SCRIPT_DIR}/warden-cli.sh"
readonly AGENT_IMAGE="ai-warden/agent:latest"
readonly DEMO_WS="${PROJECT_ROOT}/workspaces/demo"
readonly REPORT="${DEMO_WS}/WARDEN_SECURITY_INCIDENT.json"

AUTO=0
KEEP=0
HANDOVER_AGENT=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --auto)    AUTO=1 ;;
        --keep)    KEEP=1 ;;
        --agent)   shift; HANDOVER_AGENT="${1:-}" ;;
        --agent=*) HANDOVER_AGENT="${1#--agent=}" ;;
        -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
        *)         printf 'unknown option: %s\n' "$1" >&2; exit 64 ;;
    esac
    shift
done

# A demo left waiting on Enter in a pipeline looks like a hang, so drop the
# pauses whenever there is no terminal to press it on.
if [ ! -t 0 ]; then AUTO=1; fi

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

FAILURES=0

act() {
    printf '\n%s%s================================================================%s\n' \
        "$C_BOLD" "$C_CYAN" "$C_RESET" >&2
    printf '%s%s  ACT %s%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET" >&2
    printf '%s%s================================================================%s\n\n' \
        "$C_BOLD" "$C_CYAN" "$C_RESET" >&2
}
say()  { printf '%s>>%s %s\n' "$C_BOLD" "$C_RESET" "$*" >&2; }
cmd()  { printf '\n%s   $ %s%s\n\n' "$C_DIM" "$*" "$C_RESET" >&2; }
good() { printf '  %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
bad()  { printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; FAILURES=$((FAILURES + 1)); }
note() { printf '  %s%s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }

pause() {
    if [ "$AUTO" = "1" ]; then
        return 0
    fi
    printf '\n%s   [ Enter to continue ]%s ' "$C_DIM" "$C_RESET" >&2
    read -r _ </dev/tty 2>/dev/null || true
    printf '\n' >&2
}

# =============================================================================
#  ACT 0 - pre-flight. Everything that would derail the recording, checked
#          before the camera is rolling.
# =============================================================================
preflight() {
    act "0 - pre-flight"

    if ! command -v docker >/dev/null 2>&1; then
        bad "docker not found on PATH"; return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        bad "the Docker daemon is not reachable - start Docker Desktop first"; return 1
    fi
    good "Docker daemon reachable"

    if ! docker image inspect "$AGENT_IMAGE" >/dev/null 2>&1; then
        bad "${AGENT_IMAGE} is missing - run: ./scripts/warden-cli.sh build"; return 1
    fi
    good "agent image ${AGENT_IMAGE} present"

    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        good "ANTHROPIC_API_KEY is exported (act 4 can run a real agent)"
    else
        note "no ANTHROPIC_API_KEY exported - acts 1-3 are unaffected;"
        note "act 4 will print the command instead of launching a real agent."
    fi

    # A believable workspace: the demo should look like somebody's project, not
    # like a test fixture.
    mkdir -p "${DEMO_WS}/src" || { bad "cannot create ${DEMO_WS}"; return 1; }
    cat > "${DEMO_WS}/README.md" <<'MD'
# invoice-service

A small internal service. Handed to an AI coding agent to refactor.
MD
    cat > "${DEMO_WS}/src/app.py" <<'PY'
def total(items):
    return sum(i["price"] * i["qty"] for i in items)
PY

    # Start from a clean slate so the report shown in act 3 is unmistakably
    # produced by this run and not left over from a rehearsal.
    rm -f "${DEMO_WS}"/WARDEN_SECURITY_INCIDENT*.json 2>/dev/null || true
    good "demo workspace ready: ${DEMO_WS}"

    write_proof_script || return 1
    good "in-sandbox proof script written (shown on camera before it runs)"
    return 0
}

# The proofs run INSIDE the sandbox, as the agent, with the agent's privileges.
# It lives in the workspace so it can be displayed before it is executed - the
# audience sees there is no sleight of hand.
write_proof_script() {
    mkdir -p "${DEMO_WS}/.demo" || return 1
    cat > "${DEMO_WS}/.demo/proofs.sh" <<'PROOFS'
#!/usr/bin/env bash
# Runs inside the sandbox, as the agent. Every check must hold or this exits 1.
set -uo pipefail
fails=0
p() { printf '  PASS %s\n' "$*"; }
f() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

printf '\n--- 1. who am i -------------------------------------------------\n'
id
if [ "$(id -u)" = "1001" ] && [ "$(id -un)" = "ai_user" ]; then
    p "unprivileged: uid 1001 (ai_user), not root"
else
    f "expected uid 1001/ai_user, got $(id -u)/$(id -un)"
fi

printf '\n--- 2. capabilities --------------------------------------------\n'
grep -E '^(CapBnd|CapEff|NoNewPrivs)' /proc/self/status
capbnd="$(awk '/^CapBnd/{print $2}' /proc/self/status)"
if [ "${capbnd//0/}" = "" ]; then
    p "capability bounding set is empty - mount, ptrace, net_admin are unreachable"
else
    f "CapBnd is ${capbnd}, expected all zeroes"
fi
if [ "$(awk '/^NoNewPrivs/{print $2}' /proc/self/status)" = "1" ]; then
    p "no_new_privs is set - setuid and file capabilities cannot raise privilege"
else
    f "no_new_privs is not set"
fi
if sudo -n true 2>/dev/null; then
    f "sudo works inside the sandbox"
else
    p "no sudo, no escalation path"
fi

printf '\n--- 3. the host is not here ------------------------------------\n'
printf 'hostname: %s\n' "$(cat /etc/hostname)"
printf '/workspace: %s\n' "$(ls -A /workspace | tr '\n' ' ')"
host_leak=0
for h in /host /hostfs /mnt/c /mnt/d /c /d /var/run/docker.sock; do
    if [ -e "$h" ]; then f "host path visible: ${h}"; host_leak=1; fi
done
if [ "$host_leak" = "0" ]; then
    p "no host filesystem and no docker socket - only /workspace is shared"
fi
# Probe for REAL host credentials only. Several canary honeypots are seeded at
# credential-shaped paths ($HOME/.aws/credentials, $HOME/.ssh/id_rsa_backup),
# and touching one here would trip the tripwire in the middle of act 2 - so any
# path the warden itself seeded is skipped by name, derived from the live
# WARDEN_CANARY_FILES rather than hardcoded, and `[ -f ]` never opens a file.
key_leak=0
canary_list=":${WARDEN_CANARY_FILES:-}:"
for k in /root/.ssh/id_rsa /root/.aws/credentials \
         "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ed25519" "$HOME/.aws/config"; do
    case "$canary_list" in
        *":${k}:"*) continue ;;   # a warden honeypot, not a host secret
    esac
    if [ -f "$k" ]; then f "host credential present at ${k}"; key_leak=1; fi
done
if [ "$key_leak" = "0" ]; then p "no host SSH or cloud credentials reachable"; fi

printf '\n--- 4. there is no way out except the proxy --------------------\n'
leaks=0
for probe in "1.1.1.1 443" "8.8.8.8 53" "142.250.185.78 80"; do
    # shellcheck disable=SC2086
    if nc -z -w 3 $probe 2>/dev/null; then f "direct egress reached ${probe// /:}"; leaks=1; fi
done
if [ "$leaks" = "0" ]; then
    p "no direct TCP egress at all - the sandbox network is internal:true"
fi

code() {
    curl --silent --show-error --output /dev/null --max-time 20 \
         --write-out '%{http_code}' "$@" 2>/dev/null || printf '000'
}

printf '\n--- 5. the allowlist has teeth in both directions -------------\n'
allowed="$(code https://api.anthropic.com/v1/models)"
printf 'GET https://api.anthropic.com/v1/models  -> HTTP %s\n' "$allowed"
case "$allowed" in
    000) printf '  SKIP api.anthropic.com unreachable (no internet on this host?)\n' ;;
    *)   p "allowlisted api.anthropic.com tunnels through the proxy (HTTP ${allowed})" ;;
esac

denied="$(code http://example.com/)"
printf 'GET http://example.com/                  -> HTTP %s\n' "$denied"
if [ "$denied" = "403" ]; then
    p "non-allowlisted example.com refused by the proxy with 403"
elif [ "$denied" = "000" ]; then
    p "non-allowlisted example.com got no response at all"
else
    f "example.com was NOT blocked (HTTP ${denied})"
fi

if curl --silent --output /dev/null --max-time 15 https://example.com/ 2>/dev/null; then
    f "CONNECT to non-allowlisted example.com:443 succeeded"
else
    p "CONNECT to non-allowlisted example.com:443 refused - no TLS escape hatch"
fi
if curl --silent --output /dev/null --max-time 15 https://1.1.1.1/ 2>/dev/null; then
    f "an IP literal bypassed the allowlist"
else
    p "IP-literal destinations are refused too (no allowlist bypass by address)"
fi

printf '\n--- 6. the tripwire is armed, and says so honestly ------------\n'
armed="$(cat /run/warden/armed 2>/dev/null || echo 0)"
printf 'canary paths genuinely enforced: %s\n' "$armed"
if [ "${armed:-0}" -gt 0 ]; then
    p "${armed} canary path(s) probed and proven enforceable on this platform"
else
    f "no canary path is enforced - the tripwire would be decoration"
fi

printf '\n----------------------------------------------------------------\n'
if [ "$fails" -eq 0 ]; then
    printf 'in-sandbox proofs: ALL PASS\n'
    exit 0
fi
printf 'in-sandbox proofs: %s FAILED\n' "$fails"
exit 1
PROOFS
    chmod +x "${DEMO_WS}/.demo/proofs.sh" 2>/dev/null || true
    return 0
}

# =============================================================================
#  ACT 1 - the perimeter, seen from the host.
# =============================================================================
act_perimeter() {
    act "1 - the perimeter"
    say "One process is allowed out of the sandbox network, and it is not the agent."
    cmd "./scripts/warden-cli.sh up && ./scripts/warden-cli.sh status"

    "$CLI" up >/dev/null 2>&1
    "$CLI" status || true

    if docker network inspect warden_internal \
        --format '{{if .Internal}}internal{{else}}routable{{end}}' 2>/dev/null \
        | grep -q internal; then
        good "warden_internal is internal:true - Docker gives it no route to the internet"
    else
        bad "warden_internal is routable - the whole egress story is void"
    fi

    local rules
    rules="$(grep -cvE '^\s*(#|$)' "${PROJECT_ROOT}/core/network/whitelist_domains.txt" 2>/dev/null || echo 0)"
    good "egress allowlist: ${rules} rule(s), default deny for everything else"
    pause
}

# =============================================================================
#  ACT 2 - the same claims, asserted from inside by the agent itself.
# =============================================================================
act_inside() {
    act "2 - inside the cage"
    say "Now the agent audits its own prison. This is the script it will run:"
    cmd "cat workspaces/demo/.demo/proofs.sh   # (abridged on screen)"
    sed -n '1,4p' "${DEMO_WS}/.demo/proofs.sh" >&2
    printf '  %s...%s\n' "$C_DIM" "$C_RESET" >&2
    pause

    say "Launch it the way a user launches an agent - no special flags:"
    cmd "./scripts/warden-cli.sh run workspaces/demo bash -- /workspace/.demo/proofs.sh"

    local rc=0
    "$CLI" run "$DEMO_WS" bash -- /workspace/.demo/proofs.sh || rc=$?

    if [ "$rc" -eq 0 ]; then
        good "every in-sandbox proof passed, and the session ended cleanly (exit 0)"
    else
        bad "the in-sandbox proofs exited ${rc} - read the output above before recording"
    fi
    pause
}

# =============================================================================
#  ACT 3 - the live breach. The money shot.
# =============================================================================
act_breach() {
    act "3 - the tripwire"
    say "The workspace contains honeypot credentials the agent was never told about."
    say "A compromised agent - prompt injection, a poisoned dependency - reads them."
    say "Watch the exit code and the incident report."
    cmd "./scripts/warden-cli.sh run workspaces/demo bash -- -c '<read the honeypot, then keep running>'"
    pause

    # The reader opens the canary and stays alive, which is what an exfiltrating
    # agent does: read, then send. It also keeps the reader in /proc while the
    # monitors attribute the breach. A short-lived `cat` is contained exactly the
    # same way (exit 99) but cannot be attributed; the report then says
    # "attribution": "unavailable" rather than implying nobody read it.
    local rc=0
    "$CLI" run "$DEMO_WS" bash -- -c \
        'exec 3< /workspace/.secrets/credentials; cat <&3; echo; echo "[agent] got the keys, now exfiltrating..."; sleep 25' \
        || rc=$?

    if [ "$rc" -eq 99 ]; then
        good "exit code 99 - the sandbox was terminated by the canary tripwire"
    else
        bad "expected exit 99, got ${rc} - the tripwire did NOT contain the breach"
    fi

    # The demo must not narrate a containment that produced no evidence.
    if [ -f "$REPORT" ]; then
        good "incident report written: WARDEN_SECURITY_INCIDENT.json"
    else
        bad "no incident report at ${REPORT}"
        pause
        return
    fi

    say "The forensic record, on the host, outside the sandbox:"
    cmd "cat workspaces/demo/WARDEN_SECURITY_INCIDENT.json"
    if command -v python >/dev/null 2>&1; then
        python -m json.tool "$REPORT" 2>/dev/null || cat "$REPORT"
    else
        cat "$REPORT"
    fi
    printf '\n' >&2

    # --- the report itself is a control, so check it for the failure modes
    #     that made it lie before (v1.0.3): a false tamper alarm, and a
    #     duplicate fallback report from the monitor/sentinel write race.
    local extra
    extra="$(find "$DEMO_WS" -maxdepth 1 -name 'WARDEN_SECURITY_INCIDENT.*.json' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$extra" = "0" ]; then
        good "exactly one report - no duplicate fallback from the monitor/sentinel race"
    else
        bad "${extra} extra fallback report(s) - the v1.0.3 write race is back"
    fi
    if grep -q 'report_path_tampered' "$REPORT" 2>/dev/null; then
        bad "the report cries tampering on a benign run - false alarm (v1.0.3 regression)"
    else
        good "no false tamper alarm - the report says only what happened"
    fi
    if grep -q '"canary_path"' "$REPORT" && grep -q '"suspects"' "$REPORT"; then
        good "the report names which canary was read, and when"
    else
        bad "the report is missing canary_path or suspects"
    fi
    # An incident report that contains no attribution at all is the weakest
    # possible forensic outcome, and on this platform it is the sentinel (which
    # holds no CAP_SYS_PTRACE) that wins the write race. Assert attribution
    # rather than assume it: a silent "suspects": [] must not pass as a success.
    if grep -q '"cmdline"' "$REPORT"; then
        good "the report attributes the breach to a process (pid, uid, cmdline)"
    else
        bad "\"suspects\" is empty - the report contains no attribution at all"
    fi
    # Since v1.0.4 the report also states how far that list can be trusted. The
    # sentinel cannot read another uid's /proc/<pid>/fd or exe, so its honest
    # verdict is "restricted"; a report with no verdict leaves a partial list
    # looking like the whole picture.
    local attr
    attr="$(sed -n 's/^ *"attribution": "\([a-z]*\)".*/\1/p' "$REPORT" | head -1)"
    case "$attr" in
        complete)
            good "attribution: complete - the writing monitor could inspect every process" ;;
        restricted)
            good "attribution: restricted - the sentinel states what it could NOT see (CAP_KILL only, by design)" ;;
        *)
            bad "the report carries no usable attribution verdict ('${attr:-missing}')" ;;
    esac

    say "Nothing about the host was risked: the honeypot keys are synthetic,"
    say "and the container that read them no longer exists."
    pause
}

# =============================================================================
#  ACT 4 - hand over to a real agent for the live part of the recording.
# =============================================================================
act_handover() {
    act "4 - a real agent, live"

    if [ -z "$HANDOVER_AGENT" ]; then
        say "Run the real thing with:"
        cmd "./scripts/warden-cli.sh run ./workspaces/demo claude"
        note "in that session, ask the agent to do real work, then ask it to"
        note "read /workspace/.secrets/credentials - it dies the same way."
        return
    fi
    if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ "$HANDOVER_AGENT" = "claude" ]; then
        note "no ANTHROPIC_API_KEY exported - skipping the live hand-over."
        note "export it and re-run: ./scripts/demo.sh --agent claude"
        return
    fi
    if [ "$AUTO" = "1" ]; then
        note "--auto: skipping the interactive hand-over to ${HANDOVER_AGENT}."
        return
    fi

    say "Handing the terminal to ${HANDOVER_AGENT}, inside the sandbox."
    cmd "./scripts/warden-cli.sh run ./workspaces/demo ${HANDOVER_AGENT}"
    pause
    "$CLI" run "$DEMO_WS" "$HANDOVER_AGENT" || true
}

# =============================================================================
#  MAIN
# =============================================================================
printf '\n%sAI Warden - live demo%s  (%s)\n' "$C_BOLD" "$C_RESET" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >&2
printf '%severy claim below is produced by the running system, not by this script%s\n' \
    "$C_DIM" "$C_RESET" >&2

if ! preflight; then
    printf '\n%s%s  PRE-FLIGHT FAILED - do not start recording.%s\n\n' \
        "$C_BOLD" "$C_RED" "$C_RESET" >&2
    exit 1
fi
pause

act_perimeter
act_inside
act_breach
act_handover

printf '\n%s%s================================================================%s\n' \
    "$C_BOLD" "$C_CYAN" "$C_RESET" >&2
if [ "$FAILURES" -eq 0 ]; then
    printf '%s%s  DEMO COMPLETE - %s%s\n' "$C_BOLD" "$C_GREEN" \
        "every act verified its own claim" "$C_RESET" >&2
else
    printf '%s%s  DEMO FINISHED WITH %s UNVERIFIED CLAIM(S) - fix before recording.%s\n' \
        "$C_BOLD" "$C_RED" "$FAILURES" "$C_RESET" >&2
fi
printf '%s%s================================================================%s\n\n' \
    "$C_BOLD" "$C_CYAN" "$C_RESET" >&2

if [ "$KEEP" = "0" ]; then
    rm -rf "${DEMO_WS}/.demo" 2>/dev/null || true
fi

if [ "$FAILURES" -eq 0 ]; then exit 0; fi
exit 1
