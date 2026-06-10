#!/bin/bash
# Injects performance-optimized VS Code settings on first container boot.
# Runs as root via linuxserver s6-overlay custom-cont-init.d.
# Idempotent: never overwrites settings.json once created, so user
# customizations made in VS Code are preserved across container restarts.
BOOT_MODE=$([ -f /config/.haven/.code-server-initialized ] && echo warm || echo cold)
echo "InferHaven: ${0##*/} (${BOOT_MODE} boot)"

# ── User settings (code_server_data volume) ──────────────────────────────────
SETTINGS_DIR="/config/data/User"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"

mkdir -p "${SETTINGS_DIR}"

if [ ! -f "${SETTINGS_FILE}" ]; then
    cat > "${SETTINGS_FILE}" << 'EOF'
{
  "files.watcherExclude": {
    "**/.git/objects/**": true,
    "**/.git/subtree-cache/**": true,
    "**/node_modules/**": true,
    "**/__pycache__/**": true,
    "**/.npm/**": true,
    "**/.go/**": true,
    "**/.cargo/**": true,
    "**/.cache/**": true,
    "**/.conda/**": true,
    "**/venv/**": true,
    "**/.venv/**": true,
    "**/.tox/**": true,
    "**/dist/**": true,
    "**/build/**": true,
    "**/.mypy_cache/**": true,
    "**/.pytest_cache/**": true,
    "**/.ruff_cache/**": true
  },
  "search.exclude": {
    "**/.git/objects/**": true,
    "**/node_modules/**": true,
    "**/__pycache__/**": true,
    "**/.npm/**": true,
    "**/.go/**": true,
    "**/.cargo/**": true,
    "**/.cache/**": true,
    "**/.conda/**": true,
    "**/venv/**": true,
    "**/.venv/**": true,
    "**/dist/**": true,
    "**/build/**": true,
    "**/.mypy_cache/**": true,
    "**/.pytest_cache/**": true,
    "**/.ruff_cache/**": true
  },
  "git.autoRepositoryDetection": "openEditors",
  "extensions.autoUpdate": false,
  "extensions.autoCheckUpdates": false,
  "telemetry.telemetryLevel": "off",
  "update.mode": "none",
  "search.followSymlinks": false,
  "terminal.integrated.profiles.linux": {
    "workspace": {
      "path": "/usr/bin/ssh",
      "args": ["-t", "-i", "/config/.ssh/code-server-workspace", "-o", "UserKnownHostsFile=/config/.ssh/known_hosts", "haven@workspace"],
      "icon": "vm-connect"
    }
  },
  "terminal.integrated.defaultProfile.linux": "workspace"
}
EOF
    chown abc:abc "${SETTINGS_FILE}"
fi

chown abc:abc "${SETTINGS_DIR}"

# ── Workspace settings (projects volume) ──────────────────────────────────────
# Reinforces watcher/search exclusions at workspace scope so they apply even
# if the user resets global settings. Only watcher/search patterns here — not
# behavioral settings like git detection or extension updates, which belong
# at the user level. Path is already in .gitignore.
WORKSPACE_VSCODE_DIR="/config/workspace/projects/.vscode"
WORKSPACE_SETTINGS="${WORKSPACE_VSCODE_DIR}/settings.json"

mkdir -p "${WORKSPACE_VSCODE_DIR}"

if [ ! -f "${WORKSPACE_SETTINGS}" ]; then
    cat > "${WORKSPACE_SETTINGS}" << 'EOF'
{
  "files.watcherExclude": {
    "**/.git/objects/**": true,
    "**/.git/subtree-cache/**": true,
    "**/node_modules/**": true,
    "**/__pycache__/**": true,
    "**/.npm/**": true,
    "**/.go/**": true,
    "**/.cargo/**": true,
    "**/.cache/**": true,
    "**/.conda/**": true,
    "**/venv/**": true,
    "**/.venv/**": true,
    "**/dist/**": true,
    "**/build/**": true,
    "**/.mypy_cache/**": true,
    "**/.pytest_cache/**": true,
    "**/.ruff_cache/**": true
  },
  "search.exclude": {
    "**/.git/objects/**": true,
    "**/node_modules/**": true,
    "**/__pycache__/**": true,
    "**/.npm/**": true,
    "**/.go/**": true,
    "**/.cargo/**": true,
    "**/.cache/**": true,
    "**/.conda/**": true,
    "**/venv/**": true,
    "**/.venv/**": true,
    "**/dist/**": true,
    "**/build/**": true,
    "**/.mypy_cache/**": true,
    "**/.pytest_cache/**": true,
    "**/.ruff_cache/**": true
  },
  "search.followSymlinks": false
}
EOF
fi

# Recursive chown only when ownership has actually drifted. Same pattern
# linuxserver's baseimage uses to skip /config chown on warm boots — keeps
# warm-boot work O(1) instead of O(N) over a user-extensible .vscode/ tree.
if find "${WORKSPACE_VSCODE_DIR}" -maxdepth 2 ! -uid 1000 -print -quit 2>/dev/null | grep -q .; then
    chown -R abc:abc "${WORKSPACE_VSCODE_DIR}"
fi
