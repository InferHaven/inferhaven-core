#!/usr/bin/env bash
###############################################################################
# tune-detect-family.sh
#
# Standalone bash unit test for the model-family classifier used by
# `haven tune`. Sources lib/haven-tune-detect.sh directly so it runs on dev
# hosts without the workspace container.
#
# Guardrail: any new dangerous case (a model that current logic would inject
# the wrong template for) MUST be added to the "must fall to generic" rows
# before adding it to a named family.
###############################################################################

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="${HERE}/../../docker/workspace/scripts/lib/haven-tune-detect.sh"
if [ ! -f "${LIB}" ]; then
  echo "FATAL: cannot find ${LIB}" >&2
  exit 2
fi
# shellcheck disable=SC1090
. "${LIB}"

PASS=0
FAIL=0

# rows: "<model name>|<expected family>"
matrix=(
  # ── tested families — unchanged behaviour ──
  "qwen2.5-coder:7b|qwen25"
  "qwen2.5:14b|qwen25"
  "qwen3:8b|qwen3"
  "qwen3-coder:30b|qwen3"
  "llama3:8b|llama3"
  "llama3.1:8b|llama3"
  "llama3.2:3b|llama3"
  "llama3.3:70b|llama3"
  "llama-3.1:8b|llama3"
  "mistral:7b|mistral"
  "mistral-nemo:12b|mistral"
  "mistral-small:24b|mistral"
  "mistral-large:123b|mistral"
  "phi4:14b|phi4"
  "phi-4:14b|phi4"
  "deepseek-r1:7b|deepseek"
  "deepseek-coder:6.7b|deepseek"
  "deepseek-coder-v2:16b|deepseek"
  "deepseek-v3:671b|deepseek"
  "codellama:13b|codellama"
  "code-llama:7b|codellama"
  "gemma2:9b|gemma"
  "gemma3:27b-it|gemma"
  "gemma3-it:27b|gemma"

  # ── dangerous cases — MUST fall to generic ──
  "qwen3.5:32b|generic"
  "qwen3.6:35b|generic"
  "qwen3.7:8b|generic"
  "hf.co/unsloth/Qwen3.6-35B-A3B-GGUF:UD-IQ2_M|generic"
  "Qwen3.6-35B-A3B-GGUF:UD-IQ2_M|generic"
  "llama2:13b|generic"
  "llama4:scout|generic"
  "mixtral:8x7b|generic"
  "devstral:24b|generic"
  "magistral:24b|generic"
  "phi3:medium|generic"
  "phi3.5:mini|generic"
  "phi-3:medium|generic"
  "gemma:7b|generic"
  "gemma4:e4b-it-q4_K_M|generic"
  "granite3.1-dense:8b|generic"
  "command-r:35b|generic"
  "yi:34b|generic"
  "qwen:7b|generic"
  "my-custom-finetune:7b|generic"

  # ── normalisation — registry prefixes stripped ──
  "ghcr.io/me/llama3.1:8b-instruct|llama3"
  "registry.ollama.ai/library/qwen3:8b|qwen3"
  "REGISTRY.OLLAMA.AI/LIBRARY/QWEN3:8B|qwen3"
)

for row in "${matrix[@]}"; do
  name="${row%|*}"
  expected="${row##*|}"
  got=$(_tune_detect_family "$name")
  if [ "$got" = "$expected" ]; then
    PASS=$((PASS + 1))
    printf "  OK    %-55s -> %s\n" "$name" "$got"
  else
    FAIL=$((FAIL + 1))
    printf "  FAIL  %-55s -> %s (expected %s)\n" "$name" "$got" "$expected"
  fi
done

# ── override test ──────────────────────────────────────────────────────────
got=$(HAVEN_FORCE_FAMILY=qwen3 _tune_detect_family "my-custom-finetune:latest")
if [ "$got" = "qwen3" ]; then
  PASS=$((PASS + 1))
  printf "  OK    %-55s -> %s\n" "HAVEN_FORCE_FAMILY=qwen3 my-custom-finetune:latest" "$got"
else
  FAIL=$((FAIL + 1))
  printf "  FAIL  HAVEN_FORCE_FAMILY override -> %s (expected qwen3)\n" "$got"
fi

# ── normaliser direct ──────────────────────────────────────────────────────
got=$(_tune_normalize_model_name "hf.co/unsloth/Qwen3.6-35B-A3B-GGUF:UD-IQ2_M")
if [ "$got" = "qwen3.6-35b-a3b-gguf" ]; then
  PASS=$((PASS + 1))
  printf "  OK    normalize HF path -> %s\n" "$got"
else
  FAIL=$((FAIL + 1))
  printf "  FAIL  normalize HF path -> %s (expected qwen3.6-35b-a3b-gguf)\n" "$got"
fi

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
