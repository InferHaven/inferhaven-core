#!/bin/bash
# shellcheck disable=SC2012,SC2015
# SC2012: pane state dir holds controlled filenames; ls is fine.
# SC2015: `[ -n "${_cmd}" ] && ... || true` is the deliberate non-fatal idiom.
# Restore pane content and restart foreground processes after tmux-resurrect.
# Runs as the haven user, called 5s after bootstrap so zsh has finished loading.
# Content is shown via `cat` (old output appears, then live process starts below).
#
# Panes are matched by visual position (pane_left, pane_top) rather than pane ID.
# resurrect may assign new IDs in a different order than the original session,
# causing content to land in the wrong pane; positions are always restored correctly.

_IHLOG="${HOME}/.haven/tmux-boot.log"
_log() { echo "[$(date '+%H:%M:%S')] [restore] $*" >> "${_IHLOG}" 2>/dev/null || true; }

_dir="${HOME}/.tmux/resurrect/ih_state"
if [ ! -d "${_dir}" ]; then
    _log "ih_state directory not found at ${_dir} — nothing to restore"
    exit 0
fi

_files=$(ls "${_dir}" 2>/dev/null | wc -l)
_log "ih_state found at ${_dir} with ${_files} files: $(ls "${_dir}" 2>/dev/null | tr '\n' ' ')"

# Wait for the tmux socket to be connectable — the socket can be briefly
# inaccessible right after the bootstrap su block exits even though the
# server is alive. Retry for up to 20 seconds before giving up.
_tries=0
while [ "${_tries}" -lt 20 ]; do
    tmux list-sessions >/dev/null 2>&1 && break
    sleep 1
    _tries=$((_tries + 1))
done
if ! tmux list-sessions >/dev/null 2>&1; then
    _log "tmux not ready after 20s — skipping"
    exit 0
fi
_log "tmux ready after ${_tries}s — waiting 3s for shells to initialize"
sleep 3

_panes=$(tmux list-panes -a \
    -F '#{session_name}|#{window_index}|#{pane_index}|#{pane_left}|#{pane_top}' \
    2>/dev/null)
_log "current panes: $(echo "${_panes}" | tr '\n' ' ')"

echo "${_panes}" | \
while IFS='|' read -r sess win pane left top; do
    # Match by position — same key format as ih-pane-capture
    key="${sess}_w${win}_x${left}_y${top}"
    target="${sess}:${win}.${pane}"

    if [ -s "${_dir}/${key}.cmd" ]; then
        # Harness pane: relaunch via respawn-pane so keystrokes never leak
        # into an interactive TUI (opencode, aider, etc). send-keys writes
        # to the pane's TTY input buffer; respawn-pane replaces the pane's
        # process atomically, so no input can be misinterpreted regardless
        # of timing races. Scrollback inject is skipped for harness panes —
        # the TUI redraws immediately and would overwrite it anyway.
        _cmd=$(tr -d '\n' < "${_dir}/${key}.cmd")
        _log "respawning ${key} (pane ${pane}): ${_cmd}"
        if [ -n "${_cmd}" ]; then
            # Intentional word-split on ${_cmd}: tmux needs argv tokens.
            # shellcheck disable=SC2086
            tmux respawn-pane -k -t "${target}" -- ${_cmd} 2>/dev/null \
                || _log "  → respawn-pane failed for ${target}"
        fi
    elif [ -s "${_dir}/${key}.txt" ]; then
        # Shell pane: inject saved scrollback as context above the live prompt.
        _log "restoring content for ${key} (pane ${pane})"
        _tmp="/tmp/ih_${key}_$$.txt"
        cp "${_dir}/${key}.txt" "${_tmp}" 2>/dev/null || { _log "  → cp failed"; continue; }
        # Leading space = excluded from zsh history (HIST_IGNORE_SPACE)
        tmux send-keys -t "${target}" \
            " cat '${_tmp}' && rm -f '${_tmp}'" Enter 2>/dev/null || true
        sleep 0.5
    else
        _log "no state for ${key}"
    fi
done
_log "restore loop complete"
