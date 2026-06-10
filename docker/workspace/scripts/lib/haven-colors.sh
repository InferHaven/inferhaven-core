# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are sourced by other scripts
# InferHaven shared color palette.
# ANSI sequences for terminal output + tmux #[fg=...] tags for status bar.
# Source from any script that writes formatted output.

# ── ANSI (terminal) ────────────────────────────────────────────────────────
HAVEN_C_RED=$'\033[0;31m'
HAVEN_C_GREEN=$'\033[0;32m'
HAVEN_C_YELLOW=$'\033[1;33m'
HAVEN_C_BLUE=$'\033[0;34m'
HAVEN_C_CYAN=$'\033[0;36m'
HAVEN_C_MAGENTA=$'\033[0;35m'
HAVEN_C_BOLD=$'\033[1m'
HAVEN_C_DIM=$'\033[2m'
HAVEN_C_RESET=$'\033[0m'

# ── tmux status-bar palette ────────────────────────────────────────────────
HAVEN_T_ACCENT="#[fg=colour45,bold]"
HAVEN_T_TEXT="#[fg=colour250]"
HAVEN_T_DIM="#[fg=colour245]"
HAVEN_T_SEP="#[fg=colour238]"
HAVEN_T_OK="#[fg=colour83,bold]"
HAVEN_T_WARN="#[fg=colour220]"
HAVEN_T_ERR="#[fg=colour196,bold]"
HAVEN_T_NV="#[fg=#76b900]"
HAVEN_T_AMD="#[fg=#de0021]"
HAVEN_T_RESET="#[default]"

# Legacy aliases (drop-in replacements for existing scripts).
RED="${HAVEN_C_RED}"
GREEN="${HAVEN_C_GREEN}"
YELLOW="${HAVEN_C_YELLOW}"
BLUE="${HAVEN_C_BLUE}"
CYAN="${HAVEN_C_CYAN}"
MAGENTA="${HAVEN_C_MAGENTA}"
BOLD="${HAVEN_C_BOLD}"
DIM="${HAVEN_C_DIM}"
NC="${HAVEN_C_RESET}"
