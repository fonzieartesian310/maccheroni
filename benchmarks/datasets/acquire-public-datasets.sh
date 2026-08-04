#!/usr/bin/env bash
# Download only the immutable, pinned public source artifacts used by T1.
# The destination is intentionally gitignored: these are downloaded audio
# artifacts, not repository fixtures.  This script never rewrites a source
# recording; re-running it reuses Hugging Face's verified local files.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
destination="${1:-"$repo_root/benchmarks/samples/public"}"

command -v hf >/dev/null || {
  echo "error: Hugging Face CLI (hf) is required" >&2
  exit 1
}
command -v uv >/dev/null || {
  echo "error: uv is required to create the RTTM reference files" >&2
  exit 1
}
hf auth whoami >/dev/null

mkdir -p "$destination"

# FLEURS language test-path artifacts.  Row counts are verified separately:
# the pinned Parquet files currently disagree with the dataset-card split counts.
hf download google/fleurs parquet-data/ko_kr/test-00000-of-00001.parquet \
  --repo-type dataset \
  --revision 70bb2e84b976b7e960aa89f1c648e09c59f894dd \
  --local-dir "$destination/fleurs"
hf download google/fleurs parquet-data/it_it/test-00000-of-00001.parquet \
  --repo-type dataset \
  --revision 70bb2e84b976b7e960aa89f1c648e09c59f894dd \
  --local-dir "$destination/fleurs"
hf download google/fleurs parquet-data/en_us/test-00000-of-00001.parquet \
  --repo-type dataset \
  --revision 70bb2e84b976b7e960aa89f1c648e09c59f894dd \
  --local-dir "$destination/fleurs"

# HiKE: complete public Korean-English code-switching test split.
hf download thetaone-ai/HiKE data/test-00000-of-00001.parquet \
  --repo-type dataset \
  --revision 255609b24005e1fcce3f8b3a452260aaf2872cc9 \
  --local-dir "$destination/hike"

# VoxConverse: one complete dev shard, selected as the reproducible T1 subset.
hf download diarizers-community/voxconverse data/dev-00000-of-00005.parquet \
  --repo-type dataset \
  --revision 3acfa1b45ca4b7419aee999d67d94c617f9c9d47 \
  --local-dir "$destination/voxconverse"

uv run --with pyarrow python "$repo_root/benchmarks/datasets/export-voxconverse-rttm.py" \
  --source "$destination/voxconverse/data/dev-00000-of-00005.parquet" \
  --output-dir "$destination/voxconverse/rttm"

echo "Downloaded public benchmark sources to: $destination"
