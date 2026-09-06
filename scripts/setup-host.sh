#!/usr/bin/env bash
# =============================================================================
#  AI Warden - Host Setup and Prerequisite Check
# -----------------------------------------------------------------------------
#    ./scripts/setup-host.sh            full setup (checks, dirs, .env, networks)
#    ./scripts/setup-host.sh --check    read-only diagnosis, changes nothing
#    ./scripts/setup-host.sh --build    also build both images
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT

MODE="setup"
case "${1:-}" in
    --check) MODE="check" ;;
    --build) MODE="build" ;;
    "")      MODE="setup" ;;
    *)       printf 'usage: %s [--check|--build]\n' "$0" >&2; exit 64 ;;
esac

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""
fi

PASS=0
FAIL=0
WARNCOUNT=0

pass() { PASS=$((PASS + 1)); printf '  %s[ ok ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  %s[fail]%s %s\n' "$C_RED" "$C_RESET" "$*"; }
warn() { WARNCOUNT=$((WARNCOUNT + 1)); printf '  %s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
note() { printf '  %s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

printf '\n%sAI Warden - host setup (%s)%s\n' "$C_BOLD" "$MODE" "$C_RESET"
printf 'project root: %s\n' "$PROJECT_ROOT"

# =============================================================================
# 1. Prerequisites
# =============================================================================
head1 "1. Prerequisites"

if command -v docker >/dev/null 2>&1; then
    pass "docker found: $(docker --version 2>/dev/null | head -1)"
else
    fail "docker not found. Install Docker Engine or Docker Desktop."
fi

if docker info >/dev/null 2>&1; then
    pass "docker daemon reachable"
    server_os="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || echo unknown)"
    note "engine: ${server_os}"
    case "$server_os" in
        *Desktop*|*docker-desktop*)
            note "Docker Desktop detected - bind mounts go through the VM's file sharing layer."
            note "Keep sandboxed projects on a shared drive, or performance and inotify will suffer."
            ;;
    esac
else
    fail "docker daemon is not reachable. Start Docker Desktop / systemctl start docker."
fi

if docker compose version >/dev/null 2>&1; then
    pass "docker compose v2: $(docker compose version --short 2>/dev/null || echo present)"
elif command -v docker-compose >/dev/null 2>&1; then
    warn "only the legacy docker-compose v1 was found; v2 is recommended"
else
    fail "docker compose is required"
fi

if command -v git >/dev/null 2>&1; then
    pass "git found: $(git --version)"
else
    warn "git not found on the host (only needed for your own workflow)"
fi

# Disk space: the agent image is large (Node + Python + toolchain).
if command -v df >/dev/null 2>&1; then
    avail_kb="$(df -Pk "$PROJECT_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [ -n "${avail_kb:-}" ] && [ "$avail_kb" -lt 6000000 ]; then
        warn "less than ~6 GB free on this volume; the agent image needs roughly 3-4 GB"
    else
        pass "sufficient free disk space"
    fi
fi

# =============================================================================
# 2. Host posture
# =============================================================================
head1 "2. Host posture"

if docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q 'rootless'; then
    pass "rootless Docker - the strongest host posture for this workload"
else
    note "rootful Docker. That is fine, but remember: a container escape becomes host root."
    note "Rootless mode (https://docs.docker.com/engine/security/rootless/) removes that step."
fi

if docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q 'seccomp'; then
    pass "seccomp profile active"
else
    warn "seccomp does not appear to be active on this engine"
fi

if docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -qE 'apparmor|selinux'; then
    pass "a mandatory access control system (AppArmor/SELinux) is active"
else
    note "no AppArmor/SELinux reported (normal on Docker Desktop)"
fi

# =============================================================================
# 3. Repository integrity
# =============================================================================
head1 "3. Repository integrity"

required=(
    "core/Dockerfile"
    "core/entrypoint.sh"
    "core/network/squid.conf"
    "core/network/whitelist_domains.txt"
    "core/network/Dockerfile"
    "core/network/proxy-entrypoint.sh"
    "monitors/canary_monitor.py"
    "scripts/warden-cli.sh"
    "devcontainer/devcontainer.json"
    "docker-compose.yml"
)
missing=0
for f in "${required[@]}"; do
    if [ ! -f "${PROJECT_ROOT}/${f}" ]; then
        fail "missing: ${f}"
        missing=$((missing + 1))
    fi
done
if [ "$missing" -eq 0 ]; then
    pass "all ${#required[@]} required files present"
fi

# CRLF line endings silently break every shell script inside the container.
crlf=0
for f in core/entrypoint.sh core/network/proxy-entrypoint.sh scripts/warden-cli.sh scripts/setup-host.sh; do
    if [ -f "${PROJECT_ROOT}/${f}" ] && grep -qU $'\r' "${PROJECT_ROOT}/${f}" 2>/dev/null; then
        fail "${f} has CRLF line endings - run: dos2unix ${f}"
        crlf=$((crlf + 1))
    fi
done
if [ "$crlf" -eq 0 ]; then
    pass "shell scripts use LF line endings"
fi

rules="$(grep -cvE '^[[:space:]]*(#|$)' "${PROJECT_ROOT}/core/network/whitelist_domains.txt" 2>/dev/null || echo 0)"
if [ "$rules" -gt 0 ]; then
    pass "egress allowlist has ${rules} rule(s)"
else
    fail "egress allowlist is empty - the proxy will refuse to start"
fi

if grep -qE '^[[:space:]]*http_access[[:space:]]+deny[[:space:]]+all[[:space:]]*$' \
        "${PROJECT_ROOT}/core/network/squid.conf" 2>/dev/null; then
    pass "squid.conf ends in a default-deny rule"
else
    fail "squid.conf has no 'http_access deny all' - the allowlist is not fail-closed"
fi

if [ "$MODE" = "check" ]; then
    head1 "Summary"
    printf '  %d passed, %d warning(s), %d failure(s)\n\n' "$PASS" "$WARNCOUNT" "$FAIL"
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
fi

# =============================================================================
# 4. Setup actions
# =============================================================================
head1 "4. Setup"

mkdir -p "${PROJECT_ROOT}/workspaces/default"
pass "workspaces/default ready"

chmod +x "${PROJECT_ROOT}"/scripts/*.sh 2>/dev/null || true
chmod +x "${PROJECT_ROOT}/core/entrypoint.sh" "${PROJECT_ROOT}/core/network/proxy-entrypoint.sh" 2>/dev/null || true
pass "scripts marked executable"

if [ ! -f "${PROJECT_ROOT}/.env" ]; then
    cp "${PROJECT_ROOT}/.env.example" "${PROJECT_ROOT}/.env"
    chmod 600 "${PROJECT_ROOT}/.env" 2>/dev/null || true
    pass ".env created from .env.example (mode 600) - add your API keys"
else
    chmod 600 "${PROJECT_ROOT}/.env" 2>/dev/null || true
    pass ".env already exists (mode forced to 600)"
fi

# Networks are intentionally NOT created here. `docker compose up` creates them
# and stamps them with com.docker.compose.network; a network created by hand
# lacks that label and compose then refuses to adopt it.
if docker info >/dev/null 2>&1; then
    for net in warden_internal warden_external; do
        if docker network inspect "$net" >/dev/null 2>&1; then
            label="$(docker network inspect -f '{{index .Labels "com.docker.compose.network"}}' "$net" 2>/dev/null || true)"
            if [ -z "$label" ]; then
                fail "${net} exists but was not created by compose - remove it: docker network rm ${net}"
            elif [ "$net" = "warden_internal" ]                  && [ "$(docker network inspect -f '{{.Internal}}' "$net")" != "true" ]; then
                fail "warden_internal is NOT internal - remove it: docker network rm warden_internal"
            else
                pass "${net} present and correctly labelled"
            fi
        else
            note "${net} will be created by 'make up'"
        fi
    done
fi

if [ "$MODE" = "build" ]; then
    head1 "5. Build"
    "${SCRIPT_DIR}/warden-cli.sh" build
fi

head1 "Summary"
printf '  %d passed, %d warning(s), %d failure(s)\n' "$PASS" "$WARNCOUNT" "$FAIL"
cat <<NEXT

  Next steps
    1. Put your keys in .env            (chmod 600 .env)
    2. Build the images                 ./scripts/warden-cli.sh build
    3. Start the egress filter          ./scripts/warden-cli.sh up
    4. Prove the isolation holds        ./scripts/verify-isolation.sh
    5. Run an agent                     ./scripts/warden-cli.sh run ./my-project claude

NEXT
[ "$FAIL" -eq 0 ] || exit 1
exit 0
