# shellcheck shell=bash
# InferHaven shared log helpers — sourced by other scripts.
# Provides log() and log_private() with consistent timestamp + tag.
# Caller must set HAVEN_LOG (path to log file). Falls back to /dev/null.

_haven_ts() { date '+%H:%M:%S'; }

# Public log: stdout + log file
log() {
    local tag="${HAVEN_LOG_TAG:-haven}"
    local line
    line="[$(_haven_ts)] [${tag}] $*"
    if [ -n "${HAVEN_LOG:-}" ] && [ -w "$(dirname "${HAVEN_LOG}" 2>/dev/null || echo /tmp)" ]; then
        echo "${line}" | tee -a "${HAVEN_LOG}"
    else
        echo "${line}"
    fi
}

# Private log: log file only — never stdout. Use for secrets.
log_private() {
    local tag="${HAVEN_LOG_TAG:-haven}"
    [ -n "${HAVEN_LOG:-}" ] || return 0
    echo "[$(_haven_ts)] [${tag}] $*" >> "${HAVEN_LOG}" 2>/dev/null || true
}
