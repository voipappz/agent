# VoipAppz agent. `make` lists everything.
SHELL := /bin/sh
.DEFAULT_GOAL := help
SUDO := $(shell [ "$$(id -u)" = 0 ] || echo sudo)

help: ## This list
	@printf '\n\033[1mVoipAppz agent\033[0m   make install, then make status\n\n'
	@awk 'BEGIN { FS = ":.*## " } /^[a-z][a-z0-9-]*:.*## / { printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf '\n  unattended: VA_API_USER VA_API_PASSWORD NODE_NAME NATS_TOKEN SECRET_KEY make install (VA_API_URL, NATS_URL optional)\n\n'

install: ## The wizard: mothership, account, node, NATS, secret -> installed and running
	@sh scripts/wizard.sh

status: ## Is it running, and healthy?
	@systemctl --no-pager status va-node | head -5 || true
	@printf 'health: '; curl -fsS localhost:4000/health || printf 'not answering'; echo

logs: ## Follow its log
	@$(SUDO) journalctl -u va-node -f

config: ## After the node changed in the mothership: fetch va.yaml again, restart
	@$(SUDO) va-agent-fetch-config

update: ## The latest release, keeping the settings
	@sh install.sh && $(SUDO) systemctl restart va-node && echo "updated and restarted"

rollback: ## Back to the old va-agent service
	@$(SUDO) systemctl disable --now va-node && $(SUDO) systemctl enable --now va-agent && echo "va-agent is back"

uninstall: ## Remove the agent (keeps /etc/va-agent)
	@$(SUDO) systemctl disable --now va-node 2>/dev/null || true
	@$(SUDO) rm -f /etc/systemd/system/va-node.service /usr/local/bin/va-agent /usr/local/bin/va-agent-fetch-config
	@$(SUDO) systemctl daemon-reload; echo "removed (settings kept in /etc/va-agent)"

.PHONY: help install status logs config update rollback uninstall
