#!/bin/bash
# Injects the workspace SSH terminal profile into an existing settings.json.
# Runs on every code-server start; no-ops if the profile is already present.
# Uses only coreutils (head, sed, tail, grep) — no python, node, or jq needed.
BOOT_MODE=$([ -f /config/.haven/.code-server-initialized ] && echo warm || echo cold)
echo "InferHaven: ${0##*/} (${BOOT_MODE} boot)"

SETTINGS_FILE="/config/data/User/settings.json"
[ -f "${SETTINGS_FILE}" ] || exit 0

# Already present — nothing to do
grep -q '"terminal.integrated.profiles.linux"' "${SETTINGS_FILE}" 2>/dev/null && \
    grep -q '"workspace"' "${SETTINGS_FILE}" 2>/dev/null && exit 0

# Only proceed if the file ends with a lone "}" (standard pretty-printed JSON)
if [ "$(tail -1 "${SETTINGS_FILE}")" != "}" ]; then
    echo "[InferHaven] WARNING: settings.json has unexpected format — skipping terminal profile migration" >&2
    exit 0
fi

TMP="${SETTINGS_FILE}.tmp"
{
    # All lines except the closing "}", with a comma appended to the last of them.
    # Valid JSON has no trailing commas, so the last key-value never ends with one.
    head -n -1 "${SETTINGS_FILE}" | sed '$s/$/,/'
    cat << 'EOF'
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
} > "${TMP}" && mv "${TMP}" "${SETTINGS_FILE}"
chown abc:abc "${SETTINGS_FILE}"
