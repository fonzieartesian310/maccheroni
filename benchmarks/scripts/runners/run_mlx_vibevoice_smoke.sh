#!/bin/zsh
set -euo pipefail

cache_root="${MACCHERONI_BENCHMARK_CACHE:-$HOME/Library/Caches/Maccheroni/benchmarks}"
venv="$cache_root/venvs/mlx-audio"
audio="$cache_root/smoke/synthetic-10s.wav"
model_id="microsoft/VibeVoice-ASR"
model_revision="d0c9efdb8d614685062c04425d91e01b6f37d944"
run_id="${MACCHERONI_SMOKE_RUN_ID:-$model_revision}"
[[ -n "$run_id" && "$run_id" != *[^A-Za-z0-9._-]* ]] || {
  print -u2 "invalid MACCHERONI_SMOKE_RUN_ID: $run_id"
  exit 64
}
output="$cache_root/smoke/vibevoice-$run_id"
script_dir=${0:A:h}

[[ -x "$venv/bin/mlx_audio.stt.generate" ]] || {
  print -u2 "mlx-audio environment missing: $venv"
  exit 69
}
"$script_dir/generate_synthetic_smoke.sh" "$audio"
if [[ -e "$output.json" ]]; then
  print -u2 "refusing to overwrite existing smoke output: $output.json"
  exit 73
fi
# mlx-audio 0.4.6 loads VibeVoice's remote model module only from a repository
# ID; an equivalent local snapshot path is rejected as an unsupported model
# type. The check records and verifies the exact HF cache snapshot separately.
HF_HOME="$cache_root/models/huggingface" "$venv/bin/mlx_audio.stt.generate" \
  --model "$model_id" \
  --audio "$audio" \
  --output-path "$output" \
  --format json \
  --language en \
  --context 'Smoke test names: Alice, Bob. Glossary term: Qwen3-ASR.'
