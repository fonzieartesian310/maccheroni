#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  print -u2 "usage: $0 <output-wav>"
  exit 64
fi

script_dir=${0:A:h}
output_wav=${1:A}
mkdir -p "${output_wav:h}"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/maccheroni-smoke.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

# This is local macOS speech synthesis, not a recording or downloaded audio.
/usr/bin/say -v Samantha -o "$work_dir/source.aiff" \
  "This is a synthetic Maccheroni benchmark smoke test. Alice says hello. Bob says the glossary term Qwen three ASR. This sentence is repeated so the fixed ten second fixture contains synthesized speech."
/usr/bin/afconvert -f WAVE -d LEI16@16000 "$work_dir/source.aiff" "$work_dir/source.wav"
/usr/bin/python3 "$script_dir/trim_wave.py" "$work_dir/source.wav" "$output_wav"
