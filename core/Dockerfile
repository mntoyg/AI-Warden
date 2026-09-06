# syntax=docker/dockerfile:1.7
# =============================================================================
#  AI Warden - Hardened Agent Sandbox Image
# -----------------------------------------------------------------------------
#  Runs autonomous AI coding agents (Claude Code, Aider, Codex, Hermes) as an
#  unprivileged user, with every Linux capability dropped at runtime and all
#  egress forced through the warden-egress-proxy allowlist.
#
#  Build:  docker build -f core/Dockerfile -t ai-warden/agent:latest .
#
#  Never run this image with --privileged, --cap-add, --network host, or a
#  bind mount of the Docker socket. See docs/THREAT_MODEL.md.
# =============================================================================

FROM debian:bookworm-slim

# --- Build-time knobs --------------------------------------------------------
ARG NODE_MAJOR=20
ARG AI_UID=1001
ARG AI_GID=1001
# Agent CLIs installed globally from npm.
ARG NPM_AGENTS="@anthropic-ai/claude-code @openai/codex"
# Extra packages folded in at build time (e.g. a Hermes Agent distribution).
ARG EXTRA_PIP_PACKAGES=""
ARG EXTRA_NPM_PACKAGES=""

LABEL org.opencontainers.image.title="AI Warden Agent Sandbox" \
      org.opencontainers.image.description="Zero-Trust isolation sandbox for autonomous AI coding agents" \
      org.opencontainers.image.source="https://github.com/mntoyg/AI-Warden" \
      org.opencontainers.image.licenses="MIT" \
      ai.warden.role="agent-sandbox"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_UPDATE_NOTIFIER=false

# -----------------------------------------------------------------------------
# 1. Base OS + toolchain
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        git \
        openssh-client \
        build-essential \
        pkg-config \
        python3 \
        python3-venv \
        python3-dev \
        python3-pip \
        ripgrep \
        jq \
        less \
        nano \
        vim-tiny \
        procps \
        psmisc \
        file \
        unzip \
        tar \
        gzip \
        iproute2 \
        dnsutils \
        netcat-openbsd \
        libcap2-bin; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 2. Node.js (NodeSource) - required by Claude Code and the Codex CLI
# -----------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource_setup.sh; \
    bash /tmp/nodesource_setup.sh; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -f /tmp/nodesource_setup.sh; \
    rm -rf /var/lib/apt/lists/*; \
    node --version; \
    npm --version

# -----------------------------------------------------------------------------
# 3. Unprivileged runtime user
#    - locked password; the sudo package is never installed
#    - owns /workspace and its own npm prefix so nothing ever needs root
# -----------------------------------------------------------------------------
RUN set -eux; \
    groupadd --gid "${AI_GID}" ai_user; \
    useradd --uid "${AI_UID}" --gid "${AI_GID}" --shell /bin/bash \
            --home-dir /home/ai_user --create-home ai_user; \
    passwd --lock ai_user; \
    : "--- out-of-band sentinel identity (see docker-compose.yml) ---"; \
    groupadd --gid 1002 warden_mon; \
    useradd --uid 1002 --gid 1002 --shell /usr/sbin/nologin \
            --home-dir /home/warden_mon --create-home warden_mon; \
    passwd --lock warden_mon; \
    mkdir -p /workspace /run/warden /opt/agents \
             /home/ai_user/.npm-global /home/ai_user/.cache \
             /home/ai_user/.aws /home/ai_user/.ssh; \
    chmod 0700 /home/ai_user/.ssh; \
    chown -R ai_user:ai_user /workspace /run/warden /home/ai_user

# -----------------------------------------------------------------------------
# 4. Agent CLIs
#    npm globals live in root-owned /usr/local so the agent cannot rewrite its
#    own binaries; python agents live in an isolated venv on PATH.
# -----------------------------------------------------------------------------
RUN set -eux; \
    npm install -g --omit=dev ${NPM_AGENTS} ${EXTRA_NPM_PACKAGES}; \
    npm cache clean --force

RUN set -eux; \
    python3 -m venv /opt/agents/venv; \
    /opt/agents/venv/bin/pip install --no-cache-dir --upgrade pip setuptools wheel; \
    /opt/agents/venv/bin/pip install --no-cache-dir aider-chat ${EXTRA_PIP_PACKAGES}; \
    ln -sf /opt/agents/venv/bin/aider /usr/local/bin/aider

# -----------------------------------------------------------------------------
# 5. Warden supervisor venv - kept separate from anything the agent installs
# -----------------------------------------------------------------------------
RUN set -eux; \
    python3 -m venv /opt/warden/venv; \
    /opt/warden/venv/bin/pip install --no-cache-dir --upgrade pip; \
    /opt/warden/venv/bin/pip install --no-cache-dir watchdog

# -----------------------------------------------------------------------------
# 6. Warden runtime files
# -----------------------------------------------------------------------------
COPY monitors/canary_monitor.py         /opt/warden/canary_monitor.py
COPY core/entrypoint.sh                 /usr/local/bin/warden-entrypoint
COPY core/network/whitelist_domains.txt /opt/warden/whitelist_domains.txt
COPY .aiignore                          /opt/warden/aiignore.template

RUN set -eux; \
    chmod 0755 /usr/local/bin/warden-entrypoint; \
    chmod 0444 /opt/warden/canary_monitor.py \
               /opt/warden/whitelist_domains.txt \
               /opt/warden/aiignore.template; \
    chown -R root:root /opt/warden /opt/agents

# -----------------------------------------------------------------------------
# 7. Egress: every client library is pointed at the allowlist proxy.
#    The sandbox network is `internal`, so this is the ONLY usable route out.
# -----------------------------------------------------------------------------
ENV WARDEN_PROXY_HOST=warden-egress-proxy \
    WARDEN_PROXY_PORT=3128 \
    HTTP_PROXY=http://warden-egress-proxy:3128 \
    HTTPS_PROXY=http://warden-egress-proxy:3128 \
    http_proxy=http://warden-egress-proxy:3128 \
    https_proxy=http://warden-egress-proxy:3128 \
    NO_PROXY=localhost,127.0.0.1,::1,warden-egress-proxy \
    no_proxy=localhost,127.0.0.1,::1,warden-egress-proxy \
    npm_config_proxy=http://warden-egress-proxy:3128 \
    npm_config_https_proxy=http://warden-egress-proxy:3128 \
    PIP_PROXY=http://warden-egress-proxy:3128 \
    PATH=/home/ai_user/.npm-global/bin:/opt/agents/venv/bin:/usr/local/bin:/usr/bin:/bin

# System-wide pip proxy (belt and braces alongside PIP_PROXY).
RUN set -eux; \
    printf '%s\n' \
      '[global]' \
      'proxy = http://warden-egress-proxy:3128' \
      'disable-pip-version-check = true' \
      > /etc/pip.conf

# -----------------------------------------------------------------------------
# 8. Canary configuration
# -----------------------------------------------------------------------------
ENV WARDEN_CANARY_FILES="/workspace/.secrets.canary:/workspace/secrets.json:/workspace/.env.vault:/home/ai_user/.aws/credentials:/home/ai_user/.ssh/id_rsa_backup" \
    WARDEN_CANARY_ACTION=kill \
    WARDEN_BREACH_EXIT_CODE=99 \
    WARDEN_WORKSPACE=/workspace

# -----------------------------------------------------------------------------
# 9. Final hardening
#    Strip every setuid/setgid bit in the image. Together with
#    --security-opt no-new-privileges this removes the local privilege
#    escalation surface entirely (su, mount, chsh, newgrp, ping, ...).
# -----------------------------------------------------------------------------
RUN set -eux; \
    find / -xdev -type f -perm -4000 -exec chmod a-s {} + || true; \
    find / -xdev -type f -perm -2000 -exec chmod a-s {} + || true; \
    rm -f /usr/bin/wall /usr/bin/write || true

USER ai_user
WORKDIR /workspace

# npm must not try to write into root-owned /usr/local as a non-root user.
RUN set -eux; \
    npm config set prefix /home/ai_user/.npm-global; \
    git config --global --add safe.directory /workspace; \
    git config --global http.proxy  http://warden-egress-proxy:3128; \
    git config --global https.proxy http://warden-egress-proxy:3128; \
    git config --global init.defaultBranch main

# Unhealthy the moment the canary tripwire fires.
HEALTHCHECK --interval=20s --timeout=5s --start-period=10s --retries=2 \
    CMD test ! -f /run/warden/breach.flag

ENTRYPOINT ["/usr/local/bin/warden-entrypoint"]
CMD ["bash", "-l"]
