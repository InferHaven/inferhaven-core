#!/bin/bash
# shellcheck disable=SC2016,SC1007
# SC2016: heredoc-like single-quoted SYSTEM_CMD / DL_CMD / ALERTS_CMD bodies
#   keep $vars literal so they expand inside the spawned tmux pane, not here.
# SC1007: `TMUX= tmux ...` intentionally launches nested tmux from inside an
#   outer tmux client (the popup runs under the outer session).
###############################################################################
# InferHaven status-right click dispatcher
#
# Opens a popup with five views:
#   System      — memory bars (active/cache/available), per-core CPU, disk, GPU
#   Downloads   — live haven pullback status
#   Alerts      — fzf list of undismissed alert files; dismiss with Enter
#   Containers  — live docker stats for inferhaven containers (CPU normalized)
#   Sessions    — tmux session list with create/attach/rename/kill/save actions
#
# Navigation: ← → arrow keys to switch tabs, q to close
#
# Starting window priority:
#   Undismissed alerts exist → Alerts
#   Active background downloads → Downloads
#   Default → System
###############################################################################

OLLAMA_HOST="${OLLAMA_HOST:-http://ollama:11434}"
DL_DIR="${HOME}/.haven/downloads"
SESSION="haven-popup-$$"
OUTER_CLIENT=$(tmux display-message -p '#{client_name}' 2>/dev/null)

COLS=$(tput cols  2>/dev/null || echo 200)
LINES=$(tput lines 2>/dev/null || echo 50)

# ── Determine starting view ───────────────────────────────────────────────────
alert_active=0
# shellcheck disable=SC2012  # filenames are controlled timestamps; ls is fine
[ "$(ls "${HOME}/.haven/alerts/"*.alert 2>/dev/null | wc -l)" -gt 0 ] && alert_active=1

dl_active=0
if [ -d "$DL_DIR" ]; then
  for f in "${DL_DIR}"/*.status; do
    [ -f "$f" ] || continue
    st=$(grep '^status=' "$f" 2>/dev/null | cut -d= -f2-)
    if [ "$st" = "downloading" ] || [ "$st" = "starting" ]; then
      dl_active=1; break
    fi
  done
fi

# ── System window command ─────────────────────────────────────────────────────
# Visual bar meters for memory (active / cache / available), per-core CPU
# (dynamic layout), disk, and GPU.
# Memory reads /proc/meminfo to distinguish truly consumed RAM from
# reclaimable kernel cache (buffers + page cache + SReclaimable), so the user
# can tell actual memory pressure at a glance.
# CPU layout scales dynamically: ≤12 cores → single column, 13–24 → dual
# column, >24 → aggregate bar + load averages.
SYSTEM_CMD='
export DOCKER_HOST=unix:///var/run/docker.sock
stty -echo 2>/dev/null
trap "stty echo 2>/dev/null" EXIT INT TERM

# ── Truecolor palette ─────────────────────────────────────────────────────────
C1="\033[38;2;57;170;170m"    # #39AAAA teal  — primary data / bar fill
C2="\033[38;2;140;223;224m"   # #8cdfe0 lteal — section headers
C3="\033[38;2;46;134;193m"    # #2E86C1 blue  — percentages, separators
CD="\033[38;2;80;100;110m"    # dim text
CE="\033[38;2;40;60;70m"      # bar empty-fill
CW="\033[38;2;220;180;50m"    # amber — bar >= 70%
CR2="\033[38;2;220;60;60m"    # red   — bar >= 90%
CB="\033[1m"
CR="\033[0m"
CG="\033[38;5;82m"            # System tab accent (green)

# ── Bar function ──────────────────────────────────────────────────────────────
# Usage: _bar <pct> [width]   (width defaults to 28)
# Prints a color-coded block bar. Turns amber at 70%, red at 90%.
_bar() {
    local pct="${1:-0}" width="${2:-28}"
    pct="${pct%%.*}"
    [ -z "$pct" ] || ! [ "$pct" -eq "$pct" ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    [ "$pct" -lt 0 ]   2>/dev/null && pct=0
    local fill=$(( pct * width / 100 ))
    local empty=$(( width - fill ))
    local clr="${C1}"
    [ "${pct}" -ge 70 ] 2>/dev/null && clr="${CW}"
    [ "${pct}" -ge 90 ] 2>/dev/null && clr="${CR2}"
    printf "${clr}"
    local _bi=0
    while [ "$_bi" -lt "$fill" ]; do
        printf "\xe2\x96\x88"   # U+2588 FULL BLOCK █
        _bi=$(( _bi + 1 ))
    done
    printf "${CE}"
    _bi=0
    while [ "$_bi" -lt "$empty" ]; do
        printf "\xe2\x96\x91"   # U+2591 LIGHT SHADE ░
        _bi=$(( _bi + 1 ))
    done
    printf "${CR}"
}

# ── Bar function (dim/fixed color) ────────────────────────────────────────────
# Usage: _bar_dim <pct> [width]
# Like _bar but always renders in dim teal — used for reclaimable cache so it
# never triggers amber/red alarm coloring (high cache is healthy on Linux).
_bar_dim() {
    local pct="${1:-0}" width="${2:-28}"
    pct="${pct%%.*}"
    [ -z "$pct" ] || ! [ "$pct" -eq "$pct" ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    [ "$pct" -lt 0 ]   2>/dev/null && pct=0
    local fill=$(( pct * width / 100 ))
    local empty=$(( width - fill ))
    printf "${CD}"
    local _bi=0
    while [ "$_bi" -lt "$fill" ];  do printf "\xe2\x96\x88"; _bi=$(( _bi + 1 )); done
    printf "${CE}"
    _bi=0
    while [ "$_bi" -lt "$empty" ]; do printf "\xe2\x96\x91"; _bi=$(( _bi + 1 )); done
    printf "${CR}"
}

# ── Human-readable bytes (integer, one decimal when >= KiB) ──────────────────
_hr() {
    local bytes="${1:-0}" val=0 rem=0 unit="B"
    [ -z "$bytes" ] || ! [ "$bytes" -eq "$bytes" ] 2>/dev/null && bytes=0
    val="$bytes"
    local u
    for u in B KiB MiB GiB TiB; do
        unit="$u"
        [ "$val" -lt 1024 ] && break
        rem=$(( val % 1024 ))
        val=$(( val / 1024 ))
    done
    if [ "$unit" != "B" ] && [ "$rem" -gt 0 ]; then
        local dec=$(( rem * 10 / 1024 ))
        printf "%d.%d %s" "$val" "$dec" "$unit"
    else
        printf "%d %s" "$val" "$unit"
    fi
}

# ── CPU delta helper ──────────────────────────────────────────────────────────
# Computes CPU usage % for a given core index (or "agg" for aggregate).
# Reads from global _curr_cpu and _prev_cpu (multi-line /proc/stat snapshots).
_cpu_pct() {
    local core="$1" pat
    [ "$core" = "agg" ] && pat="^cpu " || pat="^cpu${core} "
    local cl pl cu pu ci pi dt di pct
    cl=$(printf "%s\n" "$_curr_cpu" | grep "$pat" | head -1)
    pl=$(printf "%s\n" "$_prev_cpu" | grep "$pat" | head -1)
    [ -z "$cl" ] || [ -z "$pl" ] && echo 0 && return
    cu=$(echo "$cl" | awk "{print \$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9}")
    pu=$(echo "$pl" | awk "{print \$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9}")
    ci=$(echo "$cl" | awk "{print \$5}")
    pi=$(echo "$pl" | awk "{print \$5}")
    dt=$(( ${cu:-0} - ${pu:-0} ))
    di=$(( ${ci:-0} - ${pi:-0} ))
    pct=0
    [ "${dt:-0}" -gt 0 ] && pct=$(( 100 - (di * 100 / dt) ))
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    echo "$pct"
}

# ── Persistent state across loop iterations ───────────────────────────────────
_prev_cpu=""

# ── Main loop ─────────────────────────────────────────────────────────────────
while true; do
    printf "\033[2J\033[H"

    # ── Header ────────────────────────────────────────────────────────────────
    printf "  ${CB}${CG}System Stats${CR}  ${CD}(refreshes every 2s)${CR}\n"
    printf "  ${CB}${CG}[System]${CR}  ${CD}│  Downloads  │  Alerts  │  Containers  │  Sessions${CR}   ${CD}← → q${CR}\n"
    printf "  ${C3}──────────────────────────────────────────────────────────${CR}\n\n"

    # ── Memory ───────────────────────────────────────────────────────────────
    # Read all values from /proc/meminfo (kB → bytes via *1024).
    # MemAvailable is what the OS can actually give to new processes (free +
    # reclaimable cache). Active = Total - Available = truly consumed.
    # Cache total = Buffers + Cached + SReclaimable (all reclaimable under pressure).
    _meminfo=$(cat /proc/meminfo 2>/dev/null)
    _mt=$(    awk "/^MemTotal:/{     print \$2*1024}" <<< "$_meminfo"); _mt="${_mt:-0}"
    _mavail=$(awk "/^MemAvailable:/{  print \$2*1024}" <<< "$_meminfo"); _mavail="${_mavail:-0}"
    _mbuf=$(  awk "/^Buffers:/{       print \$2*1024}" <<< "$_meminfo"); _mbuf="${_mbuf:-0}"
    _mcache=$(awk "/^Cached:/{        print \$2*1024}" <<< "$_meminfo"); _mcache="${_mcache:-0}"
    _msrec=$( awk "/^SReclaimable:/{  print \$2*1024}" <<< "$_meminfo"); _msrec="${_msrec:-0}"
    _swt=$(   awk "/^SwapTotal:/{     print \$2*1024}" <<< "$_meminfo"); _swt="${_swt:-0}"
    _swf=$(   awk "/^SwapFree:/{      print \$2*1024}" <<< "$_meminfo"); _swf="${_swf:-0}"

    _mactive=$(( _mt - _mavail ))
    _mcache_total=$(( _mbuf + _mcache + _msrec ))
    _swused=$(( _swt - _swf ))

    _map=0; [ "${_mt:-1}"  -gt 0 ] 2>/dev/null && _map=$(( _mactive * 100       / _mt ))
    _cap=0; [ "${_mt:-1}"  -gt 0 ] 2>/dev/null && _cap=$(( _mcache_total * 100  / _mt ))
    _sp=0;  [ "${_swt:-1}" -gt 0 ] 2>/dev/null && _sp=$(( _swused * 100         / _swt ))

    printf "  ${C2}Memory${CR}  ${CD}total: $(_hr "${_mt}")   available: $(_hr "${_mavail}")${CR}\n"
    printf "    Active  ["; _bar     "$_map"; printf "]  ${C3}%3d%%${CR}  ${CD}$(_hr "${_mactive}")${CR}   ${CD}process memory${CR}\n" "$_map"
    printf "    Cache   ["; _bar_dim "$_cap"; printf "]  ${C3}%3d%%${CR}  ${CD}$(_hr "${_mcache_total}")${CR}   ${CD}buf / cache / slab${CR}\n" "$_cap"
    if [ "${_swt:-0}" -gt 0 ] 2>/dev/null; then
        printf "    Swap    ["; _bar "$_sp"; printf "]  ${C3}%3d%%${CR}  ${CD}$(_hr "${_swused}") / $(_hr "${_swt}")${CR}\n" "$_sp"
    fi
    printf "\n"

    # ── CPU ───────────────────────────────────────────────────────────────────
    _curr_cpu=$(grep "^cpu" /proc/stat 2>/dev/null)
    _ncores=$(printf "%s\n" "$_curr_cpu" | grep -c "^cpu[0-9]" 2>/dev/null || echo 0)

    _plural="cores"; [ "$_ncores" = "1" ] && _plural="core"
    printf "  ${C2}CPU${CR}  ${CD}(${_ncores} ${_plural})${CR}\n"

    if [ -n "$_prev_cpu" ]; then
        if [ "$_ncores" -le 12 ] 2>/dev/null; then
            # Single-column: one bar per core
            _c=0
            while [ "$_c" -lt "$_ncores" ]; do
                _pct=$(_cpu_pct "$_c")
                printf "    Core %2d  [" "$_c"; _bar "$_pct" 22; printf "]  ${C3}%3d%%${CR}\n" "$_pct"
                _c=$(( _c + 1 ))
            done
        elif [ "$_ncores" -le 24 ] 2>/dev/null; then
            # Dual-column: two cores per line
            _c=0
            while [ "$_c" -lt "$_ncores" ]; do
                _pct=$(_cpu_pct "$_c")
                _c2=$(( _c + 1 ))
                printf "    Core %2d  [" "$_c"; _bar "$_pct" 14; printf "]  ${C3}%3d%%${CR}" "$_pct"
                if [ "$_c2" -lt "$_ncores" ]; then
                    _pct2=$(_cpu_pct "$_c2")
                    printf "   Core %2d  [" "$_c2"; _bar "$_pct2" 14; printf "]  ${C3}%3d%%${CR}" "$_pct2"
                    _c=$(( _c2 + 1 ))
                else
                    _c=$(( _c + 1 ))
                fi
                printf "\n"
            done
        else
            # Aggregate mode: too many cores for per-core display
            _pct=$(_cpu_pct "agg")
            read -r _la1 _la5 _la15 _ < /proc/loadavg 2>/dev/null
            printf "    All    ["; _bar "$_pct"; printf "]  ${C3}%3d%%${CR}  ${CD}load: %s / %s / %s${CR}\n" \
                "$_pct" "${_la1:--}" "${_la5:--}" "${_la15:--}"
        fi
    else
        printf "    ${CD}Measuring CPU usage...${CR}\n"
    fi
    _prev_cpu="$_curr_cpu"
    printf "\n"

    # ── Disk ─────────────────────────────────────────────────────────────────
    read -r _disk_t _disk_u _disk_f < <(df -B1 / 2>/dev/null | awk "NR==2{print \$2, \$3, \$4}")
    _dp=0; [ "${_disk_t:-0}" -gt 0 ] 2>/dev/null && _dp=$(( _disk_u * 100 / _disk_t ))
    printf "  ${C2}Disk${CR}\n"
    printf "    /      ["; _bar "$_dp"; printf "]  ${C3}%3d%%${CR}  ${CD}$(_hr "${_disk_f:-0}") free / $(_hr "${_disk_t:-0}")${CR}\n\n" "$_dp"

    # ── GPU (canonical source: metrics-server :9091, no docker exec here) ─────
    # 1.0s timeout + tmpfs cache: metrics-server precomputes its payload every
    # 1s, but Docker/jq overhead means hitting the bar exactly during a slow
    # nvidia-smi can still race — keep last-good values in /run/haven so the
    # GPU section never blanks for more than the refresh interval.
    _gpu_cache="/run/haven/last-popup-gpu.tsv"
    _gm=$(curl -sf --max-time 1.0 http://127.0.0.1:9091/metrics.json 2>/dev/null)
    _gname=""; _gutil=""; _gused=""; _gtot=""
    if [ -n "$_gm" ]; then
        IFS="	" read -r _gname _gutil _gused _gtot < <(
            printf "%s" "$_gm" | jq -r "[
                (.gpu_name // \"\"),
                (.gpu_util_pct // \"\"),
                (.gpu_vram_used_mb // \"\"),
                (.gpu_vram_total_mb // \"\")
            ] | @tsv" 2>/dev/null
        )
        if [ -n "$_gname" ]; then
            mkdir -p /run/haven 2>/dev/null
            # Subshell isolates the redirect — bash redirect-open errors
            # escape plain 2>/dev/null on the printf when wrapped this way.
            ( printf "%s\t%s\t%s\t%s\n" "$_gname" "$_gutil" "$_gused" "$_gtot" \
                > "${_gpu_cache}.tmp" ) 2>/dev/null \
                && mv -f "${_gpu_cache}.tmp" "$_gpu_cache" 2>/dev/null
        fi
    fi
    # Fall back to cache on any failure or partial payload.
    if [ -z "$_gname" ] && [ -f "$_gpu_cache" ]; then
        IFS="	" read -r _gname _gutil _gused _gtot < "$_gpu_cache"
    fi
    if [ -n "$_gname" ]; then
        if [ -n "$_gutil" ]; then
            _gmp=0
            [ -n "$_gused" ] && [ -n "$_gtot" ] && [ "${_gtot:-0}" -gt 0 ] 2>/dev/null \
                && _gmp=$(( _gused * 100 / _gtot ))
            # Single-line header — vendor inferred from the model name shown next.
            printf "  ${C2}GPU${CR}\n"
            printf "    ${C1}%s${CR}\n" "$_gname"
            printf "    Util  ["; _bar "${_gutil:-0}"; printf "]  ${C3}%3d%%${CR}\n" "${_gutil:-0}"
            if [ -n "$_gused" ] && [ -n "$_gtot" ]; then
                _gug=$(awk "BEGIN{printf \"%.1f\", ${_gused:-0}/1024}")
                _gtg=$(awk "BEGIN{printf \"%.0f\", ${_gtot:-1}/1024}")
                printf "    VRAM  ["; _bar "$_gmp"; \
                    printf "]  ${C3}%3d%%${CR}  ${CD}%s GiB / %s GiB${CR}\n\n" "$_gmp" "$_gug" "$_gtg"
            else
                printf "\n"
            fi
        fi
    fi

    # ── Footer ────────────────────────────────────────────────────────────────
    printf "  ${CD}← → navigate   q close${CR}\n"

    # ── Key handler (2s timeout = refresh interval) ───────────────────────────
    _ESC=$(printf "\033")
    IFS= read -rt 2 -n1 _k 2>/dev/null
    if [ "$_k" = "$_ESC" ]; then
        IFS= read -rt 0.1 -n2 _rest 2>/dev/null
        _k="${_k}${_rest}"
    fi
    case "$_k" in
        "${_ESC}[C") tmux next-window     -t "$HAVEN_SESSION" 2>/dev/null ;;
        "${_ESC}[D") tmux previous-window -t "$HAVEN_SESSION" 2>/dev/null ;;
        q|Q)         tmux kill-session    -t "$HAVEN_SESSION" 2>/dev/null; exit 0 ;;
    esac
done'

# ── Downloads window command ──────────────────────────────────────────────────
DL_CMD='
export DOCKER_HOST=unix:///var/run/docker.sock
stty -echo 2>/dev/null
trap "stty echo 2>/dev/null" EXIT INT TERM

C2="\033[38;2;140;223;224m"
C3="\033[38;2;46;134;193m"
CD="\033[38;2;80;100;110m"
CB="\033[1m"
CR="\033[0m"
CY="\033[38;5;220m"

while true; do
    printf "\033[2J\033[H"
    printf "  ${CB}${CY}Background Downloads${CR}  ${CD}(refreshes every 3s)${CR}\n"
    printf "  ${CD}System  │${CR}  ${CB}${CY}[Downloads]${CR}  ${CD}│  Alerts  │  Containers  │  Sessions${CR}   ${CD}← → q${CR}\n"
    printf "  ${C3}──────────────────────────────────────────────────────────${CR}\n\n"
    haven pullback status 2>/dev/null \
        || printf "  ${CD}No active downloads.${CR}\n"
    printf "\n  ${CD}← → navigate   q close${CR}\n"

    _ESC=$(printf "\033")
    IFS= read -rt 3 -n1 _k 2>/dev/null
    if [ "$_k" = "$_ESC" ]; then
        IFS= read -rt 0.1 -n2 _rest 2>/dev/null
        _k="${_k}${_rest}"
    fi
    case "$_k" in
        "${_ESC}[C") tmux next-window     -t "$HAVEN_SESSION" 2>/dev/null ;;
        "${_ESC}[D") tmux previous-window -t "$HAVEN_SESSION" 2>/dev/null ;;
        q|Q)         tmux kill-session    -t "$HAVEN_SESSION" 2>/dev/null; exit 0 ;;
    esac
done'

# ── Alerts window command ─────────────────────────────────────────────────────
# Delegates to inferhaven-alerts-popup (fzf) when alerts exist.
# When no alerts, shows a placeholder with arrow-key navigation.
# sleep 0.3 before fzf launch lets the pane terminal fully initialize so
# fzf does not receive spurious escape sequences at startup.
# HAVEN_SESSION is injected via -e on new-window so the popup script can
# add carousel nav bindings to fzf.
ALERTS_CMD='
export DOCKER_HOST=unix:///var/run/docker.sock
stty -echo 2>/dev/null
trap "stty echo 2>/dev/null" EXIT INT TERM

C3="\033[38;2;46;134;193m"
CD="\033[38;2;80;100;110m"
CB="\033[1m"
CR="\033[0m"
CA="\033[38;5;196m"

while true; do
    _ac=$(ls "${HOME}/.haven/alerts/"*.alert 2>/dev/null | wc -l)
    if [ "${_ac:-0}" -eq 0 ]; then
        printf "\033[2J\033[H"
        printf "  ${CB}${CA}Alerts${CR}\n"
        printf "  ${CD}System  │  Downloads  │${CR}  ${CB}${CA}[Alerts]${CR}  ${CD}│  Containers  │  Sessions${CR}   ${CD}← → q${CR}\n"
        printf "  ${C3}──────────────────────────────────────────────────────────${CR}\n\n"
        printf "  ${CD}No alerts.${CR}\n\n"
        printf "  ${CD}Ollama load errors, OOM events, and container crashes will appear here.${CR}\n"
        printf "\n  ${CD}← → navigate   q close${CR}\n"

        _ESC=$(printf "\033")
        IFS= read -rt 3 -n1 _k 2>/dev/null
        if [ "$_k" = "$_ESC" ]; then
            IFS= read -rt 0.1 -n2 _rest 2>/dev/null
            _k="${_k}${_rest}"
        fi
        case "$_k" in
            "${_ESC}[C") tmux next-window     -t "$HAVEN_SESSION" 2>/dev/null ;;
            "${_ESC}[D") tmux previous-window -t "$HAVEN_SESSION" 2>/dev/null ;;
            q|Q)         tmux kill-session    -t "$HAVEN_SESSION" 2>/dev/null; exit 0 ;;
        esac
    else
        sleep 0.3
        inferhaven-alerts-popup
    fi
done'

# ── Containers window command ─────────────────────────────────────────────────
# Discovers running inferhaven-* containers dynamically via docker ps.
# Data is collected BEFORE the screen is cleared so there is no blank-screen
# flicker during the ~1s docker stats sampling window.
# CPU% from docker stats is reported as a share of all cores combined
# (e.g. 600% max on a 6-core system). It is normalized to 0-100% of total
# system capacity (raw / nproc) so the bar and color thresholds are meaningful.
CONTAINERS_CMD='
export DOCKER_HOST=unix:///var/run/docker.sock
stty -echo 2>/dev/null
trap "stty echo 2>/dev/null" EXIT INT TERM

# Source the compose-label resolver. Same library haven CLI uses, so the
# popup sees the same containers regardless of project name (codespaces vs
# dev override vs prod).
# shellcheck source=/dev/null
. /usr/local/lib/haven/haven-resolve.sh 2>/dev/null || true

C1="\033[38;2;57;170;170m"
C2="\033[38;2;140;223;224m"
C3="\033[38;2;46;134;193m"
CD="\033[38;2;80;100;110m"
CB="\033[1m"
CR="\033[0m"
CC="\033[38;5;45m"
CW="\033[38;2;220;180;50m"
CR2="\033[38;2;220;60;60m"
CE="\033[38;2;40;60;70m"

_bar() {
    local pct="${1:-0}" width="${2:-14}"
    pct="${pct%%.*}"
    [ -z "$pct" ] || ! [ "$pct" -eq "$pct" ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    [ "$pct" -lt 0 ]   2>/dev/null && pct=0
    local fill=$(( pct * width / 100 ))
    local empty=$(( width - fill ))
    local clr="${C1}"
    [ "${pct}" -ge 70 ] 2>/dev/null && clr="${CW}"
    [ "${pct}" -ge 90 ] 2>/dev/null && clr="${CR2}"
    printf "${clr}"
    local _bi=0
    while [ "$_bi" -lt "$fill" ]; do
        printf "\xe2\x96\x88"
        _bi=$(( _bi + 1 ))
    done
    printf "${CE}"
    _bi=0
    while [ "$_bi" -lt "$empty" ]; do
        printf "\xe2\x96\x91"
        _bi=$(( _bi + 1 ))
    done
    printf "${CR}"
}

# Detect host thread count once — used to normalize docker CPU% to 0-100%.
_ncpu=$(nproc 2>/dev/null || echo 1)
[ "${_ncpu:-1}" -lt 1 ] 2>/dev/null && _ncpu=1

while true; do
    # ── Collect data first (screen still showing previous render) ─────────────
    # Try without sudo first (haven user is in the docker group after Round-1
    # GID fix), fall back to sudo -n if the group propagation has not landed.
    _docker_ok=0
    _di_err=""
    _names=""
    _stats=""
    _proj=""
    _di_err=$(docker info 2>&1 >/dev/null) || _di_err=$(sudo -n docker info 2>&1 >/dev/null)
    _docker_ok=$?

    if [ $_docker_ok -eq 0 ]; then
        _proj=$(_haven_resolve_project 2>/dev/null)
        _names=$(_haven_resolve_all_containers 2>/dev/null | tr "\n" " ")
        if [ -n "$_names" ]; then
            _stats=$(docker stats --no-stream \
                --format "{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.PIDs}}" \
                ${_names} 2>&1) \
                || _stats=$(sudo -n docker stats --no-stream \
                    --format "{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.PIDs}}" \
                    ${_names} 2>&1)
        fi
    fi

    # ── Render atomically after data is ready ─────────────────────────────────
    printf "\033[2J\033[H"
    printf "  ${CB}${CC}Containers${CR}  ${CD}(refreshes every 5s)${CR}\n"
    printf "  ${CD}System  │  Downloads  │  Alerts  │${CR}  ${CB}${CC}[Containers]${CR}  ${CD}│  Sessions${CR}   ${CD}← → q${CR}\n"
    printf "  ${C3}──────────────────────────────────────────────────────────${CR}\n\n"

    if [ $_docker_ok -ne 0 ]; then
        printf "  ${CD}Docker error:${CR}\n  %s\n\n" "$_di_err"
    elif [ -z "$_names" ]; then
        printf "  ${CD}No InferHaven containers found running.${CR}\n\n"
    elif printf "%s" "$_stats" | grep -q "^Error"; then
        printf "  ${CD}docker stats error:${CR}\n  %s\n\n" "$_stats"
    else
        while IFS="|" read -r _nm _cpu _mem _memp _net _pids; do
            # Strip the project prefix dynamically. Falls back to the literal
            # historical prefix when no project label was resolvable.
            if [ -n "$_proj" ]; then
                _sname="${_nm#${_proj}-}"
            else
                _sname="${_nm#inferhaven-}"
            fi
            # Normalize docker CPU% (multi-core sum) to 0-100% of system capacity.
            _cpu_raw_i=$(printf "%s" "$_cpu" | tr -d "%" | cut -d. -f1)
            [ -z "$_cpu_raw_i" ] && _cpu_raw_i=0
            _cpu_i=$(( _cpu_raw_i / _ncpu ))
            _mp_i=$(printf  "%s" "$_memp" | tr -d "%" | cut -d. -f1)
            [ -z "$_mp_i"  ] && _mp_i=0
            printf "  ${CB}${CC}%s${CR}  ${CD}PIDs: %s${CR}\n" "$_sname" "$_pids"
            printf "    ${CD}CPU${CR}  ["; _bar "$_cpu_i"; printf "]  ${C3}%3d%%${CR}" "$_cpu_i"
            printf "   ${CD}MEM${CR}  ["; _bar "$_mp_i";  printf "]  ${C3}%5s${CR}  ${CD}%s${CR}\n" "$_memp" "$_mem"
            printf "    ${CD}NET  %s${CR}\n\n" "$_net"
        done <<< "$_stats"
    fi

    printf "  ${CD}← → navigate   q close${CR}\n"

    _ESC=$(printf "\033")
    IFS= read -rt 5 -n1 _k 2>/dev/null
    if [ "$_k" = "$_ESC" ]; then
        IFS= read -rt 0.1 -n2 _rest 2>/dev/null
        _k="${_k}${_rest}"
    fi
    case "$_k" in
        "${_ESC}[C") tmux next-window     -t "$HAVEN_SESSION" 2>/dev/null ;;
        "${_ESC}[D") tmux previous-window -t "$HAVEN_SESSION" 2>/dev/null ;;
        q|Q)         tmux kill-session    -t "$HAVEN_SESSION" 2>/dev/null; exit 0 ;;
    esac
done'

# ── Sessions window command ───────────────────────────────────────────────────
# Lists all tmux sessions (excluding the popup session itself).
# Action keys: n new, a attach/switch, r rename, k kill, s save (resurrect).
# fzf is used for session selection in multi-session actions; plain read for
# name prompts. Arrow keys navigate the carousel as usual.
SESSIONS_CMD='
stty -echo 2>/dev/null
trap "stty echo 2>/dev/null" EXIT INT TERM

C1="\033[38;2;57;170;170m"
C2="\033[38;2;140;223;224m"
C3="\033[38;2;46;134;193m"
CD="\033[38;2;80;100;110m"
CB="\033[1m"
CR="\033[0m"
CR2="\033[38;2;220;60;60m"
CP="\033[38;5;141m"

while true; do
    printf "\033[2J\033[H"
    printf "  ${CB}${CP}Sessions${CR}  ${CD}(refreshes every 3s)${CR}\n"
    printf "  ${CD}System  │  Downloads  │  Alerts  │  Containers  │${CR}  ${CB}${CP}[Sessions]${CR}   ${CD}← → q${CR}\n"
    printf "  ${C3}──────────────────────────────────────────────────────────${CR}\n\n"

    _slist=$(tmux list-sessions \
        -F "#{session_name}|#{session_windows}|#{?session_attached,attached,detached}" \
        2>/dev/null \
        | grep -v "^${HAVEN_SESSION}|" \
        | grep -v "^haven-popup-")

    if [ -z "$_slist" ]; then
        printf "  ${CD}No tmux sessions found.${CR}\n\n"
    else
        printf "  ${C2}%-22s  %7s  %-10s${CR}\n" "NAME" "WINDOWS" "STATUS"
        printf "  ${CD}─────────────────────────────────────────────────${CR}\n"
        while IFS="|" read -r _sn _sw _sst; do
            _sc="${CD}"
            [ "$_sst" = "attached" ] && _sc="${C1}"
            printf "  ${CB}${C1}%-22s${CR}  ${CD}%3s win   ${_sc}%-10s${CR}\n" \
                "$_sn" "$_sw" "$_sst"
        done <<< "$_slist"
    fi

    # ── tmate (pair-programming) ─────────────────────────────────────────────
    _tmate_state="${HOME}/.haven/tmate.state"
    _tmate_sock="${HOME}/.haven/tmate.sock"
    if [ -f "${_tmate_state}" ] \
       && [ -S "${_tmate_sock}" ] \
       && tmate -S "${_tmate_sock}" display -p "#{tmate_ssh}" >/dev/null 2>&1; then
        _t_ssh=$(grep "^ssh_url=" "${_tmate_state}" | cut -d= -f2-)
        _t_web=$(grep "^web_url=" "${_tmate_state}" | cut -d= -f2-)
        _t_started=$(grep "^started=" "${_tmate_state}" | cut -d= -f2-)
        if [ -n "${_t_started}" ]; then
            _t_age=$(( $(date +%s) - _t_started ))
            _t_age_h=$(( _t_age / 3600 ))
            _t_age_m=$(( (_t_age % 3600) / 60 ))
            _t_age_str="${_t_age_h}h${_t_age_m}m"
        else
            _t_age_str="?"
        fi
        _t_server_label=""
        _tmate_settings="${HOME}/.haven/tmate-settings"
        if [ -f "${_tmate_settings}" ]; then
            _t_srv=$(grep "^server=" "${_tmate_settings}" | cut -d= -f2-)
            _t_host=$(grep "^self_host=" "${_tmate_settings}" | cut -d= -f2-)
            _t_port=$(grep "^self_port=" "${_tmate_settings}" | cut -d= -f2-)
            if [ "${_t_srv}" = "self-hosted" ] && [ -n "${_t_host}" ]; then
                _t_server_label="${_t_host}:${_t_port:-22} (self-hosted)"
            elif [ "${_t_srv}" = "public" ]; then
                _t_server_label="tmate.io (public)"
            fi
        fi
        printf "\n  ${CB}${CP}tmate (pair-programming)${CR}  ${CD}up ${_t_age_str}${CR}\n"
        printf "  ${CD}─────────────────────────────────────────────────${CR}\n"
        [ -n "${_t_ssh}"          ] && printf "  ${C2}SSH:${CR}    ${_t_ssh}\n"
        [ -n "${_t_web}"          ] && printf "  ${C2}Web:${CR}    ${_t_web}\n"
        [ -n "${_t_server_label}" ] && printf "  ${C2}Server:${CR} ${_t_server_label}\n"
    fi

    printf "\n  ${CD}n new   a attach   r rename   k kill   s save${CR}\n"
    printf "  ${CD}t tmate-start   T tmate-kill                  ${CR}\n"
    printf "  ${CD}← → navigate   q close${CR}\n"

    _ESC=$(printf "\033")
    IFS= read -rt 3 -n1 _k 2>/dev/null
    if [ "$_k" = "$_ESC" ]; then
        IFS= read -rt 0.1 -n2 _rest 2>/dev/null
        _k="${_k}${_rest}"
    fi

    case "$_k" in
        "${_ESC}[C") tmux next-window     -t "$HAVEN_SESSION" 2>/dev/null ;;
        "${_ESC}[D") tmux previous-window -t "$HAVEN_SESSION" 2>/dev/null ;;
        q|Q)         tmux kill-session    -t "$HAVEN_SESSION" 2>/dev/null; exit 0 ;;

        n|N)
            printf "\n  ${C2}New session name:${CR} "
            stty echo 2>/dev/null
            read -r _new_name 2>/dev/null
            stty -echo 2>/dev/null
            if [ -n "$_new_name" ]; then
                if tmux new-session -d -s "$_new_name" 2>/dev/null; then
                    printf "  ${C1}Created: %s${CR}\n" "$_new_name"
                else
                    printf "  ${CR2}Failed — name may already exist or be invalid.${CR}\n"
                fi
                sleep 1
            fi
            ;;

        a|A)
            _target=$(tmux list-sessions -F "#{session_name}" 2>/dev/null \
                | grep -v "^${HAVEN_SESSION}$" \
                | grep -v "^haven-popup-" \
                | fzf --prompt="Switch to > " --height=40% --reverse --no-info 2>/dev/null)
            if [ -n "$_target" ]; then
                # Switch the outer client to the target session, then close popup.
                tmux switch-client -c "${HAVEN_OUTER_CLIENT}" -t "$_target" 2>/dev/null \
                    || tmux switch-client -t "$_target" 2>/dev/null
                tmux kill-session -t "$HAVEN_SESSION" 2>/dev/null
                exit 0
            fi
            ;;

        r|R)
            _target=$(tmux list-sessions -F "#{session_name}" 2>/dev/null \
                | grep -v "^${HAVEN_SESSION}$" \
                | grep -v "^haven-popup-" \
                | fzf --prompt="Rename > " --height=40% --reverse --no-info 2>/dev/null)
            if [ -n "$_target" ]; then
                printf "  ${C2}New name for \"%s\":${CR} " "$_target"
                stty echo 2>/dev/null
                read -r _new_name 2>/dev/null
                stty -echo 2>/dev/null
                if [ -n "$_new_name" ]; then
                    if tmux rename-session -t "$_target" "$_new_name" 2>/dev/null; then
                        printf "  ${C1}Renamed to: %s${CR}\n" "$_new_name"
                    else
                        printf "  ${CR2}Failed.${CR}\n"
                    fi
                    sleep 1
                fi
            fi
            ;;

        k|K)
            _target=$(tmux list-sessions -F "#{session_name}" 2>/dev/null \
                | grep -v "^${HAVEN_SESSION}$" \
                | grep -v "^haven-popup-" \
                | fzf --prompt="Kill > " --height=40% --reverse --no-info 2>/dev/null)
            if [ -n "$_target" ]; then
                printf "  Kill \"%s\"? (y/n): " "$_target"
                read -rn1 _confirm 2>/dev/null
                printf "\n"
                if [ "$_confirm" = "y" ] || [ "$_confirm" = "Y" ]; then
                    if tmux kill-session -t "$_target" 2>/dev/null; then
                        printf "  ${C1}Killed.${CR}\n"
                    else
                        printf "  ${CR2}Failed.${CR}\n"
                    fi
                    sleep 1
                fi
            fi
            ;;

        s|S)
            if bash ~/.tmux/plugins/tmux-resurrect/scripts/save.sh 2>/dev/null; then
                printf "\n  ${C1}Sessions saved.${CR}\n"
            else
                printf "\n  ${CR2}Resurrect save script not found.${CR}\n"
            fi
            sleep 1.5
            ;;

        t)
            printf "\n  ${C2}Starting tmate session...${CR}\n"
            haven tmate start 2>&1 | sed "s/^/  /"
            sleep 2
            ;;
        T)
            printf "\n  Kill tmate session? (y/n): "
            read -rn1 _confirm 2>/dev/null
            printf "\n"
            if [ "$_confirm" = "y" ] || [ "$_confirm" = "Y" ]; then
                haven tmate kill 2>&1 | sed "s/^/  /"
                sleep 1
            fi
            ;;
    esac
done'

# ── Pre-fetch AMD GPU name from ollama logs ───────────────────────────────────
# Done here (outer script) to avoid single-quote constraints inside SYSTEM_CMD.
# grep -m1 exits on first match, causing SIGPIPE to docker logs → fast exit.
# shellcheck source=/dev/null
. /usr/local/lib/haven/haven-resolve.sh 2>/dev/null || true
_ih_ollama_name=$(_haven_resolve_container ollama 2>/dev/null)
if [ -n "$_ih_ollama_name" ]; then
  _ih_amd_gpu_name=$(timeout 3 docker logs "$_ih_ollama_name" 2>&1 \
    | grep -m1 -o 'ggml_vulkan: [0-9]* = [^|(]*' \
    | sed 's/ggml_vulkan: [0-9]* = //;s/[[:space:]]*$//')
fi

# ── Create the tmux session ───────────────────────────────────────────────────
TMUX= tmux new-session -d -s "$SESSION" -x "$COLS" -y "$LINES" \
  -n "System" \
  -e "HAVEN_SESSION=${SESSION}" \
  -e "IH_AMD_GPU_NAME=${_ih_amd_gpu_name}" \
  "bash -c '${SYSTEM_CMD}'"

# Hide the inner status bar — outer bar stays visible under the popup.
TMUX= tmux set-option -t "$SESSION" status off

# Downloads, Alerts, Containers, Sessions windows.
# -e injects HAVEN_SESSION into each pane so arrow-key handlers can target
# the correct session via tmux commands.
TMUX= tmux new-window -t "$SESSION" -n "Downloads" \
  -e "HAVEN_SESSION=${SESSION}" \
  "bash -c '${DL_CMD}'"

TMUX= tmux new-window -t "$SESSION" -n "Alerts" \
  -e "HAVEN_SESSION=${SESSION}" \
  "bash -c '${ALERTS_CMD}'"

TMUX= tmux new-window -t "$SESSION" -n "Containers" \
  -e "HAVEN_SESSION=${SESSION}" \
  "bash -c '${CONTAINERS_CMD}'"

TMUX= tmux new-window -t "$SESSION" -n "Sessions" \
  -e "HAVEN_SESSION=${SESSION}" \
  -e "HAVEN_OUTER_CLIENT=${OUTER_CLIENT}" \
  "bash -c '${SESSIONS_CMD}'"

# ── Start on the most relevant view ──────────────────────────────────────────
if [ "$alert_active" -eq 1 ]; then
  TMUX= tmux select-window -t "${SESSION}:Alerts"
elif [ "$dl_active" -eq 1 ]; then
  TMUX= tmux select-window -t "${SESSION}:Downloads"
else
  TMUX= tmux select-window -t "${SESSION}:System"
fi

# ── Open the popup ────────────────────────────────────────────────────────────
tmux display-popup -E \
  -w 92% -h 88% \
  -T " InferHaven  ← → navigate   q close " \
  "exec tmux attach-session -t '${SESSION}'"

# Always exit 0 — prevents run-shell from printing "returned N" error messages
exit 0
