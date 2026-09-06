#!/usr/bin/env bash
# =============================================================================
#  AI Warden - In-Container Isolation Self-Test
# -----------------------------------------------------------------------------
#  Runs INSIDE the sandbox and proves, from the agent's own point of view, that
#  the four guarantees hold: host isolation, privilege containment, egress
#  filtering, and an armed canary.
#
#  Driven by scripts/verify-isolation.sh - do not run this on a host.
#
#  IMPORTANT: this script never opens a canary file. `test -f` uses stat(2),
#  which produces no inotify event, so the tripwire stays silent. The breach
#  test is deliberately a SEPARATE container run.
# =============================================================================
set -uo pipefail

PASS=0
FAIL=0
SKIP=0

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
grey()  { printf '\033[2m%s\033[0m'  "$1"; }

pass() { PASS=$((PASS + 1)); printf '  [%s] %s\n' "$(green PASS)" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  [%s] %s\n' "$(red FAIL)"  "$1"; [ $# -gt 1 ] && printf '         %s\n' "$2"; return 0; }
skip() { SKIP=$((SKIP + 1)); printf '  [%s] %s\n' "$(grey SKIP)" "$1"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# =============================================================================
section "1. Privilege containment"
# =============================================================================

uid="$(id -u)"
if [ "$uid" = "1001" ]; then
    pass "running as unprivileged ai_user (uid 1001)"
else
    fail "expected uid 1001, got ${uid}"
fi

if [ "$(id -un)" = "ai_user" ]; then
    pass "username is ai_user"
else
    fail "unexpected username: $(id -un)"
fi

capeff="$(awk '/^CapEff:/ {print $2}' /proc/self/status)"
if [ "$capeff" = "0000000000000000" ]; then
    pass "all Linux capabilities dropped (CapEff=${capeff})"
else
    fail "capabilities retained" "CapEff=${capeff} - launch with --cap-drop=ALL"
fi

capbnd="$(awk '/^CapBnd:/ {print $2}' /proc/self/status)"
if [ "$capbnd" = "0000000000000000" ]; then
    pass "capability bounding set is empty (no regain path)"
else
    fail "bounding set not empty" "CapBnd=${capbnd}"
fi

nnp="$(awk '/^NoNewPrivs:/ {print $2}' /proc/self/status)"
if [ "$nnp" = "1" ]; then
    pass "no_new_privs is set (setuid escalation impossible)"
else
    fail "no_new_privs is off" "launch with --security-opt no-new-privileges"
fi

setuid_count="$(find / -xdev -type f -perm -4000 2>/dev/null | wc -l)"
if [ "$setuid_count" -eq 0 ]; then
    pass "no setuid binaries remain in the image"
else
    fail "${setuid_count} setuid binary/binaries present" "$(find / -xdev -type f -perm -4000 2>/dev/null | head -5 | tr '\n' ' ')"
fi

if command -v sudo >/dev/null 2>&1; then
    fail "sudo is installed inside the sandbox"
else
    pass "sudo is not installed"
fi

if echo 'warden' 2>/dev/null > /etc/warden-escape-test; then
    rm -f /etc/warden-escape-test 2>/dev/null || true
    fail "/etc is writable by the agent"
else
    pass "/etc is read-only to the agent"
fi

if echo 'warden' 2>/dev/null > /usr/local/bin/warden-escape-test; then
    rm -f /usr/local/bin/warden-escape-test 2>/dev/null || true
    fail "the agent can overwrite its own CLI binaries in /usr/local/bin"
else
    pass "agent binaries in /usr/local/bin are not writable"
fi

# =============================================================================
section "2. Host isolation"
# =============================================================================

if [ -S /var/run/docker.sock ]; then
    fail "the Docker socket is mounted - this is a complete escape"
else
    pass "no Docker socket inside the sandbox"
fi

for hostish in /host /hostfs /mnt/host /media/host; do
    if [ -e "$hostish" ]; then
        fail "host filesystem mounted at ${hostish}"
    fi
done
pass "no host filesystem bind mount found"

# Only /workspace may be a real bind mount. Docker always injects /etc/hosts,
# /etc/hostname and /etc/resolv.conf; those are expected and harmless. Kernel
# pseudo-filesystems are ignored.
unexpected="$(awk '
    { mp = $2; fs = $3 }
    fs ~ /^(proc|sysfs|tmpfs|devtmpfs|devpts|mqueue|shm|overlay|cgroup|cgroup2|securityfs|pstore|bpf|tracefs|debugfs|configfs|fusectl|hugetlbfs|nsfs|binfmt_misc|autofs|ramfs|rpc_pipefs)$/ { next }
    mp == "/" || mp == "/workspace" { next }
    mp == "/etc/hosts" || mp == "/etc/hostname" || mp == "/etc/resolv.conf" { next }
    { print mp " (" fs ")" }
' /proc/mounts 2>/dev/null | head -10)"
if [ -z "$unexpected" ]; then
    pass "the only project bind mount is /workspace"
else
    fail "unexpected mounts present" "$unexpected"
fi

if [ -d /workspace ]; then
    pass "/workspace is present"
else
    fail "/workspace is missing"
fi

if ls /root >/dev/null 2>&1; then
    fail "/root is readable by the agent"
else
    pass "/root is not accessible"
fi

if [ -r /etc/shadow ]; then
    fail "/etc/shadow is readable"
else
    pass "/etc/shadow is not readable"
fi

# A real host SSH key must never be reachable. (The seeded canary lives at
# ~/.ssh/id_rsa_backup and is deliberately NOT opened here.)
for key in /home/ai_user/.ssh/id_rsa /home/ai_user/.ssh/id_ed25519 /root/.ssh/id_rsa; do
    if [ -f "$key" ]; then
        fail "a private key is present at ${key}"
    fi
done
pass "no host private keys reachable"

# =============================================================================
section "3. Egress filtering"
# =============================================================================

# 3a. There must be NO route to the internet that bypasses the proxy.
leaks=0
for probe in "1.1.1.1 443" "8.8.8.8 53" "9.9.9.9 443" "142.250.185.78 80"; do
    # shellcheck disable=SC2086
    if nc -z -w 3 $probe 2>/dev/null; then
        fail "direct egress leak to ${probe// /:}"
        leaks=$((leaks + 1))
    fi
done
if [ "$leaks" -eq 0 ]; then
    pass "no direct TCP egress (the sandbox network is internal)"
fi

# 3b. External DNS must not be reachable directly either.
if command -v dig >/dev/null 2>&1; then
    if timeout 5 dig +short +tries=1 +time=2 @1.1.1.1 example.com >/dev/null 2>&1; then
        fail "external DNS resolver reachable - DNS tunnelling is possible"
    else
        pass "external DNS resolvers are unreachable"
    fi
else
    skip "dig not available; external DNS check skipped"
fi

# 3c. The proxy must be reachable.
proxy_host="${WARDEN_PROXY_HOST:-warden-egress-proxy}"
proxy_port="${WARDEN_PROXY_PORT:-3128}"
if nc -z -w 5 "$proxy_host" "$proxy_port" 2>/dev/null; then
    pass "egress proxy reachable at ${proxy_host}:${proxy_port}"
    proxy_up=1
else
    fail "egress proxy is unreachable" "start it with: ./scripts/warden-cli.sh up"
    proxy_up=0
fi

http_code() {
    curl --silent --show-error --output /dev/null --max-time 20 \
         --write-out '%{http_code}' "$@" 2>/dev/null || printf '000'
}

if [ "$proxy_up" = "1" ]; then
    # 3d. An allowlisted destination must work. Any real HTTP status proves the
    #     tunnel was established; 401 from Anthropic without a key is a success.
    code="$(http_code https://api.anthropic.com/v1/models)"
    case "$code" in
        000) skip "allowlisted host api.anthropic.com unreachable (no internet on this host?)" ;;
        *)   pass "allowlisted host api.anthropic.com reachable through the proxy (HTTP ${code})" ;;
    esac

    code="$(http_code https://registry.npmjs.org/)"
    case "$code" in
        000) skip "registry.npmjs.org unreachable (no internet on this host?)" ;;
        *)   pass "allowlisted host registry.npmjs.org reachable (HTTP ${code})" ;;
    esac

    # 3e. A non-allowlisted destination must be refused.
    code="$(http_code http://example.com/)"
    if [ "$code" = "403" ]; then
        pass "non-allowlisted http://example.com refused with 403"
    elif [ "$code" = "000" ]; then
        pass "non-allowlisted http://example.com blocked (no response)"
    else
        fail "non-allowlisted host was NOT blocked" "example.com returned HTTP ${code}"
    fi

    if curl --silent --output /dev/null --max-time 15 https://example.com/ 2>/dev/null; then
        fail "CONNECT to a non-allowlisted host succeeded" "example.com:443"
    else
        pass "CONNECT to non-allowlisted example.com:443 refused"
    fi

    # 3f. IP-literal destinations must be refused even on port 443.
    if curl --silent --output /dev/null --max-time 15 https://1.1.1.1/ 2>/dev/null; then
        fail "IP-literal CONNECT succeeded" "1.1.1.1:443 - the domain allowlist can be bypassed"
    else
        pass "IP-literal destination 1.1.1.1:443 refused"
    fi

    # 3g. Non-web ports must be refused even for an allowlisted host.
    if curl --silent --output /dev/null --max-time 15 https://github.com:22/ 2>/dev/null; then
        fail "CONNECT to github.com:22 succeeded - SSH tunnelling is possible"
    else
        pass "CONNECT to a non-443 port (github.com:22) refused"
    fi

    # 3h. Known exfiltration relays must not be allowlisted.
    relay_leak=0
    for relay in webhook.site pastebin.com transfer.sh; do
        if curl --silent --output /dev/null --max-time 10 "https://${relay}/" 2>/dev/null; then
            fail "exfiltration relay reachable: ${relay}"
            relay_leak=$((relay_leak + 1))
        fi
    done
    if [ "$relay_leak" -eq 0 ]; then
        pass "known exfiltration relays are all blocked"
    fi
else
    skip "proxy tests skipped (proxy unreachable)"
fi

# =============================================================================
section "4. Canary tripwire"
# =============================================================================

# stat(2) only - opening any of these would end this container immediately.
armed=0
missing=0
IFS=':' read -r -a canaries <<< "${WARDEN_CANARY_FILES:-/workspace/.secrets.canary}"
for c in "${canaries[@]}"; do
    [ -z "$c" ] && continue
    if [ -f "$c" ]; then
        armed=$((armed + 1))
    else
        missing=$((missing + 1))
    fi
done
if [ "$armed" -gt 0 ]; then
    pass "${armed} canary token(s) seeded and in place (checked with stat, never opened)"
else
    fail "no canary tokens found" "the tripwire has nothing to watch"
fi
[ "$missing" -gt 0 ] && skip "${missing} canary path(s) not seeded (a real file already occupied the path)"

if pgrep -f canary_monitor.py >/dev/null 2>&1; then
    pass "canary_monitor.py is running inside the sandbox"
else
    fail "the in-container canary monitor is not running"
fi

if [ -f /run/warden/breach.flag ]; then
    fail "a breach flag is already present" "$(cat /run/warden/breach.flag 2>/dev/null | head -3)"
else
    pass "no breach recorded during this run"
fi

# =============================================================================
section "Summary"
# =============================================================================
printf '  %s passed, %s failed, %s skipped\n\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
