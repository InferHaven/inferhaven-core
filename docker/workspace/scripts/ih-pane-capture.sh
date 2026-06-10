#!/bin/bash
# shellcheck disable=SC2012  # pane state dir holds controlled filenames; ls is fine
# Capture pane visible content and foreground process commands.
# Runs as the haven user. Called from entrypoint.sh save loop and shutdown trap.
# Output is stored in ~/.tmux/resurrect/ih_state/ and used by ih-pane-restore.sh.
#
# Files are keyed by SESSION_WINDOW_xLEFT_yTOP (visual position) rather than
# pane ID so that ih-pane-restore matches correctly after resurrect, which may
# assign new pane IDs in a different order than the original session.

_IHLOG="${HOME}/.haven/tmux-boot.log"
_log() { echo "[$(date '+%H:%M:%S')] [capture] $*" >> "${_IHLOG}" 2>/dev/null || true; }

# tmux list-sessions is more reliable than `tmux info` in non-interactive contexts.
# Retry up to 3 times in case of transient socket unavailability.
_tries=0
while [ "${_tries}" -lt 3 ]; do
    tmux list-sessions >/dev/null 2>&1 && break
    sleep 1
    _tries=$((_tries + 1))
done
if ! tmux list-sessions >/dev/null 2>&1; then
    _log "tmux not running — skipping"
    exit 0
fi

_new="${HOME}/.tmux/resurrect/ih_state_new"
_dir="${HOME}/.tmux/resurrect/ih_state"
rm -rf "${_new}" 2>/dev/null || true
mkdir -p "${_new}" || { _log "ERROR: cannot mkdir ${_new}"; exit 1; }

tmux list-panes -a \
    -F '#{session_name}|#{window_index}|#{pane_index}|#{pane_left}|#{pane_top}|#{pane_pid}|#{pane_current_command}' \
    2>/dev/null | \
while IFS='|' read -r sess win pane left top ppid cmd; do
    # Skip ephemeral popup sessions (haven-popup-*) — these are created by
    # InferHaven's status bar popups and should never be saved or restored.
    case "${sess}" in haven-popup-*) continue ;; esac

    # Position-based key: immune to pane ID reordering after resurrect restore
    key="${sess}_w${win}_x${left}_y${top}"
    _log "saving pane ${key} (id=${pane} cmd=${cmd} pid=${ppid})"

    # Capture visible pane content (strip trailing blank lines via awk)
    tmux capture-pane -t "${sess}:${win}.${pane}" -p 2>/dev/null | \
        awk '/[^[:space:]]/{last=NR} {lines[NR]=$0} END{for(i=1;i<=last;i++) print lines[i]}' \
        > "${_new}/${key}.txt" 2>/dev/null || true

    # Capture foreground process full argv from /proc (skip shells)
    case "${cmd}" in
        zsh|bash|sh|dash|fish) ;;
        *)
            fg=$(pgrep -P "${ppid}" 2>/dev/null | head -1)
            if [ -n "${fg}" ] && [ -f "/proc/${fg}/cmdline" ]; then
                tr '\0' ' ' < "/proc/${fg}/cmdline" 2>/dev/null \
                    | sed 's/ $//' \
                    > "${_new}/${key}.cmd" || true
                _log "  → cmd: $(cat "${_new}/${key}.cmd" 2>/dev/null || echo '(empty)')"
            else
                _log "  → no foreground process (pgrep -P ${ppid})"
            fi
            ;;
    esac
done

# Atomic swap — but refuse to overwrite a good prior state with nothing.
# tmux mid-shutdown returns 0 panes from list-panes; without this guard the
# atomic swap wipes the last successful save and the next boot has nothing
# to restore.
_new_count=$(ls "${_new}" 2>/dev/null | wc -l)
if [ "${_new_count}" -eq 0 ] && [ -d "${_dir}" ] && [ "$(ls "${_dir}" 2>/dev/null | wc -l)" -gt 0 ]; then
    _log "capture produced 0 files -- preserving previous state ($(ls "${_dir}" 2>/dev/null | wc -l) files)"
    rm -rf "${_new}" 2>/dev/null || true
    exit 0
fi
rm -rf "${_dir}" 2>/dev/null || true
mv "${_new}" "${_dir}" 2>/dev/null || true
_log "capture complete -- files in ${_dir}: $(ls "${_dir}" 2>/dev/null | wc -l)"

# Mirror opencode's TUI model selection back into its config file so a future
# restart honors the user's last `/models` pick instead of reverting to the
# cloud-priority default written by configure-assistants.sh. Opencode persists
# the active model under ~/.opencode/state/ but does not write the canonical
# `model` field in ~/.config/opencode/config.json, so the config-level default
# wins on each relaunch unless we mirror it here.
_sync_opencode_default() {
    _state_file="${HOME}/.opencode/state/model.json"
    _cfg_file="${HOME}/.config/opencode/config.json"
    [ -f "${_state_file}" ] || return 0
    [ -f "${_cfg_file}" ] || return 0
    command -v jq >/dev/null 2>&1 || { _log "opencode sync: jq missing"; return 0; }

    # Try common schema shapes — first non-empty string wins. Opencode's
    # state file structure may evolve; this defensive list covers known and
    # likely-future keys without hard-coding a single shape.
    _picked=$(jq -r '
        [ .current, .default, .model, .selected, .last,
          (.agents.build // empty), (.agents.plan // empty) ]
        | map(select(type == "string" and . != ""))
        | first // empty
    ' "${_state_file}" 2>/dev/null)
    if [ -z "${_picked}" ] || [ "${_picked}" = "null" ]; then
        _log "opencode sync: state present but no recognizable model field"
        return 0
    fi

    _current=$(jq -r '.model // empty' "${_cfg_file}" 2>/dev/null)
    if [ "${_current}" = "${_picked}" ]; then
        _log "opencode sync: config.model already matches state (${_picked})"
        return 0
    fi

    _tmp_cfg="${_cfg_file}.ih_tmp.$$"
    if jq --arg m "${_picked}" '.model = $m' "${_cfg_file}" > "${_tmp_cfg}" 2>/dev/null \
       && [ -s "${_tmp_cfg}" ]; then
        mv "${_tmp_cfg}" "${_cfg_file}" \
            && _log "opencode sync: model ${_current:-<unset>} → ${_picked}"
    else
        rm -f "${_tmp_cfg}" 2>/dev/null || true
        _log "opencode sync: jq patch failed"
    fi
}
_sync_opencode_default
