#!/usr/bin/env bash
###############################################################################
# InferHaven Workspace — Coding Assistant Configurator
#
# Called from entrypoint.sh (runs as root). Reads API keys and settings from
# the container environment and writes them to the appropriate config files
# for each coding assistant, then exports them into ~/.inferhaven so they are
# available in every shell session.
#
# Security properties:
#   • Config files written chmod 600, owned by HAVEN_USER
#   • Keys are never printed to stdout (written to ~/.haven/configure.log only)
#   • Empty / unset vars are silently skipped — no placeholder writes
#   • Idempotent: safe to run on every container start
#   • ~/.inferhaven is chmod 600 (user-readable only)
#
# Required env vars (set by entrypoint):
#   HOME_DIR   — absolute path to haven user's home (/home/haven)
#   HAVEN_USER — username (haven)
#
# Optional env vars (from .env / docker-compose):
#   ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, OPENROUTER_API_KEY
#   GITHUB_TOKEN, CLAUDE_CODE_DISABLE_TELEMETRY, OPENCODE_DEFAULT_MODEL
###############################################################################
set -euo pipefail

HOME_DIR="${HOME_DIR:-/home/haven}"
HAVEN_USER="${HAVEN_USER:-haven}"
HAVEN_DIR="${HOME_DIR}/.haven"
INFERHAVEN_FILE="${HOME_DIR}/.inferhaven"

mkdir -p "${HAVEN_DIR}"
chown "${HAVEN_USER}:${HAVEN_USER}" "${HAVEN_DIR}"

LOG="${HAVEN_DIR}/configure.log"
: > "${LOG}"
chown "${HAVEN_USER}:${HAVEN_USER}" "${LOG}"

log() {
    local ts; ts=$(date '+%H:%M:%S')
    echo "[${ts}] [configure] $*" | tee -a "${LOG}"
}
# Sensitive output — log file only, never stdout
log_private() {
    local ts; ts=$(date '+%H:%M:%S')
    echo "[${ts}] [configure] $*" >> "${LOG}"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# Write a file with correct ownership and restricted permissions.
write_secure_file() {
    local path="$1"
    local content="$2"
    local mode="${3:-600}"
    mkdir -p "$(dirname "${path}")"
    printf '%s' "${content}" > "${path}"
    chmod "${mode}" "${path}"
    chown -R "${HAVEN_USER}:${HAVEN_USER}" "$(dirname "${path}")"
}

# Set or update a single `export VAR="value"` line in ~/.inferhaven.
# Uses sed to remove any existing entry before appending — idempotent.
set_inferhaven_var() {
    local var="$1"
    local val="$2"
    touch "${INFERHAVEN_FILE}"
    sed -i "/^export ${var}=/d" "${INFERHAVEN_FILE}"
    printf 'export %s="%s"\n' "${var}" "${val}" >> "${INFERHAVEN_FILE}"
}

# ── Initialise ~/.inferhaven ─────────────────────────────────────────────────
# Create with a header on first run; subsequent runs only update var lines.
if [ ! -f "${INFERHAVEN_FILE}" ]; then
    cat > "${INFERHAVEN_FILE}" << 'HEADER'
# InferHaven environment — auto-generated on container start.
# Sourced by ~/.zprofile (all login shells) and ~/.zshrc (interactive).
# Edit API keys here or set them in your .env file and restart the container.
HEADER
fi

# Always sync OLLAMA_HOST and version (may change between starts)
set_inferhaven_var "OLLAMA_HOST"          "${OLLAMA_HOST:-http://ollama:11434}"
set_inferhaven_var "INFERHAVEN_VERSION"   "0.1.0"
# OLLAMA_OPENAI_KEY satisfies avante's api_key_name check for the Ollama provider.
# avante's __inherited_from="openai" provider requires a non-empty env var as an
# API key placeholder — Ollama ignores the Authorization header it sends.
set_inferhaven_var "OLLAMA_OPENAI_KEY"    "ollama"

# HAVEN_CTX controls the target context window for haven tune / haven pull.
# If unset, haven tune defaults to 32768. Set to 16384 on memory-constrained hardware.
if [ -n "${HAVEN_CTX:-}" ]; then
    set_inferhaven_var "HAVEN_CTX" "${HAVEN_CTX}"
fi

# INSTALL_STARSHIP: 1 (default) = use Starship prompt; 0 = keep Oh My Zsh robbyrussell.
# Written here so .zshrc can read it after sourcing ~/.inferhaven.
set_inferhaven_var "INSTALL_STARSHIP" "${INSTALL_STARSHIP:-1}"

chmod 600 "${INFERHAVEN_FILE}"
chown "${HAVEN_USER}:${HAVEN_USER}" "${INFERHAVEN_FILE}"

# ── Claude Code network access ────────────────────────────────────────────────
# Disable non-essential network access (telemetry, version checks) regardless
# of whether ANTHROPIC_API_KEY is set. This is critical when using Claude Code
# with a local Ollama model via 'haven claude' — without it, Claude Code tries
# to reach Anthropic endpoints that don't apply to local inference and hangs.
if [ "${CLAUDE_CODE_DISABLE_TELEMETRY:-}" = "true" ] || \
   [ "${CLAUDE_CODE_DISABLE_TELEMETRY:-}" = "1" ]; then
    set_inferhaven_var "CLAUDE_CODE_DISABLE_NONESSENTIAL_NETWORK_ACCESS" "1"
    log "Claude Code: non-essential network access disabled."
fi

# ── Anthropic API Key ─────────────────────────────────────────────────────────
# Used by: Claude Code, Claw Code, Aider (claude backend)
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    log_private "Configuring ANTHROPIC_API_KEY..."
    set_inferhaven_var "ANTHROPIC_API_KEY" "${ANTHROPIC_API_KEY}"

    # Claude Code settings.json — create only if absent (preserve user edits)
    CLAUDE_SETTINGS="${HOME_DIR}/.claude/settings.json"
    if [ ! -f "${CLAUDE_SETTINGS}" ]; then
        write_secure_file "${CLAUDE_SETTINGS}" '{
  "permissions": {
    "allow": [],
    "deny": []
  }
}'
        log "Claude Code: settings.json created."
    fi

    log "Anthropic key: configured (Claude Code, Claw Code, Aider)."
fi

# ── OpenAI API Key ────────────────────────────────────────────────────────────
if [ -n "${OPENAI_API_KEY:-}" ]; then
    log_private "Configuring OPENAI_API_KEY..."
    set_inferhaven_var "OPENAI_API_KEY" "${OPENAI_API_KEY}"
    log "OpenAI key: configured."
fi

# ── Gemini API Key ────────────────────────────────────────────────────────────
if [ -n "${GEMINI_API_KEY:-}" ]; then
    log_private "Configuring GEMINI_API_KEY..."
    set_inferhaven_var "GEMINI_API_KEY" "${GEMINI_API_KEY}"
    log "Gemini key: configured (Gemini CLI, OpenCode gemini backend, Aider)."
fi

# ── OpenRouter API Key ────────────────────────────────────────────────────────
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    log_private "Configuring OPENROUTER_API_KEY..."
    set_inferhaven_var "OPENROUTER_API_KEY" "${OPENROUTER_API_KEY}"
    log "OpenRouter key: configured."
fi

# ── GitHub Token ──────────────────────────────────────────────────────────────
if [ "${CODESPACES:-}" = "true" ]; then
    # Codespaces injects a rotating, short-lived GITHUB_TOKEN and manages GitHub
    # auth natively (gh + the Pull Requests extension). Pinning a snapshot into
    # ~/.inferhaven would shadow the live token with a stale value and break the
    # extension's session on every rotation ("session no longer valid"). Leave
    # GitHub auth entirely to Codespaces here.
    log "GitHub token: Codespaces-managed — skipping InferHaven pin."
elif [ -n "${GITHUB_TOKEN:-}" ]; then
    log_private "Configuring GITHUB_TOKEN..."
    set_inferhaven_var "GITHUB_TOKEN" "${GITHUB_TOKEN}"

    # Authenticate gh CLI if it's installed in the container
    if command -v gh &>/dev/null; then
        if echo "${GITHUB_TOKEN}" | \
           su -s /bin/sh "${HAVEN_USER}" -c "gh auth login --with-token" 2>>"${LOG}"; then
            log "GitHub CLI: authenticated."
        else
            log "GitHub CLI: skipped (token may be invalid — check ${LOG})."
        fi
    fi

    log "GitHub token: configured."
fi

# ── OpenCode config ───────────────────────────────────────────────────────────
# Write provider config only when we have at least one key and no config yet.
OPENCODE_CFG="${HOME_DIR}/.config/opencode/opencode.json"
if [ ! -f "${OPENCODE_CFG}" ]; then
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        PROVIDER="anthropic"
        MODEL="${OPENCODE_DEFAULT_MODEL:-claude-sonnet-4-6}"
    elif [ -n "${OPENAI_API_KEY:-}" ]; then
        PROVIDER="openai"
        MODEL="${OPENCODE_DEFAULT_MODEL:-gpt-4o}"
    elif [ -n "${GEMINI_API_KEY:-}" ]; then
        PROVIDER="google"
        MODEL="${OPENCODE_DEFAULT_MODEL:-gemini-2.0-flash}"
    else
        PROVIDER=""
        MODEL=""
    fi

    if [ -n "${PROVIDER}" ]; then
        write_secure_file "${OPENCODE_CFG}" "{
  \"model\": \"${PROVIDER}/${MODEL}\"
}"
        log "OpenCode: configured (${PROVIDER}/${MODEL})."
    fi
fi

# ── Aider config ──────────────────────────────────────────────────────────────
# When a cloud API key is present, create a minimal lock file so that
# install-assistants.sh (which handles Ollama auto-config) skips writing its
# own model: line — the cloud key is picked up automatically by Aider via env.
# When no cloud key is set, install-assistants.sh writes the full Ollama config.
AIDER_CFG="${HOME_DIR}/.aider.conf.yml"

# Migration: if the config exists but has no real key-value pairs (only comments
# or blank lines), it will cause Aider to crash with "yaml.load returned NoneType".
# Detect this and remove the broken file so the fresh-create path below rewrites it.
if [ -f "${AIDER_CFG}" ]; then
    # grep -v strips comment lines and blank lines; if nothing remains, it's broken.
    if ! grep -qvE '^\s*(#|$)' "${AIDER_CFG}" 2>/dev/null; then
        rm -f "${AIDER_CFG}"
        log "Aider: removed comment-only config (was causing yaml NoneType crash) — will recreate."
    fi
fi

if [ ! -f "${AIDER_CFG}" ]; then
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        write_secure_file "${AIDER_CFG}" '## Aider configuration — auto-generated by InferHaven
## Edit this file to customise behaviour; it will not be overwritten on restart.
## Full option reference: https://aider.chat/docs/config/options.html

# ANTHROPIC_API_KEY is exported via ~/.inferhaven — Aider picks it up automatically.
# "haven aider" always uses local Ollama models regardless of this setting.
model: claude-sonnet-4-6
'
        log "Aider: config created (Anthropic backend — key exported via ~/.inferhaven)."
    elif [ -n "${OPENAI_API_KEY:-}" ]; then
        write_secure_file "${AIDER_CFG}" '## Aider configuration — auto-generated by InferHaven
## Edit this file to customise behaviour; it will not be overwritten on restart.
## Full option reference: https://aider.chat/docs/config/options.html

# OPENAI_API_KEY is exported via ~/.inferhaven — Aider picks it up automatically.
# "haven aider" always uses local Ollama models regardless of this setting.
model: gpt-4o
'
        log "Aider: config created (OpenAI backend — key exported via ~/.inferhaven)."
    fi
fi

# ── Pi auth.json ─────────────────────────────────────────────────────────────
# Pi supports cloud API keys via ~/.pi/agent/auth.json. Using Pi's env-var
# resolution syntax ("key": "VAR_NAME") means auth.json references the names
# of the vars already exported via ~/.inferhaven — no literal key values are
# written to disk here, and key rotation only requires updating .env.
#
# Written only when at least one cloud key is present and the file does not
# already exist (user-created configs are never overwritten).
PI_AUTH="${HOME_DIR}/.pi/agent/auth.json"
if [ ! -f "${PI_AUTH}" ]; then
    PI_AUTH_JSON="{}"
    [ -n "${ANTHROPIC_API_KEY:-}" ] && \
        PI_AUTH_JSON=$(jq -n --argjson o "${PI_AUTH_JSON}" \
            '$o + {"anthropic":{"type":"api_key","key":"ANTHROPIC_API_KEY"}}')
    [ -n "${OPENAI_API_KEY:-}" ] && \
        PI_AUTH_JSON=$(jq -n --argjson o "${PI_AUTH_JSON}" \
            '$o + {"openai":{"type":"api_key","key":"OPENAI_API_KEY"}}')
    [ -n "${GEMINI_API_KEY:-}" ] && \
        PI_AUTH_JSON=$(jq -n --argjson o "${PI_AUTH_JSON}" \
            '$o + {"google":{"type":"api_key","key":"GEMINI_API_KEY"}}')
    [ -n "${OPENROUTER_API_KEY:-}" ] && \
        PI_AUTH_JSON=$(jq -n --argjson o "${PI_AUTH_JSON}" \
            '$o + {"openrouter":{"type":"api_key","key":"OPENROUTER_API_KEY"}}')

    if [ "${PI_AUTH_JSON}" != "{}" ]; then
        write_secure_file "${PI_AUTH}" "${PI_AUTH_JSON}"
        log "Pi: auth.json created (keys resolved from env vars at runtime)."
    fi
fi

# ── Avante multi-provider sidecar config ─────────────────────────────────────
# Always write on first start; default provider = ollama (local-first).
# Cloud providers are included when their API key is present.
# _sync_avante_models (haven pull/tune/remove) keeps the file up to date.
#
# Ollama is configured as __inherited_from="openai" pointing at Ollama's
# OpenAI-compatible endpoint (/v1). This uses avante's fully-tested OpenAI
# provider code for native tool calling — no patching of avante internals needed.
AVANTE_SIDECAR="${HOME_DIR}/.config/nvim/lua/inferhaven-avante-config.lua"
# Write if absent, OR if the file has an old format (no sentinel on line 1, or
# old native-ollama format still using use_ReAct_prompt).
# Distinguishes old InferHaven-generated files from user-managed ones by header.
_needs_sidecar_write=0
if [ ! -f "${AVANTE_SIDECAR}" ]; then
    _needs_sidecar_write=1
elif head -1 "${AVANTE_SIDECAR}" 2>/dev/null | grep -qF "-- Avante cloud provider"; then
    _needs_sidecar_write=1
elif head -1 "${AVANTE_SIDECAR}" 2>/dev/null | grep -qF "-- _haven: managed" \
     && grep -qF 'use_ReAct_prompt' "${AVANTE_SIDECAR}" 2>/dev/null; then
    _needs_sidecar_write=1
fi
if [ "${_needs_sidecar_write}" = "1" ]; then
    mkdir -p "$(dirname "${AVANTE_SIDECAR}")"
    {
        printf '%s\n' \
            "-- _haven: managed" \
            "-- InferHaven rewrites this file on model sync (haven pull/tune/remove)." \
            "-- Remove the first line above to manage this file yourself." \
            "return {" \
            "  provider = \"ollama\"," \
            "  providers = {" \
            "    ollama = {" \
            "      __inherited_from   = \"openai\"," \
            "      endpoint           = \"${OLLAMA_HOST:-http://ollama:11434}/v1\"," \
            "      model              = \"\"," \
            "      api_key_name       = \"OLLAMA_OPENAI_KEY\"," \
            "      timeout            = 120000," \
            "      extra_request_body = { options = { num_ctx = ${HAVEN_CTX:-32768} } }," \
            "    },"
        [ -n "${ANTHROPIC_API_KEY:-}" ]  && printf '    %s\n' "claude     = { model = \"claude-sonnet-4-6\" },"
        [ -n "${OPENAI_API_KEY:-}" ]     && printf '    %s\n' "openai     = { model = \"gpt-4o\" },"
        [ -n "${GEMINI_API_KEY:-}" ]     && printf '    %s\n' "gemini     = { model = \"gemini-2.0-flash\" },"
        if [ -n "${OPENROUTER_API_KEY:-}" ]; then
            printf '%s\n' \
                "    openrouter = {" \
                "      __inherited_from = \"openai\"," \
                "      endpoint     = \"https://openrouter.ai/api/v1\"," \
                "      api_key_name = \"OPENROUTER_API_KEY\"," \
                "      model        = \"deepseek/deepseek-r1\"," \
                "    },"
        fi
        printf '%s\n' "  }," "}"
    } > "${AVANTE_SIDECAR}"
    chmod 600 "${AVANTE_SIDECAR}"
    chown "${HAVEN_USER}:${HAVEN_USER}" "${AVANTE_SIDECAR}"
    _plist="ollama"
    [ -n "${ANTHROPIC_API_KEY:-}" ]  && _plist="${_plist}, claude"
    [ -n "${OPENAI_API_KEY:-}" ]     && _plist="${_plist}, openai"
    [ -n "${GEMINI_API_KEY:-}" ]     && _plist="${_plist}, gemini"
    [ -n "${OPENROUTER_API_KEY:-}" ] && _plist="${_plist}, openrouter"
    log "Avante: sidecar written (providers: ${_plist}; model filled on first haven pull)."
fi

# ── Final permissions pass ────────────────────────────────────────────────────
chmod 600 "${INFERHAVEN_FILE}"
chown "${HAVEN_USER}:${HAVEN_USER}" "${INFERHAVEN_FILE}"

# ── Default gitconfig (delta + sane defaults) ───────────────────────────────
# Only if the user has no ~/.gitconfig yet. Written as haven so it's mutable.
GITCONFIG="${HOME_DIR}/.gitconfig"
if [ ! -f "${GITCONFIG}" ]; then
    cat > "${GITCONFIG}" << 'GITCONF'
[core]
	pager = delta
[interactive]
	diffFilter = delta --color-only
[delta]
	navigate = true
	light = false
	line-numbers = true
[merge]
	conflictstyle = diff3
[diff]
	colorMoved = default
[pull]
	rebase = true
[init]
	defaultBranch = main
GITCONF
    chmod 644 "${GITCONFIG}"
    chown "${HAVEN_USER}:${HAVEN_USER}" "${GITCONFIG}"
    log "git: default ~/.gitconfig written (delta pager + rebase pull)."
fi

log "Configuration complete."
