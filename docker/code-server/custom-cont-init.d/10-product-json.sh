#!/bin/bash
# Patches code-server's product.json to remove the webview external CDN
# dependency (vscode-cdn.net). Without this, extension webviews (Marketplace
# detail panels, Settings UI, etc.) silently blank out whenever DNS / region
# policy / network egress blocks vscode-cdn.net. Stripping the template makes
# VS Code fall back to same-origin webview rendering.
#
# Runs at every code-server container boot via linuxserver s6-overlay
# custom-cont-init.d (as root, before code-server starts).
# Idempotent: re-runs are no-ops once the key is absent.
# Reversible: original product.json is preserved at product.json.haven.bak.
#
# The boot-mode sentinel is created at the end of the init chain by
# 99-init-complete.sh, so all 10–50 scripts report the same (cold|warm)
# boot mode on a given pass.

PRODUCT_JSON="/app/code-server/lib/vscode/product.json"
SENTINEL_DIR="/config/.haven"
SENTINEL="${SENTINEL_DIR}/.code-server-initialized"

BOOT_MODE=$([ -f "${SENTINEL}" ] && echo warm || echo cold)
echo "InferHaven: ${0##*/} (${BOOT_MODE} boot)"

mkdir -p "${SENTINEL_DIR}"
chown abc:abc "${SENTINEL_DIR}" 2>/dev/null || true

if [ ! -f "${PRODUCT_JSON}" ]; then
    echo "InferHaven: WARNING — ${PRODUCT_JSON} not found, skipping webview patch" >&2
    exit 0
fi

if ! grep -q '"webviewContentExternalBaseUrlTemplate"' "${PRODUCT_JSON}"; then
    exit 0
fi

# Preserve the unpatched original exactly once.
BAK="${PRODUCT_JSON}.haven.bak"
[ -f "${BAK}" ] || cp -a "${PRODUCT_JSON}" "${BAK}"

# The key is a single line in the bundled product.json:
#   "webviewContentExternalBaseUrlTemplate": "https://{{uuid}}.vscode-cdn.net/...",
# Deleting the whole line is safe because it sits between other key:value lines
# in the same object — no trailing-comma JSON breakage.
TMP="${PRODUCT_JSON}.haven.tmp"
sed '/"webviewContentExternalBaseUrlTemplate"[[:space:]]*:/d' "${PRODUCT_JSON}" > "${TMP}"

# Sanity-check the result is still valid JSON. node is always present in the
# code-server image at /app/code-server/lib/node.
if /app/code-server/lib/node -e \
    'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' \
    "${TMP}" 2>/dev/null; then
    mv "${TMP}" "${PRODUCT_JSON}"
    echo "InferHaven: stripped webviewContentExternalBaseUrlTemplate from product.json (webviews now same-origin)"
else
    rm -f "${TMP}"
    echo "InferHaven: ERROR — patched product.json failed JSON.parse, leaving original in place" >&2
fi
