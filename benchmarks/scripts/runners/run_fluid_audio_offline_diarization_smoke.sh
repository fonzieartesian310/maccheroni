#!/bin/zsh
set -euo pipefail

cache_root="${MACCHERONI_BENCHMARK_CACHE:-$HOME/Library/Caches/Maccheroni/benchmarks}"
audio="$cache_root/smoke/synthetic-10s.wav"
venv="$cache_root/venvs/mlx-audio"
hf="$venv/bin/hf"
model_id="FluidInference/speaker-diarization-coreml"
model_revision="1ed7a662fdc7109e36d822db793ee6eebdaf8594"
models_root="$cache_root/models/fluid-audio/diarization-$model_revision"
model_dir="$models_root/speaker-diarization"
run_id="${MACCHERONI_SMOKE_RUN_ID:-$model_revision}"
[[ -n "$run_id" && "$run_id" != *[^A-Za-z0-9._-]* ]] || {
  print -u2 "invalid MACCHERONI_SMOKE_RUN_ID: $run_id"
  exit 64
}
output="$cache_root/smoke/fluid-audio-offline-diarization-$run_id.json"
scratch="$cache_root/swift-scratch/fluid-diarization-harness"
script_dir=${0:A:h}
harness_root="$script_dir/fluid-diarization-harness"

[[ -x "$hf" ]] || {
  print -u2 "isolated hf CLI missing: $hf"
  print -u2 "Bootstrap the uv environment in benchmarks/env/tools.md."
  exit 69
}
"$script_dir/generate_synthetic_smoke.sh" "$audio"
mkdir -p "$model_dir" "$scratch" "${output:h}"
if [[ -e "$output" ]]; then
  print -u2 "refusing to overwrite existing smoke output: $output"
  exit 73
fi
"$hf" download "$model_id" \
  --revision "$model_revision" \
  --local-dir "$model_dir"
swift build --package-path "$harness_root" --scratch-path "$scratch"
swift run --package-path "$harness_root" --scratch-path "$scratch" \
  MaccheroniFluidDiarizationHarness \
  --audio "$audio" \
  --models-root "$models_root" \
  --output "$output"
