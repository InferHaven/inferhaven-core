# Workspace Tool Sourcing

This document explains how the workspace image sources its tooling — which strategy is used for which tools, why, and how to add or bump them.

## Tool sourcing in the workspace image

The workspace `Dockerfile` uses **four** install strategies, ordered by maintenance cost:

| Source | Tools | Maintenance |
| --- | --- | --- |
| `apt-get install` (Ubuntu noble) | `mosh`, `gh`, `tmate`, `rclone`, `direnv`, `zoxide`, `eza`, `git-delta`, `tmux`, `git`, `git-lfs`, `ripgrep`, `fd-find`, `bat`, `lsd`, `btop`, `tree`, `nodejs`, `python3`, `build-essential`, `docker-ce-cli`, `docker-compose-plugin` | **Zero.** Ubuntu tracks upstream; `apt upgrade` inside the container picks up patches. |
| Vendor installer (`curl ... \| sh`) | `starship`, `mise` | **Zero.** Vendor resolves the latest release at build time. |
| `npm install -g` | `@devcontainers/cli` | **Zero.** npm `latest` tag floats; needed for nested devcontainer support (`haven devcontainer`). |
| `releases/latest/download/<stable-asset>` | `supercronic`, `atuin` | **Zero on quiet days, loud break on asset rename.** GitHub redirects `/latest/` to current release; build fails immediately if the asset name changes (very rare). |
| Pinned `ARG <NAME>_VERSION` | `Go`, `fzf`, `neovim`, `uv`, `lazygit` (asset name embeds version) | **Intentional bumps only.** Pinned because plugin/library compat depends on the toolchain version. |

Adding a new tool:

1. **First check apt** — `curl -s https://packages.ubuntu.com/noble/<pkg> \| grep -oE '<title>[^<]+'` confirms availability. If shipped, append to the apt list — done.
2. If not in apt, prefer a **vendor installer** (`https://<vendor>.run` or signed `install.sh`) over a tarball.
3. Use **`/releases/latest/download/`** only when the asset name is stable across releases.
4. Pin a **`ARG`** only if the user's workflow breaks across minor versions (rare — e.g. neovim plugins, language compilers).

## Bumping pinned tool versions

When a pin needs to move:

1. Resolve the new version:

   ```bash
   curl -s 'https://go.dev/VERSION?m=text' | head -1                                    # Go
   curl -s https://api.github.com/repos/junegunn/fzf/releases/latest      | jq -r .tag_name
   curl -s https://api.github.com/repos/neovim/neovim/releases/latest     | jq -r .tag_name
   curl -s https://api.github.com/repos/astral-sh/uv/releases/latest      | jq -r .tag_name
   curl -s https://api.github.com/repos/jesseduffield/lazygit/releases/latest | jq -r .tag_name
   ```

2. Edit the corresponding `ARG <NAME>_VERSION=...` near the top of `docker/workspace/Dockerfile`.
3. Rebuild: `make rebuild-fast` (BuildKit cache mounts — only the bumped binary re-downloads).
4. Verify inside the container: `ssh -p 2222 haven@localhost <bin> --version`.
5. Open a PR titled `chore(workspace): bump <tool> to <version>` with the changelog link in the body.

One-off override without editing the Dockerfile:

```bash
docker compose build --build-arg GO_VERSION=1.27.0 workspace
```
