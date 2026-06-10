#!/bin/bash
# shellcheck disable=SC2012,SC2015
# SC2012: alert filenames are controlled timestamps; ls + wc/sort is fine.
# SC2015: `A && B || true` is the deliberate non-fatal idiom in this file.
###############################################################################
# InferHaven Alert Watcher — background daemon
#
# Two monitoring paths run concurrently:
#
# 1. Log watcher (main loop): tails the Ollama container logs and fires alerts
#    on application-level errors:
#      - Model load failures (insufficient VRAM/RAM, model not found, etc.)
#      - Inference runner crashes (llama runner process terminated)
#      - CUDA / GPU OOM errors
#      - Out-of-memory events within Ollama
#      - Go panics inside Ollama
#      - Any level=ERROR log line
#    Also detects when the Ollama container restarts by comparing StartedAt
#    timestamps before and after each docker logs session.
#
# 2. Docker events monitor (background subprocess): watches docker events for
#    crash/die events on any inferhaven-* container (except ollama, which is
#    covered by the log watcher above). Fires a container_crash alert for any
#    non-zero-exit container stop event.
#
# Alert file format (~/.haven/alerts/<nanosec>.alert):
#   type=load_failure|oom|cuda_error|panic|log_error|container_restart|
#        container_down|container_crash|runner_crash
#   message=<human-readable description>
#   timestamp=<unix seconds>
#
# Rate limiting: same category fires at most once per 60 seconds (main loop).
# Docker events monitor uses file-based rate limiting.
# Auto-expiry: alerts older than 24 hours are pruned on each write.
#
# Started from entrypoint.sh as a background process for the haven user.
# Reconnects automatically when the ollama container restarts.
###############################################################################

export DOCKER_HOST=unix:///var/run/docker.sock

# Shared compose-label resolver — uses our self container's project label so
# the watcher tracks the right ollama regardless of project name (codespaces
# vs dev override vs prod). Falls back to the historical literal if the lib
# is missing or our self container has no compose labels.
# shellcheck source=/dev/null
. /usr/local/lib/haven/haven-resolve.sh 2>/dev/null || true

ALERT_DIR="${HOME}/.haven/alerts"
_resolved_ollama=$(_haven_resolve_container ollama 2>/dev/null)
CONTAINER="${_resolved_ollama:-inferhaven-ollama}"
PROJECT="$(_haven_resolve_project 2>/dev/null)"
RATE_LIMIT=60     # seconds between alerts of the same category
EXPIRY=86400      # 24 hours in seconds
MAX_ALERTS=100    # hard cap: oldest files pruned when this is exceeded

mkdir -p "${ALERT_DIR}"

# ── Helpers ───────────────────────────────────────────────────────────────────

write_alert() {
    local type="$1" message="$2"
    local ts file
    ts=$(date +%s)
    file="${ALERT_DIR}/$(date +%s%N 2>/dev/null || printf '%s%04d' "${ts}" "${RANDOM}").alert"
    printf 'type=%s\nmessage=%s\ntimestamp=%s\n' "${type}" "${message}" "${ts}" > "${file}"
    # Increment persistent counter so the popup can show the true total
    # across prune cycles (flock prevents concurrent-write corruption).
    local _cnt_file="${ALERT_DIR}/.count"
    (
        flock -x 9
        _cur=$(cat "${_cnt_file}" 2>/dev/null || echo 0)
        printf '%d\n' $(( _cur + 1 )) > "${_cnt_file}"
    ) 9>"${_cnt_file}.lock"
    # Prune oldest files if total exceeds cap (prevents unbounded growth on crash loops).
    local _count
    _count=$(ls "${ALERT_DIR}"/*.alert 2>/dev/null | wc -l)
    if [ "${_count}" -gt "${MAX_ALERTS}" ]; then
        ls -t "${ALERT_DIR}"/*.alert 2>/dev/null \
            | tail -n "+$(( MAX_ALERTS + 1 ))" \
            | xargs rm -f 2>/dev/null
    fi
}

prune_expired() {
    local now
    now=$(date +%s)
    local f ts
    for f in "${ALERT_DIR}"/*.alert; do
        [ -f "$f" ] || continue
        ts=$(grep -m1 '^timestamp=' "$f" 2>/dev/null | cut -d= -f2-)
        [ -n "$ts" ] && [ $(( now - ts )) -gt "${EXPIRY}" ] && rm -f "$f"
    done
}

# Extract a human-readable message from a structured Ollama log line.
# Ollama structured format: time=... level=... source=... msg="..." error="..."
extract_message() {
    local line="$1"
    local msg err

    msg=$(printf '%s' "${line}" | sed -n 's/.*msg="\([^"]*\)".*/\1/p')
    err=$(printf '%s' "${line}" | sed -n 's/.*error="\([^"]*\)".*/\1/p')

    if [ -n "$msg" ] && [ -n "$err" ]; then
        printf '%s: %s' "${msg}" "${err}"
    elif [ -n "$msg" ]; then
        printf '%s' "${msg}"
    elif [ -n "$err" ]; then
        printf '%s' "${err}"
    else
        # Fall back to raw line, truncated to 120 chars
        printf '%s' "${line:0:120}"
    fi
}

# ── Rate limiting ─────────────────────────────────────────────────────────────
# Associative array tracks last alert timestamp per category (bash 4+).
declare -A last_alert_time

should_alert() {
    local category="$1"
    local now last
    now=$(date +%s)
    last="${last_alert_time[$category]:-0}"
    if [ $(( now - last )) -ge "${RATE_LIMIT}" ]; then
        last_alert_time[$category]=$now
        return 0
    fi
    return 1
}

# ── Log line processor ────────────────────────────────────────────────────────
process_line() {
    local line="$1"
    local category="" msg="" prefix=""

    # Case-insensitive pattern matching — more specific patterns first.
    # ${line,,} is bash 4+ lowercase expansion.
    local lower="${line,,}"

    # Ollama logs normal model eviction (making room for a new model) at
    # level=info. Skip info/debug lines entirely — only alert on level=error,
    # level=warn, or unstructured stderr from subprocesses (no level= prefix).
    case "${lower}" in *"level=info"*|*"level=debug"*) return ;; esac

    case "${lower}" in
        # Inference runner crash — explicit pattern before generic log_error
        *"llama runner process has terminated"*|*"runner process has terminated"*)
            category="runner_crash"
            prefix="Inference runner crashed"
            ;;
        # Model load failures
        *"failed to load"*|*"model requires more system memory"*)
            category="load_failure"
            prefix="Model load failed"
            ;;
        # Insufficient memory (catches cases not covered by load_failure)
        *"not enough memory"*|*"insufficient memory"*|*"model requires more"*)
            category="oom"
            prefix="Insufficient memory"
            ;;
        # CUDA / GPU errors
        *"cuda out of memory"*)
            category="cuda_error"
            prefix="CUDA out of memory"
            ;;
        *"cuda error"*)
            category="cuda_error"
            prefix="CUDA error"
            ;;
        # General OOM (kernel-level or process-level)
        *"out of memory"*|*" oom "*|*" oom:"*)
            category="oom"
            prefix="Out of memory"
            ;;
        # Go panics inside Ollama
        *"panic:"*)
            category="panic"
            prefix="Ollama panic"
            ;;
        # Any structured Ollama error log (catch-all, lowest priority)
        *"level=error"*)
            category="log_error"
            prefix="Ollama error"
            ;;
        *)
            return
            ;;
    esac

    should_alert "${category}" || return

    msg=$(extract_message "${line}")
    [ -n "$msg" ] \
        && write_alert "${category}" "${prefix} at $(date '+%H:%M:%S'): ${msg}" \
        || write_alert "${category}" "${prefix} at $(date '+%H:%M:%S') — check 'docker logs ${CONTAINER}'."

    prune_expired
}

# ── Docker events monitor (background) ───────────────────────────────────────
# Watches for die events on ALL inferhaven-* containers. Ollama container
# restarts are handled separately by the StartedAt comparison below;
# this subprocess covers workspace, code-server, caddy, and any other services.
(
    while true; do
        docker info > /dev/null 2>&1 || sudo -n docker info > /dev/null 2>&1 \
            || { sleep 30; continue; }

        # Use the compose project label as the filter when we have one; falls
        # back to a name-prefix match for the historical layout.
        if [ -n "$PROJECT" ]; then
            _events_filter=(--filter "label=com.docker.compose.project=${PROJECT}")
        else
            _events_filter=()
        fi

        docker events \
            --filter "type=container" \
            --filter "event=die" \
            "${_events_filter[@]}" \
            2>/dev/null | \
        while IFS= read -r _ev; do
            _name=$(printf '%s' "$_ev" | grep -oE 'name=[A-Za-z0-9_.-]+' | head -1 | cut -d= -f2-)
            [ -z "$_name" ] && continue
            # If we don't have a project label, fall back to the prefix check.
            if [ -z "$PROJECT" ]; then
                case "$_name" in
                  inferhaven-*) ;;
                  *) continue ;;
                esac
            fi
            # Ollama is handled by the StartedAt detection in the main loop
            [ "$_name" = "${CONTAINER}" ] && continue
            _exit=$(printf '%s' "$_ev" | grep -oE 'exitCode=[0-9]+' | cut -d= -f2)
            # Exit code 0 = intentional stop (docker compose down, etc.) — skip
            [ "${_exit:-1}" = "0" ] && continue

            # File-based rate limit: skip if a container_crash alert was written
            # in the last 60 seconds (avoids cross-process shared state)
            _now=$(date +%s)
            _recent=0
            for _af in "${ALERT_DIR}"/*.alert; do
                [ -f "$_af" ] || continue
                grep -q "^type=container_crash" "$_af" 2>/dev/null || continue
                _ts=$(grep '^timestamp=' "$_af" 2>/dev/null | cut -d= -f2-)
                [ -n "$_ts" ] && [ $(( _now - _ts )) -lt 60 ] && { _recent=1; break; }
            done
            [ "$_recent" -eq 0 ] && \
                write_alert "container_crash" \
                    "Container ${_name} crashed (exit ${_exit:-?}) at $(date '+%H:%M:%S')"
        done

        # docker events stream exited — brief pause before reconnecting
        sleep 5
    done
) &

# ── Main loop ─────────────────────────────────────────────────────────────────
# Uses process substitution so the while loop runs in the current shell,
# keeping last_alert_time state across iterations.

while true; do
    # Wait for docker to be reachable
    if ! sudo -n docker info > /dev/null 2>&1; then
        sleep 30
        continue
    fi

    # Wait for the container to exist
    if ! sudo -n docker inspect "${CONTAINER}" > /dev/null 2>&1; then
        sleep 30
        continue
    fi

    # Record container StartedAt before tailing — used to detect restarts
    _start_before=$(sudo -n docker inspect --format '{{.State.StartedAt}}' "${CONTAINER}" 2>/dev/null)

    # --tail 0 = start from end of log (no historical replay on reconnect)
    # Process substitution keeps the while loop in the current shell
    while IFS= read -r line; do
        process_line "${line}"
    done < <(sudo -n docker logs --tail 0 --follow "${CONTAINER}" 2>&1)

    # docker logs exited — the container stopped, restarted, or docker became
    # unavailable. Compare StartedAt to detect unexpected restarts.
    _start_after=$(sudo -n docker inspect --format '{{.State.StartedAt}}' "${CONTAINER}" 2>/dev/null)

    if [ -n "$_start_before" ] && [ -n "$_start_after" ] \
       && [ "$_start_before" != "$_start_after" ]; then
        # Container restarted (StartedAt changed)
        should_alert "container_restart" && \
            write_alert "container_restart" \
                "Container ${CONTAINER} restarted unexpectedly at $(date '+%H:%M:%S')"
    elif [ -n "$_start_before" ] && [ -z "$_start_after" ]; then
        # Container is gone (no longer inspectable)
        should_alert "container_down" && \
            write_alert "container_down" \
                "Container ${CONTAINER} stopped and is not running at $(date '+%H:%M:%S')"
    fi

    # Brief pause before reconnecting to avoid a tight spin loop.
    sleep 5
done
