#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repository=${script_dir:h:h:h}
evaluation_root=${1:-"${repository}/benchmarks/runs/moss-long-audio"}
source_fixture="${repository}/benchmarks/runs/it-asr/fixtures/italian-dialogue"
cache_root=${MACCHERONI_BENCHMARK_CACHE:-"${HOME}/Library/Caches/Maccheroni/benchmarks"}
cli="${repository}/.build/release/maccheroni"
evaluator="${repository}/benchmarks/scripts/scoring/evaluate_moss_long_audio.py"

if [[ -e ${evaluation_root} || -L ${evaluation_root} ]]; then
  print -u2 "refusing to overwrite evaluation root: ${evaluation_root}"
  exit 73
fi
mkdir -p "${evaluation_root}"

git_head=$(git -C "${repository}" rev-parse HEAD)
evaluation_id="moss-long-audio-$(date -u +%Y%m%dT%H%M%SZ)-${git_head[1,8]}"

zsh "${repository}/scripts/build-moss-harness.zsh" --verify \
  >"${evaluation_root}/helper-verify.stdout.log" \
  2>"${evaluation_root}/helper-verify.stderr.log"
swift build --package-path "${repository}" -c release --product maccheroni \
  >"${evaluation_root}/swift-build.stdout.log" \
  2>"${evaluation_root}/swift-build.stderr.log"
MACCHERONI_BENCHMARK_CACHE="${cache_root}" "${cli}" doctor --profile it-dialogue \
  >"${evaluation_root}/doctor.stdout.log" \
  2>"${evaluation_root}/doctor.stderr.log"

/usr/bin/python3 - \
  "${source_fixture}" \
  "${evaluation_root}/fixture" \
  "${git_head}" <<'PY'
from __future__ import annotations

from hashlib import sha256
import json
from pathlib import Path
import sys
import wave


source = Path(sys.argv[1])
destination = Path(sys.argv[2]).resolve()
git_head = sys.argv[3]
destination.mkdir(parents=True, exist_ok=False)

EXPECTED_SOURCE_HASHES = {
    "input.wav": "ee83dbc56293bf3e3385401c164ebcd79bc375d0d0014f782529d97922900ef6",
    "reference.segments.json": "9ae3a9ca47483af2494571b98489a60687f9287a629bf6e6ba5d5f6d36669dbc",
    "terms.json": "ea0303ad9cdb949f16b51746606e2fd109def94ba13265bc5a9db81c7188d257",
    "glossary.txt": "c8f7772fc39200edd27bea0dba7ca90143d9acfc9c31f6ec198fa244dfd5d470",
    "selection.json": "dc928bc2196e94459fad5abd0b671c756c2abef190ffeff69fbf77f317fc3e36",
    "fixture-check.json": "a6490a453e8c5253254215b5e65df32a36645f56cd30502a8d3a8e60a32480eb",
}


def digest(path: Path) -> str:
    value = sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def write_json_create(path: Path, value: object) -> None:
    payload = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    with path.open("x", encoding="utf-8") as output:
        output.write(payload)


if source.is_symlink() or not source.is_dir():
    raise SystemExit("source fixture root must be a regular non-symlink directory")
source_files = {name: source / name for name in EXPECTED_SOURCE_HASHES}
for name, source_file in source_files.items():
    if source_file.is_symlink() or not source_file.is_file():
        raise SystemExit(f"source fixture artifact must be a regular non-symlink file: {name}")
source_hashes_before = {
    name: digest(source_file)
    for name, source_file in source_files.items()
}
if source_hashes_before != EXPECTED_SOURCE_HASHES:
    raise SystemExit("source fixture hashes do not match the pinned synthetic fixture")

selection_source = json.loads(source_files["selection.json"].read_text(encoding="utf-8"))
if selection_source.get("public_source", {}).get("kind") != "local_synthetic":
    raise SystemExit("source fixture selection is not local_synthetic")
fixture_check_source = json.loads(source_files["fixture-check.json"].read_text(encoding="utf-8"))
if fixture_check_source.get("passed") is not True:
    raise SystemExit("source fixture check did not pass")

source_wav = source_files["input.wav"]
source_reference = source_files["reference.segments.json"]
source_terms = source_files["terms.json"]
source_glossary = source_files["glossary.txt"]

with wave.open(str(source_wav), "rb") as input_wave:
    if (
        input_wave.getnchannels() != 1
        or input_wave.getsampwidth() != 2
        or input_wave.getframerate() != 16_000
        or input_wave.getcomptype() != "NONE"
    ):
        raise SystemExit("source fixture must be mono 16 kHz PCM16")
    source_frames = input_wave.readframes(input_wave.getnframes())
    source_frame_count = input_wave.getnframes()

block_frame_count = 30 * 16_000
if source_frame_count >= block_frame_count:
    raise SystemExit("source dialogue must fit inside one 30-second block")
padding = b"\0" * ((block_frame_count - source_frame_count) * 2)
input_path = destination / "input-600s.wav"
with input_path.open("xb") as raw_output:
    with wave.open(raw_output, "wb") as output_wave:
        output_wave.setnchannels(1)
        output_wave.setsampwidth(2)
        output_wave.setframerate(16_000)
        for _ in range(20):
            output_wave.writeframesraw(source_frames)
            output_wave.writeframesraw(padding)

reference_source = json.loads(source_reference.read_text(encoding="utf-8"))
reference_segments = []
for repeat_index in range(20):
    offset = repeat_index * 30.0
    for segment in reference_source["segments"]:
        repeated = dict(segment)
        repeated["start_s"] = float(segment["start_s"]) + offset
        repeated["end_s"] = float(segment["end_s"]) + offset
        repeated["repeat_index"] = repeat_index
        reference_segments.append(repeated)
reference = {
    "num_speakers": reference_source["num_speakers"],
    "schema_version": "1.0.0",
    "segments": reference_segments,
    "source": {
        "block_duration_s": 30,
        "duration_s": 600,
        "file_name": input_path.name,
        "repeat_count": 20,
        "sha256": digest(input_path),
    },
}
reference_path = destination / "reference.segments.json"
write_json_create(reference_path, reference)

rttm_path = destination / "reference.rttm"
with rttm_path.open("x", encoding="utf-8") as output:
    for segment in reference_segments:
        start_s = float(segment["start_s"])
        duration_s = float(segment["end_s"]) - start_s
        if duration_s <= 0:
            raise SystemExit("source reference contains a non-positive segment duration")
        speaker = str(segment["speaker"])
        output.write(
            f"SPEAKER input-600s 1 {start_s:.6f} {duration_s:.6f} "
            f"<NA> <NA> {speaker} <NA> <NA>\n"
        )

terms_source = json.loads(source_terms.read_text(encoding="utf-8"))
terms = [
    {"reference_count": int(item["reference_count"]) * 20, "term": item["term"]}
    for item in terms_source
]
terms_path = destination / "terms.json"
write_json_create(terms_path, terms)

glossary_path = destination / "glossary.txt"
with glossary_path.open("xb") as output:
    output.write(source_glossary.read_bytes())

source_hashes_after = {
    name: digest(source_file)
    for name, source_file in source_files.items()
}
if source_hashes_after != EXPECTED_SOURCE_HASHES:
    raise SystemExit("source fixture hashes no longer match the pinned synthetic fixture")
if source_hashes_after != source_hashes_before:
    raise SystemExit("fixture generation changed a source artifact")

write_json_create(
    destination / "provenance.json",
    {
        "block_duration_s": 30,
        "duration_s": 600,
        "generated": {
            "glossary_sha256": digest(glossary_path),
            "input_sha256": digest(input_path),
            "reference_rttm_path": rttm_path.name,
            "reference_rttm_sha256": digest(rttm_path),
            "reference_segments_sha256": digest(reference_path),
            "terms_sha256": digest(terms_path),
        },
        "generator": "run_moss_long_audio_eval.sh",
        "git_head": git_head,
        "repeat_count": 20,
        "sample_rate_hz": 16_000,
        "source_hashes_after": source_hashes_after,
        "source_hashes_before": source_hashes_before,
    },
)
PY

fixture_input="${evaluation_root}/fixture/input-600s.wav"
fixture_glossary="${evaluation_root}/fixture/glossary.txt"

run_case() {
  local identifier=$1
  local input=$2
  local leaf_seconds=$3
  local maximum_tokens=$4
  local case_directory="${evaluation_root}/cases/${identifier}"
  local runs_directory="${case_directory}/runs"
  mkdir -p "${runs_directory}"
  local input_sha_before
  input_sha_before=$(shasum -a 256 "${input}" | awk '{print $1}')
  local stdout_path="${case_directory}/stdout.log"
  local stderr_path="${case_directory}/stderr-time.log"
  local command_status

  set +e
  /usr/bin/time -l /usr/bin/env \
    MACCHERONI_BENCHMARK_CACHE="${cache_root}" \
    MACCHERONI_ENABLE_BENCHMARK_OVERRIDES=1 \
    MACCHERONI_MOSS_EVAL_LEAF_SECONDS="${leaf_seconds}" \
    MACCHERONI_MOSS_EVAL_MAX_TOKENS="${maximum_tokens}" \
    "${cli}" run "${input}" \
      --profile it-dialogue \
      --output-root "${runs_directory}" \
      --glossary "${fixture_glossary}" \
      >"${stdout_path}" 2>"${stderr_path}"
  command_status=$?
  set -e

  local input_sha_after
  input_sha_after=$(shasum -a 256 "${input}" | awk '{print $1}')
  local printed_run
  printed_run=$(tail -n 1 "${stdout_path}" 2>/dev/null || true)

  /usr/bin/python3 - \
    "${evaluation_root}" \
    "${case_directory}" \
    "${identifier}" \
    "${input}" \
    "${input_sha_before}" \
    "${input_sha_after}" \
    "${leaf_seconds}" \
    "${maximum_tokens}" \
    "${command_status}" \
    "${printed_run}" \
    "${git_head}" \
    "${cli}" <<'PY'
from __future__ import annotations

from hashlib import sha256
import json
from pathlib import Path
import sys


root = Path(sys.argv[1]).resolve()
case_directory = Path(sys.argv[2]).resolve()
identifier = sys.argv[3]
input_path = Path(sys.argv[4]).resolve()
before = sys.argv[5]
after = sys.argv[6]
leaf_seconds = int(sys.argv[7])
maximum_tokens = int(sys.argv[8])
exit_code = int(sys.argv[9])
printed_run = Path(sys.argv[10]).resolve() if sys.argv[10] else None
git_head = sys.argv[11]
cli = sys.argv[12]


def digest(path: Path) -> str:
    value = sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


runs_directory = (case_directory / "runs").resolve()
run_candidates = sorted(
    path
    for path in runs_directory.iterdir()
    if path.is_dir() and not path.is_symlink()
)
if printed_run is not None:
    if not (
        printed_run.is_dir()
        and printed_run.parent == runs_directory
        and run_candidates == [printed_run]
    ):
        raise SystemExit("printed run is not the unique direct child")
elif len(run_candidates) != 1:
    raise SystemExit("failed command did not preserve one direct-child run")
run_path = str(run_candidates[0].relative_to(root))
execution = {
    "command": [
        cli,
        "run",
        str(input_path),
        "--profile",
        "it-dialogue",
        "--output-root",
        str(case_directory / "runs"),
        "--glossary",
        str(root / "fixture" / "glossary.txt"),
    ],
    "environment": {
        "MACCHERONI_ENABLE_BENCHMARK_OVERRIDES": "1",
        "MACCHERONI_MOSS_EVAL_LEAF_SECONDS": str(leaf_seconds),
        "MACCHERONI_MOSS_EVAL_MAX_TOKENS": str(maximum_tokens),
    },
    "exit_code": exit_code,
    "git_head": git_head,
    "id": identifier,
    "input_sha256_after": after,
    "input_sha256_before": before,
    "leaf_seconds": leaf_seconds,
    "maximum_tokens": maximum_tokens,
    "run_path": run_path,
    "stderr_time_sha256": digest(case_directory / "stderr-time.log"),
    "stdout_sha256": digest(case_directory / "stdout.log"),
}
with (case_directory / "execution.json").open("x", encoding="utf-8") as output:
    json.dump(execution, output, ensure_ascii=False, indent=2, sort_keys=True)
    output.write("\n")
PY

  if [[ ${input_sha_before} != ${input_sha_after} ]]; then
    print -u2 "${identifier} changed its input; preserved ${evaluation_root}"
    return 1
  fi
  if [[ ${identifier} == warmup || ${identifier} == forced-recovery-240-1024 ]] \
    && (( command_status != 0 )); then
    print -u2 "${identifier} exited ${command_status}; preserved ${evaluation_root}"
    return ${command_status}
  fi
}

# One short product run warms the same model and diarization paths before the
# measured matrix. It is preserved but excluded from ranking.
run_case "warmup" "${source_fixture}/input.wav" 120 5120

run_case "candidate-120" "${fixture_input}" 120 5120
run_case "candidate-240" "${fixture_input}" 240 5120
run_case "candidate-300" "${fixture_input}" 300 5120
run_case "forced-recovery-240-1024" "${fixture_input}" 240 1024

/usr/bin/python3 - \
  "${evaluation_root}" \
  "${evaluation_id}" \
  "${git_head}" <<'PY'
from __future__ import annotations

from hashlib import sha256
import json
from pathlib import Path
import sys


root = Path(sys.argv[1]).resolve()
evaluation_id = sys.argv[2]
git_head = sys.argv[3]
fixture_root = root / "fixture"


def digest(path: Path) -> str:
    value = sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


provenance = json.loads((fixture_root / "provenance.json").read_text(encoding="utf-8"))
cases = []
for identifier, leaf_seconds, maximum_tokens, forced in (
    ("candidate-120", 120, 5120, False),
    ("candidate-240", 240, 5120, False),
    ("candidate-300", 300, 5120, False),
    ("forced-recovery-240-1024", 240, 1024, True),
):
    cases.append(
        {
            "execution_path": f"cases/{identifier}/execution.json",
            "forced_recovery": forced,
            "id": identifier,
            "leaf_seconds": leaf_seconds,
            "maximum_tokens": maximum_tokens,
        }
    )
experiment = {
    "cases": cases,
    "evaluation_id": evaluation_id,
    "fixture": {
        "block_duration_s": provenance["block_duration_s"],
        "duration_s": provenance["duration_s"],
        "glossary_path": "fixture/glossary.txt",
        "glossary_sha256": digest(fixture_root / "glossary.txt"),
        "input_path": "fixture/input-600s.wav",
        "input_sha256": digest(fixture_root / "input-600s.wav"),
        "provenance_path": "fixture/provenance.json",
        "provenance_sha256": digest(fixture_root / "provenance.json"),
        "reference_rttm_path": "fixture/reference.rttm",
        "reference_rttm_sha256": provenance["generated"]["reference_rttm_sha256"],
        "reference_segments_path": "fixture/reference.segments.json",
        "reference_segments_sha256": digest(fixture_root / "reference.segments.json"),
        "repeat_count": provenance["repeat_count"],
        "sample_rate_hz": provenance["sample_rate_hz"],
        "terms_path": "fixture/terms.json",
        "terms_sha256": digest(fixture_root / "terms.json"),
    },
    "git_head": git_head,
    "schema_version": "1.0.0",
    "warmup_execution_path": "cases/warmup/execution.json",
}
with (root / "experiment.json").open("x", encoding="utf-8") as output:
    json.dump(experiment, output, ensure_ascii=False, indent=2, sort_keys=True)
    output.write("\n")
PY

/usr/bin/python3 "${evaluator}" "${evaluation_root}"
print "preserved evaluation: ${evaluation_root}"
