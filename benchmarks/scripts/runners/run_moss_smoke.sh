#!/bin/zsh
set -euo pipefail

cache_root="${MACCHERONI_BENCHMARK_CACHE:-$HOME/Library/Caches/Maccheroni/benchmarks}"
script_dir=${0:A:h}
venv="$cache_root/venvs/mlx-audio"
hf="$venv/bin/hf"
model_id="aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8"
model_revision="90aa65287111a327db98eb83e325bd5332945edd"
model_dir="$cache_root/models/moss-transcribe-diarize-0.9b-mlx-int8-$model_revision"
scratch="$cache_root/swift-scratch/moss-harness"
harness_binary="$scratch/arm64-apple-macosx/release/MaccheroniMossHarness"
audio="$cache_root/smoke/synthetic-10s.wav"
glossary="$cache_root/smoke/moss-smoke-glossary.txt"
run_id="${MACCHERONI_SMOKE_RUN_ID:-$model_revision}"
[[ -n "$run_id" && "$run_id" != *[^A-Za-z0-9._-]* ]] || {
  print -u2 "invalid MACCHERONI_SMOKE_RUN_ID: $run_id"
  exit 64
}
output="$cache_root/smoke/moss-smoke-$run_id.json"
max_tokens="${MACCHERONI_MOSS_SMOKE_MAX_TOKENS:-5120}"
language="${MACCHERONI_MOSS_SMOKE_LANGUAGE:-auto}"

[[ -x "$hf" ]] || { print -u2 "hf CLI missing: $hf"; exit 69; }
"$script_dir/generate_synthetic_smoke.sh" "$audio"
mkdir -p "$cache_root/models" "$cache_root/swift-scratch" "$cache_root/smoke"
if [[ ! -f "$glossary" ]]; then
  print 'Qwen3-ASR' > "$glossary"
fi
if [[ -e "$output" ]]; then
  print -u2 "refusing to overwrite existing smoke output: $output"
  exit 73
fi
"$hf" download "$model_id" --revision "$model_revision" --local-dir "$model_dir"
zsh "$script_dir/../../../scripts/build-moss-harness.zsh"
zsh "$script_dir/../../../scripts/build-moss-harness.zsh" --verify
[[ -x "$harness_binary" ]] || { print -u2 "MOSS harness missing after build: $harness_binary"; exit 70; }
"$harness_binary" \
  --audio "$audio" \
  --model-dir "$model_dir" \
  --glossary "$glossary" \
  --max-tokens "$max_tokens" \
  --language "$language" \
  --output "$output"
