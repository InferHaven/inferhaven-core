# InferHaven Workspace — Zsh Configuration

# ── InferHaven environment (load first — INSTALL_STARSHIP and API keys needed) ──
# Source API keys, OLLAMA_HOST, INSTALL_STARSHIP, and tool paths set by
# configure-assistants.sh. Loaded before ZSH_THEME so INSTALL_STARSHIP is
# available when deciding whether to use Starship or Oh My Zsh.
[ -f ~/.inferhaven ] && source ~/.inferhaven
export OLLAMA_HOST="${OLLAMA_HOST:-http://ollama:11434}"
export GOOGLE_API_KEY="$GEMINI_API_KEY"

# ── Prompt: Starship or Oh My Zsh robbyrussell ───────────────────────────────
# Starship is installed by default (INSTALL_STARSHIP=1 in .env).
# Set INSTALL_STARSHIP=0 in .env to keep the Oh My Zsh robbyrussell theme.
export ZSH="$HOME/.oh-my-zsh"
if [ "${INSTALL_STARSHIP:-1}" != "0" ] && command -v starship > /dev/null 2>&1; then
  ZSH_THEME=""   # Disable OMZ theme — Starship handles the prompt
else
  ZSH_THEME="robbyrussell"
fi
plugins=(git zsh-autosuggestions zsh-syntax-highlighting docker)
source $ZSH/oh-my-zsh.sh

# ── fzf shell integration (key-bindings + completion) ────────────────────────
# fzf 0.48+ generates this natively; no Debian-specific file paths needed.
source <(fzf --zsh)

# ── Terminal environment ─────────────────────────────────────────────────────
# Ensure 256-color and true-color support. SSH passes TERM from the client
# (sshd AcceptEnv includes TERM), so this only kicks in as a safe fallback.
export TERM="${TERM:-xterm-256color}"
export COLORTERM="${COLORTERM:-truecolor}"

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.cargo/bin:$HOME/go/bin:/usr/local/go/bin:$PATH"
export EDITOR="nvim"
export PREFIX="$HOME/.local"   # make install target — stays in home volume

# ── Terminal title ───────────────────────────────────────────────────────────
# Sets the tab/window title to "InferHaven | ~/current/path" so terminal apps
# show a meaningful name instead of a blank tab.
# add-zsh-hook stacks cleanly with Oh My Zsh's own hooks.
_ih_set_title() {
  local dir="${PWD/#$HOME/\~}"
  print -Pn "\033]0;InferHaven | ${dir}\007"
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd  _ih_set_title
add-zsh-hook chpwd   _ih_set_title

# ── Aliases ──────────────────────────────────────────────────────────────────
alias ll="ls -alF"
alias la="ls -A"
alias v="nvim"
alias g="git"
alias dc="docker compose"
alias k="kubectl"

# InferHaven AI shortcuts
alias ai-models="curl -s \${OLLAMA_HOST}/api/tags | jq -r '.models[].name'"
alias ai-status="curl -sf \${OLLAMA_HOST}/api/tags > /dev/null && echo '✓ Ollama running' || echo '✗ Ollama not reachable'"

# ── FZF ──────────────────────────────────────────────────────────────────────
export FZF_DEFAULT_COMMAND="fd --type f --hidden --follow --exclude .git"
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND="fd --type d --hidden --follow --exclude .git"

# ── Modern shell utilities (P1/P2 tools) ────────────────────────────────────
# zoxide — smart cd (`z proj` jumps to most-used dir)
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"
# direnv — per-project .envrc loader
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook zsh)"
# mise — per-project tool versions (replaces nvm/pyenv/rbenv)
command -v mise >/dev/null 2>&1 && eval "$(mise activate zsh)"
# atuin — searchable shell history (local-only by default)
command -v atuin >/dev/null 2>&1 && eval "$(atuin init zsh --disable-up-arrow)"
# eza — modern ls with icons
if command -v eza >/dev/null 2>&1; then
  alias ls='eza --group-directories-first --icons=auto'
  alias ll='eza -alF --group-directories-first --icons=auto'
  alias la='eza -A --group-directories-first --icons=auto'
fi

# ── Welcome ──────────────────────────────────────────────────────────────────
if [ -z "$TMUX" ] && [ "$TERM_PROGRAM" != "vscode" ]; then
  echo ""
  echo "  ╔══════════════════════════════════════════╗"
  echo "  ║         Welcome to InferHaven            ║"
  echo "  ║      A safe haven for AI inference       ║"
  echo "  ╚══════════════════════════════════════════╝"
  echo ""
  ai-status
  echo ""
  echo "  Quick start:"
  echo "    haven tmux            — Attach to Haven (or pick from multiple sessions)"
  echo "    haven models          — List available models"
  echo "    haven chat            — Chat with your AI model"
  echo "    haven help            — All commands"
  echo ""
  echo "  Your Haven tmux session is always running and fully restored after"
  echo "  every restart (windows, panes, and working directories preserved)."
  echo "  Sessions auto-save every 15 minutes. Type 'haven tmux help' for more."
  echo ""
fi

# ── Starship prompt init ──────────────────────────────────────────────────────
# Initialised at the very end so all PATH additions above are in effect.
# When INSTALL_STARSHIP=0, this block is skipped and Oh My Zsh handles the prompt.
if [ "${INSTALL_STARSHIP:-1}" != "0" ] && command -v starship > /dev/null 2>&1; then
  eval "$(starship init zsh)"
fi
