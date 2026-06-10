#!/bin/bash
###############################################################################
# InferHaven tmux status-left — loaded model indicator
#
# Called by .tmux.conf every status-interval seconds (default: 5s).
# Outputs the ⚡ model indicator appended to the InferHaven status-left string.
# Outputs nothing when no model is loaded (the │ separator is suppressed too).
#
# Truncation is dynamic: the available column budget is computed from the
# current session name length so the model name is always cut from the END
# (keeping the important beginning) and always gets a … marker when truncated.
#
# status-left visible overhead breakdown (status-left-length = 65):
#   " InferHaven │ "  = 14 cols  (fixed)
#   session_name      = variable
#   " │ "             = 3 cols   (fixed)
#   "│ ⚡ "           = 4 cols   (│=1, space=1, ⚡=1, space=1)
#   ──────────────────────────────
#   fixed total       = 21 + len(session_name)
#   available for model name = 65 − 21 − len(session_name)
###############################################################################

OLLAMA_HOST="${OLLAMA_HOST:-http://ollama:11434}"
STATUS_LEFT_LENGTH=65

# Query the current session name from tmux to compute available space.
# Falls back to a 10-char estimate when called outside a tmux context.
_sname=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "----------")
_slen=${#_sname}

# Available columns for the model name (reserve 1 extra for the … character).
_max_len=$(( STATUS_LEFT_LENGTH - 21 - _slen - 1 ))
[ "$_max_len" -lt 6 ] && _max_len=6

ps_resp=$(curl -sf --max-time 1 "${OLLAMA_HOST}/api/ps" 2>/dev/null)
loaded_count=$(echo "$ps_resp" | jq -r '.models | length' 2>/dev/null)

if [ -n "$loaded_count" ] && [ "$loaded_count" -gt 0 ] 2>/dev/null; then
  if [ "$loaded_count" -eq 1 ]; then
    model_name=$(echo "$ps_resp" | jq -r '.models[0].name' 2>/dev/null)
    if [ "${#model_name}" -gt "$_max_len" ]; then
      short_name="${model_name:0:${_max_len}}…"
    else
      short_name="$model_name"
    fi
    printf '#[fg=colour238]│#[fg=colour83,bold] ⚡ %s#[default]' "$short_name"
  else
    printf '#[fg=colour238]│#[fg=colour83,bold] ⚡ %d loaded#[default]' "$loaded_count"
  fi
fi
