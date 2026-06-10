# shellcheck shell=bash
# shellcheck disable=SC2015,SC2016
# SC2015: `curl && mv || true` is the deliberate non-fatal cache-fill idiom.
# SC2016: xargs bash -c '...' body keeps $vars literal for the spawned shell.
# InferHaven model-cache helpers.
# Eliminates the N+1 curl pattern across 7 sync functions + status scripts.
#
# /run is tmpfs in the container — cache resets every container restart, so
# stale-after-update bugs cannot persist beyond a single boot.

HAVEN_CACHE_DIR="${HAVEN_CACHE_DIR:-/run/haven}"
HAVEN_CACHE_TTL="${HAVEN_CACHE_TTL:-30}"   # seconds

_haven_ollama_url() {
    printf '%s' "${OLLAMA_URL:-${OLLAMA_HOST:-http://ollama:11434}}"
}

_haven_cache_init() {
    [ -d "${HAVEN_CACHE_DIR}" ] || mkdir -p "${HAVEN_CACHE_DIR}" 2>/dev/null || \
        HAVEN_CACHE_DIR="${HOME:-/tmp}/.haven/cache"
    [ -d "${HAVEN_CACHE_DIR}" ] || mkdir -p "${HAVEN_CACHE_DIR}" 2>/dev/null || true
}

_haven_cache_fresh() {
    local f="$1" ttl="${2:-${HAVEN_CACHE_TTL}}"
    [ -f "${f}" ] || return 1
    local age
    age=$(( $(date +%s) - $(stat -c %Y "${f}" 2>/dev/null || echo 0) ))
    [ "${age}" -lt "${ttl}" ]
}

# Returns JSON from /api/tags (cached). Empty string on error.
_haven_models_tags() {
    _haven_cache_init
    local cache="${HAVEN_CACHE_DIR}/tags.json"
    if ! _haven_cache_fresh "${cache}"; then
        local url
        url="$(_haven_ollama_url)"
        curl -sf --max-time 2 "${url}/api/tags" -o "${cache}.tmp" 2>/dev/null \
            && mv "${cache}.tmp" "${cache}" \
            || { rm -f "${cache}.tmp"; [ -f "${cache}" ] || return 1; }
    fi
    cat "${cache}" 2>/dev/null
}

# Returns newline-separated model names. Empty if unreachable.
_haven_models_list() {
    _haven_models_tags | jq -r '.models[].name' 2>/dev/null
}

# Returns the context window a harness may safely advertise for a model — i.e.
# what Ollama will actually SERVE, never more (over-advertising overflows the
# server and triggers "context exceeds window"). Cached per model.
# Priority: 1) explicit num_ctx in /api/show .parameters (haven tune/params) —
#              served verbatim via the Modelfile, already capped at model max.
#           2) UNTUNED model → min(native <arch>.context_length, server floor).
#              The server serves untuned models at OLLAMA_CONTEXT_LENGTH, not
#              their native GGUF window, so we cap native at OLLAMA_DEFAULT_CTX
#              (kept in lockstep with the compose OLLAMA_CONTEXT_LENGTH).
#           3) OLLAMA_DEFAULT_CTX env (32768 fallback) when no window is known.
_haven_model_ctx() {
    _haven_cache_init
    local model="$1"
    local safe="${model//[^A-Za-z0-9_.-]/_}"
    local cache="${HAVEN_CACHE_DIR}/show-${safe}.json"
    if ! _haven_cache_fresh "${cache}"; then
        local url
        url="$(_haven_ollama_url)"
        curl -sf --max-time 2 "${url}/api/show" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"${model}\"}" \
            -o "${cache}.tmp" 2>/dev/null \
            && mv "${cache}.tmp" "${cache}" \
            || { rm -f "${cache}.tmp"; [ -f "${cache}" ] || true; }
    fi
    local ctx
    ctx=$(jq -r '.parameters // ""' "${cache}" 2>/dev/null \
            | grep -i '^num_ctx ' | awk '{print $2}' | head -1)
    if [ -n "${ctx}" ]; then
        # Explicit num_ctx (haven tune/params): Ollama serves exactly this via
        # the Modelfile and tune already capped it at the model max — use as-is.
        echo "${ctx}"
        return 0
    fi
    # No explicit num_ctx → the server serves this UNTUNED model at its default
    # window (OLLAMA_CONTEXT_LENGTH, built-in 4096 if unset), NOT the model's
    # native GGUF window. Advertising native to openai-compat harnesses
    # (opencode/aider/...) lets them overflow what the server actually serves
    # and hit "context exceeds window". Cap native at the server floor so the
    # advertised ctx never exceeds what is served. Keep OLLAMA_CONTEXT_LENGTH
    # (compose) and OLLAMA_DEFAULT_CTX (here) in lockstep.
    local native ceiling="${OLLAMA_DEFAULT_CTX:-32768}"
    native=$(jq -r '(.model_info // {}) | to_entries[]
                 | select(.key | test("\\.context_length$"))
                 | .value' "${cache}" 2>/dev/null \
            | sort -n | head -1)
    case "${native}" in
        ''|*[!0-9]*) echo "${ceiling}"; return 0 ;;
    esac
    [ "${native}" -lt "${ceiling}" ] && echo "${native}" || echo "${ceiling}"
}

# Pre-populate /api/show cache for ALL models in parallel.
# Call once at the top of sync work to amortize roundtrips: O(1) wall time
# instead of O(N).
_haven_models_warm() {
    local names parallel
    names=$(_haven_models_list)
    [ -z "${names}" ] && return 0
    parallel="${HAVEN_WARM_PARALLEL:-8}"
    printf '%s\n' "${names}" \
        | xargs -P "${parallel}" -I{} -n1 bash -c '
            source /usr/local/lib/haven/haven-models.sh
            _haven_model_ctx "$1" >/dev/null
        ' _ {}
}
