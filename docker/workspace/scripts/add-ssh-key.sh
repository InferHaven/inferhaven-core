#!/bin/bash
###############################################################################
# InferHaven — Add SSH Key Helper
# Usage: add-ssh-key "ssh-ed25519 AAAA... user@host"
#    or: add-ssh-key < ~/.ssh/id_ed25519.pub
###############################################################################
set -e

HAVEN_USER="${HAVEN_USER:-haven}"
SSH_DIR="/home/${HAVEN_USER}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

mkdir -p "${SSH_DIR}"

if [ -n "$1" ]; then
  KEY="$1"
elif [ ! -t 0 ]; then
  KEY=$(cat)
else
  echo "Usage: add-ssh-key \"ssh-ed25519 AAAA... user@host\""
  echo "   or: cat ~/.ssh/id_ed25519.pub | add-ssh-key"
  exit 1
fi

if echo "${KEY}" | grep -qE "^ssh-(ed25519|rsa|ecdsa)"; then
  echo "${KEY}" >> "${AUTH_KEYS}"
  sort -u -o "${AUTH_KEYS}" "${AUTH_KEYS}"
  chmod 600 "${AUTH_KEYS}"
  chmod 700 "${SSH_DIR}"
  chown -R "${HAVEN_USER}:${HAVEN_USER}" "${SSH_DIR}"
  echo "SSH key added successfully."
else
  echo "Error: Invalid SSH public key format."
  exit 1
fi
