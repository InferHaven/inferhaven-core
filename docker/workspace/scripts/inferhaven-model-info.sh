#!/bin/bash
###############################################################################
# InferHaven model info popup
#
# Displays runtime details for all models currently loaded in Ollama.
# Invoked by the MouseDown1StatusLeft binding in .tmux.conf via display-popup.
###############################################################################

OLLAMA_HOST="${OLLAMA_HOST:-http://ollama:11434}"

# ── ANSI colours (plain sequences — display-popup is a real terminal) ─────────
BOLD=$(printf '\033[1m')
RESET=$(printf '\033[0m')
CYAN=$(printf '\033[38;5;45m')
GREEN=$(printf '\033[38;5;83m')
GRAY=$(printf '\033[38;5;245m')
DIM=$(printf '\033[38;5;238m')

# ── Helper: human-readable bytes ──────────────────────────────────────────────
human_bytes() {
  awk "BEGIN{
    b=$1
    if (b >= 1073741824) printf \"%.1f GB\", b/1073741824
    else if (b >= 1048576) printf \"%.0f MB\", b/1048576
    else printf \"%d B\", b
  }"
}

# ── Helper: relative time from ISO-8601 timestamp ─────────────────────────────
rel_time() {
  local ts="$1"
  [ -z "$ts" ] || [ "$ts" = "null" ] && echo "unknown" && return
  local epoch
  epoch=$(date -d "$ts" +%s 2>/dev/null) || { echo "unknown"; return; }
  local now diff
  now=$(date +%s)
  diff=$(( epoch - now ))
  local abs=$(( diff < 0 ? -diff : diff ))
  local sign=""
  [ "$diff" -lt 0 ] && sign="ago" || sign="from now"
  if [ "$abs" -ge 3600 ]; then
    printf '%dh %dm %s' $(( abs/3600 )) $(( (abs%3600)/60 )) "$sign"
  elif [ "$abs" -ge 60 ]; then
    printf '%dm %ds %s' $(( abs/60 )) $(( abs%60 )) "$sign"
  else
    printf '%ds %s' "$abs" "$sign"
  fi
}

# ── Fetch loaded models ────────────────────────────────────────────────────────
ps_resp=$(curl -sf --max-time 2 "${OLLAMA_HOST}/api/ps" 2>/dev/null)
loaded_count=$(echo "$ps_resp" | jq -r '.models | length' 2>/dev/null)

printf '\n'

if [ -z "$loaded_count" ] || [ "$loaded_count" -eq 0 ] 2>/dev/null; then
  printf '  %sNo models are currently loaded.%s\n' "$GRAY" "$RESET"
  printf '\n'
  printf '  %sLoad a model with  %shaven chat <model>%s  or an AI assistant.%s\n' \
    "$DIM" "$GRAY" "$DIM" "$RESET"
  printf '\n'
  printf '  %sPress any key to close%s\n' "$DIM" "$RESET"
  read -r -n1 -s
  exit 0
fi

printf '  %s%sLoaded Models%s\n' "$BOLD" "$CYAN" "$RESET"
printf '  %s%s%s\n' "$DIM" "────────────────────────────────────────────────────" "$RESET"

# ── Iterate models ─────────────────────────────────────────────────────────────
echo "$ps_resp" | jq -r '.models[] | @base64' | while IFS= read -r encoded; do
  m=$(echo "$encoded" | base64 --decode 2>/dev/null)

  name=$(echo "$m"       | jq -r '.name // "unknown"')
  size=$(echo "$m"       | jq -r '.size // 0')
  size_vram=$(echo "$m"  | jq -r '.size_vram // 0')
  expires=$(echo "$m"    | jq -r '.expires_at // ""')
  param_sz=$(echo "$m"   | jq -r '.details.parameter_size // "?"')
  quant=$(echo "$m"      | jq -r '.details.quantization_level // "?"')
  family=$(echo "$m"     | jq -r '.details.family // "?"')

  # ── Fetch additional detail from /api/show ───────────────────────────────────
  show_resp=$(curl -sf --max-time 2 -X POST "${OLLAMA_HOST}/api/show" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${name}\"}" 2>/dev/null)

  # num_ctx: prefer the parameters text field, fall back to model_info
  num_ctx=$(echo "$show_resp" | jq -r '.parameters // ""' 2>/dev/null \
    | awk '/^num_ctx /{print $2; exit}')
  if [ -z "$num_ctx" ]; then
    num_ctx=$(echo "$show_resp" \
      | jq -r '(.model_info // {}) | to_entries[] | select(.key | endswith("context_length")) | .value' \
      2>/dev/null | head -1)
  fi
  [ -z "$num_ctx" ] && num_ctx="?"

  # ── Format sizes ─────────────────────────────────────────────────────────────
  size_fmt=$(human_bytes "$size")
  vram_fmt=$(human_bytes "$size_vram")

  # ── Processor split (mirrors what `ollama ps` shows) ─────────────────────────
  # size = total footprint (RAM + VRAM); size_vram = GPU portion only.
  processor="unknown"
  if [ "${size:-0}" -gt 0 ] 2>/dev/null; then
    gpu_pct=$(( size_vram * 100 / size ))
    cpu_pct=$(( 100 - gpu_pct ))
    if [ "$gpu_pct" -ge 100 ]; then
      processor="100% GPU"
    elif [ "$gpu_pct" -le 0 ]; then
      processor="100% CPU"
    else
      processor="${gpu_pct}% GPU  +  ${cpu_pct}% CPU"
    fi
  fi

  # Loaded-since: derive from expires_at by subtracting typical 5-min keep-alive
  # (Ollama default keepalive is 5m; expires_at = load_time + keepalive)
  expires_fmt=$(rel_time "$expires")

  printf '\n'
  printf '  %s%s⚡ %s%s\n' "$BOLD" "$GREEN" "$name" "$RESET"
  printf '  %s  Architecture:%s  %-14s  %sParameters:%s  %s\n' \
    "$GRAY" "$RESET" "$family" "$GRAY" "$RESET" "$param_sz"
  printf '  %s  Quantization:%s  %-14s  %sContext:%s      %s tokens\n' \
    "$GRAY" "$RESET" "$quant" "$GRAY" "$RESET" "$num_ctx"
  printf '  %s  Size:%s         %-14s  %sVRAM:%s         %s\n' \
    "$GRAY" "$RESET" "$size_fmt" "$GRAY" "$RESET" "$vram_fmt"
  printf '  %s  Processor:%s    %s\n' \
    "$GRAY" "$RESET" "$processor"
  if [ -n "$expires" ] && [ "$expires" != "null" ]; then
    printf '  %s  Expires:%s      %s\n' "$GRAY" "$RESET" "$expires_fmt"
  fi
done

printf '\n'
printf '  %s%s%s\n' "$DIM" "────────────────────────────────────────────────────" "$RESET"
printf '\n'
printf '  %sPress any key to close%s\n' "$DIM" "$RESET"
read -r -n1 -s
