#!/usr/bin/env bash
# InferHaven volume layout migrator — one-shot.
#
# Old layout: workspace_home volume mounted at /home/haven (single user only).
# New layout: workspace_home volume mounted at /home (multi-user friendly).
#
# Run when upgrading a deployment that ran an older inferhaven-core release.
#
#   sudo /usr/local/bin/haven-migrate-home
#
# What it does
#   1. Detects which layout the volume is on by sampling key paths.
#   2. If old layout: shuffles existing files into a /home/haven/ subdir on the
#      mounted volume so the new docker-compose.yml mount works.
#   3. Writes a sentinel ~/.haven/.layout-migrated so we never re-run.
#
# Idempotent. Safe to run from inside the container OR via docker exec.
set -euo pipefail

HAVEN_USER="${HAVEN_USER:-haven}"
HOME_DIR="/home/${HAVEN_USER}"
LAYOUT_SENTINEL="${HOME_DIR}/.haven/.layout-migrated"

if [ -f "${LAYOUT_SENTINEL}" ]; then
    echo "[migrate-home] Already migrated — sentinel ${LAYOUT_SENTINEL} present. Nothing to do."
    exit 0
fi

# If the volume already presents /home/haven correctly AND no stray flat
# files are at /home/, we're already on the new layout.
if [ -d "${HOME_DIR}" ] && [ ! -f "/home/.zshrc" ] && [ ! -d "/home/.config" ]; then
    echo "[migrate-home] /home/haven already exists; no flat layout detected. Marking migrated."
    mkdir -p "$(dirname "${LAYOUT_SENTINEL}")"
    : > "${LAYOUT_SENTINEL}"
    chown "${HAVEN_USER}:${HAVEN_USER}" "${LAYOUT_SENTINEL}" 2>/dev/null || true
    exit 0
fi

if ! mountpoint -q /home 2>/dev/null; then
    echo "[migrate-home] /home is not a volume mount — abort."
    echo "[migrate-home]   Update docker-compose.yml workspace volume to: workspace_home:/home"
    exit 1
fi

echo "[migrate-home] Old layout detected. Re-nesting files under ${HOME_DIR}..."

TMP_DIR="/home/.migrate-home-staging"
mkdir -p "${TMP_DIR}"

# Move every top-level entry in /home (except our staging dir) into the
# staging area, then create the haven subdir and move them in there.
shopt -s dotglob
for entry in /home/*; do
    name="$(basename "${entry}")"
    case "${name}" in
        "${HAVEN_USER}"|".migrate-home-staging") continue ;;
    esac
    mv "${entry}" "${TMP_DIR}/" 2>/dev/null || true
done
shopt -u dotglob

mkdir -p "${HOME_DIR}"
shopt -s dotglob nullglob
for entry in "${TMP_DIR}"/*; do
    mv "${entry}" "${HOME_DIR}/" 2>/dev/null || true
done
shopt -u dotglob nullglob
rmdir "${TMP_DIR}" 2>/dev/null || true

chown -R "${HAVEN_USER}:${HAVEN_USER}" "${HOME_DIR}"
mkdir -p "$(dirname "${LAYOUT_SENTINEL}")"
: > "${LAYOUT_SENTINEL}"
chown "${HAVEN_USER}:${HAVEN_USER}" "${LAYOUT_SENTINEL}" 2>/dev/null || true

echo "[migrate-home] Migration complete. Restart the workspace: docker compose restart workspace"
