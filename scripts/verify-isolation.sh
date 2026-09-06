#!/usr/bin/env bash
# =============================================================================
#  AI Warden - Isolation Verification Suite (host driver)
# -----------------------------------------------------------------------------
#  Proves the sandbox actually does what the README claims. Three phases:
#
#    A. In-sandbox self-test  - privilege containment, host isolation, egress
#                               filtering and canary arming, asserted from the
#                               agent's own point of view.
#    B. Live breach drill     - a container deliberately reads a canary and must
#                               die with exit code 99.
#    C. Fail-closed drill     - a container launched WITHOUT --cap-drop=ALL must
#                               refuse to start (exit code 78).
#
#  Usage:  ./scripts/verify-isolation.sh [--keep] [--no-breach]
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

readonly AGENT_IMAGE="ai-warden/agent:latest"
readonly INTERNAL_NET="warden_internal"

KEEP=0
RUN_BREACH=1
for arg in "$@"; do
    case "$arg" in
        --keep)       KEEP=1 ;;
        --no-breach)  RUN_BREACH=0 ;;
        -h|--help)    sed -n '2,17p' "$0"; exit 0 ;;
        *)            printf 'unknown option: %s\n' "$arg" >&2; exit 64 ;;
    esac
done

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""
fi

info() { printf '%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*" >&2; }
good() { printf '  %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
bad()  { printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$*"; }
note() { printf '  %s%s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }

PHASE_FAILURES=0

host_path() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) command -v cygpath >/dev/null 2>&1 && cygpath -w "$1" || printf '%s' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

command -v docker >/dev/null 2>&1 || { bad "docker not found"; exit 1; }
docker info >/dev/null 2>&1     || { bad "docker daemon not reachable"; exit 1; }
docker image inspect "$AGENT_IMAGE" >/dev/null 2>&1 || {
    bad "${AGENT_IMAGE} not built. Run: ./scripts/warden-cli.sh build"
    exit 1
}

info "ensuring the egress filter is up"
"${SCRIPT_DIR}/warden-cli.sh" up >/dev/null || { bad "could not start the egress proxy"; exit 1; }

# --- disposable workspace ----------------------------------------------------
VERIFY_WS="${PROJECT_ROOT}/workspaces/.verify-$$"
mkdir -p "$VERIFY_WS"
cp "${SCRIPT_DIR}/selftest-in-container.sh" "${VERIFY_WS}/.warden-selftest.sh"
chmod +x "${VERIFY_WS}/.warden-selftest.sh" 2>/dev/null || true
VERIFY_WS_MOUNT="$(host_path "$VERIFY_WS")"

VERIFY_VAULT="warden-verify-vault-$$"
docker volume create --label ai.warden.role=canary-vault "$VERIFY_VAULT" >/dev/null
docker run --rm --network none --user 0:0 --cap-drop=ALL --cap-add=CHOWN \
    --entrypoint sh -v "${VERIFY_VAULT}:/vault" "$AGENT_IMAGE" \
    -c "chmod 0770 /vault && chown -R 1001:1001 /vault" >/dev/null

cleanup() {
    docker rm -f warden-verify-selftest warden-verify-breach warden-verify-failclosed >/dev/null 2>&1 || true
    docker volume rm -f "$VERIFY_VAULT" >/dev/null 2>&1 || true
    if [ "$KEEP" = "0" ]; then
        rm -rf "$VERIFY_WS" 2>/dev/null || true
    else
        note "workspace kept at ${VERIFY_WS}"
    fi
}
trap cleanup EXIT

# The exact hardened flag set. Anything the sandbox is allowed to do, it is
# allowed to do under these flags and no others.
warden_flags=(
    --rm
    --network "$INTERNAL_NET"
    --user 1001:1001
    --workdir /workspace
    --cap-drop=ALL
    --security-opt no-new-privileges:true
    --memory 2g --memory-swap 2g
    --pids-limit 256
    --tmpfs "/run/warden:rw,nosuid,size=16m,uid=1001,gid=1001"
    -v "${VERIFY_VAULT}:/workspace/.secrets"
    -v "${VERIFY_WS_MOUNT}:/workspace"
)

# =============================================================================
printf '\n%s================= PHASE A: in-sandbox self-test =================%s\n' "$C_BOLD" "$C_RESET"
# =============================================================================
docker run "${warden_flags[@]}" --name warden-verify-selftest "$AGENT_IMAGE" \
    bash /workspace/.warden-selftest.sh
phase_a=$?

if [ "$phase_a" -eq 0 ]; then
    good "phase A: every isolation assertion held"
else
    bad "phase A: at least one assertion failed (exit ${phase_a})"
    PHASE_FAILURES=$((PHASE_FAILURES + 1))
fi

# =============================================================================
if [ "$RUN_BREACH" = "1" ]; then
printf '\n%s================= PHASE B: live breach drill ====================%s\n' "$C_BOLD" "$C_RESET"
info "a container will now deliberately read /workspace/.secrets/credentials"
info "expected outcome: the tripwire kills it and the container exits 99"
printf '\n'

BREACH_WS="${PROJECT_ROOT}/workspaces/.verify-breach-$$"
mkdir -p "$BREACH_WS"
BREACH_WS_MOUNT="$(host_path "$BREACH_WS")"

docker run --rm \
    --network "$INTERNAL_NET" \
    --user 1001:1001 --workdir /workspace \
    --cap-drop=ALL --security-opt no-new-privileges:true \
    --memory 1g --pids-limit 128 \
    --tmpfs "/run/warden:rw,nosuid,size=16m,uid=1001,gid=1001" \
    -v "${VERIFY_VAULT}:/workspace/.secrets" \
    -v "${BREACH_WS_MOUNT}:/workspace" \
    --name warden-verify-breach \
    "$AGENT_IMAGE" \
    bash -c 'echo "[attacker] exfiltrating credentials..."; cat /workspace/.secrets/credentials > /dev/null 2>&1; sleep 20; echo "[attacker] still alive - THE TRIPWIRE FAILED"'
phase_b=$?

printf '\n'
if [ "$phase_b" -eq 99 ]; then
    good "phase B: canary trip terminated the sandbox with exit 99"
    if [ -f "${BREACH_WS}/WARDEN_SECURITY_INCIDENT.json" ]; then
        good "phase B: forensic incident report written to the workspace"
    else
        note "phase B: no incident report file (bind-mount write may be restricted on this host)"
    fi
else
    bad "phase B: expected exit 99, got ${phase_b} - the canary tripwire did NOT contain the breach"
    PHASE_FAILURES=$((PHASE_FAILURES + 1))
fi
rmdir "${BREACH_WS}/.secrets" 2>/dev/null || true
rm -rf "$BREACH_WS" 2>/dev/null || true
fi

# =============================================================================
printf '\n%s================= PHASE C: fail-closed drill ====================%s\n' "$C_BOLD" "$C_RESET"
info "launching WITHOUT --cap-drop=ALL and WITHOUT no-new-privileges"
info "expected outcome: the entrypoint refuses to start (exit 78)"
printf '\n'

docker run --rm \
    --network "$INTERNAL_NET" \
    --user 1001:1001 --workdir /workspace \
    --memory 1g --pids-limit 128 \
    -v "${VERIFY_WS_MOUNT}:/workspace" \
    --name warden-verify-failclosed \
    "$AGENT_IMAGE" \
    bash -c 'echo "this must never run"'
phase_c=$?

printf '\n'
if [ "$phase_c" -eq 78 ]; then
    good "phase C: the sandbox refused an unsafe launch posture"
else
    bad "phase C: expected exit 78, got ${phase_c} - the posture check is not fail-closed"
    PHASE_FAILURES=$((PHASE_FAILURES + 1))
fi

# =============================================================================
printf '\n%s=========================== RESULT ==============================%s\n' "$C_BOLD" "$C_RESET"
if [ "$PHASE_FAILURES" -eq 0 ]; then
    printf '  %sAll phases passed. The sandbox is holding.%s\n\n' "$C_GREEN" "$C_RESET"
    exit 0
fi
printf '  %s%d phase(s) failed. Do NOT run an untrusted agent until this is fixed.%s\n\n' \
    "$C_RED" "$PHASE_FAILURES" "$C_RESET"
exit 1
