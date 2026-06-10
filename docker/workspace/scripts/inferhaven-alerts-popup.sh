#!/bin/bash
# shellcheck disable=SC2012,SC2016
# SC2012: alert filenames are controlled timestamps; ls is sufficient.
# SC2016: fzf --preview body keeps $vars literal so they expand inside the
#   preview subshell, not here.
###############################################################################
# InferHaven alerts popup
#
# Called by inferhaven-right-popup when undismissed alert files exist in
# ~/.haven/alerts/. Shows alerts sorted newest-first in an fzf multi-select
# list. Selected alerts are permanently deleted on Enter. Falls back to a
# plain numbered list if fzf is not available.
#
# Alert file format:
#   type=oom_kill|ollama_crash
#   message=<human-readable description>
#   timestamp=<unix seconds>
###############################################################################

ALERT_DIR="${HOME}/.haven/alerts"
BULK_THRESHOLD=30   # show fast bulk-dismiss screen instead of fzf when count >= this
MAX_ALERTS=100      # hard cap enforced on load (matches watcher cap)

# ── Capture true total before enforcing the cap ───────────────────────────────
# The watcher increments ~/.haven/alerts/.count on every write (survives prune
# cycles). Pre-prune file count covers accumulation while the watcher was down.
_pre_prune_count=$(ls "${ALERT_DIR}"/*.alert 2>/dev/null | wc -l)
# shellcheck disable=SC2002  # `cat 2>/dev/null` is the simplest way to suppress shell error on missing file
_cnt_raw=$(cat "${ALERT_DIR}/.count" 2>/dev/null | tr -dc '0-9')
_counter_total="${_cnt_raw:-0}"

# ── Enforce cap on load: prune oldest files if accumulated beyond MAX_ALERTS ──
# This covers files written directly (outside the watcher) and any historical
# accumulation from before the cap was introduced.
_excess=$(ls -t "${ALERT_DIR}"/*.alert 2>/dev/null | tail -n "+$(( MAX_ALERTS + 1 ))")
[ -n "$_excess" ] && printf '%s\n' "$_excess" | xargs rm -f 2>/dev/null

# ── Collect alert files (newest first) ───────────────────────────────────────
mapfile -t alert_files < <(ls -t "${ALERT_DIR}"/*.alert 2>/dev/null)

# ── Compute display total (max of counter, pre-prune count, and stored count) ─
_stored="${#alert_files[@]}"
_display_total="${_counter_total}"
[ "${_pre_prune_count}" -gt "${_display_total}" ] && _display_total="${_pre_prune_count}"
[ "${_stored}"          -gt "${_display_total}" ] && _display_total="${_stored}"

if [ "${#alert_files[@]}" -eq 0 ]; then
    echo ""
    echo "  No alerts."
    sleep 1
    exit 0
fi

# ── Build display list ────────────────────────────────────────────────────────
# Format: "<filename_basename>  [HH:MM:SS]  TYPE — message"
# The filename is the first field so we can map selected lines back to files.
declare -a display_lines
declare -A file_for_id

for f in "${alert_files[@]}"; do
    base=$(basename "${f}" .alert)
    ts=$(grep -m1 '^timestamp=' "${f}" 2>/dev/null | cut -d= -f2-)
    type=$(grep -m1 '^type=' "${f}" 2>/dev/null | cut -d= -f2-)
    message=$(grep -m1 '^message=' "${f}" 2>/dev/null | cut -d= -f2-)

    # Format timestamp as HH:MM:SS if it's a valid unix epoch.
    time_str=""
    if [ -n "${ts}" ] && [ "${ts}" -gt 0 ] 2>/dev/null; then
        time_str=$(date -d "@${ts}" '+%H:%M:%S' 2>/dev/null \
                   || date -r "${ts}" '+%H:%M:%S' 2>/dev/null \
                   || echo "${ts}")
    fi

    # Type label with padding.
    case "${type}" in
        oom_kill)          type_label="OOM KILL  " ;;
        ollama_crash)      type_label="CRASH     " ;;
        container_restart) type_label="RESTART   " ;;
        container_crash)   type_label="CRASH     " ;;
        container_down)    type_label="DOWN      " ;;
        runner_crash)      type_label="RUNNER    " ;;
        load_failure)      type_label="LOAD FAIL " ;;
        oom)               type_label="OOM       " ;;
        cuda_error)        type_label="CUDA ERR  " ;;
        panic)             type_label="PANIC     " ;;
        log_error)         type_label="ERROR     " ;;
        *)                 type_label="${type:0:10}$(printf '%*s' $(( 10 - ${#type} )) '')" ;;
    esac

    line="${base}  [${time_str}]  ${type_label}  ${message}"
    display_lines+=("${line}")
    file_for_id["${base}"]="${f}"
done

# ── Dismiss helper ────────────────────────────────────────────────────────────
dismiss_files() {
    local ids=("$@")
    local removed=0
    for id in "${ids[@]}"; do
        local path="${file_for_id[${id}]:-}"
        [ -z "${path}" ] && path="${ALERT_DIR}/${id}.alert"
        if rm -f "${path}" 2>/dev/null; then
            removed=$(( removed + 1 ))
        fi
    done
    echo "${removed}"
}

# ── Bulk-dismiss fast path ────────────────────────────────────────────────────
# When the count is very high, skip loading all files into fzf (which requires
# 3×N file reads) and show a compact summary with instant dismiss-all instead.
# The type summary is built with a single grep pass over all files (1×N reads).
if command -v fzf > /dev/null 2>&1 \
   && [ "${#alert_files[@]}" -ge "${BULK_THRESHOLD}" ]; then

    # Build type breakdown cheaply — one grep pass, no per-file loops.
    type_summary=$(grep -h '^type=' "${ALERT_DIR}"/*.alert 2>/dev/null \
        | cut -d= -f2- \
        | sort \
        | uniq -c \
        | sort -rn \
        | awk '{
            cnt=$1; t=$2
            sub(/oom_kill/,      "OOM KILL",   t)
            sub(/ollama_crash/,  "CRASH",      t)
            sub(/container_restart/, "RESTART",t)
            sub(/container_crash/,   "CRASH",  t)
            sub(/container_down/,    "DOWN",   t)
            sub(/runner_crash/,  "RUNNER",     t)
            sub(/load_failure/,  "LOAD FAIL",  t)
            sub(/oom$/,          "OOM",        t)
            sub(/cuda_error/,    "CUDA ERR",   t)
            sub(/panic/,         "PANIC",      t)
            sub(/log_error/,     "ERROR",      t)
            printf "  %5d   %s\n", cnt, t
        }')

    while true; do
        printf "\033[2J\033[H"
        # Truecolor palette (matches the carousel style).
        printf "\033[38;2;220;60;60m\033[1m  ⚠  %d Alerts\033[0m\n" "${_display_total}"
        if [ "${_display_total}" -gt "${_stored}" ]; then
            printf "\033[38;2;80;100;110m  (%d stored — oldest pruned when cap was hit)\033[0m\n" "${_stored}"
        fi
        printf '\n'
        printf "\033[38;2;46;134;193m  TYPE BREAKDOWN\033[0m\n"
        printf "\033[38;2;80;100;110m  ─────────────────────────────────────\033[0m\n"
        printf "\033[38;2;57;170;170m%s\033[0m\n" "${type_summary}"
        printf "\n\033[38;2;80;100;110m  ─────────────────────────────────────\033[0m\n"
        if [ -n "${HAVEN_SESSION:-}" ]; then
            printf "\033[38;2;140;223;224m  a\033[0m\033[38;2;80;100;110m = dismiss all   \033[0m\033[38;2;140;223;224mV\033[0m\033[38;2;80;100;110m = view in fzf   ← →\033[0m\033[38;2;80;100;110m navigate   \033[0m\033[38;2;140;223;224mq\033[0m\033[38;2;80;100;110m close\033[0m\n"
        else
            printf "\033[38;2;140;223;224m  a\033[0m\033[38;2;80;100;110m = dismiss all instantly   \033[0m\033[38;2;140;223;224mV\033[0m\033[38;2;80;100;110m = view in fzf   Esc close\033[0m\n"
        fi

        _ESC=$(printf "\033")
        IFS= read -rt 10 -n1 _bk 2>/dev/null
        if [ "$_bk" = "$_ESC" ]; then
            IFS= read -rt 0.1 -n2 _brest 2>/dev/null
            _bk="${_bk}${_brest}"
        fi

        case "$_bk" in
            a|A|d|D)
                rm -f "${ALERT_DIR}"/*.alert 2>/dev/null
                printf '0\n' > "${ALERT_DIR}/.count"
                printf "\n\033[38;2;57;170;170m  All %d alerts cleared.\033[0m\n" "${_display_total}"
                sleep 1
                exit 0
                ;;
            v|V)
                # Fall through to the fzf path below.
                break
                ;;
            "${_ESC}[C")
                [ -n "${HAVEN_SESSION:-}" ] && tmux next-window -t "${HAVEN_SESSION}" 2>/dev/null
                exit 0
                ;;
            "${_ESC}[D")
                [ -n "${HAVEN_SESSION:-}" ] && tmux previous-window -t "${HAVEN_SESSION}" 2>/dev/null
                exit 0
                ;;
            "${_ESC}"|q|Q)
                [ -n "${HAVEN_SESSION:-}" ] && tmux kill-session -t "${HAVEN_SESSION}" 2>/dev/null
                exit 0
                ;;
        esac
    done
    # User pressed V — fall through to fzf. Build the display list now.
fi

# ── fzf path ──────────────────────────────────────────────────────────────────
if command -v fzf > /dev/null 2>&1; then
    if [ -n "${HAVEN_SESSION:-}" ]; then
        header="${_display_total} Alerts  |  Tab: select  |  Enter: dismiss  |  a: dismiss all  |  Esc: exit  |  ← →: navigate  q: close"
    else
        header="${_display_total} Alerts  |  Tab: select  |  Enter: dismiss selected  |  a: dismiss all  |  Esc: close"
    fi

    # Build fzf argument array. When running as a carousel tab (HAVEN_SESSION set),
    # add n/p/q bindings for single-key navigation between carousel windows.
    declare -a fzf_args=(
        --multi
        --prompt="  › "
        --header="${header}"
        --height=100%
        --min-height=8
        --border=none
        --no-sort
        --color="fg+:#39AAAA,bg+:#1a3040,header:#39AAAA:bold,prompt:#8cdfe0,pointer:#39AAAA,marker:#39AAAA"
        --bind="a:select-all+accept"
        --preview='f="$HOME/.haven/alerts/{1}.alert"; [ -f "$f" ] && grep "^message=" "$f" | cut -d= -f2- || echo "(alert not found)"'
        --preview-window='bottom:3:wrap'
    )

    if [ -n "${HAVEN_SESSION:-}" ]; then
        fzf_args+=(
            --bind "right:execute-silent(tmux next-window -t ${HAVEN_SESSION})+abort"
            --bind "left:execute-silent(tmux previous-window -t ${HAVEN_SESSION})+abort"
            --bind "q:execute-silent(tmux kill-session -t ${HAVEN_SESSION})+abort"
        )
    fi

    selected_lines=$(printf '%s\n' "${display_lines[@]}" | \
        fzf "${fzf_args[@]}" || true)

    if [ -z "${selected_lines}" ]; then
        exit 0
    fi

    # Extract the basename (first field) from each selected line.
    declare -a ids_to_remove
    while IFS= read -r line; do
        id=$(printf '%s' "${line}" | awk '{print $1}')
        [ -n "${id}" ] && ids_to_remove+=("${id}")
    done <<< "${selected_lines}"

    removed=$(dismiss_files "${ids_to_remove[@]}")

    # Update counter
    _new_cnt=$(( _display_total - removed ))
    [ "${_new_cnt}" -lt 0 ] && _new_cnt=0
    printf '%d\n' "${_new_cnt}" > "${ALERT_DIR}/.count"

    # If all alerts are now gone, show a brief confirmation.
    remaining=$(ls "${ALERT_DIR}"/*.alert 2>/dev/null | wc -l)
    if [ "${remaining}" -eq 0 ]; then
        echo ""
        echo "  All alerts cleared."
        sleep 1
    fi

# ── Fallback: plain list ──────────────────────────────────────────────────────
else
    echo ""
    echo "  ⚠  InferHaven Alerts (${_display_total} total)"
    echo "  $(printf '─%.0s' {1..60})"
    echo ""

    i=1
    for line in "${display_lines[@]}"; do
        # Strip the hidden basename prefix from display.
        visible=$(printf '%s' "${line}" | cut -d' ' -f3-)
        printf '  %2d)  %s\n' "${i}" "${visible}"
        i=$(( i + 1 ))
    done

    echo ""
    echo "  $(printf '─%.0s' {1..60})"
    printf '  Enter alert numbers to dismiss (e.g. 1 3), or "all", or Enter to close: '
    read -r choice

    if [ -z "${choice}" ]; then
        exit 0
    fi

    declare -a ids_to_remove
    _dismiss_all=0
    if [ "${choice}" = "all" ]; then
        _dismiss_all=1
        for f in "${alert_files[@]}"; do
            ids_to_remove+=("$(basename "${f}" .alert)")
        done
    else
        for n in ${choice}; do
            idx=$(( n - 1 ))
            if [ "${idx}" -ge 0 ] && [ "${idx}" -lt "${#alert_files[@]}" ]; then
                ids_to_remove+=("$(basename "${alert_files[${idx}]}" .alert)")
            fi
        done
    fi

    removed=$(dismiss_files "${ids_to_remove[@]}")

    # Update counter
    if [ "${_dismiss_all}" -eq 1 ]; then
        printf '0\n' > "${ALERT_DIR}/.count"
    else
        _new_cnt=$(( _display_total - removed ))
        [ "${_new_cnt}" -lt 0 ] && _new_cnt=0
        printf '%d\n' "${_new_cnt}" > "${ALERT_DIR}/.count"
    fi

    echo ""
    echo "  ${removed} alert(s) dismissed."

    remaining=$(ls "${ALERT_DIR}"/*.alert 2>/dev/null | wc -l)
    if [ "${remaining}" -gt 0 ]; then
        echo "  ${remaining} alert(s) remaining."
    else
        echo "  All alerts cleared."
    fi
    sleep 2
fi
