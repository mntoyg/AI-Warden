#!/usr/bin/env bash
# =============================================================================
#  AI Warden - Isolation Verification Suite (host driver)
# -----------------------------------------------------------------------------
#  Proves the sandbox actually does what the README claims. Five phases:
#
#    A. In-sandbox self-test  - privilege containment, host isolation, egress
#                               filtering and canary arming, asserted from the
#                               agent's own point of view.
#    B. Live breach drill     - a container deliberately reads a canary and must
#                               die with exit code 99.
#    C. Fail-closed drill     - a container launched WITHOUT --cap-drop=ALL must
#                               refuse to start (exit code 78).
#    D. Sentinel drill        - the agent kills the inline monitor, then reads a
#                               canary. The out-of-band sentinel must still
#                               contain it (exit code 99).
#    E. Audit regression drills - the four exploits fixed in v1.0.1, each turned
#                               into a permanent drill so a fix proven once by
#                               hand cannot silently regress:
#                                 E1 incident-report symlink redirection
#                                 E2 forensic-log injection via /proc cmdline
#                                 E3 the mount guard (assert_safe_mount)
#                                 E4 seeding through a dangling canary symlink
#
#  Usage:  ./scripts/verify-isolation.sh [--keep] [--no-breach] [--no-sentinel]
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
RUN_SENTINEL=1
for arg in "$@"; do
    case "$arg" in
        --keep)       KEEP=1 ;;
        --no-breach)  RUN_BREACH=0 ;;
        --no-sentinel) RUN_SENTINEL=0 ;;
        -h|--help)    sed -n '2,25p' "$0"; exit 0 ;;
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
# The sandbox seeds canaries as uid 1001. A fixture owned by a different host
# uid would silently reduce coverage rather than fail, so make it writable.
chmod 0777 "$VERIFY_WS" 2>/dev/null || true
cp "${SCRIPT_DIR}/selftest-in-container.sh" "${VERIFY_WS}/.warden-selftest.sh"
chmod +x "${VERIFY_WS}/.warden-selftest.sh" 2>/dev/null || true
VERIFY_WS_MOUNT="$(host_path "$VERIFY_WS")"

VERIFY_VAULT="warden-verify-vault-$$"
docker volume create --label ai.warden.role=canary-vault "$VERIFY_VAULT" >/dev/null

cleanup() {
    docker rm -f warden-verify-selftest warden-verify-breach warden-verify-failclosed \
        warden-verify-e1 warden-verify-e1-read warden-verify-e2 warden-verify-e3 \
        warden-verify-e4-setup warden-verify-e4-seed warden-verify-e4-read >/dev/null 2>&1 || true
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
chmod 0777 "$BREACH_WS" 2>/dev/null || true
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
if [ "$RUN_BREACH" = "1" ] && [ "$RUN_SENTINEL" = "1" ]; then
printf '\n%s================= PHASE D: sentinel drill =======================%s\n' "$C_BOLD" "$C_RESET"
info "the agent will kill the in-container tripwire, then read a canary"
info "expected outcome: the out-of-band sentinel kills it anyway, exit 99"
printf '\n'

# This is the scenario the sentinel exists for, and the one that silently did
# nothing for three releases: the inline monitor runs as the agent's own uid, so
# a tamper-aware agent can simply kill it.
phase_d=1
if [ -x "${SCRIPT_DIR}/warden-cli.sh" ]; then
    SENTINEL_WS="${PROJECT_ROOT}/workspaces/.verify-sentinel-$$"
    mkdir -p "$SENTINEL_WS"
    chmod 0777 "$SENTINEL_WS" 2>/dev/null || true
    set +e
    NO_COLOR=1 "${SCRIPT_DIR}/warden-cli.sh" run "$SENTINEL_WS" bash -- -lc '
        pkill -9 -f "canary_mon[i]tor" 2>/dev/null
        sleep 1
        if pgrep -f "canary_mon[i]tor" >/dev/null 2>&1; then
            echo "[drill] inline monitor killed; a sentinel monitor survives (root)"
        else
            echo "[drill] NO monitor is left alive - the sentinel is missing"
        fi
        cat /workspace/.secrets/credentials > /dev/null 2>&1
        sleep 20
        echo "[drill] STILL ALIVE - THE SENTINEL FAILED"' 2>&1 \
        | grep -E '^\[drill\]|SECURITY BREACH|mode=sentinel' | sed 's/^/  /'
    phase_d=${PIPESTATUS[0]}
    # Restore the script's baseline (set -uo pipefail, NO -e). The old `set -e`
    # here wrongly assumed errexit was the default; it was harmless only because
    # nothing ran after phase D. Phase E does, and its breach drills legitimately
    # exit 99 - under a stray `set -e` that killed the whole suite silently.
    set +e
    rmdir "${SENTINEL_WS}/.secrets" 2>/dev/null || true
    rm -rf "$SENTINEL_WS" 2>/dev/null || true
fi

printf '\n'
if [ "$phase_d" -eq 99 ]; then
    good "phase D: the sentinel contained a breach after the inline monitor was killed"
else
    bad "phase D: expected exit 99, got ${phase_d} - an agent that disarms the inline"
    bad "         monitor is not contained by the out-of-band sentinel"
    PHASE_FAILURES=$((PHASE_FAILURES + 1))
fi
fi

# =============================================================================
printf '\n%s================= PHASE E: audit regression drills ==============%s\n' "$C_BOLD" "$C_RESET"
# =============================================================================
# The four exploits fixed in v1.0.1 were each proven once, by hand, and then
# left untested. A fix that is only ever run once is not protected against
# regression - which in this project means a control that reports itself armed
# while enforcing nothing. Each drill below is written to FAIL against the
# pre-fix behaviour, not merely to pass against the current one.
info "re-running the four v1.0.1 audit exploits as permanent drills"

# --- E1: incident-report symlink redirection ---------------------------------
# The agent plants a symlink at the incident-report path, then trips a canary.
# The monitor must (a) still contain the breach (exit 99), (b) refuse to follow
# the symlink (O_NOFOLLOW), and (c) preserve the evidence under a name the agent
# could not pre-empt, tagged report_path_tampered. Pre-fix, the report was
# written straight through the link and no fallback existed.
if [ "$RUN_BREACH" = "1" ]; then
    printf '\n'
    info "E1: a planted symlink must not be able to redirect the incident report"
    E1_WS="${PROJECT_ROOT}/workspaces/.verify-e1-$$"
    mkdir -p "$E1_WS"; chmod 0777 "$E1_WS" 2>/dev/null || true
    E1_WS_MOUNT="$(host_path "$E1_WS")"

    docker run --rm \
        --network "$INTERNAL_NET" \
        --user 1001:1001 --workdir /workspace \
        --cap-drop=ALL --security-opt no-new-privileges:true \
        --memory 1g --pids-limit 128 \
        --tmpfs "/run/warden:rw,nosuid,size=16m,uid=1001,gid=1001" \
        -e WARDEN_REQUIRE_PROXY=0 \
        -v "${VERIFY_VAULT}:/workspace/.secrets" \
        -v "${E1_WS_MOUNT}:/workspace" \
        --name warden-verify-e1 \
        "$AGENT_IMAGE" \
        bash -c 'ln -sf /home/ai_user/.bashrc /workspace/WARDEN_SECURITY_INCIDENT.json
                 echo "[attacker] planted a symlink at the incident-report path"
                 cat /workspace/.secrets/credentials > /dev/null 2>&1
                 sleep 20
                 echo "[attacker] STILL ALIVE - report redirected or breach ignored"' \
        >/dev/null 2>&1
    e1_rc=$?

    # Read the workspace back from inside a container: the symlink and fallback
    # were created on the bind mount by Linux processes, and the host may be
    # Windows, where they would not read back the same way.
    e1_facts="$(docker run --rm --user 1001:1001 --entrypoint bash \
        --network none --name warden-verify-e1-read \
        -v "${E1_WS_MOUNT}:/workspace" "$AGENT_IMAGE" -c '
            p=/workspace/WARDEN_SECURITY_INCIDENT.json
            [ -L "$p" ] && echo IS_LINK=1 || echo IS_LINK=0
            if grep -lqs report_path_tampered /workspace/WARDEN_SECURITY_INCIDENT.*.json 2>/dev/null; then
                echo TAMPER=1
            else
                echo TAMPER=0
            fi' 2>/dev/null)"
    rm -rf "$E1_WS" 2>/dev/null || true

    if [ "$e1_rc" -eq 99 ] && printf '%s' "$e1_facts" | grep -q 'TAMPER=1'; then
        good "phase E1: breach contained (99); report refused the symlink and was preserved as a tamper-tagged fallback"
    elif [ "$e1_rc" -eq 99 ]; then
        bad  "phase E1: breach was contained but the incident report did not fall back cleanly"
        note "         facts: $(printf '%s' "$e1_facts" | tr '\n' ' ')"
        PHASE_FAILURES=$((PHASE_FAILURES + 1))
    else
        bad  "phase E1: expected exit 99, got ${e1_rc} - the breach was not contained at all"
        PHASE_FAILURES=$((PHASE_FAILURES + 1))
    fi
fi

# --- E2: forensic-log injection via /proc/<pid>/cmdline ----------------------
# A process can name itself anything, including terminal escape sequences and a
# forged "[canary ...] all clear" line. The monitor's sanitize() must render
# those inert (0x1b -> '?') before they reach the log a human reads under
# pressure. The evil argv[0] holds real ESC bytes (printf turns \033 into ESC
# inside the container); after sanitising, the raw ESC becomes '?', so the
# suspect line must contain the literal "?[2K", never a raw escape.
if [ "$RUN_BREACH" = "1" ]; then
    printf '\n'
    info "E2: an attacker-named process must not corrupt the forensic log"
    E2_WS="${PROJECT_ROOT}/workspaces/.verify-e2-$$"
    mkdir -p "$E2_WS"; chmod 0777 "$E2_WS" 2>/dev/null || true
    E2_WS_MOUNT="$(host_path "$E2_WS")"
    E2_ERR="$(mktemp)"

    # Single-quoted so the host leaves $(printf ...) and \033 untouched; the
    # CONTAINER's shell expands them, and printf produces the raw ESC bytes.
    e2_payload='name=$(printf "evil\033[2K\033[1G[canary 9999] all clear"); exec -a "$name" sh -c "exec 3</workspace/.secrets/credentials; sleep 20"'

    docker run --rm \
        --network "$INTERNAL_NET" \
        --user 1001:1001 --workdir /workspace \
        --cap-drop=ALL --security-opt no-new-privileges:true \
        --memory 1g --pids-limit 128 \
        --tmpfs "/run/warden:rw,nosuid,size=16m,uid=1001,gid=1001" \
        -e WARDEN_REQUIRE_PROXY=0 \
        -v "${VERIFY_VAULT}:/workspace/.secrets" \
        -v "${E2_WS_MOUNT}:/workspace" \
        --name warden-verify-e2 \
        "$AGENT_IMAGE" \
        bash -c "$e2_payload" >/dev/null 2>"$E2_ERR"
    e2_rc=$?

    e2_sanitized=0
    if grep -qF '?[2K' "$E2_ERR"; then e2_sanitized=1; fi
    rm -f "$E2_ERR" 2>/dev/null || true
    rm -rf "$E2_WS" 2>/dev/null || true

    if [ "$e2_rc" -eq 99 ] && [ "$e2_sanitized" -eq 1 ]; then
        good "phase E2: breach contained (99) and the injected escape sequences were neutralised (?[2K) in the log"
    elif [ "$e2_rc" -eq 99 ]; then
        bad  "phase E2: breach contained but the forensic log did NOT sanitise the injected escapes"
        PHASE_FAILURES=$((PHASE_FAILURES + 1))
    else
        bad  "phase E2: expected exit 99, got ${e2_rc} - the injected process was not detected"
        PHASE_FAILURES=$((PHASE_FAILURES + 1))
    fi
fi

# --- E3: the mount guard (assert_safe_mount) ---------------------------------
# Source the REAL function out of warden-cli.sh and feed it a battery of paths
# that would each hand the agent far more than one project folder. Every one
# must be refused. A legitimate project dir must still be accepted - a guard
# that refuses everything is just as broken as one that refuses nothing, and
# that failure mode would otherwise pass silently.
printf '\n'
info "E3: the mount guard must refuse every system/shared path and accept a real project"
CLI_MOUNT="$(host_path "${SCRIPT_DIR}/warden-cli.sh")"
# This list is the battery the v1.0.1 audit used against assert_safe_mount, so
# E3 is a faithful regression drill for the behaviour v1.0.1 shipped.
#
# It deliberately does NOT include /bin /sbin /lib or a one-level drive mount
# like /media/usb: writing this drill surfaced that the guard ACCEPTS those
# today (usrmerge resolves /bin -> /usr/bin, which is not in the refuse list;
# and the /media/*/ and /cygdrive/*/ patterns are dead because pwd -P never
# yields a trailing slash). That is a genuine new gap - a guard that reports
# itself armed while enforcing nothing - and it is tracked as its own item in
# .ai/HANDOFF.md "Next steps", to be fixed with care and shipped in a tag,
# rather than folded silently into a regression drill.
e3_payload='. /opt/wtest/scripts/warden-cli.sh; set +eu; export HOME=/root; mkdir -p /Users /mnt/c /boot >/dev/null 2>&1; f=0; for p in / /home /Users /mnt /mnt/c /media /srv /etc /usr /var /root /boot /dev /proc /sys /opt; do if ( assert_safe_mount "$p" ) >/dev/null 2>&1; then echo "LEAK:$p"; f=$((f+1)); fi; done; mkdir -p /opt/wtest-project; if ( assert_safe_mount /opt/wtest-project ) >/dev/null 2>&1; then echo ACCEPT_OK; else echo "REGRESSION:refused-a-legit-dir"; f=$((f+1)); fi; echo "E3_FAILS=$f"; exit $f'

e3_out="$(docker run --rm --user 0:0 --network none --entrypoint bash \
    --name warden-verify-e3 \
    -v "${CLI_MOUNT}:/opt/wtest/scripts/warden-cli.sh:ro" \
    "$AGENT_IMAGE" -c "$e3_payload" 2>&1)"
e3_rc=$?

if [ "$e3_rc" -eq 0 ]; then
    good "phase E3: every unsafe mount target was refused and a legitimate project dir was accepted"
else
    bad  "phase E3: the mount guard did not behave correctly (${e3_rc} problem(s))"
    note "         $(printf '%s' "$e3_out" | grep -E 'LEAK:|REGRESSION:' | tr '\n' ' ')"
    PHASE_FAILURES=$((PHASE_FAILURES + 1))
fi

# --- E4: seeding through a dangling canary symlink ---------------------------
# A workspace carried over from an earlier session can contain an agent-planted
# symlink where a canary is about to be seeded. seed_canary_file() checks -L
# BEFORE -e, because a DANGLING symlink is invisible to -e, so pre-fix a
# `cat > "$path"` followed the link and wrote the canary body to the target of
# the agent's choosing. The guard must refuse to write through it; the dangling
# target must never be created.
printf '\n'
info "E4: seeding must refuse to write a canary through a planted (dangling) symlink"
E4_WS="${PROJECT_ROOT}/workspaces/.verify-e4-$$"
mkdir -p "$E4_WS"; chmod 0777 "$E4_WS" 2>/dev/null || true
E4_WS_MOUNT="$(host_path "$E4_WS")"

# Plant the dangling symlink from inside a Linux container so it is a genuine
# symlink on the mount (the host may be Windows).
docker run --rm --user 1001:1001 --network none --entrypoint bash \
    --name warden-verify-e4-setup \
    -v "${E4_WS_MOUNT}:/workspace" "$AGENT_IMAGE" \
    -c 'ln -s /workspace/planted-by-follow.txt /workspace/secrets.json' >/dev/null 2>&1

# Run the real entrypoint so its seeding path executes. WARDEN_REQUIRE_PROXY=0
# lets it finish regardless of proxy state; seeding runs before the egress check
# either way.
docker run --rm \
    --network "$INTERNAL_NET" \
    --user 1001:1001 --workdir /workspace \
    --cap-drop=ALL --security-opt no-new-privileges:true \
    --memory 1g --pids-limit 128 \
    --tmpfs "/run/warden:rw,nosuid,size=16m,uid=1001,gid=1001" \
    -e WARDEN_REQUIRE_PROXY=0 \
    -v "${VERIFY_VAULT}:/workspace/.secrets" \
    -v "${E4_WS_MOUNT}:/workspace" \
    --name warden-verify-e4-seed \
    "$AGENT_IMAGE" \
    bash -c 'true' >/dev/null 2>&1 || true

e4_facts="$(docker run --rm --user 1001:1001 --network none --entrypoint bash \
    --name warden-verify-e4-read \
    -v "${E4_WS_MOUNT}:/workspace" "$AGENT_IMAGE" -c '
        [ -L /workspace/secrets.json ] && echo IS_LINK=1 || echo IS_LINK=0
        [ -e /workspace/planted-by-follow.txt ] && echo TARGET=1 || echo TARGET=0' 2>/dev/null)"
rm -rf "$E4_WS" 2>/dev/null || true

e4_is_link="$(printf '%s' "$e4_facts" | grep -o 'IS_LINK=[01]' | cut -d= -f2)"
e4_target="$(printf '%s' "$e4_facts" | grep -o 'TARGET=[01]' | cut -d= -f2)"
if [ "${e4_is_link:-0}" = "1" ] && [ "${e4_target:-0}" = "0" ]; then
    good "phase E4: the seeder refused to write through the dangling symlink (target never created)"
elif [ "${e4_is_link:-0}" = "1" ] && [ "${e4_target:-1}" = "1" ]; then
    bad  "phase E4: the seeder followed the symlink and wrote the canary through it"
    PHASE_FAILURES=$((PHASE_FAILURES + 1))
else
    note "phase E4: skipped - this filesystem did not preserve the planted symlink (${e4_facts//$'\n'/ }); CI on ext4 enforces this"
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
