#!/bin/bash
# Runs at code-server container startup via linuxserver s6-overlay custom-cont-init.d.
# Generates a dedicated SSH keypair and auto-authorizes it in the workspace container
# so that the code-server integrated terminal can SSH into workspace transparently.
set -e

BOOT_MODE=$([ -f /config/.haven/.code-server-initialized ] && echo warm || echo cold)
echo "InferHaven: ${0##*/} (${BOOT_MODE} boot)"

CS_SSH_DIR="/config/.ssh"
CS_PRIVKEY="${CS_SSH_DIR}/code-server-workspace"
CS_PUBKEY="${CS_PRIVKEY}.pub"
CS_KNOWN_HOSTS="${CS_SSH_DIR}/known_hosts"

# workspace_home volume as seen from code-server
WS_SSH_DIR="/config/workspace/.ssh"
WS_AUTH_KEYS_AUTO="${WS_SSH_DIR}/authorized_keys.auto"
WS_HOSTKEY_PUB="${WS_SSH_DIR}/host_keys/ssh_host_ed25519_key.pub"

# ── 1. Ensure openssh-client is available ────────────────────────────────────
if ! command -v ssh >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y --no-install-recommends openssh-client
fi

# ── 2. Set up /config/.ssh ────────────────────────────────────────────────────
mkdir -p "${CS_SSH_DIR}"
chown abc:abc "${CS_SSH_DIR}"
chmod 700 "${CS_SSH_DIR}"

# ── 3. Generate keypair once (persists in code_server_data volume) ────────────
if [ ! -f "${CS_PRIVKEY}" ]; then
    ssh-keygen -q -t ed25519 -f "${CS_PRIVKEY}" -N "" -C "code-server@inferhaven"
    chown abc:abc "${CS_PRIVKEY}" "${CS_PUBKEY}"
    chmod 600 "${CS_PRIVKEY}"
    chmod 644 "${CS_PUBKEY}"
fi

# ── 4. Inject public key into workspace authorized_keys.auto ─────────────────
# Wait for workspace .ssh dir to be visible via shared volume. workspace starts
# first (depends_on), but its entrypoint.sh may still be initializing .ssh/.
_ready=0
for _i in $(seq 1 10); do
    [ -d "${WS_SSH_DIR}" ] && { _ready=1; break; }
    sleep 1
done

if [ "${_ready}" -eq 0 ]; then
    echo "[InferHaven] WARNING: ${WS_SSH_DIR} not found after 10s — skipping SSH key injection" >&2
else
    CS_PUBKEY_CONTENT=$(cat "${CS_PUBKEY}")
    if ! grep -qF "${CS_PUBKEY_CONTENT}" "${WS_AUTH_KEYS_AUTO}" 2>/dev/null; then
        echo "${CS_PUBKEY_CONTENT}" >> "${WS_AUTH_KEYS_AUTO}"
    fi
    # sshd in workspace reads this as haven (UID 1000); haven doesn't exist in
    # code-server's /etc/passwd so use numeric UID.
    chmod 600 "${WS_AUTH_KEYS_AUTO}"
    chown 1000:1000 "${WS_AUTH_KEYS_AUTO}"
fi

# ── 5. Regenerate known_hosts from workspace's persisted host key ─────────────
# Host keys survive workspace rebuilds because they live in the workspace_home
# volume at ~/.ssh/host_keys/. Regenerating here means no stale-key warnings
# even after a docker compose up --build workspace.
if [ -f "${WS_HOSTKEY_PUB}" ]; then
    _expected="workspace $(cat "${WS_HOSTKEY_PUB}")"
    if ! { [ -f "${CS_KNOWN_HOSTS}" ] && [ "$(cat "${CS_KNOWN_HOSTS}")" = "${_expected}" ]; }; then
        printf '%s\n' "${_expected}" > "${CS_KNOWN_HOSTS}"
        chown abc:abc "${CS_KNOWN_HOSTS}"
        chmod 644 "${CS_KNOWN_HOSTS}"
    fi
else
    echo "[InferHaven] WARNING: ${WS_HOSTKEY_PUB} not found — known_hosts not updated" >&2
    echo "[InferHaven]   Terminal SSH will fail until workspace has started at least once" >&2
fi
