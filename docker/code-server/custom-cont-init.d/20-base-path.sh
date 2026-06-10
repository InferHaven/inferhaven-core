#!/bin/bash
# Disable code-server's built-in TLS so Caddy can proxy plain HTTP internally.
# Base-path is NOT set here — this version of code-server doesn't support it.
# Instead, Caddy uses handle_path to strip /ide and sends X-Forwarded-Prefix: /ide
# so VS Code's web server prefixes all generated asset URLs correctly.
# Runs after linuxserver's own config generation (s6-overlay ordering guarantee).
BOOT_MODE=$([ -f /config/.haven/.code-server-initialized ] && echo warm || echo cold)
echo "InferHaven: ${0##*/} (${BOOT_MODE} boot)"
CONFIG="/config/.config/code-server/config.yaml"
mkdir -p "$(dirname "$CONFIG")"
sed -i '/^base-path:/d;/^base:/d;/^cert:/d' "$CONFIG" 2>/dev/null || true
echo "cert: false" >> "$CONFIG"
