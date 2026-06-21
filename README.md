<p align="center">
  <img src="docs/img/inferhaven-logo.png" alt="InferHaven lighthouse mark" width="140" />
</p>

<h1 align="center">InferHaven</h1>

  <p align="center"><em>A safe haven for AI inference</em></p>
  <p align="center">
    Self-hostable AI coding server with GPU support, terminal-first design, and complete privacy.
  </p>
</p>

<p align="center">
  <img src="docs/img/demo.gif" alt="InferHaven demo: SSH in, ask a local model to extend the stack, watch it run" width="820" />
</p>

<p align="center">
  <a href="https://github.com/codespaces/new?hide_repo_select=true&repo=InferHaven/inferhaven-core">
    <img src="https://github.com/codespaces/badge.svg" alt="Open in GitHub Codespaces" />
  </a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-FSL--1.1--Apache--2.0-blue.svg" alt="License: FSL-1.1-Apache-2.0" /></a>
  <a href="https://github.com/InferHaven/inferhaven-core/actions/workflows/devcontainer.yml"><img src="https://github.com/InferHaven/inferhaven-core/actions/workflows/devcontainer.yml/badge.svg" alt="Devcontainer smoke tests" /></a>
  <a href="https://discord.gg/X5htGNnEh5"><img src="https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white" alt="Join the InferHaven Discord" /></a>
  <a href="https://github.com/InferHaven/inferhaven-core/stargazers"><img src="https://img.shields.io/github/stars/InferHaven/inferhaven-core?style=social" alt="GitHub stars" /></a>
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> •
  <a href="#configuration">Configuration</a> •
  <a href="#haven-cli">Haven CLI</a> •
  <a href="docs/quickstart.md">Full Guide</a> •
  <a href="docs/harnesses.md">Harnesses & Models</a> •
  <a href="https://inferhaven.com">InferHaven Cloud ↗</a>
</p>

---

## What is InferHaven?

InferHaven is your own private AI coding server: a self-hostable Docker stack that turns hardware you control into a private, secure dev environment. It runs Ollama for local inference and hands you a pre-configured workspace over SSH and a web IDE, with your own models and up to ten coding assistants already wired to them. It isn't another coding assistant competing for your editor; it's the box they all run in.

- **Local AI inference** via Ollama: OpenAI-compatible API, any open-weight model
- **Complete privacy**: local code and weights never leave your machine when you use local models
- **Terminal-first workspace**: SSH (+ mosh for connection-resilient remote shells), tmux with auto-save, zsh + Starship, neovim, ripgrep, fzf, supercronic, lazygit, git-delta, direnv, zoxide, eza, mise, atuin, tmate
- **Web IDE**: VS Code in the browser via code-server
- **Coding harnesses**: Claude Code, OpenCode, Aider, Qwen Code, Amp, Gemini CLI, Goose, Continue CLI, Pi, and Avante, all of which can be auto-installed and pre-configured from `.env`
- **GPU support**: NVIDIA and AMD GPUs supported out of the box
- **Cloud models**: use any popular provider's models instead of, or alongside, your private local models
- **Real security**: leverages Docker for a secure dev environment; SSH is key-only
- **Fast, reproducible builds**: BuildKit cache mounts make warm rebuilds < 30s
- **Multi-user**: provision extra users with their own SSH keys via `.env`
- **Devcontainer-ready**: works with VS Code Dev Containers, GitHub Codespaces, DevPod, JetBrains Gateway, and headless `@devcontainers/cli`. Two flavors ship: a lightweight Codespaces flavor for CPU-only quickstarts and a full-stack flavor that boots the same production services (web IDE + Caddy) with optional GPU passthrough. Nested devcontainers (dev-in-prod) supported via the `haven devcontainer` command.
- **Backup & restore**: `haven backup configure` sets up an rclone remote interactively; `haven backup push <remote:path>` snapshots home directory and harness configs.

## Why not just wire it up myself?

You can, and if you do, you've built the first couple of layers of what InferHaven ships whole. The DIY path is Ollama, plus a web UI, plus each assistant's config, plus a reverse proxy, HTTPS, SSH, and backups: a weekend to assemble and a maintenance tab that never closes, since every assistant's config drifts the moment you pull a new model.

InferHaven is those same parts, assembled and kept in tune. `docker compose up -d` brings the whole stack up, and seven assistants (`opencode`, `aider`, `qwencode`, `pi`, `goose`, `continue`, `avante`) re-render their config automatically on every model pull. It's still just Docker. The exit door is the same size as the front door.

## Quick Start

> **Just want to try it first?** No install needed: click **[Open in GitHub Codespaces](https://github.com/codespaces/new?hide_repo_select=true&repo=InferHaven/inferhaven-core)** (badge above). It boots the CPU-only flavor with a small model (`qwen3:4b`) and `opencode` + `aider` preinstalled. For real use (GPU, web IDE, your own models), self-host below.

**Requirements:** Linux, Docker, Docker Compose v2.

See **[docs/gpu-setup.md](docs/gpu-setup.md)** for full GPU configuration.

```bash
git clone https://github.com/InferHaven/inferhaven-core.git
cd inferhaven-core
cp .env.example .env
chmod 600 .env    # contains API keys — keep it owner-only
# Edit .env — set CODE_SERVER_PASSWORD, AUTHORIZED_KEYS, and any API keys.
# Edit docker-compose.yml - enable required GPU settings, Nvidia + AMD (vulkan or RocM) supported
docker compose up -d
```

Once running:

| Access | Method |
| -------- | --------- |
| SSH | `ssh -p 2222 haven@localhost` |
| Web IDE | `http://localhost` |
| Ollama / OpenAI API | `http://localhost` / `http://localhost/v1/` |

> Ollama and code-server exposed ports are commented out in `docker-compose.yml` by default. All traffic routes through Caddy. To expose them directly, uncomment the `ports:` blocks for the `ollama` and `code-server` services (routes around Caddy security).

For a step-by-step walkthrough see **[docs/quickstart.md](docs/quickstart.md)**.

## Configuration

All configuration lives in `.env` (copy from `.env.example`).

| Variable | Default | Description |
| ---------- | --------- | ------------- |
| `DEFAULT_MODEL` | `qwen3.5:9b` | Model pulled on first startup |
| `CODE_SERVER_PASSWORD` | `inferhaven` | Web IDE password (**change this**) |
| `AUTHORIZED_KEYS` | *(empty)* | SSH public key(s) |
| `DOMAIN` | `localhost` | Domain for auto-HTTPS via Caddy |
| `SSH_PORT` | `2222` | SSH port |
| `OLLAMA_PORT` | `11434` | Ollama API port |
| `INSTALL_ASSISTANTS` | *(empty)* | Harnesses to auto-install on first boot |
| `HAVEN_CTX` | `32768` | Context window target for auto-tune on pull. Use `16384` on memory-constrained hardware |
| `HAVEN_AUTO_TUNE` | `1` | Auto-run `haven tune` after every pull / pullback and for `DEFAULT_MODEL` on boot. Set `0` to disable |
| `HAVEN_FORCE_FAMILY` | *(empty)* | Bypass family detection in `haven tune`. Values: `qwen3` `qwen25` `llama3` `deepseek` `mistral` `phi4` `codellama` `gemma`. Use for custom finetunes you know are template-compatible |
| `GOOSE_CTX_LIMIT` | `32768` | Maximum context passed to Goose sessions. Caps the KV-cache budget regardless of model tuning; reduce to `16384` if you see 30 s stream stalls on constrained hardware |
| `ANTHROPIC_API_KEY` | *(empty)* | For Claude Code, Aider (claude backend), Amp |
| `OPENAI_API_KEY` | *(empty)* | For OpenCode, Aider (openai backend) |
| `GEMINI_API_KEY` | *(empty)* | For Gemini CLI |
| `OPENROUTER_API_KEY` | *(empty)* | For OpenRouter-compatible tools |
| `GITHUB_TOKEN` | *(empty)* | GitHub CLI auth |
| `CLAUDE_CODE_DISABLE_TELEMETRY` | `true` | Disable Claude Code telemetry |
| `INSTALL_STARSHIP` | `1` | Starship prompt (0 = keep Oh My Zsh robbyrussell) |
| `MOSH_PORTS` | `60000-60010` | Host UDP range for mosh. Set empty to skip host mapping (mosh still works internally) |
| `HAVEN_EXTRA_USERS` | *(empty)* | Comma-separated extra users provisioned alongside `haven` (e.g. `alice,bob`) |
| `HAVEN_EXTRA_USERS_SUDO` | *(empty)* | Subset of `HAVEN_EXTRA_USERS` granted passwordless sudo |
| `AUTHORIZED_KEYS_<USER>` | *(empty)* | Per-extra-user SSH key. `USER` is uppercase (e.g. `AUTHORIZED_KEYS_ALICE`) |
| `DOTFILES_REPO` | *(empty)* | Git URL cloned to `~/.dotfiles` on first boot; runs `install.sh` once |

### Coding Assistant Harnesses

Set `INSTALL_ASSISTANTS` and any API keys in `.env` before the first start. Harnesses are installed in the background. SSH is available immediately and they are ready within a minute or two.

```bash
INSTALL_ASSISTANTS=claudecode,opencode,aider
ANTHROPIC_API_KEY=sk-ant-...
```

Supported Harnesses: `claudecode`, `opencode`, `aider`, `qwencode`, `amp`, `gemini`, `pi`, `goose`, `continue`, `avante`

When `opencode`, `aider`, `qwencode`, `pi`, `goose`, `continue`, or `avante` is included, local Ollama models are auto-configured and kept in sync: every `haven pull`, `haven tune`, and `haven remove` updates all harness configs immediately. Most harnesses use an internal sentinel so InferHaven never touches user-customised configs; `continue` syncs whenever `cn` is installed (opt out: `touch ~/.continue/.no-autosync`).

See **[docs/harnesses.md](docs/harnesses.md)** for opt-out, per-project override instructions, and for per-harness setup details and recommended models.

### SSH keys

Single key (no quotes needed):

```bash
AUTHORIZED_KEYS=ssh-ed25519 AAAA... user@host
```

Multiple keys, wrap in double quotes with a real newline:

```bash
AUTHORIZED_KEYS="ssh-ed25519 AAAA...key1 user@host
ssh-ed25519 AAAA...key2 user2@host"
```

## Haven CLI

`haven` is InferHaven's unified CLI. It works in two contexts:

**From the host** (repo directory) manages Docker services:

```bash
./scripts/haven up                   # start all services
./scripts/haven down                 # stop all services
./scripts/haven restart              # restart all services
./scripts/haven logs                 # stream logs (all services)
./scripts/haven logs ollama          # stream logs for a specific service
./scripts/haven update               # pull latest images and restart
./scripts/haven reset                # remove all data (careful)
./scripts/haven status               # service status
./scripts/haven doctor               # diagnose the host environment
./scripts/haven ssh-key "<pubkey>"   # add an SSH public key
./scripts/haven ssh                  # show SSH connection command
./scripts/haven ide                  # show web IDE URL
```

**Inside the workspace** (after SSH-ing in): full feature set:

```bash
# Models
haven models                            # list downloaded models
haven pull <model>                      # download a model (foreground, with live progress)
haven pullback <model>                  # download a model in the background — keep working
haven pullback status                   # show all background download progress
haven pullback cancel <model>           # cancel a background download
haven remove <model>                    # remove a model (updates harness configs)
haven show <model>                      # model details: params, template, system prompt
haven show <model> --modelfile          # print raw Modelfile
haven ps                                # models currently loaded in GPU/RAM
haven unload <model>                    # force-unload from GPU/RAM
haven cp <src> <dest>                   # copy / rename a model
haven chat [model]                      # interactive chat (defaults to DEFAULT_MODEL)
haven run <model>                       # same as chat — TTY interactive session
haven run <model> "your prompt"         # one-shot: print response and exit (scriptable)
echo "prompt" | haven run <model>       # pipe stdin into model
haven bench [model]                     # benchmark tokens/sec (--tokens N --prompt ".." --runs K --json)

# ollama.com account
haven push <model>                      # push a model to ollama.com
haven signin                            # authenticate with ollama.com
haven signout                           # sign out of ollama.com

# Model parameters (instant — no re-download)
haven params <model>                            # show current parameters
haven params <model> set num_ctx 32768          # context window size
haven params <model> set temperature 0.3        # creativity (0.0–2.0)
haven params <model> set num_predict 4096       # max tokens (-1 = unlimited)
haven params <model> set top_p 0.9              # nucleus sampling threshold
haven params <model> set top_k 40               # top-k candidates per step
haven params <model> set repeat_penalty 1.1     # penalise repeated tokens
haven params <model> reset                      # reset all params to defaults

# Model tuning (no re-download — sets num_ctx, stop tokens, template per family)
haven tune <model>                      # optimise for harness use
# Families: qwen2.5 · qwen3 · llama3 · deepseek · mistral · phi4 · codellama

# Harnesses
haven harness                           # show installed harnesses + OpenCode config summary
haven claude                            # launch Claude Code with a local Ollama model
haven aider                             # launch Aider with a local Ollama model
haven goose                             # launch Goose with a local Ollama model
haven qwen                              # launch Qwen Code with a local Ollama model

# Status & diagnostics
haven status                            # service status + model count
haven logs [service]                    # stream service logs
haven doctor                            # diagnose the container environment (incl. P1/P2 binaries, swap, cgroup)
haven service <name> <action>           # docker compose wrapper: status / restart / stop / start / logs
haven limits                            # show container cgroup limits vs host capacity (memory/CPU/swap)
haven gpu-info                          # canonical GPU readout from the metrics-server (driver, util, VRAM)

# Pair-programming + backup (P2)
haven tmate                             # start a backgrounded tmate session — prints SSH/web URLs
haven tmate status                      # print current tmate URLs + uptime
haven tmate fg                          # attach to the active tmate session
haven tmate kill                        # tear down the tmate session
haven backup configure                  # interactive rclone remote setup wizard
haven backup status                     # show local backup paths + configured rclone remotes
haven backup status <remote:path>       # also show size + top-level contents of that remote
haven backup push <remote:path>         # snapshot ~/.haven + ~/.config + ~/.continue to an rclone remote
haven backup pull <remote:path>         # restore from an rclone remote

# Tool-config sync (re-render coding-assistant configs from the live model list)
haven sync                              # re-sync all 7 supported tools in parallel
haven sync <tool>                       # opencode | aider | qwencode | pi | goose | continue | avante
haven sync list                         # list supported tools

# Tmux workspace (sessions auto-save every 15 min, fully restored after restarts)
haven tmux                              # attach to the always-running 'Haven' session
haven tmux attach [name]                # attach to a session (default: Haven)
haven tmux ls                           # list all active sessions
haven tmux new <name>                   # create and attach to a new named session
haven tmux kill <name>                  # kill a session
haven tmux save                         # manually save sessions to disk
haven tmux restore                      # manually restore from last save
haven tmux plugin list                  # list installed plugins
haven tmux plugin install               # install plugins from ~/.tmux.conf
haven tmux plugin update                # update all plugins
haven tmux plugin bootstrap             # reinstall all plugins from scratch
haven tmux help                         # full subcommand reference

# Packages (persist across container restarts)
haven apt install <pkg...>              # install and track apt packages
haven apt remove <pkg...>              # stop tracking a package
haven apt list                          # show tracked packages
haven apt update                        # refresh package lists
haven apt upgrade                       # upgrade all tracked packages

# SSH / IDE
haven ssh-key "<pubkey>"               # add an SSH public key
haven ssh                               # show SSH connection command
haven ide                               # show web IDE URL
haven help                              # show all commands
```

For workspace-specific features (model tuning, background downloads, Starship prompt, persistent packages, and status bar alerts), see **[docs/workspace.md](docs/workspace.md)**.

## Architecture

Four Docker services in a bridge network:

| Service | Image | Purpose |
| --------- | ------- | --------- |
| `ollama` | `ollama/ollama` | AI inference, OpenAI-compatible API on :11434 |
| `workspace` | Custom build | SSH terminal (:2222) + `haven` CLI + harnesses |
| `code-server` | `linuxserver/code-server` | VS Code in Browser |
| `caddy` | `caddy:2-alpine` | Reverse proxy, auto-HTTPS |

```javascript
┌──────────────────────────────────────────────┐
│                 InferHaven                   │
│                                              │
│  ┌───────────┐  ┌──────────┐  ┌───────────┐  │
│  │ Workspace │  │  Ollama  │  │Code Server│  │
│  │ (SSH/tmux)│  │  (AI)    │  │   (IDE)   │  │
│  └────┬──────┘  └────┬─────┘  └─────┬─────┘  │
│       └──────────────┴──────────────┘        │
│                      │                       │
│            ┌─────────┴──────────┐            │
│            │        Caddy       │            │
│            │ (Proxy + auto-TLS) │            │
│            └────────────────────┘            │
└──────────────────────────────────────────────┘
  :2222 SSH  :80/:443 HTTP/HTTPS  :11434 Ollama API
```

Caddy routes: `/status` → status page, `/ide*` → code-server, `/api/*` and `/v1/*` → Ollama, default → code-server.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a pull request.

## Security

Found a vulnerability? **Don't open a public issue.** Report it privately per our [Security Policy](SECURITY.md) (email [lookout@inferhaven.com](mailto:lookout@inferhaven.com)). For sensitive reports, encrypt to our OpenPGP key ([`inferhaven_pub.asc`](inferhaven_pub.asc), also at <https://inferhaven.com/pgpkey.asc>):

> **OpenPGP fingerprint:** `4992 80D5 D75E 3A4F 837C  6A68 85D8 E097 0D05 CEC0`

For deployment hardening (access control, network exposure, TLS, secrets, and the stack's intended trust boundaries), see [docs/security.md](docs/security.md).

## AI-assisted development

AI assistants are part of how InferHaven is built. We use them to accelerate the work: drafting code, refactoring, generating tests, and writing documentation.

What doesn't change: every change is reviewed, understood, and manually tested by a human before it merges. InferHaven is owned and maintained by its human author(s). AI is a tool we use, not the author.

## License

InferHaven Core is licensed under the **Functional Source License 1.1 with Apache 2.0 Future License** (FSL-1.1-Apache-2.0).

**What this means in practice:**

- ✅ You can use, modify, and self-host InferHaven Core for any purpose: personal, commercial, internal, or research.
- ✅ Enterprises can deploy it on their own infrastructure, integrate it with internal tools, and modify it as needed.
- ✅ Consultants and integrators can offer professional services around it.
- ❌ You cannot offer a commercial managed-hosting service that competes with InferHaven Cloud (until each version's two-year window expires).
- 🔄 Two years after each version's release, that version automatically converts to the Apache License 2.0, a fully permissive open-source license with no restrictions.

See the [LICENSE](./LICENSE) file for full terms, [docs/licensing.md](./docs/licensing.md) for a plain-language explainer, and [fsl.software](https://fsl.software/) for background on the license.

---

<p align="center">
  <strong>InferHaven</strong> · A safe haven for AI inference.<br>
  <a href="https://inferhaven.com">Website</a> •
  <a href="https://discord.gg/X5htGNnEh5">Discord</a> •
  <a href="https://twitter.com/InferHaven">Twitter</a>
</p>
