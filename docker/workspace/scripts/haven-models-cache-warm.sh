#!/usr/bin/env bash
# InferHaven model cache warmer — runs every 30 min via supercronic.
# Pre-populates /run/haven/{tags,show-*}.json so first user-facing query
# (haven models, status bar, sync) hits a warm cache.
set -uo pipefail

# shellcheck source=/dev/null
. /usr/local/lib/haven/haven-models.sh

# _haven_models_warm fetches /api/tags then /api/show for every model in parallel.
_haven_models_warm 2>/dev/null || true
