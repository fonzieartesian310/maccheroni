#!/bin/zsh
# Create or update the external local-LLM runtime without rewriting model cache data.
set -euo pipefail

repo_root="${0:A:h:h}"
python_project="$repo_root/Sources/MaccheroniPostprocess/Python"
benchmark_cache="${MACCHERONI_BENCHMARK_CACHE:-$HOME/Library/Caches/Maccheroni/benchmarks}"
venv="$benchmark_cache/venvs/mlx-vlm"
hf_home="${HF_HOME:-$HOME/.cache/huggingface}"
hf_cache="$hf_home/hub"
model_id="mlx-community/gemma-4-12B-it-qat-4bit"
revision="e70c6b3ba0979b3357dcd2f223ad8bde7787a6b6"
quantization="qat-int4"

command -v uv >/dev/null || {
  print -u2 "error: uv is required"
  exit 1
}
command -v hf >/dev/null || {
  print -u2 "error: Hugging Face CLI (hf) is required"
  exit 1
}

mkdir -p "$benchmark_cache/venvs" "$hf_cache"
UV_PROJECT_ENVIRONMENT="$venv" uv sync --frozen --inexact --project "$python_project" --python 3.12
hf download "$model_id" --revision "$revision" --cache-dir "$hf_cache"

snapshot="$hf_cache/models--mlx-community--gemma-4-12B-it-qat-4bit/snapshots/$revision"
[[ -d "$snapshot" ]] || {
  print -u2 "error: pinned model snapshot is missing after download: $snapshot"
  exit 1
}
print "Postprocess runtime is ready: model=$model_id revision=$revision quantization=$quantization snapshot=$snapshot"
