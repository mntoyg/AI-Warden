# =============================================================================
#  AI Warden - command shortcuts
# -----------------------------------------------------------------------------
#  Every target is a thin wrapper around ./scripts/warden-cli.sh, which stays
#  the source of truth. Use `make` (or `make help`) for the full list.
#
#  Override the workspace with WS=, the agent with AGENT=:
#     make run WS=~/src/my-api AGENT=aider
# =============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help
# NOTE: no .ONESHELL - every recipe line is its own shell, so multi-step
# recipes below are written as a single backslash-continued command.

CLI    := ./scripts/warden-cli.sh
SETUP  := ./scripts/setup-host.sh
VERIFY := ./scripts/verify-isolation.sh

WS    ?= ./workspaces/default
AGENT ?= bash

IGNORE_MIRRORS := .claudeignore .cursorignore .aiderignore .hermesignore .cometignore .codexignore

.PHONY: help setup doctor build up down run run-claude run-aider run-codex run-hermes run-bash \
        status logs logs-proxy exec stop verify test allowlist sync-ignores lint clean nuke

# -----------------------------------------------------------------------------
help: ## Show this help
	@echo ""
	@echo "  AI Warden - Zero-Trust sandbox for autonomous AI coding agents"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Variables:  WS=<project folder>   AGENT=<claude|aider|codex|hermes|bash>"
	@echo "  Example:    make run WS=~/src/my-api AGENT=claude"
	@echo ""

# --- setup -------------------------------------------------------------------
setup: ## Check prerequisites, create .env, networks and workspaces/
	@$(SETUP)

doctor: ## Read-only host diagnosis (changes nothing)
	@$(SETUP) --check

build: ## Build the agent image and the egress proxy image
	@$(CLI) build

# --- lifecycle ---------------------------------------------------------------
up: ## Start the egress allowlist proxy and both networks
	@$(CLI) up

down: ## Stop every sandbox and the egress proxy
	@$(CLI) down

stop: ## Stop running sandboxes (leave the proxy up)
	@$(CLI) stop

# --- running agents ----------------------------------------------------------
run: ## Run AGENT in WS  (make run WS=./my-project AGENT=claude)
	@$(CLI) run "$(WS)" "$(AGENT)"

run-claude: ## Run Claude Code in WS
	@$(CLI) run "$(WS)" claude

run-aider: ## Run Aider in WS
	@$(CLI) run "$(WS)" aider

run-codex: ## Run the Codex CLI in WS
	@$(CLI) run "$(WS)" codex

run-hermes: ## Run Hermes Agent in WS
	@$(CLI) run "$(WS)" hermes

run-bash: ## Open a hardened shell in WS (best way to poke at the sandbox)
	@$(CLI) run "$(WS)" bash

exec: ## Attach to a running sandbox  (make exec NAME=warden-sbx-my-project)
	@$(CLI) exec "$(NAME)"

# --- observability -----------------------------------------------------------
status: ## Show proxy, networks, sandboxes and recorded incidents
	@$(CLI) status

logs: ## Tail the egress audit trail (every allow and deny)
	@$(CLI) logs proxy -f

logs-proxy: logs ## Alias for `make logs`

allowlist: ## Print the effective egress allowlist
	@$(CLI) allowlist list

# --- verification ------------------------------------------------------------
verify: ## Full isolation suite: self-test + breach drill + fail-closed drill
	@$(VERIFY)

test: verify ## Alias for `make verify`

# --- maintenance -------------------------------------------------------------
sync-ignores: ## Regenerate every per-tool ignore file from .aiignore
	@set -eu; \
	for f in $(IGNORE_MIRRORS); do \
		case "$$f" in \
			.claudeignore) tool="Claude Code" ;; \
			.cursorignore) tool="Cursor" ;; \
			.aiderignore)  tool="Aider" ;; \
			.hermesignore) tool="Hermes Agent" ;; \
			.cometignore)  tool="Comet" ;; \
			.codexignore)  tool="Codex CLI" ;; \
		esac; \
		{ printf '# %s - AI Warden agent deny-list (mirror of .aiignore).\n' "$$tool"; \
		  printf '# Regenerate with: make sync-ignores\n\n'; \
		  cat .aiignore; } > "$$f"; \
		echo "  regenerated $$f"; \
	done

lint: ## shellcheck every script, byte-compile the monitor, parse squid.conf
	@fail=0; \
	scripts="scripts/warden-cli.sh scripts/setup-host.sh scripts/verify-isolation.sh \
		  scripts/selftest-in-container.sh core/entrypoint.sh core/network/proxy-entrypoint.sh"; \
	if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -S warning $$scripts || fail=1; \
	else \
		echo "  shellcheck not installed - falling back to 'bash -n'"; \
		for f in $$scripts; do bash -n "$$f" || fail=1; done; \
	fi; \
	python3 -m py_compile monitors/canary_monitor.py \
		&& echo "  monitors/canary_monitor.py compiles" || fail=1; \
	if docker image inspect ai-warden/egress-proxy:latest >/dev/null 2>&1; then \
		docker run --rm --entrypoint squid ai-warden/egress-proxy:latest \
			-k parse -f /etc/squid/squid.conf >/dev/null 2>&1 \
			&& echo "  squid.conf parses" || fail=1; \
	else \
		echo "  (squid.conf parse skipped - build the proxy image first)"; \
	fi; \
	exit $$fail

clean: ## Remove verification leftovers and __pycache__
	@rm -rf workspaces/.verify-* workspaces/.verify-breach-* monitors/__pycache__ 2>/dev/null || true
	@echo "  cleaned"

nuke: down ## Stop everything and delete the warden images and networks
	@docker rmi -f ai-warden/agent:latest ai-warden/egress-proxy:latest 2>/dev/null || true
	@docker network rm warden_internal warden_external 2>/dev/null || true
	@echo "  images and networks removed"
