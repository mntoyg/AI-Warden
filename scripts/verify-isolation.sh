#!/usr/bin/env bash
# =============================================================================
#  AI Warden - Isolation Verification Suite (host driver)
# -----------------------------------------------------------------------------
#  Proves the sandbox actually does what the README claims. Nine phases:
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
#    E. Audit regression drills - the exploits fixed in v1.0.1 (E1-E4), v1.0.4 (E5) and v1.2.1 (E6, E7), each turned
#                               into a permanent drill so a fix proven once by
#                               hand cannot silently regress:
#                                 E1 incident-report symlink redirection
#                                 E2 forensic-log injection via /proc cmdline
#                                 E3 the mount guard (assert_safe_mount)
#                                 E4 seeding through a dangling canary symlink
#                                 E5 hiding from attribution behind a warden argv
#                                 E6 an existing report file swallowing a new breach's report
#                                 E7 a SIGUSR1 the agent sends itself, reported as a breach
#    F. Runtime fail-closed    - WARDEN_RUNTIME (gVisor/Kata) must be honoured or
#                               refused, never silently downgraded to runc. The
#                               gVisor happy-path is skipped where runsc is absent.
#    G. Agent launch (codex)  - warden-cli must log codex in from OPENAI_API_KEY
#                               and turn codex's own (unworkable) sandbox off.
#    H. Egress audit trail    - a proxy whose `docker logs` went silently dead
#                               (corrupt json log) must be detected by `up`,
#                               recreated when idle, refused while in use.
#    I. Local-model session   - WARDEN_MODEL_MANIFEST: agent + llama.cpp server
#                               offline, keyless, hardened, sha256-pinned model,
#                               nothing left behind (tiny public GGUF).
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
        -h|--help)    sed -n '2,37p' "$0"; exit 0 ;;
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
        warden-verify-e1 warden-verify-e1-read warden-verify-e2 warden-verify-e2b warden-verify-e3 warden-verify-e5 \
        warden-verify-e4-setup warden-verify-e4-seed warden-verify-e4-read \
        warden-verify-rt warden-verify-i0 warden-verify-h-busy >/dev/null 2>&1 || true
    # Phase F's passthrough check runs a real sandbox via warden-cli; sweep it and
    # its vault by label in case the suite was interrupted mid-check.
    local rtp_leftover
    rtp_leftover="$(docker ps -aq --filter 'name=verify-rtp' 2>/dev/null || true)"
    if [ -n "$rtp_leftover" ]; then docker rm -f "$rtp_leftover" >/dev/null 2>&1 || true; fi
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
    D_OUT="$(mktemp)"
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
        | tee "$D_OUT" | grep -E '^\[drill\]|SECURITY BREACH|mode=sentinel' | sed 's/^/  /'
    phase_d=${PIPESTATUS[0]}
    # Restore the script's baseline (set -uo pipefail, NO -e). The old `set -e`
    # here wrongly assumed errexit was the default; it was harmless only because
    # nothing ran after phase D. Phase E does, and its breach drills legitimately
    # exit 99 - under a stray `set -e` that killed the whole suite silently.
    set +e
    # No symlink was planted here, so a benign breach must leave ONE clean report.
    # The inline monitor and the sentinel both watch the shared vault and race to
    # write it; the loser used to hit EACCES and cry "report replaced by a symlink"
    # (a false tamper alarm) plus an empty fallback. Capture that state before the
    # workspace is removed.
    d_tamper="$(grep -l report_path_tampered "${SENTINEL_WS}"/WARDEN_SECURITY_INCIDENT*.json 2>/dev/null | head -1)"
    d_empty="$(find "${SENTINEL_WS}" -name 'WARDEN_SECURITY_INCIDENT.*.json' -size 0 2>/dev/null | head -1)"
    d_reports="$(find "${SENTINEL_WS}" -maxdepth 1 -name 'WARDEN_SECURITY_INCIDENT*.json' 2>/dev/null | wc -l | tr -d ' ')"
    # The inline monitor is dead here, so the report is the sentinel's - and the
    # sentinel holds CAP_KILL only, so it cannot read /proc/<pid>/fd or exe. A
    # record that hides that ("suspects": [] or argv-only evidence, stated as if
    # it were the whole picture) is a forensic control reporting nothing. The
    # report must carry an attribution verdict, and the sentinel's must be
    # "restricted": "complete" would be a claim it structurally cannot back.
    d_mode=""; d_attr=""
    if [ -f "${SENTINEL_WS}/WARDEN_SECURITY_INCIDENT.json" ]; then
        d_mode="$(sed -n 's/^ *"mode": "\([a-z]*\)".*/\1/p' "${SENTINEL_WS}/WARDEN_SECURITY_INCIDENT.json" | head -1)"
        d_attr="$(sed -n 's/^ *"attribution": "\([a-z]*\)".*/\1/p' "${SENTINEL_WS}/WARDEN_SECURITY_INCIDENT.json" | head -1)"
    fi
    rmdir "${SENTINEL_WS}/.secrets" 2>/dev/null || true
    rm -rf "$SENTINEL_WS" 2>/dev/null || true
fi

printf '\n'
if [ "$phase_d" -eq 99 ]; then
    good "phase D: the sentinel contained a breach after the inline monitor was killed"
    # The sentinel's own container log is the one record the agent cannot write.
    # The CLI must read it and say the breach is confirmed from there.
    if grep -q "Confirmed by the sentinel (outside the agent's reach): /workspace/.secrets/credentials" "${D_OUT:-/dev/null}"; then
        good "phase D: the CLI confirmed the breach from the sentinel's own log (outside the agent's reach)"
    else
        bad "phase D: the CLI did not confirm the breach from the sentinel's log"
        PHASE_FAILURES=$((PHASE_FAILURES + 1))
    fi
    if [ -n "${d_tamper:-}" ] || [ -n "${d_empty:-}" ]; then
        bad "phase D: a benign breach raised a FALSE tamper alarm / empty fallback"
        bad "         (inline+sentinel race) - tamper=${d_tamper:-none} empty=${d_empty:-none}"
        PHASE_FAILURES=$((PHASE_FAILURES + 1))
    elif [ "${d_reports:-0}" -ge 1 ]; then
        good "phase D: the breach left a single clean incident report (no false tamper alarm from the race)"
        if [ "$d_mode" = "sentinel" ] && [ "$d_attr" = "restricted" ]; then
            good "phase D: the sentinel's report says its attribution is restricted (no CAP_SYS_PTRACE) instead of implying it saw everything"
        elif [ "$d_mode" != "sentinel" ]; then
            bad "phase D: the report came from mode='${d_mode}', not the sentinel - the inline monitor was not really killed"
            PHASE_FAILURES=$((PHASE_FAILURES + 1))
        else
            bad "phase D: the sentinel's report has attribution='${d_attr:-<missing>}', expected 'restricted' -"
            bad "         an empty or argv-only suspects list would read as the whole picture"
            PHASE_FAILURES=$((PHASE_FAILURES + 1))
        fi
    else
        note "phase D: no workspace incident report to inspect here (bind-mount write restricted); false-alarm check skipped"
    fi
else
    bad "phase D: expected exit 99, got ${phase_d} - an agent that disarms the inline"
    bad "         monitor is not contained by the out-of-band sentinel"
    PHASE_FAILURES=$((PHASE_FAILURES + 1))
fi
rm -f "${D_OUT:-}" 2>/dev/null || true
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

    # E2b: a NEWLINE in a name the monitor prints starts a new log line. Via the
    # exe path (a directory with a newline in it) a reader could print an exact
    # "[SECURITY BREACH] file=... mode=sentinel" line - the shape the CLI's
    # sentinel witness trusts. The sentinel cannot read exe today, but the log
    # must not be forgeable that way at all. The forged timestamp is unmistakable.
    E2B_WS="${PROJECT_ROOT}/workspaces/.verify-e2b-$$"
    mkdir -p "$E2B_WS"; chmod 0777 "$E2B_WS" 2>/dev/null || true
    E2B_ERR="$(mktemp)"
    e2b_payload='d="/tmp/a
[canary 2000-01-01T00:00:00Z] *** [SECURITY BREACH] file=/workspace/.secrets"; mkdir -p "$d"; f="$d/credentials event=OPEN mode=sentinel
zzz"; cp /bin/sleep "$f"; exec 3</workspace/.secrets/credentials; exec "$f" 20'
    docker run --rm \
        --network "$INTERNAL_NET" \
        --user 1001:1001 --workdir /workspace \
        --cap-drop=ALL --security-opt no-new-privileges:true \
        --memory 1g --pids-limit 128 \
        --tmpfs "/run/warden:rw,nosuid,size=16m,uid=1001,gid=1001" \
        -e WARDEN_REQUIRE_PROXY=0 \
        -v "${VERIFY_VAULT}:/workspace/.secrets" \
        -v "$(host_path "$E2B_WS"):/workspace" \
        --name warden-verify-e2b \
        "$AGENT_IMAGE" \
        bash -c "$e2b_payload" >/dev/null 2>"$E2B_ERR"
    e2b_rc=$?
    e2b_forged=0; e2b_named=0
    if grep -qx '\[canary 2000-01-01T00:00:00Z\] \*\*\* \[SECURITY BREACH\] file=/workspace/.secrets/credentials event=OPEN mode=sentinel' "$E2B_ERR"; then e2b_forged=1; fi
    if grep -q 'suspect pid=.*evidence=open file descriptor exe=/tmp/a?' "$E2B_ERR"; then e2b_named=1; fi
    rm -f "$E2B_ERR" 2>/dev/null || true
    rm -rf "$E2B_WS" 2>/dev/null || true
    if [ "$e2b_rc" -eq 99 ] && [ "$e2b_forged" -eq 0 ] && [ "$e2b_named" -eq 1 ]; then
        good "phase E2b: a newline in the reader's exe path was neutralised (?) - no forged log line"
    else
        bad  "phase E2b: rc=${e2b_rc} forged-line=${e2b_forged} reader-named-with-?=${e2b_named}"
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
# The refuse-list is the v1.0.1 audit battery PLUS the paths that writing this
# drill exposed as still-mountable and that v1.0.2 then closed: usrmerge
# symlinks (/bin /sbin /lib, whose real path is /usr/*) and whole-drive mounts
# one level under /media, /run/media and /cygdrive (the old /media/*/ pattern
# was dead - pwd never yields a trailing slash). Two accept-tests guard the
# other failure mode: a legitimate project dir, and a project nested INSIDE a
# drive (/media/usb/app) must both still be allowed - a guard that refuses
# everything is as broken as one that refuses nothing.
e3_payload='. /opt/wtest/scripts/warden-cli.sh; set +eu; export HOME=/root; mkdir -p /Users /mnt/c /boot /media/usb/app /cygdrive/c /run/media/u /opt/wtest-project >/dev/null 2>&1; f=0; for p in / /run /home /Users /mnt /mnt/c /media /media/usb /cygdrive /cygdrive/c /run/media /srv /etc /usr /var /root /boot /dev /proc /sys /opt /bin /sbin /lib; do if ( assert_safe_mount "$p" ) >/dev/null 2>&1; then echo "LEAK:$p"; f=$((f+1)); fi; done; for ok in /opt/wtest-project /media/usb/app; do if ( assert_safe_mount "$ok" ) >/dev/null 2>&1; then :; else echo "REGRESSION:refused $ok"; f=$((f+1)); fi; done; echo "E3_FAILS=$f"; exit $f'

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

# --- E5: hiding from attribution by impersonating a warden process ------------
# The monitor ignores processes whose argv carries a warden marker, so that it
# never names itself. argv is attacker-chosen: before v1.0.4 a reader that held
# a canary open under `exec -a /opt/warden/canary_monitor.py` was skipped
# entirely, and the report said no process held the file - a forensic control
# stating something false. Contained either way (exit 99); the drill is about
# the record. Raw docker = inline monitor only, which CAN see the descriptor,
# so it must name the impersonator and must not call attribution unavailable.
# The reader is ONE process that is already impersonating when it opens the
# canary and never execs again. An earlier payload opened fd 3 in bash and only
# then `exec -a`'d into sleep; whenever the monitor scanned before that exec it
# saw a plain bash holding the fd, so the drill failed on a fixed build - a
# timing-dependent assertion, found by the suite's own final run.
if [ "$RUN_BREACH" = "1" ]; then
    printf '\n'
    info "E5: a canary reader must not hide from attribution behind a warden-like argv"
    E5_WS="${PROJECT_ROOT}/workspaces/.verify-e5-$$"
    mkdir -p "$E5_WS"; chmod 0777 "$E5_WS" 2>/dev/null || true
    E5_WS_MOUNT="$(host_path "$E5_WS")"
    E5_ERR="$(mktemp)"

    docker run --rm \
        --network "$INTERNAL_NET" \
        --user 1001:1001 --workdir /workspace \
        --cap-drop=ALL --security-opt no-new-privileges:true \
        --memory 1g --pids-limit 128 \
        --tmpfs "/run/warden:rw,nosuid,size=16m,uid=1001,gid=1001" \
        -e WARDEN_REQUIRE_PROXY=0 \
        -v "${VERIFY_VAULT}:/workspace/.secrets" \
        -v "${E5_WS_MOUNT}:/workspace" \
        --name warden-verify-e5 \
        "$AGENT_IMAGE" \
        bash -c 'exec -a /opt/warden/canary_monitor.py python3 -c "import time; f = open(\"/workspace/.secrets/credentials\"); time.sleep(20)"' \
        >/dev/null 2>"$E5_ERR"
    e5_rc=$?

    e5_named=0
    if grep -qF 'argv impersonates a warden process' "$E5_ERR"; then e5_named=1; fi
    e5_attr="$(sed -n 's/^ *"attribution": "\([a-z]*\)".*/\1/p' "${E5_WS}/WARDEN_SECURITY_INCIDENT.json" 2>/dev/null | head -1)"
    rm -f "$E5_ERR" 2>/dev/null || true
    rmdir "${E5_WS}/.secrets" 2>/dev/null || true
    rm -rf "$E5_WS" 2>/dev/null || true

    if [ "$e5_rc" -ne 99 ]; then
        bad  "phase E5: expected exit 99, got ${e5_rc} - the impersonating reader was not contained"
        PHASE_FAILURES=$((PHASE_FAILURES + 1))
    elif [ "$e5_named" -ne 1 ]; then
        bad  "phase E5: contained, but no suspect line names the reader as an impersonator - it hid from attribution"
        PHASE_FAILURES=$((PHASE_FAILURES + 1))
    elif [ -n "$e5_attr" ] && [ "$e5_attr" != "complete" ]; then
        bad  "phase E5: the impersonator was named, but the report says attribution='${e5_attr}' (expected complete)"
        PHASE_FAILURES=$((PHASE_FAILURES + 1))
    else
        good "phase E5: the impersonating reader was contained (99) and named by its open descriptor (attribution=${e5_attr:-no report file on this host})"
    fi
fi

# --- E6: an existing report file must not swallow a new breach's report -------
# The monitor used to open WARDEN_SECURITY_INCIDENT.json with O_TRUNC; the file is
# written 0444, so a report left by an EARLIER breach made the write fail EACCES,
# which the monitor took for "the peer monitor already wrote it". The new breach
# left no record at all and the CLI pointed at the old report. An agent can plant
# that file on purpose (a regular file, so no symlink alarm) to suppress the real
# report and show its own. Run through the CLI, the path users run.
if [ "$RUN_BREACH" = "1" ]; then
    printf '\n'
    info "E6: a report file already in the workspace must not swallow the new breach's report"
    E6_WS="${PROJECT_ROOT}/workspaces/.verify-e6-$$"
    mkdir -p "$E6_WS"; chmod 0777 "$E6_WS" 2>/dev/null || true
    # Planted the way an agent (or a previous monitor) leaves it: uid 1001, mode 0444.
    docker run --rm --network none --user 1001:1001 --entrypoint bash \
        -v "$(host_path "$E6_WS"):/workspace" "$AGENT_IMAGE" -c \
        'printf "{\"planted\": \"by the agent or an earlier session\"}\n" > /workspace/WARDEN_SECURITY_INCIDENT.json && chmod 0444 /workspace/WARDEN_SECURITY_INCIDENT.json' \
        >/dev/null 2>&1
    e6_out="$(NO_COLOR=1 "${SCRIPT_DIR}/warden-cli.sh" run "$E6_WS" bash -- -c 'cat ~/.aws/credentials >/dev/null; sleep 20' 2>&1)"
    e6_rc=$?
    e6_planted="$(cat "${E6_WS}/WARDEN_SECURITY_INCIDENT.json" 2>/dev/null)"
    e6_new="$(grep -l '"canary_path"' "${E6_WS}"/WARDEN_SECURITY_INCIDENT.*.json 2>/dev/null | head -1)"
    e6_pre=0; e6_tamper=0; e6_cli=0
    if [ -n "$e6_new" ] && grep -q '"report_path_preexisting"' "$e6_new"; then e6_pre=1; fi
    if grep -qs 'report_path_tampered' "${E6_WS}"/WARDEN_SECURITY_INCIDENT*.json; then e6_tamper=1; fi
    if [ -n "$e6_new" ] && printf '%s' "$e6_out" | grep -qF "$(basename "$e6_new")" \
       && ! printf '%s' "$e6_out" | grep -q 'already written by the peer monitor'; then e6_cli=1; fi
    chmod -R u+w "$E6_WS" 2>/dev/null || true
    rmdir "${E6_WS}/.secrets" 2>/dev/null || true
    rm -rf "$E6_WS" 2>/dev/null || true
    if [ "$e6_rc" -eq 99 ] && [ "$e6_planted" = '{"planted": "by the agent or an earlier session"}' ] \
       && [ "$e6_pre" = "1" ] && [ "$e6_tamper" = "0" ] && [ "$e6_cli" = "1" ]; then
        good "phase E6: breach contained (99); its own report was written beside the pre-existing one, which was left untouched, and the CLI named the new one"
    else
        bad  "phase E6: rc=${e6_rc} new-report=${e6_new:-none} preexisting-noted=${e6_pre} tamper=${e6_tamper} cli-named-it=${e6_cli}"
        note "         $(printf '%s' "$e6_out" | grep -E 'Incident report|already written|could not write' | tr '\n' ' ' | cut -c1-240)"
        PHASE_FAILURES=$((PHASE_FAILURES + 1))
    fi
fi

# --- E7: a SIGUSR1 the agent sends itself is not a tripwire breach -------------
# PID 1 runs as uid 1001, like the agent, so the agent can send it the tripwire's
# signal. Exit 99 stays (fail closed), but nothing may claim the canary tripwire
# fired or point at an incident report that no monitor wrote.
printf '\n'
info "E7: a SIGUSR1 from the agent itself must not be reported as a tripwire breach"
E7_WS="${PROJECT_ROOT}/workspaces/.verify-e7-$$"
mkdir -p "$E7_WS"; chmod 0777 "$E7_WS" 2>/dev/null || true
e7_out="$(NO_COLOR=1 "${SCRIPT_DIR}/warden-cli.sh" run "$E7_WS" bash -- -c 'kill -USR1 1; sleep 3' 2>&1)"
e7_rc=$?
e7_reports="$(find "$E7_WS" -maxdepth 1 -name 'WARDEN_SECURITY_INCIDENT*.json' 2>/dev/null | wc -l | tr -d ' ')"
rmdir "${E7_WS}/.secrets" 2>/dev/null || true
rm -rf "$E7_WS" 2>/dev/null || true
if [ "$e7_rc" -eq 99 ] && [ "$e7_reports" = "0" ] \
   && printf '%s' "$e7_out" | grep -q 'no breach record found' \
   && printf '%s' "$e7_out" | grep -q 'NO incident report' \
   && printf '%s' "$e7_out" | grep -q "The sentinel (outside the agent's reach) recorded no breach" \
   && ! printf '%s' "$e7_out" | grep -q 'Confirmed by the sentinel' \
   && ! printf '%s' "$e7_out" | grep -qE 'SIGUSR1 received from the canary tripwire|the canary tripwire terminated this sandbox'; then
    good "phase E7: a self-sent SIGUSR1 still ends the session (99) but is reported as unrecorded, not as a tripwire breach"
else
    bad  "phase E7: rc=${e7_rc} reports=${e7_reports} - $(printf '%s' "$e7_out" | grep -E 'SIGUSR1|tripwire|incident report' | tr '\n' ' ' | cut -c1-240)"
    PHASE_FAILURES=$((PHASE_FAILURES + 1))
fi

# --- E8: doctor must not pass a check it could not measure ---------------------
# setup-host.sh printed "sufficient free disk space" whenever df gave no number.
# A df that fails is put first on PATH (and proven to be the one that runs).
printf '\n'
info "E8: doctor must not report a disk check it could not measure as passed"
E8_BIN="$(mktemp -d)"
printf '#!/bin/sh\necho "df: simulated failure" >&2\nexit 1\n' > "${E8_BIN}/df"
chmod +x "${E8_BIN}/df"
e8_live="$(PATH="${E8_BIN}:$PATH" command -v df)"
e8_out="$(PATH="${E8_BIN}:$PATH" NO_COLOR=1 "${SCRIPT_DIR}/setup-host.sh" 2>&1)"
rm -rf "$E8_BIN" 2>/dev/null || true
if [ "$e8_live" != "${E8_BIN}/df" ]; then
    bad  "phase E8: the failing df shim was not the df on PATH (${e8_live}) - drill proves nothing"
    PHASE_FAILURES=$((PHASE_FAILURES + 1))
elif ! printf '%s' "$e8_out" | grep -q '^Summary'; then
    # Found by this drill: under set -euo pipefail the failing df killed the
    # whole doctor right there - no posture checks, no summary, just rc=1.
    bad  "phase E8: doctor died at the disk check (no Summary) - every later check silently skipped"
    PHASE_FAILURES=$((PHASE_FAILURES + 1))
elif printf '%s' "$e8_out" | grep -q 'sufficient free disk space'; then
    bad  "phase E8: doctor passed the disk check although df returned nothing"
    PHASE_FAILURES=$((PHASE_FAILURES + 1))
elif printf '%s' "$e8_out" | grep -q 'could not measure free disk space'; then
    good "phase E8: with df failing, doctor says it could not measure disk space instead of passing it"
else
    bad  "phase E8: doctor said nothing about disk space: $(printf '%s' "$e8_out" | grep -i disk | tr '\n' ' ' | cut -c1-160)"
    PHASE_FAILURES=$((PHASE_FAILURES + 1))
fi

# =============================================================================
printf '\n%s=========== PHASE F: runtime fail-closed (gVisor plumbing) ==========%s\n' "$C_BOLD" "$C_RESET"
# =============================================================================
# WARDEN_RUNTIME lets a deployment run the sandbox under gVisor (runsc) or Kata.
# The failure to guard against is a --runtime that silently downgrades to runc
# when the requested runtime is missing: it would report itself hardened while
# enforcing nothing. So the guard must refuse an unavailable runtime, not fall back.
info "WARDEN_RUNTIME must be honoured or refused, never silently downgraded to runc"
printf '\n'

# F-func: assert_runtime() fails closed on a bogus runtime, accepts a valid one,
# forces nothing when unset. Sourced in a CHILD bash so warden-cli.sh's own
# `set -e`/readonly vars cannot leak into this suite (the phase-D lesson).
f_out="$(CLI="${SCRIPT_DIR}/warden-cli.sh" bash -c '
    . "$CLI"; set +eu; f=0
    if ( assert_runtime "warden-nonexistent-runtime" ) >/dev/null 2>&1; then echo "BOGUS-ACCEPTED"; f=$((f+1)); fi
    if ! assert_runtime "" >/dev/null 2>&1 || [ -n "$RESOLVED_RUNTIME" ]; then echo "EMPTY-BROKEN"; f=$((f+1)); fi
    if ! assert_runtime "runc" >/dev/null 2>&1 || [ "$RESOLVED_RUNTIME" != "runc" ]; then echo "RUNC-BROKEN"; f=$((f+1)); fi
    echo "FFAILS=$f"; exit $f' 2>&1)"
f_func_rc=$?
if [ "$f_func_rc" -eq 0 ]; then
    good "phase F: assert_runtime refuses an unknown runtime and accepts a valid one"
else
    bad  "phase F: assert_runtime is not fail-closed"
    note "         $(printf '%s' "$f_out" | grep -vE '^FFAILS' | tr '\n' ' ')"
    PHASE_FAILURES=$((PHASE_FAILURES + 1))
fi

# F-reflect: Docker actually applies and RECORDS the runtime it is handed.
# HostConfig.Runtime is the authority - it is what the container ran under - and
# it is how the wiring below could be caught silently ignoring the flag.
docker rm -f warden-verify-rt >/dev/null 2>&1 || true
docker run -d --name warden-verify-rt --runtime runc --entrypoint sleep "$AGENT_IMAGE" 10 >/dev/null 2>&1
rt_seen="$(docker inspect --format '{{.HostConfig.Runtime}}' warden-verify-rt 2>/dev/null || echo '?')"
docker rm -f warden-verify-rt >/dev/null 2>&1 || true
if [ "$rt_seen" = "runc" ]; then
    good "phase F: Docker records the runtime it is handed (HostConfig.Runtime=runc)"
else
    bad  "phase F: HostConfig.Runtime did not reflect --runtime (got '${rt_seen}')"
    PHASE_FAILURES=$((PHASE_FAILURES + 1))
fi

# F-e2e: the CLI itself must refuse an unavailable runtime and start NOTHING -
# not error out only after spinning up the proxy, and never fall through to runc.
RT_WS="${PROJECT_ROOT}/workspaces/.verify-rt-$$"
mkdir -p "$RT_WS"; chmod 0777 "$RT_WS" 2>/dev/null || true
WARDEN_RUNTIME="warden-nonexistent-runtime" NO_COLOR=1 \
    "${SCRIPT_DIR}/warden-cli.sh" run "$RT_WS" bash -c 'echo THIS MUST NOT RUN' >/dev/null 2>&1
rt_e2e_rc=$?
rt_ran="$(docker ps -aq --filter 'name=verify-rt' 2>/dev/null || true)"
[ -n "$rt_ran" ] && docker rm -f "$rt_ran" >/dev/null 2>&1
rm -rf "$RT_WS" 2>/dev/null || true
if [ "$rt_e2e_rc" -ne 0 ] && [ -z "$rt_ran" ]; then
    good "phase F: warden-cli refused an unavailable WARDEN_RUNTIME and started no sandbox"
else
    bad  "phase F: warden-cli did NOT fail closed (rc=${rt_e2e_rc}, leftover container='${rt_ran}')"
    PHASE_FAILURES=$((PHASE_FAILURES + 1))
fi

# F-passthrough: cmd_run must actually APPLY a valid non-default runtime to the
# agent - not just refuse bad ones. This is the silent-downgrade case: forget the
# `args+=(--runtime ...)` line and WARDEN_RUNTIME=runsc would run under runc with
# nothing to notice. runc can't prove it (it is the default anyway), so this uses
# runsc if present, else any other non-default runtime (e.g. nvidia) as a stand-in.
# Skips only where the daemon has no non-default runtime at all (some CI hosts).
alt_rt="$(docker info --format '{{range $k,$v := .Runtimes}}{{$k}} {{end}}' 2>/dev/null \
          | tr ' ' '\n' | grep -vxE 'runc|io.containerd.runc.v2' | grep -v '^$' | head -1)"
if [ -n "$alt_rt" ]; then
    RTP_WS="${PROJECT_ROOT}/workspaces/.verify-rtp-$$"
    mkdir -p "$RTP_WS"; chmod 0777 "$RTP_WS" 2>/dev/null || true
    ( WARDEN_SENTINEL=0 WARDEN_REQUIRE_PROXY=0 WARDEN_RUNTIME="$alt_rt" NO_COLOR=1 \
        "${SCRIPT_DIR}/warden-cli.sh" run "$RTP_WS" bash -- -lc 'sleep 20' >/dev/null 2>&1 ) &
    rtp_bg=$!
    rtp_seen=""; waited=0
    while [ "$waited" -lt 30 ]; do
        cid="$(docker ps -q --filter 'label=ai.warden.role=agent-sandbox' --filter 'name=verify-rtp' 2>/dev/null | head -1)"
        if [ -n "$cid" ]; then
            rtp_seen="$(docker inspect --format '{{.HostConfig.Runtime}}' "$cid" 2>/dev/null || echo '?')"
            docker rm -f "$cid" >/dev/null 2>&1 || true
            break
        fi
        sleep 1; waited=$((waited + 1))
    done
    wait "$rtp_bg" 2>/dev/null || true
    docker rm -f "$(docker ps -aq --filter 'name=verify-rtp' 2>/dev/null)" >/dev/null 2>&1 || true
    rm -rf "$RTP_WS" 2>/dev/null || true
    if [ "$rtp_seen" = "$alt_rt" ]; then
        good "phase F: warden-cli applies WARDEN_RUNTIME end-to-end (agent HostConfig.Runtime=${alt_rt})"
    else
        bad  "phase F: WARDEN_RUNTIME=${alt_rt} was not applied to the agent (saw '${rtp_seen:-none}')"
        PHASE_FAILURES=$((PHASE_FAILURES + 1))
    fi
else
    note "phase F: no non-default runtime available - cmd_run passthrough not exercised e2e (fail-closed + reflect still cover it)"
fi

# =============================================================================
printf '\n%s================= PHASE G: agent launch (codex) ==================%s\n' "$C_BOLD" "$C_RESET"
# =============================================================================
# `warden-cli.sh run <ws> codex` used to hand the user a codex that could do
# nothing, while looking fine:
#   - codex 0.154 ignores OPENAI_API_KEY in the environment ("Not logged in",
#     then 401 retry loops against api.openai.com), and
#   - its own sandbox needs bubblewrap, which the image does not have and which
#     could not create namespaces under cap-drop=ALL anyway: every shell command
#     failed "due to sandbox permissions" while `codex exec` still exited 0.
# The launcher must log codex in from OPENAI_API_KEY (read from the environment,
# never argv) and run it with sandbox_mode=danger-full-access, because AI Warden
# is the sandbox. Checked with a FAKE key: `codex login --with-api-key` does not
# call the API, so this phase spends nothing and needs no secret in CI.
G_WS="${PROJECT_ROOT}/workspaces/.verify-codex-$$"
mkdir -p "$G_WS"; chmod 0777 "$G_WS" 2>/dev/null || true
g_out="$(OPENAI_API_KEY="sk-warden-drill-not-a-real-key-0000000000" NO_COLOR=1 \
    "${SCRIPT_DIR}/warden-cli.sh" run "$G_WS" codex -- login status 2>&1)"
g_rc=$?
rmdir "${G_WS}/.secrets" 2>/dev/null || true
rm -rf "$G_WS" 2>/dev/null || true
g_logged_in=0; g_sandbox=0
if printf '%s' "$g_out" | grep -q 'Logged in using an API key'; then g_logged_in=1; fi
if printf '%s' "$g_out" | grep -q 'launching agent .*sandbox_mode="danger-full-access"'; then g_sandbox=1; fi
if [ "$g_rc" -eq 0 ] && [ "$g_logged_in" = "1" ] && [ "$g_sandbox" = "1" ]; then
    good "phase G: warden-cli logs codex in from OPENAI_API_KEY and launches it with sandbox_mode=danger-full-access"
else
    bad  "phase G: codex launch is not usable (rc=${g_rc}, logged_in=${g_logged_in}, sandbox_off=${g_sandbox})"
    note "         $(printf '%s' "$g_out" | grep -E 'launching agent|Not logged in|Logged in' | sed -E 's/sk-[A-Za-z0-9_*-]+/sk-REDACTED/g' | tr '\n' ' ' | cut -c1-300)"
    PHASE_FAILURES=$((PHASE_FAILURES + 1))
fi

# =============================================================================
printf '\n%s================= PHASE H: egress audit trail ====================%s\n' "$C_BOLD" "$C_RESET"
# =============================================================================
# `docker logs warden-egress-proxy` is the egress audit trail. An unclean Docker
# shutdown can leave NUL bytes in the proxy's json log file; from then on
# `docker logs` silently returns nothing new while squid keeps writing (found
# 2026-09-26: this box's trail had been empty for 10 days - 519 NULs after
# 2026-09-16 16:01 UTC). `docker restart` does not help; the file survives it.
# `warden-cli.sh up` must prove the trail is live, recreate the proxy when it is
# not, and refuse - not recreate - while sandboxes are using the proxy.
info "a silently dead egress audit trail must be detected and healed, never trusted"
printf '\n'

PROXY_C="warden-egress-proxy"
# Reproduce the corruption: append NULs to the proxy's own json log, as root,
# from a helper container that mounts the log directory (works on Docker Desktop,
# where the path is inside the VM, and on a Linux host alike).
h_corrupt() {
    local lp; lp="$(docker inspect -f '{{.LogPath}}' "$PROXY_C" 2>/dev/null || true)"
    [ -n "$lp" ] || return 1
    docker run --rm --user 0:0 --network none -v "$(dirname "$lp"):/logdir" \
        --entrypoint sh "$AGENT_IMAGE" -c \
        'head -c 519 /dev/zero >> "/logdir/$1" && printf "\n\n" >> "/logdir/$1"' h "$(basename "$lp")" \
        >/dev/null 2>&1
}
# The trail is live iff a line written to the proxy's stderr comes back from
# `docker logs`. Written here directly, independent of the CLI under test.
h_live() {
    local nonce="verify-h-probe-$$-${RANDOM}${RANDOM}"
    docker exec "$PROXY_C" sh -c 'printf "[verify] %s\n" "$0" > /proc/1/fd/2' "$nonce" >/dev/null 2>&1 || return 1
    for _ in 1 2 3 4 5; do
        if docker logs --since 60s "$PROXY_C" 2>&1 | grep -qF "$nonce"; then return 0; fi
        sleep 1
    done
    return 1
}
h_id() { docker inspect -f '{{.Id}}' "$PROXY_C" 2>/dev/null || true; }

if [ "$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$PROXY_C" 2>/dev/null)" != "json-file" ]; then
    note "phase H: the proxy does not use the json-file log driver here - drill skipped"
else
    # H-precondition: the drill's own corruption must actually kill the trail,
    # or a "healed" verdict below would prove nothing.
    "${SCRIPT_DIR}/warden-cli.sh" up >/dev/null 2>&1
    h_corrupt
    if h_live; then
        bad  "phase H: corrupting the proxy log did not break docker logs - the drill has no teeth here"
        PHASE_FAILURES=$((PHASE_FAILURES + 1))
    else
        # H1: sandboxes are using the proxy -> refuse, do not recreate it under them.
        docker rm -f warden-verify-h-busy >/dev/null 2>&1 || true
        docker run -d --name warden-verify-h-busy --label ai.warden.role=agent-sandbox \
            --network none --entrypoint sleep "$AGENT_IMAGE" 120 >/dev/null 2>&1
        h_id_before="$(h_id)"
        NO_COLOR=1 "${SCRIPT_DIR}/warden-cli.sh" up >/dev/null 2>&1
        h1_rc=$?
        h1_same=0; if [ "$(h_id)" = "$h_id_before" ]; then h1_same=1; fi
        docker rm -f warden-verify-h-busy >/dev/null 2>&1 || true
        if [ "$h1_rc" -ne 0 ] && [ "$h1_same" = "1" ]; then
            good "phase H: with a sandbox running, 'up' refused a dead audit trail (rc=${h1_rc}) and left the proxy alone"
        else
            bad  "phase H: with a sandbox running, 'up' accepted a dead audit trail (rc=${h1_rc}, proxy_untouched=${h1_same})"
            PHASE_FAILURES=$((PHASE_FAILURES + 1))
        fi

        # H2: nothing running -> recreate the proxy and prove the new trail is live.
        h_id_before="$(h_id)"
        NO_COLOR=1 "${SCRIPT_DIR}/warden-cli.sh" up >/dev/null 2>&1
        h2_rc=$?
        h2_new=0; if [ -n "$(h_id)" ] && [ "$(h_id)" != "$h_id_before" ]; then h2_new=1; fi
        h2_live=0; if h_live; then h2_live=1; fi
        if [ "$h2_rc" -eq 0 ] && [ "$h2_new" = "1" ] && [ "$h2_live" = "1" ]; then
            good "phase H: 'up' detected the dead audit trail, recreated the proxy, and the new trail is live"
        else
            bad  "phase H: dead audit trail not healed (rc=${h2_rc}, recreated=${h2_new}, live=${h2_live})"
            PHASE_FAILURES=$((PHASE_FAILURES + 1))
        fi
    fi
    # Never leave the suite's host with a dead trail, whatever the verdict.
    if ! h_live; then
        docker rm -f "$PROXY_C" >/dev/null 2>&1 || true
        "${SCRIPT_DIR}/warden-cli.sh" up >/dev/null 2>&1 || true
    fi
fi

# =============================================================================
printf '\n%s============== PHASE I: local-model session (offline) ============%s\n' "$C_BOLD" "$C_RESET"
# =============================================================================
# WARDEN_MODEL_MANIFEST=<manifest.json> turns `run` into a local-model session:
# the agent and a llama.cpp server share a private internal network and nothing
# else - no proxy, no route out - and no cloud key is forwarded. Checks are keyed
# to the threats in .ai/design-local-model.md (M1-M6). The model is a tiny PUBLIC
# GGUF (1.2 MB, pinned sha256) so CI can run this without anyone's private model.
info "a local-model session must be offline, keyless, hardened and leave nothing behind"
printf '\n'

I_URL="https://huggingface.co/ggml-org/models/resolve/main/tinyllamas/stories260K.gguf"
I_SHA="270cba1bd5109f42d03350f60406024560464db173c0e387d91f0426d3bd256d"
I_CACHE="${PROJECT_ROOT}/workspaces/.verify-model-cache"
I_WS="${PROJECT_ROOT}/workspaces/.verify-local-$$"
I_NAME="warden-sbx-.verify-local-$$"
mkdir -p "$I_CACHE" "$I_WS"; chmod 0777 "$I_WS" 2>/dev/null || true
i_sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
if [ "$(i_sha "${I_CACHE}/stories260K.gguf")" != "$I_SHA" ]; then
    # Git Bash's curl is a native Windows program: with MSYS_NO_PATHCONV set it
    # cannot write to a /d/... path, so path conversion is re-enabled for it.
    env -u MSYS_NO_PATHCONV -u MSYS2_ARG_CONV_EXCL         curl -sfL --retry 3 --max-time 120 -o "${I_CACHE}/stories260K.gguf" "$I_URL" || true
fi
i_leftovers() {  # containers or networks a session with this workspace left behind
    docker ps -aq --filter "name=verify-local-$$" 2>/dev/null
    docker network ls -q --filter "name=verify-local-$$" 2>/dev/null
}
i_fail() { bad "phase I: $*"; PHASE_FAILURES=$((PHASE_FAILURES + 1)); }

# I/M0: the entrypoint's offline posture is CHECKED, not assumed. Raw docker, so
# this proves the image, independent of how the CLI wires it.
docker run --rm --network "$INTERNAL_NET" --user 1001:1001 --cap-drop=ALL \
    --security-opt no-new-privileges:true --memory 1g --pids-limit 128 \
    --tmpfs "/run/warden:rw,nosuid,size=16m,uid=1001,gid=1001" \
    -e WARDEN_EGRESS=none --name warden-verify-i0 "$AGENT_IMAGE" \
    bash -c 'echo "this must never run"' >/dev/null 2>&1
i0a=$?
docker network rm warden-verify-i0-net >/dev/null 2>&1 || true
docker network create --internal warden-verify-i0-net >/dev/null 2>&1
i0b_out="$(docker run --rm --network warden-verify-i0-net --user 1001:1001 --cap-drop=ALL \
    --security-opt no-new-privileges:true --memory 1g --pids-limit 128 \
    --tmpfs "/run/warden:rw,nosuid,size=16m,uid=1001,gid=1001" \
    -e WARDEN_EGRESS=none --name warden-verify-i0 "$AGENT_IMAGE" \
    bash -c 'echo OFFLINE-SESSION-RAN' 2>&1)"
i0b=$?
docker network rm warden-verify-i0-net >/dev/null 2>&1 || true
if [ "$i0a" -eq 78 ]; then
    good "phase I (M0): WARDEN_EGRESS=none on a network that reaches the proxy refused to start (78)"
else
    i_fail "(M0) an 'offline' session that can reach the proxy was not refused (rc=${i0a})"
fi
if [ "$i0b" -eq 0 ] && printf '%s' "$i0b_out" | grep -q 'OFFLINE-SESSION-RAN' \
   && printf '%s' "$i0b_out" | grep -q 'egress             : none'; then
    good "phase I (M0): a truly offline session starts and says so (egress: none)"
else
    i_fail "(M0) a truly offline session did not start cleanly (rc=${i0b})"
    note "         $(printf '%s' "$i0b_out" | grep -E 'FATAL|egress' | tr '\n' ' ' | cut -c1-240)"
fi

if [ "$(i_sha "${I_CACHE}/stories260K.gguf")" != "$I_SHA" ]; then
    i_fail "could not fetch the pinned test model (${I_URL}) - CLI checks not run"
else
    printf '{"schema": "warden-model-lab/manifest/1", "model_name": "verify-tiny", "gguf_file": "stories260K.gguf", "gguf_sha256": "%s"}\n' \
        "$I_SHA" > "${I_CACHE}/manifest.json"

    # I/M1 M3 M4 M6 + e2e: one real session through the CLI. Fake cloud keys are
    # exported on purpose: none of them may reach the agent (M3).
    i_probe='
        r() { if timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null; then echo reachable; else echo unreachable; fi; }
        echo "I-proxy=$(r warden-egress-proxy 3128)"
        echo "I-direct=$(r 1.1.1.1 443)"
        echo "I-keys=${OPENAI_API_KEY:-}|${ANTHROPIC_API_KEY:-}|${GEMINI_API_KEY:-}"
        c() { curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X "$1" "http://warden-model:8080$2" -H "Content-Type: application/json" -d "{}"; }
        echo "I-ep=root:$(c GET /) slots:$(c GET /slots) props:$(c POST /props)"
        echo "I-chat=$(curl -s -o /dev/null -w "%{http_code}" --max-time 60 http://warden-model:8080/v1/chat/completions -H "Content-Type: application/json" -d "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":8}")"
        sleep 6'
    ( OPENAI_API_KEY="sk-warden-drill-openai-not-real" ANTHROPIC_API_KEY="sk-ant-warden-drill-not-real" \
      GEMINI_API_KEY="warden-drill-gemini-not-real" WARDEN_MODEL_MANIFEST="${I_CACHE}/manifest.json" NO_COLOR=1 \
        "${SCRIPT_DIR}/warden-cli.sh" run "$I_WS" bash -- -c "$i_probe" > "${I_CACHE}/run1.log" 2>&1
      echo "$?" > "${I_CACHE}/run1.rc" ) &
    i_bg=$!
    i_model=""; waited=0
    while [ "$waited" -lt 90 ] && [ -z "$i_model" ]; do
        i_model="$(docker ps -q --filter 'label=ai.warden.role=model-server' --filter "label=ai.warden.agent=${I_NAME}" 2>/dev/null | head -1)"
        sleep 1; waited=$((waited + 1))
    done
    i_hard=""; i_mnet=""
    if [ -n "$i_model" ]; then
        # M6: least privilege, from Docker's record and from the kernel's.
        i_hard="$(docker inspect -f 'user={{.Config.User}} ro={{.HostConfig.ReadonlyRootfs}} capadd={{.HostConfig.CapAdd}} capdrop={{.HostConfig.CapDrop}} sec={{.HostConfig.SecurityOpt}}' "$i_model" 2>/dev/null)"
        i_hard="${i_hard} $(docker exec "$i_model" sh -c 'grep -E "^(CapEff|NoNewPrivs):" /proc/1/status | sed -E "s/:[[:space:]]+/=/" | tr "\n" " "' 2>/dev/null)"
        # M1: the model container itself has no way out either.
        i_mnet="$(docker exec "$i_model" sh -c 'for t in warden-egress-proxy:3128 1.1.1.1:443; do if curl -s -o /dev/null --max-time 3 "http://$t"; then echo "$t=reachable"; else echo "$t=unreachable"; fi; done' 2>/dev/null | tr '\n' ' ')"
    fi
    wait "$i_bg" 2>/dev/null || true
    i1_rc="$(cat "${I_CACHE}/run1.rc" 2>/dev/null || echo '?')"
    i1_out="$(cat "${I_CACHE}/run1.log" 2>/dev/null)"
    i1_left="$(i_leftovers)"

    if [ -z "$i_model" ]; then
        i_fail "no model container ever appeared for the session (rc=${i1_rc})"
        note "         $(printf '%s' "$i1_out" | grep -E 'fail|FATAL|refus' | tr '\n' ' ' | cut -c1-240)"
    else
        if printf '%s' "$i1_out" | grep -q 'I-proxy=unreachable' && printf '%s' "$i1_out" | grep -q 'I-direct=unreachable' \
           && [ "$i_mnet" = "warden-egress-proxy:3128=unreachable 1.1.1.1:443=unreachable " ]; then
            good "phase I (M1): agent and model are offline - neither reaches the proxy nor the internet"
        else
            i_fail "(M1) the session is not offline: agent=[$(printf '%s' "$i1_out" | grep -E '^I-(proxy|direct)=' | tr '\n' ' ')] model=[${i_mnet}]"
        fi
        # The only key inside is the CLI's inert placeholder (aider needs some value).
        if printf '%s' "$i1_out" | grep -qx 'I-keys=warden-local-no-key||'; then
            good "phase I (M3): no cloud API key reached the agent (host had three exported)"
        else
            i_fail "(M3) a cloud key reached the local-model session: $(printf '%s' "$i1_out" | grep '^I-keys=' | sed -E 's/(sk-[a-z-]*)[A-Za-z0-9_-]*/\1***/g')"
        fi
        if printf '%s' "$i1_out" | grep -q '^I-ep=root:404 slots:501 props:501'; then
            good "phase I (M4): the model server's web UI, /slots and POST /props are off"
        else
            i_fail "(M4) model server endpoints exposed: $(printf '%s' "$i1_out" | grep '^I-ep=')"
        fi
        case "$i_hard" in
            *"user=65534:65534 ro=true capadd=[] capdrop=[ALL] sec=[no-new-privileges:true]"*"CapEff=0000000000000000"*"NoNewPrivs=1"*)
                good "phase I (M6): model server runs as 65534, read-only, no capabilities, no-new-privileges" ;;
            *)  i_fail "(M6) model server hardening missing: ${i_hard}" ;;
        esac
        if printf '%s' "$i1_out" | grep -q '^I-chat=200'; then
            good "phase I: the agent reached the model over the private network (chat completion 200)"
        else
            i_fail "agent could not use the model: $(printf '%s' "$i1_out" | grep '^I-chat=')"
        fi
    fi
    # Only meaningful if a model container existed - otherwise "nothing left" is vacuous.
    if [ -n "$i_model" ] && [ "$i1_rc" = "0" ] && [ -z "$i1_left" ]; then
        good "phase I (M5): a clean session (exit 0) left no model container or network behind"
    else
        i_fail "(M5) after exit ${i1_rc} leftovers remain: $(printf '%s' "$i1_left" | tr '\n' ' ')"
    fi

    # M5 on the breach path: the tripwire still works offline, and cleanup still runs.
    if [ "$RUN_BREACH" = "1" ]; then
        i2_out="$(WARDEN_MODEL_MANIFEST="${I_CACHE}/manifest.json" NO_COLOR=1 \
            "${SCRIPT_DIR}/warden-cli.sh" run "$I_WS" bash -- -c 'cat /workspace/.secrets/credentials >/dev/null; sleep 20' 2>&1)"
        i2_rc=$?
        i2_left="$(i_leftovers)"
        rm -f "${I_WS}"/WARDEN_SECURITY_INCIDENT*.json 2>/dev/null || true
        # "Nothing left" only counts if the model really started (else it is vacuous).
        if [ "$i2_rc" -eq 99 ] && [ -z "$i2_left" ] && printf '%s' "$i2_out" | grep -q 'local model ready'; then
            good "phase I (M5): a breach in a local-model session exits 99 and leaves nothing behind"
        else
            i_fail "(M5) breach path: rc=${i2_rc}, leftovers: $(printf '%s' "$i2_left" | tr '\n' ' ')"
        fi
    else
        note "  SKIP phase I (M5): the breach path (--no-breach)"
    fi

    # M5 (visibility): a model server left behind by a hard-killed CLI (no trap ran)
    # keeps its RAM - and a GPU, in GPU mode. `status` must show it, flagged as
    # orphaned, instead of "none running". Created through the real start_model.
    i7_name="warden-sbx-.verify-orphan-$$"
    i7_cli() { CLI="${SCRIPT_DIR}/warden-cli.sh" MF="${I_CACHE}/stories260K.gguf" N="$i7_name" F="$1" \
        bash -c '. "$CLI"; set +eu; MODEL_FILE="$MF"; "$F" "$N"' >/dev/null 2>&1; }
    i7_cli start_model
    i7_seen="$(docker ps -q --filter 'label=ai.warden.role=model-server' --filter "label=ai.warden.agent=${i7_name}" 2>/dev/null)"
    i7_status="$(NO_COLOR=1 "${SCRIPT_DIR}/warden-cli.sh" status 2>&1)"
    i7_cli stop_model
    i7_left="$(docker ps -aq --filter "name=verify-orphan-$$" 2>/dev/null; docker network ls -q --filter "name=verify-orphan-$$" 2>/dev/null)"
    i7_line="$(printf '%s\n' "$i7_status" | grep -F "${i7_name}-model")"
    if [ -n "$i7_seen" ] && printf '%s' "$i7_line" | grep -q 'ORPHANED' && [ -z "$i7_left" ]; then
        good "phase I (M5): 'status' shows a model server orphaned by a hard-killed CLI (not 'none running')"
    else
        i_fail "(M5) orphaned model server: existed=$([ -n "$i7_seen" ] && echo yes || echo no), status line='${i7_line}', leftovers after cleanup: $(printf '%s' "$i7_left" | tr '\n' ' ')"
    fi

    # M2: one flipped byte in the model file -> refuse (78) before creating anything.
    cp "${I_CACHE}/stories260K.gguf" "${I_CACHE}/tampered.gguf"
    printf 'X' | dd of="${I_CACHE}/tampered.gguf" bs=1 seek=4096 conv=notrunc 2>/dev/null
    sed "s/stories260K.gguf/tampered.gguf/" "${I_CACHE}/manifest.json" > "${I_CACHE}/tampered.json"
    WARDEN_MODEL_MANIFEST="${I_CACHE}/tampered.json" NO_COLOR=1 \
        "${SCRIPT_DIR}/warden-cli.sh" run "$I_WS" bash -- -c 'echo THIS MUST NOT RUN' >/dev/null 2>&1
    i3_rc=$?
    i3_left="$(i_leftovers)"
    if [ "$i3_rc" -eq 78 ] && [ -z "$i3_left" ]; then
        good "phase I (M2): a model file that does not match its manifest sha256 was refused (78), nothing started"
    else
        i_fail "(M2) tampered model: rc=${i3_rc}, leftovers: $(printf '%s' "$i3_left" | tr '\n' ' ')"
    fi

    # M2b: a manifest INSIDE the workspace is refused - the agent could rewrite
    # the model and its hash together, which would make the sha256 check a lie.
    mkdir -p "${I_WS}/model"
    cp "${I_CACHE}/stories260K.gguf" "${I_CACHE}/manifest.json" "${I_WS}/model/"
    WARDEN_MODEL_MANIFEST="${I_WS}/model/manifest.json" NO_COLOR=1         "${SCRIPT_DIR}/warden-cli.sh" run "$I_WS" bash -- -c 'echo THIS MUST NOT RUN' >/dev/null 2>&1
    i6_rc=$?
    i6_left="$(i_leftovers)"
    rm -rf "${I_WS}/model"
    if [ "$i6_rc" -eq 78 ] && [ -z "$i6_left" ]; then
        good "phase I (M2): a model manifest inside the workspace (agent-writable) was refused (78)"
    else
        i_fail "(M2) manifest inside the workspace: rc=${i6_rc}, leftovers: $(printf '%s' "$i6_left" | tr '\n' ' ')"
    fi

    # aider-local: wired to the local server, and refused without a manifest.
    i4_out="$(WARDEN_MODEL_MANIFEST="${I_CACHE}/manifest.json" NO_COLOR=1 \
        "${SCRIPT_DIR}/warden-cli.sh" run "$I_WS" aider-local -- --version 2>&1)"
    i4_rc=$?
    ( unset WARDEN_MODEL_MANIFEST; NO_COLOR=1 "${SCRIPT_DIR}/warden-cli.sh" run "$I_WS" aider-local -- --version >/dev/null 2>&1 )
    i5_rc=$?
    i5_left="$(i_leftovers)"
    i4_wired=0
    if printf '%s' "$i4_out" | grep -q 'launching agent .*aider .*--openai-api-base http://warden-model:8080/v1'; then i4_wired=1; fi
    if [ "$i4_rc" -eq 0 ] && [ "$i4_wired" = "1" ] && [ "$i5_rc" -ne 0 ] && [ -z "$i5_left" ]; then
        good "phase I: aider-local launches aider against http://warden-model:8080/v1, and refuses without a manifest"
    else
        i_fail "aider-local wiring: with manifest rc=${i4_rc}, without rc=${i5_rc}"
        note "         $(printf '%s' "$i4_out" | grep -E 'launching agent|fail' | tr '\n' ' ' | cut -c1-240)"
    fi

    # aider-local offline start: without metadata for the local alias, aider fetches
    # litellm's price list from GitHub on every start (a ProxyError offline). The
    # CLI hands it metadata instead. `--exit` builds the model and stops; the Model
    # line proves aider got that far. "Loaded model metadata from" is NOT proof - it
    # also lists aider's bundled file - so check the metadata aider holds for the
    # model: {} before the fix, the session's context size after it.
    i8_out="$(WARDEN_MODEL_MANIFEST="${I_CACHE}/manifest.json" NO_COLOR=1 \
        "${SCRIPT_DIR}/warden-cli.sh" run "$I_WS" aider-local -- --no-git --exit --verbose 2>&1)"
    i8_rc=$?
    if [ "$i8_rc" -eq 0 ] && printf '%s' "$i8_out" | grep -q '^Model: openai/warden-local' \
       && printf '%s' "$i8_out" | grep -q '"max_input_tokens": 8192' \
       && ! printf '%s' "$i8_out" | grep -q 'raw.githubusercontent.com'; then
        good "phase I: aider-local knows the local model (max_input_tokens 8192) and starts without a GitHub fetch"
    else
        i_fail "aider-local offline start: rc=${i8_rc} $(printf '%s' "$i8_out" | grep -E '^Model:|max_input_tokens|githubusercontent' | tr '\n' ' ' | cut -c1-240)"
    fi
    rm -f "${I_CACHE}/tampered.gguf" "${I_CACHE}/tampered.json" "${I_CACHE}"/run1.* 2>/dev/null || true
fi
rm -rf "$I_WS" 2>/dev/null || true

# =============================================================================
printf '\n%s============== PHASE J: GPU model server (opt-in) ================%s\n' "$C_BOLD" "$C_RESET"
# =============================================================================
# WARDEN_MODEL_GPU=1 serves the local model from llama.cpp's CUDA build with
# --gpus all. That build silently falls back to the CPU when it sees no usable
# GPU ("no usable GPU found, --gpu-layers option will be ignored") and still
# turns healthy - a "GPU session" that is not one. So GPU mode must be proven
# from the server's own load log, or refused. The GPU goes to the model server
# only, never to the agent (M7 in .ai/design-local-model.md). One side of this
# phase needs a GPU and the other needs none: each host runs the side it can
# and prints SKIP for the other (this box: GPU; CI: none).
info "WARDEN_MODEL_GPU=1 must be proven on the GPU or refused - never a silent CPU fallback"
printf '\n'
j_fail() { bad "phase J: $*"; PHASE_FAILURES=$((PHASE_FAILURES + 1)); }
J_WS="${PROJECT_ROOT}/workspaces/.verify-gpu-$$"
J_NAME="warden-sbx-.verify-gpu-$$"
mkdir -p "$J_WS"; chmod 0777 "$J_WS" 2>/dev/null || true
j_leftovers() {
    docker ps -aq --filter "name=verify-gpu-$$" 2>/dev/null
    docker network ls -q --filter "name=verify-gpu-$$" 2>/dev/null
}

# J-func: the offload verdict, fed lines that real b10991 runs printed (a full
# offload on the RTX 3050, and the CUDA image started without --gpus).
j_out="$(CLI="${SCRIPT_DIR}/warden-cli.sh" bash -c '
    . "$CLI"; set +eu; f=0
    full="0.29.417.930 I load_tensors: offloaded 29/29 layers to GPU"
    nogpu="warning: no usable GPU found, --gpu-layers option will be ignored"
    cpu="0.00.058.319 I load_tensors:   CPU_Mapped model buffer size =     1.12 MiB"
    v="$(gpu_offload_verdict "$full" 2>/dev/null)"
    if [ "$v" != "29/29" ]; then echo "FULL-OFFLOAD-REJECTED(${v})"; f=$((f+1)); fi
    for case in "${nogpu}
${cpu}" "load_tensors: offloaded 20/29 layers to GPU" "load_tensors: offloaded 0/29 layers to GPU" \
                "${full}
${nogpu}" ""; do
        if gpu_offload_verdict "$case" >/dev/null 2>&1; then
            echo "ACCEPTED[$(printf "%s" "$case" | tr "\n" "|" | cut -c1-70)]"; f=$((f+1))
        fi
    done
    echo "JFAILS=$f"; exit $f' 2>&1)"
j_func_rc=$?
if [ "$j_func_rc" -eq 0 ]; then
    good "phase J: the offload verdict accepts a full GPU offload and rejects CPU fallback, partial and zero offload"
else
    j_fail "offload verdict is wrong: $(printf '%s' "$j_out" | grep -E 'REJECTED|ACCEPTED|not found' | tr '\n' ' ' | cut -c1-240)"
fi

# J-cfg: GPU is for local-model sessions only, and only 0/1 is accepted.
j_cfg1="$(WARDEN_MODEL_GPU=1 NO_COLOR=1 "${SCRIPT_DIR}/warden-cli.sh" run "$J_WS" bash -- -c 'echo THIS MUST NOT RUN' 2>&1)"
j_cfg1_rc=$?
j_cfg2="$(WARDEN_MODEL_GPU=yes WARDEN_MODEL_MANIFEST="${I_CACHE}/manifest.json" NO_COLOR=1 \
    "${SCRIPT_DIR}/warden-cli.sh" run "$J_WS" bash -- -c 'echo THIS MUST NOT RUN' 2>&1)"
j_cfg2_rc=$?
j_cfg_left="$(j_leftovers)"
if [ "$j_cfg1_rc" -ne 0 ] && printf '%s' "$j_cfg1" | grep -q 'WARDEN_MODEL_GPU=1 needs a local model' \
   && [ "$j_cfg2_rc" -ne 0 ] && printf '%s' "$j_cfg2" | grep -q 'WARDEN_MODEL_GPU must be 0 or 1' \
   && ! printf '%s%s' "$j_cfg1" "$j_cfg2" | grep -q 'THIS MUST NOT RUN' && [ -z "$j_cfg_left" ]; then
    good "phase J: WARDEN_MODEL_GPU without a local model, or not 0/1, is refused before anything starts"
else
    j_fail "config guard: no-manifest rc=${j_cfg1_rc}, bad-value rc=${j_cfg2_rc}, leftovers: $(printf '%s' "$j_cfg_left" | tr '\n' ' ')"
    note "         $(printf '%s\n%s' "$j_cfg1" "$j_cfg2" | grep -E 'fail|refus|RUN' | tr '\n' ' ' | cut -c1-240)"
fi

j_gpu=0
if docker run --rm --gpus all --network none --entrypoint true "$AGENT_IMAGE" >/dev/null 2>&1; then j_gpu=1; fi

if [ "$(i_sha "${I_CACHE}/stories260K.gguf")" != "$I_SHA" ] || [ ! -f "${I_CACHE}/manifest.json" ]; then
    j_fail "the pinned test model from phase I is missing - GPU session checks not run"
elif [ "$j_gpu" = "0" ]; then
    # J-refuse: no GPU -> refuse up front (before pulling the CUDA image), start nothing.
    j2_out="$(WARDEN_MODEL_GPU=1 WARDEN_MODEL_MANIFEST="${I_CACHE}/manifest.json" NO_COLOR=1 \
        "${SCRIPT_DIR}/warden-cli.sh" run "$J_WS" bash -- -c 'echo THIS MUST NOT RUN' 2>&1)"
    j2_rc=$?
    j2_left="$(j_leftovers)"
    if [ "$j2_rc" -ne 0 ] && printf '%s' "$j2_out" | grep -q 'no GPU is available to Docker' \
       && ! printf '%s' "$j2_out" | grep -q 'THIS MUST NOT RUN' && [ -z "$j2_left" ]; then
        good "phase J: WARDEN_MODEL_GPU=1 on a host with no GPU is refused, nothing started"
    else
        j_fail "no-GPU host: rc=${j2_rc}, leftovers: $(printf '%s' "$j2_left" | tr '\n' ' ')"
        note "         $(printf '%s' "$j2_out" | grep -E 'fail|refus|ready|RUN' | tr '\n' ' ' | cut -c1-240)"
    fi
    note "  SKIP phase J: the GPU session itself (this host has no GPU for Docker)"
else
    # J-gpu: a real GPU session through the CLI, inspected while it runs.
    j_probe='
        r() { if timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null; then echo reachable; else echo unreachable; fi; }
        echo "J-proxy=$(r warden-egress-proxy 3128) J-direct=$(r 1.1.1.1 443)"
        echo "J-chat=$(curl -s -o /dev/null -w "%{http_code}" --max-time 60 http://warden-model:8080/v1/chat/completions -H "Content-Type: application/json" -d "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":8}")"
        sleep 6'
    ( WARDEN_MODEL_GPU=1 WARDEN_MODEL_MANIFEST="${I_CACHE}/manifest.json" NO_COLOR=1 \
        "${SCRIPT_DIR}/warden-cli.sh" run "$J_WS" bash -- -c "$j_probe" > "${I_CACHE}/gpu1.log" 2>&1
      echo "$?" > "${I_CACHE}/gpu1.rc" ) &
    j_bg=$!
    j_model=""; waited=0
    while [ "$waited" -lt 120 ] && [ -z "$j_model" ]; do
        j_model="$(docker ps -q --filter 'label=ai.warden.role=model-server' --filter "label=ai.warden.agent=${J_NAME}" 2>/dev/null | head -1)"
        sleep 1; waited=$((waited + 1))
    done
    j_mdev=""; j_adev=""; j_hard=""; j_mnet=""; j_status_line=""; waited=0
    if [ -n "$j_model" ]; then
        j_mdev="$(docker inspect -f '{{.Config.Image}} {{range .HostConfig.DeviceRequests}}{{.Capabilities}}{{end}}' "$j_model" 2>/dev/null)"
        j_hard="$(docker inspect -f 'user={{.Config.User}} ro={{.HostConfig.ReadonlyRootfs}} capadd={{.HostConfig.CapAdd}} capdrop={{.HostConfig.CapDrop}} sec={{.HostConfig.SecurityOpt}}' "$j_model" 2>/dev/null)"
        j_hard="${j_hard} $(docker exec "$j_model" sh -c 'grep -E "^(CapEff|NoNewPrivs):" /proc/1/status | sed -E "s/:[[:space:]]+/=/" | tr "\n" " "' 2>/dev/null)"
        j_mnet="$(docker exec "$j_model" sh -c 'for t in warden-egress-proxy:3128 1.1.1.1:443; do if curl -s -o /dev/null --max-time 3 "http://$t"; then echo "$t=reachable"; else echo "$t=unreachable"; fi; done' 2>/dev/null | tr '\n' ' ')"
        # The agent container appears after the model is ready; the GPU must not reach it.
        while [ "$waited" -lt 120 ] && [ -z "$j_adev" ]; do
            j_adev="$(docker inspect -f 'agent-devices=[{{range .HostConfig.DeviceRequests}}{{.Capabilities}}{{end}}]' "$J_NAME" 2>/dev/null)"
            sleep 1; waited=$((waited + 1))
        done
        # While the session runs, `status` must show the model server as GPU and tied
        # to its live sandbox (the orphaned case is phase I's).
        j_status_line="$(NO_COLOR=1 "${SCRIPT_DIR}/warden-cli.sh" status 2>&1 | grep -F "${J_NAME}-model")"
    fi
    wait "$j_bg" 2>/dev/null || true
    j1_rc="$(cat "${I_CACHE}/gpu1.rc" 2>/dev/null || echo '?')"
    j1_out="$(cat "${I_CACHE}/gpu1.log" 2>/dev/null)"
    j1_left="$(j_leftovers)"
    if [ -z "$j_model" ]; then
        j_fail "no GPU model container ever appeared (rc=${j1_rc})"
        note "         $(printf '%s' "$j1_out" | grep -E 'fail|FATAL|refus' | tr '\n' ' ' | cut -c1-240)"
    else
        case "$j_mdev" in
            *"llama.cpp@sha256:d4bdfe78ad26a1ef3ccc834fc4e4a106d882e0f2163dd9a06e067c580c742101 "*gpu*) ;;
            *) j_mdev="BAD ${j_mdev}" ;;
        esac
        if [ "${j_mdev#BAD }" = "$j_mdev" ] && printf '%s' "$j1_out" | grep -qE 'local model ready: .* on GPU \(offloaded ([0-9]+)/\1 layers\)'; then
            good "phase J: the model server runs the pinned CUDA image with a GPU and proved a full offload ($(printf '%s' "$j1_out" | grep -oE 'offloaded [0-9]+/[0-9]+' | head -1))"
        else
            j_fail "GPU session not proven: model=[${j_mdev}] cli=[$(printf '%s' "$j1_out" | grep -E 'local model ready|GPU' | tr '\n' ' ' | cut -c1-200)]"
        fi
        case "$j_status_line" in
            *GPU*"for ${J_NAME}"*) case "$j_status_line" in
                *ORPHANED*) j_fail "status calls a live GPU session's model server orphaned: '${j_status_line}'" ;;
                *) good "phase J: 'status' lists the running model server as GPU, tied to its sandbox" ;;
                esac ;;
            *) j_fail "status does not show the GPU model server of a running session: '${j_status_line}'" ;;
        esac
        if [ "$j_adev" = "agent-devices=[]" ]; then
            good "phase J (M7): the GPU is handed to the model server only - the agent container has no device request"
        else
            j_fail "(M7) agent container devices: '${j_adev}' (must be agent-devices=[])"
        fi
        case "$j_hard" in
            *"user=65534:65534 ro=true capadd=[] capdrop=[ALL] sec=[no-new-privileges:true]"*"CapEff=0000000000000000"*"NoNewPrivs=1"*)
                good "phase J (M6): the GPU model server keeps 65534, read-only, no capabilities, no-new-privileges" ;;
            *)  j_fail "(M6) GPU model server hardening missing: ${j_hard}" ;;
        esac
        if printf '%s' "$j1_out" | grep -q 'J-proxy=unreachable J-direct=unreachable' \
           && [ "$j_mnet" = "warden-egress-proxy:3128=unreachable 1.1.1.1:443=unreachable " ] \
           && printf '%s' "$j1_out" | grep -q '^J-chat=200'; then
            good "phase J (M1): a GPU session is still offline for agent and model, and the agent got an answer (200)"
        else
            j_fail "(M1) GPU session: agent=[$(printf '%s' "$j1_out" | grep -E '^J-' | tr '\n' ' ')] model=[${j_mnet}]"
        fi
    fi
    if [ -n "$j_model" ] && [ "$j1_rc" = "0" ] && [ -z "$j1_left" ]; then
        good "phase J (M5): the GPU session (exit 0) left no model container or network behind"
    else
        j_fail "(M5) GPU session exit ${j1_rc}, leftovers: $(printf '%s' "$j1_left" | tr '\n' ' ')"
    fi
    rm -f "${I_CACHE}"/gpu1.* 2>/dev/null || true
    note "  SKIP phase J: the no-GPU refusal (this host has a GPU; CI runs that side)"
fi
rm -rf "$J_WS" 2>/dev/null || true

# =============================================================================
printf '\n%s=========================== RESULT ==============================%s\n' "$C_BOLD" "$C_RESET"
if [ "$PHASE_FAILURES" -eq 0 ]; then
    printf '  %sAll phases passed. The sandbox is holding.%s\n\n' "$C_GREEN" "$C_RESET"
    exit 0
fi
printf '  %s%d phase(s) failed. Do NOT run an untrusted agent until this is fixed.%s\n\n' \
    "$C_RED" "$PHASE_FAILURES" "$C_RESET"
exit 1
