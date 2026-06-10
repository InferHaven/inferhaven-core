#!/bin/bash
# shellcheck shell=bash
###############################################################################
# haven-resolve.sh — dynamic compose-aware container resolution
#
# Every container that compose starts carries two labels:
#   com.docker.compose.project=<project>
#   com.docker.compose.service=<service>
# and (modern compose) a third:
#   com.docker.compose.project.config_files=<comma-separated absolute paths>
#
# Service names are stable across our compose files (ollama, workspace,
# code-server, caddy, haven-agent). Project names vary:
#   - main stack:        inferhaven
#   - codespaces flavor: inferhaven-codespaces
#   - full-stack dev:    inferhaven-dev
#   - user-overridden:   anything
#
# Resolving siblings by label means the CLI + monitoring scripts never break
# when container_name changes. Originally introduced in haven.sh for the
# haven CLI (Round 1); moved here in Round 3 so metrics-server, popup, and
# alert-watcher share one source of truth.
#
# Usage:
#   . /usr/local/lib/haven/haven-resolve.sh
#   project="$(_haven_resolve_project)"
#   ollama_name="$(_haven_resolve_container ollama)"
#   files="$(_haven_resolve_compose_files)"
#
# All functions are idempotent and cached per-process. They print empty
# strings on failure so callers can `[ -z "$x" ]`-check.
###############################################################################

# Reliable across cgroup v1 and v2: every container has paths like
# /var/lib/docker/containers/<64-hex>/{resolv.conf,hostname,hosts} bind-mounted
# into it. Pull the first such ID from /proc/self/mountinfo.
_haven_resolve_self_container_id() {
  grep -oE '/containers/[0-9a-f]{64}' /proc/self/mountinfo 2>/dev/null \
    | head -1 | sed 's|^/containers/||'
}

# Compose project name our self container belongs to (cached).
_haven_resolve_project() {
  if [ -n "${_HAVEN_PROJECT_CACHE:-}" ]; then
    printf '%s' "$_HAVEN_PROJECT_CACHE"
    return
  fi
  local id
  id="$(_haven_resolve_self_container_id)"
  if [ -n "$id" ]; then
    _HAVEN_PROJECT_CACHE="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$id" 2>/dev/null || true)"
  fi
  printf '%s' "${_HAVEN_PROJECT_CACHE:-}"
}

# _haven_resolve_container <service> → container NAME of sibling running that
# compose service in our project, or empty if not running. Works as a target
# for `docker exec`, `docker logs`, `docker inspect`, `docker cp src:/...`.
_haven_resolve_container() {
  local svc="$1" proj
  proj="$(_haven_resolve_project)"
  if [ -n "$proj" ]; then
    docker ps --filter "label=com.docker.compose.project=${proj}" \
              --filter "label=com.docker.compose.service=${svc}" \
              --format '{{.Names}}' 2>/dev/null | head -1
  else
    # No project label on self (rare — outside compose). Best effort: any
    # container claiming this service. Multiple stacks running simultaneously
    # → set _HAVEN_PROJECT_CACHE to disambiguate before calling.
    docker ps --filter "label=com.docker.compose.service=${svc}" \
              --format '{{.Names}}' 2>/dev/null | head -1
  fi
}

# All sibling container names under our project, newline-separated. Useful for
# popup-style "list every container in the stack" enumerations.
_haven_resolve_all_containers() {
  local proj
  proj="$(_haven_resolve_project)"
  if [ -n "$proj" ]; then
    docker ps --filter "label=com.docker.compose.project=${proj}" \
              --format '{{.Names}}' 2>/dev/null
  else
    docker ps --filter "label=com.docker.compose.service" \
              --format '{{.Names}}' 2>/dev/null
  fi
}

# Comma-separated absolute paths of the compose files our project was started
# with (HOST-side paths — they may need translating to in-container paths via
# INFERHAVEN_DIR + basename when the project repo is bind-mounted at
# /opt/inferhaven). Cached.
_haven_resolve_compose_files() {
  if [ -n "${_HAVEN_COMPOSE_FILES_CACHE+x}" ]; then
    printf '%s' "$_HAVEN_COMPOSE_FILES_CACHE"
    return
  fi
  local id
  id="$(_haven_resolve_self_container_id)"
  if [ -n "$id" ]; then
    _HAVEN_COMPOSE_FILES_CACHE="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$id" 2>/dev/null || true)"
  fi
  printf '%s' "${_HAVEN_COMPOSE_FILES_CACHE:-}"
}

# ── Back-compat shims ─────────────────────────────────────────────────────────
# haven.sh historically called these names. Keep them as aliases so older
# subcommands (and any out-of-tree forks) keep working unchanged.
_haven_self_container_id() { _haven_resolve_self_container_id; }
_haven_compose_project()    { _haven_resolve_project; }
_haven_container()          { _haven_resolve_container "$@"; }
