#!/usr/bin/env bash
# InferHaven log rotation — runs daily via supercronic (as haven user).
# Caps log files at sane sizes, keeps a few rotated copies, evicts old alerts/downloads.
# Resolves user homes via getent so sudo-invocations don't write to /root.
set -uo pipefail

# Resolve home dirs from passwd (NOT $HOME — breaks under sudo).
_home_of() {
    local user="$1"
    getent passwd "${user}" 2>/dev/null | cut -d: -f6
}

_rotate() {
    local file="$1" max_bytes="$2" keep="${3:-3}"
    [ -f "${file}" ] || return 0
    local size
    size=$(stat -c %s "${file}" 2>/dev/null || echo 0)
    [ "${size}" -gt "${max_bytes}" ] || return 0

    local i prev
    for (( i = keep; i > 0; i-- )); do
        prev=$(( i - 1 ))
        if [ "${prev}" -eq 0 ]; then
            mv -f "${file}"          "${file}.1"     2>/dev/null || true
        else
            mv -f "${file}.${prev}"  "${file}.${i}"  2>/dev/null || true
        fi
    done
    : > "${file}"
}

_rotate_user() {
    local user="$1"
    local home; home=$(_home_of "${user}")
    [ -n "${home}" ] && [ -d "${home}/.haven" ] || return 0

    local log_dir="${home}/.haven"
    _rotate "${log_dir}/install.log"     5242880 3   # 5 MB, keep 3
    _rotate "${log_dir}/configure.log"   1048576 2   # 1 MB, keep 2
    _rotate "${log_dir}/tmux-boot.log"   5242880 3   # 5 MB, keep 3

    find "${log_dir}/alerts"    -name '*.alert'  -mtime +30 -delete 2>/dev/null || true
    find "${log_dir}/downloads" -name '*.status' -mtime +7 \
        -exec sh -c 'grep -qE "^status=(completed|failed)" "$1" 2>/dev/null && rm -f "$1"' _ {} \; \
        2>/dev/null || true

    local retain="${TMUX_RESURRECT_RETAIN_DAYS:-7}"
    find "${home}/.tmux/resurrect" -name 'tmux_resurrect_*.txt' \
        -mtime +"${retain}" -delete 2>/dev/null || true

    echo "[$(date '+%F %T')] haven-logrotate(${user}): complete" >> "${log_dir}/install.log"
}

# Always rotate haven; iterate HAVEN_EXTRA_USERS too.
USERS="${HAVEN_USER:-haven}"
if [ -n "${HAVEN_EXTRA_USERS:-}" ]; then
    USERS="${USERS} $(printf '%s' "${HAVEN_EXTRA_USERS}" | tr ',' ' ')"
fi
for _u in ${USERS}; do
    _u="${_u// /}"
    [ -n "${_u}" ] && _rotate_user "${_u}"
done
