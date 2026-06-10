#!/usr/bin/env bash
###############################################################################
# InferHaven Workspace — Coding Assistant Installer
#
# Runs in the background at container start (spawned from entrypoint.sh).
# Installs coding assistant harnesses listed in INSTALL_ASSISTANTS.
#
# This script runs AS THE HAVEN USER with HOME set to /home/haven.
# Progress is written to ~/.haven/install.log — not stdout (SSH is unaffected).
#
# Supported tools (INSTALL_ASSISTANTS is comma-separated):
#   claudecode  — @anthropic-ai/claude-code     (npm)
#   opencode    — opencode                      (autoscript, npm fallback)
#   aider       — aider-chat                    (uv tool install)
#   qwencode    — @qwen-code/qwen-code          (autoscript, npm fallback)
#   amp         — @sourcegraph/amp              (npm)
#   gemini      — @google/gemini-cli            (npm)
#   pi          — @mariozechner/pi-coding-agent (npm)
#   goose       — Goose AI CLI                  (curl installer)
#   continue    — @continuedev/cli              (npm, binary: cn)
#   avante      — avante.nvim                   (Neovim plugin via lazy.nvim)
#
# Example .env:
#   INSTALL_ASSISTANTS=claudecode,opencode,aider
###############################################################################
set -uo pipefail

HAVEN_DIR="${HOME}/.haven"
mkdir -p "${HAVEN_DIR}"

LOG="${HAVEN_DIR}/install.log"
MANIFEST="${HAVEN_DIR}/installed-assistants"
touch "${MANIFEST}"

log() {
    echo "[$(date '+%H:%M:%S')] [install] $*" >> "${LOG}"
}

# Ensure all user tool paths are in PATH for this script
# (non-interactive shells don't source .zshrc or .zprofile)
export PATH="${HOME}/.npm-global/bin:${HOME}/.local/bin:${HOME}/.cargo/bin:${HOME}/go/bin:/usr/local/go/bin:/usr/local/bin:${HOME}/.opencode/bin:${PATH}"

# ── Guard ─────────────────────────────────────────────────────────────────────
if [ -z "${INSTALL_ASSISTANTS:-}" ]; then
    exit 0
fi

log "Starting installation: ${INSTALL_ASSISTANTS}"

IFS=',' read -ra TOOLS <<< "${INSTALL_ASSISTANTS}"

# ── Helpers ───────────────────────────────────────────────────────────────────

mark_installed() {
    grep -qxF "$1" "${MANIFEST}" 2>/dev/null || echo "$1" >> "${MANIFEST}"
}

# Append a path directory to ~/.inferhaven if not already present.
# ~/.inferhaven is sourced by both ~/.bash_profile and ~/.zprofile on login,
# so this persists across all future shell sessions without a rebuild.
add_to_path() {
    local dir="$1"
    local inferhaven="${HOME}/.inferhaven"
    [ -d "${dir}" ] || return 0
    grep -qF "${dir}" "${inferhaven}" 2>/dev/null && return 0
    echo "export PATH=\"${dir}:\${PATH}\"" >> "${inferhaven}"
    log "PATH: added ${dir} to ~/.inferhaven."
}

install_npm() {
    local label="$1" pkg="$2" bin="$3"
    if command -v "${bin}" &>/dev/null; then
        log "${label}: already installed ($(${bin} --version 2>/dev/null || echo 'ok'))."
        mark_installed "${label}"
        return 0
    fi
    log "${label}: installing via npm (${pkg})..."
    if npm install -g "${pkg}" >> "${LOG}" 2>&1; then
        log "${label}: OK — $(command -v "${bin}" 2>/dev/null || echo "${HOME}/.npm-global/bin/${bin}")."
        mark_installed "${label}"
    else
        log "${label}: FAILED — check ${LOG} for details."
        return 1
    fi
}

install_uv_tool() {
    local label="$1" pkg="$2" bin="$3"
    if command -v "${bin}" &>/dev/null; then
        log "${label}: already installed."
        mark_installed "${label}"
        return 0
    fi
    if ! command -v uv &>/dev/null; then
        log "${label}: uv not available. Cannot install ${pkg}."
        return 1
    fi
    log "${label}: installing via uv (${pkg})..."
    if uv tool install "${pkg}" >> "${LOG}" 2>&1; then
        log "${label}: OK."
        mark_installed "${label}"
    else
        log "${label}: FAILED — check ${LOG} for details."
        return 1
    fi
}

# ── Tool-config sync: single driver in lib/haven-sync.sh ──────────────────────
# Replaces 7 former configure_*_ollama functions. Each tool calls
# `_haven_sync <tool>` after install — driver handles cache + atomic write.
# shellcheck source=/dev/null
. /usr/local/lib/haven/haven-models.sh
# shellcheck source=/dev/null
. /usr/local/lib/haven/haven-sync.sh
HAVEN_LOG="${LOG}"
export HAVEN_LOG

# ── Avante post-install (lazy.nvim + avante binary — not handled by sync driver) ──
configure_avante_postinstall() {
    local nvim_dir="${HOME}/.config/nvim"
    mkdir -p "${nvim_dir}/lua/plugins"
    if [ ! -f "${nvim_dir}/init.lua" ]; then
        cat > "${nvim_dir}/init.lua" << 'INIT_LUA'
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({"git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git", "--branch=stable", lazypath})
end
vim.opt.rtp:prepend(lazypath)
require("lazy").setup("plugins")
INIT_LUA
        chmod 600 "${nvim_dir}/init.lua"
    fi

    local lazy_path="${HOME}/.local/share/nvim/lazy/lazy.nvim"
    if [ ! -d "${lazy_path}/.git" ]; then
        log "avante: cloning lazy.nvim..."
        git clone --filter=blob:none --branch=stable \
            https://github.com/folke/lazy.nvim.git "${lazy_path}" >> "${LOG}" 2>&1 \
            || log "avante: lazy.nvim clone failed — check ${LOG}."
    fi

    log "avante: running lazy.nvim sync (installing plugin + build step, this may take ~1-2 min)..."
    if timeout 300 nvim --headless "+Lazy! sync" +qall >> "${LOG}" 2>&1; then
        log "avante: plugin install complete."
    else
        log "avante: lazy sync timed out or partially failed — run ':Lazy sync' in Neovim to complete."
    fi

    mkdir -p "${HOME}/.local/bin"
    cat > "${HOME}/.local/bin/avante" << 'AVANTE_CMD'
#!/bin/bash
[ "${1:-}" = "--version" ] && { nvim --version 2>/dev/null | head -1; exit 0; }
exec nvim -c 'lua vim.defer_fn(function() require("avante.api").zen_mode() end, 100)'
AVANTE_CMD
    chmod +x "${HOME}/.local/bin/avante"
}

# ── Install loop ──────────────────────────────────────────────────────────────
# Write a lockfile listing each binary being installed so `haven harness` can
# show "installing..." instead of "not installed" during the background install.
# The lockfile is removed automatically when this script exits (trap below).
IN_PROGRESS="${HAVEN_DIR}/install-in-progress"
: > "${IN_PROGRESS}"

for _pre_tool in "${TOOLS[@]}"; do
    _pt="${_pre_tool// /}"
    [ -z "${_pt}" ] && continue
    case "${_pt}" in
        claudecode|claude-code|claude)   echo "claude"   >> "${IN_PROGRESS}" ;;
        opencode)                         echo "opencode" >> "${IN_PROGRESS}" ;;
        aider)                            echo "aider"    >> "${IN_PROGRESS}" ;;
        qwencode|qwen-code|qwen)          echo "qwen"     >> "${IN_PROGRESS}" ;;
        amp)                              echo "amp"      >> "${IN_PROGRESS}" ;;
        gemini)                           echo "gemini"   >> "${IN_PROGRESS}" ;;
        pi|pi-coding-agent)               echo "pi"       >> "${IN_PROGRESS}" ;;
        goose)                            echo "goose"    >> "${IN_PROGRESS}" ;;
        continue|continue-code|continuecode|continue-extension) echo "cn" >> "${IN_PROGRESS}" ;;
        avante|avante-nvim)                                      echo "avante" >> "${IN_PROGRESS}" ;;
    esac
done

trap 'rm -f "${IN_PROGRESS}"' EXIT

for raw_tool in "${TOOLS[@]}"; do
    tool="${raw_tool// /}"   # trim whitespace
    [ -z "${tool}" ] && continue

    case "${tool}" in

        claudecode|claude-code|claude)
            if command -v claude &>/dev/null; then
                log "claudecode: already installed ($(claude --version 2>/dev/null || echo 'ok'))."
                mark_installed "claudecode"
            else
                log "claudecode: installing via autoscript..."
                if curl -fsSL https://claude.ai/install.sh 2>>"${LOG}" | bash >>"${LOG}" 2>&1 \
                        && command -v claude &>/dev/null; then
                    log "claudecode: OK — $(command -v claude)."
                    mark_installed "claudecode"
                else
                    log "claudecode: autoscript failed or binary not found, falling back to npm..."
                    install_npm "claudecode" "@anthropic-ai/claude-code" "claude"
                fi
            fi
            ;;

        opencode)
            if command -v opencode &>/dev/null; then
                log "opencode: already installed ($(opencode --version 2>/dev/null || echo 'ok'))."
                mark_installed "opencode"
            else
                log "opencode: installing via autoscript..."
                if curl -fsSL https://opencode.ai/install 2>>"${LOG}" | bash >>"${LOG}" 2>&1 \
                        && command -v opencode &>/dev/null; then
                    mark_installed "opencode"
                    log "opencode: OK — $(command -v opencode)."
                else
                    log "opencode: autoscript failed or binary not found, falling back to npm..."
                    install_npm "opencode" "opencode" "opencode"
                fi
            fi
            # opencode installs its binary to ~/.opencode/bin which is not in the
            # system-wide PATH baked into the image — persist it via ~/.inferhaven.
            add_to_path "${HOME}/.opencode/bin"
            # Symlink into ~/.local/bin (always in PATH) so opencode is immediately
            # available in the current session without a login/re-source.
            if [ -f "${HOME}/.opencode/bin/opencode" ]; then
                ln -sf "${HOME}/.opencode/bin/opencode" "${HOME}/.local/bin/opencode"
                log "opencode: symlinked to ~/.local/bin/opencode for immediate PATH availability."
            fi
            # Auto-configure local Ollama models so they are usable on first launch.
            ( _haven_sync opencode ) || true
            ;;

        aider)
            install_uv_tool "aider" "aider-chat" "aider"
            ( _haven_sync aider ) || true
            ;;

        amp)
            install_npm "amp" "@sourcegraph/amp" "amp"
            ;;

        gemini)
            install_npm "gemini" "@google/gemini-cli" "gemini"
            ;;

        qwencode|qwen-code|qwen)
            if command -v qwen &>/dev/null; then
                log "qwencode: already installed ($(qwen --version 2>/dev/null || echo 'ok'))."
                mark_installed "qwencode"
            else
                log "qwencode: installing via autoscript..."
                if curl -fsSL https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen.sh \
                        2>>"${LOG}" | bash -s -- --source qwenchat >>"${LOG}" 2>&1 \
                        && command -v qwen &>/dev/null; then
                    log "qwencode: OK — $(command -v qwen-code)."
                    mark_installed "qwencode"
                else
                    log "qwencode: autoscript failed or binary not found, falling back to npm..."
                    install_npm "qwencode" "@qwen-code/qwen-code@latest" "qwen"
                fi
            fi
            # Auto-configure local Ollama models so they are usable on first launch.
            ( _haven_sync qwencode ) || true
            ;;

        pi|pi-coding-agent)
            install_npm "pi" "@mariozechner/pi-coding-agent" "pi"
            # Auto-configure local Ollama models so they are usable on first launch.
            ( _haven_sync pi ) || true
            ;;

        goose)
            # Force-claim ownership of the goose config on first install: if a
            # stale config exists without our sentinel (e.g. left over from a
            # pre-haven goose install or an older haven version), remove it so
            # _haven_sync can write a fresh sentinel-tagged file.
            _goose_cfg="${HOME}/.config/goose/config.yaml"
            if [ -f "${_goose_cfg}" ] \
               && ! head -1 "${_goose_cfg}" 2>/dev/null | grep -qF "_haven: managed"; then
                log "goose: removing pre-existing config without sentinel (${_goose_cfg})."
                rm -f "${_goose_cfg}"
            fi
            if command -v goose &>/dev/null; then
                log "goose: already installed ($(goose --version 2>/dev/null || echo 'ok'))."
                mark_installed "goose"
                ( _haven_sync goose ) || true
            else
                log "goose: downloading binary..."
                # Pinned to v1.27.2 — last stable release before the v1.30.0 TUI overhaul
                # that broke Ollama streaming (30 s stall after tool calls with local models).
                # Override with GOOSE_VERSION in .env (e.g. GOOSE_VERSION=v1.29.0) to test newer releases.
                _goose_ver="${GOOSE_VERSION:-v1.27.2}"
                _goose_arch=""
                case "$(uname -m)" in
                    x86_64)  _goose_arch="x86_64-unknown-linux-gnu" ;;
                    aarch64) _goose_arch="aarch64-unknown-linux-gnu" ;;
                    *) log "goose: unsupported arch $(uname -m) — skipping." ;;
                esac
                if [ -n "${_goose_arch}" ]; then
                    _tmp=$(mktemp /tmp/goose-XXXXXX.tar.bz2)
                    if curl -fsSL \
                            "https://github.com/aaif-goose/goose/releases/download/${_goose_ver}/goose-${_goose_arch}.tar.bz2" \
                            -o "${_tmp}" >>"${LOG}" 2>&1 \
                            && tar -xj -C "${HOME}/.local/bin" -f "${_tmp}" >>"${LOG}" 2>&1; then
                        rm -f "${_tmp}"
                        if command -v goose &>/dev/null; then
                            log "goose: OK — $(command -v goose)."
                            mark_installed "goose"
                            ( _haven_sync goose ) || true
                        else
                            log "goose: binary not found in ${HOME}/.local/bin after extraction — check ${LOG}."
                        fi
                    else
                        rm -f "${_tmp}"
                        log "goose: FAILED — check ${LOG} for details."
                    fi
                fi
            fi
            add_to_path "${HOME}/.local/bin"
            ;;

        continue|continue-code|continuecode|continue-extension)
            # InferHaven installs the `cn` CLI in the workspace and maintains
            # ~/.continue/config.yaml for it. The code-server browser editor is
            # NOT touched — users who want the Continue extension install it
            # themselves via code-server's Extensions panel. See docs/ide/continue.md.
            install_npm "continue" "@continuedev/cli" "cn"
            ( _haven_sync continue ) || true
            touch "${HOME}/.haven/install-extension-continue"
            ;;

        avante|avante-nvim)
            ( configure_avante_postinstall && _haven_sync avante ) || true
            if command -v avante &>/dev/null; then
                mark_installed "avante"
            fi
            ;;

        *)
            log "Unknown tool '${tool}' — skipping."
            log "  Valid options: claudecode, opencode, aider, qwencode, amp, gemini, pi, goose, continue, avante"
            ;;
    esac
done

INSTALLED="$(tr '\n' ' ' < "${MANIFEST}" 2>/dev/null || echo '(none)')"
log "Done. Installed: ${INSTALLED}"
