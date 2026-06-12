# syntax=docker/dockerfile:1.7
###############################################################################
# InferHaven Workspace — Terminal-First Dev Environment
#
# Ubuntu-based container with:
#   - SSH server, mosh, tmux, zsh, neovim, git + git-delta + lazygit
#   - Docker CLI (Docker-in-Docker via socket mount)
#   - Python 3 + uv, Node.js LTS, Go (latest), Rust toolchain via mise (opt-in)
#   - direnv, zoxide, eza, fzf, ripgrep, fd, bat — modern shell utilities
#   - mise (per-project tool versions), atuin (shared shell history), tmate
#   - rclone (workspace backup), supercronic (cron-in-container)
#   - Coding assistant framework: auto-install + credential injection via
#     INSTALL_ASSISTANTS and *_API_KEY env vars in .env
#
# Build flags:
#   DOCKER_BUILDKIT=1 docker compose build workspace
#
# Bumping pinned versions: edit the ARG defaults below, then rebuild. The
# upgrade flow is documented in CONTRIBUTING.md.
###############################################################################

FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive

# ── Pinned tool versions (toolchain-only — bump per CONTRIBUTING.md) ────────
# Pin policy:
#   - Pin language toolchains where minor versions affect plugin/library compat.
#   - For shell utilities, prefer apt (auto-tracked) or vendor installer (auto-latest).
#   - For tools NOT in apt and without vendor installer, use /releases/latest/download/
#     with stable asset names — fewer pins to maintain.
ARG GO_VERSION=1.26.2
ARG NODE_MAJOR=22
ARG FZF_VERSION=0.72.0
ARG NVIM_VERSION=0.12.2
ARG UV_VERSION=0.11.11
ARG LAZYGIT_VERSION=0.55.1   # asset name embeds version — unavoidable pin

# ── apt: force IPv4, configure all repos before single update ───────────────
# Docker bridge networks have no IPv6 by default. Without ForceIPv4, apt
# resolves AAAA records and silently hangs. Configure all third-party repos
# (Docker, NodeSource) BEFORE the single apt-get update so we run apt only
# once instead of three times.
RUN echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99-inferhaven.conf \
 && install -m 0755 -d /etc/apt/keyrings \
 && apt-get update -qq && apt-get install -y --no-install-recommends \
       ca-certificates curl gnupg lsb-release \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
       -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
       https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
       > /etc/apt/sources.list.d/docker.list \
 && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -

# ── System packages: single apt-get with BuildKit cache mounts ──────────────
# Cache mounts persist across builds — second build does not re-download .deb
# files. Drop the rm -rf /var/lib/apt/lists at the end (cache mount handles it).
#
# Removed from apt list (vs. v0.1.0):
#   vim, htop, nano  — duplicates of nvim/btop/nvim respectively
#
# Added (P1/P2 tools):
#   mosh           — connection-resilient SSH (UDP)
#   gh             — GitHub CLI (referenced by configure-assistants.sh)
#   direnv         — per-project .envrc loader
#   tmate          — instant pair-programming sessions
#   rclone         — workspace_home backup to S3/B2/etc.
#   bash-completion — for gh + git completions
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        openssh-server \
        mosh \
        sudo \
        wget \
        git \
        git-lfs \
        gh \
        tmux \
        tmate \
        zsh \
        jq \
        yq \
        ripgrep \
        fd-find \
        bat \
        eza \
        lsd \
        btop \
        tree \
        unzip \
        zip \
        build-essential \
        python3 \
        python3-pip \
        python3-venv \
        locales \
        bash-completion \
        direnv \
        zoxide \
        git-delta \
        rclone \
        docker-ce-cli \
        docker-buildx-plugin \
        docker-compose-plugin \
        nodejs

# ── Locale ──────────────────────────────────────────────────────────────────
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

# ── Toolchain binaries (pinned ARGs — language tooling, plugin compat) ──────
# Parallel downloads with BuildKit cache mount. Each curl is idempotent.
ENV PATH="/usr/local/go/bin:${PATH}"
RUN --mount=type=cache,target=/tmp/dl set -e; \
    ARCH="$(dpkg --print-architecture)"; \
    case "${ARCH}" in \
      amd64) UV_TRIPLE="x86_64-unknown-linux-musl"; FZF_ARCH="linux_amd64"; \
             NVIM_ARCH="x86_64"; LAZYGIT_ARCH="x86_64" ;; \
      arm64) UV_TRIPLE="aarch64-unknown-linux-musl"; FZF_ARCH="linux_arm64"; \
             NVIM_ARCH="arm64"; LAZYGIT_ARCH="arm64" ;; \
      *)     echo "Unsupported arch: ${ARCH}" && exit 1 ;; \
    esac; \
    cd /tmp/dl; \
    [ -f "go${GO_VERSION}.tar.gz" ]            || curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz"                                                                  -o "go${GO_VERSION}.tar.gz"            & \
    [ -f "fzf-${FZF_VERSION}.tar.gz" ]         || curl -fsSL "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-${FZF_ARCH}.tar.gz"               -o "fzf-${FZF_VERSION}.tar.gz"         & \
    [ -f "uv-${UV_VERSION}.tar.gz" ]           || curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_TRIPLE}.tar.gz"                                 -o "uv-${UV_VERSION}.tar.gz"           & \
    [ -f "nvim-${NVIM_VERSION}.tar.gz" ]       || curl -fsSL "https://github.com/neovim/neovim/releases/download/v${NVIM_VERSION}/nvim-linux-${NVIM_ARCH}.tar.gz"                     -o "nvim-${NVIM_VERSION}.tar.gz"       & \
    [ -f "lazygit-${LAZYGIT_VERSION}.tar.gz" ] || curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_${LAZYGIT_ARCH}.tar.gz" -o "lazygit-${LAZYGIT_VERSION}.tar.gz" & \
    wait; \
    tar -C /usr/local -xzf "go${GO_VERSION}.tar.gz"; \
    tar -xzf "fzf-${FZF_VERSION}.tar.gz" -C /usr/local/bin fzf; chmod +x /usr/local/bin/fzf; \
    tar -xzf "uv-${UV_VERSION}.tar.gz" --strip-components=1 -C /usr/local/bin "uv-${UV_TRIPLE}/uv" "uv-${UV_TRIPLE}/uvx"; \
    chmod +x /usr/local/bin/uv /usr/local/bin/uvx; \
    tar -xzf "nvim-${NVIM_VERSION}.tar.gz" --strip-components=1 -C /usr/local; \
    nvim --version | head -1; \
    tar -xzf "lazygit-${LAZYGIT_VERSION}.tar.gz" -C /usr/local/bin lazygit; chmod +x /usr/local/bin/lazygit

# ── Auto-latest binaries (releases/latest/download — stable asset names) ────
# No version pins to maintain. GitHub redirects /latest/ to current release.
# Build breaks loudly if asset name changes (very rare for these projects).
RUN --mount=type=cache,target=/tmp/dl set -e; \
    ARCH="$(dpkg --print-architecture)"; \
    case "${ARCH}" in \
      amd64) SUPERCRONIC_BIN="supercronic-linux-amd64"; ATUIN_TGT="x86_64-unknown-linux-gnu" ;; \
      arm64) SUPERCRONIC_BIN="supercronic-linux-arm64"; ATUIN_TGT="aarch64-unknown-linux-gnu" ;; \
    esac; \
    cd /tmp/dl; \
    # supercronic — single binary, asset name stable across releases
    curl -fsSL "https://github.com/aptible/supercronic/releases/latest/download/${SUPERCRONIC_BIN}" \
        -o supercronic && install -m 755 supercronic /usr/local/bin/supercronic; \
    # atuin — tarball with stable asset name pattern
    if curl -fsSL "https://github.com/atuinsh/atuin/releases/latest/download/atuin-${ATUIN_TGT}.tar.gz" \
        -o atuin.tar.gz 2>/dev/null && [ -s atuin.tar.gz ]; then \
        tar -xzf atuin.tar.gz --strip-components=1 -C /tmp \
            "$(tar -tzf atuin.tar.gz | grep -E '/atuin$' | head -1)" 2>/dev/null \
            && install -m 755 /tmp/atuin /usr/local/bin/atuin \
            || echo "[build] atuin extract failed — skipping (apt fallback unavailable)"; \
    else \
        echo "[build] atuin download failed — skipping (not in apt 24.04)"; \
    fi; \
    /usr/local/bin/supercronic -version 2>&1 | head -1 || true; \
    /usr/local/bin/atuin --version 2>&1 | head -1 || echo "atuin: not installed"

# ── Vendor installers (auto-latest, vendor-maintained) ──────────────────────
# starship: official install script — handles arch detection + signature verify.
# mise: official install script — sets MISE_INSTALL_PATH for system-wide install.
RUN curl -sS https://starship.rs/install.sh | sh -s -- --yes \
    && curl -fsSL https://mise.run | env MISE_INSTALL_PATH=/usr/local/bin/mise sh

# ── @devcontainers/cli (npm global) ─────────────────────────────────────────
# Required for nested devcontainer support: a contributor SSH'd into a
# production workspace can run `haven devcontainer up <path>` to spin up an
# isolated dev stack inside it. Also handy for headless CI use.
RUN npm install -g @devcontainers/cli \
    && devcontainer --version | head -1

# ── docker-credential-devpod stub (nested DevPod-in-DevPod compatibility) ──
# When the workspace is brought up by DevPod, the outer DevPod CLI writes a
# `credHelpers` entry into ~/.docker/config.json pointing at a wrapper named
# `docker-credential-devpod` that lives in the outer's ~/.devpod/ tree. That
# wrapper is NOT visible from inside the workspace container, so any docker
# build (including BuildKit's syntax-image resolution) inside the workspace
# fails with `docker-credential-devpod: executable file not found in $PATH`.
#
# This stub satisfies the lookup with a no-op helper that returns empty
# credentials. Docker then falls back to anonymous auth, which is correct
# for public images (caddy:2-alpine, docker/dockerfile:1.7, etc.). Users
# who actually need DevPod-Pro registry auth inside the workspace can shadow
# this with the real wrapper.
RUN printf '%s\n' \
        '#!/bin/sh' \
        '# InferHaven no-op stub — see docker/workspace/Dockerfile.' \
        'case "$1" in' \
        '  get)   read REG; printf "{\"ServerURL\":\"%s\",\"Username\":\"\",\"Secret\":\"\"}\n" "$REG" ;;' \
        '  store) cat >/dev/null ;;' \
        '  erase) cat >/dev/null ;;' \
        '  list)  printf "{}\n" ;;' \
        'esac' \
        'exit 0' \
        > /usr/local/bin/docker-credential-devpod \
    && chmod +x /usr/local/bin/docker-credential-devpod

# ── SSH server config ───────────────────────────────────────────────────────
# Same explicit sshd_config as before — Include glob removed to avoid
# Ubuntu cloud-init overrides. AcceptEnv adds MOSH_* for mosh-server pass-through.
RUN mkdir -p /run/sshd && \
    printf '%s\n' \
        'Port 22' \
        'AddressFamily any' \
        'ListenAddress 0.0.0.0' \
        'ListenAddress ::' \
        '' \
        'HostKey /etc/ssh/ssh_host_ed25519_key' \
        'HostKey /etc/ssh/ssh_host_rsa_key' \
        '' \
        'LoginGraceTime 2m' \
        'PermitRootLogin no' \
        'StrictModes no' \
        '' \
        'PubkeyAuthentication yes' \
        'AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys.auto' \
        '' \
        'PasswordAuthentication no' \
        'PermitEmptyPasswords no' \
        'ChallengeResponseAuthentication no' \
        '' \
        'UsePAM yes' \
        'AllowAgentForwarding yes' \
        'AllowTcpForwarding yes' \
        'GatewayPorts no' \
        'X11Forwarding no' \
        'PrintMotd no' \
        'TCPKeepAlive yes' \
        'UseDNS no' \
        '' \
        'AcceptEnv LANG LC_* TERM COLORTERM TERM_PROGRAM WEZTERM_EXECUTABLE KITTY_WINDOW_ID MOSH_*' \
        'Subsystem sftp internal-sftp' \
    > /etc/ssh/sshd_config

# ── Create haven user ──────────────────────────────────────────────────────
# ubuntu:24.04 ships a built-in 'ubuntu' user at UID 1000. Remove it so haven
# is assigned UID 1000 (matches code-server's PUID=1000 via shared volume).
RUN userdel -f ubuntu 2>/dev/null || true \
    && groupdel ubuntu 2>/dev/null || true \
    && useradd -m -u 1000 -s /bin/zsh haven \
    && echo "haven ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/haven \
    && mkdir -p /home/haven/.ssh /home/haven/projects /home/haven/.apt-repos \
    && chown -R haven:haven /home/haven \
    && chmod 700 /home/haven/.ssh

# ── fd and bat symlinks (Ubuntu renames them) ───────────────────────────────
RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat

# ── System-wide PATH for all session types ──────────────────────────────────
# Three coverage layers needed because bash and zsh disagree about which
# rc/profile to source for non-interactive non-login shells (e.g. the
# `docker exec ... bash scripts/devcontainer-smoke.sh` path):
#   1. ENV PATH=… (Dockerfile)         → inherited by every `docker exec` and
#                                         every container process, including
#                                         non-login non-interactive bash.
#   2. /etc/profile.d/haven-path.sh   → sh/bash *login* shells.
#   3. /etc/zsh/zshenv                → every zsh instance, all session types.
# Keeping all three in sync — single source of truth for the same path list.
ENV PATH="/home/haven/.npm-global/bin:/home/haven/.local/bin:/home/haven/.opencode/bin:/home/haven/.local/share/mise/shims:/home/haven/.cargo/bin:/home/haven/go/bin:/usr/local/go/bin:${PATH}"
RUN printf '%s\n' \
      '# InferHaven: user tool paths' \
      'export PATH="/home/haven/.npm-global/bin:/home/haven/.local/bin:/home/haven/.opencode/bin:/home/haven/.local/share/mise/shims:/home/haven/.cargo/bin:/home/haven/go/bin:/usr/local/go/bin:${PATH}"' \
      > /etc/profile.d/haven-path.sh \
    && mkdir -p /etc/zsh \
    && printf '%s\n' \
      '# InferHaven: user tool paths — loaded for every zsh instance' \
      'typeset -U path 2>/dev/null || true' \
      'path=("/home/haven/.npm-global/bin" "/home/haven/.local/bin" "/home/haven/.opencode/bin" "/home/haven/.local/share/mise/shims" "/home/haven/.cargo/bin" "/home/haven/go/bin" "/usr/local/go/bin" $path)' \
      'export PATH' \
      > /etc/zsh/zshenv

# ── Zsh + Oh My Zsh + plugins (single tarball / shallow clones, BuildKit-cached) ──
USER haven
WORKDIR /home/haven

RUN --mount=type=cache,target=/home/haven/.cache,uid=1000,gid=1000 \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended \
    && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
       ${ZSH_CUSTOM:-/home/haven/.oh-my-zsh/custom}/plugins/zsh-autosuggestions \
    && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting \
       ${ZSH_CUSTOM:-/home/haven/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

# ── TPM + tmux persistence plugins ─────────────────────────────────────────
# Single source of truth — entrypoint no longer re-clones on every start.
RUN git clone --depth=1 https://github.com/tmux-plugins/tpm \
      /home/haven/.tmux/plugins/tpm \
    && git clone --depth=1 https://github.com/tmux-plugins/tmux-resurrect \
      /home/haven/.tmux/plugins/tmux-resurrect \
    && git clone --depth=1 https://github.com/tmux-plugins/tmux-continuum \
      /home/haven/.tmux/plugins/tmux-continuum \
    && mkdir -p /home/haven/.tmux/resurrect

# ── npm global prefix (baked into image) ───────────────────────────────────
RUN npm config set prefix /home/haven/.npm-global

# ── Shell configuration ────────────────────────────────────────────────────
COPY --link --chown=1000:1000 config/.zshrc     /home/haven/.zshrc
COPY --link --chown=1000:1000 config/.bashrc    /home/haven/.bashrc
COPY --link --chown=1000:1000 config/.tmux.conf /home/haven/.tmux.conf

# ── Helper scripts + shared lib ─────────────────────────────────────────────
USER root
COPY --link scripts/lib                         /usr/local/lib/haven/
COPY --link scripts/entrypoint.sh               /usr/local/bin/entrypoint.sh
COPY --link scripts/add-ssh-key.sh              /usr/local/bin/add-ssh-key
COPY --link scripts/haven.sh                    /usr/local/bin/haven
COPY --link scripts/haven-install.sh            /usr/local/bin/haven-install
COPY --link scripts/haven-logrotate.sh          /usr/local/bin/haven-logrotate
COPY --link scripts/haven-migrate-home.sh       /usr/local/bin/haven-migrate-home
COPY --link scripts/haven-models-cache-warm.sh  /usr/local/bin/haven-models-cache-warm
COPY --link scripts/devcontainer-setup.sh       /usr/local/bin/devcontainer-setup.sh
COPY --link scripts/configure-assistants.sh     /usr/local/bin/configure-assistants.sh
COPY --link scripts/install-assistants.sh       /usr/local/bin/install-assistants.sh
COPY --link scripts/metrics-server.js           /usr/local/bin/metrics-server.js
COPY --link scripts/inferhaven-status.sh        /usr/local/bin/inferhaven-status
COPY --link scripts/inferhaven-loaded.sh        /usr/local/bin/inferhaven-loaded
COPY --link scripts/inferhaven-model-info.sh    /usr/local/bin/inferhaven-model-info
COPY --link scripts/inferhaven-sysmon.sh        /usr/local/bin/inferhaven-sysmon
COPY --link scripts/inferhaven-right-popup.sh   /usr/local/bin/inferhaven-right-popup
COPY --link scripts/inferhaven-alert-watcher.sh /usr/local/bin/inferhaven-alert-watcher
COPY --link scripts/inferhaven-alerts-popup.sh  /usr/local/bin/inferhaven-alerts-popup
COPY --link scripts/ih-pane-capture.sh          /usr/local/bin/ih-pane-capture
COPY --link scripts/ih-pane-restore.sh          /usr/local/bin/ih-pane-restore
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/add-ssh-key \
             /usr/local/bin/haven \
             /usr/local/bin/haven-install \
             /usr/local/bin/haven-logrotate \
             /usr/local/bin/haven-migrate-home \
             /usr/local/bin/haven-models-cache-warm \
             /usr/local/bin/devcontainer-setup.sh \
             /usr/local/bin/configure-assistants.sh \
             /usr/local/bin/install-assistants.sh \
             /usr/local/bin/metrics-server.js \
             /usr/local/bin/inferhaven-status \
             /usr/local/bin/inferhaven-loaded \
             /usr/local/bin/inferhaven-model-info \
             /usr/local/bin/inferhaven-sysmon \
             /usr/local/bin/inferhaven-right-popup \
             /usr/local/bin/inferhaven-alert-watcher \
             /usr/local/bin/inferhaven-alerts-popup \
             /usr/local/bin/ih-pane-capture \
             /usr/local/bin/ih-pane-restore

# ── Starship default config + crontab (baked into image, copied on first start) ──
RUN mkdir -p /etc/inferhaven
COPY --link config/starship.toml      /etc/inferhaven/starship.toml
COPY --link config/crontab            /etc/inferhaven/crontab
COPY --link config/mise.toml.example  /etc/inferhaven/mise.toml.example

EXPOSE 22 60000-60010/udp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
