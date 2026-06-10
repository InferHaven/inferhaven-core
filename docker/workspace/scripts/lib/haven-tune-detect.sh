#!/bin/bash
###############################################################################
# haven-tune-detect.sh
#
# Family classifier + Modelfile backup helper for `haven tune`.
#
# Sourced from haven.sh and from the standalone classifier test
# (scripts/tests/tune-detect-family.sh).
#
# Safe-by-default principle: only known-tested model versions match a named
# family. Anything else falls through to "generic", which the tune codepath
# treats as "context window only — TEMPLATE, SYSTEM, PARAMETERs preserved".
###############################################################################

# Reduce a model ref to the bare model name for pattern matching.
#   hf.co/unsloth/Qwen3.6-35B-A3B-GGUF:UD-IQ2_M  -> qwen3.6-35b-a3b-gguf
#   registry.ollama.ai/library/qwen3:8b           -> qwen3
#   ghcr.io/me/llama3.1:8b-instruct               -> llama3.1
#   qwen2.5-coder:7b                              -> qwen2.5-coder
_tune_normalize_model_name() {
  local raw="${1,,}"
  raw="${raw##*/}"            # keep only last path segment
  raw="${raw%%:*}"            # strip ":tag"
  printf '%s' "$raw"
}

# Classify a model into a tune family.
# Returns one of: qwen25, qwen3, llama3, deepseek, mistral, phi4, codellama,
# gemma, generic. The generic path applies only num_ctx — every other
# directive in the Modelfile is preserved verbatim.
#
# Set HAVEN_FORCE_FAMILY=<family> in the environment to bypass detection and
# force a specific family on a custom finetune. The override is lowercased
# but otherwise unchecked — supplying an unknown value yields a no-op tune.
_tune_detect_family() {
  local raw="$1"
  if [ -n "${HAVEN_FORCE_FAMILY:-}" ]; then
    printf '%s' "${HAVEN_FORCE_FAMILY,,}"
    return 0
  fi
  local model
  model=$(_tune_normalize_model_name "$raw")
  case "$model" in
    # Qwen 2.5 — embedded Jinja template preserved (no inject).
    qwen2.5|qwen2.5-*)
      echo "qwen25" ;;
    # Qwen 3.x only (3, 3-coder). Qwen 3.5 / 3.6 / 3.7+ fall to generic.
    qwen3|qwen3-*)
      echo "qwen3" ;;
    # Llama 3 / 3.1 / 3.2 / 3.3 only. Llama 2 / 4 fall to generic.
    llama3|llama3.[123]|llama3.[123]-*|llama-3|llama-3.[123]|llama-3.[123]-*)
      echo "llama3" ;;
    # DeepSeek — R1, Coder, Coder-V2, V2, V3.
    deepseek-r1|deepseek-r1-*|deepseek-coder|deepseek-coder-*|deepseek-v2|deepseek-v2-*|deepseek-v3|deepseek-v3-*)
      echo "deepseek" ;;
    # Mistral only. Mixtral / Devstral / Magistral fall to generic.
    mistral|mistral-*)
      echo "mistral" ;;
    # Phi-4 only. Phi-3 / Phi-3.5 fall to generic.
    phi4|phi4-*|phi-4|phi-4-*)
      echo "phi4" ;;
    # codellama.
    codellama|codellama-*|code-llama|code-llama-*)
      echo "codellama" ;;
    # Gemma 2 / 3. Gemma 1 / 4 fall to generic.
    gemma2|gemma2-*|gemma3|gemma3-*)
      echo "gemma" ;;
    *)
      echo "generic" ;;
  esac
}

# Snapshot a model's pre-modification Modelfile to ~/.haven/modelfile-backups
# before any haven-driven rewrite. Idempotent: only the first backup wins,
# so the on-disk copy is always the upstream original.
#
# Requires _model_slug to be available (defined in haven.sh) when called.
# Soft-fails: tune must never abort because of a backup miss.
_tune_backup_modelfile() {
  local model="$1"
  local dir="${HOME}/.haven/modelfile-backups"
  mkdir -p "${dir}" 2>/dev/null || return 1
  local slug
  slug=$(_model_slug "${model}")
  local backup="${dir}/${slug}.modelfile"
  [ -f "${backup}" ] && return 0
  local current
  current=$(curl -sf "${OLLAMA_URL}/api/show" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${model}\"}" 2>/dev/null \
    | jq -r '.modelfile // empty')
  [ -z "${current}" ] && return 1
  printf '%s' "${current}" > "${backup}"
  chmod 600 "${backup}" 2>/dev/null || true
}
