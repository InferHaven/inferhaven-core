# shellcheck shell=bash
# InferHaven — bench metric math.
#
# Pure + sourceable: reads one Ollama /api/generate JSON object on stdin and
# emits computed tokens/sec metrics as compact JSON. No network, no globals —
# so scripts/tests/bench-parse.sh can source this and test the math on any host
# with zero container. cmd_bench (haven.sh) handles the curl + the pretty print.
#
# Ollama /api/generate (stream:false) returns these in NANOSECONDS:
#   eval_count / eval_duration               → tokens generated / time generating
#   prompt_eval_count / prompt_eval_duration → prompt tokens / time ingesting them
#   load_duration                            → weights → VRAM (big on a cold run)
#   total_duration                           → end to end
#
# The headline number is gen_tps = eval_count / (eval_duration / 1e9).
# eval_duration EXCLUDES load + prompt-eval, so it is the honest pure decode
# rate even on a cold first run — that is the number worth quoting.

# _bench_compute_metrics — stdin: one /api/generate JSON object
#                          stdout: compact JSON with raw fields + computed rates
#
# Null-safe by design: an error response (or a model that returned no stats)
# has missing/zero fields, so each rate is guarded — we emit `null` instead of
# dividing by null/zero and crashing. (This is exactly the
# "null (null) and number (1E+9) cannot be divided" failure, handled.)
_bench_compute_metrics() {
  jq '
    # a tokens/sec helper: count / (duration_ns / 1e9), or null if unusable
    def tps($count; $dur):
      if ($count != null and $dur != null and $dur > 0)
      then ($count / ($dur / 1e9))
      else null end;
    # nanoseconds → seconds, or null
    def secs($ns):
      if $ns != null then ($ns / 1e9) else null end;

    {
      model:                .model,
      eval_count:           .eval_count,
      eval_duration:        .eval_duration,
      prompt_eval_count:    .prompt_eval_count,
      prompt_eval_duration: .prompt_eval_duration,
      load_duration:        .load_duration,
      total_duration:       .total_duration,
      gen_tps:    tps(.eval_count;        .eval_duration),
      prompt_tps: tps(.prompt_eval_count; .prompt_eval_duration),
      load_s:     secs(.load_duration),
      total_s:    secs(.total_duration)
    }'
}
