#!/bin/bash
###############################################################################
# InferHaven tmux status bar — right-side script
#
# Called by .tmux.conf every status-interval seconds (default: 5s).
# Outputs a coloured string showing alerts, active downloads, RAM/CPU/GPU,
# and the current time.
#
# Performance: HOT loop. All metrics come from the local metrics-server
# (localhost:9091) which caches results. Zero `docker exec`, no per-request
# sleep. GPU NAME is intentionally NOT in the status bar — the right-popup's
# System Resources tab shows the model name. Status bar is util/VRAM only.
###############################################################################

# shellcheck source=/dev/null
. /usr/local/lib/haven/haven-colors.sh 2>/dev/null || true

OLLAMA_HOST="${OLLAMA_HOST:-http://ollama:11434}"
DL_DIR="${HOME}/.haven/downloads"
METRICS_URL="${METRICS_URL:-http://127.0.0.1:9091/metrics.json}"

# ── Alert indicator ──────────────────────────────────────────────────────────
alerts=""
_alert_files=( "${HOME}/.haven/alerts/"*.alert )
[ -e "${_alert_files[0]}" ] || _alert_files=()
_alert_count="${#_alert_files[@]}"
if [ "${_alert_count}" -gt 0 ]; then
  alerts="${HAVEN_T_ERR:-#[fg=colour196,bold]} ⚠ ${_alert_count} ALERT ${HAVEN_T_RESET:-#[default]}${HAVEN_T_SEP:-#[fg=colour238]} │"
fi

# ── Active background downloads ──────────────────────────────────────────────
downloads=""
if [ -d "${DL_DIR}" ]; then
  dl_count=0; dl_total_pct=0; dl_entries=""
  for f in "${DL_DIR}"/*.status; do
    [ -f "$f" ] || continue
    status=$(grep '^status=' "$f" 2>/dev/null | cut -d= -f2-)
    [ "$status" = "downloading" ] || [ "$status" = "starting" ] || continue
    model=$(grep '^model=' "$f" 2>/dev/null | cut -d= -f2-)
    pct=$(grep '^pct=' "$f" 2>/dev/null | cut -d= -f2-)
    pct="${pct:-0}"
    dl_count=$(( dl_count + 1 ))
    dl_total_pct=$(( dl_total_pct + pct ))
    short_model="${model:0:15}"
    [ "${#model}" -gt 15 ] && short_model="${short_model}…"
    dl_entries="${dl_entries}${HAVEN_T_WARN:-#[fg=colour220]}⬇ ${short_model}:${pct}%${HAVEN_T_SEP:-#[fg=colour238]} │ "
  done
  if [ "${dl_count}" -ge 4 ]; then
    avg_pct=$(( dl_total_pct / dl_count ))
    downloads="${HAVEN_T_WARN:-#[fg=colour220]}⬇ ${dl_count} models: ${avg_pct}%${HAVEN_T_SEP:-#[fg=colour238]} │ "
  elif [ "${dl_count}" -gt 0 ]; then
    downloads="${dl_entries}"
  fi
fi

# ── Sys metrics from local server (RAM / CPU / GPU) ──────────────────────────
# Hot loop — runs every 5 s. Strategy:
#   1. Try the local metrics-server with a generous-but-bounded timeout (0.8s).
#      The server precomputes its payload in the background, so any successful
#      hit is sub-millisecond; the 0.8s budget exists only for the rare case
#      where the server is restarting.
#   2. On success, persist parsed values to /run/haven/last-metrics.tsv (tmpfs).
#   3. On failure, fall back to those cached values so the status bar never
#      flickers blank under transient load.
LAST_CACHE="/run/haven/last-metrics.tsv"
metrics=$(curl -sf --max-time 0.8 "${METRICS_URL}" 2>/dev/null || echo "")

ram=""; cpu=""; gpu=""
mem_used=""; mem_total=""; cpu_pct=""; gpu_util=""; gpu_used=""; gpu_total=""
if [ -n "${metrics}" ] && command -v jq >/dev/null 2>&1; then
  IFS=$'\t' read -r mem_used mem_total cpu_pct gpu_util gpu_used gpu_total < <(
    printf '%s' "${metrics}" | jq -r '[
        (.mem_used_mb // 0),
        (.mem_total_mb // 0),
        (.cpu_pct // 0),
        (.gpu_util_pct // ""),
        (.gpu_vram_used_mb // ""),
        (.gpu_vram_total_mb // "")
    ] | @tsv' 2>/dev/null
  )
  # Persist last-good values to tmpfs (race-free atomic write).
  # Subshell isolates bash's redirect-failure stderr from the parent process.
  mkdir -p /run/haven 2>/dev/null
  ( printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${mem_used}" "${mem_total}" "${cpu_pct}" "${gpu_util}" "${gpu_used}" "${gpu_total}" \
      > "${LAST_CACHE}.tmp" ) 2>/dev/null \
    && mv -f "${LAST_CACHE}.tmp" "${LAST_CACHE}" 2>/dev/null
elif [ -f "${LAST_CACHE}" ]; then
  # Metrics-server slow/down → reuse last known values so the bar stays visible.
  IFS=$'\t' read -r mem_used mem_total cpu_pct gpu_util gpu_used gpu_total < "${LAST_CACHE}"
fi

if [ -n "${mem_total:-}" ] && [ "${mem_total:-0}" -gt 0 ] 2>/dev/null; then

  # RAM: "U.UG/TG"
  if [ -n "${mem_total}" ] && [ "${mem_total}" -gt 0 ] 2>/dev/null; then
    ram_g=$(awk -v u="${mem_used:-0}"  'BEGIN{printf "%.1f", u/1024}')
    tot_g=$(awk -v t="${mem_total:-1}" 'BEGIN{printf "%.0f", t/1024}')
    ram="${HAVEN_T_TEXT:-#[fg=colour250]} ${ram_g}/${tot_g}G"
  fi

  # CPU: integer percent
  if [ -n "${cpu_pct}" ]; then
    cpu_int=$(awk -v p="${cpu_pct:-0}" 'BEGIN{printf "%d", p}')
    cpu=" ${HAVEN_T_DIM:-#[fg=colour245]}${cpu_int}%"
  fi

  # GPU: util% + used/total in GiB. NO model name in status bar.
  if [ -n "${gpu_util}" ] && [ "${gpu_util}" != "null" ]; then
    gpu_util_int=$(awk -v u="${gpu_util:-0}" 'BEGIN{printf "%d", u}')
    if [ -n "${gpu_used}" ] && [ -n "${gpu_total}" ] && [ "${gpu_total:-0}" -gt 0 ] 2>/dev/null; then
      used_g=$(awk -v u="${gpu_used:-0}"  'BEGIN{printf "%.1f", u/1024}')
      tot_g=$( awk -v t="${gpu_total:-1}" 'BEGIN{printf "%.0f", t/1024}')
      gpu=" ${HAVEN_T_NV:-#[fg=#76b900]}GPU ${gpu_util_int}% ${used_g}/${tot_g}G"
    else
      gpu=" ${HAVEN_T_NV:-#[fg=#76b900]}GPU ${gpu_util_int}%"
    fi
  fi
fi

# ── Time ─────────────────────────────────────────────────────────────────────
time_str="${HAVEN_T_WARN:-#[fg=colour220]} $(date +'%H:%M')${HAVEN_T_DIM:-#[fg=colour245]} $(date +'%a %b %d')"

# ── Assemble ─────────────────────────────────────────────────────────────────
out=""
[ -n "${alerts}" ]    && out="${out}${alerts} "
[ -n "${downloads}" ] && out="${out}${downloads}"

_sys=""
[ -n "${ram}" ] && _sys="${_sys}${ram}"
[ -n "${cpu}" ] && _sys="${_sys}${cpu}"
[ -n "${gpu}" ] && _sys="${_sys}${gpu}"
[ -n "${_sys}" ] && out="${out}${_sys} ${HAVEN_T_SEP:-#[fg=colour238]}│"

out="${out} ${time_str} "

printf '%s' "${out}"
