#!/bin/bash
###############################################################################
# haven — InferHaven CLI (workspace-internal)
#
# Runs inside the workspace container. Ollama is always reached via the
# container-internal service name — no host port conflicts possible.
#
# Usage: haven <command> [args]
###############################################################################
set -e

VERSION="0.1.0"
OLLAMA_URL="${OLLAMA_HOST:-http://ollama:11434}"
COMPOSE_FILE="${INFERHAVEN_DIR:-/opt/inferhaven}/docker-compose.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ── Docker access wrapper ─────────────────────────────────────────────────────
# The haven user has passwordless sudo (NOPASSWD:ALL). If the docker group
# membership from the entrypoint hasn't propagated to this SSH session yet,
# transparently fall back to sudo so all docker commands just work.
if ! docker info > /dev/null 2>&1; then
  # shellcheck disable=SC2032,SC2033  # intentional wrapper: interactive docker calls route through sudo
  docker() { sudo docker "$@"; }
fi

# ── Sibling-container resolution ──────────────────────────────────────────────
# Shared library: _haven_resolve_project, _haven_resolve_container,
# _haven_resolve_compose_files (plus back-compat aliases _haven_compose_project,
# _haven_container, _haven_self_container_id). Used by monitoring scripts +
# popup + alert-watcher so every InferHaven surface resolves containers the
# same way.
# shellcheck source=/dev/null
. /usr/local/lib/haven/haven-resolve.sh

# _haven_compose <args> → docker compose -p <our-project> <args>
# Compose v2 resolves services by container label when given just -p, so we
# don't have to translate host-side compose file paths to in-container paths.
# Falls back to -f $COMPOSE_FILE when self-detection fails.
_haven_compose() {
  local proj
  proj="$(_haven_resolve_project)"
  if [ -n "$proj" ]; then
    docker compose -p "$proj" "$@"
  else
    docker compose -f "$COMPOSE_FILE" "$@"
  fi
}

# ── Help ──────────────────────────────────────────────────────────────────────
cmd_help() {
  echo ""
  echo -e "  ${CYAN}${BOLD}InferHaven${NC} v${VERSION} — A safe haven for AI inference"
  echo ""
  echo "  Usage: haven <command> [args]"
  echo ""
  echo -e "  ${BOLD}Models${NC}"
  echo "    models                    List downloaded models"
  echo "    pull <model>              Download a model (foreground, with progress)"
  echo "    pullback <model>          Download a model in the background"
  echo "    pullback status           Show all background download progress"
  echo "    pullback cancel <model>   Cancel a background download"
  echo "    remove <model>            Delete a model"
  echo "    show <model>              Show model details (params, template, etc.)"
  echo "    show <model> --modelfile  Print the raw Modelfile (debug tune/params)"
  echo "    ps                        List models currently loaded in memory"
  echo "    unload [model]            Force-unload from GPU/RAM; omit model to unload all"
  echo "    cp <source> <dest>        Copy / rename a model"
  echo "    chat [model]              Interactive chat (default: \$DEFAULT_MODEL)"
  echo "    run <model> [prompt]      Run a model (interactive or one-shot with a prompt)"
  echo "    push <model>              Push a model to ollama.com"
  echo "    signin                    Authenticate with ollama.com"
  echo "    signout                   Sign out of ollama.com"
  echo ""
  echo -e "  ${BOLD}Status${NC}"
  echo "    status                    Service status + model count"
  echo "    logs [service]            Stream logs (all services or one)"
  echo "    doctor                    Diagnose this environment"
  echo ""
  echo -e "  ${BOLD}SSH / IDE${NC}"
  echo "    ssh-key \"<pubkey>\"        Add an SSH public key"
  echo "    ssh                       Show SSH connection command"
  echo "    ide                       Show web IDE URL"
  echo "    tmate                     Start a shared tmate session for pair programming"
  echo ""
  echo -e "  ${BOLD}Service / system${NC}"
  echo "    service <name> <action>   Wrapper around docker compose (status/restart/stop/start/logs)"
  echo "    limits                    Show container cgroup limits vs host capacity"
  echo "    gpu-info                  Canonical GPU summary (driver, util, VRAM)"
  echo "    backup configure          Interactively set up an rclone remote
    backup status [remote:]   Show local backup paths + configured remotes (or check a remote)
    backup push|pull          Snapshot ~/.haven + configs to / from an rclone remote"
  echo ""
  echo -e "  ${BOLD}Starship prompt${NC}"
  echo "    starship                  Show prompt mode and config path"
  echo "    starship emoji            Switch badge to emoji mode (🏡 IH) — no Nerd Font needed"
  echo "    starship nf               Switch badge to Nerd Font mode (󰚊 IH)"
  echo "    starship reset            Restore InferHaven default config"
  echo "    starship edit             Open ~/.config/starship.toml in \$EDITOR"
  echo ""
  echo -e "  ${BOLD}Tmux workspace${NC}"
  echo "    tmux                      Attach to the 'Haven' session (always running)"
  echo "    tmux ls                   List all active sessions"
  echo "    tmux new <name>           Create a new named session"
  echo "    tmux kill <name>          Kill a session"
  echo "    tmux save / restore       Manual save or restore via tmux-resurrect"
  echo "    tmux plugin <sub>         Manage plugins (list / install / update / bootstrap)"
  echo ""
  echo -e "  ${BOLD}Packages${NC}"
  echo "    apt install <pkg...>      Install and persist packages across restarts"
  echo "    apt remove  <pkg...>      Untrack package"
  echo "    apt list                  Show tracked packages"
  echo "    apt update                Refresh package lists"
  echo "    apt upgrade               Upgrade all tracked packages"
  echo ""
  echo -e "  ${BOLD}Stack management (run from host)${NC}"
  echo "    up / down / restart / reset / update"
  echo "    → These modify the Docker stack itself. Run them from the host:"
  echo "      ./scripts/haven <command>"
  echo ""
  echo -e "  ${BOLD}Model parameters${NC}"
  echo "    params <model>                    Show current parameters"
  echo "    params <model> set <key> <value>  Set a parameter"
  echo "      num_ctx         int     Context window size (default 2048)"
  echo "      num_predict     int     Max tokens per response; -1=unlimited"
  echo "      temperature     0–1     Creativity — lower is more focused (default 0.8)"
  echo "      top_p           0–1     Nucleus sampling threshold (default 0.9)"
  echo "      top_k           int     Top-k candidates per step (default 40)"
  echo "      repeat_penalty  float   Penalise repeated tokens (default 1.1)"
  echo "      presence_penalty float  Penalise already-used tokens (default 0)"
  echo "    params <model> reset              Reset all parameters to defaults"
  echo ""
  echo -e "  ${BOLD}Model tuning${NC}"
  echo "    tune [--dry-run] <model>  Inject tool-call template + stop tokens"
  echo "                              for reliable use with coding assistants."
  echo "                              Sets context window to 32 768 (capped at model max)."
  echo "                              Tested families (full tune):"
  echo "                                qwen2.5  qwen3  llama3.{0,1,2,3}  deepseek"
  echo "                                mistral  phi4   codellama  gemma{2,3}"
  echo "                              Anything else: safe defaults (num_ctx only)."
  echo "                              Override: HAVEN_FORCE_FAMILY=<family> haven tune <model>"
  echo "    untune <model>            Restore Modelfile from the pre-tune backup"
  echo ""
  echo -e "  ${BOLD}Coding assistants${NC}"
  echo "    harness                   Show installed coding assistant harnesses"
  echo "    claude                    Launch Claude Code with a local Ollama model"
  echo "    aider                     Launch Aider with a local Ollama model"
  echo "    goose                     Launch Goose with a local Ollama model"
  echo "    qwen                      Launch Qwen Code with a local Ollama model"
  echo ""
  echo -e "  ${BOLD}Caddy proxy${NC}"
  echo "    caddy                     Show Caddy TLS mode and domain"
  echo "    caddy cert                Export root CA + print per-OS trust instructions"
  echo ""
  echo -e "  ${BOLD}Nested devcontainer (dev-in-prod, build-based projects)${NC}"
  echo "    devcontainer up [path] [--flavor <sub>|--config <p>]   Build + start"
  echo "    devcontainer down [path]                               Tear it down"
  echo "    devcontainer help                                      Full reference"
  echo ""
  echo -e "  ${BOLD}Nested InferHaven compose (inferhaven-in-inferhaven)${NC}"
  echo "    nest up <path> [--flavor <sub>]    Spin up a second InferHaven stack"
  echo "    nest down <path>                   Tear down the nested stack"
  echo "    nest exec <path> -- <cmd>          Exec inside (-u haven)"
  echo "    nest status [path|all]             Show running nested stacks"
  echo "    nest help                          Full reference"
  echo ""
}

# ── OpenCode helpers ──────────────────────────────────────────────────────────

# Return the active OpenCode config file path.
# Per OpenCode docs, the global config is ~/.config/opencode/config.json.
# If settings.json exists from a previous install, use it (migration path).
_opencode_config_path() {
  local dir="${HOME}/.config/opencode"
  if [ -f "${dir}/settings.json" ]; then
    echo "${dir}/settings.json"
  else
    echo "${dir}/config.json"
  fi
}

# ── Tool-config sync (single driver in /usr/local/lib/haven/haven-sync.sh) ────
# All per-tool sync logic lives in lib/haven-sync.sh. Functions here are thin
# back-compat wrappers so existing callsites continue to work after the refactor.
# shellcheck source=/dev/null
. /usr/local/lib/haven/haven-models.sh
# shellcheck source=/dev/null
. /usr/local/lib/haven/haven-sync.sh
# shellcheck source=/dev/null
. /usr/local/lib/haven/haven-tune-detect.sh

# Back-compat shims: callsites in this file invoke these names; new code should
# use _haven_sync <tool> or _haven_sync_all directly.
_sync_opencode_models() { _haven_sync opencode; }
_sync_aider_models()    { _haven_sync aider; }
_sync_qwencode_models() { _haven_sync qwencode; }
_sync_pi_models()       { _haven_sync pi; }
_sync_goose_models()    { _haven_sync goose; }
_sync_continue_models() { _haven_sync continue; }
_sync_avante_models()   { _haven_sync avante; }


# ── Model management ──────────────────────────────────────────────────────────
cmd_models() {
  echo -e "\n  ${CYAN}Installed models:${NC}\n"
  local out
  out=$(curl -sf "${OLLAMA_URL}/api/tags" 2>/dev/null) || {
    echo "  Error: Cannot reach Ollama (${OLLAMA_URL}). Are services running?"
    exit 1
  }
  echo "${out}" | jq -r '
    .models[]
    | "  \(.name)\t\(.details.parameter_size // "?")\t\(.details.quantization_level // "?")\t\(.size / 1073741824 | . * 10 | round / 10 | tostring)GB"
  ' 2>/dev/null | awk '{  printf "  %-30s %-20s %-15s %s\n", $1, $2, $3, $4 }' || echo "  (no models installed)"
  echo ""
}

cmd_pull() {
  if [ -z "${1:-}" ]; then
    echo "Usage: haven pull <model>"
    echo "Example: haven pull qwen2.5-coder:7b"
    exit 1
  fi
  echo -e "${CYAN}[InferHaven]${NC} Pulling model: $1"
  local pull_error=""
  while IFS= read -r line; do
    local jerror status total completed
    jerror=$(printf '%s' "$line" | jq -r '.error // empty' 2>/dev/null)
    if [ -n "$jerror" ]; then
      pull_error="$jerror"
      break
    fi
    status=$(printf '%s' "$line" | jq -r '.status // empty' 2>/dev/null)
    total=$(printf '%s' "$line" | jq -r '.total // empty' 2>/dev/null)
    completed=$(printf '%s' "$line" | jq -r '.completed // empty' 2>/dev/null)
    if [ -n "$total" ] && [ -n "$completed" ] && [ "$total" -gt 0 ]; then
      local pct=$(( completed * 100 / total ))
      printf '\r  %s … %d%%' "$status" "$pct"
    elif [ -n "$status" ]; then
      printf '\r  %-60s' "$status"
    fi
  done < <(curl -s "${OLLAMA_URL}/api/pull" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"$1\"}")
  echo ""
  if [ -n "$pull_error" ]; then
    echo -e "${RED}[InferHaven]${NC} Error: ${pull_error}" >&2
    return 1
  fi
  echo -e "${GREEN}[InferHaven]${NC} Model $1 ready."
  _haven_sync_all || true

  # Auto-tune: optimise context window, stop tokens, and template for all models.
  # Named families (qwen3, llama3, mistral, gemma, etc.) get full template tuning.
  # Unknown models get context window optimisation with safe defaults.
  # Skipped if HAVEN_AUTO_TUNE=0.
  if [ "${HAVEN_AUTO_TUNE:-1}" != "0" ]; then
    echo -e "${CYAN}[InferHaven]${NC} Auto-tuning for coding assistant use..."
    cmd_tune "$1"
  fi
}

# ── Background download helpers ───────────────────────────────────────────────

# Convert a model name to a filesystem-safe slug (colons and slashes → underscores)
_model_slug() {
  printf '%s' "$1" | tr ':/' '__'
}

# Internal worker — invoked via: haven _pullback_worker <model>
# Runs detached (nohup). Streams Ollama pull API, updates ~/.haven/downloads/<slug>.status.
_pullback_worker() {
  local model="$1"
  local slug
  slug=$(_model_slug "$model")
  local dl_dir="${HOME}/.haven/downloads"
  mkdir -p "${dl_dir}"
  local sf="${dl_dir}/${slug}.status"
  local tf="${sf}.tmp"
  local started
  started=$(date +%s)

  # Write initial status file
  printf 'model=%s\nslug=%s\npid=%s\npct=0\nstatus=starting\nstarted=%s\nupdated=%s\nsize_total=0\nsize_done=0\n' \
    "$model" "$slug" "$$" "$started" "$started" > "$sf"

  local had_error=0
  local final_pct=0

  # Stream the pull API via process substitution so the while loop runs in the
  # current shell (variables like final_pct are visible after the loop).
  while IFS= read -r line; do
    local jstatus jtotal jcompleted jerror
    jstatus=$(printf '%s' "$line" | jq -r '.status // empty' 2>/dev/null)
    jtotal=$(printf '%s'   "$line" | jq -r '.total // empty'   2>/dev/null)
    jcompleted=$(printf '%s' "$line" | jq -r '.completed // empty' 2>/dev/null)
    jerror=$(printf '%s' "$line" | jq -r '.error // empty' 2>/dev/null)
    local now
    now=$(date +%s)

    # Ollama error response
    if [ -n "$jerror" ]; then
      printf 'model=%s\nslug=%s\npid=%s\npct=0\nstatus=error\nstarted=%s\nupdated=%s\nsize_total=0\nsize_done=0\nerror=%s\n' \
        "$model" "$slug" "$$" "$started" "$now" "$jerror" > "$sf"
      had_error=1
      break
    fi

    # Progress with byte counts
    if [ -n "$jtotal" ] && [ -n "$jcompleted" ] && [ "$jtotal" -gt 0 ] 2>/dev/null; then
      local pct
      pct=$(( jcompleted * 100 / jtotal ))
      final_pct=$pct
      printf 'model=%s\nslug=%s\npid=%s\npct=%s\nstatus=downloading\nstarted=%s\nupdated=%s\nsize_total=%s\nsize_done=%s\n' \
        "$model" "$slug" "$$" "$pct" "$started" "$now" "$jtotal" "$jcompleted" > "$tf" \
        && mv "$tf" "$sf"
    elif [ -n "$jstatus" ]; then
      # Status-only line (e.g. "pulling manifest")
      printf 'model=%s\nslug=%s\npid=%s\npct=%s\nstatus=downloading\nstarted=%s\nupdated=%s\nsize_total=0\nsize_done=0\n' \
        "$model" "$slug" "$$" "$final_pct" "$started" "$now" > "$tf" \
        && mv "$tf" "$sf"
    fi
  done < <(curl -s --no-buffer "${OLLAMA_URL}/api/pull" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"${model}\"}")

  [ "$had_error" -ne 0 ] && return 1

  # Mark done
  local now
  now=$(date +%s)
  printf 'model=%s\nslug=%s\npid=%s\npct=100\nstatus=done\nstarted=%s\nupdated=%s\n' \
    "$model" "$slug" "$$" "$started" "$now" > "$sf"

  # Post-pull sync (same as cmd_pull)
  _haven_sync_all 2>/dev/null || true

  if [ "${HAVEN_AUTO_TUNE:-1}" != "0" ]; then
    cmd_tune "$model" 2>/dev/null || true
  fi

  # Leave the done status visible for 60s so status/status-bar can show it, then clean up
  sleep 60
  rm -f "$sf"
}

_pullback_start() {
  local model="$1"
  local slug
  slug=$(_model_slug "$model")
  local dl_dir="${HOME}/.haven/downloads"
  mkdir -p "${dl_dir}"
  local sf="${dl_dir}/${slug}.status"

  # Already in progress?
  if [ -f "$sf" ]; then
    local existing_status
    existing_status=$(grep '^status=' "$sf" 2>/dev/null | cut -d= -f2-)
    if [ "$existing_status" = "downloading" ] || [ "$existing_status" = "starting" ]; then
      echo -e "${YELLOW}[InferHaven]${NC} $model is already downloading."
      echo "  Run: haven pullback status"
      return 0
    fi
    # Stale done/error entry — remove and restart
    rm -f "$sf"
  fi

  # Soft concurrency cap: 5 simultaneous downloads
  local active=0
  for _f in "${dl_dir}"/*.status; do
    [ -f "$_f" ] || continue
    local _s
    _s=$(grep '^status=' "$_f" 2>/dev/null | cut -d= -f2-)
    # shellcheck disable=SC2015  # `|| true` keeps counter increment non-fatal
    { [ "$_s" = "downloading" ] || [ "$_s" = "starting" ]; } && active=$(( active + 1 )) || true
  done
  if [ "$active" -ge 5 ]; then
    echo -e "${YELLOW}[InferHaven]${NC} 5 downloads already in progress (soft cap)."
    echo "  Wait for one to complete or run: haven pullback status"
    return 1
  fi

  # Verify Ollama is reachable
  if ! curl -sf --max-time 2 "${OLLAMA_URL}/api/tags" > /dev/null 2>&1; then
    echo -e "${RED}[InferHaven]${NC} Cannot reach Ollama at ${OLLAMA_URL}."
    exit 1
  fi

  # Launch background worker (nohup + exec so $$ in worker == $! here)
  nohup /usr/local/bin/haven _pullback_worker "$model" \
    >> "${HOME}/.haven/install.log" 2>&1 &
  local worker_pid=$!

  echo -e "${CYAN}[InferHaven]${NC} Downloading ${BOLD}$model${NC} in the background (PID $worker_pid)."
  echo "  haven pullback status         — check progress"
  echo "  haven pullback cancel $model  — cancel"
}

_pullback_status() {
  local dl_dir="${HOME}/.haven/downloads"
  mkdir -p "${dl_dir}"

  local active=0 done_count=0 error_count=0
  local active_out="" done_out="" error_out=""

  for _f in "${dl_dir}"/*.status; do
    [ -f "$_f" ] || continue
    local model pct status started size_total size_done errmsg
    model=$(grep '^model=' "$_f" 2>/dev/null | cut -d= -f2-)
    pct=$(grep '^pct=' "$_f" 2>/dev/null | cut -d= -f2-)
    status=$(grep '^status=' "$_f" 2>/dev/null | cut -d= -f2-)
    started=$(grep '^started=' "$_f" 2>/dev/null | cut -d= -f2-)
    size_total=$(grep '^size_total=' "$_f" 2>/dev/null | cut -d= -f2-)
    size_done=$(grep '^size_done=' "$_f" 2>/dev/null | cut -d= -f2-)
    errmsg=$(grep '^error=' "$_f" 2>/dev/null | cut -d= -f2-)
    [ -z "$model" ] && continue
    pct="${pct:-0}"
    status="${status:-unknown}"
    size_total="${size_total:-0}"
    size_done="${size_done:-0}"

    # Human-readable age
    local now age_s age_str
    now=$(date +%s)
    age_s=$(( now - ${started:-$now} ))
    if [ "$age_s" -lt 60 ]; then
      age_str="${age_s}s ago"
    elif [ "$age_s" -lt 3600 ]; then
      age_str="$(( age_s / 60 ))m ago"
    else
      age_str="$(( age_s / 3600 ))h ago"
    fi

    # Human-readable size (GB or MB)
    local size_str=""
    if [ "$size_total" -gt 0 ] 2>/dev/null; then
      local gb_done gb_total
      gb_done=$(awk "BEGIN{printf \"%.1f\", $size_done/1073741824}")
      gb_total=$(awk "BEGIN{printf \"%.1f\", $size_total/1073741824}")
      if [ "$size_total" -ge 1073741824 ] 2>/dev/null; then
        size_str="  ${gb_done}/${gb_total} GB"
      else
        local mb_done mb_total
        mb_done=$(( size_done / 1048576 ))
        mb_total=$(( size_total / 1048576 ))
        size_str="  ${mb_done}/${mb_total} MB"
      fi
    fi

    # 20-char ASCII progress bar
    local filled empty bar=""
    filled=$(( pct * 20 / 100 ))
    empty=$(( 20 - filled ))
    local _i=0
    while [ "$_i" -lt "$filled" ]; do bar="${bar}█"; _i=$(( _i + 1 )); done
    _i=0
    while [ "$_i" -lt "$empty" ]; do bar="${bar}░"; _i=$(( _i + 1 )); done

    case "$status" in
      downloading|starting)
        active=$(( active + 1 ))
        active_out="${active_out}  ${YELLOW}⬇${NC}  $(printf '%-34s' "$model") [${bar}] ${pct}%${size_str}  ${age_str}\n"
        ;;
      done)
        done_count=$(( done_count + 1 ))
        done_out="${done_out}  ${GREEN}✓${NC}  $(printf '%-34s' "$model")  done  ${age_str}\n"
        ;;
      error)
        error_count=$(( error_count + 1 ))
        local err_display="${errmsg:-unknown error}"
        error_out="${error_out}  ${RED}✗${NC}  $(printf '%-34s' "$model")  ${err_display}  ${age_str}\n"
        ;;
    esac
  done

  if [ "$active" -eq 0 ] && [ "$done_count" -eq 0 ] && [ "$error_count" -eq 0 ]; then
    echo -e "  ${CYAN}[InferHaven]${NC} No background downloads."
    echo "  Start one: haven pullback <model>"
    return 0
  fi

  echo ""
  if [ "$active" -gt 0 ]; then
    echo -e "  ${BOLD}Downloading${NC}"
    printf "%b" "${active_out}"
    echo ""
  fi
  if [ "$done_count" -gt 0 ]; then
    echo -e "  ${BOLD}Completed (removed after 60s)${NC}"
    printf "%b" "${done_out}"
    echo ""
  fi
  if [ "$error_count" -gt 0 ]; then
    echo -e "  ${BOLD}Failed${NC}"
    printf "%b" "${error_out}"
    echo "  Re-run: haven pullback <model>"
    echo ""
  fi
}

_pullback_cancel() {
  local model="${1:-}"
  if [ -z "$model" ]; then
    echo "Usage: haven pullback cancel <model>"
    exit 1
  fi
  local slug
  slug=$(_model_slug "$model")
  local sf="${HOME}/.haven/downloads/${slug}.status"

  if [ ! -f "$sf" ]; then
    echo -e "${YELLOW}[InferHaven]${NC} No active download found for: $model"
    return 0
  fi

  local pid
  pid=$(grep '^pid=' "$sf" 2>/dev/null | cut -d= -f2-)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    echo -e "${CYAN}[InferHaven]${NC} Cancelled download of $model (PID $pid)."
  else
    echo -e "${YELLOW}[InferHaven]${NC} Worker process not found — cleaning up."
  fi
  rm -f "$sf"
}

cmd_pullback() {
  local sub="${1:-}"
  case "$sub" in
    status|ls|list) _pullback_status ;;
    cancel)         shift; _pullback_cancel "${1:-}" ;;
    "")
      echo "Usage: haven pullback <model>"
      echo "       haven pullback status"
      echo "       haven pullback cancel <model>"
      exit 1
      ;;
    *)              _pullback_start "$1" ;;
  esac
}

cmd_remove() {
  if [ -z "${1:-}" ]; then
    echo "Usage: haven remove <model>"
    exit 1
  fi
  echo -e "${YELLOW}[InferHaven]${NC} Removing model: $1"
  local resp
  resp=$(curl -sf -X DELETE "${OLLAMA_URL}/api/delete" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"$1\"}" 2>/dev/null) || true
  echo -e "${GREEN}[InferHaven]${NC} Model $1 removed."
  _haven_sync_all || true
}

cmd_show() {
  local model="${1:-}"
  if [ -z "$model" ]; then
    echo "Usage: haven show <model> [--modelfile]"
    echo "  --modelfile   Print the raw Modelfile (useful after haven tune/params)"
    exit 1
  fi
  local resp
  resp=$(curl -sf "${OLLAMA_URL}/api/show" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${model}\"}" 2>/dev/null) || {
    echo "Error: Cannot reach Ollama or model '${model}' not found."
    exit 1
  }

  # --modelfile flag: print raw Modelfile and exit (debug-friendly)
  if [ "${2:-}" = "--modelfile" ]; then
    echo "${resp}" | jq -r '.modelfile // empty'
    return 0
  fi

  echo ""
  echo -e "  ${CYAN}${BOLD}${model}${NC}\n"

  # Details block
  echo "${resp}" | jq -r '
    .details |
    "  Family:        \(.family // "unknown")",
    "  Parameters:    \(.parameter_size // "unknown")",
    "  Quantization:  \(.quantization_level // "unknown")",
    "  Format:        \(.format // "unknown")"
  ' 2>/dev/null || true

  # Model info
  local size
  size=$(echo "${resp}" | jq -r '.model_info["general.parameter_count"] // empty' 2>/dev/null)
  [ -n "$size" ] && echo "  Parameter count: ${size}"

  # Current parameters (if any custom ones are set)
  local params
  params=$(echo "${resp}" | jq -r '.parameters // empty' 2>/dev/null)
  if [ -n "${params}" ]; then
    echo ""
    echo -e "  ${BOLD}Custom parameters:${NC}"
    echo "${params}" | awk '{print "    " $0}'
  fi

  # System prompt (if any)
  local system
  system=$(echo "${resp}" | jq -r '.system // empty' 2>/dev/null)
  if [ -n "${system}" ]; then
    echo ""
    echo -e "  ${BOLD}System prompt:${NC}"
    echo "${system}" | awk '{print "    " $0}'
  fi

  # License (first line only)
  local license
  license=$(echo "${resp}" | jq -r '.license // empty' 2>/dev/null | head -1)
  [ -n "${license}" ] && echo -e "\n  License: ${license}"

  echo ""
  echo "  Tip: haven show ${model} --modelfile   to inspect the full Modelfile"
  echo ""
}

cmd_harness() {
  echo ""
  echo -e "  ${CYAN}${BOLD}Coding assistant harnesses${NC}"
  echo ""

  # Print one row per harness: green tick if installed, yellow if installing,
  # red cross if not installed.
  local _in_progress="${HOME}/.haven/install-in-progress"
  _harness_row() {
    local label="$1" bin="$2"
    if command -v "${bin}" &>/dev/null; then
      local ver
      ver=$("${bin}" --version 2>/dev/null | head -1 || true)
      if [ -n "${ver}" ]; then
        echo -e "  ${GREEN}✓${NC} ${label} — ${ver}"
      else
        echo -e "  ${GREEN}✓${NC} ${label}"
      fi
    elif [ -f "${_in_progress}" ] && grep -qxF "${bin}" "${_in_progress}" 2>/dev/null; then
      echo -e "  ${YELLOW}◌${NC} ${label} (installing...)"
    else
      echo -e "  ${RED}✗${NC} ${label} (not installed)"
    fi
  }

  _harness_row "Claude Code" "claude"
  _harness_row "OpenCode"    "opencode"
  _harness_row "Aider"       "aider"
  _harness_row "Qwen Code"   "qwen"
  _harness_row "Amp"         "amp"
  _harness_row "Gemini CLI"  "gemini"
  _harness_row "Pi"          "pi"
  _harness_row "Goose"       "goose"
  _harness_row "Continue"    "cn"
  _harness_row "Avante"      "avante"

  echo ""

  # OpenCode config summary (most useful detail to surface)
  if command -v opencode &>/dev/null; then
    local oc_config
    oc_config=$(_opencode_config_path)
    if [ -f "${oc_config}" ]; then
      local model_count baseurl
      model_count=$(jq '.provider.ollama.models | length' "${oc_config}" 2>/dev/null || echo "?")
      baseurl=$(jq -r '.provider.ollama.options.baseURL // "not set"' "${oc_config}" 2>/dev/null || echo "not set")
      echo -e "  OpenCode config: ${oc_config}"
      echo -e "  Ollama endpoint: ${baseurl}"
      echo -e "  Local models:    ${model_count} configured"
      if [ "${model_count}" -gt 0 ] 2>/dev/null; then
        jq -r '.provider.ollama.models | to_entries[] | "    \(.key)  ctx:\(.value.limit.context // "?")"' \
          "${oc_config}" 2>/dev/null || true
      fi
    else
      echo -e "  OpenCode config: ${YELLOW}not found${NC} — pull a model to generate it automatically"
    fi
    echo ""
  fi

  # Pi config summary
  if command -v pi &>/dev/null; then
    local pi_models="${HOME}/.pi/agent/models.json"
    if [ -f "${pi_models}" ]; then
      local pi_count pi_baseurl
      pi_count=$(jq '.providers.ollama.models | length' "${pi_models}" 2>/dev/null || echo "?")
      pi_baseurl=$(jq -r '.providers.ollama.baseUrl // "not set"' "${pi_models}" 2>/dev/null || echo "not set")
      echo -e "  Pi config:       ${pi_models}"
      echo -e "  Ollama endpoint: ${pi_baseurl}"
      echo -e "  Local models:    ${pi_count} configured"
      if [ "${pi_count}" -gt 0 ] 2>/dev/null; then
        jq -r '.providers.ollama.models[] | "    \(.id)  ctx:\(.contextWindow // "?")"' \
          "${pi_models}" 2>/dev/null || true
      fi
    else
      echo -e "  Pi config:       ${YELLOW}not found${NC} — pull a model to generate it automatically"
    fi
    echo ""
  fi

  # Goose config summary
  if command -v goose &>/dev/null; then
    local goose_config="${HOME}/.config/goose/config.yaml"
    if [ -f "${goose_config}" ]; then
      local goose_model goose_host goose_ctx
      goose_model=$(grep -m1 '^GOOSE_MODEL:' "${goose_config}" 2>/dev/null | awk '{print $2}' || echo "not set")
      goose_host=$(grep -m1 '^OLLAMA_HOST:' "${goose_config}" 2>/dev/null | awk '{print $2}' || echo "not set")
      goose_ctx=$(grep -m1 '^export OLLAMA_CONTEXT_LENGTH=' "${HOME}/.inferhaven" 2>/dev/null \
        | sed 's/.*="\(.*\)"/\1/' || echo "?")
      echo -e "  Goose config:    ${goose_config}"
      echo -e "  Ollama endpoint: ${goose_host}"
      echo -e "  Active model:    ${goose_model}  ctx:${goose_ctx}"
      echo -e "  Switch model:    goose run --model <model> -t 'prompt'"
    else
      echo -e "  Goose config:    ${YELLOW}not found${NC} — pull a model to generate it automatically"
    fi
    echo ""
  fi

  # Avante config summary
  if command -v avante &>/dev/null; then
    local avante_sidecar="${HOME}/.config/nvim/lua/inferhaven-avante-config.lua"
    if [ -f "${avante_sidecar}" ]; then
      local avante_provider avante_model avante_endpoint
      avante_provider=$(grep -m1 'provider = ' "${avante_sidecar}" 2>/dev/null | sed 's/.*provider = "\([^"]*\)".*/\1/' || echo "?")
      avante_model=$(grep -m1 'model = ' "${avante_sidecar}" 2>/dev/null | sed 's/.*model = "\([^"]*\)".*/\1/' || echo "?")
      avante_endpoint=$(grep -m1 'endpoint = ' "${avante_sidecar}" 2>/dev/null | sed 's/.*endpoint = "\([^"]*\)".*/\1/' || echo "?")
      local avante_managed=""
      head -1 "${avante_sidecar}" | grep -qF -- "-- _haven: managed" && avante_managed=" (auto-sync on)"
      echo -e "  Avante config:   ${avante_sidecar}${avante_managed}"
      echo -e "  Provider:        ${avante_provider}"
      [ "${avante_provider}" = "ollama" ] && echo -e "  Ollama endpoint: ${avante_endpoint}"
      echo -e "  Active model:    ${avante_model}"
    else
      echo -e "  Avante config:   ${YELLOW}not found${NC} — pull a model to generate it automatically"
    fi
    echo ""
  fi

  # Continue config summary
  if command -v cn &>/dev/null; then
    local cont_config="${HOME}/.continue/config.yaml"
    if [ -f "${cont_config}" ]; then
      local cont_count cont_autocomplete
      cont_count=$(grep -c '^  - name:' "${cont_config}" 2>/dev/null || echo "?")
      cont_autocomplete=$(awk '/^  - name:/{name=$NF} /- autocomplete/{print name; exit}' "${cont_config}" 2>/dev/null || echo "not set")
      echo -e "  Continue config: ${cont_config}"
      echo -e "  Local models:    ${cont_count} configured"
      echo -e "  Autocomplete:    ${cont_autocomplete}"
    else
      echo -e "  Continue config: ${YELLOW}not found${NC} — pull a model to generate it automatically"
    fi
    echo ""
  fi
}

cmd_ps() {
  echo -e "\n  ${CYAN}Models loaded in memory:${NC}\n"
  local resp
  resp=$(curl -sf "${OLLAMA_URL}/api/ps" 2>/dev/null) || {
    echo "  Error: Cannot reach Ollama."
    exit 1
  }
  local count
  count=$(echo "${resp}" | jq '.models | length' 2>/dev/null || echo 0)
  if [ "${count}" -eq 0 ]; then
    echo "  No models currently loaded."
  else
    printf "  %-42s  %8s  %-22s  %8s  %s\n" "NAME" "SIZE" "PROCESSOR" "CTX" "UNTIL"
    printf "  %s\n" "$(printf '─%.0s' $(seq 1 102))"

    local name size_bytes size_gb gpu_pct cpu_pct processor
    local num_ctx expires_at exp_ts now_ts diff_s expires_str show_resp ctx_val

    while IFS= read -r line; do
      name=$(echo "$line"       | jq -r '.name')
      size_bytes=$(echo "$line" | jq -r '.size // 0')
      expires_at=$(echo "$line" | jq -r '.expires_at // ""')

      # Human-readable size
      size_gb=$(echo "$line" | jq -r '(.size / 1073741824 * 10 | round / 10 | tostring) + " GB"')

      # GPU / CPU processor split derived from size_vram vs total size
      if [ "${size_bytes}" -gt 0 ] 2>/dev/null; then
        gpu_pct=$(echo "$line" | jq -r '(.size_vram * 100 / .size | round | tostring)')
        cpu_pct=$(( 100 - gpu_pct ))
        if   [ "${gpu_pct}" -ge 100 ]; then processor="100% GPU"
        elif [ "${cpu_pct}" -ge 100 ]; then processor="100% CPU"
        else processor="${gpu_pct}% GPU / ${cpu_pct}% CPU"
        fi
      else
        processor="—"
      fi

      # Context window — fetch from /api/show; try parameters string then model_info
      num_ctx="?"
      show_resp=$(curl -sf --max-time 2 "${OLLAMA_URL}/api/show" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${name}\"}" 2>/dev/null)
      if [ -n "$show_resp" ]; then
        ctx_val=$(echo "$show_resp" | jq -r '.parameters // ""' 2>/dev/null \
          | grep -i '^num_ctx ' | awk '{print $2}' | head -1)
        if [ -z "$ctx_val" ]; then
          # Ollama ≥ 0.3 exposes structured model_info
          ctx_val=$(echo "$show_resp" | jq -r \
            '.model_info["llama.context_length"] // .model_info["context_length"] // empty' \
            2>/dev/null | head -1)
        fi
        [ -n "$ctx_val" ] && [ "$ctx_val" != "null" ] && num_ctx="$ctx_val"
      fi

      # Relative expiry time
      if [ -n "$expires_at" ] && [ "$expires_at" != "null" ]; then
        exp_ts=$(date -d "$expires_at" +%s 2>/dev/null || echo "")
        if [ -n "$exp_ts" ]; then
          now_ts=$(date +%s)
          diff_s=$(( exp_ts - now_ts ))
          if   [ "$diff_s" -le 0 ];    then expires_str="now"
          elif [ "$diff_s" -lt 60 ];   then expires_str="${diff_s}s"
          elif [ "$diff_s" -lt 3600 ]; then expires_str="$(( diff_s / 60 ))m"
          else expires_str="$(( diff_s / 3600 ))h $(( (diff_s % 3600) / 60 ))m"
          fi
        else
          expires_str="$expires_at"
        fi
      else
        expires_str="∞"
      fi

      printf "  %-42s  %8s  %-22s  %8s  in %s\n" \
        "$name" "$size_gb" "$processor" "$num_ctx" "$expires_str"

    done < <(echo "${resp}" | jq -c '.models[]')
  fi
  echo ""
}

cmd_unload() {
  local model="${1:-}"
  if [ -z "$model" ]; then
    local resp
    resp=$(curl -sf "${OLLAMA_URL}/api/ps" 2>/dev/null) || {
      echo "Error: Cannot reach Ollama."
      exit 1
    }
    local count
    count=$(echo "${resp}" | jq '.models | length' 2>/dev/null || echo 0)
    if [ "${count}" -eq 0 ]; then
      echo "No models currently loaded in memory."
      exit 0
    fi
    echo -e "${YELLOW}[InferHaven]${NC} The following models are currently loaded:\n"
    echo "${resp}" | jq -r '.models[].name' | while IFS= read -r m; do
      echo "  - ${m}"
    done
    echo ""
    printf "Unload all %d model(s)? [y/N] " "${count}"
    local answer
    read -r answer
    if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
      echo "Aborted."
      exit 0
    fi
    echo "${resp}" | jq -r '.models[].name' | while IFS= read -r m; do
      echo -e "${CYAN}[InferHaven]${NC} Unloading ${m}..."
      curl -sf "${OLLAMA_URL}/api/generate" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${m}\",\"keep_alive\":0}" > /dev/null 2>&1 || true
    done
    echo -e "${GREEN}[InferHaven]${NC} Done. All models unloaded."
    return
  fi
  echo -e "${CYAN}[InferHaven]${NC} Unloading ${model} from memory..."
  curl -sf "${OLLAMA_URL}/api/generate" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${model}\",\"keep_alive\":0}" > /dev/null 2>&1 || true
  echo -e "${GREEN}[InferHaven]${NC} Done. Model will reload fresh on next use."
}

cmd_cp() {
  if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    echo "Usage: haven cp <source> <destination>"
    echo "Example: haven cp qwen2.5-coder:7b my-custom-model"
    exit 1
  fi
  echo -e "${CYAN}[InferHaven]${NC} Copying $1 → $2..."
  curl -sf "${OLLAMA_URL}/api/copy" \
    -H "Content-Type: application/json" \
    -d "{\"source\": \"$1\", \"destination\": \"$2\"}" > /dev/null || {
    echo "Error: Copy failed. Check that '$1' exists (haven models)."
    exit 1
  }
  echo -e "${GREEN}[InferHaven]${NC} Done. '$2' is now available."
  _haven_sync_all || true
}

# ── Model parameters ──────────────────────────────────────────────────────────
# Reads and writes model parameters via Ollama's Modelfile system.
# Setting a parameter on an existing model recreates it in-place — weights
# are NOT re-downloaded, only the metadata changes. Instant operation.
#
# Usage:
#   haven params <model>                      — show current parameters
#   haven params <model> set <key> <value>    — set a parameter
#   haven params <model> reset                — remove all custom parameters
#
# Common parameters:
#   temperature <0.0–2.0>   Creativity. Lower = more focused/deterministic.
#   num_ctx <int>           Context window in tokens (e.g. 4096, 8192, 32768).
#   top_k <int>             Limits token candidates per step (default: 40).
#   top_p <0.0–1.0>         Nucleus sampling threshold (default: 0.9).
#   seed <int>              Fixed seed for reproducible output (0 = random).
#   num_predict <int>       Max tokens to generate. -1 = unlimited.
#   repeat_penalty <float>  Penalise repeated tokens (default: 1.1).
#   stop "<token>"          Add a stop sequence (can be set multiple times).
cmd_params() {
  local model="${1:-}"
  if [ -z "${model}" ]; then
    echo "Usage: haven params <model> [set <key> <value> | reset]"
    echo ""
    echo "  Common parameters:"
    echo "    temperature   0.0–2.0   Creativity (lower = more focused)"
    echo "    num_ctx       int       Context window size in tokens"
    echo "    top_k         int       Token candidates per step (default 40)"
    echo "    top_p         0.0–1.0   Nucleus sampling (default 0.9)"
    echo "    seed          int       Fixed seed for reproducibility (0=random)"
    echo "    num_predict   int       Max tokens to generate (-1=unlimited)"
    echo "    repeat_penalty  float   Penalise repeated tokens (default 1.1)"
    echo "    presence_penalty float  Penalise tokens already present (default 0)"
    echo "    top_p           0–1     Nucleus sampling — lower = more focused (default 0.9)"
    echo "    top_k           int     Token candidates per step — lower = less random (default 40)"
    echo "    num_predict     int     Max tokens per response. -1=unlimited (default 128)"
    exit 1
  fi
  shift
  local subcmd="${1:-list}"
  shift || true

  case "${subcmd}" in
    list|show|"")
      _params_list "${model}"
      ;;
    set)
      local key="${1:-}" value="${2:-}"
      if [ -z "${key}" ] || [ -z "${value}" ]; then
        echo "Usage: haven params ${model} set <key> <value>"
        echo "Example: haven params ${model} set temperature 0.3"
        exit 1
      fi
      _params_apply "${model}" "${key}" "${value}"
      ;;
    reset)
      _params_reset "${model}"
      ;;
    *)
      echo "Usage: haven params <model> [set <key> <value> | reset]"
      exit 1
      ;;
  esac
}

_params_fetch_modelfile() {
  # Fetch and return the raw Modelfile for a model. Exits with error if
  # the model doesn't exist or Ollama is unreachable.
  local model="$1"
  local resp
  resp=$(curl -sf "${OLLAMA_URL}/api/show" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${model}\"}" 2>/dev/null) || {
    echo "Error: Cannot reach Ollama or model '${model}' not found." >&2
    exit 1
  }
  echo "${resp}" | jq -r '.modelfile // empty'
}

_params_recreate() {
  # Apply a Modelfile to an existing Ollama model.
  #
  # Uses `docker exec ollama create` (the Ollama CLI) rather than the
  # /api/create REST endpoint. The REST endpoint returns empty responses
  # when recreating existing models on several Ollama versions, causing
  # silent failures that are impossible to distinguish from success.
  # The CLI always produces output and exits non-zero on error.
  local model="$1" modelfile="$2"

  if [ -z "${modelfile}" ]; then
    echo -e "${RED}[InferHaven]${NC} Internal error: empty modelfile — aborting." >&2
    return 1
  fi

  # Snapshot the pre-modification Modelfile before we overwrite it.
  # Idempotent — only the first backup wins, so the on-disk copy is always the
  # upstream original. Skipped by haven untune (sets _HAVEN_SKIP_BACKUP=1) so a
  # restore never overwrites the pristine snapshot with the just-restored copy.
  if [ "${_HAVEN_SKIP_BACKUP:-0}" != "1" ]; then
    _tune_backup_modelfile "${model}" || true
  fi

  # Strip read-only GGUF-metadata params that ollama create rejects (e.g.
  # rope_frequency_base). Ollama reports these in /api/show output but refuses
  # them when passed back via `ollama create` — they are internally computed.
  modelfile=$(printf '%s\n' "${modelfile}" | _tune_strip_unsupported_params || true)

  # Write the Modelfile into the Ollama container's /tmp.
  # Use a unique name to avoid collisions if multiple commands run in parallel.
  local tmpfile="/tmp/haven_mf_$$"
  if ! printf '%s\n' "${modelfile}" \
       | docker exec -i "$(_haven_container ollama)" sh -c "cat > '${tmpfile}'" 2>/dev/null; then
    echo -e "${RED}[InferHaven]${NC} Could not write Modelfile to Ollama container." >&2
    echo "  Is the Ollama container running?  haven status" >&2
    return 1
  fi

  # Run ollama create inside the container — this is the authoritative tool.
  local output exit_code=0
  output=$(docker exec "$(_haven_container ollama)" ollama create "${model}" -f "${tmpfile}" 2>&1) \
    || exit_code=$?
  docker exec "$(_haven_container ollama)" rm -f "${tmpfile}" 2>/dev/null || true

  if [ "${exit_code}" -ne 0 ]; then
    echo -e "${RED}[InferHaven]${NC} Ollama could not apply Modelfile:" >&2
    printf '%s\n' "${output}" | head -5 | sed 's/^/  /' >&2
    return 1
  fi

  # Evict from GPU/RAM immediately so next load picks up the new Modelfile.
  curl -s "${OLLAMA_URL}/api/generate" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${model}\",\"keep_alive\":0}" > /dev/null 2>&1 || true

  return 0
}

_params_list() {
  local model="$1"
  # The 'parameters' field from /api/show is a formatted string of
  # the model's current PARAMETER lines — cleaner than parsing the Modelfile.
  local resp
  resp=$(curl -sf "${OLLAMA_URL}/api/show" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${model}\"}" 2>/dev/null) || {
    echo "Error: Cannot reach Ollama or model '${model}' not found."
    exit 1
  }

  echo ""
  echo -e "  ${CYAN}${BOLD}${model}${NC} — parameters\n"

  local params
  params=$(echo "${resp}" | jq -r '.parameters // empty' 2>/dev/null)
  if [ -z "${params}" ]; then
    echo "  (no custom parameters — using Ollama defaults)"
    echo ""
    echo "  Set one with: haven params ${model} set <key> <value>"
  else
    echo "${params}" | awk '{print "  " $0}'
    echo ""
    echo "  Change:  haven params ${model} set <key> <value>"
    echo "  Reset:   haven params ${model} reset"
  fi
  echo ""
}

_params_apply() {
  local model="$1" key="$2" value="$3"

  # Use the full Modelfile — only strip the specific PARAMETER line being replaced,
  # then append the new value. This preserves TEMPLATE, SYSTEM, and all other
  # Modelfile directives that the model creator embedded (e.g. custom tool-call
  # templates). A "minimal" Modelfile (FROM + PARAMETER only) would silently drop
  # the TEMPLATE block, which breaks tool use on any model with a custom template.
  local show_resp
  show_resp=$(curl -sf "${OLLAMA_URL}/api/show" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${model}\"}" 2>/dev/null) || {
    echo -e "${RED}[InferHaven]${NC} Cannot reach Ollama or model '${model}' not found." >&2
    return 1
  }

  local full_modelfile
  full_modelfile=$(printf '%s' "${show_resp}" | jq -r '.modelfile // ""')
  if [ -z "${full_modelfile}" ]; then
    echo -e "${RED}[InferHaven]${NC} Could not fetch Modelfile for model '${model}'." >&2
    return 1
  fi

  # Remove any existing line for this PARAMETER key, then append the new value.
  local updated
  updated=$(printf '%s\n' "${full_modelfile}" | grep -iv "^PARAMETER ${key} " || true)
  updated="${updated}"$'\n'"PARAMETER ${key} ${value}"

  echo -e "${CYAN}[InferHaven]${NC} Applying ${key}=${value} to ${model}..."
  if _params_recreate "${model}" "${updated}"; then
    echo -e "${GREEN}[InferHaven]${NC} Done. Model unloaded — new parameters active on next chat."
    _haven_sync_all 2>/dev/null || true
  fi
}

_params_reset() {
  local model="$1"

  # Strip all PARAMETER lines from the full Modelfile, preserving TEMPLATE,
  # SYSTEM, and all other directives — Ollama uses its built-in defaults for
  # any parameter not explicitly set.
  local show_resp
  show_resp=$(curl -sf "${OLLAMA_URL}/api/show" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${model}\"}" 2>/dev/null) || {
    echo -e "${RED}[InferHaven]${NC} Cannot reach Ollama or model '${model}' not found." >&2
    return 1
  }

  local full_modelfile
  full_modelfile=$(printf '%s' "${show_resp}" | jq -r '.modelfile // ""')
  if [ -z "${full_modelfile}" ]; then
    echo -e "${RED}[InferHaven]${NC} Could not fetch Modelfile for model '${model}'." >&2
    return 1
  fi

  local stripped
  stripped=$(printf '%s\n' "${full_modelfile}" | grep -iv "^PARAMETER " || true)

  echo -e "${YELLOW}[InferHaven]${NC} Resetting parameters for ${model}..."
  if _params_recreate "${model}" "${stripped}"; then
    echo -e "${GREEN}[InferHaven]${NC} All custom parameters removed. Model unloaded — Ollama defaults active on next chat."
    _haven_sync_all 2>/dev/null || true
  fi
}

# ── Tune (Modelfile provisioning for tool-call reliability) ───────────────────
# _tune_detect_family / _tune_normalize_model_name / _tune_backup_modelfile
# live in lib/haven-tune-detect.sh (sourced above).

# Strip TEMPLATE """...""" block(s) from a Modelfile on stdin.
# Handles both single-line (TEMPLATE """...""") and multi-line forms.
_tune_strip_template() {
  awk '
    /^[Tt][Ee][Mm][Pp][Ll][Aa][Tt][Ee][[:space:]]+"""/ {
      rest = substr($0, index($0, "\"\"\"") + 3)
      if (index(rest, "\"\"\"") > 0) { next }   # single-line — skip
      in_tmpl = 1; next
    }
    in_tmpl && /"""/ { in_tmpl = 0; next }
    in_tmpl { next }
    { print }
  '
}

# Strip PARAMETER stop lines from a Modelfile on stdin.
_tune_strip_stops() {
  grep -iv "^PARAMETER stop "
}

# Strip PARAMETER lines that Ollama injects from GGUF metadata but rejects when
# passed back via `ollama create`. These appear in /api/show output but are NOT
# valid user-settable Modelfile keys — they are internally computed by Ollama.
_tune_strip_unsupported_params() {
  grep -iv "^PARAMETER rope_frequency_base " \
  | grep -iv "^PARAMETER rope_frequency_scale "
}

# Report server-level memory optimisations (flash attention, KV cache quantisation).
# These are Ollama environment variables — not Modelfile parameters — so they apply
# globally to all models on this server. Called from cmd_tune after a successful tune.
_tune_server_opts_report() {
  local fa kv_type
  fa=$(docker exec "$(_haven_container ollama)" sh -c 'printf "%s" "${OLLAMA_FLASH_ATTENTION:-0}"' 2>/dev/null) || fa="?"
  kv_type=$(docker exec "$(_haven_container ollama)" sh -c 'printf "%s" "${OLLAMA_KV_CACHE_TYPE:-f16}"' 2>/dev/null) || kv_type="?"

  local fa_str kv_str
  if [ "${fa}" = "1" ]; then
    fa_str="${GREEN}on${NC}"
  else
    fa_str="${YELLOW}off${NC} — set OLLAMA_FLASH_ATTENTION=1 in .env to enable"
  fi

  case "${kv_type}" in
    q4_0) kv_str="${GREEN}q4_0${NC} (~75% less KV-cache VRAM)" ;;
    q8_0) kv_str="${GREEN}q8_0${NC} (~50% less KV-cache VRAM)" ;;
    f16)  kv_str="${YELLOW}f16${NC} (full precision) — set OLLAMA_KV_CACHE_TYPE=q8_0 in .env to save VRAM" ;;
    "?")  kv_str="unknown" ;;
    *)    kv_str="${kv_type}" ;;
  esac

  echo -e "  Flash attention: ${fa_str}"
  echo -e "  KV cache quant:  ${kv_str}"
}

# ── Per-family templates ──────────────────────────────────────────────────────
# Each function prints the raw Go-template text (no surrounding TEMPLATE """).

_tmpl_qwen25() {
  cat <<'TMPL'
{{- if .Messages }}
{{- if or .System .Tools }}<|im_start|>system
{{- if .System }}
{{ .System }}
{{- end }}
{{- if .Tools }}

You have access to the following tools. To use a tool, output a JSON object inside <tool_call></tool_call> tags with no other text:
<tools>
{{- range .Tools }}
{"type": "function", "function": {{ .Function }}}
{{- end }}
</tools>
{{- end }}<|im_end|>
{{ end }}
{{- range .Messages }}
{{- if eq .Role "user" }}<|im_start|>user
{{ .Content }}<|im_end|>
{{ end }}
{{- if eq .Role "assistant" }}<|im_start|>assistant
{{- if .ToolCalls }}
{{- range .ToolCalls }}<tool_call>
{"name": "{{ .Function.Name }}", "arguments": {{ .Function.Arguments }}}
</tool_call>
{{- end }}
{{- else }}
{{ .Content }}
{{- end }}<|im_end|>
{{ end }}
{{- if eq .Role "tool" }}<|im_start|>tool
{{ .Content }}<|im_end|>
{{ end }}
{{- end }}
{{- else }}
{{- if .System }}<|im_start|>system
{{ .System }}<|im_end|>
{{ end }}
{{- if .Prompt }}<|im_start|>user
{{ .Prompt }}<|im_end|>
{{ end }}
{{- end }}
<|im_start|>assistant
TMPL
}

_tmpl_qwen3() {
  # Qwen3 uses different special tokens from Qwen2.5 for tool use:
  #   Input:  <|tools_start|>...<|tools_end|> in the system turn
  #   Output: <|tool_call_start|>...<|tool_call_end|>
  # The empty <think></think> prefix suppresses chain-of-thought by default,
  # keeping responses direct for coding assistant use cases.
  cat <<'TMPL'
{{- if .Messages }}
{{- if or .System .Tools }}<|im_start|>system
{{- if .System }}
{{ .System }}
{{- end }}
{{- if .Tools }}
<|tools_start|>
{{- range .Tools }}
{"type": "function", "function": {{ .Function }}}
{{- end }}
<|tools_end|>
{{- end }}<|im_end|>
{{ end }}
{{- range .Messages }}
{{- if eq .Role "user" }}<|im_start|>user
{{ .Content }}<|im_end|>
{{ end }}
{{- if eq .Role "assistant" }}<|im_start|>assistant
{{- if .ToolCalls }}
{{- range .ToolCalls }}<|tool_call_start|>{"name": "{{ .Function.Name }}", "arguments": {{ .Function.Arguments }}}<|tool_call_end|>
{{- end }}
{{- else }}
{{ .Content }}
{{- end }}<|im_end|>
{{ end }}
{{- if eq .Role "tool" }}<|im_start|>tool
{{ .Content }}<|im_end|>
{{ end }}
{{- end }}
{{- else }}
{{- if .System }}<|im_start|>system
{{ .System }}<|im_end|>
{{ end }}
{{- if .Prompt }}<|im_start|>user
{{ .Prompt }}<|im_end|>
{{ end }}
{{- end }}
<|im_start|>assistant
<think>

</think>
TMPL
}

_tmpl_llama3() {
  cat <<'TMPL'
{{- if .Messages }}
<|begin_of_text|>
{{- if or .System .Tools }}<|start_header_id|>system<|end_header_id|>
{{- if .System }}
{{ .System }}
{{- end }}
{{- if .Tools }}

You have access to the following tools. To use a tool, output a JSON object inside <tool_call></tool_call> tags with no other text:
<tools>
{{- range .Tools }}
{"type": "function", "function": {{ .Function }}}
{{- end }}
</tools>
{{- end }}
<|eot_id|>
{{- end }}
{{- range .Messages }}
{{- if eq .Role "user" }}<|start_header_id|>user<|end_header_id|>
{{ .Content }}<|eot_id|>
{{- end }}
{{- if eq .Role "assistant" }}<|start_header_id|>assistant<|end_header_id|>
{{- if .ToolCalls }}
{{- range .ToolCalls }}<tool_call>
{"name": "{{ .Function.Name }}", "arguments": {{ .Function.Arguments }}}
</tool_call>
{{- end }}
{{- else }}
{{ .Content }}
{{- end }}<|eot_id|>
{{- end }}
{{- if eq .Role "tool" }}<|start_header_id|>tool<|end_header_id|>
{{ .Content }}<|eot_id|>
{{- end }}
{{- end }}
{{- else }}
<|begin_of_text|>
{{- if .System }}<|start_header_id|>system<|end_header_id|>
{{ .System }}<|eot_id|>
{{- end }}
{{- if .Prompt }}<|start_header_id|>user<|end_header_id|>
{{ .Prompt }}<|eot_id|>
{{- end }}
{{- end }}
<|start_header_id|>assistant<|end_header_id|>
TMPL
}

_tmpl_deepseek() {
  # DeepSeek-Coder-V2 / DeepSeek-R1 format.
  # Special triangle tokens are literal UTF-8 in the model vocab.
  cat <<'TMPL'
{{- if .Messages }}
{{- if or .System .Tools }}<|begin▁of▁sentence|>
{{- if .System }}{{ .System }}

{{ end }}
{{- if .Tools }}You have access to the following tools. To use a tool, output a JSON object inside <tool_call></tool_call> tags with no other text:
<tools>
{{- range .Tools }}
{"type": "function", "function": {{ .Function }}}
{{- end }}
</tools>

{{ end }}
{{- end }}
{{- range .Messages }}
{{- if eq .Role "user" }}<|User|>{{ .Content }}<|Assistant|>{{- end }}
{{- if eq .Role "assistant" }}
{{- if .ToolCalls }}{{- range .ToolCalls }}<tool_call>
{"name": "{{ .Function.Name }}", "arguments": {{ .Function.Arguments }}}
</tool_call>
{{- end }}{{- else }}{{ .Content }}{{- end }}<|end▁of▁sentence|>
{{- end }}
{{- if eq .Role "tool" }}<|User|>Tool result: {{ .Content }}<|Assistant|>{{- end }}
{{- end }}
{{- else }}
{{- if .System }}<|begin▁of▁sentence|>{{ .System }}

{{ end }}
{{- if .Prompt }}<|User|>{{ .Prompt }}<|Assistant|>{{- end }}
{{- end }}
TMPL
}

_tmpl_mistral() {
  # NOTE: .Tools must be accessed at root level, NOT inside {{range .Messages}}.
  # Inside the range, . is a per-message struct that has no .Tools field, which
  # causes: "can't evaluate field Tools in type *template.templateMessage"
  cat <<'TMPL'
{{- if .Messages }}
{{- if or .System .Tools }}[INST]
{{- if .System }}{{ .System }}
{{ end -}}
{{- if .Tools }}
You have access to the following tools. To use a tool, output a JSON object inside <tool_call></tool_call> tags with no other text:
<tools>
{{- range .Tools }}
{"type": "function", "function": {{ .Function }}}
{{- end }}
</tools>
{{ end }} [/INST]
{{ end }}
{{- range .Messages }}
{{- if eq .Role "system" }}[INST] {{ .Content }} [/INST]
{{ end }}
{{- if eq .Role "user" }}[INST] {{ .Content }} [/INST]
{{- end }}
{{- if eq .Role "assistant" }}
{{- if .ToolCalls }}{{- range .ToolCalls }}<tool_call>
{"name": "{{ .Function.Name }}", "arguments": {{ .Function.Arguments }}}
</tool_call>
{{- end }}{{- else }} {{ .Content }}{{- end }}</s>
{{ end }}
{{- if eq .Role "tool" }}[INST] Tool result: {{ .Content }} [/INST]
{{ end }}
{{- end }}
{{- else }}
{{- if .System }}[INST] {{ .System }}
{{ end }}
{{- if .Prompt }}[INST] {{ .Prompt }} [/INST]{{- end }}
{{- end }}
TMPL
}

_tmpl_phi4() {
  # NOTE: .Tools must be accessed at root level, NOT inside {{range .Messages}}.
  # System+tools are emitted in a pre-loop block; the range handles user/assistant/tool only.
  cat <<'TMPL'
{{- if .Messages }}
{{- if or .System .Tools }}<|system|>
{{- if .System }}
{{ .System }}
{{- end -}}
{{- if .Tools }}

You have access to the following tools. To use a tool, output a JSON object inside <tool_call></tool_call> tags with no other text:
<tools>
{{- range .Tools }}
{"type": "function", "function": {{ .Function }}}
{{- end }}
</tools>
{{- end }}<|end|>
{{ end }}
{{- range .Messages }}
{{- if eq .Role "system" }}<|system|>
{{ .Content }}<|end|>
{{ end }}
{{- if eq .Role "user" }}<|user|>
{{ .Content }}<|end|>
{{ end }}
{{- if eq .Role "assistant" }}<|assistant|>
{{- if .ToolCalls }}{{- range .ToolCalls }}<tool_call>
{"name": "{{ .Function.Name }}", "arguments": {{ .Function.Arguments }}}
</tool_call>
{{- end }}{{- else }}{{ .Content }}{{- end }}<|end|>
{{ end }}
{{- if eq .Role "tool" }}<|user|>
Tool result: {{ .Content }}<|end|>
{{ end }}
{{- end }}
{{- else }}
{{- if .System }}<|system|>
{{ .System }}<|end|>
{{ end }}
{{- if .Prompt }}<|user|>
{{ .Prompt }}<|end|>
{{ end }}
{{- end }}
<|assistant|>
TMPL
}

_tmpl_codellama() {
  # NOTE: .Tools must be accessed at root level, NOT inside {{range .Messages}}.
  # System+tools are emitted in a pre-loop block; the range handles user/assistant/tool only.
  cat <<'TMPL'
{{- if .Messages }}
{{- if or .System .Tools }}[INST] <<SYS>>
{{- if .System }}
{{ .System }}
{{- end -}}
{{- if .Tools }}

You have access to the following tools. To use a tool, output a JSON object inside <tool_call></tool_call> tags with no other text:
<tools>
{{- range .Tools }}
{"type": "function", "function": {{ .Function }}}
{{- end }}
</tools>
{{- end }}
<</SYS>>

{{ end }}
{{- range .Messages }}
{{- if eq .Role "system" }}[INST] <<SYS>>
{{ .Content }}
<</SYS>>

{{ end }}
{{- if eq .Role "user" }}[INST] {{ .Content }} [/INST]{{- end }}
{{- if eq .Role "assistant" }}
{{- if .ToolCalls }}{{- range .ToolCalls }}<tool_call>
{"name": "{{ .Function.Name }}", "arguments": {{ .Function.Arguments }}}
</tool_call>
{{- end }}{{- else }} {{ .Content }}{{- end }}</s>
{{ end }}
{{- if eq .Role "tool" }}[INST] Tool result: {{ .Content }} [/INST]
{{ end }}
{{- end }}
{{- else }}
{{- if .System }}[INST] <<SYS>>
{{ .System }}
<</SYS>>

{{ end }}
{{- if .Prompt }}[INST] {{ .Prompt }} [/INST]{{- end }}
{{- end }}
TMPL
}

# Output stop tokens for a given family (one per line).
_tune_get_stops() {
  case "$1" in
    qwen25)    echo '<|im_end|>'; echo '<|endoftext|>' ;;
    qwen3)     echo '<|im_end|>'; echo '<|endoftext|>'; echo '<|tool_call_end|>' ;;
    llama3)    echo '<|eot_id|>'; echo '<|end_of_text|>' ;;
    deepseek)  echo '<|end▁of▁sentence|>' ;;
    mistral)   echo '</s>' ;;
    phi4)      echo '<|end|>'; echo '<|endoftext|>' ;;
    codellama) echo '</s>' ;;
    gemma)     echo '<end_of_turn>' ;;
    # generic: returns nothing — model's embedded stop tokens are preserved as-is
  esac
}

cmd_tune() {
  # Parse flags. --dry-run / -n prints the diff of Modelfile changes without
  # applying them. Anything else is collected as positional args.
  local dry_run=0
  local args=()
  for a in "$@"; do
    case "$a" in
      --dry-run|-n) dry_run=1 ;;
      *)            args+=("$a") ;;
    esac
  done
  set -- "${args[@]}"

  local model="${1:-}"
  if [ -z "$model" ]; then
    echo ""
    echo "  Usage: haven tune [--dry-run] <model>"
    echo "         haven untune <model>            (restore from pre-tune backup)"
    echo ""
    echo "  Provisions an optimised Modelfile for tool-call reliability."
    echo "  Base weights are not re-downloaded — only the Modelfile changes."
    echo "  --dry-run / -n   Print the diff of changes without applying."
    echo ""
    echo "  Safe-by-default. Only known-tested model versions get a full template + stop"
    echo "  rewrite. Anything else is treated as 'generic': only num_ctx is written;"
    echo "  TEMPLATE, SYSTEM, and all other PARAMETER lines are preserved verbatim."
    echo ""
    echo "  Tested families (full tune applied):"
    echo "    qwen2.5, qwen2.5-coder       (embedded Jinja template preserved + stops + ctx)"
    echo "    qwen3, qwen3-coder           (no-think template injected + stops + ctx)"
    echo "    llama3, llama3.{1,2,3}       (Llama3 header tokens + stops + ctx)"
    echo "    deepseek-{r1,coder,v2,v3}    (DeepSeek triangle tokens + stops + ctx)"
    echo "    mistral, mistral-{nemo,small,large}  ([INST]/[/INST] + stops + ctx)"
    echo "    phi4, phi-4                  (Phi-4 <|end|> tokens + stops + ctx)"
    echo "    codellama                    (Llama2 <<SYS>>/[INST] + ctx)"
    echo "    gemma2, gemma3               (embedded Jinja template preserved + stops + ctx)"
    echo ""
    echo "  Everything else (gemma1/4, qwen3.5/3.6, llama2/4, phi3, mixtral, devstral,"
    echo "  custom finetunes, hf.co/* paths) -> generic: only num_ctx is set."
    echo ""
    echo "  Override detection: HAVEN_FORCE_FAMILY=<family> haven tune <model>"
    echo "                      Valid values: qwen3 qwen25 llama3 deepseek mistral phi4 codellama gemma"
    echo ""
    echo "  Server-side memory knobs (set via .env, reported by haven tune):"
    echo "    OLLAMA_FLASH_ATTENTION=1   (faster; disable on AMD/Vulkan + Gemma3 — see haven doctor)"
    echo "    OLLAMA_KV_CACHE_TYPE=q8_0  (saves VRAM; f16 is the safest default on AMD/Vulkan)"
    echo ""
    echo "  Examples:"
    echo "    haven tune qwen2.5-coder:7b"
    echo "    haven tune qwen3-coder:30b"
    echo "    haven tune llama3.1:8b"
    echo "    haven tune --dry-run qwen3:8b"
    echo "    HAVEN_FORCE_FAMILY=qwen3 haven tune my-custom-qwen3-finetune:7b"
    echo "    haven untune <model>             # restore pre-tune Modelfile"
    echo ""
    exit 0
  fi

  local family
  family=$(_tune_detect_family "$model")

  echo -e "${CYAN}[InferHaven]${NC} Tuning ${model} (family: ${family})..."
  if [ -n "${HAVEN_FORCE_FAMILY:-}" ]; then
    echo -e "  ${YELLOW}HAVEN_FORCE_FAMILY${NC} active — forced family: ${family}."
  elif [ "$family" = "generic" ]; then
    echo -e "  ${YELLOW}Note:${NC} '${model}' did not match a tested family — safe defaults only (context window)."
    echo    "        TEMPLATE, SYSTEM, and all other PARAMETER lines preserved verbatim."
    echo    "        Override with: HAVEN_FORCE_FAMILY=<qwen3|qwen25|llama3|deepseek|mistral|phi4|codellama|gemma> haven tune ${model}"
  fi

  # Fetch the current Modelfile + model metadata in one request
  local show_resp
  show_resp=$(curl -sf "${OLLAMA_URL}/api/show" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${model}\"}" 2>/dev/null)

  local modelfile
  modelfile=$(printf '%s' "${show_resp}" | jq -r '.modelfile // empty')

  if [ -z "$modelfile" ]; then
    echo -e "${RED}[InferHaven]${NC} Could not fetch Modelfile for '${model}'."
    echo "  Is the model pulled? Run: haven pull ${model}"
    exit 1
  fi

  # Query the model's native max context window from GGUF metadata.
  # Keys follow the pattern <architecture>.context_length (e.g. gemma3.context_length).
  # Use this as an upper bound so we never set num_ctx higher than the model supports.
  local model_max_ctx
  model_max_ctx=$(printf '%s' "${show_resp}" | jq -r '
    (.model_info // {}) | to_entries[]
    | select(.key | endswith(".context_length"))
    | .value
  ' 2>/dev/null | head -1)

  # ── Template strategy ────────────────────────────────────────────────────────
  # PRINCIPLE: Tuning must never degrade a model's existing capabilities.
  # Templates must access .Tools at root level only — never inside {{range .Messages}}
  # (inside range, . is a per-message struct with no .Tools field, causing a crash).
  #
  # Template replacement strategy per family:
  #   qwen25   — DO NOT inject a custom template. All qwen2.5 models ship an embedded
  #              Jinja template Ollama uses for tool-call detection. Replacing it causes
  #              silent output (instruct) or blank tool calls (coder). Preserve embedded.
  #   gemma    — DO NOT inject. Gemma models ship a high-quality embedded Jinja template.
  #   generic  — DO NOT inject. Unknown models: preserve everything, only update ctx.
  #   qwen3    — Inject template to suppress thinking mode (<think></think> prefix).
  #   others   — Inject family-specific template for correct stop tokens and format.
  local replace_template
  case "$family" in
    qwen25|gemma|generic) replace_template=0 ;;
    *)                    replace_template=1 ;;
  esac

  # ── Strip and rebuild Modelfile ───────────────────────────────────────────────
  # Generic family: preserve existing stop tokens and template entirely — only
  # strip num_ctx so we can update it. Named families: strip stops (re-add correct
  # ones) and optionally strip template (re-inject family-specific one).
  local stripped
  if [ "$family" = "generic" ]; then
    stripped=$(printf '%s\n' "${modelfile}" | grep -iv "^PARAMETER num_ctx " || true)
  else
    # Strip stop PARAMETERs (we'll re-add correct ones for this family).
    stripped=$(printf '%s\n' "${modelfile}" | _tune_strip_stops || true)
    if [ "$replace_template" -eq 1 ]; then
      stripped=$(printf '%s\n' "${stripped}" | _tune_strip_template || true)
    fi
  fi

  # ── Context window ────────────────────────────────────────────────────────────
  # Target: HAVEN_CTX (default 32768), capped at the model's native GGUF max so
  # we never allocate more KV-cache than the model's weights actually support.
  # Always sets to target_ctx even if the existing value is larger — models that
  # ship with 128k default context exhaust VRAM on constrained hardware (12 GB),
  # causing mid-stream GPU stalls and 30 s timeout errors in Goose and other tools.
  local target_ctx
  target_ctx="${HAVEN_CTX:-32768}"

  # Cap at model's native max if the GGUF reports one
  if [ -n "${model_max_ctx}" ] && [ "${model_max_ctx}" -gt 0 ] 2>/dev/null; then
    if [ "${target_ctx}" -gt "${model_max_ctx}" ]; then
      target_ctx="${model_max_ctx}"
    fi
  fi

  # Read existing ctx from the original modelfile (before any stripping) so the
  # "was: X" message is always accurate regardless of family-specific strip order.
  local existing_ctx ctx_changed=0
  existing_ctx=$(printf '%s\n' "${modelfile}" \
    | grep -i "^PARAMETER num_ctx " | awk '{print $3}' | head -1 || true)
  # Always write target_ctx — including when existing > target (e.g. 128k → 32k).
  stripped=$(printf '%s\n' "${stripped}" | grep -iv "^PARAMETER num_ctx " || true)
  stripped="${stripped}"$'\n'"PARAMETER num_ctx ${target_ctx}"
  [ "${existing_ctx:-0}" != "${target_ctx}" ] && ctx_changed=1

  # ── Assemble the new Modelfile ─────────────────────────────────────────────────
  local new_modelfile
  if [ "$replace_template" -eq 1 ]; then
    local template
    case "$family" in
      qwen25)    template=$(_tmpl_qwen25) ;;
      qwen3)     template=$(_tmpl_qwen3) ;;
      llama3)    template=$(_tmpl_llama3) ;;
      deepseek)  template=$(_tmpl_deepseek) ;;
      mistral)   template=$(_tmpl_mistral) ;;
      phi4)      template=$(_tmpl_phi4) ;;
      codellama) template=$(_tmpl_codellama) ;;
    esac
    new_modelfile="${stripped}"$'\n'
    new_modelfile+=$'TEMPLATE """\n'
    new_modelfile+="${template}"$'\n'
    new_modelfile+=$'"""\n'
  else
    new_modelfile="${stripped}"$'\n'
  fi

  # Append correct stop tokens for named families.
  # Generic family skips this — its existing stop tokens were preserved above.
  if [ "$family" != "generic" ]; then
    while IFS= read -r stop; do
      [ -n "$stop" ] && new_modelfile+="PARAMETER stop \"${stop}\""$'\n'
    done < <(_tune_get_stops "$family")
  fi

  if [ "$dry_run" -eq 1 ]; then
    echo ""
    echo -e "  ${CYAN}--- DRY RUN: diff of Modelfile changes ---${NC}"
    diff -u \
      <(printf '%s\n' "${modelfile}") \
      <(printf '%s\n' "${new_modelfile}") \
      | sed 's/^/    /' || true
    echo ""
    echo "  Dry-run: no changes applied. Re-run without --dry-run to apply."
    return 0
  fi

  echo "  Uploading tuned Modelfile..."
  if _params_recreate "${model}" "${new_modelfile}"; then
    if [ "$family" = "generic" ]; then
      echo -e "${GREEN}[InferHaven]${NC} '${model}' context window optimised. Model unloaded — active on next chat."
    else
      echo -e "${GREEN}[InferHaven]${NC} '${model}' tuned for coding assistant use. Model unloaded — active on next chat."
    fi
    if [ "$ctx_changed" -eq 1 ]; then
      echo "  Context window: set to ${target_ctx} tokens (was: ${existing_ctx:-unset})"
    else
      echo "  Context window: ${target_ctx} tokens (unchanged)"
    fi
    # Per-family notes about template and tool calling behaviour.
    case "$family" in
      qwen3)
        echo "  Template: no-think mode active — empty <think></think> prefix suppresses chain-of-thought."
        ;;
      qwen25)
        echo "  Template: embedded (preserved) — tool calling reliability varies by harness and Ollama version."
        ;;
      codellama)
        echo "  Template: applied for response formatting. Note: codellama does not support tool calling (Ollama API limitation)."
        ;;
      generic)
        echo "  Template and stop tokens: preserved from model defaults (unknown family)."
        ;;
    esac
    # Report server-level memory optimisations (flash attention, KV cache quant).
    _tune_server_opts_report || true
    # Keep coding assistant configs in sync with the updated model.
  _haven_sync_all || true
  fi
}

# ── Untune ────────────────────────────────────────────────────────────────────
# Restore a model's Modelfile from the pre-tune backup snapshot taken on the
# first haven tune / params set / params reset. The backup lives at
# ~/.haven/modelfile-backups/<slug>.modelfile in the workspace_home volume.
cmd_untune() {
  local model="${1:-}"
  if [ -z "$model" ]; then
    echo ""
    echo "  Usage: haven untune <model>"
    echo ""
    echo "  Restores the Modelfile to the snapshot taken before the first"
    echo "  haven tune / params set / params reset modification."
    echo ""
    echo "  Backup location: ~/.haven/modelfile-backups/<slug>.modelfile"
    echo ""
    exit 0
  fi
  local slug backup
  slug=$(_model_slug "${model}")
  backup="${HOME}/.haven/modelfile-backups/${slug}.modelfile"
  if [ ! -f "${backup}" ]; then
    echo -e "${YELLOW}[InferHaven]${NC} No backup found for '${model}'."
    echo "  (Backups are taken on the first tune / params modification — this model has not been modified by haven.)"
    exit 1
  fi
  echo -e "${CYAN}[InferHaven]${NC} Restoring '${model}' Modelfile from backup..."
  local mf
  mf=$(cat "${backup}")
  # Skip the backup hook in _params_recreate so we don't overwrite the pristine
  # snapshot with the just-restored copy.
  if _HAVEN_SKIP_BACKUP=1 _params_recreate "${model}" "${mf}"; then
    echo -e "${GREEN}[InferHaven]${NC} '${model}' restored. Model unloaded — original parameters active on next chat."
    echo "  Backup retained at: ${backup}"
    _haven_sync_all 2>/dev/null || true
  fi
}

cmd_chat() {
  local model="${1:-${DEFAULT_MODEL:-qwen2.5-coder:7b}}"
  echo -e "${CYAN}[InferHaven]${NC} Chatting with ${model} (Ctrl+D or /bye to exit)..."
  echo ""
  docker exec -it "$(_haven_container ollama)" ollama run "${model}"
}

# ── haven run — direct ollama run wrapper (interactive or one-shot) ───────────
# Mirrors `ollama run` exactly. When called with only a model name, drops into
# an interactive session. When called with a prompt argument, runs non-
# interactively and exits — useful for scripting and quick one-liners.
#
# Examples:
#   haven run qwen3-coder:30b
#   haven run qwen3-coder:30b "Explain tail call optimisation in three sentences"
#   echo "What is 2+2?" | haven run qwen3-coder:30b
cmd_run() {
  if [ -z "${1:-}" ]; then
    echo ""
    echo -e "  ${RED}✗${NC} Usage: haven run <model> [prompt]"
    echo ""
    exit 1
  fi
  local model="$1"; shift
  if [ -t 0 ] && [ $# -eq 0 ]; then
    # Interactive — allocate a TTY so the readline UI works
    docker exec -it "$(_haven_container ollama)" ollama run "${model}"
  else
    # One-shot: collect prompt from args or stdin, then stream via REST API.
    # `ollama run model "prompt"` hangs when stdin is a pipe through docker exec
    # because it never receives EOF. The /api/chat endpoint is reliable for this.
    local prompt
    if [ $# -gt 0 ]; then
      prompt="$*"
    else
      prompt=$(cat)
    fi
    curl -sN "${OLLAMA_URL}/api/chat" \
      -H 'Content-Type: application/json' \
      -d "$(jq -cn --arg m "${model}" --arg p "${prompt}" \
            '{model:$m,messages:[{role:"user",content:$p}],stream:true}')" \
    | while IFS= read -r line; do
        printf '%s' "$(printf '%s' "${line}" | jq -r '.message.content // empty' 2>/dev/null)"
      done
    printf '\n'
  fi
}

# ── haven push — push a model to ollama.com ───────────────────────────────────
cmd_push() {
  if [ -z "${1:-}" ]; then
    echo ""
    echo -e "  ${RED}✗${NC} Usage: haven push <model>"
    echo "         Model must be in your ollama.com namespace, e.g. myuser/mymodel:tag"
    echo ""
    exit 1
  fi
  docker exec -it "$(_haven_container ollama)" ollama push "$@"
}

# ── haven signin / signout — ollama.com authentication ───────────────────────
cmd_signin() {
  docker exec -it "$(_haven_container ollama)" ollama login "$@"
}

cmd_signout() {
  docker exec -it "$(_haven_container ollama)" ollama logout "$@"
}

# ── haven claude — Claude Code with local Ollama models ──────────────────────
# Launches Claude Code pointed at the container-internal Ollama endpoint.
# Model selection:
#   0 models  → error with a helpful hint
#   1 model   → launches directly, no prompt
#   2+ models → interactive fzf picker (numbered list fallback if fzf absent)
#
# Sets the three env vars Claude Code needs for local use — the user never has
# to type them manually.
cmd_claude() {
  # ── Guard: claude must be installed ────────────────────────────────────────
  if ! command -v claude &>/dev/null; then
    echo ""
    echo -e "  ${RED}✗${NC} Claude Code is not installed."
    echo "  Add 'claudecode' to INSTALL_ASSISTANTS in .env and restart."
    echo ""
    exit 1
  fi

  # ── Fetch available Ollama models ──────────────────────────────────────────
  local tags_json
  tags_json=$(curl -sf "${OLLAMA_URL}/api/tags" 2>/dev/null || echo "")

  local model_count
  model_count=$(printf '%s' "${tags_json}" | jq '.models | length' 2>/dev/null || echo "0")

  if [ "${model_count}" -eq 0 ]; then
    echo ""
    echo -e "  ${YELLOW}⚠${NC}  No local models found."
    echo "  Pull a model first:  haven pull qwen3-coder:30b"
    echo ""
    exit 1
  fi

  local selected_model

  if [ "${model_count}" -eq 1 ]; then
    # ── Single model — skip the menu, launch immediately ────────────────────
    selected_model=$(printf '%s' "${tags_json}" | jq -r '.models[0].name')
    echo ""
    echo -e "  ${CYAN}[InferHaven]${NC} Using local model: ${BOLD}${selected_model}${NC}"
  else
    # ── Multiple models — build a formatted display table ───────────────────
    # Columns: MODEL (left-aligned, 44 chars), PARAMS (10 chars), SIZE
    local display_list
    display_list=$(printf '%s' "${tags_json}" | jq -r '
      .models[] |
      [
        .name,
        (.details.parameter_size // "?"),
        ((.size / 1073741824 * 10 | round / 10 | tostring) + " GB")
      ] | @tsv
    ' | awk -F'\t' '{printf "%-44s %-10s %s\n", $1, $2, $3}')

    if command -v fzf &>/dev/null; then
      local col_header
      col_header=$(printf '  %-44s %-10s %s' "MODEL" "PARAMS" "SIZE")
      local selected_line
      selected_line=$(printf '%s\n' "${display_list}" | \
        fzf \
          --prompt="  › " \
          --header="${col_header}" \
          --height=60% \
          --min-height=10 \
          --border=rounded \
          --border-label="  haven claude — local models  " \
          --border-label-pos=3 \
          --no-sort \
          --color="header:cyan:bold,border:cyan,label:cyan,prompt:cyan,pointer:green" \
          2>/dev/null || true)
      selected_model=$(printf '%s' "${selected_line}" | awk '{print $1}')
    else
      # ── Fallback: numbered list ────────────────────────────────────────────
      echo ""
      echo -e "  ${CYAN}${BOLD}Local models:${NC}"
      echo ""
      printf '  %4s  %-44s %-10s %s\n' "#" "MODEL" "PARAMS" "SIZE"
      printf '  %s\n' "$(printf '─%.0s' {1..70})"
      local i=1
      while IFS= read -r line; do
        printf '  %3d)  %s\n' "${i}" "${line}"
        i=$(( i + 1 ))
      done <<< "${display_list}"
      echo ""
      printf '  Select (1–%d, Enter to cancel): ' "${model_count}"
      read -r choice
      if [ -z "${choice}" ]; then
        echo ""
        exit 0
      fi
      selected_model=$(printf '%s' "${tags_json}" \
        | jq -r --argjson n "${choice}" '.models[$n - 1].name // empty')
    fi

    # User hit Esc / Ctrl-C in fzf or entered nothing
    if [ -z "${selected_model}" ]; then
      echo ""
      exit 0
    fi
  fi

  # ── Fetch context length for the selected model ────────────────────────────
  # Priority 1: explicit num_ctx in model parameters (user-set or tuned)
  # Priority 2: native context_length from GGUF model_info (Ollama reads from file)
  # Fallback: OLLAMA_DEFAULT_CTX env or 131072 (common modern default)
  local show_json
  show_json=$(curl -sf "${OLLAMA_URL}/api/show" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${selected_model}\"}" 2>/dev/null || echo "{}")

  local ctx
  ctx=$(printf '%s' "${show_json}" \
    | jq -r '.parameters // ""' \
    | grep -i "^num_ctx " | awk '{print $2}' | head -1 || true)

  if [ -z "${ctx}" ]; then
    # Extract the smallest context_length key from model_info (handles llama.*,
    # gemma4.*, mistral.*, etc.). Use smallest in case multiple keys exist.
    ctx=$(printf '%s' "${show_json}" \
      | jq -r '(.model_info // {}) | to_entries[]
               | select(.key | test("\\.context_length$"))
               | .value' 2>/dev/null \
      | sort -n | head -1 || true)
  fi
  ctx="${ctx:-${OLLAMA_DEFAULT_CTX:-131072}}"

  # Cap to CLAUDE_CTX_LIMIT if set (e.g. CLAUDE_CTX_LIMIT=32768 in .env for
  # memory-constrained hardware). Unset = no cap, Claude Code manages compaction.
  local claude_ctx_max="${CLAUDE_CTX_LIMIT:-}"
  local ctx_display="${ctx}"
  if [ -n "${claude_ctx_max}" ] && [ "${ctx}" -gt "${claude_ctx_max}" ] 2>/dev/null; then
    ctx="${claude_ctx_max}"
  fi

  # ── Launch ─────────────────────────────────────────────────────────────────
  # ANTHROPIC_BASE_URL must be the root endpoint WITHOUT a /v1 suffix — the
  # Anthropic SDK appends /v1/messages automatically.  Ollama exposes the
  # Anthropic-compatible API at /v1/messages, so the correct base is just
  # the Ollama root (e.g. http://ollama:11434).
  #
  # CLAUDE_CODE_AUTO_COMPACT_WINDOW sets the token count at which auto-compaction
  # fires. Ollama's Anthropic API reports a fixed context_window (often 100k)
  # regardless of num_ctx — Claude Code's /context display will show that larger
  # number, but compaction triggers at the value we set here (the actual model
  # context). The "Autocompact buffer" percentage in /context reflects this value.
  echo -e "  ${CYAN}[InferHaven]${NC} Endpoint: ${OLLAMA_URL}"
  if [ "${ctx_display}" != "${ctx}" ]; then
    echo -e "  ${CYAN}[InferHaven]${NC} Context:  ${ctx} tokens (model supports ${ctx_display} — capped by CLAUDE_CTX_LIMIT)"
  else
    echo -e "  ${CYAN}[InferHaven]${NC} Context:  ${ctx} tokens (auto-compact threshold; /context display may show Ollama API value)"
  fi
  echo ""
  ANTHROPIC_AUTH_TOKEN="ollama" \
  ANTHROPIC_API_KEY="ollama" \
  ANTHROPIC_BASE_URL="${OLLAMA_URL}" \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_NETWORK_ACCESS="1" \
  CLAUDE_CODE_AUTO_COMPACT_WINDOW="${ctx}" \
    exec claude --model "${selected_model}"
}

# ── haven aider — Aider with local Ollama models ─────────────────────────────
# Launches Aider pointed at the container-internal Ollama endpoint.
# Uses the ollama_chat/ prefix (recommended by Aider docs over ollama/).
# Model selection:
#   0 models  → error with a helpful hint
#   1 model   → launches directly, no prompt
#   2+ models → interactive fzf picker (numbered list fallback if fzf absent)
#
# Sets OLLAMA_API_BASE so Aider routes requests to the correct endpoint.
cmd_aider() {
  # ── Guard: aider must be installed ─────────────────────────────────────────
  if ! command -v aider &>/dev/null; then
    echo ""
    echo -e "  ${RED}✗${NC} Aider is not installed."
    echo "  Add 'aider' to INSTALL_ASSISTANTS in .env and restart."
    echo ""
    exit 1
  fi

  # ── Fetch available Ollama models ──────────────────────────────────────────
  local tags_json
  tags_json=$(curl -sf "${OLLAMA_URL}/api/tags" 2>/dev/null || echo "")

  local model_count
  model_count=$(printf '%s' "${tags_json}" | jq '.models | length' 2>/dev/null || echo "0")

  if [ "${model_count}" -eq 0 ]; then
    echo ""
    echo -e "  ${YELLOW}⚠${NC}  No local models found."
    echo "  Pull a model first:  haven pull qwen2.5-coder:7b"
    echo ""
    exit 1
  fi

  local selected_model

  if [ "${model_count}" -eq 1 ]; then
    # ── Single model — skip the menu, launch immediately ────────────────────
    selected_model=$(printf '%s' "${tags_json}" | jq -r '.models[0].name')
    echo ""
    echo -e "  ${CYAN}[InferHaven]${NC} Using local model: ${BOLD}${selected_model}${NC}"
  else
    # ── Multiple models — build a formatted display table ───────────────────
    local display_list
    display_list=$(printf '%s' "${tags_json}" | jq -r '
      .models[] |
      [
        .name,
        (.details.parameter_size // "?"),
        ((.size / 1073741824 * 10 | round / 10 | tostring) + " GB")
      ] | @tsv
    ' | awk -F'\t' '{printf "%-44s %-10s %s\n", $1, $2, $3}')

    if command -v fzf &>/dev/null; then
      local col_header
      col_header=$(printf '  %-44s %-10s %s' "MODEL" "PARAMS" "SIZE")
      local selected_line
      selected_line=$(printf '%s\n' "${display_list}" | \
        fzf \
          --prompt="  › " \
          --header="${col_header}" \
          --height=60% \
          --min-height=10 \
          --border=rounded \
          --border-label="  haven aider — local models  " \
          --border-label-pos=3 \
          --no-sort \
          --color="header:cyan:bold,border:cyan,label:cyan,prompt:cyan,pointer:green" \
          2>/dev/null || true)
      selected_model=$(printf '%s' "${selected_line}" | awk '{print $1}')
    else
      # ── Fallback: numbered list ────────────────────────────────────────────
      echo ""
      echo -e "  ${CYAN}${BOLD}Local models:${NC}"
      echo ""
      printf '  %4s  %-44s %-10s %s\n' "#" "MODEL" "PARAMS" "SIZE"
      printf '  %s\n' "$(printf '─%.0s' {1..70})"
      local i=1
      while IFS= read -r line; do
        printf '  %3d)  %s\n' "${i}" "${line}"
        i=$(( i + 1 ))
      done <<< "${display_list}"
      echo ""
      printf '  Select (1–%d, Enter to cancel): ' "${model_count}"
      read -r choice
      if [ -z "${choice}" ]; then
        echo ""
        exit 0
      fi
      selected_model=$(printf '%s' "${tags_json}" \
        | jq -r --argjson n "${choice}" '.models[$n - 1].name // empty')
    fi

    # User hit Esc / Ctrl-C in fzf or entered nothing
    if [ -z "${selected_model}" ]; then
      echo ""
      exit 0
    fi
  fi

  # ── Fetch context length and ensure aider model settings are in sync ────────
  # _haven_model_ctx: .parameters num_ctx → .model_info[*.context_length] → env.
  local ctx
  ctx=$(_haven_model_ctx "${selected_model}")

  # Sync ~/.aider.model.settings.yml now so extra_params.num_ctx reflects the
  # freshest value — covers the case where 'haven params' was used
  # to change num_ctx after the last automatic sync.
  _sync_aider_models 2>/dev/null || true

  # ── Launch ─────────────────────────────────────────────────────────────────
  echo -e "  ${CYAN}[InferHaven]${NC} Endpoint: ${OLLAMA_URL}"
  echo -e "  ${CYAN}[InferHaven]${NC} Context:  ${ctx} tokens"
  echo ""
  # Unset cloud API keys so Aider routes exclusively to Ollama — prevents
  # conflict when ANTHROPIC_API_KEY / OPENAI_API_KEY are set in the environment.
  ANTHROPIC_API_KEY="" \
  OPENAI_API_KEY="" \
  OLLAMA_API_BASE="${OLLAMA_URL}" \
    exec aider --model "ollama_chat/${selected_model}"
}

# ── haven qwen — Qwen Code with local Ollama models ──────────────────────────
# Launches Qwen Code pointed at the container-internal Ollama endpoint.
# Model selection:
#   0 models  → error with a helpful hint
#   1 model   → launches directly, no prompt
#   2+ models → interactive fzf picker (numbered list fallback if fzf absent)
#
# --auth-type openai bypasses the mandatory cloud auth screen.
# OLLAMA_API_KEY is required (any non-empty value) for the OpenAI-compat provider.
cmd_qwen() {
  # ── Guard: qwen must be installed ──────────────────────────────────────────
  if ! command -v qwen &>/dev/null; then
    echo ""
    echo -e "  ${RED}✗${NC} Qwen Code is not installed."
    echo "  Add 'qwencode' to INSTALL_ASSISTANTS in .env and restart."
    echo ""
    exit 1
  fi

  # ── Fetch available Ollama models ──────────────────────────────────────────
  local tags_json
  tags_json=$(curl -sf "${OLLAMA_URL}/api/tags" 2>/dev/null || echo "")

  local model_count
  model_count=$(printf '%s' "${tags_json}" | jq '.models | length' 2>/dev/null || echo "0")

  if [ "${model_count}" -eq 0 ]; then
    echo ""
    echo -e "  ${YELLOW}⚠${NC}  No local models found."
    echo "  Pull a model first:  haven pull qwen2.5-coder:7b"
    echo ""
    exit 1
  fi

  local selected_model

  if [ "${model_count}" -eq 1 ]; then
    # ── Single model — skip the menu, launch immediately ────────────────────
    selected_model=$(printf '%s' "${tags_json}" | jq -r '.models[0].name')
    echo ""
    echo -e "  ${CYAN}[InferHaven]${NC} Using local model: ${BOLD}${selected_model}${NC}"
  else
    # ── Multiple models — build a formatted display table ───────────────────
    local display_list
    display_list=$(printf '%s' "${tags_json}" | jq -r '
      .models[] |
      [
        .name,
        (.details.parameter_size // "?"),
        ((.size / 1073741824 * 10 | round / 10 | tostring) + " GB")
      ] | @tsv
    ' | awk -F'\t' '{printf "%-44s %-10s %s\n", $1, $2, $3}')

    if command -v fzf &>/dev/null; then
      local col_header
      col_header=$(printf '  %-44s %-10s %s' "MODEL" "PARAMS" "SIZE")
      local selected_line
      selected_line=$(printf '%s\n' "${display_list}" | \
        fzf \
          --prompt="  › " \
          --header="${col_header}" \
          --height=60% \
          --min-height=10 \
          --border=rounded \
          --border-label="  haven qwen — local models  " \
          --border-label-pos=3 \
          --no-sort \
          --color="header:cyan:bold,border:cyan,label:cyan,prompt:cyan,pointer:green" \
          2>/dev/null || true)
      selected_model=$(printf '%s' "${selected_line}" | awk '{print $1}')
    else
      # ── Fallback: numbered list ────────────────────────────────────────────
      echo ""
      echo -e "  ${CYAN}${BOLD}Local models:${NC}"
      echo ""
      printf '  %4s  %-44s %-10s %s\n' "#" "MODEL" "PARAMS" "SIZE"
      printf '  %s\n' "$(printf '─%.0s' {1..70})"
      local i=1
      while IFS= read -r line; do
        printf '  %3d)  %s\n' "${i}" "${line}"
        i=$(( i + 1 ))
      done <<< "${display_list}"
      echo ""
      printf '  Select (1–%d, Enter to cancel): ' "${model_count}"
      read -r choice
      if [ -z "${choice}" ]; then
        echo ""
        exit 0
      fi
      selected_model=$(printf '%s' "${tags_json}" \
        | jq -r --argjson n "${choice}" '.models[$n - 1].name // empty')
    fi

    # User hit Esc / Ctrl-C in fzf or entered nothing
    if [ -z "${selected_model}" ]; then
      echo ""
      exit 0
    fi
  fi

  # ── Fetch context length and ensure qwen model settings are in sync ─────────
  # _haven_model_ctx: .parameters num_ctx → .model_info[*.context_length] → env.
  local ctx
  ctx=$(_haven_model_ctx "${selected_model}")

  # Sync settings.json so the selected model is set as default and context
  # reflects the freshest num_ctx value (covers haven params changes).
  _sync_qwencode_models 2>/dev/null || true

  # ── Launch ─────────────────────────────────────────────────────────────────
  echo -e "  ${CYAN}[InferHaven]${NC} Endpoint: ${OLLAMA_URL}"
  echo -e "  ${CYAN}[InferHaven]${NC} Context:  ${ctx} tokens"
  echo ""
  OLLAMA_API_KEY="ollama" \
    exec qwen --auth-type openai -m "${selected_model}"
}

# ── haven goose — Goose with local Ollama models ─────────────────────────────
# Launches Goose pointed at the container-internal Ollama endpoint.
# Model selection:
#   0 models  → error with a helpful hint
#   1 model   → launches directly, no prompt
#   2+ models → interactive fzf picker (numbered list fallback if fzf absent)
#
# After model selection, a second menu asks about the Ollama tool shim.
# The tool shim routes tool calls through a second (interpreter) model, which
# is useful when the main model does not natively support structured tool calls.
# Enabled via GOOSE_TOOLSHIM=1 + GOOSE_TOOLSHIM_OLLAMA_MODEL=<shim_model>.
cmd_goose() {
  # ── Guard: goose must be installed ─────────────────────────────────────────
  if ! command -v goose &>/dev/null; then
    echo ""
    echo -e "  ${RED}✗${NC} Goose is not installed."
    echo "  Add 'goose' to INSTALL_ASSISTANTS in .env and restart."
    echo ""
    exit 1
  fi

  # ── Fetch available Ollama models ──────────────────────────────────────────
  local tags_json
  tags_json=$(curl -sf "${OLLAMA_URL}/api/tags" 2>/dev/null || echo "")

  local model_count
  model_count=$(printf '%s' "${tags_json}" | jq '.models | length' 2>/dev/null || echo "0")

  if [ "${model_count}" -eq 0 ]; then
    echo ""
    echo -e "  ${YELLOW}⚠${NC}  No local models found."
    echo "  Pull a model first:  haven pull qwen2.5-coder:7b"
    echo ""
    exit 1
  fi

  # Build formatted display table (reused for both main and shim pickers)
  local display_list col_header
  display_list=$(printf '%s' "${tags_json}" | jq -r '
    .models[] |
    [
      .name,
      (.details.parameter_size // "?"),
      ((.size / 1073741824 * 10 | round / 10 | tostring) + " GB")
    ] | @tsv
  ' | awk -F'\t' '{printf "%-44s %-10s %s\n", $1, $2, $3}')
  col_header=$(printf '  %-44s %-10s %s' "MODEL" "PARAMS" "SIZE")

  local selected_model

  if [ "${model_count}" -eq 1 ]; then
    # ── Single model — skip the menu, launch immediately ────────────────────
    selected_model=$(printf '%s' "${tags_json}" | jq -r '.models[0].name')
    echo ""
    echo -e "  ${CYAN}[InferHaven]${NC} Using local model: ${BOLD}${selected_model}${NC}"
  else
    # ── Multiple models — fzf picker or numbered list ───────────────────────
    if command -v fzf &>/dev/null; then
      local selected_line
      selected_line=$(printf '%s\n' "${display_list}" | \
        fzf \
          --prompt="  › " \
          --header="${col_header}" \
          --height=60% \
          --min-height=10 \
          --border=rounded \
          --border-label="  haven goose — local models  " \
          --border-label-pos=3 \
          --no-sort \
          --color="header:cyan:bold,border:cyan,label:cyan,prompt:cyan,pointer:green" \
          2>/dev/null || true)
      selected_model=$(printf '%s' "${selected_line}" | awk '{print $1}')
    else
      # ── Fallback: numbered list ────────────────────────────────────────────
      echo ""
      echo -e "  ${CYAN}${BOLD}Local models:${NC}"
      echo ""
      printf '  %4s  %-44s %-10s %s\n' "#" "MODEL" "PARAMS" "SIZE"
      printf '  %s\n' "$(printf '─%.0s' {1..70})"
      local i=1
      while IFS= read -r line; do
        printf '  %3d)  %s\n' "${i}" "${line}"
        i=$(( i + 1 ))
      done <<< "${display_list}"
      echo ""
      printf '  Select (1–%d, Enter to cancel): ' "${model_count}"
      read -r choice
      if [ -z "${choice}" ]; then
        echo ""
        exit 0
      fi
      selected_model=$(printf '%s' "${tags_json}" \
        | jq -r --argjson n "${choice}" '.models[$n - 1].name // empty')
    fi

    # User hit Esc / Ctrl-C in fzf or entered nothing
    if [ -z "${selected_model}" ]; then
      echo ""
      exit 0
    fi
  fi

  # ── Tool shim configuration ───────────────────────────────────────────────
  # The Ollama tool shim lets models that don't support native tool calls work
  # with Goose by routing tool-call JSON through a second interpreter model.
  # Default shim interpreter is mistral-nemo (Goose upstream default); here we
  # default to the selected model so users get a working setup immediately.
  local toolshim_enabled=0
  local shim_model="${selected_model}"

  local shim_none="  No  — standard mode (use native tool calls)"
  local shim_same="  Yes — enable tool shim  [shim interpreter: ${selected_model}]"
  local shim_pick="  Yes — enable tool shim  [pick a different shim interpreter]"

  if command -v fzf &>/dev/null; then
    local shim_options shim_choice
    if [ "${model_count}" -gt 1 ]; then
      shim_options=$(printf '%s\n%s\n%s' "${shim_none}" "${shim_same}" "${shim_pick}")
    else
      shim_options=$(printf '%s\n%s' "${shim_none}" "${shim_same}")
    fi

    shim_choice=$(printf '%s\n' "${shim_options}" | \
      fzf \
        --prompt="  › " \
        --header="  Experimental — helps models without native tool calls work with Goose" \
        --height=12 \
        --min-height=8 \
        --border=rounded \
        --border-label="  haven goose — Ollama tool shim  " \
        --border-label-pos=3 \
        --no-sort \
        --color="header:cyan:bold,border:cyan,label:cyan,prompt:cyan,pointer:green" \
        2>/dev/null || true)

    # Empty = Esc/Ctrl-C
    if [ -z "${shim_choice}" ]; then
      echo ""
      exit 0
    fi

    if printf '%s' "${shim_choice}" | grep -q "^  Yes"; then
      toolshim_enabled=1
      if printf '%s' "${shim_choice}" | grep -q "pick a different"; then
        # Third picker: choose the shim interpreter model
        local shim_line
        shim_line=$(printf '%s\n' "${display_list}" | \
          fzf \
            --prompt="  › " \
            --header="${col_header}" \
            --height=60% \
            --min-height=10 \
            --border=rounded \
            --border-label="  haven goose — shim interpreter model  " \
            --border-label-pos=3 \
            --no-sort \
            --color="header:cyan:bold,border:cyan,label:cyan,prompt:cyan,pointer:green" \
            2>/dev/null || true)
        shim_model=$(printf '%s' "${shim_line}" | awk '{print $1}')
        if [ -z "${shim_model}" ]; then
          echo ""
          exit 0
        fi
      fi
    fi
  else
    # ── Fallback: plain prompts ────────────────────────────────────────────
    echo ""
    printf '  Enable Ollama tool shim? (experimental — helps models without native tool calls work with Goose) [y/N]: '
    read -r ts_choice
    if [ "${ts_choice}" = "y" ] || [ "${ts_choice}" = "Y" ]; then
      toolshim_enabled=1
      if [ "${model_count}" -gt 1 ]; then
        printf '  Use %s as shim interpreter? [Y/n]: ' "${selected_model}"
        read -r same_choice
        if [ "${same_choice}" = "n" ] || [ "${same_choice}" = "N" ]; then
          echo ""
          echo -e "  ${CYAN}${BOLD}Shim interpreter model:${NC}"
          echo ""
          printf '  %4s  %-44s %-10s %s\n' "#" "MODEL" "PARAMS" "SIZE"
          printf '  %s\n' "$(printf '─%.0s' {1..70})"
          local j=1
          while IFS= read -r line; do
            printf '  %3d)  %s\n' "${j}" "${line}"
            j=$(( j + 1 ))
          done <<< "${display_list}"
          echo ""
          printf '  Select shim model (1–%d, Enter to use %s): ' "${model_count}" "${selected_model}"
          read -r shim_idx
          if [ -n "${shim_idx}" ]; then
            local candidate
            candidate=$(printf '%s' "${tags_json}" \
              | jq -r --argjson n "${shim_idx}" '.models[$n - 1].name // empty')
            [ -n "${candidate}" ] && shim_model="${candidate}"
          fi
        fi
      fi
    fi
  fi

  # ── Pre-flight: verify the model is still listed in Ollama ──────────────────
  # The user could have removed it between the picker and now (or it failed to
  # load). Bail early with a helpful message rather than letting Goose error out.
  if ! printf '%s' "${tags_json}" | jq -e --arg m "${selected_model}" \
      '.models[].name | select(. == $m)' > /dev/null 2>&1; then
    echo ""
    echo -e "  ${RED}✗${NC} Model '${selected_model}' is no longer available in Ollama."
    echo -e "  Run 'haven pull ${selected_model}' to restore it, or choose a different model."
    echo ""
    exit 1
  fi

  # ── Fetch context length for the main model ────────────────────────────────
  # _haven_model_ctx: .parameters num_ctx → .model_info[*.context_length] → env.
  # Critical for goose: this value becomes OLLAMA_CONTEXT_LENGTH at exec time.
  local ctx
  ctx=$(_haven_model_ctx "${selected_model}")

  # ── Context ceiling ────────────────────────────────────────────────────────
  # Cap context sent to Goose to prevent KV-cache OOM on constrained hardware.
  # Goose fills its context budget with tool schemas; a huge window dramatically
  # increases VRAM/RAM usage and can cause the model to stall mid-stream (30s
  # timeout) or the Ollama server to OOM-crash on model reload.
  # Override: set GOOSE_CTX_LIMIT in .env (e.g. GOOSE_CTX_LIMIT=16384).
  local goose_ctx_max="${GOOSE_CTX_LIMIT:-32768}"
  local ctx_display="${ctx}"
  if [ "${ctx}" -gt "${goose_ctx_max}" ] 2>/dev/null; then
    ctx="${goose_ctx_max}"
  fi

  # ── Launch ──────────────────────────────────────────────────────────────────
  echo -e "  ${CYAN}[InferHaven]${NC} Endpoint:   ${OLLAMA_URL}"
  if [ "${ctx_display}" != "${ctx}" ]; then
    echo -e "  ${CYAN}[InferHaven]${NC} Context:    ${ctx} tokens (model supports ${ctx_display} — capped; set GOOSE_CTX_LIMIT to override)"
  else
    echo -e "  ${CYAN}[InferHaven]${NC} Context:    ${ctx} tokens"
  fi
  if [ "${toolshim_enabled}" -eq 1 ]; then
    echo -e "  ${CYAN}[InferHaven]${NC} Tool shim:  enabled  (interpreter: ${shim_model})"
    echo -e "  ${YELLOW}[InferHaven]${NC} Note: tool shim holds two model instances simultaneously — may cause OOM on memory-constrained hardware."
  fi
  echo ""

  if [ "${toolshim_enabled}" -eq 1 ]; then
    GOOSE_PROVIDER="ollama" \
    OLLAMA_HOST="${OLLAMA_URL}" \
    GOOSE_MODEL="${selected_model}" \
    OLLAMA_CONTEXT_LENGTH="${ctx}" \
    GOOSE_TOOLSHIM="1" \
    GOOSE_TOOLSHIM_OLLAMA_MODEL="${shim_model}" \
      exec goose session
  else
    GOOSE_PROVIDER="ollama" \
    OLLAMA_HOST="${OLLAMA_URL}" \
    GOOSE_MODEL="${selected_model}" \
    OLLAMA_CONTEXT_LENGTH="${ctx}" \
      exec goose session
  fi
}


# ── Status / logs ─────────────────────────────────────────────────────────────
cmd_status() {
  echo ""
  _haven_compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
  echo ""

  if curl -sf "${OLLAMA_URL}/api/tags" > /dev/null 2>&1; then
    local count
    count=$(curl -s "${OLLAMA_URL}/api/tags" | jq '.models | length' 2>/dev/null || echo "?")
    local loaded
    loaded=$(curl -sf "${OLLAMA_URL}/api/ps" 2>/dev/null | jq '.models | length' 2>/dev/null || echo "0")
    echo -e "  Ollama:      ${GREEN}● running${NC}  (${count} downloaded, ${loaded} loaded in memory)"
  else
    echo -e "  Ollama:      ${RED}● not reachable${NC}"
  fi

  # Ollama uses Ed25519 key-based auth — there is no credentials file.
  # The only reliable check is `ollama login` itself, which calls /api/me and
  # exits immediately in both the signed-in and signed-out cases (no hang).
  local login_out
  login_out=$(docker exec "$(_haven_container ollama)" sh -c \
    'timeout 5 ollama login 2>&1 </dev/null' 2>/dev/null || echo "")
  if printf '%s' "${login_out}" | grep -q "already signed in"; then
    local username
    username=$(printf '%s' "${login_out}" | \
      grep -oP "(?<=user ')[^']+" 2>/dev/null || echo "")
    if [ -n "${username}" ]; then
      echo -e "  Ollama auth: ${GREEN}● authenticated${NC}  (${username})"
    else
      echo -e "  Ollama auth: ${GREEN}● authenticated${NC}"
    fi
  else
    echo -e "  Ollama auth: ${YELLOW}● not signed in${NC}  (run: haven signin)"
  fi
  echo ""
}

cmd_logs() {
  if [ -n "${1:-}" ]; then
    _haven_compose logs -f "$1"
  else
    _haven_compose logs -f
  fi
}

# ── SSH / IDE info ────────────────────────────────────────────────────────────
cmd_ssh_key() {
  if [ -z "${1:-}" ]; then
    echo "Usage: haven ssh-key \"ssh-ed25519 AAAA... user@host\""
    exit 1
  fi
  add-ssh-key "$1"
}

# Returns 0 (true) when the host warrants TLS (i.e. not a bare IP or localhost)
_is_tls() {
  local d="$1"
  case "$d" in
    localhost|127.*) return 1 ;;
  esac
  echo "$d" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && return 1
  return 0
}

# DOMAIN is injected by docker-compose from the host .env.
# Inside the container hostname -I gives the bridge IP, so we rely solely on $DOMAIN.
_resolve_host() {
  local domain="${DOMAIN:-localhost}"
  echo "$domain"
}

cmd_ssh() {
  local PORT="${SSH_PORT:-2222}"
  local HOST; HOST="$(_resolve_host)"
  echo ""
  echo -e "  ${CYAN}SSH into InferHaven:${NC}"
  echo "    ssh -p ${PORT} haven@${HOST}"
  if [ "$HOST" = "localhost" ]; then
    echo ""
    echo "  For remote access, set DOMAIN in .env to your server IP or hostname."
  fi
  echo ""
}

cmd_ide() {
  local HOST; HOST="$(_resolve_host)"
  local URL
  if _is_tls "$HOST"; then
    URL="https://${HOST}/ide"
  else
    local PORT="${HTTP_PORT:-80}"
    if [ "$PORT" = "80" ]; then
      URL="http://${HOST}/ide"
    else
      URL="http://${HOST}:${PORT}/ide"
    fi
  fi
  echo ""
  echo -e "  ${CYAN}Web IDE (VS Code):${NC}"
  echo "    ${URL}"
  echo ""
  echo "  Password: (set in .env as CODE_SERVER_PASSWORD)"
  echo ""
}

# ── tmux workspace manager ────────────────────────────────────────────────────
# 'haven tmux' is the unified tmux interface. The 'Haven' session is always
# running and auto-restored after every container restart via tmux-continuum
# (auto-saves every 15 min) + tmux-resurrect. No manual setup required.
#
# 'haven session' is kept as a backward-compatible alias.

_tmux_attach() {
  local name="${1:-Haven}"
  if tmux has-session -t "${name}" 2>/dev/null; then
    exec tmux attach-session -t "${name}"
  else
    echo -e "${CYAN}[InferHaven]${NC} Creating session '${name}'..."
    exec tmux new-session -s "${name}"
  fi
}

# Prompt for a name and create + switch to a new session (used when already inside tmux).
_tmux_new_switch() {
  local new_name
  printf '  New session name: '
  read -r new_name
  [ -z "${new_name}" ] && return 0
  if tmux has-session -t "${new_name}" 2>/dev/null; then
    echo -e "${YELLOW}[InferHaven]${NC} Session '${new_name}' already exists — switching."
  else
    tmux new-session -d -s "${new_name}"
  fi
  tmux switch-client -t "${new_name}"
}

# Prompt for a name and create + attach to a new session (used when outside tmux).
_tmux_new_attach() {
  local new_name
  printf '  New session name: '
  read -r new_name
  [ -z "${new_name}" ] && return 0
  if tmux has-session -t "${new_name}" 2>/dev/null; then
    echo -e "${YELLOW}[InferHaven]${NC} Session '${new_name}' already exists — attaching."
    exec tmux attach-session -t "${new_name}"
  else
    exec tmux new-session -s "${new_name}"
  fi
}

# Smart attach: fzf picker that supports switching, creating, and detaching without nesting.
_tmux_smart_attach() {
  local sessions
  local new_label="  + new session"

  # If no tmux server / no sessions, create and attach Haven
  sessions=$(tmux list-sessions -F "#{session_name}" 2>/dev/null) || {
    echo -e "${CYAN}[InferHaven]${NC} Creating Haven session..."
    exec tmux new-session -s Haven
  }

  if [ -n "${TMUX:-}" ]; then
    # Already inside tmux — use switch-client to avoid nesting.
    # Exclude the current session from the list (switching to yourself is a no-op).
    local current_session detach_label other_sessions menu choice
    current_session=$(tmux display-message -p '#S')
    detach_label="  detach from '${current_session}'"
    other_sessions=$(printf '%s\n' "${sessions}" | grep -vx "${current_session}" || true)

    if [ -n "${other_sessions}" ]; then
      menu=$(printf '%s\n%s\n%s' "${detach_label}" "${other_sessions}" "${new_label}")
    else
      menu=$(printf '%s\n%s' "${detach_label}" "${new_label}")
    fi

    choice=$(printf '%s\n' "${menu}" \
      | fzf \
          --prompt=" Session › " \
          --height=~40% \
          --border=rounded \
          --header=" Currently in: ${current_session}" \
          --header-first \
          --color="header:cyan,border:cyan,prompt:cyan" \
          --no-info \
          2>/dev/null)

    [ -z "${choice}" ] && return 0

    case "${choice}" in
      "${detach_label}") tmux detach-client ;;
      "${new_label}")    _tmux_new_switch ;;
      *)                 tmux switch-client -t "${choice}" ;;
    esac
  else
    # Not in tmux — always show the picker so the user can create new sessions too.
    local choice
    choice=$(printf '%s\n%s' "${sessions}" "${new_label}" \
      | fzf \
          --prompt=" Session › " \
          --height=~40% \
          --border=rounded \
          --header=" Select a tmux session" \
          --header-first \
          --color="header:cyan,border:cyan,prompt:cyan" \
          --no-info \
          2>/dev/null)

    [ -z "${choice}" ] && return 0

    if [ "${choice}" = "${new_label}" ]; then
      _tmux_new_attach
    else
      exec tmux attach-session -t "${choice}"
    fi
  fi
}

cmd_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "Error: tmux is not installed."
    exit 1
  fi

  local sub="${1:-}"
  shift 2>/dev/null || true

  case "${sub}" in

    "")
      _tmux_smart_attach
      ;;

    attach)
      _tmux_attach "${1:-Haven}"
      ;;

    ls|list)
      echo -e "${CYAN}[InferHaven]${NC} Active tmux sessions:"
      tmux list-sessions 2>/dev/null \
        || echo "  No sessions running. Start one with: haven tmux"
      ;;

    new)
      local name="${1:-}"
      if [ -z "${name}" ]; then
        echo "Usage: haven tmux new <name>"
        exit 1
      fi
      if tmux has-session -t "${name}" 2>/dev/null; then
        echo -e "${YELLOW}[InferHaven]${NC} Session '${name}' already exists — attaching."
        exec tmux attach-session -t "${name}"
      else
        echo -e "${CYAN}[InferHaven]${NC} Creating session '${name}'..."
        exec tmux new-session -s "${name}"
      fi
      ;;

    kill)
      local name="${1:-}"
      if [ -z "${name}" ]; then
        echo "Usage: haven tmux kill <name>"
        echo ""
        tmux list-sessions 2>/dev/null || echo "No sessions running."
        exit 1
      fi
      if [ "${name}" = "Haven" ]; then
        echo -e "${YELLOW}[InferHaven]${NC} Killing 'Haven' will destroy it until the next container restart."
        read -r -p "  Confirm? (y/N): " _confirm
        [ "${_confirm}" = "y" ] || { echo "Cancelled."; exit 0; }
      fi
      if tmux kill-session -t "${name}" 2>/dev/null; then
        echo -e "${GREEN}[InferHaven]${NC} Session '${name}' killed."
      else
        echo -e "${RED}[InferHaven]${NC} Session '${name}' not found."
        exit 1
      fi
      ;;

    save)
      local resurrect_save="${HOME}/.tmux/plugins/tmux-resurrect/scripts/save.sh"
      if [ ! -f "${resurrect_save}" ]; then
        echo -e "${RED}[InferHaven]${NC} tmux-resurrect not found. Run: haven tmux plugin install"
        exit 1
      fi
      if ! tmux list-sessions >/dev/null 2>&1; then
        echo -e "${RED}[InferHaven]${NC} No tmux sessions running — nothing to save."
        exit 1
      fi
      echo -e "${CYAN}[InferHaven]${NC} Saving session structure..."
      "${resurrect_save}"
      # Strip ephemeral popup sessions — same cleanup as the periodic save in entrypoint
      local last="${HOME}/.tmux/resurrect/last"
      if [ -L "${last}" ] && [ -e "${last}" ]; then
        local target; target=$(readlink -f "${last}")
        grep -v "haven-popup-" "${target}" > "${target}.tmp" && mv "${target}.tmp" "${target}"
      fi
      echo -e "${CYAN}[InferHaven]${NC} Saving pane content and running processes..."
      /usr/local/bin/ih-pane-capture
      echo -e "${GREEN}[InferHaven]${NC} Saved to ~/.tmux/resurrect/"
      ;;

    restore)
      local resurrect_restore="${HOME}/.tmux/plugins/tmux-resurrect/scripts/restore.sh"
      if [ ! -f "${resurrect_restore}" ]; then
        echo -e "${RED}[InferHaven]${NC} tmux-resurrect not found. Run: haven tmux plugin install"
        exit 1
      fi
      local last="${HOME}/.tmux/resurrect/last"
      if [ ! -e "${last}" ]; then
        echo -e "${RED}[InferHaven]${NC} No save file found — run 'haven tmux save' first."
        exit 1
      fi
      echo -e "${CYAN}[InferHaven]${NC} Restoring session structure..."
      "${resurrect_restore}"
      echo -e "${CYAN}[InferHaven]${NC} Restoring pane content and processes..."
      /usr/local/bin/ih-pane-restore
      echo -e "${GREEN}[InferHaven]${NC} Restore complete."
      ;;

    plugin)
      local plugin_sub="${1:-list}"
      shift 2>/dev/null || true
      case "${plugin_sub}" in
        list)
          echo -e "${CYAN}[InferHaven]${NC} Installed tmux plugins:"
          if [ -d "${HOME}/.tmux/plugins" ]; then
            # shellcheck disable=SC2012,SC2001  # plugin dir names are tmux-controlled; sed indent is fine
            ls -1 "${HOME}/.tmux/plugins/" | sed 's/^/  /'
          else
            echo "  No plugins directory found."
          fi
          ;;
        install)
          local tpm="${HOME}/.tmux/plugins/tpm/bin/install_plugins"
          if [ ! -f "${tpm}" ]; then
            echo -e "${RED}[InferHaven]${NC} TPM not found. Reinstall with: haven tmux plugin bootstrap"
            exit 1
          fi
          echo -e "${CYAN}[InferHaven]${NC} Installing plugins from ~/.tmux.conf..."
          "${tpm}"
          ;;
        update)
          local tpm="${HOME}/.tmux/plugins/tpm/bin/update_plugins"
          if [ ! -f "${tpm}" ]; then
            echo -e "${RED}[InferHaven]${NC} TPM not found. Reinstall with: haven tmux plugin bootstrap"
            exit 1
          fi
          echo -e "${CYAN}[InferHaven]${NC} Updating all tmux plugins..."
          "${tpm}" all
          ;;
        bootstrap)
          echo -e "${CYAN}[InferHaven]${NC} Bootstrapping tmux plugins from scratch..."
          rm -rf "${HOME}/.tmux/plugins"
          mkdir -p "${HOME}/.tmux/plugins" "${HOME}/.tmux/resurrect"
          git clone --depth=1 https://github.com/tmux-plugins/tpm \
            "${HOME}/.tmux/plugins/tpm"
          git clone --depth=1 https://github.com/tmux-plugins/tmux-resurrect \
            "${HOME}/.tmux/plugins/tmux-resurrect"
          git clone --depth=1 https://github.com/tmux-plugins/tmux-continuum \
            "${HOME}/.tmux/plugins/tmux-continuum"
          echo -e "${GREEN}[InferHaven]${NC} Plugins installed. Reload tmux config with: tmux source ~/.tmux.conf"
          ;;
        *)
          echo "Usage: haven tmux plugin <list|install|update|bootstrap>"
          ;;
      esac
      ;;

    help)
      echo ""
      echo -e "  ${CYAN}${BOLD}haven tmux${NC} — persistent tmux workspace manager"
      echo ""
      echo "  Usage: haven tmux [subcommand] [args]"
      echo ""
      echo -e "  ${BOLD}Sessions${NC}"
      echo "    (no args)          Smart attach: auto-attach if only Haven exists,"
      echo "                       fzf picker for multiple sessions, detach option"
      echo "                       if already inside tmux"
      echo "    attach [name]      Attach directly to a session (default: Haven)"
      echo "    <name>             Shorthand: attach to or create a named session"
      echo "    ls                 List all active sessions"
      echo "    new <name>         Create and attach to a new named session"
      echo "    kill <name>        Kill a session"
      echo ""
      echo -e "  ${BOLD}Persistence${NC}"
      echo "    save               Manually save all sessions to disk"
      echo "    restore            Manually restore sessions from last save"
      echo ""
      echo "  Sessions auto-save every 15 minutes and are fully restored after"
      echo "  every container restart — windows, panes, and working directories"
      echo "  are preserved automatically."
      echo ""
      echo -e "  ${BOLD}Plugins${NC}"
      echo "    plugin list        Show installed plugins"
      echo "    plugin install     Install plugins declared in ~/.tmux.conf"
      echo "    plugin update      Update all plugins to latest"
      echo "    plugin bootstrap   Reinstall all plugins from scratch"
      echo ""
      echo -e "  ${BOLD}Key bindings${NC} (prefix = Ctrl+a)"
      echo "    prefix + Ctrl-s    Save sessions now"
      echo "    prefix + Ctrl-r    Restore sessions now"
      echo "    prefix + I         Install plugins from ~/.tmux.conf"
      echo "    prefix + U         Update all plugins"
      echo ""
      ;;

    *)
      # Treat an unrecognised argument as a session name (shorthand attach/create)
      _tmux_attach "${sub}"
      ;;
  esac
}

# Backward-compatible alias
cmd_session() {
  cmd_tmux "$@"
}

# ── Package management ────────────────────────────────────────────────────────
_apt_ensure_fresh() {
  # Run apt-get update automatically if the package cache is missing or >24h old.
  # This prevents "Unable to locate package" errors without requiring the user
  # to remember to run update first. Runs silently unless actually refreshing.
  local cache="/var/cache/apt/pkgcache.bin"
  local stale=true

  if [ -f "${cache}" ]; then
    local age=$(( $(date +%s) - $(stat -c %Y "${cache}" 2>/dev/null || echo 0) ))
    [ "${age}" -lt 86400 ] && stale=false
  fi

  if [ "${stale}" = true ]; then
    echo "  Refreshing package lists..."
    sudo apt-get update -qq
  fi
}

cmd_apt() {
  local PKG_FILE="${HOME}/.apt-packages"

  case "${1:-help}" in
    install)
      shift
      if [ $# -eq 0 ]; then
        echo "Usage: haven apt install <package> [package2 ...]"
        exit 1
      fi
      touch "${PKG_FILE}"
      _apt_ensure_fresh
      sudo apt-get install -y "$@"
      for pkg in "$@"; do
        grep -qxF "${pkg}" "${PKG_FILE}" || echo "${pkg}" >> "${PKG_FILE}"
      done
      echo ""
      echo "Saved to ${PKG_FILE} — will persist on next restart."
      ;;

    remove)
      shift
      if [ $# -eq 0 ]; then
        echo "Usage: haven apt remove <package> [package2 ...]"
        exit 1
      fi
      touch "${PKG_FILE}"
      for pkg in "$@"; do
        sed -i "/^${pkg}$/d" "${PKG_FILE}"
        echo "Untracked: ${pkg} (still installed until next container restart)"
      done
      ;;

    list)
      if [ -s "${PKG_FILE}" ]; then
        echo "Persistent packages (${PKG_FILE}):"
        cat "${PKG_FILE}"
      else
        echo "No persistent packages tracked yet."
        echo "Install packages with: haven apt install <package>"
      fi
      ;;

    update)
      echo "Refreshing package lists..."
      sudo apt-get update
      ;;

    upgrade)
      if [ ! -s "${PKG_FILE}" ]; then
        echo "No persistent packages tracked. Nothing to upgrade."
        exit 0
      fi
      echo "Refreshing package lists..."
      sudo apt-get update -qq
      echo "Upgrading tracked packages..."
      # shellcheck disable=SC2024  # PKG_FILE is in $HOME (caller-readable); sudo only needed for apt-get
      sudo xargs apt-get install -y --no-install-recommends < "${PKG_FILE}"
      echo "Done. All tracked packages are at their latest versions."
      ;;

    repo)
      shift
      local REPO_DIR="${HOME}/.apt-repos"
      mkdir -p "${REPO_DIR}"
      case "${1:-list}" in
        add)
          # haven apt repo add <name> "<deb line>" [gpg-key-url]
          # Example:
          #   haven apt repo add github \
          #     "deb [arch=amd64 signed-by=/etc/apt/keyrings/github.gpg] https://cli.github.com/packages stable main" \
          #     https://cli.github.com/packages/githubcli-archive-keyring.gpg
          local repo_name="${2:-}"
          local deb_line="${3:-}"
          local key_url="${4:-}"
          if [ -z "${repo_name}" ] || [ -z "${deb_line}" ]; then
            echo "Usage: haven apt repo add <name> \"<deb line>\" [gpg-key-url]"
            echo ""
            echo "  <name>        Short identifier (e.g. github, nodesource)"
            echo "  <deb line>    Full deb entry as it would appear in sources.list"
            echo "  [gpg-key-url] URL to the repo's GPG signing key (optional)"
            exit 1
          fi
          if [ -n "${key_url}" ]; then
            echo "  Importing GPG key from ${key_url}..."
            curl -fsSL "${key_url}" | sudo gpg --dearmor -o "/etc/apt/keyrings/${repo_name}.gpg"
            sudo chmod a+r "/etc/apt/keyrings/${repo_name}.gpg"
            cp "/etc/apt/keyrings/${repo_name}.gpg" "${REPO_DIR}/${repo_name}.gpg"
          fi
          echo "${deb_line}" | sudo tee "/etc/apt/sources.list.d/${repo_name}.list" > /dev/null
          cp "/etc/apt/sources.list.d/${repo_name}.list" "${REPO_DIR}/${repo_name}.list"
          echo "  Refreshing package lists..."
          sudo apt-get update -qq
          echo ""
          echo "  Repo '${repo_name}' added and saved to ${REPO_DIR}/"
          echo "  It will be restored automatically on every container start."
          ;;

        remove)
          local repo_name="${2:-}"
          if [ -z "${repo_name}" ]; then
            echo "Usage: haven apt repo remove <name>"
            exit 1
          fi
          sudo rm -f "/etc/apt/sources.list.d/${repo_name}.list" "/etc/apt/keyrings/${repo_name}.gpg"
          rm -f "${REPO_DIR}/${repo_name}.list" "${REPO_DIR}/${repo_name}.gpg"
          echo "  Removed repo '${repo_name}'."
          ;;

        list)
          local found=false
          for _f in "${REPO_DIR}"/*.list; do
            [ -f "${_f}" ] || continue
            found=true
            break
          done
          if [ "${found}" = true ]; then
            echo "Custom repos (~/.apt-repos/):"
            for _f in "${REPO_DIR}"/*.list; do
              [ -f "${_f}" ] || continue
              printf "  %-20s %s\n" "$(basename "${_f}" .list)" "$(cat "${_f}")"
            done
          else
            echo "No custom repos configured."
            echo "Add one with: haven apt repo add <name> \"<deb line>\" [gpg-key-url]"
          fi
          ;;

        help|*)
          echo ""
          echo "  Usage: haven apt repo <subcommand>"
          echo ""
          echo "  Subcommands:"
          echo "    add <name> \"<deb line>\" [key-url]   Add a repo and optional GPG key"
          echo "    remove <name>                        Remove a repo"
          echo "    list                                 Show custom repos"
          echo ""
          echo "  Repos are stored in ~/.apt-repos/ and restored on every container start."
          echo ""
          echo "  Example (GitHub CLI):"
          echo "    haven apt repo add github \\"
          echo "      \"deb [arch=amd64 signed-by=/etc/apt/keyrings/github.gpg] https://cli.github.com/packages stable main\" \\"
          echo "      https://cli.github.com/packages/githubcli-archive-keyring.gpg"
          echo ""
          ;;
      esac
      ;;

    help|*)
      echo ""
      echo "  Usage: haven apt <subcommand> [args]"
      echo ""
      echo "  Subcommands:"
      echo "    install <pkg...>   Install and persist packages across restarts"
      echo "    remove  <pkg...>   Untrack package (stays installed until rebuild)"
      echo "    list               Show tracked packages"
      echo "    update             Refresh package lists (apt-get update)"
      echo "    upgrade            Upgrade all tracked packages to latest"
      echo "    repo               Manage persistent custom apt repositories"
      echo ""
      echo "  Package lists are refreshed automatically before install if >24h stale."
      echo "  Tracked packages are saved to ~/.apt-packages and reinstalled on start."
      echo ""
      ;;
  esac
}

# ── OpenCode status & setup ───────────────────────────────────────────────────
# ── Doctor ────────────────────────────────────────────────────────────────────
cmd_doctor() {
  echo ""
  echo -e "  ${CYAN}${BOLD}InferHaven Doctor${NC} — Checking your environment..."
  echo ""
  local ISSUES=0

  # ── Ollama API ─────────────────────────────────────────────────────────────
  if curl -sf "${OLLAMA_URL}/api/tags" > /dev/null 2>&1; then
    local count loaded
    count=$(curl -s "${OLLAMA_URL}/api/tags" | jq '.models | length' 2>/dev/null || echo "?")
    loaded=$(curl -sf "${OLLAMA_URL}/api/ps" 2>/dev/null | jq '.models | length' 2>/dev/null || echo "0")
    echo -e "  Ollama API:        ${GREEN}✓${NC} reachable (${count} downloaded, ${loaded} in memory)"
  else
    echo -e "  Ollama API:        ${RED}✗ not reachable${NC} (${OLLAMA_URL})"
    echo -e "                     Run from host: ./scripts/haven up"
    ISSUES=$((ISSUES + 1))
  fi

  # ── Docker socket ─────────────────────────────────────────────────────────
  # 'docker' may be aliased to 'sudo docker' above — either way it should work.
  if docker info > /dev/null 2>&1; then
    if alias docker 2>/dev/null | grep -q sudo; then
      echo -e "  Docker socket:     ${GREEN}✓${NC} accessible (via sudo — group propagation pending)"
    else
      echo -e "  Docker socket:     ${GREEN}✓${NC} accessible"
    fi
  else
    echo -e "  Docker socket:     ${RED}✗ not accessible${NC}"
    echo -e "                     The socket must be mounted: - /var/run/docker.sock:/var/run/docker.sock"
    ISSUES=$((ISSUES + 1))
  fi

  # ── Compose file ──────────────────────────────────────────────────────────
  # Look up the active compose project's config files (the labels compose
  # stamps on every container). The codespaces flavor uses
  # docker-compose.codespaces.yml, the full-stack flavor uses two files,
  # main stack uses docker-compose.yml — resolve dynamically rather than
  # hardcoding the filename.
  local _files _firstfile _firstname _local_path
  _files="$(_haven_resolve_compose_files)"
  if [ -z "$_files" ]; then
    if [ -f "$COMPOSE_FILE" ]; then
      echo -e "  Compose file:      ${GREEN}✓${NC} found (${COMPOSE_FILE})"
    else
      echo -e "  Compose file:      ${YELLOW}⚠ no compose labels${NC} (running outside compose?)"
    fi
  else
    _firstfile="$(printf '%s' "$_files" | tr ',' '\n' | head -1)"
    _firstname="$(basename "$_firstfile")"
    _local_path="${INFERHAVEN_DIR:-/opt/inferhaven}/${_firstname}"
    if [ -f "$_local_path" ]; then
      echo -e "  Compose file:      ${GREEN}✓${NC} found (${_local_path})"
    else
      echo -e "  Compose file:      ${YELLOW}⚠ project label OK but not mounted at ${INFERHAVEN_DIR:-/opt/inferhaven}${NC}"
      echo -e "                     Compose project files: ${_files}"
      echo -e "                     Add to your compose: \`- .:/opt/inferhaven:ro\`"
      ISSUES=$((ISSUES + 1))
    fi
  fi

  # ── .env perms ────────────────────────────────────────────────────────────
  # The host .env is mounted RO at /opt/inferhaven/.env via the workspace's
  # :/opt/inferhaven:ro bind. We can stat it but not chmod (the bind is RO).
  local _env_path="${INFERHAVEN_DIR:-/opt/inferhaven}/.env"
  if [ -f "$_env_path" ]; then
    local _env_mode
    _env_mode="$(stat -c '%a' "$_env_path" 2>/dev/null || echo '')"
    if [ -n "$_env_mode" ] && [ "$_env_mode" != "600" ] && [ "$_env_mode" != "400" ]; then
      echo -e "  .env perms:        ${YELLOW}⚠ ${_env_mode}${NC} (recommended 600 — contains API keys)"
      echo -e "                     Fix on host: chmod 600 \"\$(dirname \$COMPOSE_FILE)/.env\""
      ISSUES=$((ISSUES + 1))
    else
      echo -e "  .env perms:        ${GREEN}✓${NC} ${_env_mode:-unknown} (owner-only)"
    fi
  fi

  # ── Services ───────────────────────────────────────────────────────────────
  echo ""
  for SVC in ollama workspace code-server caddy; do
    local status name
    name="$(_haven_container "$SVC")"
    if [ -z "$name" ]; then
      echo -e "    ${SVC}: ${YELLOW}● not found in compose project '$(_haven_compose_project)'${NC}"
      continue
    fi
    status=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "not found")
    if [ "$status" = "running" ]; then
      echo -e "    ${name}: ${GREEN}● running${NC}"
    else
      echo -e "    ${name}: ${YELLOW}● ${status}${NC}"
    fi
  done

  # ── System resources ───────────────────────────────────────────────────────
  echo ""
  local total_mb avail_mb
  total_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
  avail_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
  if [ -n "$total_mb" ]; then
    local total_gb=$(( total_mb / 1024 ))
    local avail_gb=$(( avail_mb / 1024 ))
    if [ "$total_mb" -ge 16000 ]; then
      echo -e "  RAM:               ${GREEN}✓${NC} ${total_gb}GB total, ${avail_gb}GB available"
    elif [ "$total_mb" -ge 8000 ]; then
      echo -e "  RAM:               ${YELLOW}⚠${NC} ${total_gb}GB total (16GB+ recommended for larger models)"
    else
      echo -e "  RAM:               ${RED}✗${NC} ${total_gb}GB total (minimum 8GB recommended)"
      ISSUES=$((ISSUES + 1))
    fi
  fi

  local avail_disk
  avail_disk=$(df -BG /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')
  if [ -n "$avail_disk" ]; then
    if [ "$avail_disk" -ge 50 ]; then
      echo -e "  Disk (Docker):     ${GREEN}✓${NC} ${avail_disk}GB available"
    elif [ "$avail_disk" -ge 20 ]; then
      echo -e "  Disk (Docker):     ${YELLOW}⚠${NC} ${avail_disk}GB available (50GB+ recommended)"
    else
      echo -e "  Disk (Docker):     ${RED}✗${NC} ${avail_disk}GB available (models need 5-20GB each)"
      ISSUES=$((ISSUES + 1))
    fi
  fi

  # ── Bare-metal tools (P1/P2) ─────────────────────────────────────────────
  echo ""
  echo -e "  ${BOLD}Bare-metal tools${NC}"
  for _bin in mosh gh lazygit delta direnv zoxide eza mise atuin tmate rclone supercronic; do
    if command -v "${_bin}" >/dev/null 2>&1; then
      local _ver
      _ver=$("${_bin}" --version 2>/dev/null | head -1 | awk '{print $NF}')
      printf "    %-12s ${GREEN}✓${NC} %s\n" "${_bin}" "${_ver:-installed}"
    else
      printf "    %-12s ${YELLOW}—${NC} not installed\n" "${_bin}"
    fi
  done

  # ── Ollama backend (AMD / Vulkan known-bad-combo warnings) ───────────────
  # InferHaven never modifies Ollama's GPU layer offload or backend selection;
  # this section just surfaces known-broken upstream combinations so users can
  # spot them before they manifest as "nonsense output" or "33% offload"
  # symptoms (typically: Gemma3 + Vulkan + flash attention).
  #
  # Detection inspects the Ollama container (not the workspace host): the
  # workspace container does not see /dev/kfd or /dev/dri. We check the
  # container's env, mounted devices, and recent log lines.
  echo ""
  echo -e "  ${BOLD}Ollama backend${NC}"
  local ollama_vulkan=0 ollama_rocm=0
  if docker exec "$(_haven_container ollama)" sh -c 'echo "${OLLAMA_VULKAN:-0}"' 2>/dev/null \
       | grep -q '^1$'; then
    ollama_vulkan=1
  fi
  if docker inspect "$(_haven_container ollama)" --format='{{range .HostConfig.Devices}}{{.PathOnHost}} {{end}}' 2>/dev/null \
       | grep -q '/dev/kfd'; then
    ollama_rocm=1
  fi
  # Fallback: scan recent Ollama logs for vulkan/rocm markers.
  if [ "${ollama_vulkan}" -eq 0 ] && [ "${ollama_rocm}" -eq 0 ]; then
    if docker logs --tail 200 "$(_haven_container ollama)" 2>&1 | grep -qiE 'ggml_vulkan|vulkan device'; then
      ollama_vulkan=1
    elif docker logs --tail 200 "$(_haven_container ollama)" 2>&1 | grep -qiE 'rocm|hipblas|gfx[0-9]+'; then
      ollama_rocm=1
    fi
  fi
  if [ "${ollama_vulkan}" -eq 1 ] || [ "${ollama_rocm}" -eq 1 ]; then
    local _backend
    [ "${ollama_vulkan}" -eq 1 ] && _backend="AMD/Vulkan" || _backend="AMD/ROCm"
    local _fa _kv
    _fa=$(docker exec "$(_haven_container ollama)" sh -c 'printf "%s" "${OLLAMA_FLASH_ATTENTION:-0}"' 2>/dev/null)
    _kv=$(docker exec "$(_haven_container ollama)" sh -c 'printf "%s" "${OLLAMA_KV_CACHE_TYPE:-f16}"' 2>/dev/null)
    echo -e "    Backend:           ${_backend} detected (OLLAMA_FLASH_ATTENTION=${_fa:-0}, OLLAMA_KV_CACHE_TYPE=${_kv:-f16})"
    if [ "${ollama_vulkan}" -eq 1 ] && [ "${_fa}" = "1" ]; then
      echo -e "    ${YELLOW}⚠${NC}  OLLAMA_FLASH_ATTENTION=1 with AMD/Vulkan backend."
      echo    "        Known upstream Ollama bug: causes partial offload + corrupted output"
      echo    "        on Gemma3 (and some other models). Same model runs correctly on NVIDIA."
      echo    "        Workaround: set OLLAMA_FLASH_ATTENTION=0 in .env until upstream fixes it."
      ISSUES=$((ISSUES + 1))
    fi
    if [ "${ollama_vulkan}" -eq 1 ] && [ "${_kv}" != "f16" ]; then
      echo -e "    ${YELLOW}⚠${NC}  OLLAMA_KV_CACHE_TYPE=${_kv} with AMD/Vulkan backend."
      echo    "        Quantised KV cache can break partial offload on Vulkan. If you see"
      echo    "        slow inference or wrong output, try OLLAMA_KV_CACHE_TYPE=f16 in .env."
    fi
    if [ "${ollama_vulkan}" -eq 1 ] && [ "${_fa}" != "1" ] && [ "${_kv}" = "f16" ]; then
      echo -e "    ${GREEN}✓${NC}  AMD/Vulkan-safe defaults (flash-attention off, KV cache f16)."
    fi

    # iGPU detection — Ollama logs `uma: 1` on init when GPU has unified memory
    # (i.e. shares system RAM via GTT). iGPUs hit two hard limits not present on
    # dGPUs: per-allocation cap (Vulkan maxMemoryAllocationSize, often ~4 GiB on
    # AMD iGPU) and GTT heap ceiling (kernel `amdgpu.gttsize`). Large models fail
    # with `ErrorOutOfDeviceMemory` even when host RAM looks sufficient.
    if [ "${ollama_vulkan}" -eq 1 ] \
       && docker logs --tail 500 "$(_haven_container ollama)" 2>&1 | grep -qE 'ggml_vulkan:.*uma:[[:space:]]*1'; then
      echo -e "    ${YELLOW}⚠${NC}  AMD iGPU detected (unified memory)."
      echo    "        iGPUs share system RAM via GTT. Two hard limits apply:"
      echo    "          • Per-allocation cap (~4 GiB on most AMD iGPU) — single tensors"
      echo    "            larger than this fail regardless of free RAM."
      echo    "          • GTT heap ceiling — set via kernel boot param amdgpu.gttsize=<MB>."
      echo    "        See docs/gpu-setup.md → 'Vulkan on AMD iGPU' for tuning."
      ISSUES=$((ISSUES + 1))
    fi

    # Recent OOM scan — these markers indicate the iGPU/Vulkan path hit its cap.
    if [ "${ollama_vulkan}" -eq 1 ] \
       && docker logs --tail 500 "$(_haven_container ollama)" 2>&1 \
            | grep -qE 'ErrorOutOfDeviceMemory|failed to allocate Vulkan[0-9]+ buffer|exceeds device buffer size limit'; then
      echo -e "    ${YELLOW}⚠${NC}  Recent Vulkan OOM in Ollama logs."
      echo    "        Try: smaller quant (q3_K_M / q4_K_S), OLLAMA_NUM_PARALLEL=1 in .env,"
      echo    "        or raise host GTT: amdgpu.gttsize=<MB> via kernel boot param + reboot."
      ISSUES=$((ISSUES + 1))
    fi

    # Gemma3/4 + Vulkan — known broken (sliding-window attention mis-handled by
    # Vulkan backend; corrupt logits regardless of flash-attention setting).
    if [ "${ollama_vulkan}" -eq 1 ]; then
      local _gemma_bad
      _gemma_bad=$(curl -sf "${OLLAMA_URL:-http://ollama:11434}/api/tags" 2>/dev/null \
                     | jq -r '.models[].name' 2>/dev/null \
                     | grep -E '^gemma[34]' || true)
      if [ -n "${_gemma_bad}" ]; then
        echo -e "    ${YELLOW}⚠${NC}  Gemma3/4 model(s) installed with Vulkan backend:"
        # shellcheck disable=SC2086  # intentional word-split: print each model on its own line
        printf '          %s\n' ${_gemma_bad}
        echo    "        Known upstream Ollama bug — Vulkan mis-handles Gemma sliding-window"
        echo    "        attention, producing corrupted output even with FA off + KV f16."
        echo    "        Workarounds: use Gemma2 (older arch, works on Vulkan), switch to"
        echo    "        ROCm if your card is supported, or force CPU for Gemma sessions."
        ISSUES=$((ISSUES + 1))
      fi
    fi
  else
    echo -e "    Backend:           NVIDIA / CPU (no AMD-specific checks needed)"
  fi

  # ── Container limits / swap ──────────────────────────────────────────────
  echo ""
  local swap_total
  swap_total=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
  if [ "${swap_total:-0}" -eq 0 ]; then
    echo -e "  Host swap:         ${YELLOW}⚠ disabled${NC} (workloads near OOM will crash; enable host swap if possible)"
  else
    echo -e "  Host swap:         ${GREEN}✓${NC} $(awk -v s="${swap_total}" 'BEGIN{printf "%.1f", s/1048576}') GiB"
  fi
  if pgrep -f supercronic >/dev/null 2>&1; then
    echo -e "  supercronic:       ${GREEN}✓${NC} running (scheduled tasks active)"
  else
    echo -e "  supercronic:       ${YELLOW}—${NC} not running (log rotation + cache warm disabled)"
  fi

  # ── Connection info ────────────────────────────────────────────────────────
  echo ""
  echo -e "  SSH port (host):   ${SSH_PORT:-2222}"
  echo -e "  HTTP port (host):  ${HTTP_PORT:-80}"
  echo -e "  Ollama (internal): ${OLLAMA_URL}"

  # ── Summary ────────────────────────────────────────────────────────────────
  echo ""
  echo "  ──────────────────────────────────────────"
  if [ "$ISSUES" -eq 0 ]; then
    echo -e "  ${GREEN}✓ All checks passed. InferHaven is ready.${NC}"
  elif [ "$ISSUES" -le 2 ]; then
    echo -e "  ${YELLOW}⚠ ${ISSUES} minor issue(s) found. See above.${NC}"
  else
    echo -e "  ${RED}✗ ${ISSUES} issue(s) found. See above.${NC}"
  fi
  echo ""
}

# ── service: thin wrapper around docker compose for one service ──────────────
cmd_service() {
  local svc="${1:-}" action="${2:-status}"
  if [ -z "${svc}" ]; then
    echo "Usage: haven service <name> {status|restart|stop|start|logs}"
    echo "Services: ollama, workspace, code-server, caddy"
    return 1
  fi
  case "${action}" in
    status)
      local name; name="$(_haven_container "$svc")"
      if [ -z "$name" ]; then
        echo "${svc}: not found in compose project '$(_haven_compose_project)'"
        return 1
      fi
      docker inspect --format='{{.State.Status}}: started {{.State.StartedAt}}' "$name"
      ;;
    restart) _haven_compose restart "${svc}" ;;
    stop)    _haven_compose stop "${svc}" ;;
    start)   _haven_compose start "${svc}" ;;
    logs)    shift 2; _haven_compose logs "${@:--n=50}" "${svc}" ;;
    *) echo "Unknown action: ${action}"; return 1 ;;
  esac
}

# ── limits: show cgroup container limits vs host capacity ────────────────────
cmd_limits() {
  echo ""
  echo -e "  ${CYAN}${BOLD}Container limits${NC} vs host"
  echo ""
  local mem_max mem_cur cpu_max
  mem_max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo "max")
  mem_cur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo "?")
  cpu_max=$(cat /sys/fs/cgroup/cpu.max 2>/dev/null || echo "max")
  local host_total host_avail
  host_total=$(awk '/^MemTotal:/{printf "%.1f", $2/1048576}' /proc/meminfo)
  host_avail=$(awk '/^MemAvailable:/{printf "%.1f", $2/1048576}' /proc/meminfo)
  if [ "${mem_max}" = "max" ]; then
    echo -e "  Memory cap:        ${YELLOW}unlimited${NC} (host has ${host_total} GiB total, ${host_avail} GiB free)"
  else
    local cap_g
    cap_g=$(awk -v m="${mem_max}" 'BEGIN{printf "%.1f", m/1073741824}')
    echo -e "  Memory cap:        ${cap_g} GiB (host: ${host_total} GiB total, ${host_avail} GiB free)"
    [ "${mem_cur}" != "?" ] && \
      echo -e "  Memory in use:     $(awk -v m="${mem_cur}" 'BEGIN{printf "%.1f", m/1073741824}') GiB"
  fi
  if [ "${cpu_max}" = "max" ]; then
    echo -e "  CPU cap:           ${YELLOW}unlimited${NC} (host has $(nproc) cores)"
  else
    local quota period
    read -r quota period <<< "${cpu_max}"
    if [ -n "${quota}" ] && [ -n "${period}" ] && [ "${quota}" != "max" ]; then
      local cores
      cores=$(awk "BEGIN{printf \"%.2f\", ${quota}/${period}}")
      echo -e "  CPU cap:           ${cores} cores (host: $(nproc))"
    fi
  fi
  local swap_total
  swap_total=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
  if [ "${swap_total:-0}" -eq 0 ]; then
    echo -e "  Host swap:         ${YELLOW}⚠ 0 MiB${NC} (workloads near OOM will crash)"
  else
    local swap_g
    swap_g=$(awk -v s="${swap_total}" 'BEGIN{printf "%.1f", s/1048576}')
    echo -e "  Host swap:         ${swap_g} GiB"
  fi
  echo ""
}

# ── gpu-info: canonical GPU summary from metrics-server ──────────────────────
cmd_gpu_info() {
  local m
  m=$(curl -sf --max-time 1 http://127.0.0.1:9091/metrics.json 2>/dev/null)
  if [ -z "${m}" ]; then
    echo -e "  ${RED}metrics-server unreachable${NC} (localhost:9091)"
    return 1
  fi
  echo ""
  echo -e "  ${CYAN}${BOLD}GPU${NC}"
  echo ""
  echo "${m}" | jq -r '
    if (.gpu_name // "") == "" then
      "  No GPU detected (CPU-only inference)."
    else
      "  Name:       \(.gpu_name)\n  Util:       \(.gpu_util_pct // "?")%\n  VRAM used:  \(.gpu_vram_used_mb // "?") MiB\n  VRAM total: \(.gpu_vram_total_mb // "?") MiB"
    end
  '
  echo ""
}

# ── tmate: secure pair-programming session ────────────────────────────────────
# Backgrounded tmate session detached from the calling shell. URLs and PID get
# written to ~/.haven/tmate.state so the right-popup Sessions tab can list and
# manage active sessions without re-reading from tmate.
#
# Server config persisted in ~/.haven/tmate-settings (mode 600).
# Self-hosted tmate server is strongly recommended over public tmate.io.
# See: https://github.com/tmate-io/tmate-ssh-server
#
# Subcommands:
#   haven tmate                  start (or print existing) URLs, then return
#   haven tmate configure        interactive wizard or flag-based server setup
#   haven tmate status           print current state + server config
#   haven tmate kill             tear down the active session
#   haven tmate fg               attach to the tmate session in this terminal
#
# Env vars (pre-configure self-hosted server via .env):
#   TMATE_SERVER_HOST            hostname / IP of self-hosted tmate server
#   TMATE_SERVER_PORT            port (default 22)
#   TMATE_SERVER_RSA_FP          RSA fingerprint (SHA256:...)
#   TMATE_SERVER_ED25519_FP      Ed25519 fingerprint (SHA256:...)
cmd_tmate() {
  if ! command -v tmate >/dev/null 2>&1; then
    echo "tmate not installed. Install via: haven apt install tmate"
    return 1
  fi

  local sub="${1:-start}"
  local state="${HOME}/.haven/tmate.state"
  local sock="${HOME}/.haven/tmate.sock"
  local settings="${HOME}/.haven/tmate-settings"
  mkdir -p "${HOME}/.haven" 2>/dev/null

  _tmate_alive() {
    [ -S "${sock}" ] && tmate -S "${sock}" display -p '#{tmate_ssh}' >/dev/null 2>&1
  }

  # Load settings into _tm_* vars (cleared first so stale values never linger).
  _tmate_load_settings() {
    _tm_server=""; _tm_consented=""; _tm_host=""; _tm_port=""
    _tm_rsa_fp=""; _tm_ed25519_fp=""
    [ -f "${settings}" ] || return 0
    while IFS='=' read -r _k _v; do
      case "${_k}" in
        server)          _tm_server="${_v}" ;;
        consented)       _tm_consented="${_v}" ;;
        self_host)       _tm_host="${_v}" ;;
        self_port)       _tm_port="${_v}" ;;
        self_rsa_fp)     _tm_rsa_fp="${_v}" ;;
        self_ed25519_fp) _tm_ed25519_fp="${_v}" ;;
      esac
    done < "${settings}"
  }

  _tmate_save_settings() {
    {
      echo "server=${_tm_server}"
      [ -n "${_tm_consented}"   ] && echo "consented=${_tm_consented}"
      [ -n "${_tm_host}"        ] && echo "self_host=${_tm_host}"
      [ -n "${_tm_port}"        ] && echo "self_port=${_tm_port}"
      [ -n "${_tm_rsa_fp}"      ] && echo "self_rsa_fp=${_tm_rsa_fp}"
      [ -n "${_tm_ed25519_fp}"  ] && echo "self_ed25519_fp=${_tm_ed25519_fp}"
    } > "${settings}"
    chmod 600 "${settings}" 2>/dev/null || true
  }

  # Write ~/.tmate.conf for self-hosted relay; tmate reads this on start.
  _tmate_write_conf() {
    local _h="${1}" _p="${2:-22}" _rsa="${3:-}" _ed="${4:-}"
    {
      echo "set -g tmate-server-host \"${_h}\""
      echo "set -g tmate-server-port ${_p}"
      [ -n "${_rsa}" ] && echo "set -g tmate-server-rsa-fingerprint \"${_rsa}\""
      [ -n "${_ed}"  ] && echo "set -g tmate-server-ed25519-fingerprint \"${_ed}\""
    } > "${HOME}/.tmate.conf"
    chmod 600 "${HOME}/.tmate.conf" 2>/dev/null || true
  }

  # Silently auto-configure from Docker env vars (no prompt).
  _tmate_auto_configure_from_env() {
    _tm_server="self-hosted"; _tm_consented=""
    _tm_host="${TMATE_SERVER_HOST}"
    _tm_port="${TMATE_SERVER_PORT:-22}"
    _tm_rsa_fp="${TMATE_SERVER_RSA_FP:-}"
    _tm_ed25519_fp="${TMATE_SERVER_ED25519_FP:-}"
    _tmate_save_settings
    _tmate_write_conf "${_tm_host}" "${_tm_port}" "${_tm_rsa_fp}" "${_tm_ed25519_fp}"
    echo "tmate: auto-configured self-hosted server from env (${_tm_host}:${_tm_port})."
  }

  case "${sub}" in

    # ── configure ─────────────────────────────────────────────────────────────
    configure)
      shift  # remove "configure", leave flags in $@
      local _cfg_public=0 _cfg_host="" _cfg_port="22" _cfg_rsa="" _cfg_ed=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --public)      _cfg_public=1; shift ;;
          --server)      _cfg_host="${2:-}"; shift 2 ;;
          --port)        _cfg_port="${2:-22}"; shift 2 ;;
          --rsa-fp)      _cfg_rsa="${2:-}"; shift 2 ;;
          --ed25519-fp)  _cfg_ed="${2:-}"; shift 2 ;;
          *) echo "Unknown flag: $1"; echo "Usage: haven tmate configure [--public | --server HOST [--port PORT] [--rsa-fp FP] [--ed25519-fp FP]]"; return 1 ;;
        esac
      done

      if [ ${_cfg_public} -eq 1 ]; then
        echo ""
        echo "WARNING: tmate relays your terminal through a third-party server."
        echo "  Public tmate.io: every keystroke passes through their infrastructure."
        echo "  For sensitive workloads, use a self-hosted tmate server instead."
        echo "  See: https://github.com/tmate-io/tmate-ssh-server"
        echo ""
        printf "Type YES to confirm public tmate.io use: "
        local _yn; IFS= read -r _yn
        if [ "${_yn}" != "YES" ]; then echo "Aborted."; return 1; fi
        _tm_server="public"; _tm_consented="yes"
        _tm_host=""; _tm_port=""; _tm_rsa_fp=""; _tm_ed25519_fp=""
        _tmate_save_settings
        rm -f "${HOME}/.tmate.conf" 2>/dev/null
        echo "Configuration saved: public tmate.io."
        return 0
      fi

      if [ -n "${_cfg_host}" ]; then
        _tm_server="self-hosted"; _tm_consented=""
        _tm_host="${_cfg_host}"; _tm_port="${_cfg_port}"
        _tm_rsa_fp="${_cfg_rsa}"; _tm_ed25519_fp="${_cfg_ed}"
        _tmate_save_settings
        _tmate_write_conf "${_tm_host}" "${_tm_port}" "${_tm_rsa_fp}" "${_tm_ed25519_fp}"
        echo "Configuration saved: self-hosted server ${_tm_host}:${_tm_port}."
        [ -z "${_tm_rsa_fp}" ] && echo "  Note: no RSA fingerprint set — tmate will not verify server identity."
        return 0
      fi

      # Interactive wizard
      echo ""
      echo "haven tmate — server configuration"
      echo "──────────────────────────────────"
      echo "  [1] Self-hosted tmate server  (recommended — your infrastructure)"
      echo "  [2] Public tmate.io           (third-party relay — less secure)"
      echo "  [q] Cancel"
      echo ""
      printf "Choice [1/2/q]: "
      local _choice; IFS= read -r _choice
      case "${_choice}" in
        1)
          echo ""
          printf "Server hostname or IP: "
          IFS= read -r _cfg_host
          [ -z "${_cfg_host}" ] && echo "Aborted — hostname required." && return 1
          printf "Port [22]: "
          IFS= read -r _cfg_port
          _cfg_port="${_cfg_port:-22}"
          echo ""
          echo "Fingerprints verify your server's identity. Obtain them by running:"
          echo "  tmate-server --keys   (on your tmate server host)"
          echo "Leave blank to skip verification (not recommended for production)."
          echo ""
          printf "RSA fingerprint (SHA256:...): "
          IFS= read -r _cfg_rsa
          printf "Ed25519 fingerprint (SHA256:...): "
          IFS= read -r _cfg_ed
          _tm_server="self-hosted"; _tm_consented=""
          _tm_host="${_cfg_host}"; _tm_port="${_cfg_port}"
          _tm_rsa_fp="${_cfg_rsa}"; _tm_ed25519_fp="${_cfg_ed}"
          _tmate_save_settings
          _tmate_write_conf "${_tm_host}" "${_tm_port}" "${_tm_rsa_fp}" "${_tm_ed25519_fp}"
          echo ""
          echo "Configuration saved: self-hosted server ${_tm_host}:${_tm_port}."
          echo "Run 'haven tmate start' to begin."
          ;;
        2)
          echo ""
          echo "WARNING: tmate relays your terminal through a third-party server."
          echo "  Public tmate.io: every keystroke passes through their infrastructure."
          echo "  For sensitive workloads, use a self-hosted tmate server instead."
          echo "  See: https://github.com/tmate-io/tmate-ssh-server"
          echo ""
          printf "Type YES to confirm public tmate.io use: "
          IFS= read -r _yn
          if [ "${_yn}" != "YES" ]; then echo "Aborted."; return 1; fi
          _tm_server="public"; _tm_consented="yes"
          _tm_host=""; _tm_port=""; _tm_rsa_fp=""; _tm_ed25519_fp=""
          _tmate_save_settings
          rm -f "${HOME}/.tmate.conf" 2>/dev/null
          echo "Configuration saved: public tmate.io."
          echo "Run 'haven tmate start' to begin."
          ;;
        *)
          echo "Aborted."
          return 1
          ;;
      esac
      ;;

    # ── status ─────────────────────────────────────────────────────────────────
    status)
      _tmate_load_settings
      local _server_label=""
      if [ "${_tm_server}" = "self-hosted" ] && [ -n "${_tm_host}" ]; then
        _server_label="  Server: ${_tm_host}:${_tm_port:-22} (self-hosted)"
      elif [ "${_tm_server}" = "public" ]; then
        _server_label="  Server: tmate.io (public)"
      fi
      if _tmate_alive && [ -f "${state}" ]; then
        cat "${state}"
        [ -n "${_server_label}" ] && echo "${_server_label}"
      else
        echo "No active tmate session."
        [ -n "${_server_label}" ] && echo "${_server_label}"
        rm -f "${state}" 2>/dev/null
        return 1
      fi
      ;;

    # ── kill ───────────────────────────────────────────────────────────────────
    kill)
      if _tmate_alive; then
        tmate -S "${sock}" kill-server 2>/dev/null || true
        echo "tmate session killed."
      else
        echo "No active tmate session."
      fi
      rm -f "${state}" "${sock}" 2>/dev/null
      ;;

    # ── fg ─────────────────────────────────────────────────────────────────────
    fg)
      if _tmate_alive; then
        tmate -S "${sock}" attach
      else
        echo "No active tmate session — run 'haven tmate' to start one."
        return 1
      fi
      ;;

    # ── start ──────────────────────────────────────────────────────────────────
    start|"")
      if _tmate_alive; then
        echo "tmate session already running:"
        cat "${state}" 2>/dev/null
        return 0
      fi

      # Auto-configure from env vars when TMATE_SERVER_HOST is set and no
      # settings file exists yet — zero-friction for self-hosted deployments.
      if [ -n "${TMATE_SERVER_HOST:-}" ] && [ ! -f "${settings}" ]; then
        _tmate_auto_configure_from_env
      fi

      _tmate_load_settings

      # Consent gate: first-run or unconfigured path requires explicit opt-in.
      if [ -z "${_tm_server}" ]; then
        echo ""
        echo "WARNING: tmate relays your terminal through a third-party server."
        echo "  Public tmate.io: every keystroke passes through their infrastructure."
        echo "  For sensitive workloads, use a self-hosted tmate server instead."
        echo "  See: https://github.com/tmate-io/tmate-ssh-server"
        echo ""
        echo "Choose a relay server before starting:"
        echo "  [s] Configure self-hosted server (recommended)"
        echo "  [p] Use public tmate.io          (less secure)"
        echo "  [q] Cancel"
        echo ""
        printf "Choice [s/p/q]: "
        local _c; IFS= read -r _c
        case "${_c}" in
          s|S)
            cmd_tmate configure || return 1
            _tmate_load_settings
            ;;
          p|P)
            echo ""
            printf "Type YES to confirm public tmate.io use: "
            local _yn3; IFS= read -r _yn3
            if [ "${_yn3}" != "YES" ]; then echo "Aborted."; return 1; fi
            _tm_server="public"; _tm_consented="yes"
            _tm_host=""; _tm_port=""; _tm_rsa_fp=""; _tm_ed25519_fp=""
            _tmate_save_settings
            rm -f "${HOME}/.tmate.conf" 2>/dev/null
            ;;
          *)
            echo "Aborted."
            return 1
            ;;
        esac
      fi

      # Apply self-hosted config to ~/.tmate.conf so tmate picks it up.
      if [ "${_tm_server}" = "self-hosted" ] && [ -n "${_tm_host}" ]; then
        _tmate_write_conf "${_tm_host}" "${_tm_port:-22}" "${_tm_rsa_fp}" "${_tm_ed25519_fp}"
      fi

      rm -f "${sock}" "${state}" 2>/dev/null
      local startlog="${HOME}/.haven/tmate-start.log"
      : > "${startlog}"
      if ! tmate -S "${sock}" new-session -d >>"${startlog}" 2>&1; then
        echo "tmate: failed to start. See ${startlog}"
        sed 's/^/  /' "${startlog}" 2>/dev/null
        return 1
      fi
      # Wait up to 15 s for tmate to register with the relay.
      if ! timeout 15 tmate -S "${sock}" wait tmate-ready >>"${startlog}" 2>&1; then
        echo "tmate: never became ready (relay unreachable?). Log:"
        sed 's/^/  /' "${startlog}" 2>/dev/null
        tmate -S "${sock}" kill-server 2>/dev/null || true
        rm -f "${sock}" 2>/dev/null
        return 1
      fi
      local ssh_url web_url ssh_ro web_ro pid
      ssh_url=$(tmate -S "${sock}" display -p '#{tmate_ssh}'     2>/dev/null)
      web_url=$(tmate -S "${sock}" display -p '#{tmate_web}'     2>/dev/null)
      ssh_ro=$( tmate -S "${sock}" display -p '#{tmate_ssh_ro}'  2>/dev/null)
      web_ro=$( tmate -S "${sock}" display -p '#{tmate_web_ro}'  2>/dev/null)
      pid=$(pgrep -f "tmate -S ${sock}" | head -1)
      {
        echo "ssh_url=${ssh_url}"
        echo "web_url=${web_url}"
        echo "ssh_ro=${ssh_ro}"
        echo "web_ro=${web_ro}"
        echo "pid=${pid}"
        echo "started=$(date +%s)"
      } > "${state}"
      chmod 600 "${state}" 2>/dev/null || true
      echo "tmate session started (backgrounded)."
      [ -n "${ssh_url}" ] && echo "  SSH:    ${ssh_url}"
      [ -n "${web_url}" ] && echo "  Web:    ${web_url}"
      [ -n "${ssh_ro}"  ] && echo "  SSH/RO: ${ssh_ro}"
      [ -n "${web_ro}"  ] && echo "  Web/RO: ${web_ro}"
      if [ "${_tm_server}" = "self-hosted" ] && [ -n "${_tm_host}" ]; then
        echo "  Server: ${_tm_host}:${_tm_port:-22} (self-hosted)"
      else
        echo "  Server: tmate.io (public)"
      fi
      echo ""
      echo "  haven tmate status     — print URLs again"
      echo "  haven tmate fg         — attach"
      echo "  haven tmate kill       — tear down"
      echo "  haven tmate configure  — change server"
      ;;

    # ── fallthrough ────────────────────────────────────────────────────────────
    *)
      echo "Usage: haven tmate [start|status|fg|kill|configure]"
      return 1
      ;;
  esac
}

# ── backup: snapshot ~/.haven + ~/.config + ~/.continue via rclone ───────────
cmd_backup() {
  if ! command -v rclone >/dev/null 2>&1; then
    echo "rclone not installed."
    return 1
  fi
  local action="${1:-status}" remote="${2:-}"
  case "${action}" in
    configure)
      # fzf not available: fall back to raw rclone config wizard.
      if ! command -v fzf >/dev/null 2>&1; then
        echo "Launching rclone config — interactive remote setup."
        echo "Common providers: S3, Backblaze B2, Google Drive, Dropbox, SFTP, WebDAV."
        echo "After setup, use: haven backup push <remote:path>"
        echo ""
        rclone config
        echo ""
        echo "Configured remotes:"
        rclone listremotes 2>/dev/null || echo "  (none)"
        return 0
      fi

      local _prov_list _selected _type _name

      # Build provider list from rclone (requires jq), or use curated fallback.
      if command -v jq >/dev/null 2>&1; then
        _prov_list=$(rclone config providers 2>/dev/null \
          | jq -r '.[] | select(.Hide != true) | "\(.Prefix)\t\(.Description)"' \
          | sort \
          | awk -F'\t' '{printf "%-22s %s\n", $1, $2}')
      fi
      if [ -z "${_prov_list}" ]; then
        _prov_list=$(cat <<'FALLBACK'
azureblob              Microsoft Azure Blob Storage
b2                     Backblaze B2
box                    Box
crypt                  Encrypt/Decrypt a remote
drive                  Google Drive
dropbox                Dropbox
ftp                    FTP
gcs                    Google Cloud Storage
jottacloud             Jottacloud
local                  Local Disk
onedrive               Microsoft OneDrive / SharePoint
pcloud                 pCloud
s3                     Amazon S3 Compatible (AWS, Cloudflare R2, Minio, Wasabi…)
seafile                Seafile
sftp                   SSH / SFTP
swift                  OpenStack Swift / Rackspace Cloud Files
union                  Join multiple remotes
webdav                 WebDAV (Nextcloud, ownCloud, etc.)
yandex                 Yandex Disk
zoho                   Zoho WorkDrive
FALLBACK
      )
      fi

      _selected=$(printf '%s\n' "${_prov_list}" \
        | fzf \
            --prompt="Backend > " \
            --header="Select storage backend  (type to filter, Enter to confirm)" \
            --height=60% \
            --layout=reverse \
            --border=rounded \
            --info=inline) \
        || { echo "Cancelled."; return 1; }

      _type=$(printf '%s' "${_selected}" | awk '{print $1}')
      [ -z "${_type}" ] && echo "No backend selected." && return 1

      echo ""
      printf "Remote name (no spaces, e.g. mybackup): "
      IFS= read -r _name
      _name="${_name// /_}"
      [ -z "${_name}" ] && echo "Aborted." && return 1

      # Create the remote skeleton (non-interactive, defaults only).
      # Stdout suppressed — rclone prints noisy "using default for X" messages.
      if ! rclone config create "${_name}" "${_type}" >/dev/null; then
        echo "Failed to create remote '${_name}'. Run 'rclone config' to retry."
        return 1
      fi
      echo ""
      echo "Remote '${_name}' (${_type}) registered."

      # OAuth backends: authenticate via reconnect (opens browser auth flow).
      # Credential backends (S3, SFTP, B2, WebDAV, etc.): launch rclone config
      # — user presses 'e' to edit the newly created remote. The backend
      # selection list is skipped entirely since the remote already exists.
      local _oauth_types="box drive dropbox filefabric hidrive jottacloud mailru onedrive pcloud pikpak putio seafile sharefile sugarsync yandex zoho"
      # shellcheck disable=SC2086  # intentional word-split so grep sees each type as a token
      if printf ' %s ' ${_oauth_types} | grep -q " ${_type} "; then
        echo "Launching OAuth authentication…"
        echo ""
        rclone config reconnect "${_name}:"
      else
        echo "Fill in credentials below — press 'e', then select '${_name}'."
        echo ""
        rclone config
      fi

      echo ""
      echo "Configured remotes:"
      rclone listremotes 2>/dev/null || echo "  (none)"
      echo "Use: haven backup push ${_name}:<path>"
      ;;
    status)
      if [ -n "${remote}" ]; then
        echo "Remote: ${remote}"
        rclone size "${remote}" 2>/dev/null || echo "  (could not reach remote)"
        echo ""
        echo "Contents (top-level):"
        rclone lsd "${remote}" 2>/dev/null || true
        echo ""
      fi
      echo "Configured rclone remotes:"
      rclone listremotes 2>/dev/null || echo "  (none — run 'haven backup configure')"
      echo ""
      echo "Local backup paths:"
      du -sh "${HOME}/.haven" "${HOME}/.config" "${HOME}/.continue" "${HOME}/.inferhaven" 2>/dev/null
      ;;
    push)
      [ -z "${remote}" ] && { echo "Usage: haven backup push <remote:path>"; return 1; }
      rclone sync --progress \
        --include "/.haven/**" --include "/.config/**" --include "/.continue/**" --include "/.inferhaven" \
        "${HOME}" "${remote}"
      ;;
    pull)
      [ -z "${remote}" ] && { echo "Usage: haven backup pull <remote:path>"; return 1; }
      rclone sync --progress "${remote}" "${HOME}"
      ;;
    -h|--help|help)
      cat <<'USAGE'
Usage: haven backup <subcommand> [remote:path]

  haven backup configure          Interactive rclone remote setup wizard
  haven backup status             Show local backup paths + configured remotes
  haven backup status <remote:>   Also show size + top-level contents of that remote
  haven backup push <remote:path> Sync ~/.haven, ~/.config, ~/.continue to remote
  haven backup pull <remote:path> Restore from remote
USAGE
      ;;
    *) echo "Usage: haven backup {configure|status [remote:]|push|pull} [remote:path]"; return 1 ;;
  esac
}

# ── sync: re-render coding-assistant configs from the live model list ────────
# Reuses the same _haven_sync / _haven_sync_all driver that runs on first boot
# and after every haven pull/remove.
cmd_sync() {
  local sub="${1:-all}"
  case "${sub}" in
    all|"")
      _haven_sync_all
      ;;
    list)
      echo "Supported tools:"
      for _t in ${HAVEN_SUPPORTED_TOOLS}; do
        echo "  - ${_t}"
      done
      ;;
    -h|--help|help)
      cat <<'USAGE'
Usage: haven sync [<tool>|all|list]

Re-render coding-assistant configs from the current Ollama model list. Each
tool's file is rewritten only if the existing file carries the inferhaven
sentinel (first-line marker or sidecar) — user-owned files are preserved.

  haven sync             # all tools (parallel)
  haven sync all         # same as above
  haven sync opencode    # one tool
  haven sync list        # show supported tools
USAGE
      ;;
    *)
      case " ${HAVEN_SUPPORTED_TOOLS} " in
        *" ${sub} "*) _haven_sync "${sub}" ;;
        *)
          echo "Unknown tool: ${sub}"
          echo "Run 'haven sync list' for supported tools."
          return 1
          ;;
      esac
      ;;
  esac
}

# ── Stack lifecycle (host-only) ───────────────────────────────────────────────
_host_only() {
  echo -e "${YELLOW}[InferHaven]${NC} '$1' manages the Docker stack itself."
  echo "  Run it from the host (where the repo lives):"
  echo "    ./scripts/haven $1"
  exit 1
}

# ── Starship prompt management ────────────────────────────────────────────────
cmd_starship() {
  local subcmd="${1:-}"
  local config="${HOME}/.config/starship.toml"
  local mode_file="${HOME}/.config/haven/starship-mode"

  if ! command -v starship > /dev/null 2>&1; then
    echo ""
    echo -e "  ${YELLOW}Starship is not installed in this workspace.${NC}"
    echo "  (The .env setting INSTALL_STARSHIP controls this at build time.)"
    echo ""
    printf "  Install Starship now with InferHaven defaults? [y/N] "
    read -r answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      curl -sS https://starship.rs/install.sh | sh -s -- --yes
      mkdir -p "$(dirname "$config")"
      if [ ! -f "$config" ] && [ -f /etc/inferhaven/starship.toml ]; then
        cp /etc/inferhaven/starship.toml "$config"
      fi
      mkdir -p "$(dirname "$mode_file")"
      echo "nf" > "$mode_file"
      echo ""
      echo "  Done. Open a new shell to activate Starship."
    fi
    return
  fi

  case "$subcmd" in
    emoji) _starship_set_mode emoji ;;
    nf)    _starship_set_mode nf ;;

    reset)
      if [ ! -f /etc/inferhaven/starship.toml ]; then
        echo "Default template not found at /etc/inferhaven/starship.toml." >&2
        return 1
      fi
      printf "This will overwrite %s with InferHaven defaults. Continue? [y/N] " "$config"
      read -r answer
      [[ "$answer" =~ ^[Yy]$ ]] || return 0
      cp /etc/inferhaven/starship.toml "$config"
      mkdir -p "$(dirname "$mode_file")"
      echo "nf" > "$mode_file"
      echo "Config reset to InferHaven defaults (Nerd Font mode)."
      echo "Open a new shell (or: exec \$SHELL -l) to apply."
      ;;

    edit)
      "${EDITOR:-nano}" "$config"
      ;;

    ""|status)
      local mode="unknown"
      if [ -f "$mode_file" ]; then
        mode=$(cat "$mode_file")
      elif [ -f "$config" ]; then
        grep -q "󰚊" "$config" && mode="nf"
        grep -q "🚢" "$config" && mode="emoji"
      fi
      echo ""
      echo -e "  ${BOLD}Starship prompt${NC}"
      echo "  Version: $(starship --version 2>/dev/null | head -1)"
      echo "  Config:  ${config}"
      echo "  Mode:    ${mode}"
      echo ""
      echo "  Commands: haven starship [emoji|nf|reset|edit]"
      echo ""
      ;;

    *)
      echo "Usage: haven starship [emoji|nf|reset|edit]" >&2
      return 1
      ;;
  esac
}

_starship_set_mode() {
  local mode="$1"
  local config="${HOME}/.config/starship.toml"
  local mode_file="${HOME}/.config/haven/starship-mode"

  if [ ! -f "$config" ]; then
    echo "No starship config found at ${config}." >&2
    echo "Run 'haven starship reset' to create one from the InferHaven default." >&2
    return 1
  fi

  if [ "$mode" = "emoji" ]; then
    if grep -q "🏡 IH" "$config"; then
      echo "Already in emoji mode."
      return 0
    fi
    if ! grep -q "󰚊 IH" "$config"; then
      echo "Badge pattern not found — config may be fully customized." >&2
      echo "Edit manually: haven starship edit" >&2
      return 1
    fi
    sed -i 's/󰚊 IH/🏡 IH/g' "$config"
  else
    if grep -q "󰚊 IH" "$config"; then
      echo "Already in Nerd Font mode."
      return 0
    fi
    if ! grep -q "🏡 IH" "$config"; then
      echo "Badge pattern not found — config may be fully customized." >&2
      echo "Edit manually: haven starship edit" >&2
      return 1
    fi
    sed -i 's/🏡 IH/󰚊 IH/g' "$config"
  fi

  mkdir -p "$(dirname "$mode_file")"
  echo "$mode" > "$mode_file"
  echo "Switched to ${mode} mode. Open a new shell (or: exec \$SHELL -l) to apply."
}

# ── Caddy proxy ───────────────────────────────────────────────────────────────
cmd_caddy() {
  local SUBCMD="${1:-status}"
  local DOMAIN_VAL TLS_MODE_VAL EFFECTIVE_TLS CADDY_RUNNING="false"

  # Read live config from the running container — more reliable than $DOMAIN env
  # var alone, which SSH sessions don't always inherit from container startup.
  local _caddy_name
  _caddy_name="$(_haven_container caddy)"
  if [ -n "$_caddy_name" ]; then
    CADDY_RUNNING="true"
    local _cenv
    _cenv=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$_caddy_name" 2>/dev/null)
    DOMAIN_VAL=$(echo "$_cenv" | grep '^DOMAIN=' | head -1 | cut -d= -f2-)
    TLS_MODE_VAL=$(echo "$_cenv" | grep '^TLS_MODE=' | head -1 | cut -d= -f2-)
  fi

  # Fall back to container env var if docker inspect yielded nothing
  DOMAIN_VAL="${DOMAIN_VAL:-${DOMAIN:-localhost}}"
  TLS_MODE_VAL="${TLS_MODE_VAL:-${TLS_MODE:-auto}}"

  # Resolve effective TLS mode (mirrors entrypoint.sh logic)
  if [ "$TLS_MODE_VAL" = "auto" ]; then
    if [ "$DOMAIN_VAL" = "localhost" ] || \
       echo "$DOMAIN_VAL" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || \
       echo "$DOMAIN_VAL" | grep -qE '^\[.*\]$'; then
      EFFECTIVE_TLS="off"
    elif ! echo "$DOMAIN_VAL" | grep -q '\.' || \
         echo "$DOMAIN_VAL" | grep -qiE '\.(lan|local|home|internal|test|example|invalid|corp|private|arpa)$'; then
      EFFECTIVE_TLS="internal"
    else
      EFFECTIVE_TLS="acme"
    fi
  else
    EFFECTIVE_TLS="$TLS_MODE_VAL"
  fi

  case "$SUBCMD" in
    status)
      if [ "$CADDY_RUNNING" = "false" ]; then
        echo ""
        echo -e "  ${RED}Caddy is not running.${NC} Start with: haven up  (from the host)"
        echo ""
        return 0
      fi
      echo ""
      echo -e "  ${CYAN}Caddy status${NC}"
      echo "    Domain:   ${DOMAIN_VAL}"
      echo "    TLS mode: ${EFFECTIVE_TLS}"
      case "$EFFECTIVE_TLS" in
        off)
          echo "    Certificate: none (plain HTTP)"
          ;;
        internal)
          echo "    Certificate: Caddy self-signed CA (not trusted by default)"
          echo ""
          echo -e "  ${YELLOW}Run 'haven caddy cert' to export the CA and get install instructions.${NC}"
          ;;
        acme)
          echo "    Certificate: Let's Encrypt (publicly trusted)"
          ;;
      esac
      echo ""
      ;;

    cert)
      if [ "$EFFECTIVE_TLS" != "internal" ]; then
        echo ""
        echo -e "  ${YELLOW}No self-signed certificate in use (TLS mode: ${EFFECTIVE_TLS}).${NC}"
        echo "  Nothing to export."
        echo ""
        return 0
      fi

      local _caddy_run
      _caddy_run="$(_haven_container caddy)"
      if [ -z "$_caddy_run" ]; then
        echo -e "${RED}[InferHaven]${NC} Caddy container is not running."
        echo "  Start it with: haven up  (from the host)"
        return 1
      fi

      local CERT_PATH="${HOME}/caddy-root.crt"
      echo ""
      echo -e "  ${CYAN}Exporting Caddy root CA...${NC}"
      docker cp "${_caddy_run}:/data/caddy/pki/authorities/local/root.crt" "$CERT_PATH"
      echo -e "  ${GREEN}✓${NC} Saved to: ${CERT_PATH}"
      echo ""
      echo -e "  ${BOLD}Trust this certificate so your tools can verify HTTPS connections to ${DOMAIN_VAL}.${NC}"
      echo ""
      echo -e "  ${CYAN}macOS:${NC}"
      echo "    sudo security add-trusted-cert -d -r trustRoot \\"
      echo "      -k /Library/Keychains/System.keychain ~/caddy-root.crt"
      echo ""
      echo -e "  ${CYAN}Linux — Debian / Ubuntu:${NC}"
      echo "    sudo cp ~/caddy-root.crt /usr/local/share/ca-certificates/inferhaven-caddy.crt"
      echo "    sudo update-ca-certificates"
      echo ""
      echo -e "  ${CYAN}Linux — RHEL / Fedora / Arch:${NC}"
      echo "    sudo trust anchor --store ~/caddy-root.crt"
      echo ""
      echo -e "  ${CYAN}Windows (run in cmd as Administrator):${NC}"
      echo "    certutil -addstore Root caddy-root.crt"
      echo ""
      echo -e "  ${CYAN}Node.js tools (VS Code extensions — Cline, Continue, etc.):${NC}"
      echo "    Extensions run in VS Code's extension host — a separate Node.js process."
      echo "    terminal.integrated.env.linux only reaches the terminal shell, NOT extensions."
      echo "    NODE_EXTRA_CA_CERTS must be set at the OS level so the extension host sees it."
      echo ""
      echo "    Option A — systemd user env (recommended; works for desktop + terminal launch):"
      echo "      mkdir -p ~/.config/environment.d"
      echo "      echo \"NODE_EXTRA_CA_CERTS=${CERT_PATH}\" >> ~/.config/environment.d/caddy-cert.conf"
      echo "      systemctl --user set-environment NODE_EXTRA_CA_CERTS=${CERT_PATH}"
      echo "      Then fully restart VS Code."
      echo ""
      echo "    Option B — shell profile (works when VS Code is launched from a terminal):"
      echo "      echo 'export NODE_EXTRA_CA_CERTS=${CERT_PATH}' >> ~/.bashrc"
      echo "      Source ~/.bashrc, then launch VS Code from that same terminal."
      echo ""
      echo "    After applying either option, fully restart VS Code (not just Reload Window)."
      echo ""
      echo -e "  ${CYAN}Verify with curl (from your machine, not inside the container):${NC}"
      echo "    curl --cacert /path/to/caddy-root.crt https://${DOMAIN_VAL}/api/tags"
      echo ""
      ;;

    *)
      echo "  Usage: haven caddy [status|cert]"
      echo "    status   Show Caddy TLS mode and domain"
      echo "    cert     Export the Caddy root CA and print trust instructions"
      ;;
  esac
}

# ── Nested devcontainer (dev inside prod) ─────────────────────────────────────
# Resolve a path inside this container to its equivalent on the host docker
# daemon by walking /proc/self/mountinfo. Needed because when this container
# runs `devcontainer up` via the shared docker socket, the daemon receives
# bind-mount sources that must exist on the HOST filesystem, not just here.
_devcontainer_host_path() {
  local target="$1"
  [ -z "$target" ] && return 1
  awk -v target="$target" '
    {
      root = $4
      mp   = $5
      if (target == mp || index(target, mp "/") == 1) {
        len = length(mp)
        if (len > best_len) {
          best_len = len
          best_root = root
          best_mp   = mp
        }
      }
    }
    END {
      if (best_len > 0) {
        if (best_mp == "/") {
          suffix = target
        } else {
          suffix = substr(target, best_len + 1)
        }
        print best_root suffix
      }
    }
  ' /proc/self/mountinfo
}

cmd_devcontainer() {
  local sub="${1:-up}"
  shift || true

  if ! command -v devcontainer >/dev/null 2>&1; then
    echo -e "${RED}[InferHaven]${NC} devcontainer CLI not found in this image."
    echo "  Rebuild the workspace image to pick up @devcontainers/cli."
    exit 1
  fi
  if ! [ -S /var/run/docker.sock ]; then
    echo -e "${RED}[InferHaven]${NC} /var/run/docker.sock not mounted — nested devcontainers"
    echo "  need shared access to the host docker daemon."
    exit 1
  fi

  case "$sub" in
    up)
      local target="${1:-$PWD}"
      shift || true
      target="$(realpath "$target" 2>/dev/null || echo "$target")"

      # Optional flavor/config selection. --flavor <sub> picks
      # $target/.devcontainer/<sub>/devcontainer.json. --config <path>
      # accepts any json path (absolute or relative to $target).
      local flavor_sub="" override_config=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --flavor) shift; flavor_sub="${1:-}"; shift || true ;;
          --config) shift; override_config="${1:-}"; shift || true ;;
          --) shift; break ;;
          *) break ;;
        esac
      done

      local host
      host="$(_devcontainer_host_path "$target")"
      if [ -z "$host" ]; then
        echo -e "${RED}[InferHaven]${NC} Cannot resolve '${target}' to a host path."
        echo "  The path is not under any volume / bind mount visible to this container."
        echo "  Clone the dev repo under /home/haven/projects (which is volume-mounted)"
        echo "  or any other host-backed location, then retry."
        exit 1
      fi

      # Resolve the config path the cli should read. Default: cli's auto-
      # discovery under $target. With --flavor or --config, pass --config
      # explicitly so the cli reads the chosen flavor's devcontainer.json.
      local cfg_path="" cli_config_args=""
      if [ -n "$override_config" ]; then
        case "$override_config" in
          /*) cfg_path="$override_config" ;;
          *) cfg_path="$target/$override_config" ;;
        esac
      elif [ -n "$flavor_sub" ]; then
        cfg_path="$target/.devcontainer/$flavor_sub/devcontainer.json"
      fi
      if [ -n "$cfg_path" ]; then
        if [ ! -f "$cfg_path" ]; then
          echo -e "${RED}[InferHaven]${NC} config not found: ${cfg_path}"
          exit 1
        fi
        cli_config_args="--config $cfg_path"
      fi

      echo -e "${CYAN}[haven devcontainer]${NC} inner path : ${target}"
      echo -e "${CYAN}[haven devcontainer]${NC} host  path : ${host}"
      [ -n "$cfg_path" ] && echo -e "${CYAN}[haven devcontainer]${NC} config     : ${cfg_path}"
      echo ""

      # Use the cli's own JSONC parser via read-configuration to get the
      # merged config — robust to comments + features merging.
      local cfg_json
      # shellcheck disable=SC2086  # $cli_config_args needs word-splitting.
      cfg_json="$(devcontainer read-configuration --workspace-folder "$target" $cli_config_args 2>/dev/null \
                    | jq -c '.mergedConfiguration // .configuration')"
      if [ -z "$cfg_json" ] || [ "$cfg_json" = "null" ]; then
        echo -e "${RED}[InferHaven]${NC} Could not read a devcontainer config under ${target}."
        echo "  Looked for .devcontainer/devcontainer.json and .devcontainer.json."
        echo "  Use --flavor <subdir> or --config <path> to point at a non-default config."
        exit 1
      fi

      # Reject compose-based nested: docker-compose resolves relative paths
      # in volumes: against the compose-file directory and then hands those
      # inner paths to the host daemon, which can't see them. Rewriting the
      # compose file is out of scope for this helper.
      if echo "$cfg_json" | jq -e 'has("dockerComposeFile")' >/dev/null 2>&1; then
        echo -e "${RED}[InferHaven]${NC} Nested compose-based devcontainers aren't supported by"
        echo "  'haven devcontainer up'."
        echo ""
        echo "  Reason: docker-compose resolves relative paths in volumes: against"
        echo "  the compose-file location, then passes them to the host daemon."
        echo "  The compose-file is on a volume-backed inner path that the host"
        echo "  daemon can't see."
        echo ""
        echo "  Workarounds for the inferhaven-inside-inferhaven case:"
        echo "    1. docker compose -f ${host}/docker-compose.codespaces.yml \\"
        echo "                      -p inferhaven-dev up -d"
        echo "    2. Develop InferHaven from your host, not from inside a"
        echo "       running InferHaven workspace."
        exit 1
      fi

      # Build-based: derive containerWorkspaceFolder (devcontainer.json's
      # workspaceFolder, defaulting to /workspaces/<basename>) and inject
      # an explicit workspaceMount with the translated host path as bind
      # source. The cli reads the config from the inner path (visible from
      # this workspace) and tells the host daemon to bind the host path
      # (visible to the daemon).
      local wsf
      wsf="$(echo "$cfg_json" | jq -r --arg t "$target" \
              '.workspaceFolder // ("/workspaces/" + ($t | split("/") | last))')"

      local tmp
      tmp="$(mktemp --suffix=.json)"
      trap 'rm -f "$tmp"' EXIT

      echo "$cfg_json" \
        | jq --arg src "$host" --arg tgt "$wsf" \
              '. + {workspaceMount: ("source=" + $src + ",target=" + $tgt + ",type=bind,consistency=delegated")}' \
        > "$tmp"

      HAVEN_HOST_PROJECT_DIR="$host" \
        devcontainer up --workspace-folder "$target" --override-config "$tmp" "$@"
      ;;
    exec|read-configuration)
      local target="${1:-$PWD}"
      shift || true
      target="$(realpath "$target" 2>/dev/null || echo "$target")"

      # The cli looks up containers by the 'devcontainer.local_folder'
      # label set during `up`. That label is the INNER path (matches what
      # we pass as --workspace-folder at up time), so pass the inner path
      # here too — host paths would not match the label.
      devcontainer "$sub" --workspace-folder "$target" "$@"
      ;;
    down)
      local target="${1:-$PWD}"
      shift || true
      target="$(realpath "$target" 2>/dev/null || echo "$target")"

      # @devcontainers/cli has no 'down' subcommand. Containers it brings
      # up are tagged with devcontainer.local_folder=<workspace-folder>;
      # we find and remove them by that label.
      local ids
      ids="$(docker ps -a --filter "label=devcontainer.local_folder=$target" \
                          --format '{{.ID}}' 2>/dev/null)"
      if [ -z "$ids" ]; then
        echo -e "${YELLOW}[haven devcontainer]${NC} no containers labelled with"
        echo "  devcontainer.local_folder=${target}"
        return 0
      fi
      echo -e "${CYAN}[haven devcontainer]${NC} removing $(echo "$ids" | wc -l) container(s):"
      echo "$ids" | xargs -r docker rm -f
      ;;
    build)
      echo -e "${YELLOW}[haven devcontainer]${NC} 'build' is not nested-safe — the cli passes"
      echo "  the workspace-folder as the docker build context, which only the host"
      echo "  daemon can resolve. Use 'haven devcontainer up' (it builds + starts in"
      echo "  one step) or run 'docker buildx build' from your host instead."
      exit 1
      ;;
    help|--help|-h|"")
      echo ""
      echo -e "  ${CYAN}haven devcontainer${NC} — nested devcontainer helper"
      echo ""
      echo "  Run a devcontainer project inside this workspace, talking to the"
      echo "  host docker daemon via /var/run/docker.sock. The helper reads the"
      echo "  config from the inner path you pass, then injects an explicit"
      echo "  workspaceMount pointing at the matching host path so the daemon's"
      echo "  bind resolves correctly."
      echo ""
      echo -e "  ${BOLD}[path]${NC} is the CLONE DIRECTORY (default: \$PWD), NOT a container name."
      echo ""
      echo "  Usage:"
      echo "    haven devcontainer up    [path] [--flavor <sub>|--config <p>]"
      echo "    haven devcontainer down  [path]"
      echo "    haven devcontainer exec  [path] -- <cmd>"
      echo "    haven devcontainer read-configuration [path]"
      echo ""
      echo "  Flavor / config selection:"
      echo "    --flavor <subdir>      Use [path]/.devcontainer/<subdir>/devcontainer.json"
      echo "    --config <jsonpath>    Use an explicit devcontainer.json (absolute or"
      echo "                           relative to [path]). Wins over --flavor."
      echo "    (neither flag)         Cli auto-discovery — .devcontainer/devcontainer.json"
      echo "                           or .devcontainer.json at the repo root."
      echo ""
      echo "  Examples:"
      echo "    haven devcontainer up .                                         # cwd is the clone"
      echo "    haven devcontainer up ~/projects/try-node"
      echo "    haven devcontainer up ~/projects/my-repo --flavor python        # .devcontainer/python/"
      echo "    haven devcontainer up . --config .devcontainer/alt/devcontainer.json"
      echo ""
      echo "  Supported:"
      echo "    - Build-based devcontainers (image: / build: in devcontainer.json)"
      echo "      such as the official Microsoft examples, claude-code, etc."
      echo ""
      echo "  Not supported (use 'haven nest up' instead):"
      echo "    - Compose-based devcontainers (dockerComposeFile: …). 'haven nest'"
      echo "      generates a translated compose override that the upstream cli"
      echo "      can't produce on its own."
      echo ""
      echo "  Tips:"
      echo "    - Clone target repos under /home/haven/projects so the path is on"
      echo "      a volume / bind the host docker daemon can resolve."
      echo ""
      ;;
    *)
      echo "  Unknown subcommand: $sub"
      echo "  Run 'haven devcontainer help' for usage."
      exit 1
      ;;
  esac
}

# ── Nested InferHaven compose helper (inferhaven-in-inferhaven) ──────────────
# `haven devcontainer up` refuses compose-based projects because docker-compose
# resolves relative volumes against the compose-file dir on the inner FS and
# sends those (inner) paths to the outer docker daemon, which can't see them.
# `haven nest` works around that for inferhaven specifically: translate inner
# clone path to outer-host path via /proc/self/mountinfo, then layer a small
# compose override that replaces the workspace service's `.` binds with the
# absolute host equivalents.
_nest_project() {
  echo "haven-nest-$(basename "$1")"
}

_nest_locate_config() {
  local target="$1" sub="${2:-}"
  if [ -n "$sub" ] && [ -f "$target/.devcontainer/$sub/devcontainer.json" ]; then
    echo "$target/.devcontainer/$sub/devcontainer.json"; return 0
  fi
  [ -f "$target/.devcontainer/devcontainer.json" ] && {
    echo "$target/.devcontainer/devcontainer.json"; return 0; }
  [ -f "$target/.devcontainer.json" ] && {
    echo "$target/.devcontainer.json"; return 0; }
  return 1
}

# Verify the project name derived from <path> actually has a running stack.
# Helps when the user passes a container name (instead of the clone path) and
# we'd otherwise bubble up an opaque `service "workspace" is not running`.
_nest_require_project_running() {
  local proj="$1" target="$2"
  if docker ps --filter "label=com.docker.compose.project=$proj" \
               --format '{{.Names}}' 2>/dev/null | grep -q .; then
    return 0
  fi
  echo -e "${RED}[haven nest]${NC} no running nest stack found for project '${proj}'."
  echo "  target resolved to: ${target}"
  case "$(basename "$target")" in
    haven-nest-*|*-workspace-*|*-ollama-*|*-caddy-*|*-code-server-*)
      echo -e "  ${YELLOW}hint:${NC} the first positional is the CLONE DIRECTORY, not a"
      echo "        container name. Try:"
      echo "          haven nest exec .                      (if cwd is the clone)"
      echo "          haven nest exec ~/projects/inferhaven-dev"
      ;;
    *)
      echo "  Run 'haven nest status all' to see what's actually running."
      ;;
  esac
  exit 1
}

cmd_nest() {
  local sub="${1:-help}"
  shift || true

  case "$sub" in
    up)
      local target="${1:-$PWD}"
      shift || true
      local flavor_sub=""
      if [ "${1:-}" = "--flavor" ]; then
        shift
        flavor_sub="${1:-}"
        shift || true
      fi
      target="$(realpath "$target" 2>/dev/null || echo "$target")"
      if [ ! -d "$target" ]; then
        echo -e "${RED}[haven nest]${NC} path does not exist: ${target}"
        exit 1
      fi

      local host
      host="$(_devcontainer_host_path "$target")"
      if [ -z "$host" ]; then
        echo -e "${RED}[haven nest]${NC} cannot resolve '${target}' to a host path."
        echo "  Clone under /home/haven/projects (a known volume) and retry."
        exit 1
      fi

      local cfg
      if ! cfg="$(_nest_locate_config "$target" "$flavor_sub")"; then
        echo -e "${RED}[haven nest]${NC} no devcontainer.json under ${target}/.devcontainer${flavor_sub:+/$flavor_sub}/"
        exit 1
      fi

      # Use the cli's own JSONC parser. Pass --config so we read the FLAVOR
      # we located, not the cli's default-discovery pick (which is always
      # .devcontainer/devcontainer.json — codespaces). Without this, reading
      # a full-stack flavor config silently fell back to codespaces values
      # and resolved dockerComposeFile against the wrong directory.
      local cfg_json
      cfg_json="$(devcontainer read-configuration --workspace-folder "$target" \
                    --config "$cfg" 2>/dev/null \
                    | jq -c '.configuration')"
      if [ -z "$cfg_json" ] || [ "$cfg_json" = "null" ]; then
        echo -e "${RED}[haven nest]${NC} failed to parse ${cfg}"
        exit 1
      fi

      local compose_files_raw svc workspace_folder
      compose_files_raw="$(echo "$cfg_json" | jq -r '
        if .dockerComposeFile == null then ""
        elif (.dockerComposeFile | type) == "array" then (.dockerComposeFile | join("\n"))
        else .dockerComposeFile end')"
      svc="$(echo "$cfg_json" | jq -r '.service // "workspace"')"
      workspace_folder="$(echo "$cfg_json" | jq -r '.workspaceFolder // "/home/haven/projects/inferhaven-core"')"

      if [ -z "$compose_files_raw" ]; then
        echo -e "${RED}[haven nest]${NC} ${cfg} has no dockerComposeFile."
        echo "  For build-based projects use 'haven devcontainer up'."
        exit 1
      fi

      # Resolve compose paths against the devcontainer.json dir per spec.
      local cfg_dir compose_args=""
      cfg_dir="$(dirname "$cfg")"
      while IFS= read -r cf; do
        [ -z "$cf" ] && continue
        case "$cf" in
          /*) ;;
          *) cf="$cfg_dir/$cf" ;;
        esac
        cf="$(realpath "$cf" 2>/dev/null || echo "$cf")"
        compose_args="$compose_args -f $cf"
      done <<< "$compose_files_raw"

      # Flavor heuristic — codespaces compose mounts workspace_home at
      # /home/haven; full-stack mounts it at /home (override file).
      local workspace_home_target="/home"
      if echo "$compose_files_raw" | grep -q codespaces; then
        workspace_home_target="/home/haven"
      fi

      # Reuse the outer workspace's already-built image if we can identify it
      # via /proc/self/mountinfo + docker inspect. Falls back to a sensible
      # default name; if neither exists locally, compose will rebuild.
      local outer_image="inferhaven-workspace:latest"
      local self_id
      self_id="$(_haven_resolve_self_container_id 2>/dev/null)"
      if [ -n "$self_id" ]; then
        local detected
        detected="$(docker inspect --format '{{.Config.Image}}' "$self_id" 2>/dev/null)"
        [ -n "$detected" ] && [ "$detected" != "<no value>" ] && outer_image="$detected"
      fi

      local proj
      proj="$(_nest_project "$target")"

      # Detect the full-stack flavor by signature of its compose-file list
      # or config path. The full-stack override pins literal container_name
      # / network name / volume name = inferhaven-dev-* — without rewriting
      # them, nesting under a real full-stack outer collides on every
      # name. The codespaces compose declares no such literals, so the
      # auto-namespace via `-p $proj` already isolates it cleanly.
      local is_full_stack=0
      case "${cfg}|${compose_files_raw}" in
        *full-stack*|*devcontainer.override*) is_full_stack=1 ;;
      esac

      local tmp
      tmp="$(mktemp --suffix=.yml)"
      trap "rm -f '$tmp'" EXIT
      cat > "$tmp" <<EOF
###############################################################################
# haven nest auto-generated override
#   target service:    ${svc}
#   inner clone:       ${target}
#   host path:         ${host}
#   workspaceFolder:   ${workspace_folder}
#   outer image reuse: ${outer_image}
#   full-stack patch:  ${is_full_stack}
###############################################################################
services:
  ${svc}:
    image: ${outer_image}
    container_name: ${proj}-${svc}
    volumes: !override
      - workspace_home:${workspace_home_target}
      - ${host}:${workspace_folder}
      - ${host}:/opt/inferhaven:ro
      - /var/run/docker.sock:/var/run/docker.sock
EOF

      # Full-stack-only: re-namespace every literal that the override file
      # hardcodes to inferhaven-dev-*. Without these the inner stack tries
      # to create container_name=inferhaven-dev-ollama, network=inferhaven-dev,
      # volume=inferhaven_dev_workspace_home, etc., which already exist on
      # the outer host.
      if [ "$is_full_stack" = 1 ]; then
        cat >> "$tmp" <<EOF
  ollama:
    container_name: ${proj}-ollama
  code-server:
    container_name: ${proj}-code-server
  caddy:
    container_name: ${proj}-caddy
  haven-agent:
    container_name: ${proj}-haven-agent

networks:
  inferhaven:
    name: ${proj}_inferhaven

volumes:
  ollama_data:
    name: ${proj}_ollama_data
  workspace_home:
    name: ${proj}_workspace_home
  code_server_data:
    name: ${proj}_code_server_data
  caddy_data:
    name: ${proj}_caddy_data
  caddy_config:
    name: ${proj}_caddy_config
  projects:
    name: ${proj}_projects
EOF
      fi

      echo -e "${CYAN}[haven nest]${NC} inner:   ${target}"
      echo -e "${CYAN}[haven nest]${NC} host:    ${host}"
      echo -e "${CYAN}[haven nest]${NC} project: ${proj}"
      echo -e "${CYAN}[haven nest]${NC} compose:"
      printf '%s\n' $compose_args | grep -v '^-f$' | sed 's/^/    /'
      echo ""

      # shellcheck disable=SC2086
      docker compose $compose_args -f "$tmp" -p "$proj" up -d "$@"
      ;;

    down)
      local target="${1:-$PWD}"
      shift || true
      target="$(realpath "$target" 2>/dev/null || echo "$target")"
      local proj
      proj="$(_nest_project "$target")"
      _nest_require_project_running "$proj" "$target"
      docker compose -p "$proj" down "$@"
      ;;

    exec)
      local target="${1:-$PWD}"
      shift || true
      target="$(realpath "$target" 2>/dev/null || echo "$target")"
      # Allow `haven nest exec <path> -- <cmd …>` syntax; docker compose exec
      # doesn't want a literal `--` in argv.
      [ "${1:-}" = "--" ] && shift
      local proj
      proj="$(_nest_project "$target")"
      _nest_require_project_running "$proj" "$target"

      # Land in the devcontainer's workspaceFolder rather than the image
      # WORKDIR (which is /home/haven). Read the workspaceFolder off the
      # cloned project's config — try each known flavor location so this
      # works whether the user nested via codespaces or a flavor subdir.
      local wsf="" _flavor_cfg
      for _flavor_cfg in \
          "$target/.devcontainer/devcontainer.json" \
          "$target/.devcontainer.json" \
          "$target"/.devcontainer/*/devcontainer.json
      do
        [ -f "$_flavor_cfg" ] || continue
        wsf="$(devcontainer read-configuration --workspace-folder "$target" \
                 --config "$_flavor_cfg" 2>/dev/null \
                 | jq -r '.configuration.workspaceFolder // empty')"
        [ -n "$wsf" ] && break
      done
      [ -z "$wsf" ] && wsf="/home/haven/projects/inferhaven-core"

      docker compose -p "$proj" exec -u haven -w "$wsf" workspace "$@"
      ;;

    logs)
      local target="${1:-$PWD}"
      shift || true
      target="$(realpath "$target" 2>/dev/null || echo "$target")"
      local proj
      proj="$(_nest_project "$target")"
      _nest_require_project_running "$proj" "$target"
      docker compose -p "$proj" logs -f --tail=100 "$@"
      ;;

    status|ps|ls)
      case "${1:-}" in
        ""|all)
          # Project labels are authoritative — explicit container_name:
          # directives in flavor overrides (e.g. inferhaven-dev-* in the
          # full-stack override) defeat the `name=^haven-nest-` prefix
          # filter, but the compose project label always starts with
          # haven-nest- because that's what we pass via -p at up time.
          local _ids
          _ids="$(docker ps -aq --filter "label=com.docker.compose.project" 2>/dev/null \
                  | xargs -r docker inspect --format \
                      '{{index .Config.Labels "com.docker.compose.project"}}|{{.Name}}|{{.State.Status}}|{{.Config.Image}}' 2>/dev/null \
                  | awk -F'|' '$1 ~ /^haven-nest-/ {sub("^/", "", $2); printf "%-50s %-15s %s\n", $2, $3, $4}')"
          if [ -z "$_ids" ]; then
            echo "(no nested stacks running)"
          else
            printf '%-50s %-15s %s\n' NAME STATUS IMAGE
            printf '%s\n' "$_ids"
          fi
          ;;
        *)
          local target proj
          target="$(realpath "$1" 2>/dev/null || echo "$1")"
          proj="$(_nest_project "$target")"
          docker compose -p "$proj" ps
          ;;
      esac
      ;;

    help|--help|-h|"")
      echo ""
      echo -e "  ${CYAN}haven nest${NC} — nested InferHaven compose helper"
      echo ""
      echo "  Spin up a second InferHaven stack from a cloned repo inside the"
      echo "  running outer workspace. 'haven devcontainer up' refuses compose-"
      echo "  based projects because docker-compose passes inner paths to the"
      echo "  outer daemon. 'haven nest' generates a compose override that"
      echo "  rewrites workspace binds to translated host paths."
      echo ""
      echo -e "  ${BOLD}<path>${NC} is always the CLONE DIRECTORY (e.g. '.', '~/projects/foo'),"
      echo "  NOT a container name. Compose project name is derived from it as"
      echo "  haven-nest-<basename>."
      echo ""
      echo "  Usage:"
      echo "    haven nest up    <path> [--flavor <subdir>]   Build/start stack"
      echo "    haven nest down  <path>                       Tear down + remove"
      echo "    haven nest exec  <path> -- <cmd>              Exec inside workspace (-u haven)"
      echo "    haven nest logs  <path> [svc]                 Tail logs"
      echo "    haven nest status [<path>|all]                Show nested stacks"
      echo ""
      echo "  Flavor / config selection:"
      echo "    haven nest up <path>                          .devcontainer/devcontainer.json"
      echo "    haven nest up <path> --flavor full-stack      .devcontainer/full-stack/devcontainer.json"
      echo "    haven nest up <path> --flavor <sub>           .devcontainer/<sub>/devcontainer.json"
      echo ""
      echo "  Examples:"
      echo "    cd ~/projects/inferhaven-dev && haven nest up ."
      echo "    haven nest up ~/projects/inferhaven-dev --flavor full-stack"
      echo "    haven nest exec ~/projects/inferhaven-dev -- bash -c 'cd /home/haven/projects/inferhaven-core && haven doctor'"
      echo "    haven nest logs ~/projects/inferhaven-dev workspace"
      echo "    haven nest status all"
      echo "    haven nest down ~/projects/inferhaven-dev"
      echo ""
      echo "  Notes:"
      echo "    - Reuses the outer workspace image if visible (skips rebuild)."
      echo "    - Build-based projects (no dockerComposeFile) use 'haven devcontainer up'."
      echo ""
      ;;

    *)
      echo "  Unknown subcommand: $sub"
      echo "  Run 'haven nest help' for usage."
      exit 1
      ;;
  esac
}

# ── Route command ─────────────────────────────────────────────────────────────
case "${1:-help}" in
  # Ollama model operations
  models)         cmd_models ;;
  pull)           shift; cmd_pull "$@" ;;
  pullback)       shift; cmd_pullback "$@" ;;
  _pullback_worker) shift; _pullback_worker "$@" ;;  # internal — not user-facing
  remove|rm)      shift; cmd_remove "$@" ;;
  show)           shift; cmd_show "$@" ;;
  ps)             cmd_ps ;;
  unload)         shift; cmd_unload "$@" ;;
  cp|copy)        shift; cmd_cp "$@" ;;
  params)         shift; cmd_params "$@" ;;
  tune)           shift; cmd_tune "$@" ;;
  untune)         shift; cmd_untune "$@" ;;
  chat)           shift; cmd_chat "$@" ;;
  run)            shift; cmd_run "$@" ;;
  push)           shift; cmd_push "$@" ;;
  signin|login)   shift; cmd_signin "$@" ;;
  signout|logout) shift; cmd_signout "$@" ;;

  # Status / logs
  status)         cmd_status ;;
  logs)           shift; cmd_logs "$@" ;;

  # SSH / IDE
  ssh-key)        shift; cmd_ssh_key "$@" ;;
  ssh)            cmd_ssh ;;
  ide)            cmd_ide ;;

  # Tmux workspace management
  tmux)           shift; cmd_tmux "$@" ;;
  session)        shift; cmd_session "$@" ;;  # backward-compat alias

  # Package management
  apt)            shift; cmd_apt "$@" ;;

  # Coding assistants
  harness)        cmd_harness ;;
  claude)         cmd_claude ;;
  aider)          cmd_aider ;;
  goose)          cmd_goose ;;
  qwen)           cmd_qwen ;;

  # Starship prompt
  starship)       shift; cmd_starship "$@" ;;

  # Caddy proxy
  caddy)          shift; cmd_caddy "$@" ;;

  # Service / system introspection
  service)        shift; cmd_service "$@" ;;
  limits)         cmd_limits ;;
  gpu-info|gpu)   cmd_gpu_info ;;

  # Pair-programming + backup
  tmate)          shift; cmd_tmate "$@" ;;
  backup)         shift; cmd_backup "$@" ;;

  # Nested devcontainer helper (dev-inside-prod, build-based projects)
  devcontainer)   shift; cmd_devcontainer "$@" ;;
  # Nested InferHaven compose helper (compose-based, inferhaven-in-inferhaven)
  nest)           shift; cmd_nest "$@" ;;

  # Tool-config sync (re-render coding-assistant configs)
  sync)           shift; cmd_sync "$@" ;;

  # Diagnostics
  doctor)         cmd_doctor ;;
  version)        echo "InferHaven v${VERSION}" ;;
  help)           cmd_help ;;

  # Stack lifecycle — host only
  up|down|restart|reset|update) _host_only "$1" ;;

  *)              cmd_help ;;
esac