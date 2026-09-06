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

readonly WARDEN_VERSION="1.0.0"
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
            WARDEN_MEMORY|WARDEN_CPUS|WARDEN_PIDS_LIMIT|WARDEN_SENTINEL|WARDEN_WORKSPACE_MODE)
                value="${value%\"}"; value="${value#\"}"
                if [ -n "$value" ]; then printf -v "$key" '%s' "$value"; fi
                ;;
        esac
    done < <(grep -E '^[A-Z_]+=' "$ENV_FILE" 2>/dev/null || true)
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
assert_safe_mount() {
    local abs="$1"
    [ -d "$abs" ] || die "not a directory: ${abs}"

    local real; real="$(cd "$abs" && pwd -P)"
    local home; home="$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P || echo '/nonexistent')"

    # 1. Filesystem roots and drive roots.
    case "$real" in
        /|/root|/etc|/usr|/var|/boot|/dev|/proc|/sys|/bin|/sbin|/lib|/opt)
            die "refusing to mount system path: ${real}" ;;
        /[a-z]|/[a-z]/)
            die "refusing to mount a whole drive: ${real}" ;;
        /c|/c/|/d|/d/|/mnt/c|/mnt/c/)
            die "refusing to mount a whole Windows drive: ${real}" ;;
    esac

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

    printf '%s' "$real"
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
#  Sub-command: build
# =============================================================================
cmd_build() {
    docker_available
    local ctx; ctx="$(host_path "$PROJECT_ROOT")"

    info "building egress proxy image (${PROXY_IMAGE})"
    docker build -f "$(host_path "${PROJECT_ROOT}/core/network/Dockerfile")" -t "$PROXY_IMAGE" "$ctx"
    ok "egress proxy built"

    info "building agent sandbox image (${AGENT_IMAGE}) - this pulls Node, Python and the agent CLIs"
    docker build -f "$(host_path "${PROJECT_ROOT}/core/Dockerfile")" -t "$AGENT_IMAGE" "$ctx" "$@"
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

cmd_up() {
    docker_available
    assert_networks_sane
    if proxy_running; then
        ok "egress proxy already running"
    else
        info "starting egress allowlist proxy (compose also creates both networks)"
        compose up -d warden-egress-proxy
    fi

    local waited=0
    while [ "$waited" -lt 45 ]; do
        local health
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
resolve_agent_cmd() {
    case "${1:-bash}" in
        claude)          printf '%s\n' claude ;;
        aider)           printf '%s\n' aider ;;
        codex)           printf '%s\n' codex ;;
        hermes)          printf '%s\n' hermes ;;
        bash|sh|shell)   printf '%s\n%s\n' bash -l ;;
        *)               printf '%s\n' "$1" ;;
    esac
}

start_sentinel() {
    local agent_container="$1" host_ws="$2"
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

    if docker run -d --rm \
        --name "$sentinel" \
        --network none \
        --pid "container:${agent_container}" \
        --user 1002:1002 \
        --read-only \
        --tmpfs /tmp:rw,nosuid,size=16m \
        --cap-drop=ALL \
        --cap-add=KILL \
        --security-opt no-new-privileges:true \
        --memory 256m --pids-limit 64 \
        --label ai.warden.role=canary-sentinel \
        --label "ai.warden.agent=${agent_container}" \
        -v "${host_ws}:/workspace" \
        --entrypoint /opt/warden/venv/bin/python3 \
        "$AGENT_IMAGE" \
        /opt/warden/canary_monitor.py \
            --mode=sentinel --action=kill --target-uid=1001 \
            --run-dir=/tmp/warden --wait-for-canaries=30 \
            --canaries=/workspace/.secrets.canary:/workspace/secrets.json:/workspace/.env.vault \
        >/dev/null 2>&1
    then
        ok "canary sentinel attached (uid 1002, CAP_KILL only, no network)"
    else
        warn "could not start the out-of-band sentinel; the in-container tripwire is still armed"
    fi
}

stop_sentinel() {
    docker rm -f "${1}-sentinel" >/dev/null 2>&1 || true
}

# Canaries in the bind-mounted workspace are removed from the HOST, after both
# the container and its sentinel are gone. Doing it inside the container would
# mean reading and unlinking watched files while the sentinel is still armed,
# which is exactly the pattern the sentinel exists to flag.
cleanup_workspace_canaries() {
    local ws="$1" f
    for f in .secrets.canary secrets.json .env.vault; do
        if [ -f "${ws}/${f}" ] && grep -qs 'AI-WARDEN-CANARY' "${ws}/${f}"; then
            rm -f "${ws}/${f}" 2>/dev/null || true
        fi
    done
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

    docker image inspect "$AGENT_IMAGE" >/dev/null 2>&1 \
        || die "image ${AGENT_IMAGE} is missing. Run: $0 build"

    local abs; abs="$(assert_safe_mount "$target")"
    local mount_src; mount_src="$(host_path "$abs")"
    local name; name="$(container_name_for "$abs")"

    cmd_up

    docker rm -f "$name" >/dev/null 2>&1 || true

    # --- assemble the run arguments -----------------------------------------
    local -a args=(
        run --rm
        --name "$name"
        --hostname warden-sandbox
        --network "$INTERNAL_NET"
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
        -e WARDEN_WORKSPACE=/workspace
        -e WARDEN_STRICT=1
        -e WARDEN_REQUIRE_PROXY=1
        -e WARDEN_CANARY_ACTION=kill
        -e "TERM=${TERM:-xterm-256color}"
    )

    # Secrets: by NAME only. The value is read by the docker client from this
    # process's environment and never appears in argv, so it stays out of `ps`,
    # out of shell history and out of any container layer.
    local var forwarded=0
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

    if [ -t 0 ] && [ -t 1 ]; then args+=(-it); fi

    local -a agent_cmd=()
    while IFS= read -r line; do agent_cmd+=("$line"); done < <(resolve_agent_cmd "$agent")
    agent_cmd+=("$@")

    printf '\n'
    info "workspace  : ${abs}"
    info "mounted at : /workspace (${WARDEN_WORKSPACE_MODE})"
    info "container  : ${name}"
    info "agent      : ${agent_cmd[*]}"
    info "isolation  : cap-drop=ALL, no-new-privileges, uid 1001, network=${INTERNAL_NET} (internal)"
    printf '\n'

    if [ "$WARDEN_SENTINEL" = "1" ]; then
        ( start_sentinel "$name" "$mount_src" ) &
    fi
    trap 'stop_sentinel "$name"' EXIT INT TERM

    local rc=0
    docker "${args[@]}" "$AGENT_IMAGE" "${agent_cmd[@]}" || rc=$?
    stop_sentinel "$name"
    trap - EXIT INT TERM
    cleanup_workspace_canaries "$abs"

    printf '\n'
    if [ "$rc" -eq 99 ]; then
        printf '%s%s  SECURITY BREACH: the canary tripwire terminated this sandbox.%s\n' \
            "$C_BOLD" "$C_RED" "$C_RESET" >&2
        printf '%s  Incident report: %s/WARDEN_SECURITY_INCIDENT.json%s\n' \
            "$C_RED" "$abs" "$C_RESET" >&2
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
        if docker rm -f "$name" >/dev/null 2>&1; then
            ok "stopped ${name}"
        else
            warn "no such sandbox: ${name}"
        fi
        return 0
    fi
    local ids
    ids="$(docker ps -aq --filter 'label=ai.warden.role=agent-sandbox' 2>/dev/null || true)"
    local sids
    sids="$(docker ps -aq --filter 'label=ai.warden.role=canary-sentinel' 2>/dev/null || true)"
    if [ -z "$ids$sids" ]; then
        info "no sandboxes to stop"
        return 0
    fi
    # shellcheck disable=SC2086
    docker rm -f $sids $ids >/dev/null 2>&1 || true
    ok "all sandboxes stopped"
}

cmd_logs() {
    docker_available
    local what="${1:-proxy}"
    shift || true
    case "$what" in
        proxy|egress) docker logs "$PROXY_CONTAINER" "$@" ;;
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

main "$@"
