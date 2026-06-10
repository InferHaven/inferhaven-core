.PHONY: up down restart status logs models pull chat ssh ide update reset install help \
        rebuild-fast doctor backup limits gpu-info

COMPOSE := docker compose
HAVEN := ./scripts/haven
export DOCKER_BUILDKIT := 1
export COMPOSE_BAKE := true

# ── Quick Start ─────────────────────────────────────────────────────────────
help: ## Show this help
	@echo ""
	@echo "  InferHaven Core — Makefile"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""

install: ## First-time setup: copy env, build, and start
	@test -f .env || cp .env.example .env
	@echo "Edit .env with your settings, then run: make up"

up: ## Start all services
	$(COMPOSE) up -d --build

down: ## Stop all services
	$(COMPOSE) down

restart: ## Restart all services
	$(COMPOSE) restart

status: ## Show service status
	$(COMPOSE) ps

logs: ## Show logs (use: make logs s=ollama)
	$(COMPOSE) logs -f $(s)

# ── AI Model Management ────────────────────────────────────────────────────
models: ## List downloaded models
	@curl -s http://localhost:11434/api/tags | jq '.models[].name'

pull: ## Pull a model (use: make pull m=qwen2.5-coder:7b)
	@curl -s http://localhost:11434/api/pull -d '{"name": "$(m)"}'

chat: ## Chat with a model (use: make chat m=qwen2.5-coder:7b)
	docker exec -it inferhaven-ollama ollama run $(m)

# ── Access ──────────────────────────────────────────────────────────────────
ssh: ## Show SSH connection info
	@echo "ssh -p 2222 haven@localhost"

ide: ## Open web IDE URL
	@echo "http://localhost:80"

# ── Maintenance ─────────────────────────────────────────────────────────────
update: ## Pull latest images and rebuild
	$(COMPOSE) pull
	$(COMPOSE) up -d --build

reset: ## Remove ALL data and start fresh
	$(COMPOSE) down -v
	@echo "All data removed. Run 'make up' to start fresh."

build: ## Build containers without starting
	$(COMPOSE) build

rebuild-fast: ## Rebuild workspace using BuildKit + cache mounts (fastest path)
	DOCKER_BUILDKIT=1 $(COMPOSE) build workspace
	$(COMPOSE) up -d workspace

# ── Diagnostics ─────────────────────────────────────────────────────────────
doctor: ## Run haven doctor inside the workspace
	$(HAVEN) doctor

backup: ## Backup workspace state via rclone (use: make backup remote=name:path)
	$(HAVEN) backup push $(remote)

limits: ## Show container cgroup limits vs host capacity
	$(HAVEN) limits

gpu-info: ## Canonical GPU readout from metrics-server
	$(HAVEN) gpu-info
