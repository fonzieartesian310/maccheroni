#!/bin/zsh
set -euo pipefail

if (( $# != 1 )) || [[ "$1" != "pyannote" && "$1" != "community1" ]]; then
  print -u2 "usage: $0 <pyannote|community1>"
  exit 64
fi

engine="$1"
cache_root="${MACCHERONI_BENCHMARK_CACHE:-$HOME/Library/Caches/Maccheroni/benchmarks}"
audio="$cache_root/smoke/synthetic-10s.wav"
run_id="${MACCHERONI_SMOKE_RUN_ID:-$engine-pinned}"
[[ -n "$run_id" && "$run_id" != *[^A-Za-z0-9._-]* ]] || {
  print -u2 "invalid MACCHERONI_SMOKE_RUN_ID: $run_id"
  exit 64
}
output="$cache_root/smoke/speech-diarization-$engine-$run_id.log"
script_dir=${0:A:h}

"$script_dir/generate_synthetic_smoke.sh" "$audio"
if [[ -e "$output" ]]; then
  print -u2 "refusing to overwrite existing smoke output: $output"
  exit 73
fi
{
  if [[ "$engine" == "pyannote" ]]; then
    print 'model_hf_id=aufklarer/Pyannote-Segmentation-MLX + aufklarer/WeSpeaker-ResNet34-LM-MLX'
    print 'model_revision=abef0110277063f0ea117a802832a3eba22af84c + 26499ce11ad1b48ac96aacc8d6fa433f941bdc96'
    print 'model_quantization=float32 + float32'
  else
    print 'model_hf_id=aufklarer/Pyannote-Community-1-CoreML'
    print 'model_revision=a14e6c420d56e8472850649b016a486fd0acbe81'
    print 'model_quantization=CoreML FP32 model graph and weights'
  fi
  HF_HOME="$cache_root/models/huggingface" speech diarize "$audio" \
    --engine "$engine" \
    --json
} | tee "$output"
