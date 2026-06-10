#!/bin/bash
###############################################################################
# InferHaven — Devcontainer Post-Create Setup
#
# Runs after the devcontainer is created in any conformant client (GitHub
# Codespaces, VS Code Dev Containers, DevPod, JetBrains Gateway, or headless
# `devcontainer up` via @devcontainers/cli).
#
# Flavor selection (env DEVCONTAINER_FLAVOR, set by each devcontainer.json):
#   codespaces   — slim stack (ollama + workspace), CPU-only, default.
#   full-stack   — full prod stack (ollama + workspace + code-server + caddy).
#   nested       — running inside an outer InferHaven workspace.
###############################################################################
set -e

FLAVOR="${DEVCONTAINER_FLAVOR:-codespaces}"
MODEL="${DEFAULT_MODEL:-qwen3:4b-instruct-2507-q4_K_M}"

case "$FLAVOR" in
  codespaces|full-stack|nested) ;;
  *)
    echo "[InferHaven] WARNING: unknown DEVCONTAINER_FLAVOR='${FLAVOR}', defaulting to 'codespaces'."
    FLAVOR="codespaces"
    ;;
esac

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║         Welcome to InferHaven            ║"
echo "  ║      A safe haven for AI inference       ║"
printf  "  ║%*s║\n" 42 ""
printf  "  ║   Devcontainer flavor: %-18s║\n" "$FLAVOR"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# ── Wait for Ollama API ──────────────────────────────────────────────────────
echo "[InferHaven] Waiting for Ollama API..."
for i in $(seq 1 60); do
  if curl -sf http://ollama:11434/api/tags > /dev/null 2>&1; then
    echo "[InferHaven] Ollama API ready."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "[InferHaven] ERROR: Ollama API did not respond after 2 minutes."
    echo "             Check logs: docker logs \$(docker ps -qf name=ollama | head -1)"
    exit 1
  fi
  sleep 2
done

# ── Wait for model download to complete ─────────────────────────────────────
# The codespaces flavor has a model-loader sidecar that pulls qwen3:4b-instruct-2507.
# The full-stack and nested flavors pull DEFAULT_MODEL from the ollama entrypoint
# inline; either way the model lands in /api/tags when ready. SKIP_MODEL=1 skips
# the (slow, ~2 GB) wait — CI and the smoke idempotency rerun set it so the
# devcontainer claim is verified without depending on a model pull.
MAX_WAIT="${MODEL_WAIT:-900}"
if [ "${SKIP_MODEL:-0}" = "1" ]; then
  echo "[InferHaven] SKIP_MODEL=1 — skipping model-download wait."
else
  echo "[InferHaven] Waiting for ${MODEL} to download (may take several minutes)..."
  WAITED=0
  DOTS=0
  while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if curl -sf http://ollama:11434/api/tags 2>/dev/null \
         | grep -q "\"${MODEL}\"" 2>/dev/null; then
      echo ""
      echo "[InferHaven] Model ${MODEL} is ready."
      break
    fi
    printf '.'
    DOTS=$((DOTS + 1))
    [ $((DOTS % 60)) -eq 0 ] && echo " ${WAITED}s"
    sleep 5
    WAITED=$((WAITED + 5))
  done
  echo ""

  if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    echo "[InferHaven] Warning: model not confirmed ready after ${MAX_WAIT}s."
    echo "             It may still be downloading. Check ollama logs from the host."
  fi
fi

# ── Full-stack: check code-server + Caddy ────────────────────────────────────
if [ "$FLAVOR" = "full-stack" ]; then
  echo ""
  echo "[InferHaven] Checking code-server..."
  if curl -sf "http://code-server:8443/healthz" >/dev/null 2>&1 \
     || curl -sf "http://code-server:8443/login" >/dev/null 2>&1; then
    echo "[InferHaven] code-server reachable."
  else
    echo "[InferHaven] code-server not yet reachable (may still be starting)."
  fi

  echo "[InferHaven] Checking Caddy..."
  if curl -sf "http://caddy/status" >/dev/null 2>&1; then
    echo "[InferHaven] Caddy reachable on its internal port."
  else
    echo "[InferHaven] Caddy not yet reachable (may still be starting)."
  fi
fi

# ── opencode install + sync status ───────────────────────────────────────────
if command -v opencode >/dev/null 2>&1; then
  echo "[InferHaven] opencode ready: $(opencode --version 2>/dev/null || echo unknown)"
  if [ -f "${HOME}/.config/opencode/opencode.json" ] || [ -f "${HOME}/.config/opencode/config.json" ]; then
    echo "[InferHaven] opencode configured for ${MODEL}."
  else
    echo "[InferHaven] opencode config not yet synced — run 'haven sync opencode' once model is ready."
  fi
else
  echo "[InferHaven] opencode not installed. Add 'opencode' to INSTALL_ASSISTANTS in .env to enable."
fi

# ── Confirm available models ─────────────────────────────────────────────────
echo ""
echo "[InferHaven] Available models:"
curl -s http://ollama:11434/api/tags 2>/dev/null \
  | jq -r '.models[].name' 2>/dev/null \
  | sed 's/^/  /' \
  || echo "  (none yet — model may still be downloading)"

# ── Instructions ─────────────────────────────────────────────────────────────
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │  InferHaven is ready. Here's how to use it:                 │"
echo "  │                                                             │"
echo "  │  AI coding (opencode — terminal-first, local-tuned):        │"
echo "  │    opencode          — interactive TUI                      │"
echo "  │    opencode --help   — see all commands                     │"
echo "  │                                                             │"
echo "  │  CLI helpers (in terminal):                                 │"
echo "  │    haven models  — list downloaded models                   │"
echo "  │    haven status  — check Ollama connection                  │"
echo "  │    haven tmux    — attach to persistent tmux session        │"
echo "  │    haven sync    — re-render assistant configs from models  │"
if [ "$FLAVOR" = "full-stack" ]; then
echo "  │                                                             │"
echo "  │  Full-stack extras (forwarded via devcontainer):            │"
echo "  │    code-server   — web IDE (forwarded port 8443)            │"
echo "  │    Caddy         — reverse proxy + status (port 80)         │"
fi
echo "  │                                                             │"
echo "  │  Ollama API (OpenAI-compatible):                            │"
echo "  │    http://ollama:11434  (from inside devcontainer)          │"
echo "  │    http://localhost:11434  (forwarded port from host)       │"
echo "  │                                                             │"
echo "  │  Want GPU-powered AI with larger models?                    │"
echo "  │    https://inferhaven.com/trial                             │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
