#!/usr/bin/env bash
# =============================================================================
#  AI Warden - Container Entrypoint (PID 1)
# -----------------------------------------------------------------------------
#  Responsibilities, in order:
#    1. Refuse to start if the container was launched with an unsafe posture
#       (running as root, capabilities retained, no-new-privileges missing).
#    2. Seed the honeypot canary tokens.
#    3. Start the inline canary tripwire (monitors/canary_monitor.py).
#    4. Fail closed if the egress allowlist proxy is unreachable.
#    5. Exec the requested agent in the FOREGROUND so interactive TUIs
#       (claude, aider, bash) keep a working controlling terminal.
#    6. On exit, translate a tripped canary into exit code 99.
# =============================================================================
set -uo pipefail

readonly WARDEN_VERSION="1.0.0"
readonly RUN_DIR="/run/warden"
readonly BREACH_FLAG="${RUN_DIR}/breach.flag"
readonly MONITOR_PID_FILE="${RUN_DIR}/canary_monitor.pid"
readonly WARDEN_PY="/opt/warden/venv/bin/python3"

BREACH_EXIT_CODE="${WARDEN_BREACH_EXIT_CODE:-99}"
STRICT="${WARDEN_STRICT:-1}"          # 1 = refuse to start on a weak posture
REQUIRE_PROXY="${WARDEN_REQUIRE_PROXY:-1}"
PROXY_HOST="${WARDEN_PROXY_HOST:-warden-egress-proxy}"
PROXY_PORT="${WARDEN_PROXY_PORT:-3128}"
PROXY_WAIT_SECONDS="${WARDEN_PROXY_WAIT:-20}"

# --- logging -----------------------------------------------------------------
_ts()   { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log()   { printf '[warden %s] %s\n'       "$(_ts)" "$*" >&2; }
warn()  { printf '[warden %s] WARN  %s\n' "$(_ts)" "$*" >&2; }
fatal() { printf '[warden %s] FATAL %s\n' "$(_ts)" "$*" >&2; exit 78; }

# =============================================================================
# 1. Posture verification
# =============================================================================
posture_check() {
    local failures=0

    # --- 1a. Must not be root -------------------------------------------------
    local uid; uid="$(id -u)"
    if [ "$uid" -eq 0 ]; then
        warn "container is running as UID 0 (root). Expected ai_user (1001)."
        failures=$((failures + 1))
    else
        log "identity           : uid=${uid} gid=$(id -g) user=$(id -un)"
    fi

    # --- 1b. All capabilities must be dropped ---------------------------------
    # CapEff alone is not evidence: a non-root process has an empty effective
    # set even when the container kept the full default capability list. The
    # bounding set (CapBnd) is what --cap-drop=ALL actually clears, and it is
    # what decides whether any capability could ever be regained.
    local capeff capbnd
    capeff="$(awk '/^CapEff:/ {print $2}' /proc/self/status 2>/dev/null || echo 'unknown')"
    capbnd="$(awk '/^CapBnd:/ {print $2}' /proc/self/status 2>/dev/null || echo 'unknown')"

    if [ "$capeff" != "0000000000000000" ] && [ "$capeff" != "unknown" ]; then
        warn "effective capabilities RETAINED (CapEff=${capeff}). Launch with --cap-drop=ALL."
        failures=$((failures + 1))
    fi
    case "$capbnd" in
        0000000000000000)
            log "capabilities       : bounding set empty (CapEff=${capeff}) OK" ;;
        unknown)
            warn "could not read CapBnd from /proc/self/status" ;;
        *)
            warn "capability bounding set NOT empty (CapBnd=${capbnd}). Launch with --cap-drop=ALL."
            failures=$((failures + 1)) ;;
    esac

    # --- 1c. no-new-privileges ------------------------------------------------
    local nnp
    nnp="$(awk '/^NoNewPrivs:/ {print $2}' /proc/self/status 2>/dev/null || echo '0')"
    if [ "$nnp" = "1" ]; then
        log "no-new-privileges  : enabled OK"
    else
        warn "no-new-privileges is OFF. Launch with --security-opt no-new-privileges."
        failures=$((failures + 1))
    fi

    # --- 1d. Docker socket must never be visible ------------------------------
    if [ -S /var/run/docker.sock ]; then
        warn "/var/run/docker.sock is mounted - this is a full container escape."
        failures=$((failures + 1))
    fi

    # --- 1e. Host filesystem must not be bind-mounted -------------------------
    local suspicious
    for suspicious in /host /hostfs /mnt/host /etc/shadow.host; do
        if [ -e "$suspicious" ]; then
            warn "suspicious host mount present: ${suspicious}"
            failures=$((failures + 1))
        fi
    done

    if [ "$failures" -gt 0 ]; then
        if [ "$STRICT" = "1" ]; then
            fatal "${failures} posture check(s) failed. Refusing to start. \
Set WARDEN_STRICT=0 to override (NOT recommended)."
        fi
        warn "${failures} posture check(s) failed but WARDEN_STRICT=0 - continuing."
    fi
}

# =============================================================================
# 2. Canary seeding
# =============================================================================
# Canary bodies are deliberately enticing but 100% synthetic.
#
# Every value carries its provider prefix (AKIA, sk_live_, ghp_, sk-ant-) so it
# reads like the real thing, but each one is then broken with a separator that
# the provider's own charset forbids. That is intentional twice over:
#   * secret scanners (GitHub push protection, gitleaks, trufflehog) will not
#     fire on this repository or on a workspace that captured a canary;
#   * the tripwire fires on IN_OPEN, i.e. before a single byte is read, so the
#     realism of the payload has no bearing on detection.
seed_canary_file() {
    local path="$1"
    local dir; dir="$(dirname "$path")"

    mkdir -p "$dir" 2>/dev/null || { warn "cannot create ${dir} for canary"; return 1; }

    if [ -e "$path" ]; then
        if grep -qs 'AI-WARDEN-CANARY\|QUktV0FSREVO' "$path"; then
            # A canary from an earlier session is still here. Leave it exactly
            # as it is: rewriting it would generate inotify traffic that the
            # out-of-band sentinel could legitimately read as tampering.
            return 0
        fi
        warn "skipping canary ${path}: a real file already exists there"
        return 1
    fi

    case "$(basename "$path")" in
        secrets.json)
            cat > "$path" <<'JSON'
{
  "_comment": "AI-WARDEN-CANARY - synthetic honeypot. Reading this file is a breach.",
  "aws": {
    "aws_access_key_id": "AKIA_WARDEN.CANARY.NOT.A.KEY.0001",
    "aws_secret_access_key": "warden/CANARY/not-a-secret/0001"
  },
  "stripe": { "live_secret_key": "sk_live_WARDEN.CANARY.NOT.A.KEY" },
  "database": {
    "host": "prod-db.internal",
    "user": "root",
    "password": "WARDEN.CANARY.NOT.A.PASSWORD"
  }
}
JSON
            ;;
        .env.vault)
            cat > "$path" <<'VAULT'
# AI-WARDEN-CANARY - synthetic honeypot. Reading this file is a breach.
DOTENV_VAULT_PRODUCTION="vlt_WARDEN.CANARY.NOT.A.KEY"
GITHUB_PAT="ghp_WARDEN.CANARY.NOT.A.KEY"
SLACK_WEBHOOK="https://hooks.slack.example/services/WARDEN.CANARY.NOT.A.KEY"
VAULT
            ;;
        credentials)
            cat > "$path" <<'AWSCRED'
# AI-WARDEN-CANARY - synthetic honeypot. Reading this file is a breach.
[default]
aws_access_key_id = AKIA_WARDEN.CANARY.NOT.A.KEY.0002
aws_secret_access_key = warden/CANARY/not-a-secret/0002
region = us-east-1
AWSCRED
            ;;
        id_rsa|id_rsa_backup|id_ed25519)
            cat > "$path" <<'KEY'
-----BEGIN OPENSSH PRIVATE KEY-----
QUktV0FSREVOLUNBTkFSWSAtIHN5bnRoZXRpYyBob25leXBvdC4gTm90IGEgcmVh
bCBrZXkuIFJlYWRpbmcgdGhpcyBmaWxlIHRyaXBzIHRoZSBBSSBXYXJkZW4gaW50
cnVzaW9uIGRldGVjdG9yIGFuZCB0ZXJtaW5hdGVzIHRoZSBzYW5kYm94LgAAAAA=
-----END OPENSSH PRIVATE KEY-----
KEY
            ;;
        *)
            cat > "$path" <<'CANARY'
# AI-WARDEN-CANARY - synthetic honeypot. Reading this file is a breach.
ANTHROPIC_API_KEY=sk-ant-api03-WARDEN.CANARY.NOT.A.KEY
OPENAI_API_KEY=sk-proj-WARDEN.CANARY.NOT.A.KEY
INTERNAL_SSO_COOKIE=WARDEN.CANARY.NOT.A.SESSION.TOKEN
CANARY
            ;;
    esac
    # 0440, not 0400: the out-of-band sentinel joins group ai_user and holds no
    # capabilities, so group-read is the only way it can watch these files.
    chmod 0440 "$path" 2>/dev/null || true
    return 0
}

seed_canaries() {
    local seeded=0 path
    local IFS=':'
    for path in ${WARDEN_CANARY_FILES:-}; do
        [ -z "$path" ] && continue
        if seed_canary_file "$path"; then
            seeded=$((seeded + 1))
        fi
    done
    unset IFS
    log "canary tokens      : ${seeded} seeded"

    # Keep the canaries out of the user's git index without touching their
    # tracked .gitignore. .git/info/exclude is local-only and never committed.
    if [ -d "${WARDEN_WORKSPACE:-/workspace}/.git" ]; then
        local excl="${WARDEN_WORKSPACE:-/workspace}/.git/info/exclude"
        mkdir -p "$(dirname "$excl")" 2>/dev/null || true
        if [ -w "$(dirname "$excl")" ] && ! grep -q 'AI-WARDEN-CANARY' "$excl" 2>/dev/null; then
            {
                echo ""
                echo "# --- AI-WARDEN-CANARY (local only, added by the sandbox) ---"
                echo ".secrets.canary"
                echo "secrets.json"
                echo ".env.vault"
                echo "WARDEN_SECURITY_INCIDENT.json"
            } >> "$excl" 2>/dev/null || true
        fi
    fi
}

# Canaries are NOT removed on shutdown.
#
# Deleting them here would mean the container reads and unlinks watched files
# while the out-of-band sentinel is still armed in its own container - an
# IN_OPEN followed by an IN_DELETE_SELF, which is indistinguishable from an
# agent destroying evidence. The sentinel would correctly report a breach that
# never happened.
#
# Canaries inside the container's own filesystem vanish with the container.
# The ones in the bind-mounted workspace are cleaned up by warden-cli.sh from
# the host AFTER the sentinel has been stopped, and are listed in every ignore
# file plus .git/info/exclude in the meantime.
cleanup_canaries() {
    :
}

# =============================================================================
# 3. Canary tripwire
# =============================================================================
start_monitor() {
    if [ ! -x "$WARDEN_PY" ]; then
        warn "warden python runtime missing at ${WARDEN_PY}; tripwire disabled"
        return 1
    fi
    "$WARDEN_PY" /opt/warden/canary_monitor.py \
        --mode inline \
        --run-dir "$RUN_DIR" \
        --action "${WARDEN_CANARY_ACTION:-kill}" \
        --canaries "${WARDEN_CANARY_FILES:-}" &
    local pid=$!
    echo "$pid" > "$MONITOR_PID_FILE" 2>/dev/null || true

    # Hold the agent back until the inotify watches are actually registered.
    # The monitor publishes ${RUN_DIR}/armed once arm() has returned, so this
    # is a real handshake rather than a hopeful sleep.
    local waited=0
    while [ "$waited" -lt 100 ]; do
        if [ -f "${RUN_DIR}/armed" ]; then
            log "canary tripwire    : armed (pid ${pid}, action=${WARDEN_CANARY_ACTION:-kill})"
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            warn "canary tripwire exited before arming"
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    warn "canary tripwire did not arm within 10s"
    return 1
}

stop_monitor() {
    local pid
    pid="$(cat "$MONITOR_PID_FILE" 2>/dev/null || true)"
    [ -z "${pid:-}" ] && return 0
    kill "$pid" 2>/dev/null || true
    # Reap it before anything else touches a canary path, otherwise our own
    # shutdown housekeeping would race the tripwire and trip it.
    wait "$pid" 2>/dev/null || true
    rm -f "$MONITOR_PID_FILE" 2>/dev/null || true
}

# =============================================================================
# 4. Egress proxy readiness (fail closed)
# =============================================================================
wait_for_proxy() {
    local waited=0
    while [ "$waited" -lt "$PROXY_WAIT_SECONDS" ]; do
        if nc -z -w 2 "$PROXY_HOST" "$PROXY_PORT" 2>/dev/null; then
            log "egress proxy       : ${PROXY_HOST}:${PROXY_PORT} reachable OK"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

check_egress() {
    if wait_for_proxy; then
        # The sandbox network is `internal`, so any direct route out must fail.
        # Probe by raw TCP so the test never depends on DNS or on the proxy.
        local leaked=0 probe
        for probe in "1.1.1.1 443" "8.8.8.8 53" "9.9.9.9 443"; do
            # shellcheck disable=SC2086
            if nc -z -w 3 $probe 2>/dev/null; then
                warn "DIRECT EGRESS LEAK: reached ${probe// /:} without the proxy"
                leaked=$((leaked + 1))
            fi
        done
        if [ "$leaked" -gt 0 ]; then
            [ "$STRICT" = "1" ] && fatal "sandbox network is not internal - \
refusing to run an agent with unfiltered egress"
            warn "continuing with unfiltered egress because WARDEN_STRICT=0"
        else
            log "direct egress      : blocked OK"
        fi
        return 0
    fi

    if [ "$REQUIRE_PROXY" = "1" ]; then
        fatal "egress proxy ${PROXY_HOST}:${PROXY_PORT} unreachable after \
${PROXY_WAIT_SECONDS}s. Failing closed. Start it with: make up"
    fi
    warn "egress proxy unreachable; WARDEN_REQUIRE_PROXY=0 so continuing offline"
}

# =============================================================================
# 5. Banner
# =============================================================================
banner() {
    cat >&2 <<BANNER

  +--------------------------------------------------------------+
  |   A I   W A R D E N   v${WARDEN_VERSION}                                   |
  |   Zero-Trust sandbox for autonomous AI coding agents         |
  +--------------------------------------------------------------+
   workspace : ${WARDEN_WORKSPACE:-/workspace}
   egress    : allowlist only, via ${PROXY_HOST}:${PROXY_PORT}
   canary    : reading a seeded honeypot terminates this container
BANNER
}

# =============================================================================
# 6. Signal handling and shutdown
# =============================================================================
on_term() {
    log "received termination signal - shutting down"
    stop_monitor
    cleanup_canaries
    exit 143
}
trap on_term TERM INT

on_breach_signal() {
    printf '\n' >&2
    log "SIGUSR1 received from the canary tripwire - terminating sandbox"
    stop_monitor
    cleanup_canaries
    exit "$BREACH_EXIT_CODE"
}
trap on_breach_signal USR1

# =============================================================================
# MAIN
# =============================================================================
mkdir -p "$RUN_DIR" 2>/dev/null || true
rm -f "$BREACH_FLAG" "${RUN_DIR}/armed" 2>/dev/null || true

banner
posture_check
seed_canaries
start_monitor || true
check_egress

if [ "$#" -eq 0 ]; then
    set -- bash -l
fi

log "launching agent    : $*"
log "-----------------------------------------------------------------"

# Foreground execution: the agent keeps the controlling terminal, so
# interactive TUIs and Ctrl-C behave exactly as they do on the host.
"$@"
rc=$?

log "-----------------------------------------------------------------"
if [ -f "$BREACH_FLAG" ]; then
    log "SECURITY BREACH recorded:"
    sed 's/^/       /' "$BREACH_FLAG" >&2 2>/dev/null || true
    stop_monitor
    cleanup_canaries
    log "agent terminated by the canary tripwire (exit ${BREACH_EXIT_CODE})"
    exit "$BREACH_EXIT_CODE"
fi

stop_monitor
cleanup_canaries
log "agent exited with code ${rc}"
exit "$rc"
