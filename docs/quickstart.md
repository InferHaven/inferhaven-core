# Quick Start Guide

Get InferHaven running in 5 minutes.

## Prerequisites

- Linux machine (Tested on Ubuntu 22.04+, and Debian 12+, but any distro with Docker should work)
- Docker Engine 24+ and Docker Compose v2
- Minimum 8 GB RAM (16 GB+ recommended for larger models)
- Optional: NVIDIA GPU + Container Toolkit for GPU acceleration (Should work on WSL in Windows)

Not sure if your system is ready? Run `haven doctor` after cloning.

## Step 1: Clone and configure

```bash
git clone https://github.com/InferHaven/inferhaven-core.git
cd inferhaven-core
cp .env.example .env
chmod 600 .env
```

Edit `.env`. Critical settings:

```bash
# REQUIRED: change the default password
CODE_SERVER_PASSWORD=your-secure-password

# RECOMMENDED: add your SSH public key
AUTHORIZED_KEYS=ssh-ed25519 AAAA... you@host

# OPTIONAL: default model (pulled automatically on first boot)
DEFAULT_MODEL=qwen3.5:9b

# OPTIONAL: auto-install harnesses (installed in background, SSH is not delayed)
INSTALL_ASSISTANTS=claudecode,opencode,aider
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
GEMINI_API_KEY=...
```

See [harnesses.md](harnesses.md) for the full list of supported harnesses and model recommendations.

See [gpu-setup.md](gpu-setup.md) for configuring the `docker-compose.yml` properly for your GPU model.

## Step 2: Start

```bash
docker compose up -d
```

First startup builds the workspace image and downloads the default model — typically 2–5 minutes. Watch progress:

```bash
docker compose logs -f
```

## Step 3: Connect

| Access | Address |
| -------- | --------- |
| Terminal (SSH) | `ssh -p 2222 haven@localhost` |
| Terminal (mosh) | `mosh --ssh="ssh -p 2222" haven@<host>` (UDP `60000-60010`) |
| Web IDE | `http://localhost/ide/` (password from `.env`) |
| Ollama API | `http://localhost/v1/` (OpenAI-compatible, via Caddy) |

> Ollama and code-server direct ports are commented out in `docker-compose.yml` by default. To expose them directly, uncomment the `ports:` blocks for the `ollama` and `code-server` services.

Check everything is up:

```bash
./scripts/haven status
```

## Step 4: Start coding

From inside the workspace (SSH or web IDE terminal):

```bash
# See what models are installed
haven models

# Chat interactively
haven chat

# Pull additional models (auto-tuned, harness configs updated automatically)
haven pull llama3.1:8b
haven pull qwen2.5-coder:7b

# Benchmark tokens/sec on your own hardware
# "generation" is the decode rate (excludes model load + prompt eval) — the honest number.
haven bench qwen2.5-coder:7b --runs 3     # average of 3 runs (recommended; prompt t/s is noisy on short prompts)
haven bench qwen2.5-coder:7b --json       # machine-readable, for scripting / sharing

# See installed harnesses and OpenCode config
haven harness

# Use a coding assistant harness, like aider, against a local model
cd ~/projects/your-repo
aider --model ollama/qwen2.5-coder:7b
```

## What's next?

- **[Workspace reference](workspace.md)** — model tuning, background downloads, bare-metal-equivalent tools (lazygit, delta, direnv, zoxide, eza, mise, atuin, tmate), `haven service|limits|gpu-info`, multi-user, dotfiles bootstrap, backup
- **[Harnesses & model recommendations](harnesses.md)** — per-harness setup and model tables
- **[GPU setup](gpu-setup.md)** — run larger, faster models
- **IDE integrations** — [Continue.dev](ide/continue.md), [Cline](ide/cline.md), [Cursor](ide/cursor.md), [avante.nvim](ide/avante-nvim.md)
- **[Contributing](../CONTRIBUTING.md)** — tool sourcing strategy, version-bump flow
