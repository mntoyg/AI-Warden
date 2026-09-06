# syntax=docker/dockerfile:1.7
# =============================================================================
#  AI Warden - Egress Allowlist Proxy (warden-egress-proxy)
# -----------------------------------------------------------------------------
#  The single chokepoint between the sandbox and the internet.
#
#  Build:  docker build -f core/network/Dockerfile -t ai-warden/egress-proxy .
#
#  This container is dual-homed:
#    warden_internal (internal: true)  <- the sandbox talks to us here
#    warden_external                   <- we talk to the internet here
#  The sandbox itself is attached ONLY to warden_internal and therefore has no
#  route out that does not pass through these rules.
# =============================================================================

FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="AI Warden Egress Proxy" \
      org.opencontainers.image.description="Deny-by-default HTTP/HTTPS egress allowlist for AI agent sandboxes" \
      org.opencontainers.image.source="https://github.com/mntoyg/AI-Warden" \
      org.opencontainers.image.licenses="MIT" \
      ai.warden.role="egress-proxy"

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        squid \
        ca-certificates \
        curl \
        netcat-openbsd; \
    rm -rf /var/lib/apt/lists/*; \
    rm -f /etc/squid/squid.conf

COPY core/network/squid.conf            /etc/squid/squid.conf
COPY core/network/whitelist_domains.txt /etc/squid/whitelist_domains.txt
COPY core/network/proxy-entrypoint.sh   /usr/local/bin/proxy-entrypoint

RUN set -eux; \
    chmod 0755 /usr/local/bin/proxy-entrypoint; \
    chmod 0444 /etc/squid/squid.conf /etc/squid/whitelist_domains.txt; \
    mkdir -p /var/spool/squid /var/log/squid; \
    chown -R proxy:proxy /var/spool/squid /var/log/squid; \
    squid -k parse -f /etc/squid/squid.conf

# The proxy holds no secrets and needs no privileges: unprivileged user,
# high port, no capabilities (enforced again at runtime by compose).
USER proxy
EXPOSE 3128

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD nc -z 127.0.0.1 3128 || exit 1

ENTRYPOINT ["/usr/local/bin/proxy-entrypoint"]
