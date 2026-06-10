# InferHaven Workspace — Bash Configuration
# Loaded for interactive bash sessions (web IDE terminal, fallback shells).
# Primary login shell is zsh — this covers any bash usage.

# Only run for interactive shells
[[ $- != *i* ]] && return

# ── Terminal environment ──────────────────────────────────────────────────────
export TERM="${TERM:-xterm-256color}"
export COLORTERM="${COLORTERM:-truecolor}"

# ── Color prompt ──────────────────────────────────────────────────────────────
# cyan "InferHaven" prefix, blue working directory
PS1='\[\033[01;36m\]InferHaven\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# ── Terminal title ────────────────────────────────────────────────────────────
# Sets tab/window title to "InferHaven | ~/current/path" on every prompt.
_ih_set_title() {
  local dir="${PWD/#$HOME/\~}"
  printf '\033]0;InferHaven | %s\007' "$dir"
}
PROMPT_COMMAND="_ih_set_title${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

# ── Color aliases ─────────────────────────────────────────────────────────────
alias ls='ls --color=auto'
alias ll='ls -alF --color=auto'
alias la='ls -A --color=auto'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias diff='diff --color=auto'
alias v='nvim'
alias g='git'
alias dc='docker compose'

# ── Environment ───────────────────────────────────────────────────────────────
# Source API keys, OLLAMA_HOST, and tool settings from configure-assistants.sh
[ -f ~/.inferhaven ] && source ~/.inferhaven

export OLLAMA_HOST="${OLLAMA_HOST:-http://ollama:11434}"
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:/usr/local/go/bin:$PATH"
export EDITOR="nvim"
export PREFIX="$HOME/.local"
export GOOGLE_API_KEY="$GEMINI_API_KEY"

# ── Completion ────────────────────────────────────────────────────────────────
if [ -f /etc/bash_completion ]; then
  source /etc/bash_completion
fi

# ── Modern shell utilities (P1/P2 tools) ────────────────────────────────────
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init bash)"
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook bash)"
command -v mise   >/dev/null 2>&1 && eval "$(mise activate bash)"
command -v atuin  >/dev/null 2>&1 && eval "$(atuin init bash --disable-up-arrow)"
if command -v eza >/dev/null 2>&1; then
  alias ls='eza --group-directories-first --icons=auto'
  alias ll='eza -alF --group-directories-first --icons=auto'
  alias la='eza -A --group-directories-first --icons=auto'
fi

# ── Starship prompt ───────────────────────────────────────────────────────────
# Replaces the PS1 above when INSTALL_STARSHIP=1 (default). Set INSTALL_STARSHIP=0
# in .env to keep the plain InferHaven PS1 instead.
if [ "${INSTALL_STARSHIP:-1}" != "0" ] && command -v starship > /dev/null 2>&1; then
  eval "$(starship init bash)"
fi
