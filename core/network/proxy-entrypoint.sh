#!/usr/bin/env bash
# =============================================================================
#  AI Warden - Egress Proxy Entrypoint
# -----------------------------------------------------------------------------
#  Validates the ruleset before serving a single byte. A proxy that starts with
#  a broken allowlist is worse than a proxy that refuses to start, so any parse
#  error is fatal.
# =============================================================================
set -euo pipefail

CONF=/etc/squid/squid.conf
LIST=/etc/squid/whitelist_domains.txt

_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '[egress %s] %s\n' "$(_ts)" "$*" >&2; }

log "AI Warden egress proxy starting"

# --- 1. The allowlist must exist and must not be empty -----------------------
if [ ! -r "$LIST" ]; then
    log "FATAL: allowlist ${LIST} is missing or unreadable"
    exit 78
fi

domain_count="$(grep -cvE '^[[:space:]]*(#|$)' "$LIST" || true)"
if [ "${domain_count:-0}" -eq 0 ]; then
    log "FATAL: allowlist contains zero domains - refusing to start"
    exit 78
fi
log "allowlist loaded: ${domain_count} domain rule(s)"

# --- 2. The ruleset must parse ------------------------------------------------
if ! squid -k parse -f "$CONF" >/tmp/squid-parse.log 2>&1; then
    log "FATAL: squid configuration failed to parse:"
    sed 's/^/    /' /tmp/squid-parse.log >&2
    exit 78
fi
log "configuration validated"

# --- 3. Sanity check: the config must still end in a default deny -------------
if ! grep -qE '^[[:space:]]*http_access[[:space:]]+deny[[:space:]]+all[[:space:]]*$' "$CONF"; then
    log "FATAL: squid.conf has no 'http_access deny all' default rule"
    exit 78
fi
log "default-deny confirmed"

log "listening on 0.0.0.0:3128 - every allow/deny is logged below"

# -N  foreground (no daemonise)  |  -d 1  send cache.log to stderr
exec squid -N -d 1 -f "$CONF"
