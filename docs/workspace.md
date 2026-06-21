# Workspace Reference

Features available inside the InferHaven workspace after SSH login or in the web IDE terminal.

---

## Model tuning

`haven tune <model>` applies coding-assistant optimisations to a model in-place, no re-download. Runs automatically after every `haven pull` and on container boot for `DEFAULT_MODEL`. Set `HAVEN_AUTO_TUNE=0` in `.env` to disable.

### Safe-by-default principle

Tuning is **only allowed to help, never hurt**. The classifier matches only known-tested model versions; anything it doesn't recognise, newer variants, custom finetunes, heavy-quant HF GGUFs, falls through to `generic`, which writes nothing but `num_ctx`. `TEMPLATE`, `SYSTEM`, and every other `PARAMETER` line are preserved verbatim. If a name fits a tested family, a Modelfile rewrite happens; otherwise the model is left alone except for the context-window cap.

What a full tune does:

1. **Stop tokens**: correct end-of-response tokens for the model's family
2. **Context window**: sets `num_ctx` to `HAVEN_CTX` (default `32768`), capped at the model's native GGUF max so KV-cache never exceeds the weights' support
3. **Template**: family-specific Go template injected only where it has been validated. Qwen2.5 and Gemma2/3 keep their embedded Jinja templates (replacing them silently breaks tool calls).

After any tune, installed harness configs (`opencode`, `aider`, `qwencode`, `pi`, `goose`, `continue`, `avante`) are re-rendered automatically.

### Tested families (full tune applied)

| Name pattern | Family | Template injected? | Stops added |
| -------------- | -------- | -------------------- | ------------- |
| `qwen2.5`, `qwen2.5-coder`, `qwen2.5-*` | `qwen25` | preserve embedded | `<\|im_end\|>`, `<\|endoftext\|>` |
| `qwen3`, `qwen3-coder`, `qwen3-*` | `qwen3` | inject no-think | + `<\|tool_call_end\|>` |
| `llama3`, `llama3.{1,2,3}`, `llama-3.*` | `llama3` | inject Llama3 headers | `<\|eot_id\|>`, `<\|end_of_text\|>` |
| `deepseek-{r1,coder,coder-v2,v2,v3}` | `deepseek` | inject DeepSeek triangle tokens | `<\|end▁of▁sentence\|>` |
| `mistral`, `mistral-{nemo,small,large}` | `mistral` | inject `[INST]/[/INST]` | `</s>` |
| `phi4`, `phi-4` | `phi4` | inject Phi-4 tokens | `<\|end\|>`, `<\|endoftext\|>` |
| `codellama`, `code-llama` | `codellama` | inject Llama2 `<<SYS>>` | `</s>` |
| `gemma2`, `gemma3` | `gemma` | preserve embedded | `<end_of_turn>` |

### Falls to `generic` (safe defaults: only `num_ctx`)

- Qwen 3.5 / 3.6 / 3.7+ (incl. heavy-quant `hf.co/unsloth/Qwen3.6-…`)
- Llama 2 / Llama 4
- Mixtral, Devstral, Magistral
- Phi-3, Phi-3.5
- Gemma 1, Gemma 4+
- Granite, Command-R, Yi, custom finetunes, any unfamiliar name

The classifier strips registry prefixes (`hf.co/<user>/`, `ghcr.io/<org>/`, `registry.ollama.ai/library/`) and the `:tag` suffix before matching, so detection is consistent across naming conventions.

### Forcing a family

If you have a custom finetune you know is compatible with a tested family's template, opt in explicitly:

```bash
HAVEN_FORCE_FAMILY=qwen3 haven tune my-custom-qwen3-finetune:7b
# or persist for auto-tune at boot:
echo 'HAVEN_FORCE_FAMILY=qwen3' >> .env
```

Valid values: `qwen3` `qwen25` `llama3` `deepseek` `mistral` `phi4` `codellama` `gemma`.

### Dry run

Preview the exact Modelfile changes without applying:

```bash
haven tune --dry-run qwen3:8b
```

Prints a unified diff and exits. No `ollama create` call is made.

### Untune (restore from backup)

The first time `haven tune` (or `haven params set`/`reset`) modifies a model, the original Modelfile is snapshotted to `~/.haven/modelfile-backups/<slug>.modelfile` (mode 600, in the workspace home volume). Restore at any time:

```bash
haven untune qwen3:8b
```

This rewrites the Modelfile to the byte-identical pre-haven copy and unloads the model. Useful if a tune broke something or you want to A/B compare. The backup is retained after untune, you can re-tune and untune freely.

```bash
haven tune qwen2.5-coder:7b
haven show qwen2.5-coder:7b --modelfile   # verify
haven params qwen2.5-coder:7b             # verify parameters
```

---

## Background model downloads

`haven pullback` starts an Ollama model download in the background so you can keep working:

```bash
haven pullback qwen2.5-coder:14b        # start download, return to prompt immediately
haven pullback status                   # check progress of all background downloads
haven pullback cancel qwen2.5-coder:14b # cancel
```

Progress is tracked in `~/.haven/downloads/` and visible in the tmux status bar in real time. Up to 5 parallel downloads are supported. Auto-tune and harness config sync run automatically on completion, same as `haven pull`.

---

## Persistent packages

The workspace home directory (`/home/haven`) is a Docker volume, everything in it survives `docker compose down && docker compose up`. Language-specific installs (`go install`, `cargo install`, `uv tool install`, `npm install -g`, `pip install --user`) all land in the home volume by default.

For apt packages, use `haven apt` instead of `sudo apt install` to persist them across container restarts.

---

## Starship prompt

InferHaven ships with [Starship](https://starship.rs) enabled by default (`INSTALL_STARSHIP=1`). It shows git status, active language versions, background job count (surfaces `haven pullback` workers), and command duration for slow operations.

**Nerd Font (recommended):** Install [JetBrains Mono Nerd Font](https://www.nerdfonts.com), or any Nerd Font, in your **terminal emulator** (client-side, not in the container).

**Switching prompt mode:** Use `haven starship` from inside the workspace to manage the badge style:

| Command | Effect |
| --------- | -------- |
| `haven starship` | Show current mode, version, and config path |
| `haven starship emoji` | Switch badge to 🏡 IH, no Nerd Font required |
| `haven starship nf` | Switch badge to 󰚊 IH (Nerd Font icon) |
| `haven starship reset` | Restore InferHaven default config |
| `haven starship edit` | Open `~/.config/starship.toml` in `$EDITOR` |

The switch patches `~/.config/starship.toml` directly, so it persists across reconnects and tmux reattaches. Open a new shell after switching (`exec $SHELL -l`) to see the change.

To opt out entirely: set `INSTALL_STARSHIP=0` in `.env`. Customise by editing `~/.config/starship.toml`, InferHaven never overwrites it after the first start.

---

## Web IDE terminal

The code-server integrated terminal (opened with `` Ctrl+` `` or from the Terminal menu) automatically SSH's into the workspace container, giving you the full environment, zsh, all installed tools, tmux, and your persistent home directory, without leaving the browser.

This is wired up automatically on first start: code-server generates a dedicated keypair, authorizes it in the workspace, and configures itself as the default terminal profile. No manual setup required.

The terminal reconnects to a fresh SSH session on each open; there is no persistent process between tabs. To keep a long-running session alive across terminal closes, attach to the tmux Haven session:

```bash
haven tmux   # attach to the always-running Haven session
```

---

## Status bar alerts

A background watcher monitors the Ollama container for OOM kills and unexpected crashes. When an event is detected, a bold red **⚠ N ALERT** indicator appears in the tmux status bar. Click the right side of the status bar to open the alert viewer, alerts are shown in an fzf list, select and press Enter to dismiss (permanently deleted). Once all alerts are cleared the popup reverts to the normal system monitor.

The status bar pulls metrics (CPU / RAM / GPU / VRAM / disk) from the in-container metrics server on `:9091`, a single cached source that eliminates `docker exec` calls in the 5 s tmux refresh loop. The same data is available via `curl localhost:9091/metrics.json` if you want to script against it.

---

## Bare-metal-equivalent tools

The workspace ships a curated set of CLI tools so you don't have to install them yourself:

| Tool | Purpose |
| ---- | ------- |
| `mosh` | Connection-resilient SSH over UDP. Survives flaky WiFi, instant typing on high-latency links. Default UDP range `60000-60010` (override via `MOSH_PORTS` in `.env`). |
| `gh` | GitHub CLI, `gh pr create`, `gh issue list`, etc. Authenticate with `GITHUB_TOKEN` in `.env` or `gh auth login`. |
| `lazygit` | TUI git client, review/stage/commit/rebase without leaving the terminal. |
| `delta` | Side-by-side syntax-highlighted git diffs. Wired into git via the default `~/.gitconfig` (`pager.diff = delta`). |
| `direnv` | Per-project `.envrc` loader, auto-exports environment variables when you `cd` into a directory. |
| `zoxide` | Smart `cd`, `z proj` jumps to your most-used directory. |
| `eza` | Modern `ls` with icons, git integration, and tree mode. Aliased to `ls`/`ll`/`la`. |
| `fzf` | Fuzzy finder, `Ctrl-T` for files, `Ctrl-R` for shell history, `Alt-C` for `cd`. |
| `mise` | Per-project tool versions (replaces nvm/pyenv/rbenv). Drop a `.mise.toml` in your repo: `mise use node@20 python@3.12`. |
| `atuin` | Searchable shell history. Up-arrow remains stock; `Ctrl-R` opens atuin's TUI search. Local-only by default. |
| `tmate` | Instant pair-programming sessions, `haven tmate` prints an SSH URL for collaborators to join. |
| `rclone` | Sync workspace state to S3, B2, Drive, etc. Drives `haven backup`. |
| `supercronic` | Cron-in-container. Runs `haven-logrotate` daily and warms the model cache every 30 min. |

Tools come from `apt` (Ubuntu noble), vendor installers, or pinned tarballs, see [docs/development/tool-sourcing.md](development/tool-sourcing.md#tool-sourcing-in-the-workspace-image) for the sourcing strategy and how to add new tools.

---

## Service / system introspection (`haven service|limits|gpu-info`)

Three subcommands surface container internals without manual `docker inspect` / `cat /sys/fs/cgroup/...`:

```bash
haven service ollama status      # show "running: started 2026-05-08T..."
haven service ollama restart     # docker compose restart ollama
haven service ollama logs --tail 50
haven service workspace stop
haven service caddy start

haven limits                     # cgroup memory.max + cpu.max vs host /proc/meminfo + /proc/cpuinfo
                                 # also flags missing host swap (workloads near OOM crash hard)

haven gpu-info                   # canonical GPU readout from metrics-server:9091
```

`haven doctor` also runs an expanded check: every P1/P2 binary version, swap presence, supercronic process status, cgroup headroom.

---

## Pair programming (`haven tmate`)

```bash
haven tmate
# Tmate URL printed — share it with a collaborator. Their input + your input
# both drive the same shell. End the session with Ctrl-d.
```

Built on top of `tmate.io`, sessions are encrypted end-to-end, no account required.

---

## Backup & restore (`haven backup`)

```bash
haven backup status              # list configured rclone remotes + sizes of paths to be backed up
haven backup push gdrive:haven   # snapshot ~/.haven, ~/.config, ~/.continue, ~/.inferhaven
haven backup pull gdrive:haven   # restore from a remote
```

Rclone supports S3, B2, Drive, OneDrive, SFTP, and many more. Run `rclone config` once to set up a remote before using `haven backup push`.

---

## Multi-user (`HAVEN_EXTRA_USERS`)

Add team members alongside the primary `haven` user. Each gets their own home, their own SSH keys, and their own `~/.inferhaven` environment.

```bash
# .env
HAVEN_EXTRA_USERS=alice,bob
HAVEN_EXTRA_USERS_SUDO=alice           # optional — comma-separated subset granted sudo
AUTHORIZED_KEYS_ALICE="ssh-ed25519 AAAA... alice@laptop"
AUTHORIZED_KEYS_BOB="ssh-ed25519 AAAA... bob@laptop"
```

After `docker compose restart workspace`:

```bash
ssh -p 2222 alice@<host>     # alice's own home, own shell, own configs
ssh -p 2222 bob@<host>       # bob's own home, isolated from alice
```

All extra users share Docker socket access (in the `docker` group). They share the workspace tmux server and the same Ollama instance.

---

## Dotfiles bootstrap (`DOTFILES_REPO`)

Bring your own dotfiles. On first boot only, the entrypoint clones `DOTFILES_REPO` into `~/.dotfiles` and runs `install.sh` (or `setup.sh` if no `install.sh`). A sentinel at `~/.haven/.dotfiles-installed` prevents re-runs.

```bash
# .env
DOTFILES_REPO=https://github.com/<you>/dotfiles.git
```

If your install script writes `~/.zshrc` or `~/.tmux.conf`, it overrides the InferHaven defaults, your customisations win.
