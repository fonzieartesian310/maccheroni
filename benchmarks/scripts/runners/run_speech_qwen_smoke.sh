#!/bin/zsh
set -euo pipefail

cache_root="${MACCHERONI_BENCHMARK_CACHE:-$HOME/Library/Caches/Maccheroni/benchmarks}"
audio="$cache_root/smoke/synthetic-10s.wav"
model_id="aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
model_revision="e5450a26d1fd417c45fc9c405651ddc3180a27a6"
model_quantization="8-bit"
run_id="${MACCHERONI_SMOKE_RUN_ID:-$model_revision}"
[[ -n "$run_id" && "$run_id" != *[^A-Za-z0-9._-]* ]] || {
  print -u2 "invalid MACCHERONI_SMOKE_RUN_ID: $run_id"
  exit 64
}
output="$cache_root/smoke/speech-qwen-$run_id.log"
script_dir=${0:A:h}

"$script_dir/generate_synthetic_smoke.sh" "$audio"
if [[ -e "$output" ]]; then
  print -u2 "refusing to overwrite existing smoke output: $output"
  exit 73
fi
# The speech CLI resolves 1.7B to the pinned 8-bit MLX model listed in
# benchmarks/env/models.md. Do not substitute a smaller model silently.
{
  print "model_hf_id=$model_id"
  print "model_revision=$model_revision"
  print "model_quantization=$model_quantization"
  HF_HOME="$cache_root/models/huggingface" speech transcribe "$audio" \
    --model 1.7B \
    --language en \
    --context 'Smoke test names: Alice, Bob. Glossary term: Qwen3-ASR.'
} | tee "$output"
