#!/bin/zsh
set -euo pipefail

cache_root="${MACCHERONI_BENCHMARK_CACHE:-$HOME/Library/Caches/Maccheroni/benchmarks}"
source_root="$cache_root/fluid-audio-source"
binary="$source_root/.build/arm64-apple-macosx/debug/fluidaudiocli"
audio="$cache_root/smoke/synthetic-10s.wav"
venv="$cache_root/venvs/mlx-audio"
hf="$venv/bin/hf"
model_id="FluidInference/parakeet-tdt-0.6b-v3-coreml"
model_revision="aed02740059203c4a87495924f685de3722ae9ce"
models_root="$cache_root/models/fluid-audio/parakeet-$model_revision"
model_dir="$models_root/parakeet-tdt-0.6b-v3"
run_id="${MACCHERONI_SMOKE_RUN_ID:-$model_revision}"
[[ -n "$run_id" && "$run_id" != *[^A-Za-z0-9._-]* ]] || {
  print -u2 "invalid MACCHERONI_SMOKE_RUN_ID: $run_id"
  exit 64
}
output="$cache_root/smoke/fluid-audio-v3-$run_id.json"
script_dir=${0:A:h}

[[ -x "$binary" ]] || {
  print -u2 "FluidAudio CLI missing: $binary"
  print -u2 "Bootstrap the source at the revision in benchmarks/env/tools.md."
  exit 69
}
[[ -x "$hf" ]] || {
  print -u2 "isolated hf CLI missing: $hf"
  print -u2 "Bootstrap the uv environment in benchmarks/env/tools.md."
  exit 69
}
"$script_dir/generate_synthetic_smoke.sh" "$audio"
mkdir -p "$model_dir" "${output:h}"
if [[ -e "$output" ]]; then
  print -u2 "refusing to overwrite existing smoke output: $output"
  exit 73
fi
"$hf" download "$model_id" \
  --revision "$model_revision" \
  --local-dir "$model_dir"
"$binary" transcribe "$audio" \
  --model-version v3 \
  --model-dir "$model_dir" \
  --encoder-precision int8 \
  --language en \
  --output-json "$output"
