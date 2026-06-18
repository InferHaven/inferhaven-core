#!/usr/bin/env bash
###############################################################################
# bench-parse.sh
#
# Standalone bash unit test for _bench_compute_metrics (the tokens/sec math
# behind `haven bench`). Sources lib/haven-bench.sh directly, so it runs on a
# dev host with no workspace container and no Ollama — just bash + jq.
#
# The "real run" fixture below is genuine /api/generate output captured from an
# RTX 3060 (qwen2.5-coder:3b, num_predict 64). If you change the math, the
# expected rates must still match this real sample.
###############################################################################

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="${HERE}/../../docker/workspace/scripts/lib/haven-bench.sh"
if [ ! -f "${LIB}" ]; then
  echo "FATAL: cannot find ${LIB}" >&2
  exit 2
fi
# shellcheck disable=SC1090
. "${LIB}"

PASS=0
FAIL=0

# floats are never bit-exact across jq builds — compare within a tolerance.
approx() { # $1=actual $2=expected $3=tolerance
  awk -v a="$1" -v e="$2" -v t="$3" 'BEGIN { d=a-e; if (d<0) d=-d; exit !(d<=t) }'
}

check_num() { # $1=label $2=actual $3=expected $4=tol
  if [ "$2" = "null" ] || [ -z "$2" ]; then
    FAIL=$((FAIL+1)); printf '  FAIL  %s: got null/empty, expected %s\n' "$1" "$3"; return
  fi
  if approx "$2" "$3" "$4"; then
    PASS=$((PASS+1)); printf '  ok    %s = %s (≈ %s)\n' "$1" "$2" "$3"
  else
    FAIL=$((FAIL+1)); printf '  FAIL  %s: got %s, expected %s (±%s)\n' "$1" "$2" "$3" "$4"
  fi
}

check_null() { # $1=label $2=actual
  if [ "$2" = "null" ]; then
    PASS=$((PASS+1)); printf '  ok    %s = null (guarded)\n' "$1"
  else
    FAIL=$((FAIL+1)); printf '  FAIL  %s: got %s, expected null\n' "$1" "$2"
  fi
}

# ── 1. real RTX 3060 run — math must match the captured numbers ───────────────
REAL='{"model":"qwen2.5-coder:3b-instruct-q4_K_M","eval_count":64,"eval_duration":604127000,"prompt_eval_count":40,"prompt_eval_duration":28919000,"load_duration":176170190,"total_duration":810714669}'

echo "real run (RTX 3060, 3B-Q4):"
metrics="$(printf '%s' "${REAL}" | _bench_compute_metrics)"
check_num "gen_tps"    "$(printf '%s' "${metrics}" | jq -r '.gen_tps')"    105.937990 0.001
check_num "prompt_tps" "$(printf '%s' "${metrics}" | jq -r '.prompt_tps')" 1383.173692 0.001
check_num "load_s"     "$(printf '%s' "${metrics}" | jq -r '.load_s')"     0.176170   0.000001
check_num "total_s"    "$(printf '%s' "${metrics}" | jq -r '.total_s')"    0.810715   0.000001

# ── 2. error response — must NOT divide by null, must emit null ───────────────
echo "error response (the null-divide guard):"
ERR='{"error":"model \"nope\" not found"}'
emetrics="$(printf '%s' "${ERR}" | _bench_compute_metrics)"
check_null "gen_tps"    "$(printf '%s' "${emetrics}" | jq -r '.gen_tps')"
check_null "prompt_tps" "$(printf '%s' "${emetrics}" | jq -r '.prompt_tps')"

# ── 3. zero duration — guard divide-by-zero too ───────────────────────────────
echo "zero eval_duration (divide-by-zero guard):"
ZERO='{"eval_count":10,"eval_duration":0}'
zmetrics="$(printf '%s' "${ZERO}" | _bench_compute_metrics)"
check_null "gen_tps" "$(printf '%s' "${zmetrics}" | jq -r '.gen_tps')"

echo ""
echo "PASS=${PASS} FAIL=${FAIL}"
[ "${FAIL}" -eq 0 ]
