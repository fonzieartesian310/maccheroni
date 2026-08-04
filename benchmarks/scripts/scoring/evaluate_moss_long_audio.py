#!/usr/bin/env python3
"""Validate and score immutable MOSS long-audio evaluation runs."""

from __future__ import annotations

from collections import Counter
from hashlib import sha256
import json
import math
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, Iterable, Sequence
import wave


EVALUATOR_SOURCE = Path(__file__).resolve()
SCORING_ROOT = Path(__file__).resolve().parent
if str(SCORING_ROOT) not in sys.path:
    sys.path.insert(0, str(SCORING_ROOT))

from metrics import (  # noqa: E402
    count_term_occurrences,
    term_recall,
    text_error_rate,
    utterance_omissions,
)


MODEL = {
    "role": "asr",
    "hf_model_id": "aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8",
    "revision": "90aa65287111a327db98eb83e325bd5332945edd",
    "quantization": "int8-decoder+fp16-audio-vq-kv",
}
CANDIDATE_SECONDS = (120, 240, 300)
SAMPLE_RATE_HZ = 16_000
INPUT_DURATION_S = 600.0
INPUT_SAMPLES = int(INPUT_DURATION_S * SAMPLE_RATE_HZ)
MAXIMUM_TOKENS = 5_120
FORCED_MAXIMUM_TOKENS = 1_024
CONTEXT_HARD_CAP_TOKENS = 131_072
EXPECTED_GLOSSARY_ITEMS = 9
INVALID_EOS_OUTPUT_CODE = "invalid_eos_output"
TIMELINE_FRAME_STEP_S = 0.02
TIMELINE_MINIMUM_AGREEMENT = 0.995
PINNED_SYNTHETIC_SOURCE_HASHES = {
    "fixture-check.json": "a6490a453e8c5253254215b5e65df32a36645f56cd30502a8d3a8e60a32480eb",
    "glossary.txt": "c8f7772fc39200edd27bea0dba7ca90143d9acfc9c31f6ec198fa244dfd5d470",
    "input.wav": "ee83dbc56293bf3e3385401c164ebcd79bc375d0d0014f782529d97922900ef6",
    "reference.segments.json": "9ae3a9ca47483af2494571b98489a60687f9287a629bf6e6ba5d5f6d36669dbc",
    "selection.json": "dc928bc2196e94459fad5abd0b671c756c2abef190ffeff69fbf77f317fc3e36",
    "terms.json": "ea0303ad9cdb949f16b51746606e2fd109def94ba13265bc5a9db81c7188d257",
}
PROVENANCE_ONLY_FIELDS = ("evaluator_git_head", "evaluator_source_sha256")
QUALITY_LIMITS = {
    "cer": 0.10,
    "wer": 0.15,
    "term_recall": 0.75,
    "omitted_utterances": 0,
    "boundary_wer": 0.20,
    "speaker_repeat_stability": 1.0,
}


class EvaluationError(RuntimeError):
    """Raised when immutable benchmark evidence violates its contract."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvaluationError(message)


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise EvaluationError(f"cannot read JSON evidence {path}: {error}") from error


def file_sha256(path: Path) -> str:
    digest = sha256()
    try:
        with path.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as error:
        raise EvaluationError(f"cannot hash evidence {path}: {error}") from error
    return digest.hexdigest()


def current_git_head() -> str | None:
    """Return the repository HEAD at evaluation time.

    The recorded experiment head describes the code that produced the run, not
    the code that judged it. This value is the second half of that provenance.
    Returns None when git is unavailable or the evaluator is not inside a work
    tree, so an out-of-repository copy still evaluates.
    """
    try:
        completed = subprocess.run(
            ["git", "-C", str(EVALUATOR_SOURCE.parent), "rev-parse", "HEAD"],
            capture_output=True,
            check=False,
            text=True,
        )
    except OSError:
        return None
    if completed.returncode != 0:
        return None
    return completed.stdout.strip() or None


def evaluator_provenance() -> dict[str, Any]:
    """Name the code that produced a judgment, beside the code that ran it.

    The experiment head belongs to the recorded run; these two fields belong to
    the evaluator, so a preserved artifact can point at the exact source that
    scored it.
    """
    return {
        "evaluator_git_head": current_git_head(),
        "evaluator_source_sha256": file_sha256(EVALUATOR_SOURCE),
    }


def comparable_encoding(result: dict[str, Any]) -> str:
    """Encode a result for the stale comparison, without provenance-only fields.

    Preserved evaluations written before the evaluator recorded its own
    identity have no provenance fields at all, and a rebuilt evaluation always
    carries them. Dropping those fields on both sides keeps the comparison on
    what the evaluation judged, so a preserved verdict stays reproducible while
    a changed metric still fails.
    """
    comparable = {
        key: value
        for key, value in result.items()
        if key not in PROVENANCE_ONLY_FIELDS
    }
    return json.dumps(comparable, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def seal_evaluation(output_path: Path, result: dict[str, Any]) -> None:
    """Create the evaluation artifact once, or prove a preserved one still holds."""
    if output_path.exists():
        preserved = load_json(output_path)
        require(isinstance(preserved, dict), "evaluation.json is not an object")
        require(
            comparable_encoding(preserved) == comparable_encoding(result),
            "evaluation.json is stale",
        )
        return
    encoded = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    with output_path.open("x", encoding="utf-8") as output:
        output.write(encoded)


def safe_relative(root: Path, value: str, *, label: str) -> Path:
    relative = Path(value)
    require(not relative.is_absolute(), f"{label} must be relative: {value}")
    require(".." not in relative.parts, f"{label} escapes its root: {value}")
    resolved_root = root.resolve()
    resolved = (root / relative).resolve()
    require(
        resolved == resolved_root or resolved_root in resolved.parents,
        f"{label} resolves outside its root: {value}",
    )
    require(resolved.is_file() or resolved.is_dir(), f"{label} is missing: {value}")
    return resolved


def joined_text(document: dict[str, Any]) -> str:
    segments = sorted(
        document.get("segments", []),
        key=lambda segment: (float(segment["start_s"]), float(segment["end_s"])),
    )
    return " ".join(str(segment.get("text", "")) for segment in segments).strip()


def overlap(start_a: float, end_a: float, start_b: float, end_b: float) -> float:
    return max(0.0, min(end_a, end_b) - max(start_a, start_b))


def verify_hash(path: Path, expected: str, *, label: str) -> None:
    require(len(expected) == 64, f"{label} has no SHA-256")
    require(file_sha256(path) == expected, f"{label} hash changed: {path}")


def verify_model(value: dict[str, Any], *, label: str) -> None:
    for key, expected in MODEL.items():
        require(value.get(key) == expected, f"{label} model {key} mismatch")


def verify_glossary(
    value: dict[str, Any],
    *,
    expected_sha256: str,
    applied: bool,
    label: str,
) -> None:
    require(value.get("provided") is True, f"{label} glossary was not provided")
    require(value.get("applied") is applied, f"{label} glossary applied flag mismatch")
    require(value.get("sha256") == expected_sha256, f"{label} glossary hash mismatch")
    require(value.get("item_count") == EXPECTED_GLOSSARY_ITEMS, f"{label} glossary count mismatch")
    require(
        value.get("injection_mode") == "hotword_instruction",
        f"{label} glossary mode mismatch",
    )


def verify_helper_fingerprint(value: dict[str, Any], *, label: str) -> str:
    require(value.get("contract_version") == "moss-harness-v2", f"{label} helper contract mismatch")
    fingerprint_sha256 = str(value.get("sha256", ""))
    require(len(fingerprint_sha256) == 64, f"{label} helper fingerprint is missing")
    executable_sha256 = str(value.get("executable_sha256", ""))
    metallib_sha256 = str(value.get("metallib_sha256", ""))
    require(len(executable_sha256) == 64, f"{label} helper executable hash is missing")
    require(len(metallib_sha256) == 64, f"{label} helper metallib hash is missing")
    require(value.get("target_architecture") == "arm64", f"{label} helper architecture mismatch")
    require(value.get("configuration") == "release", f"{label} helper configuration mismatch")
    return fingerprint_sha256


def verify_evidence_path(
    run: Path,
    value: dict[str, Any],
    *,
    path_key: str,
    hash_key: str,
    label: str,
) -> Path:
    evidence = safe_relative(run, str(value.get(path_key, "")), label=label)
    require(evidence.is_file(), f"{label} is not a file")
    verify_hash(evidence, str(value.get(hash_key, "")), label=label)
    return evidence


def verify_attempt_audio(
    run: Path,
    request: dict[str, Any],
    *,
    start_sample: int,
    end_sample: int,
    label: str,
) -> None:
    audio = safe_relative(run, str(request.get("audio_path", "")), label=f"{label} audio")
    require(audio.is_file(), f"{label} audio is not a file")
    verify_hash(audio, str(request.get("audio_sha256", "")), label=f"{label} audio")
    try:
        with wave.open(str(audio), "rb") as source:
            require(source.getnchannels() == 1, f"{label} audio is not mono")
            require(source.getsampwidth() == 2, f"{label} audio is not PCM16")
            require(source.getframerate() == SAMPLE_RATE_HZ, f"{label} audio sample rate mismatch")
            require(source.getcomptype() == "NONE", f"{label} audio is compressed")
            require(
                source.getnframes() == end_sample - start_sample,
                f"{label} audio frame count does not match its request",
            )
    except (OSError, wave.Error) as error:
        raise EvaluationError(f"cannot inspect {label} audio: {error}") from error


def verify_manifest_artifacts(run: Path, manifest: dict[str, Any]) -> int:
    artifacts = manifest.get("artifacts")
    require(isinstance(artifacts, list) and artifacts, "manifest has no artifacts")
    seen: set[str] = set()
    for artifact in artifacts:
        require(isinstance(artifact, dict), "manifest artifact is not an object")
        relative = str(artifact.get("path", ""))
        require(relative not in seen, f"duplicate manifest artifact: {relative}")
        seen.add(relative)
        path = safe_relative(run, relative, label="manifest artifact")
        require(path.is_file(), f"manifest artifact is not a file: {relative}")
        verify_hash(path, str(artifact.get("sha256", "")), label=relative)
    return len(artifacts)


def collect_attempts(run: Path) -> dict[str, dict[str, Any]]:
    root = run / "primary" / "attempts"
    require(root.is_dir(), "run has no attempt tree")
    attempts: dict[str, dict[str, Any]] = {}
    for directory in sorted(path for path in root.iterdir() if path.is_dir()):
        request_path = directory / "request.json"
        outcome_path = directory / "outcome.json"
        require(request_path.is_file(), f"attempt request is missing: {directory.name}")
        require(outcome_path.is_file(), f"attempt outcome is missing: {directory.name}")
        attempts[directory.name] = {
            "directory": directory,
            "request": load_json(request_path),
            "request_sha256": file_sha256(request_path),
            "outcome": load_json(outcome_path),
        }
    require(bool(attempts), "attempt tree is empty")
    return attempts


def metric_value(metrics: dict[str, Any], key: str) -> float:
    value = metrics.get(key)
    require(
        isinstance(value, (int, float)) and not isinstance(value, bool),
        f"attempt metric {key} is missing",
    )
    numeric = float(value)
    require(math.isfinite(numeric) and numeric >= 0, f"attempt metric {key} is invalid")
    return numeric


def parse_time_profile(path: Path) -> dict[str, float | int]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise EvaluationError(f"cannot read time profile {path}: {error}") from error
    wall_matches = re.findall(r"^\s*([0-9]+(?:\.[0-9]+)?)\s+real\b", text, flags=re.MULTILINE)
    rss_matches = re.findall(r"^\s*([0-9]+)\s+maximum resident set size\b", text, flags=re.MULTILINE)
    footprint_matches = re.findall(r"^\s*([0-9]+)\s+peak memory footprint\b", text, flags=re.MULTILINE)
    require(len(wall_matches) == 1, f"time profile has no unique wall time: {path}")
    require(len(rss_matches) == 1, f"time profile has no unique maximum RSS: {path}")
    require(len(footprint_matches) == 1, f"time profile has no unique peak footprint: {path}")
    return {
        "external_wall_time_s": float(wall_matches[0]),
        "maximum_resident_set_size_bytes": int(rss_matches[0]),
        "peak_memory_footprint_bytes": int(footprint_matches[0]),
    }


def analyze_attempt_tree(
    run: Path,
    *,
    leaf_seconds: int,
    maximum_tokens: int,
    forced_recovery: bool,
    input_sha256: str,
    glossary_sha256: str,
    constraint_helper_sha256: str,
) -> dict[str, Any]:
    attempts = collect_attempts(run)
    promotion = load_json(run / "primary" / "promotion.json")
    require(promotion.get("schema_version") == "1.0.0", "promotion schema mismatch")
    require(
        promotion.get("input_sha256_before") == input_sha256
        == promotion.get("input_sha256_at_promotion"),
        "promotion input hash seal mismatch",
    )
    promoted = promotion.get("eos_leaf_attempt_ids")
    require(isinstance(promoted, list) and promoted, "promotion has no EOS leaves")
    require(len(promoted) == len(set(promoted)), "promotion repeats an EOS leaf")
    promoted_set = set(str(value) for value in promoted)
    promoted_result_hashes = promotion.get("eos_leaf_result_sha256")
    require(
        isinstance(promoted_result_hashes, list)
        and len(promoted_result_hashes) == len(promoted),
        "promotion result hash list is incomplete",
    )
    canonical_hashes = promotion.get("canonical_artifact_sha256")
    expected_canonical_paths = {
        "primary/raw.txt",
        "primary/segments.json",
        "merged/segments.json",
        "merged/conflicts.json",
    }
    require(
        isinstance(canonical_hashes, dict)
        and set(canonical_hashes) == expected_canonical_paths,
        "promotion canonical artifact seal is incomplete",
    )
    for relative, expected_hash in canonical_hashes.items():
        canonical_path = safe_relative(run, relative, label=f"canonical artifact {relative}")
        require(canonical_path.is_file(), f"canonical artifact is not a file: {relative}")
        verify_hash(canonical_path, str(expected_hash), label=f"canonical artifact {relative}")

    helper_hashes: set[str] = set()
    statuses: Counter[str] = Counter()
    canonical_ranges: list[tuple[int, int, str]] = []
    result_hash_by_attempt: dict[str, str] = {}
    request_ranges: dict[str, tuple[int, int]] = {}
    request_depths: dict[str, int] = {}
    request_roots: dict[str, int] = {}
    request_parents: dict[str, str | None] = {}
    outcome_children: dict[str, list[str]] = {}
    generated_tokens = 0
    inference_s = 0.0
    model_load_s = 0.0
    runner_wall_s = 0.0
    peak_rss_bytes = 0
    glossary_payload_hashes: set[str] = set()
    attempted_audio_s = 0.0

    for attempt_id, record in attempts.items():
        request = record["request"]
        outcome = record["outcome"]
        require(request.get("schema_version") == "1.0.0", f"request schema mismatch: {attempt_id}")
        require(outcome.get("schema_version") == "1.0.0", f"outcome schema mismatch: {attempt_id}")
        require(request.get("attempt_id") == attempt_id, f"request ID mismatch: {attempt_id}")
        require(outcome.get("attempt_id") == attempt_id, f"outcome ID mismatch: {attempt_id}")
        require(
            outcome.get("request_sha256") == record["request_sha256"],
            f"request hash mismatch: {attempt_id}",
        )
        require(
            outcome.get("canonical_promoted") is False,
            f"create-only outcome was rewritten as promoted: {attempt_id}",
        )
        parent_id = request.get("parent_id")
        require(parent_id is None or isinstance(parent_id, str), f"invalid parent ID: {attempt_id}")
        depth = request.get("depth")
        root_index = request.get("root_chunk_index")
        require(isinstance(depth, int) and depth >= 0, f"invalid depth: {attempt_id}")
        require(isinstance(root_index, int) and root_index >= 0, f"invalid root index: {attempt_id}")
        require(request.get("sample_rate_hz") == SAMPLE_RATE_HZ, f"sample rate mismatch: {attempt_id}")
        require(
            request.get("boundary_source") in {"silence", "deterministic_fallback", "input_end"},
            f"boundary source mismatch: {attempt_id}",
        )
        verify_model(request.get("model") or {}, label=f"request {attempt_id}")
        require(request.get("backend") == "moss", f"non-MOSS attempt: {attempt_id}")
        require(request.get("language") == "it", f"language pin missing: {attempt_id}")
        verify_glossary(
            request.get("glossary") or {},
            expected_sha256=glossary_sha256,
            applied=False,
            label=f"request {attempt_id}",
        )
        require(
            request.get("maximum_tokens") == maximum_tokens,
            f"max tokens mismatch: {attempt_id}",
        )
        start = int(request.get("start_sample", -1))
        end = int(request.get("end_sample", -1))
        require(0 <= start < end <= INPUT_SAMPLES, f"invalid attempt range: {attempt_id}")
        require(
            end - start <= leaf_seconds * SAMPLE_RATE_HZ,
            f"attempt exceeds candidate leaf size: {attempt_id}",
        )
        prompt_tokens = request.get("prompt_tokens")
        audio_tokens = request.get("audio_tokens")
        context_upper_bound = request.get("context_upper_bound_tokens")
        require(isinstance(prompt_tokens, int) and prompt_tokens > 0, f"prompt tokens missing: {attempt_id}")
        require(isinstance(audio_tokens, int) and audio_tokens > 0, f"audio tokens missing: {attempt_id}")
        require(
            isinstance(context_upper_bound, int)
            and context_upper_bound == prompt_tokens + maximum_tokens,
            f"context upper bound mismatch: {attempt_id}",
        )
        require(
            context_upper_bound <= CONTEXT_HARD_CAP_TOKENS,
            f"attempt exceeds context cap: {attempt_id}",
        )
        helper = request.get("helper_fingerprint") or {}
        helper_hash = verify_helper_fingerprint(helper, label=f"request {attempt_id}")
        helper_hashes.add(helper_hash)
        require(
            helper_hash == constraint_helper_sha256,
            f"request helper differs from constraint snapshot: {attempt_id}",
        )
        verify_attempt_audio(
            run,
            request,
            start_sample=start,
            end_sample=end,
            label=f"attempt {attempt_id}",
        )
        request_ranges[attempt_id] = (start, end)
        request_depths[attempt_id] = depth
        request_roots[attempt_id] = root_index
        request_parents[attempt_id] = parent_id

        status = str(outcome.get("status", ""))
        statuses[status] += 1
        children = outcome.get("child_attempt_ids") or []
        require(isinstance(children, list), f"child list is invalid: {attempt_id}")
        require(len(children) == len(set(children)), f"child list repeats an ID: {attempt_id}")
        outcome_children[attempt_id] = [str(child_id) for child_id in children]
        for child_id in children:
            require(str(child_id) in attempts, f"attempt references missing child: {child_id}")

        verify_evidence_path(
            run,
            outcome,
            path_key="runner_record_path",
            hash_key="runner_record_sha256",
            label=f"attempt runner record {attempt_id}",
        )
        verify_evidence_path(
            run,
            outcome,
            path_key="backend_raw_path",
            hash_key="backend_raw_sha256",
            label=f"attempt backend evidence {attempt_id}",
        )
        verify_glossary(
            outcome.get("glossary") or {},
            expected_sha256=glossary_sha256,
            applied=True,
            label=f"outcome {attempt_id}",
        )
        payload_hash = str(outcome.get("glossary_payload_sha256", ""))
        require(len(payload_hash) == 64, f"glossary payload hash missing: {attempt_id}")
        require(
            outcome.get("glossary_payload_entry_count") == EXPECTED_GLOSSARY_ITEMS,
            f"glossary payload count mismatch: {attempt_id}",
        )
        glossary_payload_hashes.add(payload_hash)
        language = outcome.get("language") or {}
        require(language.get("requested") == "it", f"language evidence missing: {attempt_id}")
        require(
            language.get("promptGuidanceApplied") is True,
            f"language guidance missing: {attempt_id}",
        )
        require(
            len(str(language.get("instructionSHA256", ""))) == 64,
            f"language instruction hash missing: {attempt_id}",
        )
        outcome_helper_hash = verify_helper_fingerprint(
            outcome.get("helper_fingerprint") or {},
            label=f"outcome {attempt_id}",
        )
        require(outcome_helper_hash == helper_hash, f"helper changed during attempt: {attempt_id}")
        require(
            isinstance(outcome.get("command"), list) and outcome["command"],
            f"attempt command is missing: {attempt_id}",
        )
        metrics = outcome.get("metrics") or {}
        generated = int(metric_value(metrics, "generatedTokens"))
        generated_tokens += generated
        inference_s += metric_value(metrics, "totalS")
        model_load_s += metric_value(metrics, "modelLoadS")
        runner_wall_s += metric_value(metrics, "runnerWallTimeS")
        peak_rss_bytes = max(peak_rss_bytes, int(metric_value(metrics, "peakRSSBytes")))
        attempted_audio_s += (end - start) / SAMPLE_RATE_HZ
        require(metrics.get("maxTokens") == maximum_tokens, f"metric max tokens mismatch: {attempt_id}")
        require(
            metrics.get("contextHardCapTokens") == CONTEXT_HARD_CAP_TOKENS,
            f"metric context cap mismatch: {attempt_id}",
        )
        require(metrics.get("promptTokens") == prompt_tokens, f"metric prompt mismatch: {attempt_id}")
        require(outcome.get("audio_tokens") == audio_tokens, f"outcome audio tokens mismatch: {attempt_id}")
        require(
            outcome.get("context_tokens") == prompt_tokens + generated,
            f"outcome context tokens mismatch: {attempt_id}",
        )
        require(
            abs(metric_value(metrics, "audioDurationS") - (end - start) / SAMPLE_RATE_HZ) <= 0.02,
            f"attempt audio duration mismatch: {attempt_id}",
        )

        if status == "eos_complete":
            require(
                outcome.get("stop_reason") == "endOfSequence",
                f"EOS attempt has wrong stop reason: {attempt_id}",
            )
            require(not children, f"EOS attempt unexpectedly has children: {attempt_id}")
            result_path = safe_relative(
                run,
                str(outcome.get("result_path", "")),
                label=f"attempt result {attempt_id}",
            )
            result_hash = str(outcome.get("result_sha256", ""))
            verify_hash(
                result_path,
                result_hash,
                label=f"attempt result {attempt_id}",
            )
            result_hash_by_attempt[attempt_id] = result_hash
            if attempt_id in promoted_set:
                canonical_ranges.append((start, end, attempt_id))
        elif status == "limit_isolated":
            require(forced_recovery, f"candidate unexpectedly needed recovery: {attempt_id}")
            require(
                outcome.get("stop_reason") in {"maximumTokens", "contextLimit"},
                f"limit attempt has wrong stop reason: {attempt_id}",
            )
            require(outcome.get("result_path") is None, f"limit partial became a result: {attempt_id}")
            require(outcome.get("result_sha256") is None, f"limit partial retained a result hash: {attempt_id}")
            require(attempt_id not in promoted_set, f"limit partial was promoted: {attempt_id}")
            require(len(children) == 2, f"limit attempt did not split in two: {attempt_id}")
        else:
            raise EvaluationError(f"attempt is not a usable terminal outcome: {attempt_id} / {status}")

    require(len(helper_hashes) == 1, "attempts used different helper fingerprints")
    require(len(glossary_payload_hashes) == 1, "attempts used different glossary payloads")
    for attempt_id, parent_id in request_parents.items():
        if parent_id is None:
            require(request_depths[attempt_id] == 0, f"root depth mismatch: {attempt_id}")
            continue
        require(parent_id in attempts, f"attempt has a missing parent: {attempt_id}")
        require(
            attempt_id in outcome_children[parent_id],
            f"parent does not reference child: {attempt_id}",
        )
        require(
            request_depths[attempt_id] == request_depths[parent_id] + 1,
            f"child depth mismatch: {attempt_id}",
        )
        require(
            request_roots[attempt_id] == request_roots[parent_id],
            f"child changed root index: {attempt_id}",
        )
    for parent_id, children in outcome_children.items():
        if not children:
            continue
        ordered_children = sorted((request_ranges[child_id], child_id) for child_id in children)
        parent_start, parent_end = request_ranges[parent_id]
        require(ordered_children[0][0][0] == parent_start, f"children do not start at parent: {parent_id}")
        require(ordered_children[-1][0][1] == parent_end, f"children do not end at parent: {parent_id}")
        for previous, current in zip(ordered_children, ordered_children[1:]):
            require(previous[0][1] == current[0][0], f"children have a gap or overlap: {parent_id}")

    root_ranges = sorted(
        (request_ranges[attempt_id], attempt_id)
        for attempt_id, parent_id in request_parents.items()
        if parent_id is None
    )
    require(root_ranges[0][0][0] == 0, "root attempts do not start at sample zero")
    require(root_ranges[-1][0][1] == INPUT_SAMPLES, "root attempts do not reach input end")
    for previous, current in zip(root_ranges, root_ranges[1:]):
        require(previous[0][1] == current[0][0], "root attempts have a gap or overlap")

    require(promoted_set == {item[2] for item in canonical_ranges}, "promotion is not EOS-only")
    eos_attempts = {attempt_id for attempt_id, record in attempts.items() if record["outcome"].get("status") == "eos_complete"}
    require(promoted_set == eos_attempts, "an EOS result was not promoted")
    require(
        [result_hash_by_attempt[str(attempt_id)] for attempt_id in promoted]
        == [str(value) for value in promoted_result_hashes],
        "promotion result hashes do not match EOS outcomes",
    )
    ordered = sorted(canonical_ranges)
    require(ordered[0][0] == 0, "canonical coverage does not start at sample zero")
    require(ordered[-1][1] == INPUT_SAMPLES, "canonical coverage does not reach input end")
    for previous, current in zip(ordered, ordered[1:]):
        require(previous[1] == current[0], "canonical EOS leaves have a gap or overlap")
    require(
        statuses["limit_isolated"] > 0 if forced_recovery else statuses["limit_isolated"] == 0,
        "forced recovery status does not match the case",
    )

    return {
        "attempt_count": sum(statuses.values()),
        "canonical_eos_leaf_count": len(ordered),
        "generated_tokens": generated_tokens,
        "helper_fingerprint_sha256": next(iter(helper_hashes)),
        "inference_s": inference_s,
        "model_load_s": model_load_s,
        "peak_rss_bytes": peak_rss_bytes,
        "process_setup_s": max(0.0, runner_wall_s - inference_s),
        "root_attempt_count": len(root_ranges),
        "maximum_root_samples": max(end - start for (start, end), _ in root_ranges),
        "runner_wall_s": runner_wall_s,
        "statuses": dict(sorted(statuses.items())),
        "attempted_audio_s": attempted_audio_s,
        "token_density_per_audio_second": generated_tokens / INPUT_DURATION_S,
    }


def speaker_repeat_consistency(
    reference_segments: Sequence[dict[str, Any]],
    timeline: Sequence[dict[str, Any]],
    *,
    block_duration_s: float,
    repeat_count: int,
) -> dict[str, Any]:
    reference_speakers = sorted({str(segment["speaker"]) for segment in reference_segments})
    require(len(reference_speakers) >= 2, "reference has fewer than two speakers")
    result: dict[str, Any] = {}
    dominant_labels: set[str] = set()
    for reference_speaker in reference_speakers:
        repeats: list[dict[str, Any]] = []
        for repeat_index in range(repeat_count):
            block_start = repeat_index * block_duration_s
            block_end = block_start + block_duration_s
            references = [
                segment
                for segment in reference_segments
                if str(segment["speaker"]) == reference_speaker
                and block_start <= float(segment["start_s"]) < block_end
            ]
            label_overlap: dict[str, float] = {}
            for hypothesis in timeline:
                total = sum(
                    overlap(
                        float(reference["start_s"]),
                        float(reference["end_s"]),
                        float(hypothesis["start_s"]),
                        float(hypothesis["end_s"]),
                    )
                    for reference in references
                )
                if total > 0:
                    label = str(hypothesis["speaker"])
                    label_overlap[label] = label_overlap.get(label, 0.0) + total
            require(bool(label_overlap), f"no diarization overlap for {reference_speaker} repeat {repeat_index}")
            dominant = min(label_overlap, key=lambda label: (-label_overlap[label], label))
            repeats.append(
                {
                    "dominant_label": dominant,
                    "overlap_s": label_overlap[dominant],
                    "repeat_index": repeat_index,
                }
            )
        counts = Counter(item["dominant_label"] for item in repeats)
        dominant, count = min(counts.items(), key=lambda item: (-item[1], item[0]))
        dominant_labels.add(dominant)
        result[reference_speaker] = {
            "dominant_label": dominant,
            "repeat_count": repeat_count,
            "stable_repeat_count": count,
            "stability": count / repeat_count,
            "repeats": repeats,
        }
    require(
        len(dominant_labels) == len(reference_speakers),
        "different reference speakers collapsed to one global label",
    )
    return {"speakers": result}


def timeline_labels_for_segment(
    segment: dict[str, Any],
    timeline: Sequence[dict[str, Any]],
) -> set[str]:
    return {
        str(turn["speaker"])
        for turn in timeline
        if overlap(
            float(segment["start_s"]),
            float(segment["end_s"]),
            float(turn["start_s"]),
            float(turn["end_s"]),
        ) > 0
    }


def verify_primary_merged_speakers(
    primary: dict[str, Any],
    merged: dict[str, Any],
    timeline: Sequence[dict[str, Any]],
) -> dict[str, Any]:
    primary_segments = primary.get("segments") or []
    merged_segments = merged.get("segments") or []
    require(len(primary_segments) == len(merged_segments), "merge changed the segment count")
    speaker_mismatches: list[int] = []
    unknown_count = 0
    for index, (source, attributed) in enumerate(zip(primary_segments, merged_segments)):
        require(source.get("speaker") == "UNASSIGNED", f"primary speaker is assigned: {index}")
        for key in ("start_s", "end_s", "text", "language", "confidence"):
            require(source.get(key) == attributed.get(key), f"merge changed {key}: {index}")
        speaker = str(attributed.get("speaker", ""))
        labels = timeline_labels_for_segment(attributed, timeline)
        if speaker in {"UNKNOWN", "UNASSIGNED"}:
            unknown_count += 1
        elif speaker not in labels:
            speaker_mismatches.append(index)
    return {
        "segment_count": len(primary_segments),
        "speaker_mismatch_indices": speaker_mismatches,
        "unknown_speaker_count": unknown_count,
    }


def normalized_timeline(timeline: Sequence[dict[str, Any]]) -> list[tuple[float, float, str]]:
    label_map: dict[str, str] = {}
    normalized: list[tuple[float, float, str]] = []
    for turn in sorted(
        timeline,
        key=lambda value: (
            float(value["start_s"]),
            float(value["end_s"]),
            str(value["speaker"]),
        ),
    ):
        raw_label = str(turn["speaker"])
        if raw_label not in label_map:
            label_map[raw_label] = f"S{len(label_map):02d}"
        normalized.append(
            (
                round(float(turn["start_s"]), 6),
                round(float(turn["end_s"]), 6),
                label_map[raw_label],
            )
        )
    return normalized


def timeline_frame_agreement(
    left: Sequence[tuple[float, float, str]],
    right: Sequence[tuple[float, float, str]],
) -> dict[str, Any]:
    frame_count = int(INPUT_DURATION_S / TIMELINE_FRAME_STEP_S)

    def frame_labels(timeline: Sequence[tuple[float, float, str]]) -> list[str]:
        labels: list[set[str]] = [set() for _ in range(frame_count)]
        for start, end, label in timeline:
            first = max(0, math.ceil(start / TIMELINE_FRAME_STEP_S - 0.5))
            last = min(frame_count, math.ceil(end / TIMELINE_FRAME_STEP_S - 0.5))
            for index in range(first, last):
                labels[index].add(label)
        return ["+".join(sorted(value)) if value else "SILENCE" for value in labels]

    left_labels = frame_labels(left)
    right_labels = frame_labels(right)
    matching = sum(
        left_value == right_value
        for left_value, right_value in zip(left_labels, right_labels)
    )
    return {
        "agreement": matching / frame_count,
        "frame_count": frame_count,
        "frame_step_s": TIMELINE_FRAME_STEP_S,
        "matching_frames": matching,
    }


def boundary_coverage(
    boundaries: Sequence[dict[str, Any]],
    reference_segments: Sequence[dict[str, Any]],
    hypothesis_segments: Sequence[dict[str, Any]],
    timeline: Sequence[dict[str, Any]],
    terms: Sequence[dict[str, Any]],
) -> dict[str, Any]:
    evidence: list[dict[str, Any]] = []
    for boundary in boundaries[:-1]:
        boundary_s = float(boundary["end_s"])
        nearby = [
            (index, reference)
            for index, reference in enumerate(reference_segments)
            if float(reference["end_s"]) > boundary_s - 10
            and float(reference["start_s"]) < boundary_s + 10
        ]
        nearby_hypotheses = [
            segment
            for segment in hypothesis_segments
            if float(segment["end_s"]) > boundary_s - 10
            and float(segment["start_s"]) < boundary_s + 10
        ]
        local_reference = {"segments": [segment for _, segment in nearby]}
        local_hypothesis = {"segments": nearby_hypotheses}
        local_reference_text = joined_text(local_reference)
        local_terms = []
        for term in terms:
            count = count_term_occurrences(str(term["term"]), local_reference_text)
            if count:
                local_terms.append({"reference_count": count, "term": term["term"]})
        local_scores = score_text(local_reference, local_hypothesis, local_terms)
        local_wer = local_scores["wer"]["error_rate"]
        local_term_recall = local_scores["terms"]["term_recall"]
        speaker_mismatches = [
            index
            for index, segment in enumerate(nearby_hypotheses)
            if str(segment.get("speaker")) not in {"UNKNOWN", "UNASSIGNED"}
            and str(segment.get("speaker")) not in timeline_labels_for_segment(segment, timeline)
        ]
        cut_reference_indices = [
            index
            for index, reference in enumerate(reference_segments)
            if float(reference["start_s"]) < boundary_s < float(reference["end_s"])
        ]
        evidence.append(
            {
                "boundary_s": boundary_s,
                "nearby_reference_indices": [index for index, _ in nearby],
                "cut_reference_indices": cut_reference_indices,
                "local_scores": local_scores,
                "speaker_mismatch_indices": speaker_mismatches,
            }
        )
    return {
        "boundaries": evidence,
        "boundary_count": len(evidence),
        "missing_reference_utterances": sum(
            int(item["local_scores"]["omissions"]["omitted_utterances"])
            for item in evidence
        ),
        "reference_speech_cuts": sum(len(item["cut_reference_indices"]) for item in evidence),
        "speaker_mismatches": sum(len(item["speaker_mismatch_indices"]) for item in evidence),
        "worst_wer": max(
            (float(item["local_scores"]["wer"]["error_rate"] or 0.0) for item in evidence),
            default=0.0,
        ),
        "worst_term_recall": min(
            (
                float(item["local_scores"]["terms"]["term_recall"])
                for item in evidence
                if item["local_scores"]["terms"]["term_recall"] is not None
            ),
            default=1.0,
        ),
    }


def score_text(
    reference: dict[str, Any],
    hypothesis: dict[str, Any],
    terms: Sequence[dict[str, Any]],
) -> dict[str, Any]:
    reference_text = joined_text(reference)
    hypothesis_text = joined_text(hypothesis)
    return {
        "cer": text_error_rate(reference_text, hypothesis_text, unit="character").as_dict(),
        "omissions": utterance_omissions(reference["segments"], hypothesis["segments"]),
        "terms": term_recall(terms, hypothesis_text),
        "wer": text_error_rate(reference_text, hypothesis_text, unit="word").as_dict(),
    }


def quality_passes(
    text_scores: dict[str, Any],
    speaker_consistency: dict[str, Any],
    boundaries: dict[str, Any],
) -> tuple[bool, list[str]]:
    failures: list[str] = []
    cer = text_scores["cer"]["error_rate"]
    wer = text_scores["wer"]["error_rate"]
    recall = text_scores["terms"]["term_recall"]
    omitted = text_scores["omissions"]["omitted_utterances"]
    if cer is None or cer > QUALITY_LIMITS["cer"]:
        failures.append(f"CER {cer} exceeds {QUALITY_LIMITS['cer']}")
    if wer is None or wer > QUALITY_LIMITS["wer"]:
        failures.append(f"WER {wer} exceeds {QUALITY_LIMITS['wer']}")
    if recall is None or recall < QUALITY_LIMITS["term_recall"]:
        failures.append(f"term recall {recall} is below {QUALITY_LIMITS['term_recall']}")
    if omitted != QUALITY_LIMITS["omitted_utterances"]:
        failures.append(f"omitted utterances: {omitted}")
    if boundaries["missing_reference_utterances"] != 0:
        failures.append("a chunk-boundary reference utterance is missing")
    if boundaries["reference_speech_cuts"] != 0:
        failures.append("an initial chunk boundary cuts reference speech")
    if boundaries["speaker_mismatches"] != 0:
        failures.append("a merged boundary speaker disagrees with the global timeline")
    if boundaries["worst_wer"] > QUALITY_LIMITS["boundary_wer"]:
        failures.append(
            f"boundary WER {boundaries['worst_wer']} exceeds {QUALITY_LIMITS['boundary_wer']}"
        )
    for speaker, value in speaker_consistency["speakers"].items():
        if value["stability"] < QUALITY_LIMITS["speaker_repeat_stability"]:
            failures.append(f"speaker {speaker} stability is {value['stability']}")
    return not failures, failures


def case_by_id(experiment: dict[str, Any], identifier: str) -> dict[str, Any]:
    matches = [case for case in experiment.get("cases", []) if case.get("id") == identifier]
    require(len(matches) == 1, f"experiment must contain one {identifier} case")
    return matches[0]


def resolve_execution_run(
    root: Path,
    execution_path: Path,
    execution: dict[str, Any],
    *,
    label: str,
) -> Path:
    recorded = execution.get("run_path")
    if isinstance(recorded, str) and recorded:
        run = safe_relative(root, recorded, label=label)
        require(run.is_dir(), f"{label} is not a directory")
        return run
    runs_directory = execution_path.parent / "runs"
    require(runs_directory.is_dir(), f"{label} parent is missing")
    runs = sorted(
        path
        for path in runs_directory.iterdir()
        if path.is_dir() and not path.is_symlink()
    )
    require(len(runs) == 1, f"{label} has no unique preserved run")
    return runs[0]


def evaluate_explicit_failed_case(
    root: Path,
    experiment: dict[str, Any],
    case: dict[str, Any],
    fixture: dict[str, Any],
    execution_path: Path,
    execution: dict[str, Any],
    time_profile: dict[str, float | int],
) -> dict[str, Any]:
    identifier = str(case["id"])
    require(not case.get("forced_recovery"), f"{identifier} forced recovery failed")
    require(execution.get("exit_code") == 1, f"{identifier} has an unexpected exit code")
    run = resolve_execution_run(
        root,
        execution_path,
        execution,
        label=f"{identifier} failed run",
    )
    manifest = load_json(run / "manifest.json")
    require(manifest.get("schema_version") == "1.0.0", f"{identifier} manifest schema mismatch")
    require(manifest.get("status") == "failed", f"{identifier} failure was not preserved")
    failure = manifest.get("failure") or {}
    require(
        failure.get("code") == INVALID_EOS_OUTPUT_CODE,
        f"{identifier} manifest failure code mismatch",
    )
    require(manifest.get("input", {}).get("sha256") == fixture["input_sha256"], f"{identifier} input hash mismatch")
    models = manifest.get("models") or []
    asr_models = [model for model in models if model.get("role") == "asr"]
    require(len(asr_models) == 1, f"{identifier} has no unique ASR model")
    verify_model(asr_models[0], label=identifier)
    coverage = manifest.get("coverage") or {}
    require(abs(float(coverage.get("input_duration_s", -1)) - INPUT_DURATION_S) < 0.02, f"{identifier} input duration mismatch")
    require(coverage.get("processed_duration_s") == 0, f"{identifier} promoted failed output")
    require(coverage.get("chunks_completed") == 0, f"{identifier} completed a failed root")
    require(coverage.get("truncated") is True, f"{identifier} failure is not truncated")
    verify_glossary(
        manifest.get("glossary") or {},
        expected_sha256=fixture["glossary_sha256"],
        applied=False,
        label=identifier,
    )
    artifact_count = verify_manifest_artifacts(run, manifest)

    constraints = load_json(run / "preprocess" / "asr-constraints.json")
    require(constraints.get("schema_version") == "1.0.0", f"{identifier} constraint schema mismatch")
    require(constraints.get("backend") == "moss", f"{identifier} constraint backend mismatch")
    verify_model(constraints.get("model") or {}, label=f"{identifier} constraints")
    policy = constraints.get("policy") or {}
    leaf_seconds = int(case["leaf_seconds"])
    maximum_tokens = int(case["maximum_tokens"])
    require(policy.get("source") == "benchmark-evaluation", f"{identifier} policy source missing")
    require(policy.get("minimum_initial_duration_s") == 120, f"{identifier} minimum leaf mismatch")
    require(policy.get("preferred_initial_duration_s") == leaf_seconds, f"{identifier} preferred leaf mismatch")
    require(policy.get("maximum_initial_duration_s") == leaf_seconds, f"{identifier} maximum leaf mismatch")
    require(policy.get("minimum_recovery_duration_s") == 30, f"{identifier} recovery floor mismatch")
    require(policy.get("maximum_recovery_depth") == 3, f"{identifier} recovery depth mismatch")
    require(policy.get("maximum_tokens") == maximum_tokens, f"{identifier} policy token mismatch")
    require(policy.get("context_hard_cap_tokens") == CONTEXT_HARD_CAP_TOKENS, f"{identifier} policy context cap mismatch")
    require(constraints.get("total_samples") == INPUT_SAMPLES, f"{identifier} constraint sample count mismatch")
    require(constraints.get("overlap_enabled") is False, f"{identifier} overlap unexpectedly enabled")
    require(constraints.get("previous_text_context_enabled") is False, f"{identifier} previous-text context unexpectedly enabled")
    require(constraints.get("sequential_concurrency") == 1, f"{identifier} concurrency mismatch")
    constraint_helper_sha256 = verify_helper_fingerprint(
        constraints.get("helper_fingerprint") or {},
        label=f"{identifier} constraints",
    )
    context = constraints.get("moss_context_plan") or {}
    verify_model(context.get("model") or {}, label=f"{identifier} context")
    require(context.get("language") == "it", f"{identifier} context language mismatch")
    require(context.get("glossary_sha256") == fixture["glossary_sha256"], f"{identifier} context glossary mismatch")
    require(context.get("glossary_item_count") == EXPECTED_GLOSSARY_ITEMS, f"{identifier} context glossary count mismatch")
    require(context.get("helper_fingerprint_sha256") == constraint_helper_sha256, f"{identifier} context helper mismatch")
    require(context.get("maximum_tokens") == maximum_tokens, f"{identifier} context token mismatch")
    require(context.get("context_hard_cap_tokens") == CONTEXT_HARD_CAP_TOKENS, f"{identifier} context cap mismatch")

    attempts = collect_attempts(run)
    require(len(attempts) == 1, f"{identifier} failure did not stop at its first root")
    attempt_id, attempt = next(iter(attempts.items()))
    request = attempt["request"]
    outcome = attempt["outcome"]
    require(attempt_id == "chunk-0000-root", f"{identifier} failed at an unexpected attempt")
    require(outcome.get("request_sha256") == attempt["request_sha256"], f"{identifier} request hash mismatch")
    require(
        outcome.get("status") == INVALID_EOS_OUTPUT_CODE,
        f"{identifier} attempt status mismatch",
    )
    require(
        outcome.get("error_code") == INVALID_EOS_OUTPUT_CODE,
        f"{identifier} attempt error code mismatch",
    )
    require(outcome.get("canonical_promoted") is False, f"{identifier} promoted invalid EOS output")
    require(not outcome.get("child_attempt_ids"), f"{identifier} split an unclassified backend failure")
    require(request.get("backend") == "moss", f"{identifier} request backend mismatch")
    verify_model(request.get("model") or {}, label=f"{identifier} request")
    require(request.get("maximum_tokens") == maximum_tokens, f"{identifier} request token mismatch")
    require(request.get("language") == "it", f"{identifier} request language mismatch")
    require(request.get("helper_fingerprint", {}).get("sha256") == constraint_helper_sha256, f"{identifier} request helper mismatch")
    verify_glossary(
        request.get("glossary") or {},
        expected_sha256=fixture["glossary_sha256"],
        applied=False,
        label=f"{identifier} request",
    )
    start_sample = int(request.get("start_sample", -1))
    end_sample = int(request.get("end_sample", -1))
    require(start_sample == 0, f"{identifier} first request did not start at zero")
    require(0 < end_sample - start_sample <= leaf_seconds * SAMPLE_RATE_HZ, f"{identifier} request range mismatch")
    verify_attempt_audio(
        run,
        request,
        start_sample=start_sample,
        end_sample=end_sample,
        label=identifier,
    )

    helper_outputs = sorted(
        path
        for path in (attempt["directory"] / "backend-records").glob("*/moss.json")
        if path.is_file() and not path.is_symlink()
    )
    require(len(helper_outputs) == 1, f"{identifier} has no unique helper output")
    helper_output = load_json(helper_outputs[0])
    helper_model = helper_output.get("model") or {}
    require(helper_model.get("hf_id") == MODEL["hf_model_id"], f"{identifier} helper model ID mismatch")
    require(helper_model.get("revision") == MODEL["revision"], f"{identifier} helper revision mismatch")
    require(helper_model.get("quantization") == MODEL["quantization"], f"{identifier} helper quantization mismatch")
    helper_glossary = helper_output.get("glossary") or {}
    helper_language = helper_output.get("language") or {}
    instruction_sha256 = str(helper_glossary.get("instruction_sha256", ""))
    require(helper_output.get("status") == "failed", f"{identifier} helper failure status mismatch")
    require(helper_glossary.get("applied") is True, f"{identifier} helper lost the glossary")
    require(helper_glossary.get("item_count") == EXPECTED_GLOSSARY_ITEMS, f"{identifier} helper glossary count mismatch")
    require(len(instruction_sha256) == 64, f"{identifier} helper instruction hash missing")
    require(helper_language.get("requested") == "it", f"{identifier} helper language mismatch")
    require(helper_language.get("instruction_sha256") == instruction_sha256, f"{identifier} helper language hash mismatch")
    require(helper_language.get("prompt_guidance_applied") is True, f"{identifier} helper language guidance missing")
    helper_metrics = helper_output.get("metrics") or {}
    require(helper_metrics.get("stop_reason") == "endOfSequence", f"{identifier} helper stop mismatch")
    require(helper_metrics.get("max_tokens") == maximum_tokens, f"{identifier} helper token mismatch")
    require(helper_metrics.get("context_hard_cap_tokens") == CONTEXT_HARD_CAP_TOKENS, f"{identifier} helper context cap mismatch")
    require(helper_metrics.get("prompt_tokens") == context.get("prompt_tokens"), f"{identifier} helper prompt mismatch")
    require(isinstance(helper_output.get("raw_text"), str) and helper_output["raw_text"], f"{identifier} did not preserve isolated raw output")
    require(helper_output.get("segments") == [], f"{identifier} helper failure unexpectedly has segments")
    helper_failure = helper_output.get("failure") or {}
    require(
        helper_failure.get("code") == INVALID_EOS_OUTPUT_CODE,
        f"{identifier} helper failure reason mismatch",
    )

    created_canonical = [
        relative
        for relative in (
            "primary/promotion.json",
            "primary/raw.txt",
            "primary/segments.json",
            "merged/segments.json",
        )
        if (run / relative).exists()
    ]
    require(
        not created_canonical,
        f"{identifier} created canonical output after failure: {', '.join(created_canonical)}",
    )
    timeline = load_json(run / "diarization" / "timeline.json")
    require(isinstance(timeline, list) and timeline, f"{identifier} timeline is empty")
    canonical_timeline = normalized_timeline(timeline)
    # Every element below is re-read from the preserved evidence, so the
    # reported integrity is the conjunction of the checks this function made
    # rather than a constant the caller has to trust.
    integrity_checks = {
        "attempt_error_code_is_typed": outcome.get("error_code") == INVALID_EOS_OUTPUT_CODE,
        "canonical_output_absent": not created_canonical,
        "failure_is_truncated": coverage.get("truncated") is True,
        "helper_failure_code_is_typed": helper_failure.get("code") == INVALID_EOS_OUTPUT_CODE,
        "input_hash_matches_fixture": manifest.get("input", {}).get("sha256")
        == fixture["input_sha256"],
        "manifest_artifacts_sealed": artifact_count > 0,
        "manifest_failure_code_is_typed": failure.get("code") == INVALID_EOS_OUTPUT_CODE,
        "nothing_promoted": outcome.get("canonical_promoted") is False
        and coverage.get("processed_duration_s") == 0
        and coverage.get("chunks_completed") == 0,
        "stopped_at_first_root": len(attempts) == 1,
        "timeline_preserved": bool(canonical_timeline),
    }
    manifest_wall_time = (manifest.get("timing") or {}).get("wall_time_s")
    execution_wall_time = (
        float(manifest_wall_time)
        if isinstance(manifest_wall_time, (int, float))
        and not isinstance(manifest_wall_time, bool)
        else None
    )
    return {
        "_normalized_timeline": canonical_timeline,
        "artifact_count": artifact_count,
        "attempts": {
            "attempt_count": 1,
            "measurement_status": "unavailable",
            "process_setup_s": None,
            "runner_wall_s": None,
            "statuses": {INVALID_EOS_OUTPUT_CODE: 1},
        },
        "boundary_coverage": None,
        "disposition": "disqualified",
        "execution_wall_time_s": execution_wall_time,
        "explicit_failure": {
            "attempt_error_code": outcome["error_code"],
            "code": INVALID_EOS_OUTPUT_CODE,
            "failure_point": "moss_helper_output",
            "helper_output_sha256": file_sha256(helper_outputs[0]),
            "isolated_raw_output": True,
            "manifest_failure_code": failure["code"],
            "promoted": False,
        },
        "external_process_profile": time_profile,
        "forced_recovery": False,
        "id": identifier,
        "integrity_passed": all(integrity_checks.values()),
        "leaf_seconds": leaf_seconds,
        "maximum_tokens": maximum_tokens,
        "merge_integrity": None,
        "quality_failures": ["MOSS EOS output had no inspectable segments"],
        "quality_gate_eligible": False,
        "quality_pass": False,
        "speaker_consistency": None,
        "text_scores": None,
        "timeline_normalized_sha256": sha256(
            json.dumps(canonical_timeline, separators=(",", ":")).encode("utf-8")
        ).hexdigest(),
    }


def evaluate_case(
    root: Path,
    experiment: dict[str, Any],
    case: dict[str, Any],
    fixture: dict[str, Any],
) -> dict[str, Any]:
    identifier = str(case["id"])
    execution_path = safe_relative(
        root,
        str(case["execution_path"]),
        label=f"{identifier} execution",
    )
    execution = load_json(execution_path)
    require(execution.get("exit_code") in {0, 1}, f"{identifier} command exit is invalid")
    require(execution.get("git_head") == experiment.get("git_head"), f"{identifier} git head changed")
    require(execution.get("id") == identifier, f"{identifier} execution ID mismatch")
    require(execution.get("leaf_seconds") == case.get("leaf_seconds"), f"{identifier} execution leaf mismatch")
    require(execution.get("maximum_tokens") == case.get("maximum_tokens"), f"{identifier} execution token mismatch")
    require(
        execution.get("environment")
        == {
            "MACCHERONI_ENABLE_BENCHMARK_OVERRIDES": "1",
            "MACCHERONI_MOSS_EVAL_LEAF_SECONDS": str(case["leaf_seconds"]),
            "MACCHERONI_MOSS_EVAL_MAX_TOKENS": str(case["maximum_tokens"]),
        },
        f"{identifier} execution environment mismatch",
    )
    stdout_path = execution_path.parent / "stdout.log"
    stderr_time_path = execution_path.parent / "stderr-time.log"
    verify_hash(stdout_path, str(execution.get("stdout_sha256", "")), label=f"{identifier} stdout")
    verify_hash(stderr_time_path, str(execution.get("stderr_time_sha256", "")), label=f"{identifier} stderr/time")
    time_profile = parse_time_profile(stderr_time_path)
    require(
        execution.get("input_sha256_before") == fixture["input_sha256"]
        == execution.get("input_sha256_after"),
        f"{identifier} changed the input",
    )
    if execution.get("exit_code") != 0:
        return evaluate_explicit_failed_case(
            root,
            experiment,
            case,
            fixture,
            execution_path,
            execution,
            time_profile,
        )
    run = resolve_execution_run(
        root,
        execution_path,
        execution,
        label=f"{identifier} run",
    )
    manifest = load_json(run / "manifest.json")
    require(manifest.get("schema_version") == "1.0.0", f"{identifier} manifest schema mismatch")
    require(manifest.get("status") == "succeeded", f"{identifier} did not succeed")
    require(manifest.get("failure") is None, f"{identifier} retained a failure")
    require(manifest.get("input", {}).get("sha256") == fixture["input_sha256"], f"{identifier} input hash mismatch")
    models = manifest.get("models") or []
    asr_models = [model for model in models if model.get("role") == "asr"]
    require(len(asr_models) == 1, f"{identifier} has no unique ASR model")
    verify_model(asr_models[0], label=identifier)
    coverage = manifest.get("coverage") or {}
    require(abs(float(coverage.get("input_duration_s", -1)) - INPUT_DURATION_S) < 0.02, f"{identifier} input duration mismatch")
    require(abs(float(coverage.get("processed_duration_s", -1)) - INPUT_DURATION_S) < 0.02, f"{identifier} coverage shortfall")
    require(coverage.get("truncated") is False, f"{identifier} is truncated")
    require(coverage.get("chunks_completed") == coverage.get("chunks_planned"), f"{identifier} has incomplete roots")
    glossary = manifest.get("glossary") or {}
    verify_glossary(
        glossary,
        expected_sha256=fixture["glossary_sha256"],
        applied=True,
        label=identifier,
    )
    artifact_count = verify_manifest_artifacts(run, manifest)

    constraints = load_json(run / "preprocess" / "asr-constraints.json")
    require(constraints.get("schema_version") == "1.0.0", f"{identifier} constraint schema mismatch")
    require(constraints.get("backend") == "moss", f"{identifier} constraint backend mismatch")
    verify_model(constraints.get("model") or {}, label=f"{identifier} constraints")
    policy = constraints.get("policy") or {}
    leaf_seconds = int(case["leaf_seconds"])
    maximum_tokens = int(case["maximum_tokens"])
    require(policy.get("source") == "benchmark-evaluation", f"{identifier} policy source missing")
    require(policy.get("sample_rate_hz") == SAMPLE_RATE_HZ, f"{identifier} policy sample rate mismatch")
    require(policy.get("minimum_initial_duration_s") == 120, f"{identifier} minimum leaf mismatch")
    require(policy.get("preferred_initial_duration_s") == leaf_seconds, f"{identifier} preferred leaf mismatch")
    require(policy.get("maximum_initial_duration_s") == leaf_seconds, f"{identifier} maximum leaf mismatch")
    require(policy.get("minimum_recovery_duration_s") == 30, f"{identifier} recovery floor mismatch")
    require(policy.get("maximum_recovery_depth") == 3, f"{identifier} recovery depth mismatch")
    require(policy.get("maximum_tokens") == maximum_tokens, f"{identifier} policy token mismatch")
    require(policy.get("context_hard_cap_tokens") == CONTEXT_HARD_CAP_TOKENS, f"{identifier} policy context cap mismatch")
    require(constraints.get("total_samples") == INPUT_SAMPLES, f"{identifier} constraint sample count mismatch")
    require(constraints.get("overlap_enabled") is False, f"{identifier} overlap unexpectedly enabled")
    require(
        constraints.get("previous_text_context_enabled") is False,
        f"{identifier} previous-text context unexpectedly enabled",
    )
    require(constraints.get("sequential_concurrency") == 1, f"{identifier} concurrency mismatch")
    require(constraints.get("preflight_failure") is None, f"{identifier} retained a preflight failure")
    constraint_helper_sha256 = verify_helper_fingerprint(
        constraints.get("helper_fingerprint") or {},
        label=f"{identifier} constraints",
    )
    context = constraints.get("moss_context_plan") or {}
    require(context.get("backend") == "moss", f"{identifier} context backend mismatch")
    verify_model(context.get("model") or {}, label=f"{identifier} context")
    require(context.get("language") == "it", f"{identifier} context language mismatch")
    require(context.get("glossary_sha256") == fixture["glossary_sha256"], f"{identifier} context glossary mismatch")
    require(context.get("glossary_item_count") == EXPECTED_GLOSSARY_ITEMS, f"{identifier} context glossary count mismatch")
    require(len(str(context.get("glossary_payload_sha256", ""))) == 64, f"{identifier} context glossary payload missing")
    require(
        context.get("helper_fingerprint_sha256") == constraint_helper_sha256,
        f"{identifier} context helper mismatch",
    )
    require(context.get("maximum_tokens") == maximum_tokens, f"{identifier} context token mismatch")
    require(context.get("context_hard_cap_tokens") == CONTEXT_HARD_CAP_TOKENS, f"{identifier} context cap mismatch")

    forced = bool(case.get("forced_recovery"))
    attempts = analyze_attempt_tree(
        run,
        leaf_seconds=leaf_seconds,
        maximum_tokens=maximum_tokens,
        forced_recovery=forced,
        input_sha256=fixture["input_sha256"],
        glossary_sha256=fixture["glossary_sha256"],
        constraint_helper_sha256=constraint_helper_sha256,
    )
    require(
        context.get("sample_count") == attempts["maximum_root_samples"],
        f"{identifier} context sample count is not the largest root leaf",
    )
    chunks = manifest.get("chunk_boundaries") or []
    require(bool(chunks), f"{identifier} has no root boundaries")
    require(
        constraints.get("initial_leaf_count") == len(chunks) == attempts["root_attempt_count"],
        f"{identifier} root count mismatch",
    )
    require(
        all(float(chunk["end_s"]) - float(chunk["start_s"]) <= leaf_seconds + 0.01 for chunk in chunks),
        f"{identifier} root exceeds its candidate leaf size",
    )
    hypothesis = load_json(run / "merged" / "segments.json")
    primary = load_json(run / "primary" / "segments.json")
    for label, document in (("primary", primary), ("merged", hypothesis)):
        require(document.get("schema_version") == "1.0.0", f"{identifier} {label} schema mismatch")
        source = document.get("source") or {}
        require(source.get("sha256") == fixture["input_sha256"], f"{identifier} {label} source hash mismatch")
        require(
            abs(float(source.get("duration_s", -1)) - INPUT_DURATION_S) < 0.02,
            f"{identifier} {label} source duration mismatch",
        )
    reference_path = safe_relative(root, fixture["reference_segments_path"], label="reference segments")
    terms_path = safe_relative(root, fixture["terms_path"], label="terms")
    reference = load_json(reference_path)
    terms = load_json(terms_path)
    text_scores = score_text(reference, hypothesis, terms)
    timeline = load_json(run / "diarization" / "timeline.json")
    require(isinstance(timeline, list) and timeline, f"{identifier} timeline is empty")
    merge_integrity = verify_primary_merged_speakers(primary, hypothesis, timeline)
    require(
        not merge_integrity["speaker_mismatch_indices"],
        f"{identifier} merged speakers disagree with the global timeline",
    )
    speaker_consistency = speaker_repeat_consistency(
        reference["segments"],
        timeline,
        block_duration_s=float(fixture["block_duration_s"]),
        repeat_count=int(fixture["repeat_count"]),
    )
    boundaries = boundary_coverage(
        chunks,
        reference["segments"],
        hypothesis["segments"],
        timeline,
        terms,
    )
    passes, failures = quality_passes(text_scores, speaker_consistency, boundaries)
    if forced:
        require(passes, f"forced recovery canonical output failed quality: {failures}")

    canonical_timeline = normalized_timeline(timeline)
    # Same rule as the disqualified path: integrity is the conjunction of the
    # structural checks made here, never a literal.
    integrity_checks = {
        "attempt_tree_covers_input": attempts["canonical_eos_leaf_count"] > 0,
        "coverage_complete": coverage.get("truncated") is False
        and coverage.get("chunks_completed") == coverage.get("chunks_planned"),
        "input_hash_matches_fixture": manifest.get("input", {}).get("sha256")
        == fixture["input_sha256"],
        "input_unchanged_by_execution": execution.get("input_sha256_before")
        == fixture["input_sha256"]
        == execution.get("input_sha256_after"),
        "manifest_artifacts_sealed": artifact_count > 0,
        "manifest_succeeded": manifest.get("status") == "succeeded"
        and manifest.get("failure") is None,
        "merge_preserved_segments": merge_integrity["segment_count"] > 0
        and not merge_integrity["speaker_mismatch_indices"],
        "no_preflight_failure": constraints.get("preflight_failure") is None,
        "root_count_agrees": constraints.get("initial_leaf_count")
        == len(chunks)
        == attempts["root_attempt_count"],
        "timeline_preserved": bool(canonical_timeline),
    }
    return {
        "_normalized_timeline": canonical_timeline,
        "artifact_count": artifact_count,
        "attempts": attempts,
        "boundary_coverage": boundaries,
        "disposition": "forced_recovery_evidence" if forced else "quality_candidate",
        "execution_wall_time_s": float(manifest.get("timing", {}).get("wall_time_s", 0)),
        "external_process_profile": time_profile,
        "forced_recovery": forced,
        "id": identifier,
        "integrity_passed": all(integrity_checks.values()),
        "leaf_seconds": leaf_seconds,
        "maximum_tokens": maximum_tokens,
        "merge_integrity": merge_integrity,
        "quality_failures": failures,
        "quality_gate_eligible": not forced,
        "quality_pass": passes,
        "speaker_consistency": speaker_consistency,
        "text_scores": text_scores,
        "timeline_normalized_sha256": sha256(
            json.dumps(canonical_timeline, separators=(",", ":")).encode("utf-8")
        ).hexdigest(),
    }


def choose_default(cases: Iterable[dict[str, Any]]) -> int | None:
    eligible = [
        case
        for case in cases
        if not case.get("forced_recovery")
        and case.get("explicit_failure") is None
        and case.get("quality_pass")
    ]
    if not eligible:
        return None
    winner = min(
        eligible,
        key=lambda case: (
            float(case["attempts"]["runner_wall_s"]),
            float(
                (case.get("external_process_profile") or {}).get(
                    "external_wall_time_s",
                    case["execution_wall_time_s"],
                )
            ),
            float(case["attempts"]["process_setup_s"]),
            -int(case["leaf_seconds"]),
        ),
    )
    return int(winner["leaf_seconds"])


def default_decision(cases: Sequence[dict[str, Any]]) -> dict[str, Any]:
    suggested = choose_default(cases)
    if suggested is not None:
        return {
            "status": "selected",
            "suggested_default_leaf_seconds": suggested,
            "stop_condition": None,
        }
    return {
        "status": "stop_no_quality_candidate",
        "suggested_default_leaf_seconds": None,
        "stop_condition": {
            "code": "NO_CANDIDATE_PASSED_FIXED_QUALITY_LIMITS",
            "candidate_failures": {
                str(case["id"]): list(case.get("quality_failures") or [])
                for case in cases
                if not case.get("forced_recovery")
                and case.get("explicit_failure") is None
            },
        },
    }


def derive_verdict(cases: Sequence[dict[str, Any]]) -> dict[str, Any]:
    by_id = {str(case.get("id")): case for case in cases}
    expected_ids = {f"candidate-{seconds}" for seconds in CANDIDATE_SECONDS} | {
        "forced-recovery-240-1024"
    }
    require(set(by_id) == expected_ids, "verdict case matrix mismatch")
    require(len(by_id) == len(cases), "verdict case IDs are not unique")

    anomalies: list[dict[str, Any]] = []
    for case in cases:
        explicit = case.get("explicit_failure")
        if explicit is None:
            continue
        require(
            explicit.get("code") == INVALID_EOS_OUTPUT_CODE,
            f"{case['id']} has an unexplained explicit failure",
        )
        require(
            not case.get("forced_recovery"),
            "forced recovery cannot be a disqualified candidate",
        )
        anomalies.append(
            {
                "case_id": str(case["id"]),
                "code": INVALID_EOS_OUTPUT_CODE,
                "disposition": "candidate_disqualified",
                "failure_point": explicit.get("failure_point"),
            }
        )

    candidate_120 = by_id["candidate-120"]
    forced = by_id["forced-recovery-240-1024"]
    candidate_120_passed = (
        candidate_120.get("explicit_failure") is None
        and candidate_120.get("quality_pass") is True
    )
    forced_passed = (
        forced.get("explicit_failure") is None
        and forced.get("quality_pass") is True
    )
    integrity_passed = all(case.get("integrity_passed") is True for case in cases)
    quality_gate_passed = candidate_120_passed and forced_passed
    explained_case_ids = {str(anomaly["case_id"]) for anomaly in anomalies}
    unexplained_failure_count = sum(
        1
        for case in cases
        if case.get("explicit_failure") is not None
        and str(case.get("id")) not in explained_case_ids
    )
    return {
        "anomalies": anomalies,
        "candidate_120_quality_gate_passed": candidate_120_passed,
        "forced_recovery_gate_passed": forced_passed,
        "passed": quality_gate_passed and integrity_passed,
        "preserved_run_integrity_passed": integrity_passed,
        "quality_comparison_case_ids": [
            str(case["id"])
            for case in cases
            if not case.get("forced_recovery")
            and case.get("explicit_failure") is None
        ],
        "quality_gate_passed": quality_gate_passed,
        "unexplained_failure_count": unexplained_failure_count,
    }


def evaluate(root: Path) -> dict[str, Any]:
    root = root.resolve()
    require(root.is_dir(), f"evaluation root does not exist: {root}")
    experiment = load_json(root / "experiment.json")
    require(experiment.get("schema_version") == "1.0.0", "experiment schema mismatch")
    git_head = str(experiment.get("git_head", ""))
    require(len(git_head) == 40, "experiment has no exact git head")
    fixture = experiment.get("fixture") or {}
    provenance_path = safe_relative(root, str(fixture.get("provenance_path", "")), label="fixture provenance")
    verify_hash(provenance_path, str(fixture.get("provenance_sha256", "")), label="fixture provenance")
    provenance = load_json(provenance_path)
    require(provenance.get("generator") == "run_moss_long_audio_eval.sh", "fixture generator mismatch")
    require(provenance.get("git_head") == git_head, "fixture provenance git head mismatch")
    require(
        provenance.get("source_hashes_before") == PINNED_SYNTHETIC_SOURCE_HASHES
        == provenance.get("source_hashes_after"),
        "fixture is not derived from the pinned local synthetic source",
    )
    input_path = safe_relative(root, str(fixture.get("input_path", "")), label="fixture input")
    require(input_path.is_file(), "fixture input is not a file")
    verify_hash(input_path, str(fixture.get("input_sha256", "")), label="fixture input")
    require(abs(float(fixture.get("duration_s", -1)) - INPUT_DURATION_S) < 0.001, "fixture duration mismatch")
    require(fixture.get("sample_rate_hz") == SAMPLE_RATE_HZ, "fixture sample rate mismatch")
    require(fixture.get("repeat_count") == 20, "fixture repeat count mismatch")
    require(fixture.get("block_duration_s") == 30, "fixture block duration mismatch")
    glossary_path = safe_relative(root, str(fixture.get("glossary_path", "")), label="fixture glossary")
    verify_hash(glossary_path, str(fixture.get("glossary_sha256", "")), label="fixture glossary")
    reference_path = safe_relative(root, str(fixture.get("reference_segments_path", "")), label="reference segments")
    verify_hash(reference_path, str(fixture.get("reference_segments_sha256", "")), label="reference segments")
    reference_rttm_path = safe_relative(root, str(fixture.get("reference_rttm_path", "")), label="reference RTTM")
    verify_hash(reference_rttm_path, str(fixture.get("reference_rttm_sha256", "")), label="reference RTTM")
    terms_path = safe_relative(root, str(fixture.get("terms_path", "")), label="terms")
    verify_hash(terms_path, str(fixture.get("terms_sha256", "")), label="terms")
    generated = provenance.get("generated") or {}
    require(generated.get("input_sha256") == fixture.get("input_sha256"), "provenance input hash mismatch")
    require(generated.get("glossary_sha256") == fixture.get("glossary_sha256"), "provenance glossary hash mismatch")
    require(
        generated.get("reference_segments_sha256") == fixture.get("reference_segments_sha256"),
        "provenance reference segment hash mismatch",
    )
    require(
        generated.get("reference_rttm_sha256") == fixture.get("reference_rttm_sha256"),
        "provenance reference RTTM hash mismatch",
    )
    require(generated.get("terms_sha256") == fixture.get("terms_sha256"), "provenance terms hash mismatch")

    expected_ids = {f"candidate-{seconds}" for seconds in CANDIDATE_SECONDS} | {"forced-recovery-240-1024"}
    actual_ids = {str(case.get("id")) for case in experiment.get("cases", [])}
    require(actual_ids == expected_ids, "experiment case matrix mismatch")
    cases = [
        evaluate_case(root, experiment, case_by_id(experiment, f"candidate-{seconds}"), fixture)
        for seconds in CANDIDATE_SECONDS
    ]
    forced = evaluate_case(
        root,
        experiment,
        case_by_id(experiment, "forced-recovery-240-1024"),
        fixture,
    )
    cases.append(forced)
    baseline_timeline = cases[0]["_normalized_timeline"]
    timeline_agreements: dict[str, dict[str, Any]] = {}
    for case in cases[1:]:
        agreement = timeline_frame_agreement(
            baseline_timeline,
            case["_normalized_timeline"],
        )
        require(
            agreement["agreement"] >= TIMELINE_MINIMUM_AGREEMENT,
            f"{case['id']} global diarization timeline agreement is "
            f"{agreement['agreement']}",
        )
        timeline_agreements[f"{cases[0]['id']}:{case['id']}"] = agreement
    for case in cases:
        case.pop("_normalized_timeline")
    decision = default_decision(cases)
    verdict = derive_verdict(cases)
    result = {
        **verdict,
        **evaluator_provenance(),
        "cases": cases,
        "default_decision": decision,
        "evaluation_id": experiment.get("evaluation_id"),
        "fixture": {
            "duration_s": fixture["duration_s"],
            "input_sha256": fixture["input_sha256"],
            "repeat_count": fixture["repeat_count"],
        },
        "git_head": git_head,
        "model": MODEL,
        "quality_limits": QUALITY_LIMITS,
        "schema_version": "1.0.0",
        "suggested_default_leaf_seconds": decision["suggested_default_leaf_seconds"],
        "timeline_agreements": timeline_agreements,
        "timeline_minimum_agreement": TIMELINE_MINIMUM_AGREEMENT,
    }
    seal_evaluation(root / "evaluation.json", result)
    return result


def main(argv: Sequence[str]) -> int:
    if len(argv) != 2:
        print("usage: evaluate_moss_long_audio.py EVALUATION_ROOT", file=sys.stderr)
        return 64
    try:
        result = evaluate(Path(argv[1]))
    except EvaluationError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(json.dumps({
        "evaluation_id": result["evaluation_id"],
        "passed": result["passed"],
        "quality_gate_passed": result["quality_gate_passed"],
        "suggested_default_leaf_seconds": result["suggested_default_leaf_seconds"],
    }, sort_keys=True))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
