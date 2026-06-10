#!/bin/bash
###############################################################################
# InferHaven Workspace — Entrypoint Script
# Sets up SSH keys, user environment, supercronic, and starts the SSH server.
###############################################################################
set -e

HAVEN_USER="${HAVEN_USER:-haven}"
HOME_DIR="/home/${HAVEN_USER}"
SSH_DIR="${HOME_DIR}/.ssh"
INIT_SENTINEL="${HOME_DIR}/.haven/.initialized"

# All extra users (HAVEN_EXTRA_USERS=alice,bob) provisioned alongside haven.
# Single /home volume mount required when EXTRA_USERS set — see docker-compose.yml.
ALL_HAVEN_USERS=( "${HAVEN_USER}" )
if [ -n "${HAVEN_EXTRA_USERS:-}" ]; then
  IFS=',' read -ra _extras <<< "${HAVEN_EXTRA_USERS}"
  for _u in "${_extras[@]}"; do
    _u="${_u// /}"
    [ -n "${_u}" ] && ALL_HAVEN_USERS+=( "${_u}" )
  done
fi

echo "[InferHaven] Initializing workspace..."

# ── Shared tmpfs cache dir (status bar + popup + model cache) ───────────────
# /run is tmpfs and owned by root. Pre-create /run/haven world-writable with
# the sticky bit so haven + alice + bob can all atomic-write cache files
# (last-metrics.tsv, last-popup-gpu.tsv, models.json) without permission errors.
mkdir -p /run/haven
chmod 1777 /run/haven

# ── Volume layout migration (old :/home/haven → new :/home) ──────────────────
# Detect flat layout: workspace_home mounted at /home but contents are haven
# home dirs at the root (no /home/haven subdir, but /home/.zshrc/etc exists).
if mountpoint -q /home 2>/dev/null \
   && [ ! -d "${HOME_DIR}" ] \
   && { [ -f /home/.zshrc ] || [ -d /home/.config ] || [ -d /home/.haven ]; }; then
  echo "[InferHaven] Detected legacy volume layout — running haven-migrate-home..."
  /usr/local/bin/haven-migrate-home || \
    echo "[InferHaven] Migration script returned non-zero — see /home/.migrate-home-staging."
fi

# ── Sentinel: cold vs warm boot detection ────────────────────────────────────
# First boot OR upgrade (sentinel missing) → run full chown + dir bootstrap.
# Warm boot (sentinel present + ownership intact) → fast-path, skip recursive work.
_warm_boot=0
_cold_reason=""
if [ ! -f "${INIT_SENTINEL}" ]; then
  _cold_reason="sentinel missing (${INIT_SENTINEL})"
elif [ "$(stat -c %U "${HOME_DIR}/.local" 2>/dev/null || echo missing)" != "${HAVEN_USER}" ]; then
  _cold_reason="ownership drift on ${HOME_DIR}/.local"
else
  _warm_boot=1
  echo "[InferHaven] Warm boot — sentinel + ownership ok, skipping full chown."
fi

if [ "${_warm_boot}" -eq 0 ]; then
  echo "[InferHaven] Cold boot — ${_cold_reason}; running first-time setup..."
  chown -R "${HAVEN_USER}:${HAVEN_USER}" "${HOME_DIR}"
  chmod 755 "${HOME_DIR}"

  # Pre-create standard tool directories — required before assistant installers run.
  for _dir in \
      "${HOME_DIR}/.npm-global/bin" \
      "${HOME_DIR}/.local/bin" \
      "${HOME_DIR}/.local/lib" \
      "${HOME_DIR}/.local/share" \
      "${HOME_DIR}/.config/claude" \
      "${HOME_DIR}/.config/opencode" \
      "${HOME_DIR}/.haven" \
      "${HOME_DIR}/.haven/downloads" \
      "${HOME_DIR}/.cache" \
      "${HOME_DIR}/.aider" \
      "${HOME_DIR}/.gemini" \
      "${HOME_DIR}/.opencode" \
      "${HOME_DIR}/.qwen" \
      "${HOME_DIR}/.pi/agent" \
      "${HOME_DIR}/.config/goose" \
      "${HOME_DIR}/.continue" \
      "${HOME_DIR}/.config/nvim/lua/plugins"; do
      mkdir -p "${_dir}"
      chown "${HAVEN_USER}:${HAVEN_USER}" "${_dir}"
  done

  touch "${HOME_DIR}/.apt-packages"
  chown "${HAVEN_USER}:${HAVEN_USER}" "${HOME_DIR}/.apt-packages"
  chmod 644 "${HOME_DIR}/.apt-packages"
fi

# ── Shell profile sourcing (idempotent — safe on warm boots too) ────────────
BASH_PROFILE="${HOME_DIR}/.bash_profile"
if ! grep -q 'inferhaven' "${BASH_PROFILE}" 2>/dev/null; then
  cat > "${BASH_PROFILE}" << 'BASH_PROFILE_CONTENT'
# InferHaven Workspace — Bash Login Profile
[ -f ~/.inferhaven ] && . ~/.inferhaven
BASH_PROFILE_CONTENT
  chown "${HAVEN_USER}:${HAVEN_USER}" "${BASH_PROFILE}"
  chmod 644 "${BASH_PROFILE}"
fi
ZPROFILE="${HOME_DIR}/.zprofile"
if ! grep -q 'inferhaven' "${ZPROFILE}" 2>/dev/null; then
  cat > "${ZPROFILE}" << 'ZPROFILE_CONTENT'
# InferHaven Workspace — Zsh Login Profile
[[ -f ~/.inferhaven ]] && source ~/.inferhaven
ZPROFILE_CONTENT
  chown "${HAVEN_USER}:${HAVEN_USER}" "${ZPROFILE}"
  chmod 644 "${ZPROFILE}"
fi

# ── SSH host keys (persisted in volume — survive rebuilds) ───────────────────
mkdir -p "${SSH_DIR}"
chown "${HAVEN_USER}:${HAVEN_USER}" "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

SSH_HOSTKEY_DIR="${SSH_DIR}/host_keys"
mkdir -p "${SSH_HOSTKEY_DIR}"
chown "${HAVEN_USER}:${HAVEN_USER}" "${SSH_HOSTKEY_DIR}"
chmod 700 "${SSH_HOSTKEY_DIR}"

if [ ! -f "${SSH_HOSTKEY_DIR}/ssh_host_ed25519_key" ]; then
  echo "[InferHaven] Generating SSH host keys..."
  ssh-keygen -q -t ed25519 -f "${SSH_HOSTKEY_DIR}/ssh_host_ed25519_key" -N ""
  ssh-keygen -q -t rsa    -b 3072 -f "${SSH_HOSTKEY_DIR}/ssh_host_rsa_key"    -N ""
fi

install -m 600 "${SSH_HOSTKEY_DIR}/ssh_host_ed25519_key"     /etc/ssh/ssh_host_ed25519_key
install -m 644 "${SSH_HOSTKEY_DIR}/ssh_host_ed25519_key.pub" /etc/ssh/ssh_host_ed25519_key.pub
install -m 600 "${SSH_HOSTKEY_DIR}/ssh_host_rsa_key"         /etc/ssh/ssh_host_rsa_key
install -m 644 "${SSH_HOSTKEY_DIR}/ssh_host_rsa_key.pub"     /etc/ssh/ssh_host_rsa_key.pub
chown root:root /etc/ssh/ssh_host_*

# ── Authorized keys for haven user ───────────────────────────────────────────
if [ -n "${AUTHORIZED_KEYS}" ]; then
  printf '%s\n' "${AUTHORIZED_KEYS}" > "${SSH_DIR}/authorized_keys"
  chown "${HAVEN_USER}:${HAVEN_USER}" "${SSH_DIR}/authorized_keys"
  chmod 600 "${SSH_DIR}/authorized_keys"
fi

chown -R "${HAVEN_USER}:${HAVEN_USER}" "${HOME_DIR}/projects" 2>/dev/null || true

# ── Multi-user provisioning (HAVEN_EXTRA_USERS=alice,bob) ────────────────────
# Each extra user gets: home dir, zsh shell, sudo (opt-in), SSH key from
# AUTHORIZED_KEYS_<USERUC>, own ~/.inferhaven (skeleton).
#
# Wrapped in a subshell + `|| true` so a failure on any one user (e.g. UID
# clash on warm restart, fs error) does NOT abort the entrypoint under set -e.
_provision_extra_user() (
  set +e
  local user="$1"
  local user_uc; user_uc=$(printf '%s' "${user}" | tr '[:lower:]' '[:upper:]')
  local home="/home/${user}"
  if ! id -u "${user}" >/dev/null 2>&1; then
    echo "[InferHaven] Creating extra user: ${user}"
    useradd -m -s /bin/zsh "${user}" 2>/dev/null || \
      { echo "[InferHaven] useradd failed for ${user} — skipping."; return 0; }
  fi

  # Optional sudo via HAVEN_EXTRA_USERS_SUDO=alice,bob
  if [ -n "${HAVEN_EXTRA_USERS_SUDO:-}" ]; then
    case ",${HAVEN_EXTRA_USERS_SUDO}," in
      *",${user},"*) echo "${user} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${user}" 2>/dev/null ;;
    esac
  fi

  mkdir -p "${home}/.ssh" "${home}/.haven" "${home}/.local/bin" "${home}/projects" 2>/dev/null
  chown -R "${user}:${user}" "${home}" 2>/dev/null
  chmod 700 "${home}/.ssh" 2>/dev/null

  local key_var="AUTHORIZED_KEYS_${user_uc}"
  local key_val="${!key_var:-}"
  if [ -n "${key_val}" ]; then
    printf '%s\n' "${key_val}" > "${home}/.ssh/authorized_keys.auto"
    chown "${user}:${user}" "${home}/.ssh/authorized_keys.auto" 2>/dev/null
    chmod 600 "${home}/.ssh/authorized_keys.auto" 2>/dev/null
  fi

  if [ ! -f "${home}/.inferhaven" ]; then
    cat > "${home}/.inferhaven" << EOF
# InferHaven environment (extra user: ${user})
export OLLAMA_HOST="${OLLAMA_HOST:-http://ollama:11434}"
export INFERHAVEN_VERSION="0.1.0"
EOF
    chown "${user}:${user}" "${home}/.inferhaven" 2>/dev/null
    chmod 600 "${home}/.inferhaven" 2>/dev/null
  fi
)

# Pre-flight: HAVEN_EXTRA_USERS only works when the workspace_home volume is
# mounted at /home (so each user's home persists). The legacy mount point of
# /home/haven puts extra-user homes inside the container layer — they vanish on
# rebuild. Detect by checking if /home itself is a mountpoint; if not, refuse
# to provision and tell the user to migrate.
if [ "${#ALL_HAVEN_USERS[@]}" -gt 1 ]; then
  if ! mountpoint -q /home 2>/dev/null; then
    echo "[InferHaven] WARNING: HAVEN_EXTRA_USERS is set but /home is not a volume mount." >&2
    echo "[InferHaven]   Extra-user homes would be wiped on rebuild. Skipping provisioning." >&2
    echo "[InferHaven]   Migrate via: scripts/haven-migrate-home.sh (one-time)." >&2
  else
    for _u in "${ALL_HAVEN_USERS[@]:1}"; do
      _provision_extra_user "${_u}" || true
    done
  fi
fi

# ── Docker socket permissions (all users in docker group) ───────────────────
# docker-ce-cli apt package does not create the `docker` group, so we must
# create it ourselves on first boot, matching the host socket's GID. Without
# this, `usermod -aG docker` silently no-ops and `docker ps` returns EACCES.
if [ -S /var/run/docker.sock ]; then
  DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
  if getent group docker >/dev/null 2>&1; then
    groupmod -g "${DOCKER_GID}" docker 2>/dev/null || true
  else
    groupadd -g "${DOCKER_GID}" docker 2>/dev/null || true
  fi
  for _u in "${ALL_HAVEN_USERS[@]}"; do
    usermod -aG docker "${_u}" 2>/dev/null || true
  done
fi

# ── npm global prefix (warm-boot fallback for older volumes) ────────────────
if ! grep -q '^prefix=' "${HOME_DIR}/.npmrc" 2>/dev/null; then
  echo "prefix=${HOME_DIR}/.npm-global" >> "${HOME_DIR}/.npmrc"
  chown "${HAVEN_USER}:${HAVEN_USER}" "${HOME_DIR}/.npmrc"
fi
chown -R "${HAVEN_USER}:${HAVEN_USER}" "${HOME_DIR}/.npm-global" 2>/dev/null || true

# ── Configure coding assistant credentials (every boot — env may have changed) ──
HOME_DIR="${HOME_DIR}" HAVEN_USER="${HAVEN_USER}" \
    /usr/local/bin/configure-assistants.sh

# Pre-create Aider model settings file so haven-sync can write to it.
touch "${HOME_DIR}/.aider.model.settings.yml"
chown "${HAVEN_USER}:${HAVEN_USER}" "${HOME_DIR}/.aider.model.settings.yml" 2>/dev/null || true

# ── Copy Starship default config on first start ─────────────────────────────
mkdir -p "${HOME_DIR}/.config"
if [ ! -f "${HOME_DIR}/.config/starship.toml" ] \
    && [ -f /etc/inferhaven/starship.toml ]; then
  cp /etc/inferhaven/starship.toml "${HOME_DIR}/.config/starship.toml"
  chown "${HAVEN_USER}:${HAVEN_USER}" "${HOME_DIR}/.config/starship.toml"
fi

# ── Tmux plugin dir setup (Dockerfile bakes plugins; recreate dirs only) ────
mkdir -p "${HOME_DIR}/.tmux/plugins" "${HOME_DIR}/.tmux/resurrect"
_retain="${TMUX_RESURRECT_RETAIN_DAYS:-7}"
find "${HOME_DIR}/.tmux/resurrect" -name 'tmux_resurrect_*.txt' -mtime +"${_retain}" \
  -delete 2>/dev/null || true

# ── Final ownership pass (only on cold boot — sentinel-gated) ───────────────
if [ "${_warm_boot}" -eq 0 ]; then
  chown -R "${HAVEN_USER}:${HAVEN_USER}" "${HOME_DIR}"
  mkdir -p "$(dirname "${INIT_SENTINEL}")"
  touch "${INIT_SENTINEL}"
  chown "${HAVEN_USER}:${HAVEN_USER}" "${INIT_SENTINEL}"
fi

# ── Dotfiles bootstrap (DOTFILES_REPO=https://github.com/<u>/dotfiles.git) ──
DOTFILES_SENTINEL="${HOME_DIR}/.haven/.dotfiles-installed"
if [ -n "${DOTFILES_REPO:-}" ] && [ ! -f "${DOTFILES_SENTINEL}" ]; then
  echo "[InferHaven] Bootstrapping dotfiles from ${DOTFILES_REPO}..."
  su -s /bin/bash "${HAVEN_USER}" -c "
    cd ~ && git clone --depth=1 '${DOTFILES_REPO}' .dotfiles 2>&1
    if [ -x ~/.dotfiles/install.sh ]; then
      ~/.dotfiles/install.sh 2>&1
    elif [ -x ~/.dotfiles/setup.sh ]; then
      ~/.dotfiles/setup.sh 2>&1
    fi
  " >> "${HOME_DIR}/.haven/install.log" 2>&1 || \
    echo "[InferHaven] Dotfiles bootstrap had errors — see install.log"
  touch "${DOTFILES_SENTINEL}"
  chown "${HAVEN_USER}:${HAVEN_USER}" "${DOTFILES_SENTINEL}"
fi

# ── Auto-install coding assistants (background, runs as haven user) ─────────
if [ -n "${INSTALL_ASSISTANTS:-}" ]; then
    INSTALL_LOG="${HOME_DIR}/.haven/install.log"
    touch "${INSTALL_LOG}"
    chown "${HAVEN_USER}:${HAVEN_USER}" "${INSTALL_LOG}"
    (
        su -s /bin/bash "${HAVEN_USER}" -c \
            "HOME='${HOME_DIR}' INSTALL_ASSISTANTS='${INSTALL_ASSISTANTS}' \
             exec /usr/local/bin/install-assistants.sh" \
            >> "${INSTALL_LOG}" 2>&1
    ) &
    echo "[InferHaven] Installing assistants in background: ${INSTALL_ASSISTANTS}"
fi

# ── Auto-tune default model (background) ────────────────────────────────────
if [ "${HAVEN_AUTO_TUNE:-1}" != "0" ] && [ -n "${DEFAULT_MODEL:-}" ]; then
  INSTALL_LOG="${HOME_DIR}/.haven/install.log"
  touch "${INSTALL_LOG}" 2>/dev/null || true
  chown "${HAVEN_USER}:${HAVEN_USER}" "${INSTALL_LOG}" 2>/dev/null || true
  (
    attempts=0; max_attempts=72
    while [ "${attempts}" -lt "${max_attempts}" ]; do
      if curl -sf "http://ollama:11434/api/tags" 2>/dev/null \
         | grep -q "\"${DEFAULT_MODEL}\"" 2>/dev/null; then
        echo "[InferHaven] Auto-tuning ${DEFAULT_MODEL}..."
        su -s /bin/bash "${HAVEN_USER}" -c \
          "OLLAMA_HOST='http://ollama:11434' HAVEN_AUTO_TUNE=0 HAVEN_CTX='${HAVEN_CTX:-32768}' haven tune '${DEFAULT_MODEL}'" \
          >> "${INSTALL_LOG}" 2>&1 \
          && echo "[InferHaven] ${DEFAULT_MODEL} tuned." \
          || echo "[InferHaven] Auto-tune failed. Run: haven tune ${DEFAULT_MODEL}"
        break
      fi
      attempts=$(( attempts + 1 ))
      sleep 5
    done
    if [ "${attempts}" -ge "${max_attempts}" ]; then
      echo "[InferHaven] WARNING: DEFAULT_MODEL '${DEFAULT_MODEL}' not found in Ollama after $((max_attempts * 5))s. Check the model name or pull it with: haven pull '${DEFAULT_MODEL}'"
    fi
  ) >> "${INSTALL_LOG}" 2>&1 &
fi

# ── Metrics server (background, root for Docker socket access) ──────────────
node /usr/local/bin/metrics-server.js >> "${HOME_DIR}/.haven/install.log" 2>&1 &
METRICS_PID=$!

# ── Alert watcher ────────────────────────────────────────────────────────────
(
    su -s /bin/bash "${HAVEN_USER}" -c \
        "HOME='${HOME_DIR}' exec /usr/local/bin/inferhaven-alert-watcher" \
        >> "${HOME_DIR}/.haven/install.log" 2>&1
) &

# ── Restore custom apt repos ─────────────────────────────────────────────────
REPO_DIR="${HOME_DIR}/.apt-repos"
mkdir -p "${REPO_DIR}"
for _listfile in "${REPO_DIR}"/*.list; do
  [ -f "${_listfile}" ] || continue
  cp "${_listfile}" /etc/apt/sources.list.d/
done
for _gpgfile in "${REPO_DIR}"/*.gpg; do
  [ -f "${_gpgfile}" ] || continue
  cp "${_gpgfile}" /etc/apt/keyrings/
done

# ── Reinstall persistent user packages (background) ──────────────────────────
PKG_FILE="${HOME_DIR}/.apt-packages"
(
  _lists_stale() {
    local cache="/var/cache/apt/pkgcache.bin"
    [ ! -f "${cache}" ] && return 0
    local age=$(( $(date +%s) - $(stat -c %Y "${cache}" 2>/dev/null || echo 0) ))
    [ "${age}" -ge 86400 ]
  }
  if _lists_stale; then
    echo "[InferHaven] Refreshing apt package lists..."
    apt-get update -qq 2>&1
  fi
  if [ -s "${PKG_FILE}" ]; then
    echo "[InferHaven] Restoring persistent packages in background..."
    xargs apt-get install -y --no-install-recommends -qq < "${PKG_FILE}" 2>&1 \
      && echo "[InferHaven] Persistent packages ready." \
      || echo "[InferHaven] Warning: some packages failed to install." >&2
  fi
) &

# ── Bootstrap Haven tmux session ─────────────────────────────────────────────
TMUX_BOOT_LOG="${HOME_DIR}/.haven/tmux-boot.log"
touch "${TMUX_BOOT_LOG}" 2>/dev/null || true
chown "${HAVEN_USER}:${HAVEN_USER}" "${TMUX_BOOT_LOG}" 2>/dev/null || true

(
  sleep 2
  _log() { echo "[$(date '+%H:%M:%S')] $*" >> "${TMUX_BOOT_LOG}" 2>/dev/null || true; }
  _log "tmux bootstrap starting"

  su -s /bin/zsh "${HAVEN_USER}" -c "
    _log() { echo \"[\$(date '+%H:%M:%S')] \$*\" >> '${TMUX_BOOT_LOG}' 2>/dev/null || true; }

    tmux start-server 2>>'${TMUX_BOOT_LOG}' || true
    tmux set-option -g exit-empty off 2>/dev/null || true
    # Capture visible pane scrollback on save so 'haven tmux restore' brings
    # back the terminal output you were looking at, not just the layout.
    tmux set-option -g @resurrect-capture-pane-contents 'on' 2>/dev/null || true
    # Restart foreground programs (vim, nvim, less, top, htop, btop, plus the
    # InferHaven coding agents) when restoring. Anything not on this list is
    # left exited; tmux-resurrect default whitelist is too small for our use.
    tmux set-option -g @resurrect-processes \
        '\"~vim\" \"~nvim\" \"~emacs\" \"~less\" \"~more\" \"~man\" \"~tail\" \"~top\" \"~htop\" \"~btop\" \"~node\" \"~python\" \"~goose\" \"~claude\" \"~opencode\" \"~aider\" \"~qwen\" \"~pi\" \"~cn\" \"~gemini\"' \
        2>/dev/null || true
    tmux new-session -d -s _keepalive -x 80 -y 24 2>/dev/null || true
    _log \"server locked open\"

    waited=0
    while [ \$waited -lt 15 ]; do
      tmux list-keys 2>/dev/null | grep -q resurrect && break
      sleep 1
      waited=\$((waited + 1))
    done

    RESURRECT_DIR=\"\${HOME}/.tmux/resurrect\"
    if [ -L \"\${RESURRECT_DIR}/last\" ] && [ ! -e \"\${RESURRECT_DIR}/last\" ]; then
      latest=\$(ls -t \"\${RESURRECT_DIR}\"/tmux_resurrect_*.txt 2>/dev/null | head -1)
      [ -n \"\${latest}\" ] && ln -sf \"\${latest}\" \"\${RESURRECT_DIR}/last\"
    fi

    if ! tmux has-session -t Haven 2>/dev/null; then
      if [ -e \"\${RESURRECT_DIR}/last\" ]; then
        \"\${HOME}/.tmux/plugins/tmux-resurrect/scripts/restore.sh\" >>'${TMUX_BOOT_LOG}' 2>&1 || true
        sleep 1
      fi
    fi

    tmux has-session -t Haven 2>/dev/null || \
      tmux new-session -d -s Haven -x 220 -y 50 2>>'${TMUX_BOOT_LOG}' || true

    tmux kill-session -t _keepalive 2>/dev/null || true
    _log \"bootstrap complete\"
  " 2>>"${TMUX_BOOT_LOG}" || true

  sleep 5
  su -s /bin/bash "${HAVEN_USER}" -c \
    "/usr/local/bin/ih-pane-restore" \
    >> "${TMUX_BOOT_LOG}" 2>&1 || true

  echo "[InferHaven] Haven tmux session ready."
) &

# ── supercronic (cron-in-container — log rotation, model GC, cache warmer) ──
SUPERCRONIC_PID=""
if [ -x /usr/local/bin/supercronic ] && [ -f /etc/inferhaven/crontab ]; then
  (
    su -s /bin/bash "${HAVEN_USER}" -c \
      "exec /usr/local/bin/supercronic /etc/inferhaven/crontab" \
      >> "${HOME_DIR}/.haven/install.log" 2>&1
  ) &
  SUPERCRONIC_PID=$!
fi

echo "[InferHaven] Workspace ready."
echo "[InferHaven] SSH into this container: ssh -p ${SSH_PORT:-2222} ${HAVEN_USER}@<host>"

# ── Start SSH server ─────────────────────────────────────────────────────────
"$@" &
SSHD_PID=$!

_shutdown() {
  echo "[$(date '+%H:%M:%S')] SIGTERM received — bounded shutdown..." >> "${TMUX_BOOT_LOG}" 2>/dev/null || true
  echo "[InferHaven] Container stopping — bounded shutdown (max ~5 s)..."
  # Kill helpers FIRST so they cannot block.
  # shellcheck disable=SC2015  # `|| true` keeps shutdown trap non-fatal if kill races a missing PID
  [ -n "${SUPERCRONIC_PID}" ] && kill "${SUPERCRONIC_PID}" 2>/dev/null || true
  # shellcheck disable=SC2015
  [ -n "${METRICS_PID}" ]     && kill "${METRICS_PID}"     2>/dev/null || true
  # Capture pane CONTENT first while tmux server still has live panes —
  # `tmux save.sh` can begin winding down the server and `list-panes`
  # subsequently returns empty, which used to wipe the prior good state.
  timeout 2 su -s /bin/bash "${HAVEN_USER}" -c \
    "/usr/local/bin/ih-pane-capture" \
    >>"${TMUX_BOOT_LOG}" 2>&1 || true
  # Then save the structural layout via resurrect.
  timeout 3 su -s /bin/bash "${HAVEN_USER}" -c \
    "${HOME_DIR}/.tmux/plugins/tmux-resurrect/scripts/save.sh" \
    >>"${TMUX_BOOT_LOG}" 2>&1 || true
  # shellcheck disable=SC2016  # $vars are intentionally literal — they expand inside su -c subshell
  timeout 2 su -s /bin/bash "${HAVEN_USER}" -c \
    'f="${HOME}/.tmux/resurrect/last"; [ -L "$f" ] && [ -e "$f" ] && { t=$(readlink -f "$f"); grep -v "haven-popup-" "$t" > "$t.tmp" && mv "$t.tmp" "$t"; }' \
    >>"${TMUX_BOOT_LOG}" 2>&1 || true
  kill "${SSHD_PID}" 2>/dev/null || true
  wait "${SSHD_PID}" 2>/dev/null || true
}
trap _shutdown SIGTERM

wait "${SSHD_PID}" || true
