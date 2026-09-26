#!/usr/bin/env bash
# =============================================================================
#  AI Warden - Host CLI
# -----------------------------------------------------------------------------
#  The only supported way to launch an AI agent under AI Warden.
#
#    ./scripts/warden-cli.sh build
#    ./scripts/warden-cli.sh up
#    ./scripts/warden-cli.sh run ./my-project claude
#    ./scripts/warden-cli.sh run ./my-project aider -- --model sonnet
#    ./scripts/warden-cli.sh status
#    ./scripts/warden-cli.sh exec warden-sbx-my-project bash
#    ./scripts/warden-cli.sh stop
#    ./scripts/warden-cli.sh verify
#
#  SECRET HANDLING
#  API keys are never written into the image, never passed on the command line
#  and never appear in `ps`. `docker run -e NAME` (no "=value") copies the value
#  straight from this shell's environment into the container's environment; the
#  optional .env file is handed to the daemon with --env-file. Both vanish when
#  the container exits, because every sandbox runs with --rm.
# =============================================================================
set -euo pipefail

# Git Bash on Windows rewrites /workspace into a Windows path when it appears
# as a docker argument. Turn that off for every docker invocation.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

readonly WARDEN_VERSION="1.2.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT

readonly AGENT_IMAGE="ai-warden/agent:latest"
readonly PROXY_IMAGE="ai-warden/egress-proxy:latest"
readonly PROXY_CONTAINER="warden-egress-proxy"
readonly INTERNAL_NET="warden_internal"
readonly EXTERNAL_NET="warden_external"
readonly ENV_FILE="${PROJECT_ROOT}/.env"

# --- Defaults, overridable from .env or the environment ----------------------
WARDEN_MEMORY="${WARDEN_MEMORY:-4g}"
WARDEN_CPUS="${WARDEN_CPUS:-2}"
WARDEN_PIDS_LIMIT="${WARDEN_PIDS_LIMIT:-512}"
WARDEN_SENTINEL="${WARDEN_SENTINEL:-1}"
WARDEN_WORKSPACE_MODE="${WARDEN_WORKSPACE_MODE:-rw}"   # rw | ro
WARDEN_RUNTIME="${WARDEN_RUNTIME:-}"                   # empty = Docker default (runc); e.g. runsc for gVisor
# Local-model session: set per run, never read from .env - it changes what a
# session IS (offline, keyless), so it has to be asked for explicitly.
WARDEN_MODEL_MANIFEST="${WARDEN_MODEL_MANIFEST:-}"
WARDEN_MODEL_CTX="${WARDEN_MODEL_CTX:-8192}"
WARDEN_MODEL_MEMORY="${WARDEN_MODEL_MEMORY:-4g}"
# 1 = serve the local model on the GPU. Per run only, like the manifest: it hands
# the host's GPU driver to the model server (M7), so it is never a .env default.
WARDEN_MODEL_GPU="${WARDEN_MODEL_GPU:-0}"

# llama.cpp's OpenAI-compatible server, pinned by digest (never a floating tag).
# Both are build b10991: server-b10991 (CPU) and server-cuda-b10991 (GPU).
readonly MODEL_IMAGE="ghcr.io/ggml-org/llama.cpp@sha256:79903855d3de1689e9856219283591be12ba6f40a8e65fc7223824109446ad88"
readonly MODEL_IMAGE_CUDA="ghcr.io/ggml-org/llama.cpp@sha256:d4bdfe78ad26a1ef3ccc834fc4e4a106d882e0f2163dd9a06e067c580c742101"
readonly MODEL_ALIAS="warden-local"
readonly MODEL_URL="http://warden-model:8080/v1"
# aider's OpenAI client will not start without a key; this inert value is the
# only "key" a local-model session ever sees.
readonly MODEL_PLACEHOLDER_KEY="warden-local-no-key"

# --- Secrets that are forwarded by NAME only (never by value) ----------------
readonly FORWARDED_SECRETS=(
    ANTHROPIC_API_KEY
    OPENAI_API_KEY
    PERPLEXITY_API_KEY
    GEMINI_API_KEY
    GITHUB_TOKEN
    GIT_AUTHOR_NAME
    GIT_AUTHOR_EMAIL
)

# =============================================================================
#  Output helpers
# =============================================================================
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""
fi

info()  { printf '%s[warden]%s %s\n'  "$C_BLUE"  "$C_RESET" "$*" >&2; }
ok()    { printf '%s[  ok  ]%s %s\n'  "$C_GREEN" "$C_RESET" "$*" >&2; }
warn()  { printf '%s[ warn ]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%s[ fail ]%s %s\n'  "$C_RED"   "$C_RESET" "$*" >&2; exit 1; }
# Exit 78 like the entrypoint's posture refusal: a check failed, nothing started.
refuse() { printf '%s[refuse]%s %s\n' "$C_RED"   "$C_RESET" "$*" >&2; exit 78; }

# =============================================================================
#  Environment plumbing
# =============================================================================
load_env_file() {
    [ -f "$ENV_FILE" ] || return 0
    # Only used for warden's own tuning knobs. Secrets stay in the file and are
    # handed to the daemon with --env-file so they never enter this shell.
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            WARDEN_MEMORY|WARDEN_CPUS|WARDEN_PIDS_LIMIT|WARDEN_SENTINEL|WARDEN_WORKSPACE_MODE|WARDEN_RUNTIME|WARDEN_MODEL_CTX|WARDEN_MODEL_MEMORY)
                value="${value%\"}"; value="${value#\"}"
                if [ -n "$value" ]; then printf -v "$key" '%s' "$value"; fi
                ;;
        esac
    # Only WARDEN_* lines are read. Matching '^[A-Z_]+=' would pull every API
    # key in .env through this shell's variables, which contradicts the promise
    # at the top of this file - the daemon gets them straight from --env-file.
    done < <(grep -E '^WARDEN_[A-Z_]+=' "$ENV_FILE" 2>/dev/null || true)
}

docker_available() {
    command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"
    docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable. Start Docker Desktop / dockerd."
}

compose() {
    # MSYS_NO_PATHCONV is set globally so docker never mangles in-container
    # paths like /workspace. The flip side is that HOST paths must be converted
    # explicitly, or Git Bash's /d/... reaches the daemon as D:\d\...
    local dir file
    dir="$(host_path "$PROJECT_ROOT")"
    file="$(host_path "${PROJECT_ROOT}/docker-compose.yml")"
    if docker compose version >/dev/null 2>&1; then
        docker compose --project-directory "$dir" -f "$file" "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose --project-directory "$dir" -f "$file" "$@"
    else
        die "docker compose v2 is required (docker compose version)"
    fi
}

# Convert a POSIX path to whatever the local Docker daemon expects.
host_path() {
    local p="$1"
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            if command -v cygpath >/dev/null 2>&1; then
                cygpath -w "$p"
            else
                printf '%s' "$p"
            fi
            ;;
        *) printf '%s' "$p" ;;
    esac
}

# =============================================================================
#  Mount safety - the most important guard rail in this script
# =============================================================================
# Result is published in the global RESOLVED_MOUNT rather than on stdout, and
# the function is called directly rather than inside $(...).
#
# That is not a style preference. `die` ends with `exit 1`, and inside a command
# substitution that only kills the subshell: the caller would sail on with an
# empty path and every check here would be decorative. Calling it directly also
# gives the .ssh/.aws confirmation prompt a real terminal to read from.
RESOLVED_MOUNT=""
assert_safe_mount() {
    local abs="$1"
    RESOLVED_MOUNT=""
    [ -d "$abs" ] || die "not a directory: ${abs}"

    # Resolve two ways and check both. `pwd -P` follows every symlink (the real
    # inode we would hand the daemon); `pwd -L` keeps the logical name the user
    # typed. Both matter: on a usrmerge host `/bin` -> `/usr/bin`, so a check
    # against the physical path alone waves `/bin`, `/sbin`, `/lib` straight
    # through (their real path `/usr/bin` is not in the list, only `/usr` is).
    # Checking the logical name catches what the user actually asked for, and it
    # false-positives on nothing: a real project like `/var/www` has the same
    # value both ways and matches no rule.
    local real logical
    real="$(cd "$abs" && pwd -P)"
    logical="$(cd "$abs" && pwd -L)"
    local home; home="$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P || echo '/nonexistent')"

    # 1. Filesystem roots, system paths, and anything holding every user's data.
    #    /home and /Users are listed by name: $HOME is caught below, but mounting
    #    their parent would hand the agent every account on the machine.
    local candidate parent
    for candidate in "$real" "$logical"; do
        case "$candidate" in
            /|/root|/etc|/usr|/var|/boot|/dev|/proc|/sys|/bin|/sbin|/lib|/lib64|/opt|/srv|/run)
                die "refusing to mount system path: ${candidate}" ;;
            /home|/home/|/Users|/Users/|/media|/mnt|/mnt/|/run/media|/cygdrive)
                die "refusing to mount a shared parent of user data: ${candidate}" ;;
            /[a-z]|/[a-z]/|/[A-Z]|/[A-Z]/)
                die "refusing to mount a whole drive: ${candidate}" ;;
            /mnt/[a-z]|/mnt/[a-z]/|/mnt/[A-Z]|/mnt/[A-Z]/)
                die "refusing to mount a whole mounted drive: ${candidate}" ;;
        esac

        # A volume auto-mounted directly under /media, /run/media or /cygdrive is
        # a whole drive, not a project. The old `/media/*/` and `/cygdrive/*/`
        # patterns were dead code: `pwd` never yields a trailing slash, so they
        # could never match and a whole USB stick or Windows drive was mountable.
        # Match the drive root by its PARENT instead; a project folder nested
        # deeper (e.g. /media/usb/app) has a different parent and is still
        # allowed. /mnt keeps its single-letter rule above, because a hand-made
        # /mnt/project is a legitimate layout. (The udisks /media/<user>/<label>
        # form is one level deeper and is not covered here - see HANDOFF.)
        parent="$(dirname "$candidate")"
        case "$parent" in
            /media|/run/media|/cygdrive)
                die "refusing to mount what looks like a whole drive: ${candidate}" ;;
        esac
    done

    # 2. The user's home directory itself (a project *inside* it is fine).
    if [ "$real" = "$home" ]; then
        die "refusing to mount your entire home directory. Mount a single project folder."
    fi

    # 3. Anything that would drag credentials in.
    local danger
    for danger in .ssh .aws .azure .gnupg .kube .docker .config; do
        if [ -d "${real}/${danger}" ] && [ "$(basename "$real")" != "$(basename "$PROJECT_ROOT")" ]; then
            warn "the folder you are mounting contains ./${danger} - the agent will be able to read it"
            if [ -t 0 ]; then
                read -r -p "Continue anyway? [y/N] " reply
                case "$reply" in y|Y|yes|YES) ;; *) die "aborted by user" ;; esac
            else
                die "aborting: refusing to mount a folder containing ./${danger} non-interactively"
            fi
        fi
    done

    # 4. Do not hand the agent the warden source tree itself.
    if [ "$real" = "$PROJECT_ROOT" ]; then
        die "refusing to mount the AI Warden source tree into the sandbox it controls"
    fi

    RESOLVED_MOUNT="$real"
}

container_name_for() {
    local abs="$1"
    local base; base="$(basename "$abs")"
    # Docker names allow [a-zA-Z0-9][a-zA-Z0-9_.-]*
    base="$(printf '%s' "$base" | tr -c 'a-zA-Z0-9_.-' '-' | sed 's/^-*//;s/-*$//')"
    if [ -z "$base" ]; then base="workspace"; fi
    printf 'warden-sbx-%s' "$base"
}

# =============================================================================
#  Container runtime (optional gVisor / Kata hardening)
# -----------------------------------------------------------------------------
#  WARDEN_RUNTIME empty  -> Docker's default runtime (runc); nothing is forced.
#  WARDEN_RUNTIME=runsc  -> gVisor, if the daemon actually has it registered.
#
#  This must FAIL CLOSED. A `--runtime` that silently falls back to runc when the
#  requested runtime is missing is the exact failure this project exists to catch:
#  a control that reports itself armed (WARDEN_RUNTIME=runsc) while enforcing
#  nothing (still runc). So the runtime is verified against the daemon's own list
#  BEFORE any container is created, and a mismatch aborts rather than downgrades.
#  The result is published in RESOLVED_RUNTIME (empty = use the default).
# =============================================================================
RESOLVED_RUNTIME=""
assert_runtime() {
    RESOLVED_RUNTIME=""
    local want="${1:-}"
    if [ -z "$want" ]; then return 0; fi

    local available
    available="$(docker info --format '{{range $k,$v := .Runtimes}}{{$k}} {{end}}' 2>/dev/null || true)"
    case " ${available} " in
        *" ${want} "*)
            RESOLVED_RUNTIME="$want" ;;
        *)
            die "WARDEN_RUNTIME=${want} is not a runtime this Docker daemon knows about.
        Registered runtimes: ${available:-none}
        Install and register it (e.g. gVisor's runsc) or unset WARDEN_RUNTIME.
        Refusing to fall back to the default runtime silently." ;;
    esac
}

# =============================================================================
#  Sub-command: build
# =============================================================================
cmd_build() {
    docker_available
    local ctx; ctx="$(host_path "$PROJECT_ROOT")"

    # Extra args ("$@", e.g. --pull) are placed BEFORE the context and applied to
    # BOTH images. Docker options must precede the PATH, and a scheduled CVE gate
    # that rebuilds without --pull would reuse the cached base layers and silently
    # miss base-image drift - the whole point of the timer. (Previously "$@" was
    # appended after the context on the agent build only, so it reached neither
    # image reliably.)
    info "building egress proxy image (${PROXY_IMAGE})"
    docker build "$@" -f "$(host_path "${PROJECT_ROOT}/core/network/Dockerfile")" -t "$PROXY_IMAGE" "$ctx"
    ok "egress proxy built"

    info "building agent sandbox image (${AGENT_IMAGE}) - this pulls Node, Python and the agent CLIs"
    docker build "$@" -f "$(host_path "${PROJECT_ROOT}/core/Dockerfile")" -t "$AGENT_IMAGE" "$ctx"
    ok "agent sandbox built"

    docker image inspect "$AGENT_IMAGE" --format '{{.Config.User}} {{.Config.WorkingDir}}' >/dev/null
    ok "images ready. Next: ./scripts/warden-cli.sh up"
}

# =============================================================================
#  Sub-command: up / down  (the long-lived egress filter)
# =============================================================================
# The networks are created by `docker compose up`, never here.
#
# Compose refuses to adopt a network it did not create: an existing
# warden_internal made with `docker network create` has no
# com.docker.compose.network label, and compose aborts with "network was found
# but has incorrect label". So this only validates what is already there.
assert_networks_sane() {
    local net internal label
    for net in "$INTERNAL_NET" "$EXTERNAL_NET"; do
        docker network inspect "$net" >/dev/null 2>&1 || continue
        label="$(docker network inspect -f '{{index .Labels "com.docker.compose.network"}}' "$net" 2>/dev/null || true)"
        if [ -z "$label" ]; then
            die "network ${net} exists but was not created by compose.
        Remove it so compose can recreate it correctly:
            docker network rm ${net}"
        fi
    done

    if docker network inspect "$INTERNAL_NET" >/dev/null 2>&1; then
        internal="$(docker network inspect -f '{{.Internal}}' "$INTERNAL_NET")"
        if [ "$internal" != "true" ]; then
            die "network ${INTERNAL_NET} is NOT internal - the sandbox would have
        direct internet access. Remove it and let compose recreate it:
            docker network rm ${INTERNAL_NET}"
        fi
    fi
}

proxy_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$PROXY_CONTAINER" 2>/dev/null || echo false)" = "true" ]
}

wait_proxy_healthy() {
    local waited=0 health
    while [ "$waited" -lt 45 ]; do
        health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                  "$PROXY_CONTAINER" 2>/dev/null || echo unknown)"
        case "$health" in
            healthy|none) ok "egress proxy up (health=${health})"; return 0 ;;
            unhealthy)    die "egress proxy is unhealthy. Inspect with: $0 logs proxy" ;;
        esac
        sleep 1; waited=$((waited + 1))
    done
    die "egress proxy did not become healthy within 45s. Inspect with: $0 logs proxy"
}

# `docker logs warden-egress-proxy` is the egress audit trail, and it can die
# without a sound: an unclean Docker shutdown leaves NUL bytes in the json log
# file, after which `docker logs` returns nothing new while squid keeps writing
# (seen on Docker Desktop: ten days of egress missing, proxy healthy throughout).
# `docker restart` keeps the damaged file. So liveness is PROVEN, not assumed: a
# nonce written to the proxy's stderr must come back out of `docker logs`.
audit_trail_live() {
    local nonce="warden-audit-probe-$$-${RANDOM}${RANDOM}"
    docker exec "$PROXY_CONTAINER" sh -c 'printf "[warden-cli] audit trail probe %s\n" "$0" > /proc/1/fd/2' \
        "$nonce" >/dev/null 2>&1 || return 1
    for _ in 1 2 3 4 5; do
        if docker logs --since 60s "$PROXY_CONTAINER" 2>&1 | grep -qF "$nonce"; then return 0; fi
        sleep 1
    done
    return 1
}

# A dead trail is healed by recreating the proxy (a new container gets a new log
# file) - but only when no sandbox is using it, because recreation cuts every
# live session's egress. Otherwise refuse: egress would run unaudited.
assert_audit_trail() {
    if audit_trail_live; then
        ok "egress audit trail live (docker logs returned a fresh probe)"
        return 0
    fi
    local busy
    busy="$(docker ps -q --filter 'label=ai.warden.role=agent-sandbox' 2>/dev/null || true)"
    if [ -n "$busy" ]; then
        die "the egress audit trail is DEAD: 'docker logs ${PROXY_CONTAINER}' does not return
        what the proxy writes (usually a log file damaged by an unclean Docker shutdown).
        Sandboxes are using the proxy, so it was not recreated under them. Refusing to
        run with unaudited egress. Stop them ($0 stop), then run: $0 up"
    fi
    warn "the egress audit trail is DEAD: 'docker logs ${PROXY_CONTAINER}' does not return what the proxy writes (usually a log file damaged by an unclean Docker shutdown) - recreating the proxy"
    compose up -d --force-recreate warden-egress-proxy
    wait_proxy_healthy
    audit_trail_live \
        || die "the egress audit trail is still dead after recreating the proxy. Refusing to run with unaudited egress."
    ok "egress audit trail restored (proxy recreated with a fresh log)"
}

cmd_up() {
    docker_available
    assert_networks_sane
    if proxy_running; then
        ok "egress proxy already running"
    else
        info "starting egress allowlist proxy (compose also creates both networks)"
        compose up -d warden-egress-proxy
    fi
    wait_proxy_healthy
    assert_audit_trail
}

cmd_down() {
    docker_available
    info "stopping every warden sandbox"
    cmd_stop || true
    info "stopping egress proxy"
    compose down --remove-orphans || true
    ok "warden is down"
}

# =============================================================================
#  Sub-command: run
# =============================================================================
# codex needs two things done for it inside the sandbox, or it launches looking
# fine and can do nothing (both found by running it on codex-cli 0.154.0, and
# re-verified on 0.156.1 when v1.0.5 was built):
#   1. It ignores OPENAI_API_KEY in the environment ("Not logged in", then 401
#      retry loops). The key is piped from the environment into
#      `codex login --with-api-key` - never placed on argv, where the canary
#      monitor's /proc scan and `ps` would see it. The auth file lands in the
#      container's home and dies with the container (--rm).
#   2. Its own sandbox needs bubblewrap and user namespaces; under cap-drop=ALL
#      every shell command failed "due to sandbox permissions" while `codex exec`
#      still exited 0. AI Warden is the sandbox, so codex's is turned off
#      explicitly (sandbox_mode=danger-full-access) rather than left silently
#      broken. Its approval prompts are unaffected.
# Phase G of verify-isolation.sh checks both with a fake key.
CODEX_WRAPPER='if [ -n "${OPENAI_API_KEY:-}" ]; then printenv OPENAI_API_KEY | codex login --with-api-key >/dev/null 2>&1 || { echo "[warden] codex could not log in with OPENAI_API_KEY" >&2; exit 1; }; else echo "[warden] OPENAI_API_KEY is not set - codex will ask for a sign-in" >&2; fi; exec codex -c sandbox_mode="danger-full-access" "$@"'

# aider-local: with no metadata for a model, aider downloads litellm's price and
# context list from GitHub on every start - offline that is a ProxyError, and aider
# then knows neither the context size nor that the model is free. The wrapper
# writes metadata for the local alias (context = WARDEN_MODEL_CTX, cost 0) and
# passes it in, so aider skips the fetch. Phase I checks it with --exit --verbose.
AIDER_LOCAL_WRAPPER='c="${WARDEN_MODEL_CTX:-8192}"; m="${HOME}/.warden-local.model-metadata.json"; printf "{\"openai/%s\": {\"max_tokens\": %s, \"max_input_tokens\": %s, \"max_output_tokens\": %s, \"input_cost_per_token\": 0, \"output_cost_per_token\": 0, \"litellm_provider\": \"openai\", \"mode\": \"chat\"}}\n" "${WARDEN_MODEL_ALIAS:-warden-local}" "$c" "$c" "$((c / 4))" > "$m" || { echo "[warden] could not write aider model metadata to $m" >&2; exit 1; }; exec aider --model-metadata-file "$m" "$@"'

resolve_agent_cmd() {
    case "${1:-bash}" in
        claude)          printf '%s\n' claude ;;
        aider)           printf '%s\n' aider ;;
        aider-local)     printf '%s\n' bash -c "$AIDER_LOCAL_WRAPPER" aider --model "openai/${MODEL_ALIAS}" \
                             --openai-api-base "$MODEL_URL" \
                             --no-check-update --analytics-disable --no-show-model-warnings ;;
        codex)           printf '%s\n' bash -c "$CODEX_WRAPPER" codex ;;
        hermes)          printf '%s\n' hermes ;;
        bash|sh|shell)   printf '%s\n%s\n' bash -l ;;
        *)               printf '%s\n' "$1" ;;
    esac
}

# =============================================================================
#  The canary vault
# -----------------------------------------------------------------------------
#  A named Docker volume mounted at /workspace/.secrets, in BOTH the agent and
#  the sentinel.
#
#  Two problems are solved by the same mount:
#
#  1. Docker Desktop bind-mounts the workspace as 9p/virtiofs, where
#     inotify_add_watch() succeeds and no event is ever delivered. A named
#     volume lives on the VM's own ext4, so canaries in it are enforceable on
#     every platform. (A tmpfs also fixes that, but only for one container.)
#
#  2. A tmpfs belongs to a single mount namespace, so the sentinel could not see
#     it - the whole anti-tamper layer was inert wherever it was needed most. A
#     named volume is the same inode set in both containers, and inotify watches
#     inodes, so a read by the agent wakes the watcher in the sentinel.
#
#  Ownership needs no privileged setup: a fresh named volume inherits the owner
#  and mode of the image directory it is mounted over, and core/Dockerfile
#  ships /workspace/.secrets as 0770 ai_user:ai_user.
#
#  The vault is group-writable by ai_user (0770 ai_user:ai_user) and the
#  sentinel joins group 1001 with --group-add. That is what lets a sentinel
#  running with NO capabilities read the canaries: root without
#  CAP_DAC_OVERRIDE gets no permission bypass at all, and inotify_add_watch()
#  needs read access on the file. Ordinary Unix group permissions are the
#  least-privilege answer here; granting CAP_DAC_READ_SEARCH instead would let
#  the sentinel read every file in its container to solve the same problem.
# =============================================================================
vault_name_for() { printf '%s-vault' "$1"; }

ensure_vault() {
    local vault="$1"
    docker volume create --label ai.warden.role=canary-vault "$vault" >/dev/null \
        || { warn "could not create the canary vault volume"; return 1; }
}

remove_vault() {
    docker volume rm -f "$1" >/dev/null 2>&1 || true
}

# The sentinel runs as uid 0 with --cap-drop=ALL --cap-add=KILL, and that
# combination is deliberate rather than sloppy.
#
# Killing a process owned by another user requires CAP_KILL to be in the
# EFFECTIVE set. Docker's --cap-add only seeds the bounding set; a non-root
# process starts with an empty effective set and no way to raise it, and
# no-new-privileges rules out file capabilities as a workaround. A sentinel
# running as uid 1002 would therefore watch the breach happen and get EPERM.
#
# So it runs as root holding exactly one capability, in a container with no
# network, a read-only root filesystem, and no mount other than the workspace.
# The agent (uid 1001, zero capabilities) still cannot signal it, ptrace it, or
# reach it in any way - the PID namespace is shared, nothing else is.
start_sentinel() {
    local agent_container="$1" host_ws="$2" vault="$3"
    [ "$WARDEN_SENTINEL" = "1" ] || return 0

    local sentinel="${agent_container}-sentinel"
    docker rm -f "$sentinel" >/dev/null 2>&1 || true

    # Wait for the agent container to actually exist before joining its PID ns.
    local waited=0
    while [ "$waited" -lt 20 ]; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$agent_container" 2>/dev/null || echo false)" = "true" ]; then
            break
        fi
        sleep 0.5; waited=$((waited + 1))
    done

    # Match the agent's runtime so both live under the same isolation boundary.
    # NOTE: gVisor + a shared PID namespace (--pid container:) is UNTESTED (no
    # gVisor host available yet); see docs/THREAT_MODEL.md 4.1. Empty = default.
    local -a rt=()
    if [ -n "$RESOLVED_RUNTIME" ]; then rt=(--runtime "$RESOLVED_RUNTIME"); fi

    if docker run -d --rm \
        "${rt[@]}" \
        --name "$sentinel" \
        --network none \
        --pid "container:${agent_container}" \
        --user 0:0 \
        --group-add 1001 \
        --read-only \
        --tmpfs /tmp:rw,nosuid,size=16m \
        --cap-drop=ALL \
        --cap-add=KILL \
        --security-opt no-new-privileges:true \
        --memory 256m --pids-limit 64 \
        -e WARDEN_WORKSPACE=/workspace \
        --label ai.warden.role=canary-sentinel \
        --label "ai.warden.agent=${agent_container}" \
        -v "${host_ws}:/workspace" \
        -v "${vault}:/workspace/.secrets" \
        --entrypoint /opt/warden/venv/bin/python3 \
        "$AGENT_IMAGE" \
        /opt/warden/canary_monitor.py \
            --mode=sentinel --action=kill --target-uid=1001 \
            --run-dir=/tmp/warden --wait-for-canaries=45 \
            --wait-for-marker=/workspace/.secrets/.warden-seeded \
            --armed-marker=/workspace/.secrets/.warden-sentinel-armed \
            --canaries=/workspace/.secrets/credentials:/workspace/.secrets/id_rsa:/workspace/.secrets.canary:/workspace/secrets.json:/workspace/.env.vault \
        >/dev/null 2>&1
    then
        ok "canary sentinel attached (CAP_KILL only, no network, read-only rootfs)"
    else
        warn "could not start the out-of-band sentinel; the in-container tripwire is still armed"
    fi
}

stop_sentinel() {
    docker rm -f "${1}-sentinel" >/dev/null 2>&1 || true
}

# Incident reports in a workspace, one path per line, sorted (for comm).
incident_reports() {
    find "$1" -maxdepth 1 -name 'WARDEN_SECURITY_INCIDENT*.json' 2>/dev/null | LC_ALL=C sort
}

# Canaries in the bind-mounted workspace are removed from the HOST, after both
# the container and its sentinel are gone. Doing it inside the container would
# mean reading and unlinking watched files while the sentinel is still armed,
# which is exactly the pattern the sentinel exists to flag.
cleanup_workspace_canaries() {
    local ws="$1" f
    rmdir "${ws}/.secrets" 2>/dev/null || true
    for f in .secrets.canary secrets.json .env.vault; do
        if [ -f "${ws}/${f}" ] && grep -qs 'AI-WARDEN-CANARY' "${ws}/${f}"; then
            rm -f "${ws}/${f}" 2>/dev/null || true
        fi
    done
}

# =============================================================================
#  Local-model session (WARDEN_MODEL_MANIFEST)
# -----------------------------------------------------------------------------
#  The agent and a llama.cpp server share a private `internal` network and
#  nothing else: no proxy, no route out, so workspace code cannot leave the box
#  by construction. No cloud key is forwarded. The model file must match the
#  sha256 in its manifest (GGUF parsers have had memory-safety bugs), and the
#  manifest must live OUTSIDE the workspace - an agent that can rewrite both
#  the model and its manifest makes the hash check meaningless.
#  Design and threat model: .ai/design-local-model.md (M1-M7), drills: phase I.
# =============================================================================
MODEL_FILE=""
file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

verify_model_manifest() {
    local manifest="$1" workspace="$2" dir file sha actual
    [ -f "$manifest" ] || refuse "model manifest not found: ${manifest}"
    dir="$(cd "$(dirname "$manifest")" && pwd -P)"
    case "${dir}/" in
        "${workspace}/"*) refuse "the model manifest is inside the workspace (${dir}).
        The agent could rewrite both the model and its hash. Keep models outside it." ;;
    esac
    file="$(sed -n 's/.*"gguf_file"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -1)"
    sha="$(sed -n 's/.*"gguf_sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -1)"
    case "$file" in
        ""|*/*|*..*) refuse "manifest gguf_file must be a plain file name next to the manifest (got '${file}')" ;;
        *.gguf) ;;
        *) refuse "manifest gguf_file is not a .gguf file (got '${file}')" ;;
    esac
    printf '%s' "$sha" | grep -qxE '[0-9a-f]{64}' || refuse "manifest gguf_sha256 is not a sha256 (got '${sha}')"
    [ -f "${dir}/${file}" ] || refuse "model file not found: ${dir}/${file}"
    actual="$(file_sha256 "${dir}/${file}")"
    if [ "$actual" != "$sha" ]; then
        refuse "model file ${file} does not match its manifest (sha256 ${actual:0:16}... != ${sha:0:16}...). Refusing to load it."
    fi
    MODEL_FILE="${dir}/${file}"
    ok "model file matches its manifest (sha256 ${sha:0:16}...)"
}

# llama.cpp's CUDA build silently falls back to the CPU when it sees no usable
# GPU ("no usable GPU found, --gpu-layers option will be ignored") and still
# turns healthy. So GPU mode is proven from the server's own load log: every
# layer offloaded, or it is not a GPU session. Prints "N/N" on success.
gpu_offload_verdict() {
    local log="$1" counts n m
    if printf '%s\n' "$log" | grep -q 'no usable GPU found'; then return 1; fi
    counts="$(printf '%s\n' "$log" | sed -n 's/.*load_tensors: offloaded \([0-9][0-9]*\)\/\([0-9][0-9]*\) layers to GPU.*/\1 \2/p' | tail -1)"
    [ -n "$counts" ] || return 1
    n="${counts% *}"; m="${counts#* }"
    if [ "$m" -gt 0 ] && [ "$n" -eq "$m" ]; then printf '%s/%s' "$n" "$m"; return 0; fi
    return 1
}

# Checked before anything starts, and before the multi-GB CUDA image is pulled.
assert_gpu_available() {
    docker run --rm --gpus all --network none --entrypoint true "$AGENT_IMAGE" >/dev/null 2>&1 \
        || die "WARDEN_MODEL_GPU=1 but no GPU is available to Docker ('docker run --gpus all' failed).
        Install the NVIDIA driver + container toolkit (Docker Desktop: WSL2 GPU support),
        or unset WARDEN_MODEL_GPU to serve the model on the CPU."
}

model_net_for()       { printf '%s-net' "$1"; }
model_container_for() { printf '%s-model' "$1"; }

stop_model() {
    local name="$1"
    docker rm -f "$(model_container_for "$name")" >/dev/null 2>&1 || true
    docker network rm "$(model_net_for "$name")" >/dev/null 2>&1 || true
}

start_model() {
    local name="$1" net model
    net="$(model_net_for "$name")"; model="$(model_container_for "$name")"
    stop_model "$name"
    docker network create --internal \
        --label ai.warden.role=model-net --label "ai.warden.agent=${name}" "$net" >/dev/null \
        || die "could not create the private model network ${net}"
    [ "$(docker network inspect -f '{{.Internal}}' "$net" 2>/dev/null)" = "true" ] \
        || { stop_model "$name"; die "network ${net} is not internal - refusing"; }

    local -a rt=()
    if [ -n "$RESOLVED_RUNTIME" ]; then rt=(--runtime "$RESOLVED_RUNTIME"); fi
    # GPU: the device goes to this container only, never to the agent. -lv 4 is
    # what prints the load_tensors offload line (it does not log prompt text:
    # checked with a marker on b10991).
    local image="$MODEL_IMAGE"
    local -a gpu=() gpu_args=()
    if [ "$WARDEN_MODEL_GPU" = "1" ]; then
        image="$MODEL_IMAGE_CUDA"; gpu=(--gpus all); gpu_args=(-ngl 999 -lv 4)
    fi
    # Hardened like the sentinel. The server flags are pinned here and nothing
    # else is passed: no web UI, no /slots, and never --tools / --props / MCP.
    docker run -d --name "$model" \
        "${rt[@]}" "${gpu[@]}" \
        --network "$net" --network-alias warden-model \
        --user 65534:65534 --read-only --cap-drop=ALL \
        --security-opt no-new-privileges:true \
        --memory "$WARDEN_MODEL_MEMORY" --memory-swap "$WARDEN_MODEL_MEMORY" --pids-limit 128 \
        --label ai.warden.role=model-server --label "ai.warden.agent=${name}" \
        --log-opt max-size=10m --log-opt max-file=2 \
        -v "$(host_path "$MODEL_FILE"):/models/model.gguf:ro" \
        "$image" \
        -m /models/model.gguf --host 0.0.0.0 --port 8080 --alias "$MODEL_ALIAS" \
        --no-webui --no-slots -c "$WARDEN_MODEL_CTX" "${gpu_args[@]}" >/dev/null \
        || { stop_model "$name"; die "could not start the model server (image ${image})"; }

    local waited=0 health verdict
    while [ "$waited" -lt 180 ]; do
        health="$(docker inspect -f '{{if .State.Running}}{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}{{else}}exited{{end}}' "$model" 2>/dev/null || echo gone)"
        case "$health" in
            healthy)
                if [ "$WARDEN_MODEL_GPU" != "1" ]; then
                    ok "local model ready: ${MODEL_ALIAS} on offline network ${net} (no proxy, no route out)"; return 0
                fi
                if verdict="$(gpu_offload_verdict "$(docker logs "$model" 2>&1)")"; then
                    ok "local model ready: ${MODEL_ALIAS} on GPU (offloaded ${verdict} layers), offline network ${net} (no proxy, no route out)"; return 0
                fi
                docker logs "$model" 2>&1 | grep -E 'no usable GPU|offload|CUDA0' | tail -5 >&2 || true
                stop_model "$name"
                die "WARDEN_MODEL_GPU=1 but the model server did not offload every layer to a GPU (log above).
        Refusing to run a CPU session labelled GPU. Unset WARDEN_MODEL_GPU to use the CPU." ;;
            exited|gone)
                docker logs --tail 15 "$model" >&2 2>&1 || true
                stop_model "$name"; die "the model server exited while loading (log above)" ;;
        esac
        sleep 1; waited=$((waited + 1))
    done
    docker logs --tail 15 "$model" >&2 2>&1 || true
    stop_model "$name"
    die "the model server did not become healthy within 180s (log above)"
}

cmd_run() {
    docker_available
    load_env_file

    local target="${1:-}"
    [ -n "$target" ] || die "usage: $0 run <project-folder> [claude|aider|codex|hermes|bash] [-- args...]"
    shift

    local agent="bash"
    if [ "$#" -gt 0 ] && [ "$1" != "--" ]; then
        agent="$1"; shift
    fi
    if [ "${1:-}" = "--" ]; then shift; fi

    local local_model=0
    if [ -n "$WARDEN_MODEL_MANIFEST" ]; then local_model=1; fi
    if [ "$agent" = "aider-local" ] && [ "$local_model" = "0" ]; then
        die "aider-local needs a local model: set WARDEN_MODEL_MANIFEST=<path to the model's manifest.json>"
    fi
    case "$WARDEN_MODEL_CTX" in ''|*[!0-9]*) die "WARDEN_MODEL_CTX must be a number (got '${WARDEN_MODEL_CTX}')" ;; esac
    case "$WARDEN_MODEL_GPU" in 0|1) ;; *) die "WARDEN_MODEL_GPU must be 0 or 1 (got '${WARDEN_MODEL_GPU}')" ;; esac
    if [ "$WARDEN_MODEL_GPU" = "1" ] && [ "$local_model" = "0" ]; then
        die "WARDEN_MODEL_GPU=1 needs a local model (WARDEN_MODEL_MANIFEST): only a local model server ever gets the GPU, never an agent"
    fi

    docker image inspect "$AGENT_IMAGE" >/dev/null 2>&1 \
        || die "image ${AGENT_IMAGE} is missing. Run: $0 build"

    assert_safe_mount "$target"
    local abs="$RESOLVED_MOUNT"
    local mount_src; mount_src="$(host_path "$abs")"
    local name; name="$(container_name_for "$abs")"
    local vault; vault="$(vault_name_for "$name")"

    # Resolve the container runtime before starting anything, so an unavailable
    # WARDEN_RUNTIME aborts here rather than after the proxy and vault are up.
    assert_runtime "$WARDEN_RUNTIME"

    # A local-model session needs no proxy at all; everything else goes through it.
    local agent_net="$INTERNAL_NET"
    if [ "$local_model" = "1" ]; then
        verify_model_manifest "$WARDEN_MODEL_MANIFEST" "$abs"
        if [ "$WARDEN_MODEL_GPU" = "1" ]; then assert_gpu_available; fi
        agent_net="$(model_net_for "$name")"
    else
        cmd_up
    fi
    ensure_vault "$vault" || die "the canary vault could not be prepared"

    docker rm -f "$name" >/dev/null 2>&1 || true

    # --- assemble the run arguments -----------------------------------------
    local -a args=(
        run --rm
        --name "$name"
        --hostname warden-sandbox
        --network "$agent_net"
        --user 1001:1001
        --workdir /workspace
        --cap-drop=ALL
        --security-opt no-new-privileges:true
        --memory "$WARDEN_MEMORY"
        --memory-swap "$WARDEN_MEMORY"
        --cpus "$WARDEN_CPUS"
        --pids-limit "$WARDEN_PIDS_LIMIT"
        --ulimit nofile=8192:8192
        --ulimit nproc=512:512
        --tmpfs "/run/warden:rw,nosuid,size=16m,uid=1001,gid=1001"
        --label ai.warden.role=agent-sandbox
        --label "ai.warden.workspace=${abs}"
        --log-opt max-size=20m --log-opt max-file=3
        -v "${mount_src}:/workspace:${WARDEN_WORKSPACE_MODE}"
        # Enforceable canary vault, shared with the sentinel. See ensure_vault().
        -v "${vault}:/workspace/.secrets"
        -e WARDEN_WORKSPACE=/workspace
        -e WARDEN_STRICT=1
        -e WARDEN_REQUIRE_PROXY=1
        -e WARDEN_CANARY_ACTION=kill
        -e "WARDEN_EXPECT_SENTINEL=${WARDEN_SENTINEL}"
        -e "TERM=${TERM:-xterm-256color}"
    )

    # Optional hardened runtime (gVisor/Kata). Verified available by assert_runtime
    # above; empty means Docker's default. Guarded with if/then, not `&&`, because
    # `set -e` would treat the false test as a failure and abort.
    if [ -n "$RESOLVED_RUNTIME" ]; then
        args+=(--runtime "$RESOLVED_RUNTIME")
    fi

    # Secrets: by NAME only. The value is read by the docker client from this
    # process's environment and never appears in argv, so it stays out of `ps`,
    # out of shell history and out of any container layer.
    local var forwarded=0
    if [ "$local_model" = "1" ]; then
        # Offline and keyless: no .env, no cloud key, only the git identity. The
        # entrypoint re-checks the "offline" claim itself (WARDEN_EGRESS=none).
        args+=(
            -e WARDEN_EGRESS=none
            -e "WARDEN_MODEL_CTX=${WARDEN_MODEL_CTX}"
            -e "WARDEN_MODEL_ALIAS=${MODEL_ALIAS}"
            -e "OPENAI_API_KEY=${MODEL_PLACEHOLDER_KEY}"
            -e "NO_PROXY=localhost,127.0.0.1,::1,warden-model"
            -e "no_proxy=localhost,127.0.0.1,::1,warden-model"
        )
        for var in GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL; do
            if [ -n "${!var:-}" ]; then args+=(-e "$var"); fi
        done
        info "secrets: none - local-model sessions get no cloud API key and no .env"
    else
        for var in "${FORWARDED_SECRETS[@]}"; do
            if [ -n "${!var:-}" ]; then
                args+=(-e "$var")
                forwarded=$((forwarded + 1))
            fi
        done
        if [ -f "$ENV_FILE" ]; then
            args+=(--env-file "$(host_path "$ENV_FILE")")
            info "secrets: --env-file .env (host only, never baked into the image)"
        fi
        if [ "$forwarded" -gt 0 ]; then
            info "secrets: ${forwarded} key(s) forwarded from your shell by name"
        fi
        if [ "$forwarded" -eq 0 ] && [ ! -f "$ENV_FILE" ]; then
            warn "no API keys found. Export ANTHROPIC_API_KEY or create .env (see .env.example)."
        fi
    fi

    if [ -t 0 ] && [ -t 1 ]; then args+=(-it); fi

    local -a agent_cmd=()
    local line
    while IFS= read -r line; do agent_cmd+=("$line"); done < <(resolve_agent_cmd "$agent")
    agent_cmd+=("$@")

    printf '\n'
    info "workspace  : ${abs}"
    info "mounted at : /workspace (${WARDEN_WORKSPACE_MODE})"
    info "container  : ${name}"
    info "agent      : ${agent_cmd[*]}"
    info "isolation  : cap-drop=ALL, no-new-privileges, uid 1001, network=${agent_net} (internal)"
    if [ "$local_model" = "1" ]; then
        info "model      : ${MODEL_ALIAS} at ${MODEL_URL} - OFFLINE session, no proxy"
    fi
    info "runtime    : ${RESOLVED_RUNTIME:-default (runc)}"
    printf '\n'

    if [ "$local_model" = "1" ]; then
        trap 'stop_model "$name"; remove_vault "$vault"' EXIT INT TERM
        start_model "$name"
    fi
    if [ "$WARDEN_SENTINEL" = "1" ]; then
        ( start_sentinel "$name" "$mount_src" "$vault" ) &
    fi
    trap 'stop_sentinel "$name"; stop_model "$name"; remove_vault "$vault"' EXIT INT TERM

    # Reports already here belong to earlier sessions (or were planted): only the
    # names that appear during this run are this session's.
    local reports_before
    reports_before="$(incident_reports "$abs")"

    local rc=0
    docker "${args[@]}" "$AGENT_IMAGE" "${agent_cmd[@]}" || rc=$?
    # Order matters: the sentinel must be gone before anything touches a
    # watched path, or shutdown housekeeping reads as tampering.
    stop_sentinel "$name"
    stop_model "$name"
    remove_vault "$vault"
    trap - EXIT INT TERM
    cleanup_workspace_canaries "$abs"

    printf '\n'
    if [ "$rc" -eq 99 ]; then
        local new_reports report
        new_reports="$(LC_ALL=C comm -13 <(printf '%s\n' "$reports_before") <(incident_reports "$abs") | sed '/^$/d')"
        if [ -n "$new_reports" ]; then
            printf '%s%s  SECURITY BREACH: the canary tripwire terminated this sandbox.%s\n' \
                "$C_BOLD" "$C_RED" "$C_RESET" >&2
            while IFS= read -r report; do
                printf '%s  Incident report: %s%s\n' "$C_RED" "$report" "$C_RESET" >&2
            done <<< "$new_reports"
        elif [ "$WARDEN_WORKSPACE_MODE" = "ro" ]; then
            printf '%s%s  Exit 99 with NO incident report: the workspace is read-only, so no monitor could write one.%s\n' \
                "$C_BOLD" "$C_RED" "$C_RESET" >&2
            printf '%s  The [canary] SECURITY BREACH lines above are the only record; without them, no monitor sent the signal.%s\n' \
                "$C_RED" "$C_RESET" >&2
        else
            # Monitors write their record BEFORE they signal PID 1, and PID 1 shares
            # the agent's uid - so the agent can send the tripwire's signal itself.
            printf '%s%s  Exit 99, but NO incident report was written this session: no monitor recorded a canary access.%s\n' \
                "$C_BOLD" "$C_RED" "$C_RESET" >&2
            printf '%s  PID 1 shares the agent'"'"'s uid, so the agent can send the tripwire'"'"'s signal itself -\n  treat this as an unexplained, possibly forged termination, not a contained breach.%s\n' \
                "$C_RED" "$C_RESET" >&2
        fi
        printf '%s  Treat the agent session as hostile: rotate any key it was given.%s\n\n' \
            "$C_RED" "$C_RESET" >&2
    elif [ "$rc" -eq 78 ]; then
        warn "the sandbox refused to start because a posture check failed (see the log above)"
    elif [ "$rc" -ne 0 ]; then
        info "agent exited with code ${rc}"
    else
        ok "session ended cleanly"
    fi
    return "$rc"
}

# =============================================================================
#  Sub-command: exec / shell into a live sandbox
# =============================================================================
cmd_exec() {
    docker_available
    local name="${1:-}"
    [ -n "$name" ] || die "usage: $0 exec <container> [command...]"
    shift
    if [ "$#" -eq 0 ]; then set -- bash -l; fi
    docker exec -it --user 1001:1001 --workdir /workspace "$name" "$@"
}

# =============================================================================
#  Sub-command: status
# =============================================================================
cmd_status() {
    docker_available
    printf '\n%sAI Warden v%s%s\n\n' "$C_BOLD" "$WARDEN_VERSION" "$C_RESET"

    printf '%sEgress filter%s\n' "$C_BOLD" "$C_RESET"
    if proxy_running; then
        local health
        health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$PROXY_CONTAINER")"
        printf '  %s%-22s%s running (health: %s)\n' "$C_GREEN" "$PROXY_CONTAINER" "$C_RESET" "$health"
        local rules
        rules="$(grep -cvE '^[[:space:]]*(#|$)' "${PROJECT_ROOT}/core/network/whitelist_domains.txt" 2>/dev/null || echo '?')"
        printf '  %-22s %s domain rule(s)\n' "allowlist" "$rules"
        if audit_trail_live; then
            printf '  %-22s %slive%s (docker logs returned a fresh probe)\n' "audit trail" "$C_GREEN" "$C_RESET"
        else
            printf '  %-22s %sDEAD%s - docker logs does not return what the proxy writes; fix: %s up\n' \
                "audit trail" "$C_RED" "$C_RESET" "$0"
        fi
    else
        printf '  %s%-22s%s stopped   (start it with: %s up)\n' "$C_RED" "$PROXY_CONTAINER" "$C_RESET" "$0"
    fi

    printf '\n%sNetworks%s\n' "$C_BOLD" "$C_RESET"
    local net
    for net in "$INTERNAL_NET" "$EXTERNAL_NET"; do
        if docker network inspect "$net" >/dev/null 2>&1; then
            local internal
            internal="$(docker network inspect -f '{{.Internal}}' "$net")"
            printf '  %-22s present (internal=%s)\n' "$net" "$internal"
        else
            printf '  %-22s %smissing%s\n' "$net" "$C_YELLOW" "$C_RESET"
        fi
    done

    printf '\n%sSandboxes%s\n' "$C_BOLD" "$C_RESET"
    local rows
    rows="$(docker ps -a --filter 'label=ai.warden.role=agent-sandbox' \
             --format '{{.Names}}\t{{.Status}}\t{{.Label "ai.warden.workspace"}}' 2>/dev/null || true)"
    if [ -z "$rows" ]; then
        printf '  %snone running%s\n' "$C_DIM" "$C_RESET"
    else
        printf '%s\n' "$rows" | while IFS=$'\t' read -r n s w; do
            printf '  %-26s %-24s %s\n' "$n" "$s" "$w"
        done
    fi

    printf '\n%sSentinels%s\n' "$C_BOLD" "$C_RESET"
    local sent
    sent="$(docker ps --filter 'label=ai.warden.role=canary-sentinel' --format '  {{.Names}}  {{.Status}}' 2>/dev/null || true)"
    printf '%s\n' "${sent:-  ${C_DIM}none${C_RESET}}"

    # A CLI killed hard (no trap) leaves its model server running: RAM, and a GPU
    # in GPU mode. Show every one, and say so when its sandbox is gone.
    printf '\n%sLocal model servers%s\n' "$C_BOLD" "$C_RESET"
    local mrows
    mrows="$(docker ps -a --filter 'label=ai.warden.role=model-server' \
              --format '{{.Names}}\t{{.Status}}\t{{.Label "ai.warden.agent"}}' 2>/dev/null || true)"
    if [ -z "$mrows" ]; then
        printf '  %snone%s\n' "$C_DIM" "$C_RESET"
    else
        printf '%s\n' "$mrows" | while IFS=$'\t' read -r n s a; do
            local dev owner
            dev="cpu"
            case "$(docker inspect -f '{{range .HostConfig.DeviceRequests}}{{.Capabilities}}{{end}}' "$n" 2>/dev/null)" in
                *gpu*) dev="GPU" ;;
            esac
            if docker container inspect -f '{{.Id}}' "$a" >/dev/null 2>&1; then
                owner="for ${a}"
            else
                owner="${C_RED}ORPHANED${C_RESET} (sandbox ${a} is gone) - remove with: $0 stop"
            fi
            printf '  %-32s %-22s %-4s %s\n' "$n" "$s" "$dev" "$owner"
        done
    fi

    printf '\n%sRecent incidents%s\n' "$C_BOLD" "$C_RESET"
    local found=0 report
    while IFS= read -r report; do
        [ -n "$report" ] || continue
        found=1
        printf '  %s%s%s\n' "$C_RED" "$report" "$C_RESET"
    done < <(find "${PROJECT_ROOT}/workspaces" -maxdepth 3 -name 'WARDEN_SECURITY_INCIDENT.json' 2>/dev/null || true)
    if [ "$found" -eq 0 ]; then
        printf '  %snone recorded under ./workspaces%s\n' "$C_DIM" "$C_RESET"
    fi
    printf '\n'
}

# =============================================================================
#  Sub-command: stop / logs / allowlist / verify
# =============================================================================
cmd_stop() {
    docker_available
    local name="${1:-}"
    if [ -n "$name" ]; then
        stop_sentinel "$name"
        remove_vault "$(vault_name_for "$name")"
        if docker rm -f "$name" >/dev/null 2>&1; then
            ok "stopped ${name}"
        else
            warn "no such sandbox: ${name}"
        fi
        return 0
    fi
    local ids
    ids="$(docker ps -aq --filter 'label=ai.warden.role=agent-sandbox' 2>/dev/null || true)"
    local sids mids mnets
    sids="$(docker ps -aq --filter 'label=ai.warden.role=canary-sentinel' 2>/dev/null || true)"
    # A hard-killed local-model session can leave its model server behind even
    # after the agent container is gone, so these count as something to stop.
    mids="$(docker ps -aq --filter 'label=ai.warden.role=model-server' 2>/dev/null || true)"
    if [ -z "$ids$sids$mids" ]; then
        info "no sandboxes to stop"
        return 0
    fi
    # shellcheck disable=SC2086
    docker rm -f $sids $ids $mids >/dev/null 2>&1 || true
    mnets="$(docker network ls -q --filter 'label=ai.warden.role=model-net' 2>/dev/null || true)"
    # shellcheck disable=SC2086
    if [ -n "$mnets" ]; then docker network rm $mnets >/dev/null 2>&1 || true; fi

    # Sweep up canary vaults orphaned by a hard kill of a previous session.
    local vols
    vols="$(docker volume ls -q --filter 'label=ai.warden.role=canary-vault' 2>/dev/null || true)"
    if [ -n "$vols" ]; then
        # shellcheck disable=SC2086
        docker volume rm -f $vols >/dev/null 2>&1 || true
    fi
    ok "all sandboxes stopped"
}

cmd_logs() {
    docker_available
    local what="${1:-proxy}"
    shift || true
    case "$what" in
        proxy|egress)
            # Silence here is only evidence if the trail is alive.
            if proxy_running && ! audit_trail_live; then
                warn "the egress audit trail is DEAD - output below stops where the log file was damaged. Recreate the proxy with: $0 up"
            fi
            docker logs "$PROXY_CONTAINER" "$@" ;;
        *)            docker logs "$what" "$@" ;;
    esac
}

cmd_allowlist() {
    local file="${PROJECT_ROOT}/core/network/whitelist_domains.txt"
    local action="${1:-list}"
    case "$action" in
        list)
            grep -vE '^[[:space:]]*(#|$)' "$file" | sort
            ;;
        add)
            local domain="${2:-}"
            [ -n "$domain" ] || die "usage: $0 allowlist add <domain>"
            case "$domain" in
                *ngrok*|*trycloudflare*|*pastebin*|*webhook.site*|*requestbin*|*transfer.sh*|*file.io*)
                    die "refusing to allowlist a known exfiltration relay: ${domain}" ;;
            esac
            if grep -qxF "$domain" "$file"; then
                info "${domain} is already allowlisted"
                return 0
            fi
            printf '%s\n' "$domain" >> "$file"
            ok "added ${domain}; rebuild and restart the proxy: $0 build && $0 down && $0 up"
            ;;
        *) die "usage: $0 allowlist [list|add <domain>]" ;;
    esac
}

cmd_verify() {
    docker_available
    exec "${SCRIPT_DIR}/verify-isolation.sh" "$@"
}

cmd_doctor() {
    exec "${SCRIPT_DIR}/setup-host.sh" --check
}

# =============================================================================
#  Usage
# =============================================================================
usage() {
    cat >&2 <<USAGE
${C_BOLD}AI Warden v${WARDEN_VERSION}${C_RESET} - Zero-Trust sandbox for autonomous AI coding agents

${C_BOLD}USAGE${C_RESET}
  $0 <command> [args]

${C_BOLD}COMMANDS${C_RESET}
  build [docker build args]     Build the agent image and the egress proxy
  up                            Start the egress allowlist proxy and networks
  down                          Stop everything (sandboxes + proxy)
  run <folder> [agent] [-- ...] Launch an agent with ONLY <folder> mounted
                                agent: claude | aider | codex | hermes | bash
                                       aider-local (needs WARDEN_MODEL_MANIFEST)
  exec <container> [cmd...]     Attach to a running sandbox as ai_user
  status                        Show proxy, networks, sandboxes and incidents
  stop [container]              Stop one sandbox, or all of them
  logs [proxy|<container>]      Tail logs (the proxy log is the egress audit trail)
  allowlist [list|add <domain>] Inspect or extend the egress allowlist
  verify                        Run the full isolation test suite
  doctor                        Check host prerequisites

${C_BOLD}EXAMPLES${C_RESET}
  $0 build
  $0 run ./workspaces/default claude
  $0 run ~/src/my-api aider -- --model sonnet
  WARDEN_MODEL_MANIFEST=~/models/manifest.json $0 run ./proj aider-local   # offline
  WARDEN_MODEL_GPU=1 WARDEN_MODEL_MANIFEST=~/models/manifest.json $0 run ./proj aider-local   # offline, on the GPU
  $0 logs proxy --since 10m
  $0 verify

${C_BOLD}SAFETY${C_RESET}
  Every sandbox runs with --cap-drop=ALL, --security-opt no-new-privileges,
  as uid 1001, on an internal network with no route to the internet. Only the
  folder you name is mounted; \$HOME, ~/.ssh and ~/.aws are never visible.
USAGE
}

# =============================================================================
#  Dispatch
# =============================================================================
main() {
    local cmd="${1:-help}"
    shift || true
    case "$cmd" in
        build)      cmd_build "$@" ;;
        up|start)   cmd_up "$@" ;;
        down)       cmd_down "$@" ;;
        run)        cmd_run "$@" ;;
        exec|shell) cmd_exec "$@" ;;
        status|ps)  cmd_status "$@" ;;
        stop|kill)  cmd_stop "$@" ;;
        logs)       cmd_logs "$@" ;;
        allowlist)  cmd_allowlist "$@" ;;
        verify|test) cmd_verify "$@" ;;
        doctor)     cmd_doctor "$@" ;;
        version)    printf 'ai-warden %s\n' "$WARDEN_VERSION" ;;
        help|-h|--help) usage ;;
        *)          printf 'unknown command: %s\n\n' "$cmd" >&2; usage; exit 64 ;;
    esac
}

# Run main only when executed directly, never when sourced. The isolation suite
# sources this file to exercise assert_safe_mount() against a battery of unsafe
# paths (verify-isolation.sh, phase E3); without this guard that source would
# fall straight through to `main` and try to run a command.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
