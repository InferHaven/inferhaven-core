#!/usr/bin/env bash
# shellcheck disable=SC2015
# SC2015: `test && pass || fail` is the deliberate assertion idiom — pass/fail
#   are local helpers that always return 0, so this IS safe if-then-else.
###############################################################################
# InferHaven — Devcontainer Smoke Test
#
# Runs INSIDE the workspace container after `devcontainer up` (or after the
# Codespaces / VS Code Dev Containers / DevPod / JetBrains UI has finished
# postCreate). Asserts every claim the README makes about the devcontainer
# experience for the active flavor.
#
# Flavors (env DEVCONTAINER_FLAVOR, picked up from containerEnv):
#   codespaces  — slim stack (ollama + workspace). Default.
#   full-stack  — full prod stack (+ code-server + caddy). Extra assertions.
#   nested      — dev devcontainer running inside a prod workspace.
#
# Exit 0 = green. Exit non-zero on first failure (line number reported).
#
# Skip flags (env, set to 1 to skip the named section):
#   SKIP_MODEL              — model present in /api/tags (CI doesn't pull models)
#   SKIP_OPENCODE           — opencode binary check (opencode install is async)
#   SKIP_DIND               — Docker-in-Docker section (envs without socket mount)
#   SKIP_TOOLCHAIN          — PATH binary loop (minimal-image testing)
#   SKIP_POSTCREATE         — postCreate idempotency rerun (noisy; iterating on smoke)
#   SKIP_FULL_STACK_EXTRAS  — code-server + caddy + metrics block (full-stack flavor only)
#   SKIP_NESTED             — @devcontainers/cli existence check (no nested workflow)
#
# Tuning (env):
#   MODEL_WAIT=300          — seconds to wait for model in /api/tags (default 300)
###############################################################################
set -u

FLAVOR="${DEVCONTAINER_FLAVOR:-codespaces}"
case "$FLAVOR" in
  codespaces|full-stack|nested) ;;
  *) echo "WARN: unknown DEVCONTAINER_FLAVOR='${FLAVOR}', defaulting to 'codespaces'."; FLAVOR="codespaces" ;;
esac

MODEL="${DEFAULT_MODEL:-qwen2.5-coder:3b}"
MODEL_WAIT="${MODEL_WAIT:-300}"
PASS=0
FAIL=0

pass() { printf "  \033[32mOK\033[0m   %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
skip() { printf "  \033[33mSKIP\033[0m %s\n" "$1"; }
hdr()  { printf "\n\033[1m== %s ==\033[0m\n" "$1"; }

printf "\n\033[1mInferHaven devcontainer smoke — flavor: %s\033[0m\n" "$FLAVOR"

# ─────────────────────────────────────────────────────────────────────────────
hdr "Identity & workspace"

[ "$(id -un)" = "haven" ] \
  && pass "user is haven" \
  || fail "user is $(id -un), expected haven"

case "$(pwd)/" in
  /home/haven/projects/inferhaven-core/*)
    pass "pwd in workspaceFolder ($(pwd))"
    ;;
  *)
    fail "pwd = $(pwd), expected /home/haven/projects/inferhaven-core or a subdirectory (devcontainer.json workspaceFolder)"
    ;;
esac

if touch /home/haven/projects/inferhaven-core/.smoke-rw-probe 2>/dev/null; then
  rm -f /home/haven/projects/inferhaven-core/.smoke-rw-probe
  pass "/home/haven/projects/inferhaven-core is read-write"
else
  fail "/home/haven/projects/inferhaven-core not writable"
fi

# ─────────────────────────────────────────────────────────────────────────────
hdr "Ollama reachability"

[ "${OLLAMA_HOST:-}" = "http://ollama:11434" ] \
  && pass "OLLAMA_HOST=$OLLAMA_HOST" \
  || fail "OLLAMA_HOST=${OLLAMA_HOST:-<unset>}, expected http://ollama:11434"

if curl -sf "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
  pass "ollama /api/tags responds"
else
  fail "ollama /api/tags unreachable"
fi

if [ "${SKIP_MODEL:-0}" != "1" ]; then
  waited=0
  while [ "$waited" -lt "$MODEL_WAIT" ]; do
    if curl -sf "${OLLAMA_HOST}/api/tags" 2>/dev/null \
         | grep -q "\"${MODEL}\""; then
      pass "model ${MODEL} present"
      break
    fi
    sleep 5
    waited=$((waited+5))
  done
  if [ "$waited" -ge "$MODEL_WAIT" ]; then
    fail "model ${MODEL} not in /api/tags after ${MODEL_WAIT}s"
  fi
else
  printf "  \033[33mSKIP\033[0m model check (SKIP_MODEL=1)\n"
fi

# ─────────────────────────────────────────────────────────────────────────────
if [ "${SKIP_DIND:-0}" != "1" ]; then
  hdr "Docker-in-Docker"

  if [ -S /var/run/docker.sock ]; then
    pass "/var/run/docker.sock mounted"
  else
    fail "/var/run/docker.sock not mounted"
  fi

  if docker ps >/dev/null 2>&1; then
    pass "docker ps works as $(id -un)"
  else
    fail "docker ps EACCES — entrypoint did not add $(id -un) to docker group"
  fi
else
  hdr "Docker-in-Docker"
  skip "DinD section (SKIP_DIND=1)"
fi

# ─────────────────────────────────────────────────────────────────────────────
if [ "${SKIP_TOOLCHAIN:-0}" != "1" ]; then
  hdr "Toolchain on PATH"

  for bin in haven tmux zsh nvim uv go node docker gh jq rg fd bat; do
    if command -v "$bin" >/dev/null 2>&1; then
      pass "$bin"
    else
      fail "$bin missing from PATH"
    fi
  done
else
  hdr "Toolchain on PATH"
  skip "toolchain checks (SKIP_TOOLCHAIN=1)"
fi

# ─────────────────────────────────────────────────────────────────────────────
hdr "Default assistant (opencode)"

if [ "${SKIP_OPENCODE:-0}" != "1" ]; then
  if command -v opencode >/dev/null 2>&1; then
    pass "opencode installed ($(opencode --version 2>&1 | head -1))"
  else
    fail "opencode missing — INSTALL_ASSISTANTS=opencode not honored or still pending"
  fi
else
  skip "opencode check (SKIP_OPENCODE=1)"
fi

# ─────────────────────────────────────────────────────────────────────────────
if [ "${SKIP_POSTCREATE:-0}" != "1" ]; then
  hdr "postCreate idempotency"

  if [ -x /usr/local/bin/devcontainer-setup.sh ]; then
    # SKIP_MODEL silences the in-script model wait so the rerun completes fast.
    if SKIP_MODEL=1 /usr/local/bin/devcontainer-setup.sh >/dev/null 2>&1; then
      pass "devcontainer-setup.sh re-runs cleanly"
    else
      fail "devcontainer-setup.sh exited non-zero on rerun"
    fi
  else
    fail "/usr/local/bin/devcontainer-setup.sh missing"
  fi
else
  hdr "postCreate idempotency"
  skip "postCreate rerun (SKIP_POSTCREATE=1)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Full-stack flavor: extra services that don't exist in codespaces.
if [ "$FLAVOR" = "full-stack" ] && [ "${SKIP_FULL_STACK_EXTRAS:-0}" != "1" ]; then
  hdr "Full-stack extras"

  if command -v haven >/dev/null 2>&1 \
     && haven service ollama status >/dev/null 2>&1; then
    pass "haven service introspection works"
  else
    fail "haven service introspection failed"
  fi

  if curl -sf --max-time 5 http://code-server:8443/login >/dev/null 2>&1 \
     || curl -sf --max-time 5 http://code-server:8443/healthz >/dev/null 2>&1; then
    pass "code-server reachable on internal hostname"
  else
    fail "code-server unreachable on code-server:8443"
  fi

  # Caddy: distinguish DNS/connection failures (curl exit 6/7, http_code=000)
  # from "Caddy responded" (any 2xx/3xx — 308 redirect is the expected response
  # when TLS_MODE=internal/acme; 200 when TLS_MODE=off). Capture the HTTP code
  # so the next failure is diagnosable without a separate run.
  _caddy_code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' http://caddy/status 2>/dev/null || true)
  _caddy_curl_exit=$?
  case "$_caddy_code" in
    2??|3??)
      pass "Caddy reachable on internal hostname (HTTP $_caddy_code)"
      ;;
    *)
    # Re-try root path to catch the case where /status was removed but Caddy is up.
    _caddy_root_code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' http://caddy/ 2>/dev/null || true)
    case "$_caddy_root_code" in
      2??|3??)
        pass "Caddy reachable on internal hostname (HTTP $_caddy_root_code on /, /status returned $_caddy_code)"
        ;;
      *)
      fail "Caddy unreachable on caddy:80 (curl_exit=$_caddy_curl_exit, /status=$_caddy_code, /=$_caddy_root_code)"
      # Dump container logs to ease diagnosis on the next run. Find the caddy
      # container by compose-service label — works regardless of project name.
      _caddy_id=$(docker ps -a --filter "label=com.docker.compose.service=caddy" --format '{{.ID}}' 2>/dev/null | head -1)
      if [ -n "$_caddy_id" ]; then
        printf '       Caddy container: %s — last 30 log lines:\n' "$_caddy_id"
        docker logs --tail 30 "$_caddy_id" 2>&1 | sed 's/^/         /'
      else
        printf '       No container with label com.docker.compose.service=caddy found.\n'
      fi
        ;;
    esac
      ;;
  esac

  if curl -sf --max-time 5 http://localhost:9091/metrics.json >/dev/null 2>&1; then
    pass "metrics-server serving on :9091"
  else
    fail "metrics-server not responding on :9091"
  fi
elif [ "$FLAVOR" = "full-stack" ]; then
  hdr "Full-stack extras"
  skip "full-stack extras (SKIP_FULL_STACK_EXTRAS=1)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Nested flavor: assert isolation from the outer prod stack.
if [ "$FLAVOR" = "nested" ]; then
  hdr "Nested isolation"

  if [ "${INFERHAVEN_DIR:-/opt/inferhaven}" = "/opt/inferhaven" ]; then
    pass "INFERHAVEN_DIR=/opt/inferhaven (inner)"
  else
    fail "INFERHAVEN_DIR=${INFERHAVEN_DIR:-<unset>}, expected /opt/inferhaven"
  fi

  # Find the inner stack via the workspace's own compose-project label so
  # we don't hardcode a project-name prefix. Older `haven devcontainer up`
  # ran the inner stack as `inferhaven-dev`; current `haven nest up` uses
  # `haven-nest-<basename>`. The label is authoritative either way.
  _proj=""
  if [ -r /usr/local/lib/haven/haven-resolve.sh ]; then
    # shellcheck source=/dev/null
    . /usr/local/lib/haven/haven-resolve.sh 2>/dev/null
    _proj="$(_haven_resolve_project 2>/dev/null)"
  fi
  if [ -n "$_proj" ] && \
     docker ps --filter "label=com.docker.compose.project=${_proj}" \
               --format '{{.Names}}' 2>/dev/null | grep -q .; then
    pass "inner stack running under compose project '${_proj}'"
  elif docker ps --format '{{.Names}}' 2>/dev/null \
        | grep -qE '^(haven-nest-)?inferhaven-(dev|nest)'; then
    pass "inner stack visible (legacy name-prefix match)"
  else
    fail "no inner-stack containers visible from inside nested workspace (project='${_proj:-unresolved}')"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Nested devcontainer support (applies to full-stack flavor where the user may
# want to demo nested-in-prod from this devcontainer).
if [ "$FLAVOR" = "full-stack" ] && [ "${SKIP_NESTED:-0}" != "1" ]; then
  hdr "Nested devcontainer support"

  if command -v devcontainer >/dev/null 2>&1; then
    # 2>/dev/null suppresses Node.js `NODE_EXTRA_CA_CERTS` warnings (e.g. a
    # stale `inferhaven-caddy.crt` path from a prior TLS=internal setup) so
    # they don't pollute the OK line. Real errors would surface via the
    # `command -v` check above.
    pass "@devcontainers/cli installed ($(devcontainer --version 2>/dev/null | head -1))"
  else
    fail "@devcontainers/cli missing — nested helper will refuse to run"
  fi
elif [ "$FLAVOR" = "full-stack" ]; then
  hdr "Nested devcontainer support"
  skip "nested check (SKIP_NESTED=1)"
fi

# ─────────────────────────────────────────────────────────────────────────────
hdr "Summary"
echo "  flavor: $FLAVOR"
echo "  passed: $PASS"
echo "  failed: $FAIL"
[ "$FAIL" -eq 0 ]
