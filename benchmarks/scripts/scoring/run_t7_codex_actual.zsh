#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h:h}
cd "$repo_root"

if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  print -u2 "error: actual Codex evidence requires a clean tracked worktree"
  exit 2
fi

git_head=$(git rev-parse HEAD)
short_head=$(git rev-parse --short=8 HEAD)
timestamp=$(/bin/date -u +%Y%m%dT%H%M%SZ)
identifier=$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')
run_id="t7-codex-actual-${timestamp}-${short_head}-${identifier}"
run_root="$repo_root/benchmarks/runs/e2e/t7-codex-actual"
run_dir="$run_root/$run_id"
/bin/mkdir -p "$run_root"
/bin/mkdir "$run_dir"

evidence_path="$run_dir/evidence.json"
result_path="$run_dir/test-result.json"
log_path="$run_dir/test.log"
status_path="$run_dir/exit-status.txt"
checksums_path="$run_dir/checksums.sha256"
swift_bin=$(/usr/bin/xcrun --find swift)
cache_root="${TMPDIR:-/private/tmp}/maccheroni-t7-codex-actual-cache"
temporary_root=${TMPDIR:-/private/tmp}
temporary_root=${temporary_root%/}
user_root=${HOME:-}

redaction_arguments=(-e "s|$repo_root|<repo>|g")
if [[ -n "$user_root" ]]; then
  redaction_arguments+=(-e "s|$user_root|<home>|g")
fi
if [[ -n "$temporary_root" ]]; then
  redaction_arguments+=(-e "s|$temporary_root|<tmp>|g")
fi

print -r -- "run_id=$run_id" > "$run_dir/run-metadata.txt"
print -r -- "git_head=$git_head" >> "$run_dir/run-metadata.txt"
print -r -- "fixture=inline-public-synthetic-text-only" >> "$run_dir/run-metadata.txt"
print -r -- "private_content_supplied_to_test=false" >> "$run_dir/run-metadata.txt"
print -r -- "audio_bytes_supplied_to_backend=false" >> "$run_dir/run-metadata.txt"
print -r -- "operating_system_read_scope_verified=false" >> "$run_dir/run-metadata.txt"

set +e
PATH=/usr/bin:/bin:/usr/sbin:/sbin \
CLANG_MODULE_CACHE_PATH="$cache_root/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$cache_root/swift" \
MACCHERONI_RUN_CODEX_TRANSLATION_INTEGRATION=1 \
MACCHERONI_CODEX_TRANSLATION_EVIDENCE_PATH="$evidence_path" \
MACCHERONI_EVIDENCE_RUN_ID="$run_id" \
MACCHERONI_EVIDENCE_GIT_HEAD="$git_head" \
"$swift_bin" test --disable-sandbox \
  --filter actualCodexTranslationExecutesSyntheticTextOnlyFixture 2>&1 \
  | /usr/bin/sed "${redaction_arguments[@]}" \
  | /usr/bin/tee "$log_path"
pipeline_statuses=("${pipestatus[@]}")
test_status=${pipeline_statuses[1]}
redaction_status=${pipeline_statuses[2]}
tee_status=${pipeline_statuses[3]}
set -e

print -r -- "swift_test_exit_status=$test_status" > "$status_path"
print -r -- "redaction_exit_status=$redaction_status" >> "$status_path"
print -r -- "tee_exit_status=$tee_status" >> "$status_path"

if (( test_status != 0 || redaction_status != 0 || tee_status != 0 )); then
  print -u2 "error: actual Codex test pipeline failed; partial evidence is preserved"
  print -r -- "run_dir=benchmarks/runs/e2e/t7-codex-actual/$run_id"
  (( test_status != 0 )) && exit "$test_status"
  (( redaction_status != 0 )) && exit "$redaction_status"
  exit "$tee_status"
fi

for required_path in "$evidence_path" "$log_path" "$status_path" \
  "$run_dir/run-metadata.txt"; do
  if [[ ! -s "$required_path" ]]; then
    print -u2 "error: successful test did not create every required evidence file"
    print -r -- "run_dir=benchmarks/runs/e2e/t7-codex-actual/$run_id"
    exit 3
  fi
done

/usr/bin/python3 -c '
import json
import sys

evidence_path = sys.argv[1]
result_path = sys.argv[2]
expected_head = sys.argv[3]
expected_run_id = sys.argv[4]
with open(evidence_path, encoding="utf-8") as handle:
    evidence = json.load(handle)
required_evidence = {
    "verdict": "passed",
    "git_head": expected_head,
    "run_id": expected_run_id,
    "fixture": "inline-public-synthetic-text-only",
    "private_content_supplied_to_test": False,
    "audio_bytes_supplied_to_backend": False,
    "input_unchanged": True,
    "forbidden_structure_fields_absent": True,
}
if any(evidence.get(key) != value for key, value in required_evidence.items()):
    raise SystemExit("evidence contract mismatch")
if evidence.get("input_sha256_before") != evidence.get("input_sha256_after"):
    raise SystemExit("input hash mismatch")
if any(not evidence.get(key) for key in ("model_id", "model_revision", "quantization")):
    raise SystemExit("model identity tuple missing")
payload = {
    "schema_version": "1.0",
    "test_name": "actualCodexTranslationExecutesSyntheticTextOnlyFixture",
    "swift_test_exit_status": int(sys.argv[5]),
    "redaction_exit_status": int(sys.argv[6]),
    "tee_exit_status": int(sys.argv[7]),
    "passed": True,
    "evidence_file": "evidence.json",
    "log_file": "test.log",
}
with open(result_path, "x", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
' "$evidence_path" "$result_path" "$git_head" "$run_id" \
  "$test_status" "$redaction_status" "$tee_status"

for required_path in "$result_path"; do
  if [[ ! -s "$required_path" ]]; then
    print -u2 "error: successful test did not create every required evidence file"
    print -r -- "run_dir=benchmarks/runs/e2e/t7-codex-actual/$run_id"
    exit 3
  fi
done

if /usr/bin/grep -Fq "Ciao, verifichiamo Maccheroni e Codex CLI." \
  "$log_path" "$result_path"; then
  print -u2 "error: evidence output contained synthetic prompt text"
  exit 4
fi

(
  cd "$run_dir"
  /usr/bin/shasum -a 256 evidence.json test-result.json test.log \
    exit-status.txt run-metadata.txt > checksums.sha256
)

if /usr/bin/grep -Eq '/Users/|/var/folders/|/private/var/|/private/tmp/' \
  "$evidence_path" "$result_path" "$log_path" "$status_path" \
  "$run_dir/run-metadata.txt" "$checksums_path"; then
  print -u2 "error: evidence output contained an unredacted personal or temporary path"
  exit 5
fi

print -r -- "run_dir=benchmarks/runs/e2e/t7-codex-actual/$run_id"
exit 0
